#if os(macOS)
import Foundation
import Combine
import MultipeerConnectivity
import XCTest
@testable import CellApple
@testable import CellBase

/// Opt-in hardware/OS integration; no test wire or preconnected MCSession.
final class ScannerMultipeerProcessTests: XCTestCase {
    func testTwoProcessesUseRealMultipeerInBothInvitationDirections() async throws {
        guard ProcessInfo.processInfo.environment["CP53_MULTIPEER_TEST"] == "1" else {
            throw XCTSkip("Run CP53_MULTIPEER_TEST=1 swift test --filter ScannerMultipeerProcessTests/testTwoProcessesUseRealMultipeerInBothInvitationDirections on a Mac with local network access")
        }
        for inviter in ["a", "b"] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cp53-multipeer-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            print("CP53 Multipeer artifacts: \(folder.path), inviter=\(inviter)")
            var processes: [(Process, FileHandle)] = []
            defer { for (process, file) in processes { if process.isRunning { process.terminate() }; try? file.close() } }
            for role in ["a", "b"] {
                let log = folder.appendingPathComponent("\(role).log")
                FileManager.default.createFile(atPath: log.path, contents: nil)
                let handle = try FileHandle(forWritingTo: log), process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                process.arguments = ["xctest", "-XCTest", "CellBaseTests.ScannerMultipeerProcessTests/testMultipeerWorker", Bundle(for: Self.self).bundlePath]
                var environment = ProcessInfo.processInfo.environment
                environment["CP53_PEER_DIRECTORY"] = folder.path; environment["CP53_PEER_ROLE"] = role; environment["CP53_PEER_INVITER"] = inviter
                process.environment = environment; process.standardOutput = handle; process.standardError = handle
                try process.run(); processes.append((process, handle))
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 35
            while processes.contains(where: { $0.0.isRunning }), ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            for (process, handle) in processes {
                try handle.synchronize()
                XCTAssertFalse(process.isRunning, "Multipeer worker timed out; artifacts \(folder.path)")
                if !process.isRunning { XCTAssertEqual(process.terminationStatus, 0, "Worker failed; artifacts \(folder.path)") }
            }
            for role in ["a", "b"] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(role).passed").path), "Missing proof/function result; \(folder.path)")
            }
        }
        try await runPhysicalIsolationProcesses()
        try await runRelayProcesses()
    }

    func testMultipeerWorker() async throws {
        let env = ProcessInfo.processInfo.environment
        if let role = env["CP53_RELAY_ROLE"], let path = env["CP53_PEER_DIRECTORY"] {
            try await runRelayWorker(role: role, folder: URL(fileURLWithPath: path))
            return
        }
        if let role = env["CP53_ISOLATION_ROLE"], let path = env["CP53_PEER_DIRECTORY"] {
            try await runPhysicalIsolationWorker(role: role, folder: URL(fileURLWithPath: path))
            return
        }
        guard let path = env["CP53_PEER_DIRECTORY"], let role = env["CP53_PEER_ROLE"], let inviter = env["CP53_PEER_INVITER"] else {
            throw XCTSkip("Child worker of real Multipeer process test")
        }
        let folder = URL(fileURLWithPath: path), other = role == "a" ? "b" : "a"
        let vault = MockIdentityVault()
        var owner = Identity(UUID().uuidString, displayName: "Synthetic peer", identityVault: vault)
        await vault.addIdentity(identity: &owner, for: "multipeer-test")
        CellBase.defaultIdentityVault = vault
        try BridgeChannelAuthentication.encode(BridgeChannelAuthentication.PublicIdentity(owner)).write(to: folder.appendingPathComponent("\(role).public"), options: .atomic)
        let publicURL = folder.appendingPathComponent("\(other).public"), deadline = ProcessInfo.processInfo.systemUptime + 5
        while !FileManager.default.fileExists(atPath: publicURL.path), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let remote = try BridgeChannelAuthentication.decode(BridgeChannelAuthentication.PublicIdentity.self, from: Data(contentsOf: publicURL)).makeIdentity()
        XCTAssertNil(remote.identityVault)
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        let lobby = await LobbyCell(owner: owner), scanner = await GeneralCell(owner: owner)
        lobby.agreementTemplate.ensureGrant("r---", for: "feed")
        // Explicit test-host publication policy; admission still requests the
        // remote GeneralCell origin proof over the authenticated peer channel.
        lobby.agreementAdmissionPolicy = .ownerPublishedRead
        for (name, cell) in [("Lobby", lobby as GeneralCell), ("EntityScanner", scanner), ("ConnectRadar", scanner)] {
            try await resolver.registerNamedEmitCell(name: name, emitCell: cell, scope: .template, identity: owner)
        }
        let localID = folder.lastPathComponent + role, remoteID = folder.lastPathComponent + other
        let service = ScannerService(owner: owner, sessionUUID: localID)
        let observer = MultipeerProcessObserver(expectedPeer: remoteID, inviter: inviter == role)
        service.radarDelegate = observer
        let feed = expectation(description: "real Lobby attach/feed")
        let expected = "marker-\(inviter)"
        let subscription = scanner.getFeedPublisher().first { element in
            if case let .string(value) = element.content { return value == expected }; return false
        }.sink(receiveCompletion: { _ in }, receiveValue: { _ in feed.fulfill() })
        defer { subscription.cancel(); service.stop() }
        service.start()
        let connectedDeadline = ProcessInfo.processInfo.systemUptime + 20
        while !observer.connected, ProcessInfo.processInfo.systemUptime < connectedDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(observer.connected, "No authenticated Scanner setup: \(observer.statuses)")
        guard observer.connected else { feed.fulfill(); await fulfillment(of: [feed], timeout: 1); return }
        let sender = Task {
            for _ in 0..<20 {
                if inviter == role { lobby.pushFlowElement(FlowElement(title: "probe", content: .string(expected), properties: .init(type: .content, contentType: .string)), requester: owner) }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        await fulfillment(of: [feed], timeout: 4)
        await sender.value
        XCTAssertFalse(observer.statuses.contains { $0.hasPrefix("bridgeFailed:") })
        let peerID = try XCTUnwrap(service.foundPeersDict[remoteID])
        let physical = try service.capturePeerTransport(session: service.sessionForPeer(peerID), peerID: peerID)
        let records = try XCTUnwrap(physical.gate.peerRecordCounts)
        XCTAssertGreaterThan(records.sent, 1, "Real MC must send sealed application records after confirmation")
        XCTAssertGreaterThan(records.received, 1, "Real MC must receive sealed application records after confirmation")
        try Data("authenticated; description; attach; feed; sealedSent=\(records.sent); sealedReceived=\(records.received)\n".utf8).write(to: folder.appendingPathComponent("\(role).passed"))
        // Keep the inviter alive until its receiver has recorded delivery.
        let doneDeadline = ProcessInfo.processInfo.systemUptime + 4
        while !FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(other).passed").path), ProcessInfo.processInfo.systemUptime < doneDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
    }
}
private final class MultipeerProcessObserver: ConnectServiceDelegate {
    let expectedPeer: String, inviter: Bool
    private let lock = NSLock(); private var values: [String] = []; private var invited = false
    init(expectedPeer: String, inviter: Bool) { self.expectedPeer = expectedPeer; self.inviter = inviter }
    var statuses: [String] { lock.withLock { values } }
    var connected: Bool { statuses.contains("connected") }
    func scannerStatusChanged(manager: ScannerService, status: String, remoteUUID: String?) { lock.withLock { values.append(status) } }
    func connectedDevicesChanged(manager: ScannerService, connectedDevices: [String]) {}
    func foundDevicesChanged(manager: ScannerService, foundDevice: MCPeerID, remoteUUID: String, discoveryInfo: [String: String]?) {
        guard remoteUUID == expectedPeer, inviter else { return }
        let shouldInvite = lock.withLock { if invited { return false }; invited = true; return true }
        if shouldInvite { manager.invitePeer(remoteUUID) }
    }
    func invitationReceived(manager: ScannerService, peerID: MCPeerID, remoteUUID: String) {
        _ = manager.respondToInvitation(remoteUUID: remoteUUID, accept: remoteUUID == expectedPeer && !inviter)
    }
    func lostDeviceChanged(manager: ScannerService, lostDevice: MCPeerID, remoteUUID: String) {}
    func proximityChanged(manager: ScannerService, remoteUUID: String, distanceMeters: Float?, directionX: Float?, directionY: Float?, directionZ: Float?) {}
    func scannerFlowReceived(manager: ScannerService, flowElement: FlowElement, context: ScannerConsumerContext) async throws {}
}
#endif
