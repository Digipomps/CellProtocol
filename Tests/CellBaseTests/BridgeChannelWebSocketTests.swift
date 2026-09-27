// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
#if canImport(CellVapor)
import XCTest
import Vapor
@testable import CellBase
@testable import CellVapor

/// Real loopback WebSocket framing and callbacks. TLS/proxy deployment evidence
/// remains a separate staging requirement; this test explicitly enables local WS.
final class BridgeChannelWebSocketTests: XCTestCase {
    func testVaporSocketRequiresProofThenPerformsProtectedReadWithNoServerSigner() async throws {
        let oldResolver = CellBase.defaultCellResolver, oldVault = CellBase.defaultIdentityVault
        defer { CellBase.defaultCellResolver = oldResolver; CellBase.defaultIdentityVault = oldVault }
        let vault = MockIdentityVault()
        let owner = await vault.identity(for: "loopback-client", makeNewIfNotFound: true)!
        let trap = SigningTrapVault(); CellBase.defaultIdentityVault = trap
        let cell = await GeneralCell(owner: owner.publicIdentitySnapshot())
        await cell.addInterceptForGet(requester: owner, key: "secret") { _, _ in .string("socket-value") }
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        try await resolver.registerNamedEmitCell(name: "Protected", emitCell: cell, scope: .template, identity: owner)
        let app = try await Application.make(.testing)
        let state = SocketAuthFixtureState()
        let limits = BridgeChannelLimits()
        app.webSocket("bridge", maxFrameSize: .init(integerLiteral: 16 * 1024)) { _, socket in
            do {
                let transport = VaporBridgeTransport(webSocket: socket)
                let gate = try BridgeChannelTransport(underlying: transport, endpoint: state.endpoint(), limits: limits, source: "127.0.0.1") { transport, _ in
                    state.admitted()
                    let bridge = try await BridgeBase(.init(owner: owner.publicIdentitySnapshot(), transport: transport,
                        connection: .inbound(publisherUuid: "Protected"), inboundPublisherLookupIdentity: owner.publicIdentitySnapshot()))
                    try await bridge.setTransport(transport, connection: .inbound(publisherUuid: "Protected"))
                    return bridge
                }
                state.add(gate)
            } catch { socket.close(code: .policyViolation, promise: nil) }
        }
        do {
            try await app.server.start(address: .hostname("127.0.0.1", port: 0))
            let port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
            let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)/bridge"))
            state.configure(try .init(url: url, domain: "bridge", allowInsecureLoopback: true))
            let raw = VaporBridgeTransport()
            try await raw.setup(url, identity: owner.publicIdentitySnapshot())
            try await raw.sendData(JSONEncoder().encode(BridgeCommand(cmd: "get", identity: owner.publicIdentitySnapshot(), payload: .string("secret"), cid: 1)))
            for _ in 0..<100 {
                if state.gates.first?.session.state == .closed { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(state.count, 0)
            XCTAssertEqual(state.gates.first?.session.state, .closed)
            await raw.close()
            let gate = try BridgeChannelTransport(underlying: VaporBridgeTransport(), endpoint: state.endpoint())
            let bridge = try await BridgeBase(.init(owner: owner, transport: gate, connection: .outbound,
                identityProofScopes: [.init(domain: cell.identityDomain, resource: cell.uuid)]))
            try await bridge.setTransport(gate, connection: .outbound)
            try await gate.setup(url, identity: owner)
            let value = try await bridge.get(keypath: "secret", requester: owner)
            XCTAssertEqual(value, .string("socket-value"))
            XCTAssertEqual(state.count, 1)
            let signerCalls = await trap.calls; XCTAssertEqual(signerCalls, 0)
            await gate.close()
            for connection in state.gates { await connection.close() }
            XCTAssertEqual(limits.connectionCount, 0)
            await app.server.shutdown()
            try await app.asyncShutdown()
        } catch {
            for connection in state.gates { await connection.close() }
            await app.server.shutdown()
            try await app.asyncShutdown()
            throw error
        }
    }
}

private final class SocketAuthFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var endpointValue: BridgeChannelAuthentication.Endpoint?
    private var connections: [BridgeChannelTransport] = []
    private var admittedCount = 0
    var count: Int { lock.withLock { admittedCount } }
    var gates: [BridgeChannelTransport] { lock.withLock { connections } }
    func admitted() { lock.withLock { admittedCount += 1 } }
    func add(_ gate: BridgeChannelTransport) { lock.withLock { connections.append(gate) } }
    func configure(_ endpoint: BridgeChannelAuthentication.Endpoint) { lock.withLock { endpointValue = endpoint } }
    func endpoint() throws -> BridgeChannelAuthentication.Endpoint {
        try lock.withLock { try XCTUnwrap(endpointValue) }
    }
}
#endif
