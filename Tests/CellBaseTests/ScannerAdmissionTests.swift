// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import Foundation
import MultipeerConnectivity
import XCTest
@testable import CellApple
@testable import CellBase

final class ScannerAdmissionTests: XCTestCase {
    func testEachResourceEnforcesGlobalAndPhysicalSourceCountAndByteBoundaries() throws {
        for kind in ScannerAdmission.Kind.allCases {
            for dimension in ["count", "bytes", "sourceCount", "sourceBytes"] {
                var config = ScannerAdmission.Configuration()
                let budget = ScannerAdmission.Budget(count: dimension == "count" ? 2 : 10,
                    bytes: dimension == "bytes" ? 200 : 10000,
                    perSourceCount: dimension == "sourceCount" ? 1 : 10,
                    perSourceBytes: dimension == "sourceBytes" ? 100 : 1000, lifetime: 10)
                switch kind {
                case .discovery, .consumer: config.discovery = budget
                case .invitation: config.invitation = budget
                case .task: config.task = budget
                case .event: config.event = budget
                case .physical: config.physical = budget
                }
                let admission = ScannerAdmission(configuration: config)
                let b = MCPeerID(displayName: "B"), c = MCPeerID(displayName: "C"), d = MCPeerID(displayName: "D")
                let first = try XCTUnwrap(admission.reserve(kind, peer: b, bytes: 100))
                var second: ScannerAdmission.Lease?
                if dimension == "count" || dimension == "bytes" {
                    second = try XCTUnwrap(admission.reserve(kind, peer: c, bytes: 100))
                    XCTAssertNil(admission.reserve(kind, peer: d, bytes: dimension == "bytes" ? 1 : 100))
                } else {
                    XCTAssertNil(admission.reserve(kind, peer: b, bytes: dimension == "sourceBytes" ? 1 : 100))
                    second = try XCTUnwrap(admission.reserve(kind, peer: c, bytes: 100), "Independent source remains usable")
                }
                XCTAssertEqual(admission.snapshot(kind).count, 2)
                XCTAssertEqual(admission.snapshot(kind).bytes, 200)
                first.release(); first.release(); second?.release()
                XCTAssertEqual(admission.snapshot(kind).count, 0)
                XCTAssertEqual(admission.snapshot(kind).bytes, 0)
            }
        }
    }

    func testRateSourceTableAndLeaseLifetimeAreBoundedWithoutForgedUUIDBuckets() throws {
        let clock = ScannerAdmissionClock()
        var config = ScannerAdmission.Configuration()
        config.rate = 4; config.perSourceRate = 2; config.maximumSources = 3
        let admission = ScannerAdmission(configuration: config, now: { clock.now })
        let b = MCPeerID(displayName: "same label"), c = MCPeerID(displayName: "same label")
        for _ in 0..<2 { try XCTUnwrap(admission.reserve(.event, peer: b, bytes: 1)).release() }
        XCTAssertNil(admission.reserve(.event, peer: b, bytes: 1))
        try XCTUnwrap(admission.reserve(.event, peer: c, bytes: 1)).release()
        XCTAssertNil(admission.reserve(.event, peer: MCPeerID(displayName: "D"), bytes: 1))
        clock.advance(10)
        let held = try XCTUnwrap(admission.reserve(.task, peer: b, bytes: 1))
        clock.advance(10)
        XCTAssertFalse(held.isLive)
        XCTAssertEqual(admission.snapshot(.task).count, 1, "Executing noncooperative work stays charged after deadline")
        held.release()
        clock.advance(61)
        XCTAssertEqual(admission.sourceCount, 0)
        for _ in 0..<3 { try XCTUnwrap(admission.reserve(.event, peer: MCPeerID(displayName: "rotating"), bytes: 1)).release() }
        XCTAssertEqual(admission.sourceCount, 3)
        XCTAssertNil(admission.reserve(.event, peer: MCPeerID(displayName: "extra"), bytes: 1))
        XCTAssertEqual(admission.sourceCount, 3)
    }

    func testManyUniquePeersAndContextsAreBoundedBeforeStorageTasksOrUIAndRecoverAfterExpiry() async throws {
        let clock = ScannerAdmissionClock()
        var config = ScannerAdmission.Configuration()
        config.rate = 10000; config.perSourceRate = 100
        config.discovery.count = 12; config.invitation.count = 4; config.task.count = 3; config.event.count = 8
        let admission = ScannerAdmission(configuration: config, now: { clock.now })
        let service = ScannerService(admission: admission, owner: Identity(), invitationTimeout: 10, sessionUUID: "local")
        service.invitationClock = { clock.now }; service.deferEventDrainForTesting = true
        let observer = AdmissionObserver(); service.radarDelegate = observer
        defer { service.stop() }
        let local = MCPeerID(displayName: "local")
        let browser = MCNearbyServiceBrowser(peer: local, serviceType: "haven-radar")
        let advertiser = MCNearbyServiceAdvertiser(peer: local, discoveryInfo: nil, serviceType: "haven-radar")
        var peers: [MCPeerID] = []
        for i in 0..<1000 {
            let peer = MCPeerID(displayName: "peer-\(i)"); if i < 12 { peers.append(peer) }
            service.browser(browser, foundPeer: peer, withDiscoveryInfo: ["uuid": "remote-\(i)", "metadata": String(repeating: "x", count: 40)])
        }
        XCTAssertEqual(service.foundPeersDict.count, 12)
        XCTAssertEqual(admission.snapshot(.discovery).count, 12)
        XCTAssertEqual(service.queuedEventCount, 8)
        XCTAssertEqual(observer.found, 0, "No unadmitted UI publication")
        XCTAssertLessThanOrEqual(admission.sourceCount, config.maximumSources)
        await service.drainEventsForTesting()
        XCTAssertEqual(observer.found, 8)
        let responses = AdmissionResponses()
        for i in 0..<12 {
            let endpoint = try BridgePeerChannelAuthentication.Endpoint(initiator: "remote-\(i)", responder: "local", setupID: UUID().uuidString, domain: "nearby")
            service.advertiser(advertiser, didReceiveInvitationFromPeer: peers[i], withContext: try BridgeChannelAuthentication.encode(endpoint)) { accepted, _ in responses.add(accepted) }
        }
        XCTAssertEqual(service.pendingInvitationCount, 4)
        XCTAssertEqual(admission.snapshot(.invitation).count, 4)
        XCTAssertEqual(responses.values.count, 8)
        // Unknown contexts would formerly create a Task before any admission.
        for i in 0..<1000 {
            service.advertiser(advertiser, didReceiveInvitationFromPeer: peers[i % peers.count], withContext: Data("unknown-\(i)".utf8)) { accepted, _ in responses.add(accepted) }
        }
        XCTAssertEqual(admission.snapshot(.task).count, 3)
        XCTAssertLessThanOrEqual(service.queuedEventCount, config.event.count + config.task.count)
        XCTAssertLessThanOrEqual(admission.snapshot(.task).bytes, config.task.bytes)
        XCTAssertEqual(service.bridgeDelegateCount, 0)
        clock.advance(61); service.expireInvitations()
        XCTAssertEqual(service.pendingInvitationCount, 0)
        XCTAssertEqual(admission.snapshot(.invitation).count, 0)
        XCTAssertEqual(admission.snapshot(.task).count, 0)
        XCTAssertEqual(admission.snapshot(.discovery).count, 0)
        XCTAssertEqual(responses.values.count, 1012)
        XCTAssertTrue(responses.values.allSatisfy { !$0 })
        await service.drainEventsForTesting()
        clock.advance(61)
        XCTAssertEqual(admission.sourceCount, 0)
        let fresh = MCPeerID(displayName: "legitimate")
        service.browser(browser, foundPeer: fresh, withDiscoveryInfo: ["uuid": "fresh"])
        await service.drainEventsForTesting()
        let endpoint = try BridgePeerChannelAuthentication.Endpoint(initiator: "fresh", responder: "local", setupID: UUID().uuidString, domain: "nearby")
        service.advertiser(advertiser, didReceiveInvitationFromPeer: fresh, withContext: try BridgeChannelAuthentication.encode(endpoint)) { accepted, _ in responses.add(accepted) }
        await service.drainEventsForTesting()
        XCTAssertEqual(observer.invitations, 1, "Fresh invitation is actually published")
        XCTAssertTrue(service.respondToCurrentInvitationForTesting(remoteUUID: "fresh", accept: true))
        XCTAssertEqual(responses.values.last, true)
        service.stop()
        for kind in ScannerAdmission.Kind.allCases { XCTAssertEqual(admission.snapshot(kind).count, 0) }
    }

    func testOversizedMetadataContextAndRotatingUUIDCannotEvadeSourceBudget() async throws {
        let clock = ScannerAdmissionClock()
        var config = ScannerAdmission.Configuration(); config.perSourceRate = 6
        let admission = ScannerAdmission(configuration: config, now: { clock.now })
        let service = ScannerService(admission: admission, owner: Identity(), sessionUUID: "local")
        service.deferEventDrainForTesting = true
        defer { service.stop() }
        let peer = MCPeerID(displayName: "B"), local = MCPeerID(displayName: "local")
        let browser = MCNearbyServiceBrowser(peer: local, serviceType: "haven-radar")
        let advertiser = MCNearbyServiceAdvertiser(peer: local, discoveryInfo: nil, serviceType: "haven-radar")
        service.browser(browser, foundPeer: peer, withDiscoveryInfo: ["uuid": "bad", "huge": String(repeating: "x", count: 4097)])
        XCTAssertTrue(service.foundPeersDict.isEmpty)
        var rejected = false
        service.advertiser(advertiser, didReceiveInvitationFromPeer: peer, withContext: Data(repeating: 0, count: 4097)) { accepted, _ in rejected = !accepted }
        XCTAssertTrue(rejected); XCTAssertEqual(admission.sourceCount, 0)
        for i in 0..<100 { service.browser(browser, foundPeer: peer, withDiscoveryInfo: ["uuid": "rotated-\(i)"]) }
        XCTAssertEqual(admission.sourceCount, 1)
        XCTAssertEqual(service.foundPeersDict.count, 1)
        XCTAssertNotNil(service.foundPeersDict["rotated-2"])
        XCTAssertEqual(service.queuedEventCount, 3)
        let c = MCPeerID(displayName: "legitimate")
        service.browser(browser, foundPeer: c, withDiscoveryInfo: ["uuid": "legitimate"])
        service.receiveInvitation(from: c) { _, _ in }
        XCTAssertEqual(service.pendingInvitationCount, 1)
        service.stop()
        await service.drainEventsForTesting()
        XCTAssertEqual(service.queuedEventCount, 0)
    }

    func testGlobalBudgetIsSharedAcrossScannerInstances() {
        var config = ScannerAdmission.Configuration(); config.discovery.count = 1
        let admission = ScannerAdmission(configuration: config)
        let a = ScannerService(admission: admission, owner: Identity()), b = ScannerService(admission: admission, owner: Identity())
        defer { a.stop(); b.stop() }
        let browser = MCNearbyServiceBrowser(peer: MCPeerID(displayName: "local"), serviceType: "haven-radar")
        a.browser(browser, foundPeer: MCPeerID(displayName: "A"), withDiscoveryInfo: ["uuid": "A"])
        b.browser(browser, foundPeer: MCPeerID(displayName: "B"), withDiscoveryInfo: ["uuid": "B"])
        XCTAssertEqual(a.foundPeersDict.count, 1); XCTAssertEqual(b.foundPeersDict.count, 0)
        a.stop()
        b.browser(browser, foundPeer: MCPeerID(displayName: "B"), withDiscoveryInfo: ["uuid": "B"])
        XCTAssertEqual(b.foundPeersDict.count, 1)
    }
}

private final class ScannerAdmissionClock: @unchecked Sendable {
    private let lock = NSLock(); private var time: TimeInterval = 100
    var now: TimeInterval { lock.withLock { time } }
    func advance(_ delta: TimeInterval) { lock.withLock { time += delta } }
}
private final class AdmissionResponses: @unchecked Sendable {
    private let lock = NSLock(); private var replies: [Bool] = []
    var values: [Bool] { lock.withLock { replies } }
    func add(_ value: Bool) { lock.withLock { replies.append(value) } }
}
private final class AdmissionObserver: ConnectServiceDelegate {
    var found = 0; var invitations = 0
    func connectedDevicesChanged(manager: ScannerService, connectedDevices: [String]) {}
    func foundDevicesChanged(manager: ScannerService, foundDevice: MCPeerID, remoteUUID: String, discoveryInfo: [String: String]?) { found += 1 }
    func lostDeviceChanged(manager: ScannerService, lostDevice: MCPeerID, remoteUUID: String) {}
    func invitationReceived(manager: ScannerService, peerID: MCPeerID, remoteUUID: String) { invitations += 1 }
    func scannerStatusChanged(manager: ScannerService, status: String, remoteUUID: String?) {}
    func proximityChanged(manager: ScannerService, remoteUUID: String, distanceMeters: Float?, directionX: Float?, directionY: Float?, directionZ: Float?) {}
    func scannerFlowReceived(manager: ScannerService, flowElement: FlowElement, context: ScannerConsumerContext) async throws {}
}
