import Foundation
import MultipeerConnectivity
import XCTest
import Combine
import Crypto
@testable import CellApple
@testable import CellBase

final class ScannerPeerAuthenticationTests: XCTestCase {
    typealias A = BridgeChannelAuthentication
    private var previousResolver: CellResolverProtocol?
    override func setUp() { previousResolver = CellBase.defaultCellResolver }
    override func tearDown() { CellBase.defaultCellResolver = previousResolver }

    func testIngressOverflowReusesOneRejectionTaskAndPreservesSibling() async throws {
        let pair = try await ScannerPair(); defer { pair.stop() }
        try await pair.finish(pair.start()); try await pair.addThirdPeer()
        let oversized = Data(repeating: 0, count: BridgeChannelTransport.maximumPeerFrameBytes + 1)
        let rejected = pair.pa.enqueueReceive(oversized)
        for _ in 0..<10000 {
            XCTAssertEqual(pair.pa.enqueueReceive(oversized), rejected, "Rejection must not spawn work for every callback")
        }
        do { try await rejected.value; XCTFail("Oversize frame admitted") }
        catch { XCTAssertEqual(error as? A.Failure, .capacity) }
        XCTAssertEqual(pair.a.retainedPhysicalCount, 1)
        XCTAssertNoThrow(try pair.ac!.gate.session.check())
    }

    func testUnusedResourcesAndStreamsCloseImmediatelyAcrossAuthRevokeAndReconnectWithSibling() async throws {
        for phase in ["pending", "active", "revoked", "reconnected"] {
            let pair = try await ScannerPair(); defer { pair.stop() }
            if phase != "pending" { try await pair.finish(pair.start()) }
            try await pair.addThirdPeer()
            let sibling = try XCTUnwrap(pair.ac)
            XCTAssertFalse(pair.pa.mcSession === sibling.mcSession)
            if phase == "revoked" || phase == "reconnected" {
                await pair.pa.gate.close(); await pair.pb.gate.close()
            }
            var fresh: (ScannerPeerTransport, ScannerPeerTransport)?
            if phase == "reconnected" {
                fresh = try pair.prepareReconnect()
                try await pair.authenticateTransports(fresh!.0, fresh!.1)
            }
            for _ in 0..<512 {
                let progress = Progress(totalUnitCount: 1024 * 1024 * 1024)
                pair.a.session(pair.pa.mcSession, didStartReceivingResourceWithName: "untrusted", fromPeer: pair.bPeer, with: progress)
                XCTAssertTrue(progress.isCancelled)
                let stream = ScannerRejectedStream(data: Data())
                pair.a.session(pair.pa.mcSession, didReceive: stream, withName: "untrusted", fromPeer: pair.bPeer)
                XCTAssertEqual(stream.closeCount, 1)
                pair.a.session(pair.pa.mcSession, didFinishReceivingResourceWithName: "untrusted", fromPeer: pair.bPeer, at: nil, withError: nil)
            }
            await pair.pa.gate.close()
            XCTAssertNoThrow(try sibling.gate.session.check())
            if let fresh { XCTAssertNoThrow(try fresh.0.gate.session.check()) }
            XCTAssertEqual(pair.a.retainedPhysicalCount, phase == "reconnected" ? 2 : 1)
            let observer = ScannerStatusObserver(); pair.c?.radarDelegate = observer
            let pump = pair.pump(); defer { pump.cancel() }
            try await pair.a.sendScannerFlowElement(FlowElement(title: "sibling-side-entrance", content: .string("alive"), properties: .init(type: .event, contentType: .string)), remoteUUID: pair.c!.mySessionUUID)
            for _ in 0..<200 where observer.flows.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertEqual(observer.flows.map(\.title), ["sibling-side-entrance"])
        }
    }

    func testMissingReceiptBoundsSequentialFeedAndCloseReleasesOnlyAfterPhysicalClose() async throws {
        let pair = try await ScannerPair(); defer { pair.stop() }
        try await pair.finish(pair.start()); try await pair.addThirdPeer()
        let before = pair.wire.history.count
#if os(macOS)
        let baselineRSS = isolationRSS()
#endif
        for i in 0..<32 {
            try await pair.a.sendScannerFlowElement(FlowElement(title: "held-\(i)", content: .string(String(repeating: "q", count: 1024)), properties: .init(type: .event, contentType: .string)), remoteUUID: pair.b.mySessionUUID)
        }
        XCTAssertEqual(pair.pa.gate.peerOutstandingUsage.records, 32)
        XCTAssertGreaterThan(pair.pa.gate.peerOutstandingUsage.bytes, 32 * 1024)
        XCTAssertEqual(pair.wire.history.count - before, 32)
        pair.a.holdPhysicalRetirementForTesting = true
        let overflow = Task {
            do { try await pair.a.sendScannerFlowElement(FlowElement(title: "overflow", content: .string("x"), properties: .init(type: .event, contentType: .string)), remoteUUID: pair.b.mySessionUUID); XCTFail() } catch {}
        }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(pair.pa.gate.peerOutstandingUsage.records, 32)
        // Close while a bounded producer is waiting for the full window.
        pair.pa.gate.session.close()
        for _ in 0..<200 where pair.pa.gate.session.state != .closed { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(pair.pa.gate.session.state, .closed)
        XCTAssertEqual(pair.a.retainedPhysicalCount, 2)
        XCTAssertGreaterThan(pair.pa.gate.peerOutstandingUsage.bytes, 32 * 1024, "Logical close cannot release queued bytes")
#if os(macOS)
        let heldRSS = isolationRSS()
        print("CP53 held feed RSS baseline=\(baselineRSS) held=\(heldRSS); records=32 bytes=\(pair.pa.gate.peerOutstandingUsage.bytes)")
        XCTAssertLessThan(heldRSS, baselineRSS + 64 * 1024 * 1024)
#endif
        pair.a.holdPhysicalRetirementForTesting = false; pair.a.expireInvitations()
        await overflow.value
        for _ in 0..<1000 where pair.pa.gate.peerOutstandingUsage.bytes != 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(pair.pa.gate.peerOutstandingUsage.bytes, 0)
        XCTAssertEqual(pair.a.retainedPhysicalCount, 1)
        XCTAssertNoThrow(try pair.ac!.gate.session.check())
    }

    func testMissingReceiptDeadlinePhysicallyRetiresOnlyExpiredPeer() async throws {
        let pair = try await ScannerPair(); defer { pair.stop() }
        try await pair.finish(pair.start()); try await pair.addThirdPeer()
        let clock = ScannerReceiptClock()
        pair.pa.gate.peerFlowClock = { clock.now }
        try await pair.a.sendScannerFlowElement(FlowElement(title: "no-receiver", content: .string("held"), properties: .init(type: .event, contentType: .string)), remoteUUID: pair.b.mySessionUUID)
        clock.set(9.999); await pair.pa.gate.checkPeerProgress()
        XCTAssertNoThrow(try pair.pa.gate.session.check())
        clock.set(10)
        for _ in 0..<3000 where pair.pa.gate.session.state != .closed { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertGreaterThan(pair.pa.gate.peerProgressDiagnostics.checks, 1, "The installed timer must tick without receive/send callbacks")
        XCTAssertEqual(pair.pa.gate.session.state, .closed)
        XCTAssertEqual(pair.a.retainedPhysicalCount, 1)
        XCTAssertEqual(pair.pa.gate.peerOutstandingUsage.bytes, 0)
        XCTAssertNoThrow(try pair.ac!.gate.session.check())
    }

    func testSlowReceiverResumesFullWindowProducerWhileSiblingContinues() async throws {
        let pair = try await ScannerPair(); defer { pair.stop() }
        try await pair.finish(pair.start()); try await pair.addThirdPeer()
        let observer = ScannerStatusObserver(); pair.c?.radarDelegate = observer
        let flow = FlowElement(title: "window", content: .string("held"), properties: .init(type: .event, contentType: .string))
        for _ in 0..<32 { try await pair.a.sendScannerFlowElement(flow, remoteUUID: pair.b.mySessionUUID) }
        let before = pair.wire.history.count, finished = ScannerSendFinished()
        let waiting = Task {
            try await pair.a.sendScannerFlowElement(flow, remoteUUID: pair.b.mySessionUUID)
            finished.mark()
        }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(finished.value)
        XCTAssertEqual(pair.pa.gate.peerOutstandingUsage.records, 32)
        XCTAssertEqual(pair.wire.history.count, before, "No extra MC enqueue while the receiver is held")
        try await pair.a.sendScannerFlowElement(flow, remoteUUID: pair.c!.mySessionUUID)
        let sibling = try XCTUnwrap(pair.wire.history.last)
        XCTAssertEqual(sibling.to, pair.cPeer); XCTAssertTrue(pair.wire.remove(sibling))
        try await pair.deliver(sibling)
        XCTAssertEqual(observer.flows.count, 1)
        try await pair.deliverNext() // first held data plus its genuine sealed receipt
        try await waiting.value
        XCTAssertTrue(finished.value)
        XCTAssertEqual(pair.pa.gate.peerOutstandingUsage.records, 32)
        XCTAssertNoThrow(try pair.pa.gate.session.check())
        XCTAssertNoThrow(try pair.ac!.gate.session.check())
    }

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
        let oldProof = try XCTUnwrap(original.wire.history.first { $0.command.cmd == "channelAuthPeerV3InitiatorAuth" })
        for replay in [false, true] {
            let pair = try await ScannerPair(); defer { pair.stop() }
            let tasks = pair.start()
            try await pair.deliverNext(); try await pair.deliverNext()
            let pending = try await pair.next()
            XCTAssertEqual(pending.command.cmd, "channelAuthPeerV3InitiatorAuth")
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(pending.command.payload!.stringValue().utf8)) as? [String: Any])
            var sealed = try XCTUnwrap(Data(base64Encoded: json["sealed"] as! String))
            sealed[0] ^= 1; json["sealed"] = sealed.base64EncodedString()
            let changed = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
            let proof = replay ? oldProof.command : BridgeCommand(cmd: pending.command.cmd,
                payload: .string(String(decoding: changed, as: UTF8.self)), cid: 0)
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
                json["endpoint"] = [field: UUID().uuidString] // Forbidden cleartext scope, even when otherwise well formed.
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
        XCTAssertTrue(pair.b.respondToCurrentInvitationForTesting(remoteUUID: pair.a.mySessionUUID, accept: true))
        let fresh = try pair.a.prepareBridge(remoteUUID: pair.b.mySessionUUID, peerID: pair.bPeer)
        XCTAssertNotEqual(fresh.channelSession?.generation, old.channelSession?.generation)
        do { try await old.sendData(Data([1])); XCTFail("Old generation sent") } catch {}
        await old.close()
        XCTAssertTrue(try pair.a.prepareBridge(remoteUUID: pair.b.mySessionUUID, peerID: pair.bPeer) === fresh)
        let oldProof = try XCTUnwrap(pair.wire.history.first { $0.command.cmd == "channelAuthPeerV3ResponderAuth" })
        do { try await pair.a.extractCommandFromData(A.encode(oldProof.command), from: pair.bPeer); XCTFail() } catch {}
        XCTAssertNil(fresh.bridge)
    }

    func testScannerReconnectSamePeerIDsCompletesFreshMutualProof() async throws {
        let pair = try await ScannerPair(); defer { pair.stop() }
        try await pair.finish(pair.start())
        await pair.pa.gate.close(); await pair.pb.gate.close()
        let endpoint = try pair.a.makeInvitation(remoteUUID: pair.b.mySessionUUID)
        pair.b.receiveInvitation(from: pair.aPeer, endpoint: endpoint) { _, _ in }
        XCTAssertTrue(pair.b.respondToCurrentInvitationForTesting(remoteUUID: pair.a.mySessionUUID, accept: true))
        let a = try pair.a.prepareBridge(remoteUUID: pair.b.mySessionUUID, peerID: pair.bPeer)
        let b = try pair.b.prepareBridge(remoteUUID: pair.a.mySessionUUID, peerID: pair.aPeer)
        let at = Task { try await a.gate.startPeer() }, bt = Task { try await b.gate.startPeer() }
        for _ in 0..<5 { try await pair.deliverNext() }
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
            try assertPrivateHandshake(pair.wire.history.filter { !$0.sealed }, identities: [pair.a.owner, pair.b.owner])
            XCTAssertEqual(pair.pa.gate.session.publicIdentity, try BridgeChannelAuthentication.PublicIdentity(pair.b.owner))
            XCTAssertEqual(pair.pb.gate.session.publicIdentity, try BridgeChannelAuthentication.PublicIdentity(pair.a.owner))
            XCTAssertEqual(pair.pb.bridge?.uuid, lobby.uuid, "Description installs actual Lobby UUID")
            let aRegistered = await resolver.cellUUID(for: pair.a.mySessionUUID), bRegistered = await resolver.cellUUID(for: pair.b.mySessionUUID)
            XCTAssertNotNil(aRegistered); XCTAssertNotNil(bRegistered)
            for _ in 0..<1000 where lobby.subscriptionCount < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertEqual(lobby.subscriptionCount, 2, "Both real feed subscriptions are installed before emission")
            let vaultA = try XCTUnwrap(pair.a.owner.identityVault as? MockIdentityVault)
            let vaultB = try XCTUnwrap(pair.b.owner.identityVault as? MockIdentityVault)
            let signedA = await vaultA.signedMessages, signedB = await vaultB.signedMessages
            // Agreement signatures share the vault but are not origin challenges.
            let challenges = (signedA + signedB).compactMap { try? JSONDecoder().decode(IdentitySigningChallenge.self, from: $0) }
            XCTAssertTrue(challenges.contains { $0.action == "checkIdentityOrigin" && $0.resource == lobby.uuid },
                          "Actual Lobby setup must round-trip an origin-signing RPC under Kapp")
            lobby.pushFlowElement(FlowElement(title: "lobby", content: .string(marker), properties: .init(type: .content, contentType: .string)), requester: pair.a.owner)
            await fulfillment(of: [localFlow, remoteFlow], timeout: 3)
            XCTAssertGreaterThan(pair.wire.history.filter { $0.sealed }.count, 6)
            XCTAssertFalse(pair.wire.history.contains { $0.data.range(of: Data(marker.utf8)) != nil })
            // Hold ordinary dispatch on BOTH sides after opening the records.
            // The existing live feed permits an actual origin-signature RPC;
            // both its request and registered response must overtake these holds.
            let heldA = ScannerWorkBarrier(), heldB = ScannerWorkBarrier()
            let enteredA = expectation(description: "first A dispatch"), enteredB = expectation(description: "first B dispatch")
            let observedA = ScannerStatusObserver(), observedB = ScannerStatusObserver()
            pair.a.radarDelegate = observedA; pair.b.radarDelegate = observedB
            pair.pa.beforeOrderedDispatch = { command in
                if case let .flowElement(flow) = command.payload, flow.title == "ordered-first" {
                    enteredA.fulfill(); await heldA.wait()
                }
            }
            pair.pb.beforeOrderedDispatch = { command in
                if case let .flowElement(flow) = command.payload, flow.title == "ordered-first" {
                    enteredB.fulfill(); await heldB.wait()
                }
            }
            for title in ["ordered-first", "ordered-second"] {
                let flow = FlowElement(title: title, content: .string(title), properties: .init(type: .event, contentType: .string))
                try await pair.a.sendScannerFlowElement(flow)
                try await pair.b.sendScannerFlowElement(flow)
            }
            await fulfillment(of: [enteredA, enteredB], timeout: 2)
            let originScope = try XCTUnwrap(challenges.first { $0.action == "checkIdentityOrigin" && $0.resource == lobby.uuid })
            let challenge = IdentitySigningChallenge(identityUUID: pair.b.owner.uuid,
                publicKeyFingerprint: pair.b.owner.signingPublicKeyFingerprint, domain: originScope.domain, resource: lobby.uuid,
                action: "checkIdentityOrigin", audience: "GeneralCell", nonce: Data(repeating: 7, count: 32))
            let challengeData = try A.encode(challenge)
            let signed = expectation(description: "origin RPC passes held dispatch in both directions")
            let signer = pair.pa.bridge!.signMessageForIdentity(messageData: challengeData, identity: pair.b.owner)
                .sink(receiveCompletion: { completion in
                    if case let .failure(error) = completion { XCTFail("Origin RPC failed: \(error)") }
                }, receiveValue: { signature in
                    XCTAssertTrue(IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: challengeData, identity: pair.b.owner))
                    signed.fulfill()
                })
            await fulfillment(of: [signed], timeout: 3)
            XCTAssertTrue(observedA.flows.isEmpty); XCTAssertTrue(observedB.flows.isEmpty)
            await heldA.resume(); await heldB.resume()
            for _ in 0..<1000 where observedA.flows.count < 2 || observedB.flows.count < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertEqual(observedA.flows.map(\.title), ["ordered-first", "ordered-second"])
            XCTAssertEqual(observedB.flows.map(\.title), ["ordered-first", "ordered-second"])
            signer.cancel()

            // Real feed delivery: hold the first response AFTER the auditor
            // lookup, where a second response used to overtake publication.
            let feedBarrier = ScannerWorkBarrier(), feedEntered = expectation(description: "feed after lookup")
            let feedOnce = ScannerOnce(), feedValues = ScannerTitles()
            pair.pb.bridge!.afterResponseLookup = { request in
                if request.command == .feed, feedOnce.take() { feedEntered.fulfill(); await feedBarrier.wait() }
            }
            let orderedFeed = remoteScanner.getFeedPublisher().sink(receiveCompletion: { _ in }, receiveValue: { flow in
                if flow.title.hasPrefix("ordered-feed-") { feedValues.append(flow.title) }
            })
            for title in ["ordered-feed-1", "ordered-feed-2"] {
                lobby.pushFlowElement(FlowElement(title: title, content: .string(title), properties: .init(type: .content, contentType: .string)), requester: pair.a.owner)
                if title == "ordered-feed-1" { await fulfillment(of: [feedEntered], timeout: 2) }
            }
            // A sign response is a deterministic fence proving later records
            // have been opened while first feed publication is held.
            let secondChallenge = IdentitySigningChallenge(identityUUID: pair.b.owner.uuid,
                publicKeyFingerprint: pair.b.owner.signingPublicKeyFingerprint, domain: originScope.domain, resource: lobby.uuid,
                action: "checkIdentityOrigin", audience: "GeneralCell", nonce: Data(repeating: 8, count: 32))
            _ = try await pair.pa.bridge!.signMessageForIdentity(messageData: A.encode(secondChallenge), identity: pair.b.owner).getOneWithTimeout(3)
            XCTAssertEqual(feedValues.values, [])
            await feedBarrier.resume()
            for _ in 0..<1000 where feedValues.values.count < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertEqual(feedValues.values, ["ordered-feed-1", "ordered-feed-2"])
            orderedFeed.cancel(); pair.pb.bridge!.afterResponseLookup = nil
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
        XCTAssertGreaterThan(pair.wire.history.filter { $0.sealed }.count, 2)
        XCTAssertTrue(observer.statuses.contains { $0 == "bridgeFailed:denied" })
    }

    func testExpiredScheduledSetupRevokesBeforeHeldWorkReturnsAndRetainsAdmission() async throws {
        let clock = ScannerSetupClock(), admission = ScannerAdmission(now: { clock.now })
        let pair = try await ScannerPair(admissionA: admission); defer { pair.stop() }
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        let lobby = await ScannerObservedLobby(owner: pair.a.owner)
        let scanner = await GeneralCell(owner: pair.a.owner)
        let hold = ScannerWorkBarrier(), entered = expectation(description: "physical callback setup held")
        lobby.beforeFlow = { entered.fulfill(); await hold.wait() }
        try await resolver.registerNamedEmitCell(name: "Lobby", emitCell: lobby, scope: .template, identity: pair.a.owner)
        try await resolver.registerNamedEmitCell(name: "EntityScanner", emitCell: scanner, scope: .template, identity: pair.a.owner)
        let pump = pair.pump(); defer { pump.cancel() }
        let remote = Task { try await pair.pb.gate.startPeer() }
        // Production physical callback, not a direct unbudgeted test setup.
        pair.a.session(pair.pa.mcSession, peer: pair.bPeer, didChange: .connected)
        await fulfillment(of: [entered], timeout: 2)
        try await remote.value
        XCTAssertEqual(admission.snapshot(.task).count, 1)
        clock.advance(10); pair.a.expireInvitations()
        XCTAssertThrowsError(try pair.pa.gate.session.check(), "Expired setup must already be revoked, before held code returns")
        XCTAssertEqual(admission.snapshot(.task).count, 1)
        XCTAssertGreaterThan(pair.a.channelLimits.outstandingWorkCount, 0)
        try pair.pb.gate.session.check()
        let before = await resolver.cellUUID(for: pair.b.mySessionUUID); XCTAssertNil(before)
        await hold.resume()
        for _ in 0..<1000 where admission.snapshot(.task).count != 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(admission.snapshot(.task).count, 0)
        let after = await resolver.cellUUID(for: pair.b.mySessionUUID); XCTAssertNil(after)
        XCTAssertEqual(pair.a.bridgeDelegateCount, 0)
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
        try await pair.pb.gate.sendData(A.encode(command))
        let frame = try await pair.next()
        let work = pair.pa.enqueueReceive(frame.data)
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
        XCTAssertTrue(try pair.a.capturePeerTransport(session: pair.pa.mcSession, peerID: pair.bPeer) === pair.pa)
        XCTAssertTrue(try pair.a.capturePeerTransport(session: ac.mcSession, peerID: pair.cPeer) === ac)
        XCTAssertThrowsError(try pair.a.capturePeerTransport(session: MCSession(peer: pair.aPeer), peerID: pair.bPeer))

        // Keep a real B request pending in Base. C knows B's public descriptor,
        // generation and cid, but its physical callback must never reach B's gate.
        let bridge = try XCTUnwrap(pair.pa.bridge)
        await bridge.sendCommand(command: .get, identity: pair.a.owner, payload: .string("private"))
        let heldRequest = try await pair.next()
        // Admit the record at B without running a Cell request; this assertion
        // concerns A's physical route, and preserves the receive sequence.
        _ = try pair.pb.gate.openPeerFrame(heldRequest.data)
        let pendingCommand = await bridge.auditor.loadBridgeCommandForCommandId(1)
        XCTAssertNotNil(pendingCommand)
        let forged = BridgeCommand(cmd: "response", payload: .string("from-c"), cid: 1,
                                   peerGeneration: pair.pb.gate.session.generation)
        try await pc.gate.sendData(A.encode(forged))
        try await pair.deliverNext()
        let stillPending = await bridge.auditor.loadBridgeCommandForCommandId(1)
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
        for oldResponse in [false, true] {
            let pair = try await ScannerPair(); defer { pair.stop() }
            let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
            let lobby = await LobbyCell(owner: pair.a.owner)
            try await resolver.registerNamedEmitCell(name: "Lobby", emitCell: lobby, scope: .template, identity: pair.a.owner)
            try await pair.finish(pair.start()); try await pair.addThirdPeer()
            await pair.pb.bridge!.sendCommand(command: .description, identity: pair.b.owner, payload: nil)
            let oldCommand = try await pair.next(), captured = try pair.receiver(oldCommand)
            let firstCID = await pair.pb.bridge!.auditor.loadBridgeCommandForCommandId(1)
            XCTAssertEqual(firstCID?.cid, 1)
            try await pair.deliver(oldCommand)
            let response = try await pair.next(), capturedResponse = try pair.receiver(response)
            await pair.pa.gate.close(); await pair.pb.gate.close()
            let fresh = try pair.prepareReconnect()
            try await pair.authenticateTransports(fresh.0, fresh.1)
            await fresh.1.bridge!.sendCommand(command: .description, identity: pair.b.owner, payload: nil)
            let newCommand = try await pair.next()
            let newCID = await fresh.1.bridge!.auditor.loadBridgeCommandForCommandId(1)
            XCTAssertEqual(firstCID?.cid, newCID?.cid, "Actual Base cid reuse")
            // A callback already captured by an old transport cannot close the new one.
            do { try await captured.receiveData(Data([0xff])); XCTFail() } catch {}
            do { try await capturedResponse.receiveData(response.data); XCTFail() } catch {}
            pair.a.peerDisconnected(captured); await captured.close()
            try fresh.0.gate.session.check(); try fresh.1.gate.session.check()
            try await pair.deliver(newCommand); try await pair.deliverNext()
            XCTAssertEqual(fresh.1.bridge?.uuid, lobby.uuid)
            let before = resolver.lookupCountSnapshot()
            // N07 strengthens N08: replay on the *current* connection closes it.
            do { try await pair.deliver(oldResponse ? response : oldCommand); XCTFail() } catch {}
            XCTAssertEqual(resolver.lookupCountSnapshot(), before)
            XCTAssertThrowsError(try (oldResponse ? fresh.1 : fresh.0).gate.session.check())
            let marker = FlowElement(title: "sibling", content: .string("ok"), properties: .init(type: .event, contentType: .string))
            try await pair.a.sendScannerFlowElement(marker, remoteUUID: pair.c!.mySessionUUID)
            try await pair.deliverNext(); try pair.ac!.gate.session.check(); try pair.pc!.gate.session.check()
        }
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
        // Actual MC delegate entry point retires the captured generation before
        // its main-queue UI callback can run through a reconnect.
        pair.a.session(pair.pa.mcSession, peer: pair.bPeer, didChange: .notConnected)
        pair.b.session(pair.pb.mcSession, peer: pair.aPeer, didChange: .notConnected)
        await pair.pa.gate.close(); await pair.pb.gate.close()
        let fresh = try pair.prepareReconnect()
        try await pair.authenticateTransports(fresh.0, fresh.1)
        let aObserver = ScannerStatusObserver(); pair.a.radarDelegate = aObserver
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
        XCTAssertFalse(aObserver.statuses.contains { $0.hasPrefix("bridgeFailed:") })
        XCTAssertFalse(bObserver.statuses.contains { $0.hasPrefix("bridgeFailed:") })
        XCTAssertFalse(cObserver.statuses.contains { $0.hasPrefix("bridgeFailed:") })
        try fresh.0.gate.session.check(); try fresh.1.gate.session.check()
        try pair.ac!.gate.session.check(); try pair.pc!.gate.session.check()
    }

    func testDiscoveryTokenSkipsPendingThenRevokedPeerWithoutBreakingHandshake() async throws {
        let pair = try await ScannerPair(); defer { pair.stop() }
        try await pair.finish(pair.start()); try await pair.addThirdPeer(authenticate: false)
        let c = try XCTUnwrap(pair.c), ac = try XCTUnwrap(pair.ac), pc = try XCTUnwrap(pair.pc)
        let before = pair.wire.history.count
        let context = try pair.a.consumerContext(remoteUUID: pair.b.mySessionUUID)
        try await pair.a.shareDiscoveryTokenData(Data("opaque-ni-archive".utf8), generation: UUID(), context: context)
        XCTAssertThrowsError(try pair.a.consumerContext(remoteUUID: c.mySessionUUID))
        let selected = Array(pair.wire.history.dropFirst(before))
        XCTAssertEqual(selected.count, 1); XCTAssertEqual(selected.first?.to, pair.bPeer)
        XCTAssertTrue(selected.first?.sealed == true)
        XCTAssertNil(selected.first?.data.range(of: Data("opaque-ni-archive".utf8)))
        try await pair.deliverNext()
        XCTAssertEqual(ac.gate.session.state, .unauthenticated)
        XCTAssertEqual(pc.gate.session.state, .unauthenticated)
        try await pair.authenticateTransports(ac, pc) // pending handshake survived the targeted NI send
        pair.a.channelLimits.revoke(identity: try A.PublicIdentity(c.owner), domain: "nearby")
        let revokedStart = pair.wire.history.count
        try await pair.a.shareDiscoveryTokenData(Data("second-token".utf8), generation: UUID(), context: context)
        XCTAssertThrowsError(try pair.a.consumerContext(remoteUUID: c.mySessionUUID))
        XCTAssertEqual(Array(pair.wire.history.dropFirst(revokedStart)).map(\.to), [pair.bPeer])
        try await pair.deliverNext(); try pair.pa.gate.session.check(); try pair.pb.gate.session.check()
    }

    func testPeerGenerationWireFieldIsRequiredAndAuthFramesRemainUntagged() async throws {
        let pair = try await ScannerPair(); defer { pair.stop() }
        try await pair.finish(pair.start())
        for frame in pair.wire.history.filter({ !$0.sealed }) {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: frame.data) as? [String: Any])
            XCTAssertNil(json["&peerGeneration"])
        }
        let command = BridgeCommand(cmd: "response", payload: .string("value"), cid: 42)
        try await pair.pb.gate.sendData(A.encode(command))
        let frame = try await pair.next()
        XCTAssertTrue(frame.sealed)
        XCTAssertEqual(String(decoding: frame.data.dropFirst(4).prefix(36), as: UTF8.self), pair.pb.gate.session.generation)
        try await pair.deliver(frame)
        // A correctly sealed payload still cannot omit the inner generation.
        try await pair.pb.sendData(A.encode(command))
        do { try await pair.deliverNext(); XCTFail("Untagged ordinary peer frame accepted") }
        catch { XCTAssertEqual(error as? A.Failure, .malformed) }
        XCTAssertThrowsError(try pair.pa.gate.session.check())
    }

    func testDiscoveryTokenUsesExistingSendByteQuota() async throws {
        var configuration = BridgeChannelLimits.Configuration()
        configuration.maximumPendingSendBytesPerConnection = 16 * 1024
        let pair = try await ScannerPair(limits: BridgeChannelLimits(configuration: configuration)); defer { pair.stop() }
        try await pair.finish(pair.start())
        let before = pair.wire.history.count
        let context = try pair.a.consumerContext(remoteUUID: pair.b.mySessionUUID)
        do {
            try await pair.a.shareDiscoveryTokenData(Data(repeating: 7, count: 20 * 1024), generation: UUID(), context: context)
            XCTFail("NI send escaped existing quota")
        } catch {}
        XCTAssertEqual(pair.wire.history.count, before)
        XCTAssertThrowsError(try pair.pa.gate.session.check())
    }

    func testRelayForwardsRealHandshakeButSeesOnlyCiphertextInBothDirections() async throws {
        let pair = try await ScannerPair(); defer { pair.stop() }
        let middleman = pair.wire // two independent MCSession adapter endpoints; M has bytes, no keys
        try await pair.finish(pair.start()) // M forwards all five real handshake messages unchanged
        XCTAssertEqual(middleman.history.filter { !$0.sealed }.map { $0.command.cmd },
                       ["channelAuthPeerV3Hello", "channelAuthPeerV3ResponderAuth", "channelAuthPeerV3InitiatorAuth",
                        "channelAuthPeerV3ResponderFinished", "channelAuthPeerV3InitiatorFinished"])
        XCTAssertEqual(middleman.history.filter { $0.sealed }.count, 0)
        try assertPrivateHandshake(middleman.history, identities: [pair.a.owner, pair.b.owner])
        let aObserver = ScannerStatusObserver(), bObserver = ScannerStatusObserver()
        pair.a.radarDelegate = aObserver; pair.b.radarDelegate = bObserver
        for (sender, remote, receiver) in [(pair.a, pair.b.mySessionUUID, bObserver), (pair.b, pair.a.mySessionUUID, aObserver)] {
            let marker = "confidential-" + UUID().uuidString
            let flow = FlowElement(title: marker, content: .string(marker), properties: .init(type: .event, contentType: .string))
            try await sender.sendScannerFlowElement(flow, remoteUUID: remote)
            let intercepted = try await pair.next()
            XCTAssertTrue(intercepted.sealed)
            XCTAssertNil(intercepted.data.range(of: Data(marker.utf8)))
            XCTAssertThrowsError(try JSONDecoder().decode(BridgeCommand.self, from: intercepted.data))
            try await pair.deliver(intercepted)
            XCTAssertEqual(receiver.flows.last?.title, marker)
        }
        try pair.pa.gate.session.check(); try pair.pb.gate.session.check()
    }

    private func assertPrivateHandshake(_ frames: [ScannerControlledWire.Frame], identities: [Identity]) throws {
        let names = ["channelAuthPeerV3Hello", "channelAuthPeerV3ResponderAuth", "channelAuthPeerV3InitiatorAuth",
                     "channelAuthPeerV3ResponderFinished", "channelAuthPeerV3InitiatorFinished"]
        XCTAssertEqual(frames.count, 5)
        for (index, frame) in frames.enumerated() {
            let outer = try XCTUnwrap(JSONSerialization.jsonObject(with: frame.data) as? [String: Any])
            XCTAssertEqual(Set(outer.keys), Set(["&string", "cid", "cmd"]))
            XCTAssertEqual(frame.command.cmd, names[index])
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.command.payload!.stringValue().utf8)) as? [String: Any])
            if index < 2 {
                let hello = index == 0 ? body : try XCTUnwrap(body["hello"] as? [String: Any])
                XCTAssertEqual(Set(hello.keys), Set(["profile", "role", "ephemeralPublicKey", "nonce", "generation", "issuedAtMilliseconds"]))
            }
            if index > 0 {
                XCTAssertEqual(Set(body.keys), Set(index == 1 ? ["hello", "sealed"] : ["profile", "sealed"]))
                XCTAssertEqual(Data(base64Encoded: body["sealed"] as! String)?.count, index < 3 ? 8208 : 1040)
            }
            for identity in identities {
                for marker in [identity.uuid, identity.publicSecureKey!.compressedKey!.base64EncodedString(), identity.signingPublicKeyFingerprint!] {
                    XCTAssertNil(frame.data.range(of: Data(marker.utf8)))
                    XCTAssertNil(frame.data.range(of: Data(Data(marker.utf8).base64EncodedString().utf8)))
                }
            }
        }
    }

    func testRelayCannotCorrelateIdentityFieldsAcrossFreshHandshakes() async throws {
        let pair = try await ScannerPair(); defer { pair.stop() }
        try await pair.finish(pair.start())
        let old = pair.wire.history
        await pair.pa.gate.close(); await pair.pb.gate.close()
        let fresh = try pair.prepareReconnect(), before = pair.wire.history.count
        try await pair.authenticateTransports(fresh.0, fresh.1)
        let recent = Array(pair.wire.history.dropFirst(before))
        try assertPrivateHandshake(recent, identities: [pair.a.owner, pair.b.owner])
        for index in 0..<5 { XCTAssertNotEqual(old[index].data, recent[index].data) }
    }

    func testRelayTamperInsertionReplayReorderReflectionAndMalformedRecordsCloseWithoutDispatch() async throws {
        for attack in ["tag", "insert", "replay", "reorder", "reflection", "generation", "truncated", "oversize", "empty", "plaintext"] {
            let pair = try await ScannerPair(); defer { pair.stop() }
            try await pair.finish(pair.start())
            let observer = ScannerStatusObserver(); pair.b.radarDelegate = observer; pair.a.radarDelegate = observer
            let flow = FlowElement(title: "protected", content: .string("secret"), properties: .init(type: .event, contentType: .string))
            try await pair.a.sendScannerFlowElement(flow, remoteUUID: pair.b.mySessionUUID)
            let intercepted = try await pair.next()
            var data = intercepted.data
            var target = pair.pb
            switch attack {
            case "tag": data[data.count - 1] ^= 1
            case "insert": data.replaceSubrange(49..<data.count, with: Data(repeating: 0x61, count: data.count - 49))
            case "replay": try await pair.deliver(intercepted)
            case "reorder":
                try await pair.a.sendScannerFlowElement(flow, remoteUUID: pair.b.mySessionUUID)
                data = try await pair.next().data
            case "reflection": target = pair.pa
            case "generation": data[4] = data[4] == 0x41 ? 0x42 : 0x41
            case "truncated": data = Data(data.prefix(50))
            case "oversize": data = Data(repeating: 0, count: BridgeInboundPayloadValidator.defaultMaximumBytes + 66)
            case "empty": data = Data()
            case "plaintext": data = try A.encode(BridgeCommand(cmd: "response", payload: .flowElement(flow), cid: -1, peerGeneration: pair.pa.gate.session.generation))
            default: XCTFail(attack)
            }
            let before = observer.flows.count
            do { try await target.receiveData(data); XCTFail(attack) } catch {}
            XCTAssertEqual(observer.flows.count, before, attack)
            XCTAssertThrowsError(try target.gate.session.check(), attack)
            do { try await target.receiveData(intercepted.data); XCTFail("Closed channel reopened: \(attack)") } catch {}
            XCTAssertEqual(observer.flows.count, before, attack)
        }
    }

    func testReplacingEitherEphemeralKeyInvalidatesIdentitySignature() async throws {
        for replaceInitiator in [true, false] {
            let pair = try await ScannerPair(); defer { pair.stop() }
            let tasks = pair.start()
            if !replaceInitiator { try await pair.deliverNext() }
            let intercepted = try await pair.next()
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(intercepted.command.payload!.stringValue().utf8)) as? [String: Any])
            let substitutedKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
            if replaceInitiator { json["ephemeralPublicKey"] = substitutedKey }
            else {
                var hello = try XCTUnwrap(json["hello"] as? [String: Any])
                hello["ephemeralPublicKey"] = substitutedKey; json["hello"] = hello
            }
            let bytes = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
            let changed = BridgeCommand(cmd: intercepted.command.cmd, payload: .string(String(decoding: bytes, as: UTF8.self)), cid: 0)
            if replaceInitiator {
                try await pair.pb.receiveData(A.encode(changed)) // B signs altered transcript
                do { try await pair.deliverNext(); XCTFail("Substituted initiator key verified") }
                catch {}
            } else {
                do { try await pair.pa.receiveData(A.encode(changed)); XCTFail("Substituted responder key verified") }
                catch {}
            }
            XCTAssertNil(pair.pa.bridge); XCTAssertNil(pair.pb.bridge)
            await pair.pa.gate.close(); await pair.pb.gate.close()
            _ = try? await tasks.0.value; _ = try? await tasks.1.value
        }
    }

    func testMissingEphemeralKeyAndOldProfileCannotDowngrade() async throws {
        for missingKey in [true, false] {
            let pair = try await ScannerPair(); defer { pair.stop() }
            let tasks = pair.start(), hello = try await pair.next()
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(hello.command.payload!.stringValue().utf8)) as? [String: Any])
            if missingKey { json.removeValue(forKey: "ephemeralPublicKey") }
            else { json["profile"] = "org.haven.bridge-peer-channel.v1" }
            let bytes = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
            let changed = BridgeCommand(cmd: hello.command.cmd, payload: .string(String(decoding: bytes, as: UTF8.self)), cid: 0)
            do { try await pair.pb.receiveData(A.encode(changed)); XCTFail() } catch {}
            XCTAssertNil(pair.pb.bridge)
            await pair.pa.gate.close(); await pair.pb.gate.close()
            _ = try? await tasks.0.value; _ = try? await tasks.1.value
        }
    }

    func testBothFactoriesWaitForSealedConfirmationAndEarlyDataIsRejected() async throws {
        let pair = try await ScannerPair(); defer { pair.stop() }
        let tasks = pair.start()
        for _ in 0..<3 { try await pair.deliverNext() }
        XCTAssertNil(pair.pa.bridge); XCTAssertNil(pair.pb.bridge)
        XCTAssertEqual(pair.pa.gate.session.state, .verifying)
        XCTAssertEqual(pair.pb.gate.session.state, .verifying)
        let responderConfirmation = try await pair.next()
        XCTAssertEqual(responderConfirmation.command.cmd, "channelAuthPeerV3ResponderFinished")
        try await pair.deliver(responderConfirmation)
        XCTAssertNotNil(pair.pa.bridge); XCTAssertNil(pair.pb.bridge)
        let initiatorConfirmation = try await pair.next()
        XCTAssertEqual(initiatorConfirmation.command.cmd, "channelAuthPeerV3InitiatorFinished")
        // A legitimate sender can produce application data now; B must not
        // dispatch it if M withholds the first, confirmation record.
        try await pair.pa.gate.sendData(A.encode(BridgeCommand(cmd: "response", payload: .string("too-early"), cid: 9)))
        do { try await pair.deliverNext(); XCTFail("Data passed before key confirmation") } catch {}
        XCTAssertNil(pair.pb.bridge)
        await pair.pa.gate.close(); await pair.pb.gate.close()
        _ = try? await tasks.0.value; _ = try? await tasks.1.value
    }

    func testQueuedArrivalOrderAndConcurrentSendsPreserveCounters() async throws {
        let pair = try await ScannerPair(); defer { pair.stop() }
        try await pair.finish(pair.start())
        let observer = ScannerStatusObserver(); pair.b.radarDelegate = observer
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 { group.addTask {
                let flow = FlowElement(title: "frame-\(index)", content: .string(String(index)), properties: .init(type: .event, contentType: .string))
                try await pair.a.sendScannerFlowElement(flow, remoteUUID: pair.b.mySessionUUID)
            } }
            try await group.waitForAll()
        }
        var received: [Task<Void, Error>] = []
        for sequence in 0..<20 {
            let frame = try await pair.next()
            let counter = frame.data.dropFirst(41).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            XCTAssertEqual(counter, UInt64(sequence))
            received.append(pair.pb.enqueueReceive(frame.data))
        }
        for task in received { try await task.value }
        XCTAssertEqual(Set(observer.flows.map(\.title)).count, 20)
        try pair.pb.gate.session.check()
    }

    func testOldCiphertextDuringHandshakeAndRewrittenGenerationBothFailClosed() async throws {
        for pendingHandshake in [true, false] {
            let pair = try await ScannerPair(); defer { pair.stop() }
            try await pair.finish(pair.start())
            let command = BridgeCommand(cmd: "response", payload: .string("old-secret"), cid: 1)
            try await pair.pb.gate.sendData(A.encode(command))
            let old = try await pair.next()
            let oldHello = try XCTUnwrap(pair.wire.history.first { $0.command.cmd == "channelAuthPeerV3Hello" })
            await pair.pa.gate.close(); await pair.pb.gate.close()
            let fresh = try pair.prepareReconnect()
            var replay = old.data
            if !pendingHandshake {
                let before = pair.wire.history.count
                try await pair.authenticateTransports(fresh.0, fresh.1)
                let freshHello = try XCTUnwrap(pair.wire.history.dropFirst(before).first { $0.command.cmd == "channelAuthPeerV3Hello" })
                let oldKey = try A.decode(BridgePeerChannelAuthentication.Hello.self, from: Data(oldHello.command.payload!.stringValue().utf8)).ephemeralPublicKey
                let freshKey = try A.decode(BridgePeerChannelAuthentication.Hello.self, from: Data(freshHello.command.payload!.stringValue().utf8)).ephemeralPublicKey
                XCTAssertNotEqual(oldKey, freshKey)
                let request = BridgeCommand(cmd: "description", identity: pair.a.owner.publicIdentitySnapshot(), payload: nil, cid: 1)
                let stored = await fresh.0.bridge!.auditor.storeBridgeCommand(request, for: 1)
                XCTAssertTrue(stored)
                // M knows the public new generation and the expected counter.
                // Rewriting N08 metadata cannot make old ciphertext authenticate.
                replay.replaceSubrange(4..<40, with: Data(fresh.1.gate.session.generation.utf8))
                replay.replaceSubrange(41..<49, with: Data([0, 0, 0, 0, 0, 0, 0, 0]))
            }
            do { try await fresh.0.receiveData(replay); XCTFail() } catch {}
            XCTAssertThrowsError(try fresh.0.gate.session.check())
            if pendingHandshake { XCTAssertNil(fresh.0.bridge) }
        }
    }

    func testAEADOverheadIsIncludedInExistingSendQuota() async throws {
        let payload = ValueType.string(String(repeating: "q", count: 20_000))
        let tagged = BridgeCommand(cmd: "response", payload: payload, cid: 7, peerGeneration: "11111111-1111-4111-8111-111111111111")
        var config = BridgeChannelLimits.Configuration()
        config.maximumPendingSendBytesPerConnection = try A.encode(tagged).count
        let pair = try await ScannerPair(limits: BridgeChannelLimits(configuration: config)); defer { pair.stop() }
        try await pair.finish(pair.start())
        let before = pair.wire.history.count
        do {
            try await pair.pa.gate.sendData(A.encode(BridgeCommand(cmd: "response", payload: payload, cid: 7)))
            XCTFail("The plaintext fits exactly, but AEAD overhead exceeds the quota")
        } catch { XCTAssertEqual(error as? A.Failure, .capacity) }
        XCTAssertEqual(pair.wire.history.count, before)
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

private final class ScannerSendFinished: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    var value: Bool { lock.withLock { done } }
    func mark() { lock.withLock { done = true } }
}

private final class ScannerReceiptClock: @unchecked Sendable {
    private let lock = NSLock(); private var time: TimeInterval = 0
    var now: TimeInterval { lock.withLock { time } }
    func set(_ value: TimeInterval) { lock.withLock { time = value } }
}

private final class ScannerRejectedStream: InputStream {
    var closeCount = 0
    override func close() { closeCount += 1 }
}

final class ScannerPair {
    let a: ScannerService, b: ScannerService
    let aPeer = MCPeerID(displayName: "test-a"), bPeer = MCPeerID(displayName: "test-b")
    let pa: ScannerPeerTransport, pb: ScannerPeerTransport
    let wire = ScannerControlledWire()
    var c: ScannerService?
    var cPeer = MCPeerID(displayName: "test-c")
    var ac: ScannerPeerTransport?, pc: ScannerPeerTransport?
    init(limits: BridgeChannelLimits = BridgeChannelLimits(), ownerA: Identity? = nil, ownerB: Identity? = nil, reverse: Bool = false, admissionA: ScannerAdmission = ScannerAdmission(), sessionSuffix: String = UUID().uuidString) async throws {
        let resolvedOwnerA: Identity
        if let ownerA { resolvedOwnerA = ownerA }
        else { resolvedOwnerA = await Self.owner() }
        let resolvedOwnerB: Identity
        if let ownerB { resolvedOwnerB = ownerB }
        else { resolvedOwnerB = await Self.owner() }
        let suffix = sessionSuffix
        a = ScannerService(admission: admissionA, owner: resolvedOwnerA, sessionUUID: (reverse ? "second-" : "first-") + suffix)
        b = ScannerService(admission: ScannerAdmission(), owner: resolvedOwnerB, sessionUUID: (reverse ? "first-" : "second-") + suffix)
        a.channelLimits = limits; b.channelLimits = limits
        a.foundPeersDict[b.mySessionUUID] = bPeer; a.reversedFoundPeersDict[bPeer] = b.mySessionUUID
        b.foundPeersDict[a.mySessionUUID] = aPeer; b.reversedFoundPeersDict[aPeer] = a.mySessionUUID
        let endpoint = try a.makeInvitation(remoteUUID: b.mySessionUUID)
        b.receiveInvitation(from: aPeer, endpoint: endpoint) { _, _ in }
        _ = b.respondToCurrentInvitationForTesting(remoteUUID: a.mySessionUUID, accept: true)
        pa = try a.prepareBridge(remoteUUID: b.mySessionUUID, peerID: bPeer)
        pb = try b.prepareBridge(remoteUUID: a.mySessionUUID, peerID: aPeer)
        a.peerSend = { [wire, aPeer, weak a] data, peer, session in
            XCTAssertTrue(session === (try a?.sessionForPeer(peer)))
            try wire.append(data, from: aPeer, to: peer)
        }
        b.peerSend = { [wire, bPeer, weak b] data, peer, session in
            XCTAssertTrue(session === (try b?.sessionForPeer(peer)))
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
        let c = ScannerService(admission: ScannerAdmission(), owner: await Self.owner(), sessionUUID: "third-" + UUID().uuidString)
        self.c = c; c.channelLimits = a.channelLimits
        a.foundPeersDict[c.mySessionUUID] = cPeer; a.reversedFoundPeersDict[cPeer] = c.mySessionUUID
        c.foundPeersDict[a.mySessionUUID] = aPeer; c.reversedFoundPeersDict[aPeer] = a.mySessionUUID
        let endpoint = try a.makeInvitation(remoteUUID: c.mySessionUUID)
        c.receiveInvitation(from: aPeer, endpoint: endpoint) { _, _ in }
        XCTAssertTrue(c.respondToCurrentInvitationForTesting(remoteUUID: a.mySessionUUID, accept: true))
        ac = try a.prepareBridge(remoteUUID: c.mySessionUUID, peerID: cPeer)
        pc = try c.prepareBridge(remoteUUID: a.mySessionUUID, peerID: aPeer)
        c.peerSend = { [wire, cPeer, weak c] data, peer, session in
            XCTAssertTrue(session === (try c?.sessionForPeer(peer)))
            try wire.append(data, from: cPeer, to: peer)
        }
        if authenticate { try await authenticateTransports(ac!, pc!) }
    }
    func prepareReconnect() throws -> (ScannerPeerTransport, ScannerPeerTransport) {
        // The real per-peer MCSession discards its old delivery queue on close.
        // Captured adversarial frames remain available to explicit replay tests.
        wire.discard(between: aPeer, and: bPeer)
        // Rediscovery after a physical disconnect, retaining the same MCPeerIDs.
        a.foundPeersDict[b.mySessionUUID] = bPeer; a.reversedFoundPeersDict[bPeer] = b.mySessionUUID
        b.foundPeersDict[a.mySessionUUID] = aPeer; b.reversedFoundPeersDict[aPeer] = a.mySessionUUID
        let endpoint = try a.makeInvitation(remoteUUID: b.mySessionUUID)
        b.receiveInvitation(from: aPeer, endpoint: endpoint) { _, _ in }
        XCTAssertTrue(b.respondToCurrentInvitationForTesting(remoteUUID: a.mySessionUUID, accept: true))
        return (try a.prepareBridge(remoteUUID: b.mySessionUUID, peerID: bPeer),
                try b.prepareBridge(remoteUUID: a.mySessionUUID, peerID: aPeer))
    }
    func authenticateTransports(_ a: ScannerPeerTransport, _ b: ScannerPeerTransport) async throws {
        let at = Task { try await a.gate.startPeer() }, bt = Task { try await b.gate.startPeer() }
        for _ in 0..<5 { try await deliverNext() }
        try await at.value; try await bt.value
    }
    func receiver(_ frame: ScannerControlledWire.Frame) throws -> ScannerPeerTransport {
        let destination: ScannerService
        if frame.to == aPeer { destination = a }
        else if frame.to == bPeer { destination = b }
        else { destination = try XCTUnwrap(c); XCTAssertEqual(frame.to, cPeer) }
        return try destination.capturePeerTransport(session: destination.sessionForPeer(frame.from), peerID: frame.from)
    }
    func deliver(_ frame: ScannerControlledWire.Frame) async throws {
        let before = wire.history.count
        try await receiver(frame).receiveData(frame.data)
        if frame.sealed, let receipt = wire.history.dropFirst(before).first(where: { $0.from == frame.to && $0.to == frame.from }) {
            // Scanner emits its internal receipt synchronously before dispatch.
            // Consume that exact queued frame, leaving application responses for
            // the test. Assert the real gate classifies it as receipt-only.
            XCTAssertTrue(wire.remove(receipt))
            XCTAssertEqual(try receiver(receipt).gate.openPeerFrame(receipt.data), Data())
        }
    }
    func pump() -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                if let frame = wire.take() {
                    do {
                        let physical = try receiver(frame) // capture before dispatch, as the MC callback does
                        let received = physical.enqueueReceive(frame.data)
                        Task { do { try await received.value } catch { wire.failed(error) } }
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
        for _ in 0..<5 where pa.channelSession?.state != .authenticated || pb.channelSession?.state != .authenticated {
            try await deliverNext()
        }
        try await tasks.0.value; try await tasks.1.value
    }
    func stop() { a.stop(); b.stop(); c?.stop() }
}
final class ScannerControlledWire: @unchecked Sendable {
    struct Frame {
        let data: Data; let from: MCPeerID; let to: MCPeerID
        var sealed: Bool { data.starts(with: Data("HPC3".utf8)) }
        // M can parse all five envelopes, but only identity-free hello fields.
        // Application records have an explicit sentinel; M holds no keys.
        var command: BridgeCommand { (try? JSONDecoder().decode(BridgeCommand.self, from: data)) ?? BridgeCommand(cmd: "sealed", payload: nil, cid: 0) }
    }
    private let lock = NSLock()
    private var pending: [Frame] = [], recorded: [Frame] = []
    private var failures: [String] = []
    var errors: [String] { lock.withLock { failures } }
    func failed(_ error: Error) { lock.withLock { failures.append(String(describing: error)) } }
    var history: [Frame] { lock.withLock { recorded } }
    func append(_ data: Data, from: MCPeerID, to: MCPeerID) throws {
        let frame = Frame(data: data, from: from, to: to)
        lock.withLock { pending.append(frame); recorded.append(frame) }
    }
    func discard(between a: MCPeerID, and b: MCPeerID) {
        lock.withLock { pending.removeAll { ($0.from == a && $0.to == b) || ($0.from == b && $0.to == a) } }
    }
    func remove(_ frame: Frame) -> Bool {
        lock.withLock {
            guard let index = pending.firstIndex(where: { $0.data == frame.data && $0.from == frame.from && $0.to == frame.to }) else { return false }
            pending.remove(at: index); return true
        }
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
    func scannerFlowReceived(manager: ScannerService, flowElement: FlowElement, context: ScannerConsumerContext) async throws { lock.withLock { receivedFlows.append(flowElement) } }
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

private final class ScannerOnce: @unchecked Sendable {
    private let lock = NSLock(); private var available = true
    func take() -> Bool { lock.withLock { defer { available = false }; return available } }
}
private final class ScannerTitles: @unchecked Sendable {
    private let lock = NSLock(); private var titles: [String] = []
    var values: [String] { lock.withLock { titles } }
    func append(_ title: String) { lock.withLock { titles.append(title) } }
}

private final class ScannerSetupClock: @unchecked Sendable {
    private let lock = NSLock(); private var time: TimeInterval = 100
    var now: TimeInterval { lock.withLock { time } }
    func advance(_ delta: TimeInterval) { lock.withLock { time += delta } }
}
