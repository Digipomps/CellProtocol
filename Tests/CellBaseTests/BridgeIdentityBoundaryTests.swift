// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@_spi(HAVENRuntime) @testable import CellBase

final class BridgeIdentityBoundaryTests: XCTestCase {
    private final class PeerTransport: BridgeTransportProtocol {
        weak var delegate: BridgeDelegateProtocol?
        let peerVault: IdentityVaultProtocol?
        private let lock = NSLock()
        private var commands: [BridgeCommand] = []

        init(peerVault: IdentityVaultProtocol? = nil) { self.peerVault = peerVault }
        static func new() -> BridgeTransportProtocol { PeerTransport() }
        func setDelegate(_ delegate: BridgeDelegateProtocol) { self.delegate = delegate }
        func setup(_ endpointURL: URL, identity: Identity) async throws {}
        func identityVault(for identity: Identity?) async -> IdentityVaultProtocol {
            // Deliberately reproduce transport hydration with the server's vault.
            CellBase.defaultIdentityVault!
        }
        func snapshot() -> [BridgeCommand] { lock.withLock { commands } }

        func sendData(_ data: Data) async throws {
            let command = try JSONDecoder().decode(BridgeCommand.self, from: data)
            lock.withLock { commands.append(command) }
            guard command.command == .sign,
                  let identity = command.identity,
                  case let .signData(challenge) = command.payload else { return }
            let payload: ValueType
            if let peerVault,
               let signature = try? await peerVault.signMessageForIdentity(messageData: challenge, identity: identity) {
                payload = .signature(signature)
            } else {
                payload = .string("peer does not control this key")
            }
            try await delegate?.consumeResponse(command: BridgeCommand(
                cmd: Command.response.rawValue, payload: payload, cid: command.cid
            ))
        }
    }

    private final class PairedTransport: BridgeTransportProtocol {
        weak var peer: BridgeDelegateProtocol?
        private let lock = NSLock()
        private var commands: [BridgeCommand] = []
        static func new() -> BridgeTransportProtocol { PairedTransport() }
        func setDelegate(_ delegate: BridgeDelegateProtocol) {}
        func setup(_ endpointURL: URL, identity: Identity) async throws {}
        func identityVault(for identity: Identity?) async -> IdentityVaultProtocol { CellBase.defaultIdentityVault! }
        func snapshot() -> [BridgeCommand] { lock.withLock { commands } }
        func sendData(_ data: Data) async throws {
            let command = try JSONDecoder().decode(BridgeCommand.self, from: data)
            lock.withLock { commands.append(command) }
            command.identity?.identityVault = CellBase.defaultIdentityVault
            if command.command == .response {
                try await peer?.consumeResponse(command: command)
            } else {
                try await peer?.consumeCommand(command: command)
            }
        }
    }

    private var previousVault: IdentityVaultProtocol?
    private var previousResolver: CellResolverProtocol?
    private var previousDebug = false

    override func setUp() {
        previousVault = CellBase.defaultIdentityVault
        previousResolver = CellBase.defaultCellResolver
        previousDebug = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = false
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.defaultCellResolver = previousResolver
        CellBase.debugValidateAccessForEverything = previousDebug
    }

    func testCopiedPublicOwnerCannotUseServerVaultForProtectedRead() async throws {
        let result = try await readThroughBridge(peerControlsOwnerKey: false)
        XCTAssertNotEqual(result.response.payload, .string("protected-value"))
        XCTAssertGreaterThan(result.proofRequests, 0, "The peer must prove control; the server must not prove it for the peer")
    }

    func testPeerThatControlsOwnerKeyCanStillReadThroughBridge() async throws {
        let result = try await readThroughBridge(peerControlsOwnerKey: true)
        XCTAssertEqual(result.response.payload, .string("protected-value"))
        XCTAssertGreaterThan(result.proofRequests, 0)
    }

    func testTwoSerializedBridgeEndpointsReadWithClientProofThenCloseSigningAuthority() async throws {
        let clientVault = MockIdentityVault()
        let owner = await clientVault.identity(for: "client-owner", makeNewIfNotFound: true)!
        let serverVault = MockIdentityVault()
        CellBase.defaultIdentityVault = serverVault
        let serverOwner = await serverVault.identity(for: "server-route", makeNewIfNotFound: true)!
        let publisher = await GeneralCell(owner: owner.publicIdentitySnapshot())
        await publisher.addInterceptForGet(requester: owner, key: "secret") { _, _ in .string("protected-value") }
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver
        try await resolver.registerNamedEmitCell(name: "Protected", emitCell: publisher, scope: .template, identity: serverOwner)
        let clientTransport = PairedTransport()
        let serverTransport = PairedTransport()
        let client = try await BridgeBase(BridgeBase.Config(
            owner: owner, transport: clientTransport, connection: .outbound,
            identityProofScopes: [.init(domain: publisher.identityDomain, resource: publisher.uuid)]
        ))
        let server = try await BridgeBase(BridgeBase.Config(
            owner: serverOwner, transport: serverTransport, connection: .inbound(publisherUuid: "Protected"),
            inboundPublisherLookupIdentity: serverOwner
        ))
        try await client.setTransport(clientTransport, connection: .outbound)
        try await server.setTransport(serverTransport, connection: .inbound(publisherUuid: "Protected"))
        clientTransport.peer = server
        serverTransport.peer = client
        for endpoint in [client, server] {
            try await endpoint.consumeCommand(command: BridgeCommand(cmd: "ready", payload: nil, cid: 0))
        }
        await client.sendCommand(command: .get, identity: owner, payload: .string("secret"))
        let reply = try XCTUnwrap(serverTransport.snapshot().last(where: { $0.command == .response }))
        XCTAssertEqual(reply.payload, .string("protected-value"))
        XCTAssertTrue(clientTransport.snapshot().contains { if case .signature = $0.payload { return true }; return false })

        let unsolicitedProof = try IdentitySigningChallenge.signingData(
            for: owner, trustedIdentity: owner, domain: publisher.identityDomain, resource: publisher.uuid,
            action: "checkIdentityOrigin", audience: "GeneralCell", nonce: Data(repeating: 3, count: 32)
        )
        try await client.consumeCommand(command: BridgeCommand(
            cmd: "sign", identity: owner.publicIdentitySnapshot(), payload: .signData(unsolicitedProof), cid: 700
        ))
        let denial = try XCTUnwrap(clientTransport.snapshot().last)
        guard case let .string(reason) = denial.payload else { return XCTFail("Completed read must not leave signing authority open") }
        XCTAssertTrue(reason.contains("signing denied"))
    }

    func testRevokingOneBridgeFeedPreservesTheOtherBridgeFeed() async throws {
        let previousSink = CellBase.securityEventSink
        let securityEvents = InMemoryCellSecurityEventSink()
        CellBase.securityEventSink = securityEvents
        defer { CellBase.securityEventSink = previousSink }
        let serverVault = EphemeralIdentityVault()
        CellBase.defaultIdentityVault = serverVault
        var owner = Identity(UUID().uuidString, displayName: "server-owner", identityVault: serverVault)
        await serverVault.addIdentity(identity: &owner, for: "server-owner")
        let clientsVault = EphemeralIdentityVault()
        var first = Identity(UUID().uuidString, displayName: "first-client", identityVault: clientsVault)
        var second = Identity(UUID().uuidString, displayName: "second-client", identityVault: clientsVault)
        await clientsVault.addIdentity(identity: &first, for: "first-client")
        await clientsVault.addIdentity(identity: &second, for: "second-client")
        let cell = await GeneralCell(owner: owner)
        cell.agreementTemplate.addGrant("r---", for: "feed")
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver
        try await resolver.registerNamedEmitCell(name: "ProtectedFeed", emitCell: cell, scope: .template, identity: owner)
        let before = expectation(description: "both bridge clients receive authorized event")
        before.expectedFulfillmentCount = 2
        let after = expectation(description: "remaining bridge client receives new event")
        let valuesLock = NSLock()
        var firstValues: [String] = []
        var bridges: [(client: BridgeBase, server: BridgeBase)] = []
        var subscriptions: [AnyCancellable] = []
        for identity in [first, second] {
            let agreement = Agreement(owner: owner)
            agreement.addGrant("r---", for: "feed")
            let admission = await cell.addAgreement(agreement, for: identity, authorizedBy: owner)
            XCTAssertEqual(admission, .signed)
            let localDecision = await cell.authorizationDecision(requestedAccess: "r---", at: "feed", for: identity)
            XCTAssertTrue(localDecision.allowed, "Fresh local contract: \(localDecision.reasonCode)")
            let outgoing = PairedTransport()
            let incoming = PairedTransport()
            let client = try await BridgeBase(BridgeBase.Config(
                owner: identity, transport: outgoing, connection: .outbound,
                identityProofScopes: [.init(domain: cell.identityDomain, resource: cell.uuid)]
            ))
            let server = try await BridgeBase(BridgeBase.Config(
                owner: owner, transport: incoming, connection: .inbound(publisherUuid: "ProtectedFeed"),
                inboundPublisherLookupIdentity: owner
            ))
            try await client.setTransport(outgoing, connection: .outbound)
            try await server.setTransport(incoming, connection: .inbound(publisherUuid: "ProtectedFeed"))
            outgoing.peer = server
            incoming.peer = client
            for endpoint in [client, server] {
                try await endpoint.consumeCommand(command: BridgeCommand(cmd: "ready", payload: nil, cid: 0))
            }
            let stream: AnyPublisher<FlowElement, Error>
            do { stream = try await client.flow(requester: identity) }
            catch {
                let rejections = outgoing.snapshot().compactMap { command -> String? in
                    if case let .string(reason) = command.payload { return reason }
                    return nil
                }
                let incomingCommands = incoming.snapshot().map { $0.cmd }
                let reasons = await securityEvents.snapshot().map(\.reasonCode)
                XCTFail("Valid bridge feed was denied; peer replies: \(rejections), incoming commands: \(incomingCommands), reasons: \(reasons)")
                throw error
            }
            subscriptions.append(stream.sink(receiveCompletion: { _ in }, receiveValue: { element in
                if identity === first { valuesLock.withLock { firstValues.append(element.title) } }
                if element.title == "before" { before.fulfill() }
                if element.title == "after", identity === second { after.fulfill() }
            }))
            bridges.append((client, server))
        }
        let emitValue = await cell.makeCellOwnedFlowEmitterForRuntimeBinding(requester: owner)
        let emit = try XCTUnwrap(emitValue)
        emit(FlowElement(title: "before", content: .string("before"), properties: nil))
        await fulfillment(of: [before], timeout: 3)
        await cell.removeMember(member: first, requester: owner)
        XCTAssertFalse(bridges[0].server.feedActive)
        emit(FlowElement(title: "after", content: .string("after"), properties: nil))
        await fulfillment(of: [after], timeout: 3)
        XCTAssertEqual(valuesLock.withLock { firstValues }, ["before"])
        subscriptions.forEach { $0.cancel() }
    }

    private func readThroughBridge(peerControlsOwnerKey: Bool) async throws -> (response: BridgeCommand, proofRequests: Int) {
        let localVault = MockIdentityVault()
        CellBase.defaultIdentityVault = localVault
        let owner = await localVault.identity(for: "protected-owner", makeNewIfNotFound: true)!
        let publisher = await GeneralCell(owner: owner)
        await publisher.addInterceptForGet(requester: owner, key: "secret") { _, _ in .string("protected-value") }
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver
        try await resolver.registerNamedEmitCell(name: "Protected", emitCell: publisher, scope: .template, identity: owner)
        let transport = PeerTransport(peerVault: peerControlsOwnerKey ? localVault : nil)
        let bridge = try await BridgeBase(BridgeBase.Config(
            owner: owner, transport: transport, connection: .inbound(publisherUuid: "Protected"),
            inboundPublisherLookupIdentity: owner
        ))
        try await bridge.setTransport(transport, connection: .inbound(publisherUuid: "Protected"))
        try await bridge.consumeCommand(command: BridgeCommand(cmd: Command.ready.rawValue, payload: nil, cid: 0))

        let command = try JSONDecoder().decode(BridgeCommand.self, from: JSONEncoder().encode(BridgeCommand(
            cmd: Command.get.rawValue, identity: owner.publicIdentitySnapshot(), payload: .string("secret"), cid: 17
        )))
        command.identity?.identityVault = localVault
        try await bridge.consumeCommand(command: command)

        let commands = transport.snapshot()
        let response = try XCTUnwrap(commands.last(where: { $0.command == .response && $0.cid == 17 }))
        XCTAssertTrue(owner.identityVault is MockIdentityVault, "Sanitizing the wire identity must not mutate the local owner")
        return (response, commands.filter { $0.command == .sign }.count)
    }
}
