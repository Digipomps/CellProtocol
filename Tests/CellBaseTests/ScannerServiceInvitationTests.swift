import MultipeerConnectivity
import Foundation
import XCTest
@testable import CellApple
@testable import CellBase

final class ScannerServiceInvitationTests: XCTestCase {
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
