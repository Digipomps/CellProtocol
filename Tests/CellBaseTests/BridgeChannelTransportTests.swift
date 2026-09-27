// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

final class BridgeChannelTransportTests: XCTestCase {
    typealias A = BridgeChannelAuthentication
    private var previousResolver: CellResolverProtocol?
    private var previousVault: IdentityVaultProtocol?
    override func setUp() {
        previousResolver = CellBase.defaultCellResolver
        previousVault = CellBase.defaultIdentityVault
    }
    override func tearDown() {
        CellBase.defaultCellResolver = previousResolver
        CellBase.defaultIdentityVault = previousVault
    }
    private func endpoint() throws -> A.Endpoint {
        try .init(url: XCTUnwrap(URL(string: "wss://bridge.example/bridgehead/Protected/client")), domain: "bridge")
    }
    private func identity(_ context: String = "client") async -> Identity {
        await MockIdentityVault().identity(for: context, makeNewIfNotFound: true)!
    }

    func testEveryPreAuthCommandFailsBeforeFactoryOrResolverIncludingResponsesAndReady() async throws {
        for name in ["ready", "get", "set", "admit", "agreement", "description", "feed", "sign", "response", "openChannel", "closeChannel", "unknown"] {
            let counter = ChannelCounter()
            let wire = ChannelWire()
            let limits = BridgeChannelLimits()
            let server = try BridgeChannelTransport(underlying: wire, endpoint: endpoint(), limits: limits, source: "one") { _, _ in
                counter.increment(); throw A.Failure.unavailable
            }
            let command = BridgeCommand(cmd: name, identity: await identity(), payload: nil, cid: 0)
            do {
                if name == "response" { try await server.consumeResponse(command: command) }
                else { try await server.consumeCommand(command: command) }
                XCTFail("Accepted pre-auth \(name)")
            } catch {}
            XCTAssertEqual(counter.value, 0, name)
            XCTAssertEqual(limits.connectionCount, 0, name)
            XCTAssertTrue(wire.isClosed)
        }
    }

    func testRealTwoEndpointHandshakeAndOwnerProofThenPrincipalSwapAndRevocation() async throws {
        let owner = await identity()
        let serverOwner = await identity("server")
        let serverVault = MockIdentityVault()
        CellBase.defaultIdentityVault = serverVault
        let hasClientKey = await serverVault.identityExistInVault(owner)
        XCTAssertFalse(hasClientKey)
        let publisher = await GeneralCell(owner: owner.publicIdentitySnapshot())
        await publisher.addInterceptForGet(requester: owner, key: "secret") { _, _ in .string("protected-value") }
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver
        try await resolver.registerNamedEmitCell(name: "Protected", emitCell: publisher, scope: .template, identity: serverOwner)
        let pair = try await connected(owner: owner, serverOwner: serverOwner, publisher: publisher)
        await pair.client.sendCommand(command: .get, identity: owner, payload: .string("secret"))
        let response = try XCTUnwrap(pair.serverWire.snapshot.last { $0.command == .response && $0.payload == .string("protected-value") })
        XCTAssertEqual(response.payload, .string("protected-value"))
        XCTAssertTrue(pair.clientWire.snapshot.contains { if case .signature = $0.payload { return true }; return false })
        XCTAssertEqual(pair.serverGate.session.publicIdentity, try A.PublicIdentity(owner))
        let attacker = await identity()
        do {
            try await pair.serverGate.consumeCommand(command: .init(cmd: "get", identity: attacker, payload: .string("secret"), cid: 999))
            XCTFail("Principal swap must close the channel")
        } catch {}
        XCTAssertEqual(pair.serverGate.session.state, .closed)
        XCTAssertTrue(pair.serverWire.isClosed)
        await pair.clientGate.close()
    }

    func testRevokeDuringAwaitedPolicyDoesNotCreateBridge() async throws {
        let entered = expectation(description: "entered policy")
        let policy = ChannelPolicyBarrier()
        let counter = ChannelCounter()
        let owner = await identity(), endpoint = try endpoint()
        let clientWire = ChannelWire(), serverWire = ChannelWire()
        clientWire.peer = serverWire; serverWire.peer = clientWire
        let server = try BridgeChannelTransport(underlying: serverWire, endpoint: endpoint, limits: BridgeChannelLimits(), source: "one",
            recheckPolicy: { _ in entered.fulfill(); await policy.wait() }) { _, _ in
                counter.increment(); throw A.Failure.unavailable
            }
        let client = try BridgeChannelTransport(underlying: clientWire, endpoint: endpoint)
        let connect = Task { try await client.setup(URL(string: endpoint.audience)!, identity: owner) }
        await fulfillment(of: [entered], timeout: 2)
        server.session.revoke()
        await policy.resume()
        do { try await connect.value; XCTFail("Revoked verification installed") } catch {}
        XCTAssertEqual(counter.value, 0)
        await client.close(); await server.close()
    }

    func testConfiguredBridgeDirectDispatchCannotBypassPhysicalAuth() async throws {
        let owner = await identity(), wire = ChannelWire()
        let gate = try BridgeChannelTransport(underlying: wire, endpoint: endpoint())
        let bridge = try await BridgeBase(.init(owner: owner, transport: gate, connection: .inbound(publisherUuid: "Protected")))
        for name in ["ready", "get", "set", "admit", "feed", "description", "sign", "response"] {
            do { try await bridge.consumeCommand(command: .init(cmd: name, identity: owner, payload: nil, cid: 0)); XCTFail(name) } catch {}
        }
        do { try await bridge.consumeResponse(command: .init(cmd: "response", payload: nil, cid: 0)); XCTFail() } catch {}
        XCTAssertTrue(wire.snapshot.isEmpty)
        await gate.close()
    }

    func testMultiplexOpenAndLaterCommandsAreBoundToPhysicalPrincipal() async throws {
        let owner = await identity(), endpoint = try endpoint()
        let clientWire = ChannelWire(), serverWire = ChannelWire()
        clientWire.peer = serverWire; serverWire.peer = clientWire
        let server = try BridgeChannelTransport(underlying: serverWire, endpoint: endpoint, limits: BridgeChannelLimits(), source: "one") { transport, _ in
            BridgeMultiplexServerSession(physicalTransport: transport, bridgeOwner: owner.publicIdentitySnapshot())
        }
        let client = try BridgeChannelTransport(underlying: clientWire, endpoint: endpoint)
        let multiplex = BridgeMultiplexSession(physicalTransport: client)
        let channel = try multiplex.channelTransport(targetEndpoint: "Protected")
        let bridge = try await BridgeBase(.init(owner: owner, transport: channel, connection: .outbound))
        try await bridge.setTransport(channel, connection: .outbound)
        try await channel.setup(URL(string: endpoint.audience)!, identity: owner)
        try await bridge.ready()
        XCTAssertTrue(serverWire.snapshot.contains { $0.command == .channelOpened })
        let attacker = await identity()
        do {
            try await server.consumeCommand(command: .init(cmd: "openChannel", identity: attacker, payload: nil, cid: 999,
                protocolVersion: 2, channelID: UUID().uuidString, targetEndpoint: "Protected"))
            XCTFail("Multiplex accepted a different principal")
        } catch {}
        XCTAssertTrue(serverWire.isClosed)
        await client.close(); await server.close()
    }

    func testAuthenticatedTransportPreservesCellGetSetFeedScopePurposeAndRevocation() async throws {
        let serverVault = MockIdentityVault(), clientVault = MockIdentityVault()
        var owner = Identity(UUID().uuidString, displayName: "owner", identityVault: serverVault)
        var member = Identity(UUID().uuidString, displayName: "member", identityVault: clientVault)
        var stranger = Identity(UUID().uuidString, displayName: "stranger", identityVault: clientVault)
        await serverVault.addIdentity(identity: &owner, for: "owner")
        await clientVault.addIdentity(identity: &member, for: "member")
        await clientVault.addIdentity(identity: &stranger, for: "stranger")
        CellBase.defaultIdentityVault = serverVault
        let hasMemberKey = await serverVault.identityExistInVault(member)
        XCTAssertFalse(hasMemberKey)
        let cell = await GeneralCell(owner: owner)
        cell.agreementTemplate.grants = []
        cell.agreementTemplate.addGrant("r---", for: "allowed")
        cell.agreementTemplate.addGrant("-w--", for: "execute")
        await cell.addInterceptForGet(requester: owner, key: "allowed") { _, _ in .string("allowed-value") }
        await cell.addInterceptForGet(requester: owner, key: "private") { _, _ in .string("private-value") }
        // This probe Cell's action contract narrows the granted write to exactly
        // one purpose. The transport carries the request; it supplies no purpose authority.
        await cell.addInterceptForSet(requester: owner, key: "execute") { _, value, _ in
            guard value == .string("purpose://test.allowed") else { throw StreamState.denied }
            return .string("executed")
        }
        let agreement = Agreement(owner: owner)
        agreement.grants = []
        agreement.addGrant("r---", for: "allowed")
        agreement.addGrant("-w--", for: "execute")
        let admitted = await cell.addAgreement(agreement, for: member, authorizedBy: owner)
        XCTAssertEqual(admitted, .signed)
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver
        try await resolver.registerNamedEmitCell(name: "Protected", emitCell: cell, scope: .template, identity: owner)

        for (requester, readAllowed) in [(member, true), (stranger, false)] {
            let pair = try await connected(owner: requester, serverOwner: owner, publisher: cell)
            for (key, expected) in [("allowed", readAllowed), ("private", false)] {
                let local = (try? await cell.get(keypath: key, requester: requester)) != nil
                await pair.client.sendCommand(command: .get, identity: requester, payload: .string(key))
                let remote = pair.serverWire.snapshot.last { $0.command == .response }?.payload == .string("allowed-value")
                XCTAssertEqual(local, expected, key); XCTAssertEqual(remote, local, key)
            }
            for purpose in ["purpose://test.allowed", "purpose://prompt.unknown"] {
                let expected = requester === member && purpose == "purpose://test.allowed"
                let local = (try? await cell.set(keypath: "execute", value: .string(purpose), requester: requester)) != nil
                await pair.client.sendCommand(command: .set, identity: requester,
                    payload: .keyValue(.init(key: "execute", value: .string(purpose))))
                guard case let .setValueResponse(result) = pair.serverWire.snapshot.last(where: { $0.command == .response })?.payload else {
                    return XCTFail("Missing Cell set denial/result")
                }
                XCTAssertEqual(local, expected, purpose); XCTAssertEqual(result.state == .ok, local, purpose)
            }
            do { _ = try await cell.flow(requester: requester); XCTFail("No feed grant") } catch {}
            do { _ = try await pair.client.flow(requester: requester); XCTFail("Channel proof must not create feed rights") } catch {}
            await pair.clientGate.close(); await pair.serverGate.close()
        }
        await cell.removeMember(member: member, requester: owner)
        do { _ = try await cell.get(keypath: "allowed", requester: member); XCTFail("Revoked grant") } catch {}
        let revoked = try await connected(owner: member, serverOwner: owner, publisher: cell)
        await revoked.client.sendCommand(command: .get, identity: member, payload: .string("allowed"))
        XCTAssertNotEqual(revoked.serverWire.snapshot.last(where: { $0.command == .response })?.payload, .string("allowed-value"))
        await revoked.clientGate.close(); await revoked.serverGate.close()
    }

    private func connected(owner: Identity, serverOwner: Identity, publisher: GeneralCell) async throws ->
        (client: BridgeBase, clientGate: BridgeChannelTransport, serverGate: BridgeChannelTransport, clientWire: ChannelWire, serverWire: ChannelWire) {
        let clientWire = ChannelWire(), serverWire = ChannelWire(), endpoint = try endpoint()
        clientWire.peer = serverWire; serverWire.peer = clientWire
        let server = try BridgeChannelTransport(underlying: serverWire, endpoint: endpoint, limits: BridgeChannelLimits(), source: "one") { transport, _ in
            let bridge = try await BridgeBase(.init(owner: serverOwner, transport: transport,
                connection: .inbound(publisherUuid: "Protected"), inboundPublisherLookupIdentity: serverOwner))
            try await bridge.setTransport(transport, connection: .inbound(publisherUuid: "Protected"))
            return bridge
        }
        let clientGate = try BridgeChannelTransport(underlying: clientWire, endpoint: endpoint)
        let client = try await BridgeBase(.init(owner: owner, transport: clientGate, connection: .outbound,
            identityProofScopes: [.init(domain: publisher.identityDomain, resource: publisher.uuid)]))
        try await client.setTransport(clientGate, connection: .outbound)
        try await clientGate.setup(URL(string: endpoint.audience)!, identity: owner)
        return (client, clientGate, server, clientWire, serverWire)
    }
}

private final class ChannelCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
private actor ChannelPolicyBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}
private final class ChannelWire: BridgeTransportProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var delegate: BridgeDelegateProtocol?
    weak var peer: ChannelWire?
    private var commands: [BridgeCommand] = []
    private var closed = false
    var snapshot: [BridgeCommand] { lock.withLock { commands } }
    var isClosed: Bool { lock.withLock { closed } }
    static func new() -> BridgeTransportProtocol { ChannelWire() }
    func setDelegate(_ delegate: BridgeDelegateProtocol) { lock.withLock { self.delegate = delegate } }
    func setup(_ endpointURL: URL, identity: Identity) async throws {}
    func sendData(_ data: Data) async throws {
        guard !isClosed else { throw BridgeChannelAuthentication.Failure.closed }
        let command = try JSONDecoder().decode(BridgeCommand.self, from: data)
        lock.withLock { commands.append(command) }
        guard let peer, let destination = peer.lock.withLock({ peer.delegate }) else { throw BridgeChannelAuthentication.Failure.unavailable }
        try destination.validateInboundPayload(data)
        if command.command == .response { try await destination.consumeResponse(command: command) }
        else { try await destination.consumeCommand(command: command) }
    }
    func close() async { lock.withLock { closed = true } }
    func identityVault(for identity: Identity?) async -> IdentityVaultProtocol { BridgeIdentityVault() }
}
