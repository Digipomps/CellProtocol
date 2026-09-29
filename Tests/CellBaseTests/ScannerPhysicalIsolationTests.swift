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
        try await isolationWait(seconds: 100) { children.allSatisfy { !$0.0.isRunning } }
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
                try await isolationWait { attacker.remote != nil && isolationExists(folder, "discovered-" + phase) }
                try attacker.invite()
                try await isolationWait { attacker.connected }
                let peer = try XCTUnwrap(attacker.remote)
                var outputs: [OutputStream] = []
                if phase == "resource" {
                    _ = try XCTUnwrap(attacker.session.sendResource(at: resource, withName: "unsolicited", toPeer: peer) { error in
                        attacker.resourceFinished(error: error)
                    })
                    XCTAssertEqual(try resource.resourceValues(forKeys: [.fileSizeKey]).fileSize, 64 * 1024 * 1024)
                } else if phase == "streams" {
                    for i in 0..<32 {
                        if let stream = try? attacker.session.startStream(withName: "unused-\(i)", toPeer: peer) { stream.open(); outputs.append(stream) }
                    }
                    XCTAssertFalse(outputs.isEmpty)
                }
                // Raw peer ignores ALL application messages and never voluntarily
                // closes. Only the receiver's supported MC disconnect can evict it.
                // MC does not promise when the remote observes disconnect. Use
                // the same physical-state observation/window as the authenticated
                // phases; a delayed delegate callback is not retained authority.
                let retirementStarted = ProcessInfo.processInfo.systemUptime
                try await isolationWait(seconds: 60) { attacker.session.connectedPeers.isEmpty }
                XCTAssertTrue(attacker.session.connectedPeers.isEmpty)
                XCTAssertThrowsError(try attacker.session.send(Data([1]), toPeers: [peer], with: .reliable))
                for stream in outputs { stream.close() }
                // MC's sender completion can lag disconnect; receiver-side
                // cancellation and both physical endpoints are asserted instead.
                try isolationMark(folder, "\(phase).done", "remote observed physical disconnect; ignored app messages; openedStreams=\(outputs.count); resourceCompletionObserved=\(attacker.resourceComplete) resourceFailed=\(attacker.resourceFailed); disconnectCallback=\(attacker.disconnected); observedAfterSeconds=\(ProcessInfo.processInfo.systemUptime - retirementStarted)")
                try await isolationWait { isolationExists(folder, "\(phase).checked") }
                attacker.stop()
            }
            for phase in ["revoke", "blocked"] {
                let (service, observer) = try await isolationService(prefix: prefix, role: "b" + phase, folder: folder)
                service.start(); defer { service.stop() }
                try await isolationWait { service.foundPeersDict[prefix + "a"] != nil && isolationExists(folder, "discovered-" + phase) }
                service.invitePeer(prefix + "a")
                try await isolationWait { observer.connected && isolationExists(folder, "host-ready-" + phase) }
                let peer = try XCTUnwrap(service.foundPeersDict[prefix + "a"])
                let session = try service.sessionForPeer(peer), ignored = IsolationIgnoringReceiver()
                let physical = try service.capturePeerTransport(session: session, peerID: peer)
                // Both full Scanner setups must drain their application records
                // before B stops receipts. Otherwise a startup record can occupy
                // one of the 32 slots and make the host's 32nd load send wait
                // until the production ten-second deadline correctly closes it.
                try await isolationWait { physical.gate.peerOutstandingUsage.dataRecords == 0 && isolationExists(folder, "host-drained-" + phase) }
                session.delegate = ignored // deliberately stops app receipt/close processing
                try isolationMark(folder, phase + ".ready", "authenticated; ignoring app traffic")
                let waitStarted = ProcessInfo.processInfo.systemUptime
                var lastSecond = -1
                try await isolationWait(seconds: 60) {
                    let second = Int(ProcessInfo.processInfo.systemUptime)
                    if second != lastSecond {
                        lastSecond = second
                        print("CP53 remote \(phase) peers=\(session.connectedPeers.count) callback=\(ignored.disconnected) records=\(ignored.receivedRecords) bytes=\(ignored.receivedBytes)")
                    }
                    // The supported physical state is authoritative even when
                    // a callback was queued to the previous Scanner delegate.
                    return session.connectedPeers.isEmpty
                }
                XCTAssertTrue(session.connectedPeers.isEmpty)
                XCTAssertThrowsError(try session.send(Data([1]), toPeers: [peer], with: .reliable))
                if phase == "revoke" {
                    for i in 0..<32 {
                        XCTAssertThrowsError(try session.startStream(withName: "after-revoke-\(i)", toPeer: peer))
                    }
                    let rejected = session.sendResource(at: resource, withName: "after-revoke", toPeer: peer) { error in
                        ignored.resourceFinished(error: error)
                    }
                    if rejected != nil { try await isolationWait { ignored.resourceFailed } }
                    try isolationMark(folder, "revoke.side-entrances", "32 stream attempts rejected; 64MiB resource rejected after physical revoke")
                }
                if phase == "blocked" { XCTAssertGreaterThan(ignored.receivedRecords, 0) }
                try isolationMark(folder, phase + ".done", "physical disconnect; observedAfterSeconds=\(ProcessInfo.processInfo.systemUptime - waitStarted); callback=\(ignored.disconnected); receivedRecords=\(ignored.receivedRecords) bytes=\(ignored.receivedBytes)")
                try await isolationWait { isolationExists(folder, phase + ".checked") }
                service.stop()
            }
            try isolationMark(folder, "b.passed", "64MiB resource; stream burst; expiry; authenticated revoke; missing receipt timeout; post-close sends rejected")
            return
        }
        let (service, observer) = try await isolationService(prefix: prefix, role: role, folder: folder)
        service.start(); defer { service.stop() }
        if role == "c" {
            try await isolationWait { observer.connected }
            try isolationMark(folder, "c.ready", "authenticated sibling")
            var sent = 0
            while !isolationExists(folder, "a.passed") && sent < 1200 {
                try await service.sendScannerFlowElement(FlowElement(title: "healthy-\(sent)", content: .string("live"), properties: .init(type: .event, contentType: .string)), remoteUUID: prefix + "a")
                sent += 1
                if sent % 8 == 0, let peer = service.foundPeersDict[prefix + "a"], let transport = try? service.capturePeerTransport(session: service.sessionForPeer(peer), peerID: peer) {
                    print("CP53 healthy sent=\(sent) outstanding=\(transport.gate.peerOutstandingUsage) wire=\(String(describing: transport.gate.peerRecordCounts))")
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertTrue(isolationExists(folder, "a.passed"))
            XCTAssertTrue(service.isConnected(remoteUUID: prefix + "a"))
            try isolationMark(folder, "c.passed", "continued sibling records=\(sent); rss=\(isolationRSS())")
        } else {
            try await isolationWait { observer.flows > 0 }
            let baseline = isolationRSS()
            let sibling = try XCTUnwrap(service.foundPeersDict[prefix + "c"])
            let siblingNames = [sibling.displayName]
            for phase in ["resource", "streams", "expiry"] {
                let before = observer.flows
                try await isolationWait(seconds: 65) { isolationExists(folder, "\(phase).done") }
                try await isolationWait { service.retainedPhysicalCount == 1 && observer.flows > before && observer.connectionNames == siblingNames }
                let remainingNames = await MainActor.run { service.connectedDevices }
                XCTAssertEqual(remainingNames, siblingNames)
                XCTAssertTrue(service.isConnected(remoteUUID: prefix + "c"))
                XCTAssertEqual(service.admission.snapshot(.physical).count, 1)
                if phase == "resource" { XCTAssertGreaterThan(observer.cancelledResources, 0) }
                if phase == "streams" { XCTAssertGreaterThan(observer.closedStreams, 0) }
                try isolationMark(folder, "\(phase).checked", "physical=1; siblingFlows=\(observer.flows); rss=\(isolationRSS()); baselineRSS=\(baseline); cancelledResources=\(observer.cancelledResources); closedStreams=\(observer.closedStreams)")
            }
            for phase in ["revoke", "blocked"] {
                try await isolationWait { isolationExists(folder, "host-ready-" + phase) }
                let before = observer.flows
                let peer = try XCTUnwrap(service.foundPeersDict[prefix + "b" + phase])
                let physical = try service.capturePeerTransport(session: service.sessionForPeer(peer), peerID: peer)
                let bothNames = [peer.displayName, sibling.displayName].sorted()
                try await isolationWait { physical.gate.peerOutstandingUsage.dataRecords == 0 && observer.connectionNames == bothNames }
                let publishedNames = await MainActor.run { service.connectedDevices }
                XCTAssertEqual(publishedNames, bothNames)
                XCTAssertTrue(physical.mcSession.connectedPeers.contains(peer))
                XCTAssertTrue(try service.sessionForPeer(sibling).connectedPeers.contains(sibling))
                try isolationMark(folder, "connections-" + phase, "two owned MC sessions; published=\(bothNames)")
                try isolationMark(folder, "host-drained-" + phase, "startup application records receipted")
                try await isolationWait { isolationExists(folder, phase + ".ready") }
                if phase == "revoke" {
                    service.channelLimits.revoke(identity: try XCTUnwrap(physical.gate.session.publicIdentity), domain: "nearby")
                } else {
                    let rss = isolationRSS()
                    for i in 0..<32 {
                        try await service.sendScannerFlowElement(FlowElement(title: "blocked-\(i)", content: .string(String(repeating: "q", count: 48 * 1024)), properties: .init(type: .event, contentType: .string)), remoteUUID: prefix + "b" + phase)
                    }
                    let usage = physical.gate.peerOutstandingUsage
                    XCTAssertEqual(usage.dataRecords, 32); XCTAssertGreaterThan(usage.bytes, 32 * 48 * 1024)
                    let heldRSS = isolationRSS()
                    XCTAssertLessThan(heldRSS, rss + 64 * 1024 * 1024)
                    try isolationMark(folder, "blocked.full", "records=\(usage.records) bytes=\(usage.bytes) rssBefore=\(rss) rssHeld=\(heldRSS)")
                }
                var lastSecond = -1
                try await isolationWait(seconds: 65) {
                    let second = Int(ProcessInfo.processInfo.systemUptime)
                    if second != lastSecond {
                        lastSecond = second
                        print("CP53 waiting \(phase) state=\(physical.gate.session.state) usage=\(physical.gate.peerOutstandingUsage) progress=\(physical.gate.peerProgressDiagnostics) peers=\(physical.mcSession.connectedPeers.count)")
                    }
                    return isolationExists(folder, phase + ".done")
                }
                try await isolationWait { service.retainedPhysicalCount == 1 && observer.flows > before && observer.connectionNames == siblingNames }
                let remainingNames = await MainActor.run { service.connectedDevices }
                XCTAssertEqual(remainingNames, siblingNames)
                XCTAssertTrue(physical.mcSession.connectedPeers.isEmpty)
                XCTAssertEqual(physical.gate.peerOutstandingUsage.bytes, 0)
                XCTAssertTrue(service.isConnected(remoteUUID: prefix + "c"))
                try isolationMark(folder, phase + ".checked", "physical=1; siblingFlows=\(observer.flows); rss=\(isolationRSS())")
            }
            try isolationMark(folder, "a.passed", "isolated retirement verified in three OS processes; siblingFlows=\(observer.flows); rss=\(isolationRSS())")
            try await isolationWait { isolationExists(folder, "c.passed") }
        }
    }
}

private func isolationService(prefix: String, role: String, folder: URL) async throws -> (ScannerService, IsolationObserver) {
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
        let observer = IsolationObserver(prefix: prefix, host: role == "a", autoInvite: role == "c", folder: folder)
        service.radarDelegate = observer
        service.sideEntranceRejectedForTesting = { kind, disposed in
            XCTAssertTrue(disposed, "Unused MC entrance must dispose at first callback")
            observer.disposed(kind)
        }
        return (service, observer)
    }

private final class IsolationIgnoringReceiver: NSObject, MCSessionDelegate {
    private let lock = NSLock(); private var down = false; private var records = 0; private var bytes = 0
    private var failedResource = false
    var disconnected: Bool { lock.withLock { down } }
    var receivedRecords: Int { lock.withLock { records } }
    var receivedBytes: Int { lock.withLock { bytes } }
    var resourceFailed: Bool { lock.withLock { failedResource } }
    func resourceFinished(error: Error?) { lock.withLock { failedResource = error != nil } }
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) { if state == .notConnected { lock.withLock { down = true } } }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) { lock.withLock { records += 1; bytes += data.count } }
    func session(_ session: MCSession, didReceive stream: InputStream, withName: String, fromPeer: MCPeerID) { stream.close() }
    func session(_ session: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with progress: Progress) { progress.cancel() }
    func session(_ session: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at: URL?, withError: Error?) {}
}

private func isolationExists(_ folder: URL, _ name: String) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }
private func isolationMark(_ folder: URL, _ name: String, _ value: String) throws { try Data(value.utf8).write(to: folder.appendingPathComponent(name), options: .atomic) }
private func isolationWait(seconds: Double = 10, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while !condition() && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    guard condition() else { throw NSError(domain: "CP53 physical isolation timeout", code: Int(line), userInfo: [NSLocalizedDescriptionKey: "timeout at \(file):\(line)"]) }
}
func isolationRSS() -> UInt64 {
    var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}
private final class IsolationObserver: ConnectServiceDelegate {
    let prefix: String, host: Bool, autoInvite: Bool
    let folder: URL
    private let lock = NSLock(); private var ready = false; private var count = 0; private var invited = false
    init(prefix: String, host: Bool, autoInvite: Bool, folder: URL) { self.prefix = prefix; self.host = host; self.autoInvite = autoInvite; self.folder = folder }
    private var resources = 0, streams = 0
    private var names: [String] = []
    var connectionNames: [String] { lock.withLock { names } }
    var cancelledResources: Int { lock.withLock { resources } }
    var closedStreams: Int { lock.withLock { streams } }
    func disposed(_ kind: String) { lock.withLock { if kind == "resource" { resources += 1 } else { streams += 1 } } }
    var connected: Bool { lock.withLock { ready } }
    var flows: Int { lock.withLock { count } }
    func foundDevicesChanged(manager: ScannerService, foundDevice: MCPeerID, remoteUUID: String, discoveryInfo: [String: String]?) {
        print("CP53 discovery host=\(host) remote=\(remoteUUID)")
        if host && remoteUUID.hasPrefix(prefix + "b") {
            try? isolationMark(folder, "discovered-" + remoteUUID.dropFirst(prefix.count + 1), "host observed raw peer")
        }
        if autoInvite && remoteUUID == prefix + "a" && lock.withLock({ if invited { return false }; invited = true; return true }) { manager.invitePeer(remoteUUID) }
    }
    func invitationReceived(manager: ScannerService, peerID: MCPeerID, remoteUUID: String) { print("CP53 invitation \(remoteUUID)"); _ = manager.respondToInvitation(remoteUUID: remoteUUID, accept: host && remoteUUID.hasPrefix(prefix)) }
    func scannerStatusChanged(manager: ScannerService, status: String, remoteUUID: String?) {
        print("CP53 status \(status) remote=\(remoteUUID ?? "nil")")
        if status == "connected" {
            lock.withLock { ready = true }
            if host, let remoteUUID, remoteUUID.hasPrefix(prefix + "b") {
                try? isolationMark(folder, "host-ready-" + remoteUUID.dropFirst(prefix.count + 1), "host finished full Scanner setup")
            }
        }
    }
    func scannerFlowReceived(manager: ScannerService, flowElement: FlowElement, context: ScannerConsumerContext) async throws { if context.remoteUUID == prefix + "c" { lock.withLock { count += 1 } } }
    func connectedDevicesChanged(manager: ScannerService, connectedDevices: [String]) { lock.withLock { names = connectedDevices } }
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
        advertiser = MCNearbyServiceAdvertiser(peer: id, discoveryInfo: ["uuid": local, "v": NearbyBeacon.currentVersion, "k": "u"], serviceType: "haven-radar")
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
    }
    func invite() throws {
        let peerID = try XCTUnwrap(remote)
        let endpoint = try BridgePeerChannelAuthentication.Endpoint(initiator: local, responder: target, setupID: UUID().uuidString, domain: "nearby")
        browser.invitePeer(peerID, to: session, withContext: try BridgeChannelAuthentication.encode(endpoint), timeout: 10)
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        print("CP53 raw MC state=\(state.rawValue)")
        lock.withLock { if state == .connected { up = true }; if state == .notConnected && up { down = true } }
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {} // deliberately ignores app close/auth
    func session(_ session: MCSession, didReceive stream: InputStream, withName: String, fromPeer: MCPeerID) { stream.close() }
    func session(_ session: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with progress: Progress) { progress.cancel() }
    func session(_ session: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at: URL?, withError: Error?) {}
}
#endif
