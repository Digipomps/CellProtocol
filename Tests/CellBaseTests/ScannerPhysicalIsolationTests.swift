#if os(macOS)
import Foundation
import MultipeerConnectivity
import XCTest
import Darwin
@testable import CellApple
@testable import CellBase

extension ScannerMultipeerProcessTests {
    func runPhysicalIsolationProcesses() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cp53-isolation-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        print("CP53 physical isolation artifacts: \(folder.path)")
        var children: [(Process, FileHandle)] = []
        defer { for (child, file) in children { if child.isRunning { child.terminate() }; try? file.close() } }
        for role in ["a", "b", "c"] {
            let log = folder.appendingPathComponent("\(role).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let file = try FileHandle(forWritingTo: log), child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            child.arguments = ["xctest", "-XCTest", "CellBaseTests.ScannerMultipeerProcessTests/testMultipeerWorker", Bundle(for: Self.self).bundlePath]
            var env = ProcessInfo.processInfo.environment
            env["CP53_ISOLATION_ROLE"] = role; env["CP53_PEER_DIRECTORY"] = folder.path
            child.environment = env; child.standardOutput = file; child.standardError = file
            try child.run(); children.append((child, file))
        }
        try await isolationWait(seconds: 55) { children.allSatisfy { !$0.0.isRunning } }
        for (child, file) in children { try file.synchronize(); XCTAssertEqual(child.terminationStatus, 0, folder.path) }
        for role in ["a", "b", "c"] { XCTAssertTrue(isolationExists(folder, "\(role).passed"), folder.path) }
    }

    func runPhysicalIsolationWorker(role: String, folder: URL) async throws {
        let prefix = folder.lastPathComponent
        if role == "b" {
            try await isolationWait { isolationExists(folder, "c.ready") }
            let resource = folder.appendingPathComponent("unsolicited-resource")
            FileManager.default.createFile(atPath: resource.path, contents: nil)
            let file = try FileHandle(forWritingTo: resource); try file.truncate(atOffset: 64 * 1024 * 1024); try file.close()
            for phase in ["resource", "streams", "expiry"] {
                let attacker = IsolationRawPeer(local: prefix + "b" + phase, target: prefix + "a")
                attacker.start(); defer { attacker.stop() }
                try await isolationWait { attacker.connected }
                let peer = try XCTUnwrap(attacker.remote)
                var outputs: [OutputStream] = []
                if phase == "resource" {
                    let progress = try XCTUnwrap(attacker.session.sendResource(at: resource, withName: "unsolicited", toPeer: peer) { error in
                        attacker.resourceFinished(error: error)
                    })
                    XCTAssertEqual(progress.totalUnitCount, 64 * 1024 * 1024)
                } else if phase == "streams" {
                    for i in 0..<32 {
                        if let stream = try? attacker.session.startStream(withName: "unused-\(i)", toPeer: peer) { stream.open(); outputs.append(stream) }
                    }
                    XCTAssertFalse(outputs.isEmpty)
                }
                // Raw peer ignores ALL application messages and never voluntarily
                // closes. Only the receiver's supported MC disconnect can evict it.
                try await isolationWait(seconds: 15) { attacker.disconnected }
                XCTAssertTrue(attacker.session.connectedPeers.isEmpty)
                XCTAssertThrowsError(try attacker.session.send(Data([1]), toPeers: [peer], with: .reliable))
                for stream in outputs { stream.close() }
                if phase == "resource" {
                    try await isolationWait { attacker.resourceComplete }
                    XCTAssertTrue(attacker.resourceFailed)
                }
                try isolationMark(folder, "\(phase).done", "remote observed physical disconnect; ignored app messages; openedStreams=\(outputs.count)")
                try await isolationWait { isolationExists(folder, "\(phase).checked") }
                attacker.stop()
            }
            try isolationMark(folder, "b.passed", "64MiB resource; stream burst; natural handshake expiry; rejected send after close")
            return
        }
        let vault = MockIdentityVault()
        var owner = Identity(UUID().uuidString, displayName: "Isolation fixture", identityVault: vault)
        await vault.addIdentity(identity: &owner, for: "isolation")
        CellBase.defaultIdentityVault = vault
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        let lobby = await LobbyCell(owner: owner), scanner = await GeneralCell(owner: owner)
        lobby.agreementTemplate.ensureGrant("r---", for: "feed"); lobby.agreementAdmissionPolicy = .ownerPublishedRead
        for (name, cell) in [("Lobby", lobby as GeneralCell), ("EntityScanner", scanner), ("ConnectRadar", scanner)] {
            try await resolver.registerNamedEmitCell(name: name, emitCell: cell, scope: .template, identity: owner)
        }
        let service = ScannerService(admission: ScannerAdmission(), owner: owner, sessionUUID: prefix + role)
        let observer = IsolationObserver(prefix: prefix, host: role == "a")
        service.radarDelegate = observer; service.start(); defer { service.stop() }
        if role == "c" {
            try await isolationWait { observer.connected }
            try isolationMark(folder, "c.ready", "authenticated sibling")
            var sent = 0
            while !isolationExists(folder, "a.passed") && sent < 400 {
                try await service.sendScannerFlowElement(FlowElement(title: "healthy-\(sent)", content: .string("live"), properties: .init(type: .event, contentType: .string)), remoteUUID: prefix + "a")
                sent += 1; try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertTrue(isolationExists(folder, "a.passed"))
            XCTAssertTrue(service.isConnected(remoteUUID: prefix + "a"))
            try isolationMark(folder, "c.passed", "continued sibling records=\(sent); rss=\(isolationRSS())")
        } else {
            try await isolationWait { observer.flows > 0 }
            let baseline = isolationRSS()
            for phase in ["resource", "streams", "expiry"] {
                let before = observer.flows
                try await isolationWait(seconds: 20) { isolationExists(folder, "\(phase).done") }
                try await isolationWait { service.retainedPhysicalCount == 1 && observer.flows > before }
                XCTAssertTrue(service.isConnected(remoteUUID: prefix + "c"))
                XCTAssertEqual(service.admission.snapshot(.physical).count, 1)
                try isolationMark(folder, "\(phase).checked", "physical=1; siblingFlows=\(observer.flows); rss=\(isolationRSS()); baselineRSS=\(baseline)")
            }
            try isolationMark(folder, "a.passed", "isolated retirement verified in three OS processes; siblingFlows=\(observer.flows); rss=\(isolationRSS())")
        }
    }
}

private func isolationExists(_ folder: URL, _ name: String) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }
private func isolationMark(_ folder: URL, _ name: String, _ value: String) throws { try Data(value.utf8).write(to: folder.appendingPathComponent(name), options: .atomic) }
private func isolationWait(seconds: Double = 10, _ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while !condition() && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    guard condition() else { throw NSError(domain: "CP53 physical isolation timeout", code: 1) }
}
private func isolationRSS() -> UInt64 {
    var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}
private final class IsolationObserver: ConnectServiceDelegate {
    let prefix: String, host: Bool
    private let lock = NSLock(); private var ready = false; private var count = 0; private var invited = false
    init(prefix: String, host: Bool) { self.prefix = prefix; self.host = host }
    var connected: Bool { lock.withLock { ready } }
    var flows: Int { lock.withLock { count } }
    func foundDevicesChanged(manager: ScannerService, foundDevice: MCPeerID, remoteUUID: String, discoveryInfo: [String: String]?) {
        if !host && remoteUUID == prefix + "a" && lock.withLock({ if invited { return false }; invited = true; return true }) { manager.invitePeer(remoteUUID) }
    }
    func invitationReceived(manager: ScannerService, peerID: MCPeerID, remoteUUID: String) { _ = manager.respondToInvitation(remoteUUID: remoteUUID, accept: host && remoteUUID.hasPrefix(prefix)) }
    func scannerStatusChanged(manager: ScannerService, status: String, remoteUUID: String?) { if status == "connected" { lock.withLock { ready = true } } }
    func scannerFlowReceived(manager: ScannerService, flowElement: FlowElement, remoteUUID: String?) { if remoteUUID == prefix + "c" { lock.withLock { count += 1 } } }
    func connectedDevicesChanged(manager: ScannerService, connectedDevices: [String]) {}
    func lostDeviceChanged(manager: ScannerService, lostDevice: MCPeerID, remoteUUID: String) {}
    func proximityChanged(manager: ScannerService, remoteUUID: String, distanceMeters: Float?, directionX: Float?, directionY: Float?, directionZ: Float?) {}
}

private final class IsolationRawPeer: NSObject, MCNearbyServiceBrowserDelegate, MCSessionDelegate {
    let session: MCSession
    private let browser: MCNearbyServiceBrowser, advertiser: MCNearbyServiceAdvertiser
    private let local: String, target: String
    private let lock = NSLock(); private var peer: MCPeerID?; private var up = false; private var down = false
    private var finished = false; private var failed = false; private var invited = false
    init(local: String, target: String) {
        self.local = local; self.target = target
        let id = MCPeerID(displayName: "raw-\(UUID().uuidString.prefix(8))")
        session = MCSession(peer: id, securityIdentity: nil, encryptionPreference: .required)
        browser = MCNearbyServiceBrowser(peer: id, serviceType: "haven-radar")
        advertiser = MCNearbyServiceAdvertiser(peer: id, discoveryInfo: ["uuid": local], serviceType: "haven-radar")
        super.init(); browser.delegate = self; session.delegate = self
    }
    var connected: Bool { lock.withLock { up } }
    var disconnected: Bool { lock.withLock { down } }
    var remote: MCPeerID? { lock.withLock { peer } }
    var resourceComplete: Bool { lock.withLock { finished } }
    var resourceFailed: Bool { lock.withLock { failed } }
    func resourceFinished(error: Error?) { lock.withLock { finished = true; failed = error != nil } }
    func start() { advertiser.startAdvertisingPeer(); browser.startBrowsingForPeers() }
    func stop() { advertiser.stopAdvertisingPeer(); browser.stopBrowsingForPeers(); session.disconnect() }
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard info?["uuid"] == target, lock.withLock({ if invited { return false }; invited = true; peer = peerID; return true }) else { return }
        let endpoint = try! BridgePeerChannelAuthentication.Endpoint(initiator: local, responder: target, setupID: UUID().uuidString, domain: "nearby")
        browser.invitePeer(peerID, to: session, withContext: try! BridgeChannelAuthentication.encode(endpoint), timeout: 10)
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        lock.withLock { if state == .connected { up = true }; if state == .notConnected && up { down = true } }
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {} // deliberately ignores app close/auth
    func session(_ session: MCSession, didReceive stream: InputStream, withName: String, fromPeer: MCPeerID) { stream.close() }
    func session(_ session: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with progress: Progress) { progress.cancel() }
    func session(_ session: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at: URL?, withError: Error?) {}
}
#endif
