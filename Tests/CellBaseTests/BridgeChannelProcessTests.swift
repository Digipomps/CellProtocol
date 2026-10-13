// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
#if os(macOS) && canImport(CellVapor)
import XCTest
import Foundation
import Vapor
@testable import CellBase
@testable import CellVapor

/// A second XCTest process receives only the public descriptor. Its default
/// vault fails if asked to store or sign a client identity.
final class BridgeChannelProcessTests: XCTestCase {
    func testIsolatedServerWorker() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CP53_TEST_SERVER_DIRECTORY"] else {
            throw XCTSkip("Subprocess worker; exercised by testSeparateServerProcessHasNoClientSecretInWirePersistenceOrLogs")
        }
        let folder = URL(fileURLWithPath: directory)
        let publicIdentity = try BridgeChannelAuthentication.decode(BridgeChannelAuthentication.PublicIdentity.self, from: Data(contentsOf: folder.appendingPathComponent("public.json")))
        let owner = publicIdentity.makeIdentity(), trap = SigningTrapVault()
        CellBase.defaultIdentityVault = trap
        let cell = await ProcessProtectedCell(owner: owner)
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        try await resolver.registerNamedEmitCell(name: "Protected", emitCell: cell, scope: .template, identity: owner)
        let app = try await Application.make(.testing), state = ProcessServerState(), limits = BridgeChannelLimits()
        app.webSocket("bridge", maxFrameSize: .init(integerLiteral: 16 * 1024)) { _, socket in
            do {
                let gate = try BridgeChannelTransport(underlying: VaporBridgeTransport(webSocket: socket), endpoint: state.endpoint(), limits: limits, source: "127.0.0.1") { transport, _ in
                    let bridge = BridgeBase(owner: owner)
                    try await bridge.setTransport(transport, connection: .inbound(publisherUuid: "Protected"))
                    return bridge
                }
                state.add(gate)
            } catch { socket.close(code: .policyViolation, promise: nil) }
        }
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        let port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
        let url = URL(string: "ws://127.0.0.1:\(port)/bridge")!
        state.configure(try .init(url: url, domain: "bridge", allowInsecureLoopback: true))
        let ready: [String: String] = ["url": url.absoluteString, "resource": cell.uuid, "domain": cell.identityDomain]
        try JSONEncoder().encode(ready).write(to: folder.appendingPathComponent("ready.json"), options: .atomic)
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        while !FileManager.default.fileExists(atPath: folder.appendingPathComponent("stop").path), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        for gate in state.gates { await gate.close() }
        try JSONEncoder().encode(cell).write(to: folder.appendingPathComponent("persisted-cell.json"))
        try JSONEncoder().encode(state.gates.compactMap { $0.session.publicIdentity }).write(to: folder.appendingPathComponent("session-descriptors.json"))
        let signerCalls = await trap.calls
        XCTAssertEqual(signerCalls, 0)
        XCTAssertEqual(cell.readCount, 1)
        XCTAssertEqual(limits.retainedConnectionCount, 0)
        await app.server.shutdown(); try await app.asyncShutdown()
    }

    func testSeparateServerProcessHasNoClientSecretInWirePersistenceOrLogs() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cp53-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let vault = MockIdentityVault(), owner = await vault.identity(for: "isolated-client", makeNewIfNotFound: true)!
        let marker = "SYNTHETIC_PRIVATE_MARKER_\(UUID().uuidString)"
        owner.properties = ["private-test": .string(marker)]; owner.homeVaultReference = marker
        try BridgeChannelAuthentication.encode(BridgeChannelAuthentication.PublicIdentity(owner)).write(to: folder.appendingPathComponent("public.json"))
        let log = folder.appendingPathComponent("server.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "CellBaseTests.BridgeChannelProcessTests/testIsolatedServerWorker", Bundle(for: Self.self).bundlePath]
        var environment = ProcessInfo.processInfo.environment
        environment["CP53_TEST_SERVER_DIRECTORY"] = folder.path
        process.environment = environment; process.standardOutput = handle; process.standardError = handle
        try process.run()
        defer { if process.isRunning { process.terminate() }; try? handle.close() }
        let readyURL = folder.appendingPathComponent("ready.json")
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while !FileManager.default.fileExists(atPath: readyURL.path), process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: readyURL.path), "Server did not start; artifacts: \(folder.path)")
        let ready = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: readyURL))
        let url = try XCTUnwrap(URL(string: XCTUnwrap(ready["url"])))
        let physical = ProcessRecordingTransport()
        let gate = try BridgeChannelTransport(underlying: physical, endpoint: .init(url: url, domain: "bridge", allowInsecureLoopback: true))
        let bridge = try await BridgeBase(.init(owner: owner, transport: gate, connection: .outbound,
            identityProofScopes: [.init(domain: try XCTUnwrap(ready["domain"]), resource: try XCTUnwrap(ready["resource"]))]))
        try await bridge.setTransport(gate, connection: .outbound)
        try await gate.setup(url, identity: owner)
        let value = try await bridge.get(keypath: "secret", requester: owner)
        XCTAssertEqual(value, .string("isolated-protected-value"))
        await gate.close()
        try physical.snapshot.write(to: folder.appendingPathComponent("client-wire.jsonl"))
        try Data().write(to: folder.appendingPathComponent("stop"))
        let exitDeadline = ProcessInfo.processInfo.systemUptime + 10
        while process.isRunning, ProcessInfo.processInfo.systemUptime < exitDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(process.isRunning, "Child did not finish")
        if !process.isRunning { XCTAssertEqual(process.terminationStatus, 0, "Child failure: \(folder.path)") }
        try handle.synchronize()
        for file in ["public.json", "client-wire.jsonl", "persisted-cell.json", "session-descriptors.json", "server.log"] {
            let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains(marker), file)
            // SecureKey's public wire schema includes the boolean privateKey:false.
            // Reject actual private-key values, not that public type discriminator.
            for line in text.split(separator: "\n") {
                if let value = try? JSONSerialization.jsonObject(with: Data(line.utf8)) { assertNoPrivateKey(value, file: file) }
            }
            XCTAssertFalse(text.contains("signingToken"), file)
        }
        print("CP53 isolated-process artifacts: \(folder.path)")
    }
    private func assertNoPrivateKey(_ value: Any, file: String) {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                if key == "privateKey" { XCTAssertEqual(child as? Bool, false, file) }
                assertNoPrivateKey(child, file: file)
            }
        } else if let array = value as? [Any] { array.forEach { assertNoPrivateKey($0, file: file) } }
    }

}
private final class ProcessProtectedCell: GeneralCell {
    private(set) var readCount = 0
    override func get(keypath: String, requester: Identity) async throws -> ValueType {
        guard keypath == "secret", await validateAccess("r---", at: keypath, for: requester) else { throw StreamState.denied }
        readCount += 1; return .string("isolated-protected-value")
    }
}
private final class ProcessServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var endpointValue: BridgeChannelAuthentication.Endpoint?
    private var values: [BridgeChannelTransport] = []
    var gates: [BridgeChannelTransport] { lock.withLock { values } }
    func add(_ gate: BridgeChannelTransport) { lock.withLock { values.append(gate) } }
    func configure(_ endpoint: BridgeChannelAuthentication.Endpoint) { lock.withLock { endpointValue = endpoint } }
    func endpoint() throws -> BridgeChannelAuthentication.Endpoint { try lock.withLock { try XCTUnwrap(endpointValue) } }
}
private final class ProcessRecordingTransport: BridgeTransportProtocol, @unchecked Sendable {
    private let underlying = VaporBridgeTransport(), lock = NSLock()
    private var bytes = Data()
    var snapshot: Data { lock.withLock { bytes } }
    static func new() -> BridgeTransportProtocol { ProcessRecordingTransport() }
    func setDelegate(_ delegate: BridgeDelegateProtocol) { underlying.setDelegate(delegate) }
    func setup(_ endpointURL: URL, identity: Identity) async throws { try await underlying.setup(endpointURL, identity: identity) }
    func sendData(_ data: Data) async throws { lock.withLock { bytes.append(data); bytes.append(10) }; try await underlying.sendData(data) }
    func close() async { await underlying.close() }
    func identityVault(for identity: Identity?) async -> IdentityVaultProtocol { BridgeIdentityVault() }
}
#endif
