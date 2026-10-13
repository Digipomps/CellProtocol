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

    func testAll29CommandsAndSeparateResponsesFailBeforeLookupOrCellInBothDirections() async throws {
        XCTAssertEqual(Command.allCases.count, 29)
        let owner = await identity(), resolver = MockCellResolver(), calls = ChannelCounter()
        CellBase.defaultCellResolver = resolver
        let cell = await SuspendedChannelReadCell(owner: owner)
        cell.read = { calls.increment(); return .string("value") }
        cell.write = { calls.increment(); return .string("value") }
        try await resolver.registerNamedEmitCell(name: "Protected", emitCell: cell, scope: .template, identity: owner)
        for serverSide in [true, false] {
            for name in Command.allCases.map(\.rawValue) + ["unknown", "separateResponse"] {
                let factory = ChannelCounter(), wire = ChannelWire(), limits = BridgeChannelLimits()
                let gate: BridgeChannelTransport
                if serverSide {
                    gate = try BridgeChannelTransport(underlying: wire, endpoint: endpoint(), limits: limits, source: "one") { transport, _ in
                        factory.increment()
                        let bridge = BridgeBase(owner: owner)
                        try await bridge.setTransport(transport, connection: .inbound(publisherUuid: "Protected"))
                        return bridge
                    }
                } else {
                    gate = try BridgeChannelTransport(underlying: wire, endpoint: endpoint())
                    let bridge = BridgeBase(owner: owner)
                    try await bridge.setTransport(gate, connection: .inbound(publisherUuid: "Protected"))
                }
                let command = BridgeCommand(cmd: name == "separateResponse" ? "response" : name, identity: owner, payload: .string("secret"), cid: 1)
                do {
                    if name == "separateResponse" { try await gate.consumeResponse(command: command) }
                    else { try await gate.consumeCommand(command: command) }
                    XCTFail("Accepted pre-auth \(name), server=\(serverSide)")
                } catch {}
                XCTAssertEqual(factory.value, 0, name)
                XCTAssertEqual(resolver.lookupCountSnapshot(), 0, name)
                XCTAssertEqual(calls.value, 0, name)
                XCTAssertEqual(limits.connectionCount, 0, name)
                XCTAssertTrue(wire.isClosed)
            }
        }
    }

    func testConcurrentGetDuringSuspendedProofPolicyHasNoLookupOrCellCall() async throws {
        let owner = await identity(), barrier = ChannelPolicyBarrier(), entered = expectation(description: "policy")
        let resolver = MockCellResolver(), calls = ChannelCounter(), factories = ChannelCounter()
        CellBase.defaultCellResolver = resolver
        let cell = await SuspendedChannelReadCell(owner: owner)
        cell.read = { calls.increment(); return .string("value") }
        try await resolver.registerNamedEmitCell(name: "Protected", emitCell: cell, scope: .template, identity: owner)
        let clientWire = ChannelWire(), serverWire = ChannelWire(), target = try endpoint()
        clientWire.peer = serverWire; serverWire.peer = clientWire
        let server = try BridgeChannelTransport(underlying: serverWire, endpoint: target, limits: BridgeChannelLimits(), source: "one",
            recheckPolicy: { _ in entered.fulfill(); await barrier.wait() }) { transport, _ in
                factories.increment()
                let bridge = BridgeBase(owner: owner)
                try await bridge.setTransport(transport, connection: .inbound(publisherUuid: "Protected"))
                return bridge
            }
        let client = try BridgeChannelTransport(underlying: clientWire, endpoint: target)
        let connecting = Task { try await client.setup(URL(string: target.audience)!, identity: owner) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(server.session.state, .verifying)
        do { try await server.consumeCommand(command: .init(cmd: "get", identity: owner, payload: .string("secret"), cid: 7)); XCTFail("Early get") } catch {}
        XCTAssertEqual(resolver.lookupCountSnapshot(), 0); XCTAssertEqual(calls.value, 0); XCTAssertEqual(factories.value, 0)
        await barrier.resume(); _ = try? await connecting.value
        XCTAssertEqual(factories.value, 0)
        await client.close(); await server.close()
    }

    func testRealTwoEndpointHandshakeAndOwnerProofThenPrincipalSwap() async throws {
        let owner = await identity()
        let serverOwner = await identity("server")
        let serverVault = SigningTrapVault()
        CellBase.defaultIdentityVault = serverVault
        let hasClientKey = await serverVault.identityExistInVault(owner)
        XCTAssertFalse(hasClientKey)
        let publisher = await GeneralCell(owner: owner.publicIdentitySnapshot())
        await publisher.addInterceptForGet(requester: owner, key: "secret") { _, _ in .string("protected-value") }
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver
        try await resolver.registerNamedEmitCell(name: "Protected", emitCell: publisher, scope: .template, identity: serverOwner)
        owner.properties = ["private-test": .string("must-not-cross-wire")]
        owner.homeVaultReference = "must-not-cross-vault-reference"
        let pair = try await connected(owner: owner, serverOwner: serverOwner, publisher: publisher)
        await pair.client.sendCommand(command: .get, identity: owner, payload: .string("secret"))
        let response = try XCTUnwrap(pair.serverWire.snapshot.last { $0.command == .response && $0.payload == .string("protected-value") })
        XCTAssertEqual(response.payload, .string("protected-value"))
        XCTAssertTrue(pair.clientWire.snapshot.contains { if case .signature = $0.payload { return true }; return false })
        XCTAssertEqual(pair.serverGate.session.publicIdentity, try A.PublicIdentity(owner))
        for command in pair.clientWire.snapshot {
            let wire = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
            XCTAssertFalse(wire.contains("must-not-cross"), "Normal commands must not export local identity metadata")
        }
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
        let sibling = try multiplex.channelTransport(targetEndpoint: "Protected")
        let siblingBridge = try await BridgeBase(.init(owner: owner, transport: sibling, connection: .outbound))
        try await siblingBridge.setTransport(sibling, connection: .outbound)
        try await sibling.setup(URL(string: endpoint.audience)!, identity: owner)
        await channel.close()
        XCTAssertFalse(bridge.hasAuthenticatedChannel)
        XCTAssertTrue(siblingBridge.hasAuthenticatedChannel)
        XCTAssertEqual(server.session.state, .authenticated)
        let attacker = await identity()
        do {
            try await server.consumeCommand(command: .init(cmd: "openChannel", identity: attacker, payload: nil, cid: 999,
                protocolVersion: 2, channelID: UUID().uuidString, targetEndpoint: "Protected"))
            XCTFail("Multiplex accepted a different principal")
        } catch {}
        XCTAssertTrue(serverWire.isClosed)
        await client.close(); await server.close()
    }

    func testClosingPendingMultiplexOpenPreservesAuthenticatedSibling() async throws {
        let owner = await identity(), endpoint = try endpoint()
        let entered = expectation(description: "pending logical factory")
        let barrier = ChannelPolicyBarrier()
        let clientWire = ChannelWire(), serverWire = ChannelWire()
        clientWire.peer = serverWire; serverWire.peer = clientWire
        let server = try BridgeChannelTransport(underlying: serverWire, endpoint: endpoint, limits: BridgeChannelLimits(), source: "one") { transport, _ in
            BridgeMultiplexServerSession(physicalTransport: transport) { target, _, channelTransport in
                if target == "Slow" { entered.fulfill(); await barrier.wait() }
                let bridge = try await BridgeBase(.init(owner: owner.publicIdentitySnapshot(), transport: channelTransport,
                    connection: .inbound(publisherUuid: target)))
                try await bridge.setTransport(channelTransport, connection: .inbound(publisherUuid: target))
                try bridge.activateAuthenticatedChannel()
                return bridge
            }
        }
        let client = try BridgeChannelTransport(underlying: clientWire, endpoint: endpoint)
        let multiplex = BridgeMultiplexSession(physicalTransport: client)
        let sibling = try multiplex.channelTransport(targetEndpoint: "Protected")
        let siblingBridge = try await BridgeBase(.init(owner: owner, transport: sibling, connection: .outbound))
        try await siblingBridge.setTransport(sibling, connection: .outbound)
        try await sibling.setup(URL(string: endpoint.audience)!, identity: owner)
        let pendingID = UUID().uuidString
        let opening = Task {
            try await server.consumeCommand(command: .init(cmd: "openChannel", identity: owner.publicIdentitySnapshot(), payload: nil,
                cid: 100, protocolVersion: 2, channelID: pendingID, targetEndpoint: "Slow"))
        }
        await fulfillment(of: [entered], timeout: 2)
        try await server.consumeCommand(command: .init(cmd: "closeChannel", identity: owner.publicIdentitySnapshot(), payload: nil,
            cid: 101, protocolVersion: 2, channelID: pendingID))
        await barrier.resume()
        try await opening.value
        XCTAssertEqual(server.session.state, .authenticated)
        XCTAssertTrue(siblingBridge.hasAuthenticatedChannel)
        XCTAssertFalse(serverWire.isClosed)
        XCTAssertFalse(serverWire.snapshot.contains { $0.channelID == pendingID }, "Cancelled opens must not emit stale acknowledgements")
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

    func testRenewalReprovesIdentityAndLateOldCloseCannotRetireNewGeneration() async throws {
        let owner = await identity(), publisher = await GeneralCell(owner: await identity("server"))
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        try await resolver.registerNamedEmitCell(name: "Protected", emitCell: publisher, scope: .template, identity: owner)
        let pair = try await connected(owner: owner, serverOwner: owner, publisher: publisher)
        let oldSession = pair.clientGate.session
        let nextClientWire = ChannelWire(), nextServerWire = ChannelWire()
        nextClientWire.peer = nextServerWire; nextServerWire.peer = nextClientWire
        let nextServer = try BridgeChannelTransport(underlying: nextServerWire, endpoint: endpoint(), limits: BridgeChannelLimits(), source: "next") { transport, _ in
            let bridge = try await BridgeBase(.init(owner: owner, transport: transport, connection: .inbound(publisherUuid: "Protected")))
            try await bridge.setTransport(transport, connection: .inbound(publisherUuid: "Protected"))
            return bridge
        }
        try await pair.client.renewAuthenticatedChannel(requester: owner, using: nextClientWire)
        await pair.client.channelDidClose(oldSession)
        XCTAssertTrue(pair.client.hasAuthenticatedChannel)
        XCTAssertEqual(oldSession.state, .closed)
        XCTAssertNotEqual(nextServer.session.generation, pair.serverGate.session.generation)
        XCTAssertEqual(nextClientWire.snapshot.map(\.cmd), ["channelAuthHello", "channelAuthProof"])
        XCTAssertFalse(nextClientWire.snapshot.contains { $0.command == .set || $0.command == .feed })
        await pair.client.transport?.close(); await pair.serverGate.close(); await nextServer.close()
    }

    func testTransportLossFailsPendingGetAndDoesNotReplayIt() async throws {
        let owner = await identity(), bridge = BridgeBase(owner: await identity())
        let physical = MockBridgeTransport()
        try await bridge.setTransport(physical, connection: .outbound)
        try await authenticateBridgeFixture(bridge, principal: owner)
        let pending = Task { try await bridge.get(keypath: "pending", requester: owner) }
        for _ in 0..<100 {
            if !physical.sentData.isEmpty { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(physical.sentData.count, 1)
        await bridge.pushError(errorMessage: "bridge_transport_closed", error: A.Failure.closed)
        do { _ = try await pending.value; XCTFail("Transport loss must fail pending read") } catch {}
        XCTAssertFalse(bridge.hasAuthenticatedChannel)
        XCTAssertEqual(physical.sentData.count, 1)
    }

    func testAuthenticatedFeedStopsAtChannelRevocation() async throws {
        let owner = await identity(), publisher = await GeneralCell(owner: owner.publicIdentitySnapshot())
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        try await resolver.registerNamedEmitCell(name: "Protected", emitCell: publisher, scope: .template, identity: owner)
        let pair = try await connected(owner: owner, serverOwner: owner, publisher: publisher)
        let before = expectation(description: "authenticated feed delivered")
        let values = ChannelCounter()
        let stream = try await pair.client.flow(requester: owner)
        let subscription = stream.sink(receiveCompletion: { _ in }, receiveValue: { event in
            if event.title == "before" { before.fulfill() }
            values.increment()
        })
        let emitterValue = await publisher.makeCellOwnedFlowEmitterForRuntimeBinding(requester: owner)
        let emit = try XCTUnwrap(emitterValue)
        emit(.init(title: "before", content: .string("before"), properties: nil))
        await fulfillment(of: [before], timeout: 2)
        pair.serverGate.session.revoke()
        await pair.serverGate.close()
        emit(.init(title: "after", content: .string("after"), properties: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(values.value, 1)
        XCTAssertFalse(pair.serverWire.snapshot.contains { if case let .flowElement(event) = $0.payload { return event.title == "after" }; return false })
        subscription.cancel(); await pair.clientGate.close()
    }

    func testSuspendedOldReadCannotDeliverItsResponseOnReplacementTransport() async throws {
        let owner = await identity(), barrier = ChannelPolicyBarrier()
        let entered = expectation(description: "old read entered cell")
        let cell = await SuspendedChannelReadCell(owner: owner)
        cell.read = { entered.fulfill(); await barrier.wait(); return .string("old-private-result") }
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        try await resolver.registerNamedEmitCell(name: "Protected", emitCell: cell, scope: .template, identity: owner)
        let oldWire = MockBridgeTransport(), newWire = MockBridgeTransport()
        let bridge = try await BridgeBase(.init(owner: owner, transport: oldWire, connection: .inbound(publisherUuid: "Protected")))
        try await bridge.setTransport(oldWire, connection: .inbound(publisherUuid: "Protected"))
        try await authenticateBridgeFixture(bridge, principal: owner)
        let read = Task { try await bridge.consumeCommand(command: .init(cmd: "get", identity: owner, payload: .string("secret"), cid: 1)) }
        await fulfillment(of: [entered], timeout: 2)
        try await bridge.setTransport(newWire, connection: .inbound(publisherUuid: "Protected"))
        try await authenticateBridgeFixture(bridge, principal: owner)
        await barrier.resume()
        try await read.value
        XCTAssertTrue(newWire.sentData.isEmpty)
        XCTAssertTrue(oldWire.sentData.isEmpty)
    }

    func testConcurrentFeedStartHasOneAdmissionAndCloseWinsSuspendedSubscription() async throws {
        let owner = await identity(), barrier = ChannelPolicyBarrier()
        let entered = expectation(description: "feed admission entered")
        let cell = await SuspendedChannelFeedCell(owner: owner)
        cell.beforeFlow = { entered.fulfill(); await barrier.wait() }
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        try await resolver.registerNamedEmitCell(name: "Protected", emitCell: cell, scope: .template, identity: owner)
        let wire = MockBridgeTransport()
        let bridge = try await BridgeBase(.init(owner: owner, transport: wire, connection: .inbound(publisherUuid: "Protected")))
        try await bridge.setTransport(wire, connection: .inbound(publisherUuid: "Protected"))
        try await authenticateBridgeFixture(bridge, principal: owner)
        let start = Task { try await bridge.consumeCommand(command: .init(cmd: "feed", identity: owner, payload: nil, cid: 1)) }
        await fulfillment(of: [entered], timeout: 2)
        do { try await bridge.consumeCommand(command: .init(cmd: "feed", identity: owner, payload: nil, cid: 2)); XCTFail("Duplicate pending admission") }
        catch { XCTAssertEqual(error as? A.Failure, .capacity) }
        await bridge.retireLogicalChannel()
        await barrier.resume()
        do { try await start.value; XCTFail("Closed logical channel must not install feed") } catch {}
        XCTAssertFalse(bridge.feedActive)
        XCTAssertTrue(wire.sentData.isEmpty)
    }

    func testRetiredMultiplexGetSetAndSignDenialCannotReachReusedChannelOrCID() async throws {
        for kind in ["get", "set", "sign"] {
            let owner = await identity(), barrier = ChannelPolicyBarrier()
            let entered = expectation(description: "suspended old \(kind)")
            let cell = await SuspendedChannelReadCell(owner: owner)
            cell.read = { entered.fulfill(); await barrier.wait(); return .string("old-result") }
            cell.write = { entered.fulfill(); await barrier.wait(); return .string("old-result") }
            let oldSink = CellBase.securityEventSink
            if kind == "sign" { CellBase.securityEventSink = SuspendedSigningEventSink(entered: entered, barrier: barrier) }
            defer { CellBase.securityEventSink = oldSink }
            let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
            try await resolver.registerNamedEmitCell(name: "Protected", emitCell: cell, scope: .template, identity: owner)
            let wire = MockBridgeTransport(), holder = BridgeBase(owner: owner)
            try await holder.setTransport(wire, connection: .outbound)
            try await authenticateBridgeFixture(holder, principal: owner)
            let mux = BridgeMultiplexServerSession(physicalTransport: try XCTUnwrap(holder.transport), bridgeOwner: owner)
            let id = UUID().uuidString, sibling = UUID().uuidString
            func command(_ name: String, _ channel: String, payload: ValueType? = nil) -> BridgeCommand {
                .init(cmd: name, identity: owner.publicIdentitySnapshot(), payload: payload, cid: 7,
                      protocolVersion: 2, channelID: channel, targetEndpoint: name == "openChannel" ? "Protected" : nil)
            }
            try await mux.consumeCommand(command: command("openChannel", id))
            try await mux.consumeCommand(command: command("openChannel", sibling))
            let payload: ValueType = kind == "sign" ? .signData(Data([1])) : kind == "set" ? .keyValue(.init(key: "secret", value: .string("old"))) : .string("secret")
            let old = Task { try await mux.consumeCommand(command: command(kind, id, payload: payload)) }
            await fulfillment(of: [entered], timeout: 2)
            try await mux.consumeCommand(command: command("closeChannel", id))
            try await mux.consumeCommand(command: command("openChannel", id))
            cell.read = { .string("fresh-result") }
            try await mux.consumeCommand(command: command("get", id, payload: .string("secret")))
            try await mux.consumeCommand(command: command("get", sibling, payload: .string("secret")))
            await barrier.resume(); try await old.value
            let responses = wire.sentData.compactMap { try? JSONDecoder().decode(BridgeCommand.self, from: $0) }.filter { $0.command == .response }
            XCTAssertEqual(responses.count, 2, kind)
            XCTAssertEqual(Set(responses.compactMap(\.channelID)), Set([id, sibling]), kind)
            XCTAssertTrue(responses.allSatisfy { $0.cid == 7 && $0.payload == .string("fresh-result") }, kind)
            await mux.close()
        }
    }

    func testSuspendedGetSetAndSignDenialStayOnOriginalPhysicalGenerationWithCIDCollision() async throws {
        for kind in ["get", "set", "sign"] {
            let owner = await identity(), barrier = ChannelPolicyBarrier()
            let entered = expectation(description: "old physical \(kind)")
            let cell = await SuspendedChannelReadCell(owner: owner)
            cell.read = { entered.fulfill(); await barrier.wait(); return .string("old-result") }
            cell.write = { entered.fulfill(); await barrier.wait(); return .string("old-result") }
            let oldSink = CellBase.securityEventSink
            if kind == "sign" { CellBase.securityEventSink = SuspendedSigningEventSink(entered: entered, barrier: barrier) }
            defer { CellBase.securityEventSink = oldSink }
            let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
            try await resolver.registerNamedEmitCell(name: "Protected", emitCell: cell, scope: .template, identity: owner)
            let oldWire = MockBridgeTransport(), newWire = MockBridgeTransport()
            let bridge = BridgeBase(owner: owner)
            try await bridge.setTransport(oldWire, connection: .inbound(publisherUuid: "Protected"))
            try await authenticateBridgeFixture(bridge, principal: owner)
            let payload: ValueType = kind == "sign" ? .signData(Data([1])) : kind == "set" ? .keyValue(.init(key: "secret", value: .string("old"))) : .string("secret")
            let old = Task { try await bridge.consumeCommand(command: .init(cmd: kind, identity: owner, payload: payload, cid: 7)) }
            await fulfillment(of: [entered], timeout: 2)
            try await bridge.setTransport(newWire, connection: .inbound(publisherUuid: "Protected"))
            try await authenticateBridgeFixture(bridge, principal: owner)
            cell.read = { .string("fresh-result") }
            try await bridge.consumeCommand(command: .init(cmd: "get", identity: owner, payload: .string("secret"), cid: 7))
            await barrier.resume(); try await old.value
            XCTAssertTrue(oldWire.sentData.isEmpty, kind)
            let responses = newWire.sentData.compactMap { try? JSONDecoder().decode(BridgeCommand.self, from: $0) }
            XCTAssertEqual(responses.count, 1, kind)
            XCTAssertEqual(responses.first?.payload, .string("fresh-result"), kind)
            await bridge.transport?.close()
        }
    }

    func testWireDescriptorVariantsCannotReachResolverOrCellAfterAuthenticatedPositiveControl() async throws {
        for variant in ["other-key-same-uuid", "other-uuid", "keyless", "nil", "server-owner"] {
            let owner = await identity(), serverOwner = await identity("server"), calls = ChannelCounter()
            let cell = await SuspendedChannelReadCell(owner: serverOwner)
            cell.read = { calls.increment(); return .string("value") }
            let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
            try await resolver.registerNamedEmitCell(name: "Protected", emitCell: cell, scope: .template, identity: serverOwner)
            let pair = try await connected(owner: owner, serverOwner: serverOwner, publisher: cell)
            await pair.client.sendCommand(command: .get, identity: owner, payload: .string("value"))
            XCTAssertEqual(calls.value, 1)
            let beforeLookup = resolver.lookupCountSnapshot()
            var presented: Identity? = owner.publicIdentitySnapshot()
            switch variant {
            case "other-key-same-uuid": presented = await identity()
            case "other-uuid":
                presented = Identity(UUID().uuidString, displayName: "", identityVault: nil)
                presented?.publicSecureKey = owner.publicSecureKey
            case "keyless": presented = Identity(owner.uuid, displayName: "", identityVault: nil)
            case "nil": presented = nil
            default: presented = serverOwner.publicIdentitySnapshot()
            }
            let command = BridgeCommand(cmd: "get", identity: presented, payload: .string("value"), cid: 77)
            do { try await pair.clientWire.sendData(JSONEncoder().encode(command)); XCTFail(variant) } catch {}
            XCTAssertEqual(resolver.lookupCountSnapshot(), beforeLookup, variant)
            XCTAssertEqual(calls.value, 1, variant)
            XCTAssertEqual(pair.serverGate.session.state, .closed, variant)
            await pair.clientGate.close()
        }
    }

    func testRawSignAfterAuthenticationIsDeniedWithoutLocalPermit() async throws {
        let owner = await identity(), cell = await GeneralCell(owner: owner.publicIdentitySnapshot())
        let pair = try await connected(owner: owner, serverOwner: owner, publisher: cell)
        let count = pair.clientWire.snapshot.count
        try await pair.serverWire.sendData(JSONEncoder().encode(BridgeCommand(cmd: "sign", identity: owner.publicIdentitySnapshot(), payload: .signData(Data([1, 2, 3])), cid: 55)))
        let replies = Array(pair.clientWire.snapshot.dropFirst(count))
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first?.cid, 55)
        guard case let .string(message) = replies.first?.payload else { return XCTFail("Missing denial") }
        XCTAssertTrue(message.hasPrefix("signing denied:"))
        XCTAssertFalse(replies.contains { if case .signature = $0.payload { return true }; return false })
        await pair.clientGate.close(); await pair.serverGate.close()
    }

    func testKeyRevocationDuringCellOrSendAwaitStopsAffectedClientAndPreservesOtherClient() async throws {
        for stage in ["cell", "send"] {
            let a = await identity("A"), b = await identity("B"), serverOwner = await identity("server")
            let cell = await SuspendedChannelReadCell(owner: serverOwner), barrier = ChannelPolicyBarrier()
            let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
            try await resolver.registerNamedEmitCell(name: "Protected", emitCell: cell, scope: .template, identity: serverOwner)
            cell.read = { .string("value") }
            let limits = BridgeChannelLimits()
            let first = try await connected(owner: a, serverOwner: serverOwner, publisher: cell, limits: limits)
            let other = try await connected(owner: b, serverOwner: serverOwner, publisher: cell, limits: limits)
            let entered = expectation(description: stage)
            if stage == "cell" { cell.read = { entered.fulfill(); await barrier.wait(); return .string("late") } }
            else { first.serverWire.beforeSend = { command in if command.command == .response { entered.fulfill(); await barrier.wait() } } }
            let pending = Task { await first.client.sendCommand(command: .get, identity: a, payload: .string("value")) }
            await fulfillment(of: [entered], timeout: 2)
            let began = ProcessInfo.processInfo.systemUptime
            limits.revoke(identity: try A.PublicIdentity(a), domain: "bridge")
            XCTAssertEqual(first.serverGate.session.state, .revoked)
            await first.serverGate.close()
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1, "Local revocation cutoff, not network propagation")
            cell.read = { .string("other-still-works") }
            await other.client.sendCommand(command: .get, identity: b, payload: .string("value"))
            XCTAssertEqual(other.serverWire.snapshot.last?.payload, .string("other-still-works"))
            await barrier.resume(); await pending.value
            XCTAssertFalse(first.serverWire.snapshot.contains { $0.command == .response })
            XCTAssertEqual(other.serverGate.session.state, .authenticated)
            await first.clientGate.close(); await other.clientGate.close(); await other.serverGate.close()
            XCTAssertEqual(limits.retainedConnectionCount, 0)
        }
    }

    func testLostWriteReplyDoesNotRetryMutationWhenClientReconnects() async throws {
        let owner = await identity(), count = ChannelCounter()
        let cell = await SuspendedChannelReadCell(owner: owner)
        cell.write = { count.increment(); return .string("committed") }
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        try await resolver.registerNamedEmitCell(name: "Protected", emitCell: cell, scope: .template, identity: owner)
        let pair = try await connected(owner: owner, serverOwner: owner, publisher: cell)
        pair.serverWire.beforeSend = { command in if command.command == .response { await pair.serverWire.close() } }
        await pair.client.sendCommand(command: .set, identity: owner, payload: .keyValue(.init(key: "value", value: .string("one"))))
        XCTAssertEqual(count.value, 1)
        XCTAssertFalse(pair.serverWire.snapshot.contains { $0.command == .response })
        await pair.clientGate.close(); await pair.serverGate.close()
        let next = try await connected(owner: owner, serverOwner: owner, publisher: cell)
        XCTAssertEqual(count.value, 1)
        XCTAssertFalse(next.clientWire.snapshot.contains { $0.command == .set })
        await next.clientGate.close(); await next.serverGate.close()
    }

    func testCellActionsEnforceXGrantAndRealAttachWithPermissionDomainExpiryAndPurposeParity() async throws {
        let vault = MockIdentityVault()
        let owner = await vault.identity(for: "server", makeNewIfNotFound: true)!
        let member = await vault.identity(for: "member", makeNewIfNotFound: true)!
        let cell = await ChannelActionCell(owner: owner), emitter = await GeneralCell(owner: owner)
        cell.emitter = emitter
        cell.agreementTemplate.grants = [Grant(keypath: "invoke", permission: "--x-"), Grant(keypath: "input", permission: "-w--")]
        emitter.agreementTemplate.grants = [Grant(keypath: "feed", permission: "r---")]
        let upstream = Agreement(owner: owner); upstream.grants = [Grant(keypath: "feed", permission: "r---")]
        let upstreamState = await emitter.addAgreement(upstream, for: member, authorizedBy: owner)
        XCTAssertEqual(upstreamState, .signed)
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        try await resolver.registerNamedEmitCell(name: "Protected", emitCell: cell, scope: .template, identity: owner)
        let originalDomain = cell.identityDomain
        let fixed = Date()
        cell.authorizationClock = { fixed }
        for (permission, key, allowed) in [("--x-", "invoke", true), ("-w--", "invoke", false), ("r---", "invoke", false), ("---s", "invoke", false), ("-w--", "input", true), ("--x-", "input", false)] {
            await cell.removeMember(member: member, requester: owner)
            // Grant only the tested permission; cell template constrains the issued contract.
            cell.agreementTemplate.grants = [Grant(keypath: key, permission: permission)]
            let request = Agreement(owner: owner); request.grants = [Grant(keypath: key, permission: permission)]; request.duration = 60
            let state = await cell.addAgreement(request, for: member, authorizedBy: owner)
            XCTAssertEqual(state, .signed)
            let pair = try await connected(owner: member, serverOwner: owner, publisher: cell, additionalProofScopes: [.init(domain: emitter.identityDomain, resource: emitter.uuid)])
            for scenario in ["valid", "wrong-key", "wrong-purpose", "wrong-domain", "expired", "revoked"] {
                cell.identityDomain = originalDomain
                cell.authorizationClock = { fixed }
                if scenario == "wrong-domain" { cell.identityDomain = "another-cell-domain" }
                if scenario == "expired" { cell.authorizationClock = { fixed.addingTimeInterval(61) } }
                if scenario == "revoked" { await cell.removeMember(member: member, requester: owner) }
                let action = key == "invoke" ? "invoke" : "attach"
                let path = scenario == "wrong-key" ? "ungranted" : action
                let value: ValueType = .string(scenario == "wrong-purpose" ? "purpose://prompt.unknown" : "purpose://test.allowed")
                let local = (try? await cell.set(keypath: path, value: value, requester: member)) != nil
                await pair.client.sendCommand(command: .set, identity: member, payload: .keyValue(.init(key: path, value: value)))
                guard case let .setValueResponse(result) = pair.serverWire.snapshot.last(where: { $0.command == .response })?.payload else { return XCTFail("Missing action result") }
                let expected = allowed && scenario == "valid"
                XCTAssertEqual(local, expected, "\(key) \(permission) \(scenario)")
                XCTAssertEqual(result.state == .ok, local, "\(key) \(permission) \(scenario)")
            }
            await pair.clientGate.close(); await pair.serverGate.close()
        }
        cell.identityDomain = originalDomain
        XCTAssertGreaterThan(cell.executions.value, 0, "The x-granted action actually executed")
        XCTAssertGreaterThan(cell.attachments.value, 0, "GeneralCell.attach actually returned connected")
    }

    func testSuspendedSignDenialCannotCrossActualDedicatedRenewal() async throws {
        let owner = await identity(), cell = await GeneralCell(owner: owner.publicIdentitySnapshot())
        let pair = try await connected(owner: owner, serverOwner: owner, publisher: cell)
        let oldSink = CellBase.securityEventSink; defer { CellBase.securityEventSink = oldSink }
        let entered = expectation(description: "old denial"), barrier = ChannelPolicyBarrier()
        CellBase.securityEventSink = SuspendedSigningEventSink(entered: entered, barrier: barrier)
        let old = Task { try await pair.serverWire.sendData(JSONEncoder().encode(BridgeCommand(cmd: "sign", identity: owner.publicIdentitySnapshot(), payload: .signData(Data([1])), cid: 1))) }
        await fulfillment(of: [entered], timeout: 2)
        let nextClient = ChannelWire(), nextServer = ChannelWire()
        nextClient.peer = nextServer; nextServer.peer = nextClient
        let serverGate = try BridgeChannelTransport(underlying: nextServer, endpoint: endpoint(), limits: BridgeChannelLimits(), source: "new") { transport, _ in
            let bridge = BridgeBase(owner: owner)
            try await bridge.setTransport(transport, connection: .inbound(publisherUuid: "Protected"))
            return bridge
        }
        try await pair.client.renewAuthenticatedChannel(requester: owner, using: nextClient)
        await barrier.resume(); _ = try? await old.value
        XCTAssertTrue(pair.client.hasAuthenticatedChannel)
        XCTAssertFalse(nextClient.snapshot.contains { $0.command == .response && $0.cid == 1 })
        XCTAssertEqual(nextClient.snapshot.map(\.cmd), ["channelAuthHello", "channelAuthProof"])
        await pair.client.transport?.close(); await pair.serverGate.close(); await serverGate.close()
    }

    private func connected(owner: Identity, serverOwner: Identity, publisher: GeneralCell, limits: BridgeChannelLimits = BridgeChannelLimits(), additionalProofScopes: [BridgeIdentityProofScope] = []) async throws ->
        (client: BridgeBase, clientGate: BridgeChannelTransport, serverGate: BridgeChannelTransport, clientWire: ChannelWire, serverWire: ChannelWire) {
        let clientWire = ChannelWire(), serverWire = ChannelWire(), endpoint = try endpoint()
        clientWire.peer = serverWire; serverWire.peer = clientWire
        let server = try BridgeChannelTransport(underlying: serverWire, endpoint: endpoint, limits: limits, source: "one") { transport, _ in
            let bridge = try await BridgeBase(.init(owner: serverOwner, transport: transport,
                connection: .inbound(publisherUuid: "Protected"), inboundPublisherLookupIdentity: serverOwner))
            try await bridge.setTransport(transport, connection: .inbound(publisherUuid: "Protected"))
            return bridge
        }
        let clientGate = try BridgeChannelTransport(underlying: clientWire, endpoint: endpoint)
        let client = try await BridgeBase(.init(owner: owner, transport: clientGate, connection: .outbound,
            identityProofScopes: [.init(domain: publisher.identityDomain, resource: publisher.uuid)] + additionalProofScopes))
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
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() { released = true; continuation?.resume(); continuation = nil }
}
private final class ChannelWire: BridgeTransportProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var delegate: BridgeDelegateProtocol?
    weak var peer: ChannelWire?
    var beforeSend: (@Sendable (BridgeCommand) async -> Void)?
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
        await beforeSend?(command)
        guard !isClosed else { throw BridgeChannelAuthentication.Failure.closed }
        lock.withLock { commands.append(command) }
        guard let peer, let destination = peer.lock.withLock({ peer.delegate }) else { throw BridgeChannelAuthentication.Failure.unavailable }
        try destination.validateInboundPayload(data)
        if command.command == .response { try await destination.consumeResponse(command: command) }
        else { try await destination.consumeCommand(command: command) }
    }
    func close() async { lock.withLock { closed = true } }
    func identityVault(for identity: Identity?) async -> IdentityVaultProtocol { BridgeIdentityVault() }
}

private final class SuspendedChannelReadCell: GeneralCell {
    var read: (() async -> ValueType)?
    var write: (() async -> ValueType)?
    override func set(keypath: String, value: ValueType, requester: Identity) async throws -> ValueType? { await write?() }
    override func get(keypath: String, requester: Identity) async throws -> ValueType {
        await read?() ?? .string("missing fixture")
    }
}

private final class SuspendedChannelFeedCell: GeneralCell {
    var beforeFlow: (() async -> Void)?
    override func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, Error> {
        await beforeFlow?()
        return getFeedPublisher()
    }
}

private struct SuspendedSigningEventSink: CellSecurityEventSink {
    let entered: XCTestExpectation
    let barrier: ChannelPolicyBarrier
    func record(_ event: CellSecurityEvent) async {
        guard event.kind == .vaultSignRejected else { return }
        entered.fulfill(); await barrier.wait()
    }
}

/// A real Cell action contract: invocation explicitly requires X. The attach
/// action calls GeneralCell.attach, which separately checks W at the label.
/// This does not claim that the legacy connectEmitter wire command is implemented.
private final class ChannelActionCell: GeneralCell {
    var emitter: GeneralCell?
    let executions = ChannelCounter(), attachments = ChannelCounter()
    override func set(keypath: String, value: ValueType, requester: Identity) async throws -> ValueType? {
        guard value == .string("purpose://test.allowed") else { throw StreamState.denied }
        switch keypath {
        case "invoke":
            guard await validateAccess("--x-", at: "invoke", for: requester) else { throw StreamState.denied }
            executions.increment(); return .string("executed")
        case "attach":
            guard let emitter else { throw StreamState.denied }
            let state = try await attach(emitter: emitter, label: "input", requester: requester)
            guard state == .connected else { throw StreamState.denied }
            attachments.increment(); return .string("attached")
        default: throw StreamState.denied
        }
    }
}
