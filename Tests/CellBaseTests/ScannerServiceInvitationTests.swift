import MultipeerConnectivity
import Foundation
import XCTest
@testable import CellApple
@testable import CellBase

final class ScannerServiceInvitationTests: XCTestCase {
    func testCrossedInvitationsSelectOneSetupAndRequireExplicitAcceptance() throws {
        let a = ScannerService(admission: ScannerAdmission(), owner: Identity(), sessionUUID: "a"), b = ScannerService(admission: ScannerAdmission(), owner: Identity(), sessionUUID: "b")
        defer { a.stop(); b.stop() }
        let ap = MCPeerID(displayName: "a"), bp = MCPeerID(displayName: "b")
        a.foundPeersDict["b"] = bp; a.reversedFoundPeersDict[bp] = "b"
        b.foundPeersDict["a"] = ap; b.reversedFoundPeersDict[ap] = "a"
        let outgoingA = try a.makeInvitation(remoteUUID: "b"), outgoingB = try b.makeInvitation(remoteUUID: "a")
        var toA: [Bool] = [], toB: [Bool] = []
        a.receiveInvitation(from: bp, endpoint: outgoingB) { accepted, _ in toA.append(accepted) }
        b.receiveInvitation(from: ap, endpoint: outgoingA) { accepted, _ in toB.append(accepted) }
        XCTAssertEqual(toA, [false]); XCTAssertTrue(toB.isEmpty)
        XCTAssertEqual(a.pendingInvitationCount, 0); XCTAssertEqual(b.pendingInvitationCount, 1)
        XCTAssertTrue(b.respondToInvitation(remoteUUID: "a", accept: true))
        XCTAssertEqual(toB, [true]); XCTAssertEqual(b.pendingInvitationCount, 0)
        XCTAssertEqual(a.bridgeDelegateCount, 0); XCTAssertEqual(b.bridgeDelegateCount, 0)
    }

    func testUnknownPeerIsRejectedImmediately() {
        let service = ScannerService(admission: ScannerAdmission(), owner: Identity())
        let peer = MCPeerID(displayName: "unknown")
        var response: Bool?

        service.receiveInvitation(from: peer) { accepted, _ in response = accepted }

        XCTAssertEqual(response, false)
        XCTAssertEqual(service.pendingInvitationCount, 0)
        service.stop()
    }

    func testKnownInvitationRequiresExplicitResponse() {
        let service = ScannerService(admission: ScannerAdmission(), owner: Identity())
        let peer = MCPeerID(displayName: "known")
        service.foundPeersDict["remote"] = peer
        service.reversedFoundPeersDict[peer] = "remote"
        var response: Bool?

        service.receiveInvitation(from: peer) { accepted, _ in response = accepted }

        XCTAssertNil(response)
        XCTAssertEqual(service.pendingInvitationCount, 1)
        XCTAssertTrue(service.respondToInvitation(remoteUUID: "remote", accept: true))
        XCTAssertEqual(response, true)
        XCTAssertEqual(service.pendingInvitationCount, 0)
        service.stop()
    }

    func testInvitationTimeoutRejects() async {
        let service = ScannerService(admission: ScannerAdmission(), owner: Identity(), invitationTimeout: 0.02)
        let peer = MCPeerID(displayName: "timeout")
        service.foundPeersDict["remote"] = peer
        service.reversedFoundPeersDict[peer] = "remote"
        let rejected = expectation(description: "timeout rejected")

        service.receiveInvitation(from: peer) { accepted, _ in
            XCTAssertFalse(accepted)
            rejected.fulfill()
        }

        await fulfillment(of: [rejected], timeout: 1)
        XCTAssertEqual(service.pendingInvitationCount, 0)
        service.stop()
    }

    func testStopRejectsPendingAndIsIdempotent() {
        let service = ScannerService(admission: ScannerAdmission(), owner: Identity())
        let peer = MCPeerID(displayName: "pending")
        service.foundPeersDict["remote"] = peer
        service.reversedFoundPeersDict[peer] = "remote"
        var responses = [Bool]()
        service.receiveInvitation(from: peer) { accepted, _ in responses.append(accepted) }

        service.stop()
        service.stop()

        XCTAssertEqual(responses, [false])
        XCTAssertEqual(service.pendingInvitationCount, 0)
        XCTAssertEqual(service.bridgeDelegateCount, 0)
    }

    func testConcurrentInvitationsAreEachResolvedExactlyOnce() {
        let service = ScannerService(admission: ScannerAdmission(), owner: Identity())
        let peer = MCPeerID(displayName: "concurrent")
        service.foundPeersDict["remote"] = peer
        service.reversedFoundPeersDict[peer] = "remote"
        let responseLock = NSLock()
        var responses = [Bool]()

        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            service.receiveInvitation(from: peer) { accepted, _ in
                responseLock.lock()
                responses.append(accepted)
                responseLock.unlock()
            }
        }
        service.stop()

        responseLock.lock()
        let responseSnapshot = responses
        responseLock.unlock()
        XCTAssertEqual(responseSnapshot.count, 100)
        XCTAssertTrue(responseSnapshot.allSatisfy { !$0 })
        XCTAssertEqual(service.pendingInvitationCount, 0)
    }
}

extension ScannerServiceInvitationTests {
    func testInvitationOwnsPeerSessionAndEndpointAcrossDiscoveryLossBeforeAndAfterAcceptance() async throws {
        for state in ["pending", "accepted", "outgoing"] {
            let vault = MockIdentityVault(), owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
            let service = ScannerService(admission: ScannerAdmission(), owner: owner, sessionUUID: "local")
            defer { service.stop() }
            let b = MCPeerID(displayName: "B"), c = MCPeerID(displayName: "C")
            let browser = MCNearbyServiceBrowser(peer: MCPeerID(displayName: "local"), serviceType: "haven-radar")
            service.browser(browser, foundPeer: b, withDiscoveryInfo: ["uuid": "remote"])
            var session: MCSession?
            var replies: [Bool] = []
            let endpoint: BridgePeerChannelAuthentication.Endpoint
            if state == "outgoing" { endpoint = try service.makeInvitation(remoteUUID: "remote") }
            else {
                endpoint = try BridgePeerChannelAuthentication.Endpoint(initiator: "remote", responder: "local", setupID: UUID().uuidString, domain: "nearby")
                service.receiveInvitation(from: b, endpoint: endpoint) { accepted, captured in
                    replies.append(accepted)
                    if accepted { XCTAssertTrue(captured === session) }
                }
                session = try service.sessionForPeer(b)
                if state == "accepted" { XCTAssertTrue(service.respondToInvitation(remoteUUID: "remote", accept: true)) }
            }
            session = try service.sessionForPeer(b)
            service.browser(browser, lostPeer: b)
            service.browser(browser, foundPeer: c, withDiscoveryInfo: ["uuid": "remote"])
            service.browser(browser, foundPeer: b, withDiscoveryInfo: ["uuid": "retargeted"])
            XCTAssertNil(service.foundPeersDict["remote"])
            XCTAssertNil(service.foundPeersDict["retargeted"])
            XCTAssertThrowsError(try service.capturePeerTransport(session: try XCTUnwrap(session), peerID: c, prepare: true))
            if state == "pending" { XCTAssertTrue(service.respondToInvitation(remoteUUID: "remote", accept: true)) }
            let physical = try service.capturePeerTransport(session: try XCTUnwrap(session), peerID: b, prepare: true)
            XCTAssertEqual(physical.peerID, b); XCTAssertTrue(physical.mcSession === session)
            XCTAssertEqual(physical.channelSession?.peerEndpoint, endpoint)
            XCTAssertEqual(physical.role, state == "outgoing" ? .initiator : .responder)
            XCTAssertEqual(service.retainedInvitationCount, 0)
            if state != "outgoing" { XCTAssertEqual(replies, [true]) }
            service.browser(browser, foundPeer: b, withDiscoveryInfo: ["uuid": "remote"])
            XCTAssertEqual(service.foundPeersDict["remote"], b)
        }
    }

    func testAcceptanceTransitionExcludesDeterministicDiscoveryAndStopRace() async throws {
        for race in ["collision", "stop"] {
            let vault = MockIdentityVault(), owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
            let service = ScannerService(admission: ScannerAdmission(), owner: owner, sessionUUID: "local")
            defer { service.stop() }
            let b = MCPeerID(displayName: "B"), c = MCPeerID(displayName: "C")
            let browser = MCNearbyServiceBrowser(peer: MCPeerID(displayName: "local"), serviceType: "haven-radar")
            service.browser(browser, foundPeer: b, withDiscoveryInfo: ["uuid": "remote"])
            let endpoint = try BridgePeerChannelAuthentication.Endpoint(initiator: "remote", responder: "local", setupID: UUID().uuidString, domain: "nearby")
            var replies: [Bool] = []
            service.receiveInvitation(from: b, endpoint: endpoint) { accepted, _ in replies.append(accepted) }
            service.browser(browser, lostPeer: b)
            let entered = expectation(description: "inside old remove/install window")
            let competing = expectation(description: "competing callback attempts state lock")
            let accepted = expectation(description: "accept finished"), finished = expectation(description: "competing callback finished")
            let release = DispatchSemaphore(value: 0)
            service.duringInvitationAcceptance = { entered.fulfill(); _ = release.wait(timeout: .now() + 3) }
            DispatchQueue.global().async {
                XCTAssertTrue(service.respondToInvitation(remoteUUID: "remote", accept: true)); accepted.fulfill()
            }
            await fulfillment(of: [entered], timeout: 2)
            DispatchQueue.global().async {
                competing.fulfill()
                if race == "collision" { service.browser(browser, foundPeer: c, withDiscoveryInfo: ["uuid": "remote"]) }
                else { service.stop() }
                finished.fulfill()
            }
            await fulfillment(of: [competing], timeout: 2)
            release.signal()
            await fulfillment(of: [accepted, finished], timeout: 2)
            XCTAssertEqual(replies, [true])
            XCTAssertNil(service.foundPeersDict["remote"])
            if race == "collision" {
                XCTAssertEqual(try service.capturePeerTransport(session: service.sessionForPeer(b), peerID: b, prepare: true).peerID, b)
            } else {
                XCTAssertEqual(service.retainedInvitationCount, 0)
                XCTAssertThrowsError(try service.prepareBridge(remoteUUID: "remote", peerID: b))
            }
        }
    }

    func testDiscoveryCallbackAtFormerRemoveInstallBoundaryCannotRetargetAcceptance() throws {
        let service = ScannerService(admission: ScannerAdmission(), owner: Identity(), sessionUUID: "local")
        defer { service.stop() }
        let b = MCPeerID(displayName: "B"), c = MCPeerID(displayName: "C")
        let browser = MCNearbyServiceBrowser(peer: MCPeerID(displayName: "local"), serviceType: "haven-radar")
        service.browser(browser, foundPeer: b, withDiscoveryInfo: ["uuid": "remote"])
        let endpoint = try BridgePeerChannelAuthentication.Endpoint(initiator: "remote", responder: "local", setupID: UUID().uuidString, domain: "nearby")
        var replies = [Bool]()
        service.receiveInvitation(from: b, endpoint: endpoint) { accepted, _ in replies.append(accepted) }
        service.duringInvitationAcceptance = {
            // Reentrant adversarial callback at the exact old gap. No sleep or
            // scheduler luck: pending still owns B until accepted owns B.
            service.browser(browser, lostPeer: b)
            service.browser(browser, foundPeer: c, withDiscoveryInfo: ["uuid": "remote"])
            XCTAssertNil(service.foundPeersDict["remote"])
            XCTAssertEqual(service.retainedInvitationCount, 1)
        }
        XCTAssertTrue(service.respondToInvitation(remoteUUID: "remote", accept: true))
        service.duringInvitationAcceptance = nil
        XCTAssertEqual(replies, [true]); XCTAssertEqual(service.retainedInvitationCount, 1)
        XCTAssertThrowsError(try service.prepareBridge(remoteUUID: "remote", peerID: c))
    }

    func testLateUnboundDisconnectCannotRetireNewInvitationOnSamePhysicalPeer() throws {
        let service = ScannerService(admission: ScannerAdmission(), owner: Identity(), invitationTimeout: 10, sessionUUID: "local")
        defer { service.stop() }
        var now: TimeInterval = 100; service.invitationClock = { now }
        let b = MCPeerID(displayName: "B")
        let browser = MCNearbyServiceBrowser(peer: MCPeerID(displayName: "local"), serviceType: "haven-radar")
        service.browser(browser, foundPeer: b, withDiscoveryInfo: ["uuid": "remote"])
        _ = try service.makeInvitation(remoteUUID: "remote")
        let oldSession = try service.sessionForPeer(b)
        now = 110; service.expireInvitations()
        let fresh = try BridgePeerChannelAuthentication.Endpoint(initiator: "remote", responder: "local", setupID: UUID().uuidString, domain: "nearby")
        var replies = [Bool]()
        service.receiveInvitation(from: b, endpoint: fresh) { accepted, _ in replies.append(accepted) }
        service.session(oldSession, peer: b, didChange: .notConnected)
        XCTAssertEqual(service.pendingInvitationCount, 1); XCTAssertEqual(replies, [])
        XCTAssertTrue(service.respondToInvitation(remoteUUID: "remote", accept: true))
        XCTAssertEqual(replies, [true])
    }

    func testPendingAcceptedAndOutgoingExpiryAllowsNewValidInvitationWithoutOldSetup() throws {
        for state in ["pending", "accepted", "outgoing"] {
            let service = ScannerService(admission: ScannerAdmission(), owner: Identity(), invitationTimeout: 10, sessionUUID: "local")
            defer { service.stop() }
            var now: TimeInterval = 100
            service.invitationClock = { now }
            let b = MCPeerID(displayName: "B"), c = MCPeerID(displayName: "C")
            let browser = MCNearbyServiceBrowser(peer: MCPeerID(displayName: "local"), serviceType: "haven-radar")
            service.browser(browser, foundPeer: b, withDiscoveryInfo: ["uuid": "remote"])
            var replies: [Bool] = []
            if state == "outgoing" { _ = try service.makeInvitation(remoteUUID: "remote") }
            else {
                let endpoint = try BridgePeerChannelAuthentication.Endpoint(initiator: "remote", responder: "local", setupID: UUID().uuidString, domain: "nearby")
                service.receiveInvitation(from: b, endpoint: endpoint) { accepted, _ in replies.append(accepted) }
                if state == "accepted" { XCTAssertTrue(service.respondToInvitation(remoteUUID: "remote", accept: true)) }
            }
            service.browser(browser, lostPeer: b)
            now = 110; service.expireInvitations()
            XCTAssertEqual(service.retainedInvitationCount, 0)
            XCTAssertThrowsError(try service.capturePeerTransport(session: service.sessionForPeer(b), peerID: b, prepare: true))
            if state == "pending" { XCTAssertEqual(replies, [false]) }
                if state == "accepted" { XCTAssertEqual(replies, [true]) }
            service.browser(browser, foundPeer: c, withDiscoveryInfo: ["uuid": "remote"])
            let fresh = try service.makeInvitation(remoteUUID: "remote")
            XCTAssertEqual(fresh.responder, "remote")
            service.expireInvitations() // old deadline cannot retire the new instance
            XCTAssertEqual(service.retainedInvitationCount, 1)
            service.stop()
            XCTAssertEqual(service.retainedInvitationCount, 0)
            XCTAssertFalse(service.respondToInvitation(remoteUUID: "remote", accept: true))
        }
    }
}
