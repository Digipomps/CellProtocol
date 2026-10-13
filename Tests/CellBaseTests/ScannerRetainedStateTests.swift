// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import Foundation
import MultipeerConnectivity
import XCTest
@testable import CellApple
@testable import CellBase

final class ScannerRetainedStateTests: XCTestCase {
    @MainActor func testRealConsumerDiscoveryRotationLossAndExpiryRemainBoundedAcrossWindows() async throws {
        let clock = RetentionClock()
        var config = ScannerAdmission.Configuration()
        config.discovery.count = 4; config.discovery.bytes = 1400; config.event.count = 1
        let admission = ScannerAdmission(configuration: config, now: { clock.now })
        let service = ScannerService(admission: admission, owner: Identity(), sessionUUID: "local")
        service.deferEventDrainForTesting = true
        let cell = await EntityScannerCell(owner: service.owner)
        cell.connectService = service; service.radarDelegate = cell
        cell.configureProbeForTesting(.approved(entityKind: .person, purposeRefs: ["purpose://test"], interestRefs: []))
        defer { service.stop(); cell.connectService = nil; service.radarDelegate = nil }
        let browser = MCNearbyServiceBrowser(peer: MCPeerID(displayName: "local"), serviceType: "haven-radar")
        let rotating = MCPeerID(displayName: "rotating")
        func announce(_ peer: MCPeerID, _ id: String) {
            service.browser(browser, foundPeer: peer, withDiscoveryInfo: NearbyBeacon(sessionUUID: id, entityKind: .person,
                purposeTokens: [NearbyBeacon.token(forCanonicalReference: "purpose://test")]).encodeToDiscoveryInfo())
        }
        for window in 0..<20 {
            for index in 0..<4 {
                announce(rotating, "rotation-\(window)-\(index)")
                service.drainEventsForTesting()
                XCTAssertEqual(cell.retainedPeerStateForTesting.states, 1)
                XCTAssertEqual(cell.retainedPeerStateForTesting.beacons, 1)
                XCTAssertEqual(cell.retainedPeerStateForTesting.overlaps, 1)
                XCTAssertEqual(cell.retainedAuxiliaryStateForTesting.radarCount, 1)
                XCTAssertLessThanOrEqual(cell.retainedAuxiliaryStateForTesting.radarBytes, RadarEntityLedger.maximumBytes)
            }
            for index in 0..<8 {
                announce(MCPeerID(displayName: "peer-\(window)-\(index)"), "remote-\(window)-\(index)")
                service.drainEventsForTesting()
                XCTAssertLessThanOrEqual(cell.retainedPeerStateForTesting.states, config.discovery.count)
                XCTAssertLessThanOrEqual(cell.retainedPeerStateForTesting.bytes, config.discovery.bytes)
            }
            // Expiry cleanup must work even when the ordinary event budget is full.
            clock.advance(61); service.expireInvitations(); service.drainEventsForTesting()
            XCTAssertEqual(cell.retainedPeerStateForTesting.states, 0)
            XCTAssertEqual(cell.retainedPeerStateForTesting.beacons, 0)
            XCTAssertEqual(cell.retainedPeerStateForTesting.overlaps, 0)
            XCTAssertEqual(admission.snapshot(.discovery).count, 0)
            XCTAssertEqual(cell.retainedAuxiliaryStateForTesting.radarCount, 0)
        }
        announce(rotating, "legitimate"); service.drainEventsForTesting()
        XCTAssertEqual(cell.retainedPeerStateForTesting.states, 1)
        service.browser(browser, lostPeer: rotating); service.drainEventsForTesting()
        XCTAssertEqual(cell.retainedPeerStateForTesting.states, 0)
        announce(rotating, "after-loss"); service.drainEventsForTesting()
        XCTAssertEqual(cell.retainedPeerStateForTesting.states, 1)
        service.stop(); service.drainEventsForTesting()
        XCTAssertEqual(cell.retainedPeerStateForTesting.states, 0)
    }

    @MainActor func testConsumerBudgetIsGlobalWhileAnotherScannersCleanupIsHeld() async throws {
        let clock = RetentionClock()
        var config = ScannerAdmission.Configuration(); config.discovery.count = 2
        let admission = ScannerAdmission(configuration: config, now: { clock.now })
        let a = ScannerService(admission: admission, owner: Identity()), b = ScannerService(admission: admission, owner: Identity())
        a.deferEventDrainForTesting = true; b.deferEventDrainForTesting = true
        let ca = await EntityScannerCell(owner: a.owner), cb = await EntityScannerCell(owner: b.owner)
        ca.connectService = a; cb.connectService = b; a.radarDelegate = ca; b.radarDelegate = cb
        defer { a.stop(); b.stop(); a.drainEventsForTesting(); b.drainEventsForTesting(); a.radarDelegate = nil; b.radarDelegate = nil }
        let browser = MCNearbyServiceBrowser(peer: MCPeerID(displayName: "local"), serviceType: "haven-radar")
        let peers = (0..<2).map { MCPeerID(displayName: "a-\($0)") }
        for (i, peer) in peers.enumerated() {
            a.browser(browser, foundPeer: peer, withDiscoveryInfo: ["uuid": "a-\(i)"])
            a.drainEventsForTesting()
        }
        XCTAssertEqual(ca.retainedPeerStateForTesting.states, 2)
        // Replacement releases service admission, but cannot release the old
        // consumer's independently charged copies while its cleanup is held.
        for (i, peer) in peers.enumerated() {
            a.browser(browser, foundPeer: peer, withDiscoveryInfo: ["uuid": "replacement-\(i)"])
        }
        clock.advance(61); a.expireInvitations()
        XCTAssertEqual(admission.snapshot(.discovery).count, 0)
        // A's consumer still retains expired entries until its one cleanup drains.
        let peer = MCPeerID(displayName: "fresh")
        b.browser(browser, foundPeer: peer, withDiscoveryInfo: ["uuid": "fresh"]); b.drainEventsForTesting()
        XCTAssertEqual(admission.snapshot(.consumer).count, 2)
        XCTAssertEqual(cb.retainedPeerStateForTesting.states, 0)
        a.drainEventsForTesting()
        b.browser(browser, foundPeer: peer, withDiscoveryInfo: ["uuid": "fresh"]); b.drainEventsForTesting()
        XCTAssertEqual(ca.retainedPeerStateForTesting.states, 0)
        XCTAssertEqual(cb.retainedPeerStateForTesting.states, 1)
        XCTAssertEqual(admission.snapshot(.consumer).count, 1)
    }

    @MainActor func testTerminalStatusSurvivesFullEventQuotaAndStopIsIdempotentAcrossRestart() async throws {
        var config = ScannerAdmission.Configuration(); config.event.count = 1
        let service = ScannerService(admission: ScannerAdmission(configuration: config), owner: Identity())
        service.deferEventDrainForTesting = true
        let cell = await EntityScannerCell(owner: service.owner)
        cell.connectService = service
        let observer = RetentionObserver(cell); service.radarDelegate = observer
        defer { service.stop(); service.radarDelegate = nil; cell.connectService = nil }
        service.start(); service.drainEventsForTesting()
        XCTAssertEqual(observer.statuses, ["started"])
        let browser = MCNearbyServiceBrowser(peer: MCPeerID(displayName: "local"), serviceType: "haven-radar")
        let peer = MCPeerID(displayName: "old")
        service.browser(browser, foundPeer: peer, withDiscoveryInfo: ["uuid": "old"])
        XCTAssertEqual(service.queuedEventCount, 1)
        service.stop(); service.stop(); service.drainEventsForTesting()
        XCTAssertEqual(observer.statuses, ["started", "stopped"])
        service.start(); service.drainEventsForTesting()
        service.browser(browser, lostPeer: peer); service.drainEventsForTesting()
        XCTAssertEqual(observer.statuses, ["started", "stopped", "started"])
        service.stop(); service.start(); service.drainEventsForTesting()
        XCTAssertEqual(observer.statuses, ["started", "stopped", "started", "stopped", "started"])
    }

    @MainActor func testConnectedSnapshotIncludesSiblingAndOldCallbackCannotPublishAfterReconnect() async throws {
        // This test starts the real gates explicitly; deny unrelated Lobby setup work.
        var config = ScannerAdmission.Configuration(); config.task.count = 0
        let pair = try await ScannerPair(admissionA: ScannerAdmission(configuration: config)); defer { pair.stop() }
        try await pair.finish(pair.start()); try await pair.addThirdPeer()
        let cell = await EntityScannerCell(owner: pair.a.owner)
        cell.connectService = pair.a
        let observer = RetentionObserver(cell); pair.a.radarDelegate = observer
        pair.a.deferEventDrainForTesting = true
        defer { pair.a.radarDelegate = nil; cell.connectService = nil }
        let bSession = pair.pa.mcSession, cSession = pair.ac!.mcSession
        pair.a.session(bSession, peer: pair.bPeer, didChange: .connected)
        pair.a.session(cSession, peer: pair.cPeer, didChange: .connected)
        pair.a.drainEventsForTesting()
        XCTAssertEqual(pair.a.connectedDevices, ["test-b", "test-c"])
        XCTAssertEqual(observer.connections.last, ["test-b", "test-c"])
        // Keep an old connected callback queued, close B, and install B2.
        pair.a.session(bSession, peer: pair.bPeer, didChange: .connected)
        await pair.pa.gate.close(); await pair.pb.gate.close()
        pair.a.drainLifecycleForTesting()
        XCTAssertEqual(observer.connections.last, ["test-c"])
        let fresh = try pair.prepareReconnect()
        try await pair.authenticateTransports(fresh.0, fresh.1)
        let beforeHeldCallback = observer.connections.count
        pair.a.session(fresh.0.mcSession, peer: pair.bPeer, didChange: .connected)
        pair.a.drainEventsForTesting()
        XCTAssertEqual(observer.connections.last, ["test-b", "test-c"])
        XCTAssertEqual(observer.connections.count, beforeHeldCallback + 1, "Held old callback must not publish before its generation guard")
        let publications = observer.connections.count
        pair.a.session(bSession, peer: pair.bPeer, didChange: .notConnected)
        pair.a.session(bSession, peer: pair.bPeer, didChange: .connected)
        pair.a.drainEventsForTesting()
        XCTAssertEqual(observer.connections.count, publications, "Old physical generation cannot publish")
        XCTAssertEqual(pair.a.connectedDevices, ["test-b", "test-c"])
        XCTAssertEqual(pair.ac!.gate.session.state, .authenticated)
    }
}

private final class RetentionClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: TimeInterval = 100
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ delta: TimeInterval) { lock.withLock { value += delta } }
}
@MainActor private final class RetentionObserver: ConnectServiceDelegate {
    let cell: EntityScannerCell
    var statuses: [String] = []; var connections: [[String]] = []
    init(_ cell: EntityScannerCell) { self.cell = cell }
    func connectedDevicesChanged(manager: ScannerService, connectedDevices: [String]) {
        connections.append(connectedDevices); cell.connectedDevicesChanged(manager: manager, connectedDevices: connectedDevices)
    }
    func foundDevicesChanged(manager: ScannerService, foundDevice: MCPeerID, remoteUUID: String, discoveryInfo: [String: String]?) {
        cell.foundDevicesChanged(manager: manager, foundDevice: foundDevice, remoteUUID: remoteUUID, discoveryInfo: discoveryInfo)
    }
    func lostDeviceChanged(manager: ScannerService, lostDevice: MCPeerID, remoteUUID: String) {
        cell.lostDeviceChanged(manager: manager, lostDevice: lostDevice, remoteUUID: remoteUUID)
    }
    func invitationReceived(manager: ScannerService, peerID: MCPeerID, remoteUUID: String) {}
    func scannerStatusChanged(manager: ScannerService, status: String, remoteUUID: String?) {
        statuses.append(status); cell.scannerStatusChanged(manager: manager, status: status, remoteUUID: remoteUUID)
    }
    func scannerPeerStateChanged(manager: ScannerService) { cell.scannerPeerStateChanged(manager: manager) }
    func proximityChanged(manager: ScannerService, remoteUUID: String, distanceMeters: Float?, directionX: Float?, directionY: Float?, directionZ: Float?) {}
    func scannerFlowReceived(manager: ScannerService, flowElement: FlowElement, context: ScannerConsumerContext) async throws {}
}


extension ScannerRetainedStateTests {
    @MainActor func testCellStopPublishesTerminalStatusBeforeDroppingLastServiceOwner() async throws {
        let owner = await ScannerPair.owner()
        let cell = await EntityScannerCell(owner: owner)
        var statuses: [String] = []
        cell.consumerFlowForTesting = { event in
            if event.topic == "scanner.status", case let .object(value) = event.content,
               case let .string(status)? = value["status"] { statuses.append(status) }
        }
        cell.connectService = ScannerService(admission: ScannerAdmission(), owner: owner)
        cell.connectService?.deferEventDrainForTesting = true
        cell.connectService?.radarDelegate = cell
        weak var retired = cell.connectService
        _ = try await cell.set(keypath: "stop", value: .bool(true), requester: owner)
        XCTAssertEqual(statuses, ["stopped"])
        XCTAssertNil(cell.connectService)
        for _ in 0..<100 where retired != nil { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertNil(retired, "Terminal delivery must not need another long-lived service owner")
        _ = try await cell.set(keypath: "stop", value: .bool(true), requester: owner)
        XCTAssertEqual(statuses, ["stopped"])
    }

    @MainActor func testEveryOldServiceCallbackIsIgnoredAfterReplacement() async throws {
        let owner = await ScannerPair.owner()
        let cell = await EntityScannerCell(owner: owner)
        let old = ScannerService(admission: ScannerAdmission(), owner: owner)
        let fresh = ScannerService(admission: ScannerAdmission(), owner: owner)
        defer { old.stop(); fresh.stop(); cell.connectService = nil }
        old.deferEventDrainForTesting = true; fresh.deferEventDrainForTesting = true
        old.radarDelegate = cell; fresh.radarDelegate = cell; cell.connectService = old
        old.start(); old.stop()
        cell.connectService = fresh
        var events: [FlowElement] = []
        cell.consumerFlowForTesting = { events.append($0) }
        let peer = MCPeerID(displayName: "stale")
        old.drainEventsForTesting()
        cell.connectedDevicesChanged(manager: old, connectedDevices: ["stale"])
        cell.lostDeviceChanged(manager: old, lostDevice: peer, remoteUUID: "same-remote")
        cell.scannerStatusChanged(manager: old, status: "connected", remoteUUID: "same-remote")
        cell.proximityChanged(manager: old, remoteUUID: "same-remote", distanceMeters: 1, directionX: 1, directionY: 0, directionZ: 0)
        cell.scannerChannelRetired(manager: old, generation: "old")
        XCTAssertTrue(events.isEmpty)
        cell.scannerStatusChanged(manager: fresh, status: "started", remoteUUID: nil)
        XCTAssertEqual(events.count, 1)
    }
}
