import Foundation
import MultipeerConnectivity
import XCTest
import Combine
@testable import CellApple
@testable import CellBase

final class ScannerPeerAuthenticationTests: XCTestCase {
    typealias A = BridgeChannelAuthentication
    private var previousResolver: CellResolverProtocol?
    override func setUp() { previousResolver = CellBase.defaultCellResolver }
    override func tearDown() { CellBase.defaultCellResolver = previousResolver }

    func testScannerMutualProofPrecedesBaseLookupAndRegistration() async throws {
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        let pair = try await ScannerPair()
        defer { pair.stop() }
        XCTAssertNil(pair.pa.bridge); XCTAssertNil(pair.pb.bridge)
        let tasks = pair.start()
        try await pair.deliverNext() // hello; responder signs, but has no initiator proof
        XCTAssertNil(pair.pa.bridge); XCTAssertNil(pair.pb.bridge)
        try await pair.deliverNext() // responder proof; initiator still waits for accepted
        XCTAssertNil(pair.pa.bridge); XCTAssertNil(pair.pb.bridge)
        XCTAssertEqual(resolver.lookupCountSnapshot(), 0)
        let aRegistered = await resolver.cellUUID(for: pair.a.mySessionUUID)
        XCTAssertNil(aRegistered)
        try await pair.finish(tasks)
        XCTAssertNotNil(pair.pa.bridge); XCTAssertNotNil(pair.pb.bridge)
        XCTAssertEqual(resolver.lookupCountSnapshot(), 0)
        XCTAssertEqual(pair.pa.channelSession?.publicIdentity, try A.PublicIdentity(pair.b.owner))
        XCTAssertEqual(pair.pb.channelSession?.publicIdentity, try A.PublicIdentity(pair.a.owner))
        XCTAssertFalse(pair.wire.history.contains { $0.command.cmd == "ready" })
    }

    func testScannerRejectsCommandBeforeProofAndReportsConsumerFailure() async throws {
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        let pair = try await ScannerPair(), observer = ScannerStatusObserver()
        pair.b.radarDelegate = observer; defer { pair.stop() }
        let command = BridgeCommand(cmd: "get", identity: pair.a.owner.publicIdentitySnapshot(), payload: .string("purposes"), cid: 1)
        do { try await pair.b.extractCommandFromData(A.encode(command), from: pair.aPeer); XCTFail() } catch {}
        XCTAssertEqual(resolver.lookupCountSnapshot(), 0)
        XCTAssertNil(pair.pb.bridge)
        XCTAssertTrue(observer.statuses.contains { $0.hasPrefix("bridgeFailed:") })
    }

    func testScannerForgedProofAndReplayedProofCannotCreateBase() async throws {
        let original = try await ScannerPair(); defer { original.stop() }
        let oldTasks = original.start(); try await original.finish(oldTasks)
        let oldProof = try XCTUnwrap(original.wire.history.first { $0.command.cmd == "channelAuthPeerProof" })
        for replay in [false, true] {
            let pair = try await ScannerPair(); defer { pair.stop() }
            let tasks = pair.start()
            try await pair.deliverNext(); try await pair.deliverNext()
            let pending = try await pair.next()
            XCTAssertEqual(pending.command.cmd, "channelAuthPeerProof")
            let current = try A.decode(A.Proof.self, from: Data(try XCTUnwrap(pending.command.payload?.stringValue()).utf8))
            let proof = replay ? oldProof.command : BridgeCommand(cmd: pending.command.cmd,
                payload: .string(String(decoding: try A.encode(A.Proof(sessionID: current.sessionID, generation: current.generation,
                    signature: Data(repeating: 0, count: 64))), as: UTF8.self)), cid: 0)
            do { try await pair.b.extractCommandFromData(A.encode(proof), from: pair.aPeer); XCTFail() } catch {}
            XCTAssertNil(pair.pb.bridge)
            await pair.pa.gate.close(); await pair.pb.gate.close()
            _ = try? await tasks.0.value; _ = try? await tasks.1.value
        }
    }

    func testScannerWrongPeerBindingAndRoleAreRejected() async throws {
        for field in ["initiator", "responder", "setupID", "role", "profile"] {
            let pair = try await ScannerPair(); defer { pair.stop() }
            let tasks = pair.start()
            let hello = try await pair.next()
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(hello.command.payload?.stringValue()).utf8)) as? [String: Any])
            if ["initiator", "responder", "setupID"].contains(field) {
                var endpoint = try XCTUnwrap(json["endpoint"] as? [String: Any]); endpoint[field] = UUID().uuidString; json["endpoint"] = endpoint
            } else { json[field] = field == "role" ? "responder" : A.profile }
            let bytes = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
            let changed = BridgeCommand(cmd: hello.command.cmd, payload: .string(String(decoding: bytes, as: UTF8.self)), cid: 0)
            do { try await pair.b.extractCommandFromData(A.encode(changed), from: pair.aPeer); XCTFail(field) } catch {}
            XCTAssertNil(pair.pb.bridge)
            await pair.pa.gate.close(); await pair.pb.gate.close()
            _ = try? await tasks.0.value; _ = try? await tasks.1.value
        }
    }

    func testScannerReconnectSamePeerIDRetiresOldTransportAndRejectsOldProof() async throws {
        let pair = try await ScannerPair(); defer { pair.stop() }
        let tasks = pair.start(); try await pair.finish(tasks)
        let old = pair.pa
        await pair.pa.gate.close(); await pair.pb.gate.close()
        let endpoint = try pair.a.makeInvitation(remoteUUID: pair.b.mySessionUUID)
        pair.b.receiveInvitation(from: pair.aPeer, endpoint: endpoint) { _, _ in }
        XCTAssertTrue(pair.b.respondToInvitation(remoteUUID: pair.a.mySessionUUID, accept: true))
        let fresh = try pair.a.prepareBridge(remoteUUID: pair.b.mySessionUUID, peerID: pair.bPeer)
        XCTAssertNotEqual(fresh.channelSession?.generation, old.channelSession?.generation)
        do { try await old.sendData(Data([1])); XCTFail("Old generation sent") } catch {}
        await old.close()
        XCTAssertTrue(try pair.a.prepareBridge(remoteUUID: pair.b.mySessionUUID, peerID: pair.bPeer) === fresh)
        let oldProof = try XCTUnwrap(pair.wire.history.first { $0.command.cmd == "channelAuthPeerChallenge" })
        do { try await pair.a.extractCommandFromData(A.encode(oldProof.command), from: pair.bPeer); XCTFail() } catch {}
        XCTAssertNil(fresh.bridge)
    }

    func testScannerReconnectSamePeerIDsCompletesFreshMutualProof() async throws {
        let pair = try await ScannerPair(); defer { pair.stop() }
        try await pair.finish(pair.start())
        await pair.pa.gate.close(); await pair.pb.gate.close()
        let endpoint = try pair.a.makeInvitation(remoteUUID: pair.b.mySessionUUID)
        pair.b.receiveInvitation(from: pair.aPeer, endpoint: endpoint) { _, _ in }
        XCTAssertTrue(pair.b.respondToInvitation(remoteUUID: pair.a.mySessionUUID, accept: true))
        let a = try pair.a.prepareBridge(remoteUUID: pair.b.mySessionUUID, peerID: pair.bPeer)
        let b = try pair.b.prepareBridge(remoteUUID: pair.a.mySessionUUID, peerID: pair.aPeer)
        let at = Task { try await a.gate.startPeer() }, bt = Task { try await b.gate.startPeer() }
        for _ in 0..<4 { try await pair.deliverNext() }
        try await at.value; try await bt.value
        XCTAssertNotEqual(a.channelSession?.generation, pair.pa.channelSession?.generation)
        XCTAssertNotEqual(b.channelSession?.generation, pair.pb.channelSession?.generation)
        XCTAssertEqual(a.channelSession?.publicIdentity, try A.PublicIdentity(pair.b.owner))
        XCTAssertEqual(b.channelSession?.publicIdentity, try A.PublicIdentity(pair.a.owner))
        await pair.pa.close(); await pair.pb.close()
        try a.channelSession?.check(); try b.channelSession?.check()
    }

    func testScannerRevocationClosesOnlyAffectedPeerAndReclaimsQuota() async throws {
        let limits = BridgeChannelLimits()
        let pair = try await ScannerPair(limits: limits), sibling = try await ScannerPair(limits: limits)
        defer { pair.stop(); sibling.stop() }
        try await pair.finish(pair.start()); try await sibling.finish(sibling.start())
        limits.revoke(identity: try A.PublicIdentity(pair.a.owner), domain: "nearby")
        XCTAssertThrowsError(try pair.pb.channelSession?.check())
        try sibling.pa.channelSession?.check(); try sibling.pb.channelSession?.check()
        await pair.pb.gate.close()
        for _ in 0..<100 where pair.b.bridgeDelegateCount != 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(pair.b.bridgeDelegateCount, 0)
    }

    func testScannerQuotaPlusOneDoesNotCreateTransportOrBase() async throws {
        var config = BridgeChannelLimits.Configuration(); config.maximumConnections = 2
        let limits = BridgeChannelLimits(configuration: config), pair = try await ScannerPair(limits: limits)
        defer { pair.stop() }
        try await pair.finish(pair.start())
        do { let extra = try await ScannerPair(limits: limits); extra.stop(); XCTFail() }
        catch { XCTAssertEqual(error as? A.Failure, .capacity) }
        try pair.pa.channelSession?.check(); try pair.pb.channelSession?.check()
        await pair.pa.gate.close(); await pair.pb.gate.close()
        XCTAssertEqual(limits.retainedConnectionCount, 0)
        let recovered = try await ScannerPair(limits: limits); recovered.stop()
    }

    func testActualScannerSetupLobbyDescriptionAttachAndFeedForEitherInviter() async throws {
        for inviter in ["first-device", "second-device"] {
            let pair = try await ScannerPair(reverse: inviter == "second-device"); defer { pair.stop() }
            let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
            let lobby = await ScannerObservedLobby(owner: pair.a.owner)
            lobby.agreementTemplate.ensureGrant("r---", for: "feed")
            let agreement = Agreement(owner: pair.a.owner)
            agreement.grants = [Grant(keypath: "feed", permission: "r---"), Grant(keypath: "purposes", permission: "r---")]
            let granted = await lobby.addAgreement(agreement, for: pair.b.owner, authorizedBy: pair.a.owner)
            XCTAssertEqual(granted, .signed)
            let localScanner = await GeneralCell(owner: pair.a.owner), remoteScanner = await GeneralCell(owner: pair.b.owner)
            try await resolver.registerNamedEmitCell(name: "Lobby", emitCell: lobby, scope: .template, identity: pair.a.owner)
            try await resolver.registerNamedEmitCell(name: "EntityScanner", emitCell: localScanner, scope: .template, identity: pair.a.owner)
            try await resolver.registerNamedEmitCell(name: "ConnectRadar", emitCell: remoteScanner, scope: .template, identity: pair.b.owner)
            let localFlow = expectation(description: "local lobby \(inviter)"), remoteFlow = expectation(description: "remote lobby \(inviter)")
            let marker = "lobby-\(inviter)-\(UUID())"
            let localSubscription = localScanner.getFeedPublisher().sink(receiveCompletion: { _ in }, receiveValue: { if case let .string(value) = $0.content, value == marker { localFlow.fulfill() } })
            let remoteSubscription = remoteScanner.getFeedPublisher().sink(receiveCompletion: { _ in }, receiveValue: { if case let .string(value) = $0.content, value == marker { remoteFlow.fulfill() } })
            let pump = pair.pump(); defer { pump.cancel(); localSubscription.cancel(); remoteSubscription.cancel() }
            async let aSetup: Void = pair.a.setupBridge(remoteUUID: pair.b.mySessionUUID, peerID: pair.bPeer)
            async let bSetup: Void = pair.b.setupBridge(remoteUUID: pair.a.mySessionUUID, peerID: pair.aPeer)
            try await aSetup; try await bSetup
            XCTAssertEqual(pair.pb.bridge?.uuid, lobby.uuid, "Description installs actual Lobby UUID")
            let aRegistered = await resolver.cellUUID(for: pair.a.mySessionUUID), bRegistered = await resolver.cellUUID(for: pair.b.mySessionUUID)
            XCTAssertNotNil(aRegistered); XCTAssertNotNil(bRegistered)
            for _ in 0..<1000 where lobby.subscriptionCount < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertEqual(lobby.subscriptionCount, 2, "Both real feed subscriptions are installed before emission")
            lobby.pushFlowElement(FlowElement(title: "lobby", content: .string(marker), properties: .init(type: .content, contentType: .string)), requester: pair.a.owner)
            await fulfillment(of: [localFlow, remoteFlow], timeout: 3)
            XCTAssertTrue(pair.wire.history.contains { $0.command.cmd == "description" })
            XCTAssertTrue(pair.wire.history.contains { $0.command.cmd == "admit" })
            XCTAssertTrue(pair.wire.history.contains { $0.command.cmd == "feed" })
            XCTAssertTrue(pair.wire.errors.isEmpty, "\(pair.wire.errors)")
        }
    }

    func testScannerPeerProofDoesNotOverrideLobbyOwnerApproval() async throws {
        let pair = try await ScannerPair(), observer = ScannerStatusObserver()
        defer { pair.stop() }
        pair.b.radarDelegate = observer
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        let lobby = await LobbyCell(owner: pair.a.owner)
        let local = await GeneralCell(owner: pair.a.owner), remote = await GeneralCell(owner: pair.b.owner)
        for (name, cell) in [("Lobby", lobby as GeneralCell), ("EntityScanner", local), ("ConnectRadar", remote)] {
            try await resolver.registerNamedEmitCell(name: name, emitCell: cell, scope: .template, identity: cell.owner)
        }
        let pump = pair.pump(); defer { pump.cancel() }
        let server = Task { try await pair.a.setupBridge(remoteUUID: pair.b.mySessionUUID, peerID: pair.bPeer) }
        do {
            try await pair.b.setupBridge(remoteUUID: pair.a.mySessionUUID, peerID: pair.aPeer)
            XCTFail("Transport proof granted unapproved Lobby access")
        } catch { XCTAssertEqual(error as? StreamState, .denied) }
        _ = try? await server.value
        XCTAssertTrue(pair.wire.history.contains { $0.command.cmd == "channelAuthPeerAccepted" })
        XCTAssertTrue(pair.wire.history.contains { $0.command.cmd == "agreement" })
        XCTAssertTrue(observer.statuses.contains { $0 == "bridgeFailed:denied" })
    }

    func testScannerDisconnectRetainsFeedQuotaUntilNoncooperativeWorkReturns() async throws {
        var configuration = BridgeChannelLimits.Configuration(); configuration.maximumFeeds = 1
        let limits = BridgeChannelLimits(configuration: configuration)
        let pair = try await ScannerPair(limits: limits), spare = try await ScannerPair(limits: limits)
        defer { pair.stop(); spare.stop() }
        try await pair.finish(pair.start()); try await spare.finish(spare.start())
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        let cell = await ScannerObservedLobby(owner: pair.a.owner), barrier = ScannerWorkBarrier()
        let entered = expectation(description: "remote flow entered")
        cell.beforeFlow = { entered.fulfill(); await barrier.wait(); try Task.checkCancellation() }
        try await resolver.registerNamedEmitCell(name: "Lobby", emitCell: cell, scope: .template, identity: pair.a.owner)
        let command = BridgeCommand(cmd: "feed", identity: pair.b.owner.publicIdentitySnapshot(), payload: nil, cid: 3, peerGeneration: pair.pb.gate.session.generation)
        let work = Task { try await pair.a.extractCommandFromData(A.encode(command), from: pair.bPeer) }
        await fulfillment(of: [entered], timeout: 2)
        await pair.pa.gate.close()
        XCTAssertEqual(limits.retainedConnectionCount, 4)
        XCTAssertThrowsError(try BridgeChannelResourceLease(session: spare.pa.gate.session, resource: .feed))
        XCTAssertGreaterThan(limits.outstandingWorkCount, 0)
        await barrier.resume()
        do { try await work.value; XCTFail("Disconnected work succeeded") } catch {}
        XCTAssertEqual(limits.retainedConnectionCount, 3)
        let recovered = try BridgeChannelResourceLease(session: spare.pa.gate.session, resource: .feed)
        recovered.release()
        XCTAssertEqual(limits.outstandingWorkCount, 0)
    }

    func testThirdPeerDiscoveryCollisionCannotStealAuthenticatedRouteOrGate() async throws {
        let pair = try await ScannerPair(); defer { pair.stop() }
        try await pair.finish(pair.start()); try await pair.addThirdPeer()
        let c = try XCTUnwrap(pair.c), ac = try XCTUnwrap(pair.ac), pc = try XCTUnwrap(pair.pc)
        let observer = ScannerStatusObserver(); pair.b.radarDelegate = observer
        let browser = MCNearbyServiceBrowser(peer: pair.aPeer, serviceType: "haven-radar")
        pair.a.browser(browser, foundPeer: pair.cPeer, withDiscoveryInfo: ["uuid": pair.b.mySessionUUID])
        XCTAssertEqual(pair.a.foundPeersDict[pair.b.mySessionUUID], pair.bPeer)
        XCTAssertEqual(pair.a.reversedFoundPeersDict[pair.cPeer], c.mySessionUUID)
        XCTAssertThrowsError(try pair.a.prepareBridge(remoteUUID: pair.b.mySessionUUID, peerID: pair.cPeer))
        XCTAssertTrue(try pair.a.capturePeerTransport(session: pair.a.mcSession, peerID: pair.bPeer) === pair.pa)
        XCTAssertTrue(try pair.a.capturePeerTransport(session: pair.a.mcSession, peerID: pair.cPeer) === ac)
        XCTAssertThrowsError(try pair.a.capturePeerTransport(session: MCSession(peer: pair.aPeer), peerID: pair.bPeer))

        // Keep a real B request pending in Base. C knows B's public descriptor,
        // generation and cid, but its physical callback must never reach B's gate.
        let bridge = try XCTUnwrap(pair.pa.bridge)
        await bridge.sendCommand(command: .get, identity: pair.a.owner, payload: .string("private"))
        let pending = try await pair.next()
        let forged = BridgeCommand(cmd: "response", payload: .string("from-c"), cid: pending.command.cid,
                                   peerGeneration: pair.pb.gate.session.generation)
        try await pc.sendData(A.encode(forged))
        try await pair.deliverNext()
        let stillPending = await bridge.auditor.loadBridgeCommandForCommandId(pending.command.cid)
        XCTAssertNotNil(stillPending, "C's response must not consume B's pending cid")

        let marker = FlowElement(title: "only-b", content: .string("b-data"), properties: .init(type: .event, contentType: .string))
        try await pair.a.sendScannerFlowElement(marker, remoteUUID: pair.b.mySessionUUID)
        let frame = try await pair.next()
        XCTAssertEqual(frame.to, pair.bPeer); XCTAssertNotEqual(frame.to, pair.cPeer)
        try await pair.deliver(frame)
        XCTAssertEqual(observer.flows.map(\.title), ["only-b"])
        // Losing discovery and a repeated collision also cannot redirect a live binding.
        pair.a.browser(browser, lostPeer: pair.bPeer)
        pair.a.browser(browser, foundPeer: pair.cPeer, withDiscoveryInfo: ["uuid": pair.b.mySessionUUID])
        try await pair.a.sendScannerFlowElement(marker, remoteUUID: pair.b.mySessionUUID)
        let afterLoss = try await pair.next(); XCTAssertEqual(afterLoss.to, pair.bPeer)
        try pair.pa.gate.session.check(); try ac.gate.session.check()
    }

    func testOldCommandsAndResponsesCannotCrossReconnectWithCollidingCID() async throws {
        let pair = try await ScannerPair(); defer { pair.stop() }
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        let lobby = await LobbyCell(owner: pair.a.owner)
        try await resolver.registerNamedEmitCell(name: "Lobby", emitCell: lobby, scope: .template, identity: pair.a.owner)
        try await pair.finish(pair.start()); try await pair.addThirdPeer()
        await pair.pb.bridge!.sendCommand(command: .description, identity: pair.b.owner, payload: nil)
        let oldCommand = try await pair.next(), captured = try pair.receiver(oldCommand)
        try await pair.deliver(oldCommand)
        let oldResponse = try await pair.next(), capturedResponse = try pair.receiver(oldResponse)
        XCTAssertEqual(oldResponse.command.cmd, "response")
        await pair.pa.gate.close(); await pair.pb.gate.close()
        let fresh = try pair.prepareReconnect()
        // Bytes still in the physical wire during pending auth are stale too.
        try await pair.deliver(oldCommand); try await pair.deliver(oldResponse)
        try await pair.authenticateTransports(fresh.0, fresh.1)
        await fresh.1.bridge!.sendCommand(command: .description, identity: pair.b.owner, payload: nil)
        let newCommand = try await pair.next()
        XCTAssertEqual(oldCommand.command.cid, newCommand.command.cid, "Exercise actual Base cid reuse")
        let before = resolver.lookupCountSnapshot()
        try await pair.deliver(oldCommand); try await pair.deliver(oldResponse)
        XCTAssertEqual(resolver.lookupCountSnapshot(), before, "Old command must not resolve a Cell")
        let pending = await fresh.1.bridge!.auditor.loadBridgeCommandForCommandId(newCommand.command.cid)
        XCTAssertNotNil(pending, "Old response must not consume the new generation's pending cid")
        // Callbacks captured before Task dispatch never reselect the new gate,
        // even when their payload is malformed and close arrives late.
        do { try await captured.receiveData(Data([0xff])); XCTFail() } catch {}
        do { try await capturedResponse.receiveData(oldResponse.data); XCTFail() } catch {}
        pair.a.peerDisconnected(captured)
        await captured.close(); await capturedResponse.close()
        try await pair.deliver(newCommand); try await pair.deliverNext()
        let finished = await fresh.1.bridge!.auditor.loadBridgeCommandForCommandId(newCommand.command.cid)
        XCTAssertNil(finished)
        XCTAssertEqual(fresh.1.bridge?.uuid, lobby.uuid)
        try fresh.0.gate.session.check(); try fresh.1.gate.session.check()
        let sibling = try XCTUnwrap(pair.c)
        let marker = FlowElement(title: "sibling", content: .string("ok"), properties: .init(type: .event, contentType: .string))
        try await pair.a.sendScannerFlowElement(marker, remoteUUID: sibling.mySessionUUID)
        let frame = try await pair.next(); XCTAssertEqual(frame.to, pair.cPeer)
        try await pair.deliver(frame); try pair.ac!.gate.session.check(); try pair.pc!.gate.session.check()
    }

    func testLateReceiveFailureAndDisconnectLeaveReconnectAndSiblingAlive() async throws {
        let pair = try await ScannerPair(); defer { pair.stop() }
        try await pair.finish(pair.start()); try await pair.addThirdPeer()
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        let lobby = await ScannerObservedLobby(owner: pair.a.owner), barrier = ScannerWorkBarrier()
        let entered = expectation(description: "old receive suspended in cell")
        lobby.beforeFlow = { entered.fulfill(); await barrier.wait(); throw A.Failure.malformed }
        try await resolver.registerNamedEmitCell(name: "Lobby", emitCell: lobby, scope: .template, identity: pair.a.owner)
        let oldCommand = BridgeCommand(cmd: "feed", identity: pair.b.owner.publicIdentitySnapshot(), payload: nil, cid: 7)
        try await pair.pb.gate.sendData(A.encode(oldCommand))
        let frame = try await pair.next(), captured = try pair.receiver(frame)
        let work = Task { try await captured.receiveData(frame.data) }
        await fulfillment(of: [entered], timeout: 2)
        await pair.pa.gate.close(); await pair.pb.gate.close()
        let fresh = try pair.prepareReconnect()
        try await pair.authenticateTransports(fresh.0, fresh.1)
        await barrier.resume()
        do { try await work.value; XCTFail("old work unexpectedly succeeded") } catch {}
        pair.a.peerDisconnected(captured); await captured.close()
        let marker = FlowElement(title: "alive", content: .string("ok"), properties: .init(type: .event, contentType: .string))
        let bObserver = ScannerStatusObserver(), cObserver = ScannerStatusObserver()
        pair.b.radarDelegate = bObserver; pair.c!.radarDelegate = cObserver
        try await pair.a.sendScannerFlowElement(marker, remoteUUID: pair.b.mySessionUUID)
        try await pair.deliverNext()
        try await pair.a.sendScannerFlowElement(marker, remoteUUID: pair.c!.mySessionUUID)
        try await pair.deliverNext()
        XCTAssertEqual(bObserver.flows.count, 1); XCTAssertEqual(cObserver.flows.count, 1)
        try fresh.0.gate.session.check(); try fresh.1.gate.session.check()
        try pair.ac!.gate.session.check(); try pair.pc!.gate.session.check()
    }

    func testDiscoveryTokenSkipsPendingThenRevokedPeerWithoutBreakingHandshake() async throws {
        let pair = try await ScannerPair(); defer { pair.stop() }
        try await pair.finish(pair.start()); try await pair.addThirdPeer(authenticate: false)
        let c = try XCTUnwrap(pair.c), ac = try XCTUnwrap(pair.ac), pc = try XCTUnwrap(pair.pc)
        let before = pair.wire.history.count
        let sent = try await pair.a.shareDiscoveryTokenData(Data("opaque-ni-archive".utf8))
        XCTAssertEqual(sent, 1)
        let selected = Array(pair.wire.history.dropFirst(before))
        XCTAssertEqual(selected.count, 1); XCTAssertEqual(selected.first?.to, pair.bPeer)
        XCTAssertEqual(selected.first?.command.cid, -1)
        XCTAssertEqual(selected.first?.command.peerGeneration, pair.pa.gate.session.generation)
        try await pair.deliverNext()
        XCTAssertEqual(ac.gate.session.state, .unauthenticated)
        XCTAssertEqual(pc.gate.session.state, .unauthenticated)
        try await pair.authenticateTransports(ac, pc) // pending handshake survived the broadcast
        pair.a.channelLimits.revoke(identity: try A.PublicIdentity(c.owner), domain: "nearby")
        let revokedStart = pair.wire.history.count
        let afterRevoke = try await pair.a.shareDiscoveryTokenData(Data("second-token".utf8))
        XCTAssertEqual(afterRevoke, 1)
        XCTAssertEqual(Array(pair.wire.history.dropFirst(revokedStart)).map(\.to), [pair.bPeer])
        try await pair.deliverNext(); try pair.pa.gate.session.check(); try pair.pb.gate.session.check()
    }

    func testDiscoveryTokenUsesExistingSendByteQuota() async throws {
        var configuration = BridgeChannelLimits.Configuration()
        configuration.maximumPendingSendBytesPerConnection = 16 * 1024
        let pair = try await ScannerPair(limits: BridgeChannelLimits(configuration: configuration)); defer { pair.stop() }
        try await pair.finish(pair.start())
        let before = pair.wire.history.count
        let sent = try await pair.a.shareDiscoveryTokenData(Data(repeating: 7, count: 20 * 1024))
        XCTAssertEqual(sent, 0); XCTAssertEqual(pair.wire.history.count, before)
        XCTAssertThrowsError(try pair.pa.gate.session.check())
    }

    func testScannerCopiedPublicKeyAlwaysGetsProxyIncludingWithoutDelegate() async throws {
        let pair = try await ScannerPair(); defer { pair.stop() }
        let previous = CellBase.defaultIdentityVault; CellBase.defaultIdentityVault = pair.a.owner.identityVault
        defer { CellBase.defaultIdentityVault = previous }
        for delegate in [nil, BridgeBase(owner: pair.a.owner)] {
            let copy = pair.a.owner.publicIdentitySnapshot()
            let vault = await pair.a.identityVault(for: copy, bridgeDelegate: delegate)
            XCTAssertTrue(vault is BridgeIdentityVault)
            let exists = await vault.identityExistInVault(copy); XCTAssertFalse(exists)
        }
        let copied = pair.a.owner.publicIdentitySnapshot(); copied.identityVault = nil
        let unsigned = try await ScannerPair(ownerA: copied); defer { unsigned.stop() }
        let tasks = unsigned.start()
        try await unsigned.deliverNext()
        do { try await unsigned.deliverNext(); XCTFail("Copied key signed") } catch {}
        XCTAssertNil(unsigned.pa.bridge); XCTAssertNil(unsigned.pb.bridge)
        await unsigned.pa.gate.close(); await unsigned.pb.gate.close()
        _ = try? await tasks.0.value; _ = try? await tasks.1.value
    }
}

private final class ScannerPair {
    let a: ScannerService, b: ScannerService
    let aPeer = MCPeerID(displayName: "test-a"), bPeer = MCPeerID(displayName: "test-b")
    let pa: ScannerPeerTransport, pb: ScannerPeerTransport
    let wire = ScannerControlledWire()
    var c: ScannerService?
    let cPeer = MCPeerID(displayName: "test-c")
    var ac: ScannerPeerTransport?, pc: ScannerPeerTransport?
    init(limits: BridgeChannelLimits = BridgeChannelLimits(), ownerA: Identity? = nil, reverse: Bool = false) async throws {
        let resolvedOwnerA: Identity
        if let ownerA { resolvedOwnerA = ownerA }
        else { resolvedOwnerA = await Self.owner() }
        let ownerB = await Self.owner()
        let suffix = UUID().uuidString
        a = ScannerService(owner: resolvedOwnerA, sessionUUID: (reverse ? "second-" : "first-") + suffix)
        b = ScannerService(owner: ownerB, sessionUUID: (reverse ? "first-" : "second-") + suffix)
        a.channelLimits = limits; b.channelLimits = limits
        a.foundPeersDict[b.mySessionUUID] = bPeer; a.reversedFoundPeersDict[bPeer] = b.mySessionUUID
        b.foundPeersDict[a.mySessionUUID] = aPeer; b.reversedFoundPeersDict[aPeer] = a.mySessionUUID
        let endpoint = try a.makeInvitation(remoteUUID: b.mySessionUUID)
        b.receiveInvitation(from: aPeer, endpoint: endpoint) { _, _ in }
        _ = b.respondToInvitation(remoteUUID: a.mySessionUUID, accept: true)
        pa = try a.prepareBridge(remoteUUID: b.mySessionUUID, peerID: bPeer)
        pb = try b.prepareBridge(remoteUUID: a.mySessionUUID, peerID: aPeer)
        a.peerSend = { [wire, aPeer, weak a] data, peer, session in
            XCTAssertTrue(session === a?.mcSession)
            try wire.append(data, from: aPeer, to: peer)
        }
        b.peerSend = { [wire, bPeer, weak b] data, peer, session in
            XCTAssertTrue(session === b?.mcSession)
            try wire.append(data, from: bPeer, to: peer)
        }
    }
    static func owner() async -> Identity {
        let vault = MockIdentityVault()
        var identity = Identity(UUID().uuidString, displayName: "test", identityVault: vault)
        await vault.addIdentity(identity: &identity, for: UUID().uuidString)
        return identity
    }
    func addThirdPeer(authenticate: Bool = true) async throws {
        let c = ScannerService(owner: await Self.owner(), sessionUUID: "third-" + UUID().uuidString)
        self.c = c; c.channelLimits = a.channelLimits
        a.foundPeersDict[c.mySessionUUID] = cPeer; a.reversedFoundPeersDict[cPeer] = c.mySessionUUID
        c.foundPeersDict[a.mySessionUUID] = aPeer; c.reversedFoundPeersDict[aPeer] = a.mySessionUUID
        let endpoint = try a.makeInvitation(remoteUUID: c.mySessionUUID)
        c.receiveInvitation(from: aPeer, endpoint: endpoint) { _, _ in }
        XCTAssertTrue(c.respondToInvitation(remoteUUID: a.mySessionUUID, accept: true))
        ac = try a.prepareBridge(remoteUUID: c.mySessionUUID, peerID: cPeer)
        pc = try c.prepareBridge(remoteUUID: a.mySessionUUID, peerID: aPeer)
        c.peerSend = { [wire, cPeer, weak c] data, peer, session in
            XCTAssertTrue(session === c?.mcSession)
            try wire.append(data, from: cPeer, to: peer)
        }
        if authenticate { try await authenticateTransports(ac!, pc!) }
    }
    func prepareReconnect() throws -> (ScannerPeerTransport, ScannerPeerTransport) {
        let endpoint = try a.makeInvitation(remoteUUID: b.mySessionUUID)
        b.receiveInvitation(from: aPeer, endpoint: endpoint) { _, _ in }
        XCTAssertTrue(b.respondToInvitation(remoteUUID: a.mySessionUUID, accept: true))
        return (try a.prepareBridge(remoteUUID: b.mySessionUUID, peerID: bPeer),
                try b.prepareBridge(remoteUUID: a.mySessionUUID, peerID: aPeer))
    }
    func authenticateTransports(_ a: ScannerPeerTransport, _ b: ScannerPeerTransport) async throws {
        let at = Task { try await a.gate.startPeer() }, bt = Task { try await b.gate.startPeer() }
        for _ in 0..<4 { try await deliverNext() }
        try await at.value; try await bt.value
    }
    func receiver(_ frame: ScannerControlledWire.Frame) throws -> ScannerPeerTransport {
        let destination: ScannerService
        if frame.to == aPeer { destination = a }
        else if frame.to == bPeer { destination = b }
        else { destination = try XCTUnwrap(c); XCTAssertEqual(frame.to, cPeer) }
        return try destination.capturePeerTransport(session: destination.mcSession, peerID: frame.from)
    }
    func deliver(_ frame: ScannerControlledWire.Frame) async throws {
        try await receiver(frame).receiveData(frame.data)
    }
    func pump() -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                if let frame = wire.take() {
                    do {
                        let physical = try receiver(frame) // capture before dispatch, as the MC callback does
                        Task {
                            do { try await physical.receiveData(frame.data) }
                            catch { wire.failed(error) }
                        }
                    } catch { wire.failed(error) }
                } else { try? await Task.sleep(nanoseconds: 1_000_000) }
            }
        }
    }
    func start() -> (Task<Void, Error>, Task<Void, Error>) {
        (Task { try await pa.gate.startPeer() }, Task { try await pb.gate.startPeer() })
    }
    func next() async throws -> ScannerControlledWire.Frame {
        for _ in 0..<1000 {
            if let frame = wire.take() { return frame }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw NSError(domain: "Scanner wire timeout", code: 1)
    }
    func deliverNext() async throws {
        let frame = try await next()
        try await deliver(frame)
    }
    private typealias A = BridgeChannelAuthentication
    func finish(_ tasks: (Task<Void, Error>, Task<Void, Error>)) async throws {
        for _ in 0..<4 where pa.channelSession?.state != .authenticated || pb.channelSession?.state != .authenticated {
            try await deliverNext()
        }
        try await tasks.0.value; try await tasks.1.value
    }
    func stop() { a.stop(); b.stop(); c?.stop() }
}
private final class ScannerControlledWire: @unchecked Sendable {
    struct Frame { let data: Data; let command: BridgeCommand; let from: MCPeerID; let to: MCPeerID }
    private let lock = NSLock()
    private var pending: [Frame] = [], recorded: [Frame] = []
    private var failures: [String] = []
    var errors: [String] { lock.withLock { failures } }
    func failed(_ error: Error) { lock.withLock { failures.append(String(describing: error)) } }
    var history: [Frame] { lock.withLock { recorded } }
    func append(_ data: Data, from: MCPeerID, to: MCPeerID) throws {
        let frame = Frame(data: data, command: try JSONDecoder().decode(BridgeCommand.self, from: data), from: from, to: to)
        lock.withLock { pending.append(frame); recorded.append(frame) }
    }
    func take() -> Frame? { lock.withLock { pending.isEmpty ? nil : pending.removeFirst() } }
}
private final class ScannerStatusObserver: ConnectServiceDelegate {
    private let lock = NSLock(); private var values: [String] = []
    private var receivedFlows: [FlowElement] = []
    var flows: [FlowElement] { lock.withLock { receivedFlows } }
    var statuses: [String] { lock.withLock { values } }
    func scannerStatusChanged(manager: ScannerService, status: String, remoteUUID: String?) { lock.withLock { values.append(status) } }
    func connectedDevicesChanged(manager: ScannerService, connectedDevices: [String]) {}
    func foundDevicesChanged(manager: ScannerService, foundDevice: MCPeerID, remoteUUID: String, discoveryInfo: [String: String]?) {}
    func lostDeviceChanged(manager: ScannerService, lostDevice: MCPeerID, remoteUUID: String) {}
    func invitationReceived(manager: ScannerService, peerID: MCPeerID, remoteUUID: String) {}
    func proximityChanged(manager: ScannerService, remoteUUID: String, distanceMeters: Float?, directionX: Float?, directionY: Float?, directionZ: Float?) {}
    func scannerFlowReceived(manager: ScannerService, flowElement: FlowElement, remoteUUID: String?) { lock.withLock { receivedFlows.append(flowElement) } }
}

private final class ScannerObservedLobby: LobbyCell {
    private let lock = NSLock()
    private var subscriptions = 0
    var subscriptionCount: Int { lock.withLock { subscriptions } }
    var beforeFlow: (() async throws -> Void)?
    override func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, Error> {
        try await beforeFlow?()
        return try await super.flow(requester: requester).handleEvents(receiveSubscription: { [weak self] _ in
            self?.lock.withLock { self?.subscriptions += 1 }
        }).eraseToAnyPublisher()
    }
}
private actor ScannerWorkBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func resume() { released = true; continuation?.resume(); continuation = nil }
}
