import MultipeerConnectivity
import Foundation
import XCTest
@testable import CellApple
@testable import CellBase

final class ScannerServiceInvitationTests: XCTestCase {
    func testCrossedInvitationsSelectOneSetupAndRequireExplicitAcceptance() throws {
        let a = ScannerService(owner: Identity(), sessionUUID: "a"), b = ScannerService(owner: Identity(), sessionUUID: "b")
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
        let service = ScannerService(owner: Identity())
        let peer = MCPeerID(displayName: "unknown")
        var response: Bool?

        service.receiveInvitation(from: peer) { accepted, _ in response = accepted }

        XCTAssertEqual(response, false)
        XCTAssertEqual(service.pendingInvitationCount, 0)
        service.stop()
    }

    func testKnownInvitationRequiresExplicitResponse() {
        let service = ScannerService(owner: Identity())
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
        let service = ScannerService(owner: Identity(), invitationTimeout: 0.02)
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
        let service = ScannerService(owner: Identity())
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
        let service = ScannerService(owner: Identity())
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
