#if os(macOS)
import Foundation
import MultipeerConnectivity
import XCTest
@testable import CellApple
@testable import CellBase

// Real outer MC endpoints, with the production v3 gate/session/record/receipt
// implementation at each end. M has no gate, vault, identity proof or DH secret.
// This test adapter is separate from the production Scanner adapter exercised
// by the direct two-process and physical-isolation scenarios in the same parent.
extension ScannerMultipeerProcessTests {
    func runRelayProcesses() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cp53-relay-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        print("CP53 three-process relay artifacts: \(folder.path)")
        let endpoint = try BridgePeerChannelAuthentication.Endpoint(initiator: "I", responder: "R", setupID: UUID().uuidString, domain: "nearby")
        try BridgeChannelAuthentication.encode(endpoint).write(to: folder.appendingPathComponent("endpoint.json"))
        var children: [(Process, FileHandle)] = []
        defer { for (child, file) in children { if child.isRunning { child.terminate() }; try? file.close() } }
        for role in ["m", "i", "r"] {
            let log = folder.appendingPathComponent("\(role).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let file = try FileHandle(forWritingTo: log), child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            child.arguments = ["xctest", "-XCTest", "CellBaseTests.ScannerMultipeerProcessTests/testMultipeerWorker", Bundle(for: Self.self).bundlePath]
            var env = ProcessInfo.processInfo.environment
            env["CP53_RELAY_ROLE"] = role; env["CP53_PEER_DIRECTORY"] = folder.path
            child.environment = env; child.standardOutput = file; child.standardError = file
            try child.run(); children.append((child, file))
        }
        try await relayWait(seconds: 55) { children.allSatisfy { !$0.0.isRunning } }
        for (child, file) in children { try file.synchronize(); XCTAssertEqual(child.terminationStatus, 0, folder.path) }
        for role in ["m", "i", "r"] { XCTAssertTrue(relayExists(folder, role + ".passed"), folder.path) }
    }

    func runRelayWorker(role: String, folder: URL) async throws {
        let tag = folder.lastPathComponent
        if role == "m" {
            let left = RelayMCLink(tag: tag, side: "i", relay: true), right = RelayMCLink(tag: tag, side: "r", relay: true)
            let observed = RelayObservation(folder: folder)
            left.receive = { data in try observed.capture(data, side: "i"); try right.sendRaw(data) }
            right.receive = { data in try observed.capture(data, side: "r"); try left.sendRaw(data) }
            left.start(); right.start(); defer { left.stop(); right.stop() }
            try await relayWait { left.connected && right.connected }
            try Data().write(to: folder.appendingPathComponent("relay-ready"))
            try await relayWait { relayExists(folder, "i.passed") && relayExists(folder, "r.passed") }
            XCTAssertEqual(left.errors + right.errors, [])
            try observed.verify()
            try Data("two independent encrypted MC sessions; M forwarded exact inner bytes; no signing or DH keys; five strict envelopes; encrypted application traffic both directions\n".utf8).write(to: folder.appendingPathComponent("m.passed"))
            return
        }
        let vault = MockIdentityVault()
        var owner = Identity("relay-secret-identity-\(role)-\(UUID())", displayName: "synthetic", identityVault: vault)
        await vault.addIdentity(identity: &owner, for: "relay")
        let descriptor = try BridgeChannelAuthentication.PublicIdentity(owner)
        try BridgeChannelAuthentication.encode(descriptor).write(to: folder.appendingPathComponent(role + ".public"))
        let link = RelayMCLink(tag: tag, side: role, relay: false), consumer = RelayConsumer()
        link.start(); defer { link.stop() }
        try await relayWait { link.connected && relayExists(folder, "relay-ready") }
        let endpoint = try BridgeChannelAuthentication.decode(BridgePeerChannelAuthentication.Endpoint.self, from: Data(contentsOf: folder.appendingPathComponent("endpoint.json")))
        let gate = try BridgeChannelTransport(underlying: link, peerEndpoint: endpoint, role: role == "i" ? .initiator : .responder,
            owner: owner, limits: BridgeChannelLimits(), source: role,
            disclosurePolicy: .anyProvenIdentity(allowUnauthenticatedInitiator: true)) { _, _ in consumer }
        try Data().write(to: folder.appendingPathComponent(role + ".gate"))
        try await relayWait { relayExists(folder, "i.gate") && relayExists(folder, "r.gate") }
        try await gate.startPeer()
        let other = role == "i" ? "r" : "i"
        let expected = try BridgeChannelAuthentication.decode(BridgeChannelAuthentication.PublicIdentity.self, from: Data(contentsOf: folder.appendingPathComponent(other + ".public")))
        XCTAssertEqual(gate.session.publicIdentity, expected)
        for n in 0..<8 {
            try await gate.sendData(BridgeChannelAuthentication.encode(BridgeCommand(cmd: "response", payload: .string("relay-private-application-\(role)-\(n)"), cid: n + 1)))
        }
        try await relayWait { consumer.values.count == 8 }
        XCTAssertEqual(consumer.values, (0..<8).map { "relay-private-application-\(other)-\($0)" })
        XCTAssertTrue(gate.canSendPeerData); XCTAssertEqual(link.errors, [])
        try Data("proved remote principal; ordered private data in both directions; 8 values; physical MC session\n".utf8).write(to: folder.appendingPathComponent(role + ".passed"))
        try await relayWait { relayExists(folder, "m.passed") }
        await gate.close()
    }
}

private func relayExists(_ folder: URL, _ name: String) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }
private func relayWait(seconds: Double = 20, _ condition: () -> Bool) async throws {
    let until = ProcessInfo.processInfo.systemUptime + seconds
    while !condition() && ProcessInfo.processInfo.systemUptime < until { try await Task.sleep(nanoseconds: 10_000_000) }
    guard condition() else { throw NSError(domain: "CP53 real relay timeout", code: 1) }
}

private final class RelayMCLink: NSObject, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate, MCSessionDelegate, BridgeTransportProtocol {
    let session: MCSession
    private let browser: MCNearbyServiceBrowser, advertiser: MCNearbyServiceAdvertiser
    private let tag: String, side: String, relay: Bool
    private let lock = NSLock(), sendLock = NSLock()
    private var invited = false, failures: [String] = [], tail: Task<Void, Never>?
    private weak var gate: BridgeChannelTransport?
    var receive: ((Data) throws -> Void)? // configured before start
    init(tag: String, side: String, relay: Bool) {
        self.tag = tag; self.side = side; self.relay = relay
        let id = MCPeerID(displayName: "relay-\(relay ? "m" : "end")-\(side)-\(UUID().uuidString.prefix(6))")
        session = MCSession(peer: id, securityIdentity: nil, encryptionPreference: .required)
        browser = MCNearbyServiceBrowser(peer: id, serviceType: "cp53-relay")
        advertiser = MCNearbyServiceAdvertiser(peer: id, discoveryInfo: ["tag":tag,"side":side], serviceType: "cp53-relay")
        super.init(); session.delegate = self; browser.delegate = self; advertiser.delegate = self
    }
    var connected: Bool { session.connectedPeers.count == 1 }
    var errors: [String] { lock.withLock { failures } }
    func start() { if relay { advertiser.startAdvertisingPeer() } else { browser.startBrowsingForPeers() } }
    func stop() { advertiser.stopAdvertisingPeer(); browser.stopBrowsingForPeers(); session.disconnect() }
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard info?["tag"] == tag, info?["side"] == side,
              lock.withLock({ if invited { return false }; invited = true; return true }) else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) { invitationHandler(true, session) }
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {}
    func session(_ session: MCSession, didReceive data: Data, fromPeer: MCPeerID) {
        lock.withLock {
            let prior = tail, captured = gate
            tail = Task {
                await prior?.value
                do {
                    if let receive { try receive(data); return }
                    guard let captured else { throw BridgeChannelAuthentication.Failure.unavailable }
                    let plain = try captured.openPeerFrame(data)
                    if plain.isEmpty { return }
                    try captured.validateInboundPayload(plain)
                    try sendLock.withLock { try captured.submitPeerReceipts { try sendRaw($0) } }
                    let command = try JSONDecoder().decode(BridgeCommand.self, from: plain)
                    if command.command == .response { try await captured.consumeResponse(command: command) }
                    else { try await captured.consumeCommand(command: command) }
                } catch { lock.withLock { failures.append(String(describing: error)) }; await captured?.close() }
            }
        }
    }
    func session(_ session: MCSession, didReceive stream: InputStream, withName: String, fromPeer: MCPeerID) { stream.close() }
    func session(_ session: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with progress: Progress) { progress.cancel() }
    func session(_ session: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at: URL?, withError: Error?) {}
    func sendRaw(_ data: Data) throws {
        let peers = session.connectedPeers
        guard peers.count == 1 else { throw BridgeChannelAuthentication.Failure.unavailable }
        try session.send(data, toPeers: peers, with: .reliable)
    }
    func setDelegate(_ delegate: BridgeDelegateProtocol) { lock.withLock { gate = delegate as? BridgeChannelTransport } }
    func setup(_ endpointURL: URL, identity: Identity) async throws {}
    func sendData(_ data: Data) async throws {
        let gate = try XCTUnwrap(lock.withLock { self.gate })
        try sendLock.withLock { try gate.submitPeerFrame(data) { try sendRaw($0) } }
    }
    func close() async { session.disconnect(); try? await relayWait { session.connectedPeers.isEmpty } }
    func identityVault(for identity: Identity?) async -> IdentityVaultProtocol { BridgeIdentityVault() }
    static func new() -> BridgeTransportProtocol { fatalError("Configured test MC endpoint required") }
}

private final class RelayConsumer: BridgeDelegateProtocol {
    let uuid = UUID().uuidString
    private let lock = NSLock(); private var received: [String] = []
    var values: [String] { lock.withLock { received } }
    func consumeCommand(command: BridgeCommand) async throws { try await consumeResponse(command: command) }
    func consumeResponse(command: BridgeCommand) async throws { if case .string(let value) = command.payload { lock.withLock { received.append(value) } } }
    func sendCommand(command: Command, identity: Identity, payload: ValueType?) async {}
    func sendSetValueState(for requestedKey: String, setValueState: SetValueState) async {}
    func pushError(errorMessage: String?, error: Error?) async {}
    func ready() async throws {}
}

private final class RelayObservation {
    let folder: URL
    private let lock = NSLock(); private var frames: [(String, Data)] = []
    init(folder: URL) { self.folder = folder }
    func capture(_ data: Data, side: String) throws {
        try lock.withLock {
            guard frames.count < 128 else { throw BridgeChannelAuthentication.Failure.capacity }
            frames.append((side, data))
            try data.write(to: folder.appendingPathComponent("wire-\(frames.count)-\(side).bin"))
        }
    }
    func verify() throws {
        let frames = lock.withLock { frames }
        var commands: [String] = [], records: [String: Int] = [:]
        let helloKeys: Set<String> = ["profile","role","ephemeralPublicKey","nonce","generation","issuedAtMilliseconds"]
        var forbidden = ["relay-private-application-", "relay-secret-identity-"]
        for side in ["i","r"] {
            let identity = try BridgeChannelAuthentication.decode(BridgeChannelAuthentication.PublicIdentity.self, from: Data(contentsOf: folder.appendingPathComponent(side + ".public")))
            forbidden += [identity.uuid, identity.publicKey.base64EncodedString()]
        }
        for (side, data) in frames {
            for marker in forbidden { XCTAssertNil(data.range(of: Data(marker.utf8))); XCTAssertNil(data.range(of: Data(Data(marker.utf8).base64EncodedString().utf8))) }
            if data.starts(with: Data("HPC3".utf8)) { records[side, default: 0] += 1; continue }
            let outer = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(outer.keys), ["&string","cid","cmd"])
            let name = try XCTUnwrap(outer["cmd"] as? String); commands.append(name)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((outer["&string"] as! String).utf8)) as? [String: Any])
            if name.hasSuffix("Hello") { XCTAssertEqual(Set(body.keys), helloKeys) }
            else {
                XCTAssertEqual(Set(body.keys), name.hasSuffix("ResponderAuth") ? ["hello","sealed"] : ["profile","sealed"])
                if let hello = body["hello"] as? [String: Any] { XCTAssertEqual(Set(hello.keys), helloKeys) }
                XCTAssertEqual(Data(base64Encoded: body["sealed"] as! String)?.count, name.hasSuffix("Auth") ? 8208 : 1040)
            }
        }
        XCTAssertEqual(commands, ["Hello","ResponderAuth","InitiatorAuth","ResponderFinished","InitiatorFinished"].map { "channelAuthPeerV3" + $0 })
        XCTAssertGreaterThanOrEqual(records["i", default: 0], 8); XCTAssertGreaterThanOrEqual(records["r", default: 0], 8)
    }
}
#endif
