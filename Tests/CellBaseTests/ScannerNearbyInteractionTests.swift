// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import Foundation
import MultipeerConnectivity
import XCTest
@testable import CellApple
@testable import CellBase
#if os(iOS)
import NearbyInteraction
#endif

final class ScannerNearbyInteractionTests: XCTestCase {
    @MainActor func testConcurrentPeersKeepTokensSessionsAndResultsOnTheirAuthenticatedPeer() async throws {
        let f = try await NIFixture(third: true); defer { f.pair.stop() }
        try await f.connect(f.pair.b)
        try await f.connect(f.pair.c!)
        XCTAssertEqual(f.aDrivers.count, 2)
        let b = f.aDrivers[0], c = f.aDrivers[1]
        XCTAssertNotEqual(b.token, c.token)
        XCTAssertEqual(b.runs, [f.bDrivers[0].token])
        XCTAssertEqual(c.runs, [f.cDrivers[0].token])
        f.pair.a.connectedRemoteUUID = f.pair.b.mySessionUUID // old erroneous lookup
        c.emit(.measurement(.init(distance: 3, x: nil, y: nil, z: nil)))
        b.emit(.measurement(.init(distance: 1, x: nil, y: nil, z: nil)))
        f.pair.a.drainEventsForTesting()
        XCTAssertEqual(f.observer.results.map(\.0), [f.pair.c!.mySessionUUID, f.pair.b.mySessionUUID])
        XCTAssertEqual(f.observer.results.compactMap(\.1), [3, 1])
        // Exact duplicate does not run again; neither a new generation nor a
        // second token may overwrite an established NI configuration.
        let incoming = try f.token(from: f.pair.b)
        try await f.receive(incoming)
        XCTAssertEqual(b.runs.count, 1)
        for field in ["token", "niGeneration"] {
            var changed = incoming
            changed[field] = field == "token" ? .data(Data("different".utf8)) : .string(UUID().uuidString)
            do { try await f.receive(changed); XCTFail("Replacement token accepted") } catch {}
        }
        XCTAssertEqual(b.runs, [f.bDrivers[0].token])
        try f.pair.pa.gate.session.check(); try f.pair.ac!.gate.session.check()
    }

    @MainActor func testPrincipalSetupTargetAndVersionRejectBeforeCreatingOrRunningNI() async throws {
        let f = try await NIFixture(third: true); defer { f.pair.stop() }
        let original = try f.token(from: f.pair.b, token: Data("synthetic-token".utf8))
        for (field, value) in ["userUuid": ValueType.string(f.pair.c!.owner.uuid),
                               "setupID": .string(UUID().uuidString), "targetSession": .string("another-device"),
                               "niVersion": .integer(0), "niGeneration": .string("invalid"), "token": .data(Data()),
                               "unknown": .bool(true)] {
            var changed = original; changed[field] = value
            do { try await f.receive(changed); XCTFail("Bad \(field) accepted") } catch {}
            XCTAssertEqual(f.aDrivers.count, 0)
        }
        // Valid B metadata on C's authenticated transport is still not B.
        let contextC = try f.pair.a.consumerContext(remoteUUID: f.pair.c!.mySessionUUID)
        do { try await f.receive(original, context: contextC); XCTFail("Cross-peer token accepted") } catch {}
        XCTAssertEqual(f.aDrivers.count, 0)
        try await f.connect(f.pair.b)
        XCTAssertEqual(f.aDrivers.count, 1)
    }

    @MainActor func testWrongTokenBindingOnRealWireClosesOnlyOffendingChannel() async throws {
        let f = try await NIFixture(third: true); defer { f.pair.stop() }
        try await f.connect(f.pair.b); try await f.connect(f.pair.c!)
        var forged = try f.token(from: f.pair.b)
        forged["userUuid"] = .string(f.pair.c!.owner.uuid)
        let flow = FlowElement(title: "DiscoveryToken", content: .object(forged), properties: .init(type: .event, contentType: .object))
        try await f.pair.b.sendScannerFlowElement(flow, context: f.pair.b.consumerContext(remoteUUID: f.pair.a.mySessionUUID))
        do { try await f.pair.deliverNext(); XCTFail("Authenticated B relabelled its token as C") } catch {}
        XCTAssertThrowsError(try f.pair.pa.gate.session.check())
        XCTAssertEqual(f.aDrivers[0].invalidations, 1)
        XCTAssertEqual(f.aDrivers[0].runs.count, 1)
        try f.pair.ac!.gate.session.check()
        f.aDrivers[1].emit(.measurement(.init(distance: 2, x: nil, y: nil, z: nil)))
        f.pair.a.drainEventsForTesting()
        XCTAssertEqual(f.observer.results.map(\.0), [f.pair.c!.mySessionUUID])
    }

    @MainActor func testCloseRevokeDisconnectAndStopInvalidateAndDiscardQueuedAndLateCallbacks() async throws {
        for mode in ["close", "revoke", "disconnect", "stop"] {
            let f = try await NIFixture(third: true); defer { f.pair.stop() }
            try await f.connect(f.pair.b); try await f.connect(f.pair.c!)
            let old = f.aDrivers[0], sibling = f.aDrivers[1], late = old.captureCallback()
            old.emit(.measurement(.init(distance: 8, x: nil, y: nil, z: nil)))
            switch mode {
            case "close": await f.pair.pa.gate.close()
            case "revoke": f.pair.pa.gate.session.revoke()
            case "disconnect": f.pair.a.peerDisconnected(f.pair.pa)
            default: f.pair.a.stop()
            }
            old.deliver(late, .measurement(.init(distance: 9, x: nil, y: nil, z: nil)))
            for event in [ScannerNIEvent.resumed, .timeout, .invalidated, .ended, .suspended] { old.deliver(late, event) }
            f.pair.a.drainEventsForTesting()
            XCTAssertTrue(f.observer.results.isEmpty, mode)
            XCTAssertEqual(old.invalidations, 1, mode)
            XCTAssertEqual(old.runs.count, 1, mode)
            if mode != "stop" {
                sibling.emit(.measurement(.init(distance: 2, x: nil, y: nil, z: nil)))
                f.pair.a.drainEventsForTesting()
                XCTAssertEqual(f.observer.results.map(\.0), [f.pair.c!.mySessionUUID], mode)
                XCTAssertEqual(sibling.invalidations, 0, mode)
            }
        }
    }

    @MainActor func testReconnectRejectsOldTokenContextAndCallbacksWithoutTouchingNewSession() async throws {
        let f = try await NIFixture(); defer { f.pair.stop() }
        try await f.connect(f.pair.b)
        let oldContext = try f.pair.a.consumerContext(remoteUUID: f.pair.b.mySessionUUID)
        let oldToken = try f.token(from: f.pair.b), old = f.aDrivers[0], late = old.captureCallback()
        await f.pair.pa.gate.close(); await f.pair.pb.gate.close()
        let fresh = try f.pair.prepareReconnect()
        try await f.pair.authenticateTransports(fresh.0, fresh.1)
        try await f.connect(f.pair.b)
        XCTAssertEqual(f.aDrivers.count, 2)
        let current = f.aDrivers[1]
        XCTAssertNotEqual(old.token, current.token)
        do { try await f.receive(oldToken); XCTFail("Prior invitation token accepted") } catch {}
        do { try await f.receive(oldToken, context: oldContext); XCTFail("Retired context accepted") } catch {}
        for event in [ScannerNIEvent.resumed, .timeout, .ended, .invalidated, .measurement(.init(distance: 99, x: nil, y: nil, z: nil))] {
            old.deliver(late, event)
        }
        current.emit(.measurement(.init(distance: 4, x: nil, y: nil, z: nil)))
        f.pair.a.drainEventsForTesting()
        XCTAssertEqual(f.observer.results.compactMap(\.1), [4])
        XCTAssertEqual(current.runs.count, 1); XCTAssertEqual(current.invalidations, 0)
        try fresh.0.gate.session.check()
    }

    @MainActor func testSuspensionTimeoutAndInvalidationNeverCreateReplacementSessionOrReuseOldCallback() async throws {
        let f = try await NIFixture(); defer { f.pair.stop() }
        try await f.connect(f.pair.b)
        let driver = f.aDrivers[0], late = driver.captureCallback()
        driver.emit(.suspended)
        driver.emit(.measurement(.init(distance: 99, x: nil, y: nil, z: nil)))
        f.pair.a.drainEventsForTesting(); XCTAssertTrue(f.observer.results.isEmpty)
        driver.emit(.resumed); driver.emit(.timeout)
        XCTAssertEqual(driver.runs, Array(repeating: f.bDrivers[0].token, count: 3))
        driver.emit(.invalidated)
        try await f.pair.a.startNearbyInteraction(context: f.pair.a.consumerContext(remoteUUID: f.pair.b.mySessionUUID))
        driver.deliver(late, .resumed)
        XCTAssertEqual(f.aDrivers.count, 1); XCTAssertEqual(driver.invalidations, 1)
        XCTAssertEqual(driver.runs.count, 3)
    }

#if os(iOS)
    func testPlatformTokenDecoderRejectsMalformedArchiveWithoutNIHardware() {
        XCTAssertThrowsError(try AppleScannerNISession.decodeToken(Data("not-an-archive".utf8)))
    }
#endif
}

private final class FakeNISession: ScannerNISession {
    let queue: DispatchQueue
    let token = Data(UUID().uuidString.utf8)
    var localToken: Data { token }
    var event: ((ScannerNIEvent) -> Void)?
    private var runTokens: [Data] = []
    private var invalidationCount = 0
    init(queue: DispatchQueue) { self.queue = queue }
    func run(token: Data) throws { dispatchPrecondition(condition: .onQueue(queue)); runTokens.append(token) }
    func invalidate() { dispatchPrecondition(condition: .onQueue(queue)); invalidationCount += 1 }
    var runs: [Data] { queue.sync { runTokens } }
    var invalidations: Int { queue.sync { invalidationCount } }
    func captureCallback() -> ((ScannerNIEvent) -> Void)? { queue.sync { event } }
    func emit(_ value: ScannerNIEvent) { queue.sync { event?(value) } }
    func deliver(_ callback: ((ScannerNIEvent) -> Void)?, _ value: ScannerNIEvent) { queue.sync { callback?(value) } }
}

@MainActor private final class NIFixture {
    let pair: ScannerPair
    let observer = NIObserver()
    private let drivers = NIDrivers()
    var aDrivers: [FakeNISession] { drivers.get("a") }
    var bDrivers: [FakeNISession] { drivers.get("b") }
    var cDrivers: [FakeNISession] { drivers.get("c") }
    init(third: Bool = false) async throws {
        pair = try await ScannerPair(); try await pair.finish(pair.start())
        if third { try await pair.addThirdPeer() }
        for (name, service) in [("a", pair.a), ("b", pair.b), ("c", pair.c)] {
            service?.setNearbySessionFactoryForTesting { [drivers] queue in
                let driver = FakeNISession(queue: queue); drivers.add(name, driver); return driver
            }
        }
        pair.a.deferEventDrainForTesting = true
        pair.a.radarDelegate = observer
    }
    func connect(_ other: ScannerService) async throws {
        let incoming = try pair.a.consumerContext(remoteUUID: other.mySessionUUID)
        incoming.physical.beforeOrderedDispatch = { [drivers, remote = other.mySessionUUID] command in
            if case let .flowElement(flow) = command.payload, flow.title == "DiscoveryToken", case let .object(content) = flow.content {
                drivers.record(remote, content)
            }
        }
        try await pair.a.startNearbyInteraction(context: pair.a.consumerContext(remoteUUID: other.mySessionUUID))
        try await pair.deliverNext(); try await pair.deliverNext()
    }
    func token(from sender: ScannerService, token: Data? = nil) throws -> Object {
        let context = try sender.consumerContext(remoteUUID: pair.a.mySessionUUID)
        if token == nil { return try XCTUnwrap(drivers.content(sender.mySessionUUID)) }
        guard case let .object(content) = ScannerNearbyInteraction.tokenFlow(token!, generation: UUID(), context: context).content else { throw CancellationError() }
        return content
    }
    func receive(_ content: Object, context: ScannerConsumerContext? = nil) async throws {
        let target = try context ?? pair.a.consumerContext(remoteUUID: pair.b.mySessionUUID)
        let flow = FlowElement(title: "DiscoveryToken", content: .object(content), properties: .init(type: .event, contentType: .object))
        try await pair.a.handleOutOfBandFlowElement(flow, context: target)
    }
}
private final class NIDrivers: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: [FakeNISession]] = [:]
    private var tokens: [String: Object] = [:]
    func record(_ name: String, _ content: Object) { lock.withLock { tokens[name] = content } }
    func content(_ name: String) -> Object? { lock.withLock { tokens[name] } }
    func add(_ name: String, _ driver: FakeNISession) { lock.withLock { storage[name, default: []].append(driver) } }
    func get(_ name: String) -> [FakeNISession] { lock.withLock { storage[name, default: []] } }
}
@MainActor private final class NIObserver: ConnectServiceDelegate {
    var results: [(String, Float?)] = []
    func connectedDevicesChanged(manager: ScannerService, connectedDevices: [String]) {}
    func foundDevicesChanged(manager: ScannerService, foundDevice: MCPeerID, remoteUUID: String, discoveryInfo: [String: String]?) {}
    func lostDeviceChanged(manager: ScannerService, lostDevice: MCPeerID, remoteUUID: String) {}
    func invitationReceived(manager: ScannerService, peerID: MCPeerID, remoteUUID: String) {}
    func scannerStatusChanged(manager: ScannerService, status: String, remoteUUID: String?) {}
    func proximityChanged(manager: ScannerService, remoteUUID: String, distanceMeters: Float?, directionX: Float?, directionY: Float?, directionZ: Float?) { results.append((remoteUUID, distanceMeters)) }
    func scannerFlowReceived(manager: ScannerService, flowElement: FlowElement, context: ScannerConsumerContext) async throws {}
}
