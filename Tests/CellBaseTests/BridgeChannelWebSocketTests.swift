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
    func testCloseCancelsARealSocketStalledBeforeWebSocketUpgrade() async throws {
        let app = try await Application.make(.testing)
        let entered = expectation(description: "server received upgrade request")
        let release = SocketUpgradeBarrier()
        app.get("stall") { _ async -> HTTPStatus in
            entered.fulfill()
            await release.wait()
            return .ok
        }
        let transport = VaporBridgeTransport()
        do {
            try await app.server.start(address: .hostname("127.0.0.1", port: 0))
            let port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
            let pending = Task { try await transport.setup(URL(string: "ws://127.0.0.1:\(port)/stall")!, identity: Identity()) }
            await fulfillment(of: [entered], timeout: 3)
            do {
                try await transport.setup(URL(string: "ws://127.0.0.1:\(port)/stall")!, identity: Identity())
                XCTFail("A second setup cannot replace a pending socket")
            } catch {}
            let began = ProcessInfo.processInfo.systemUptime
            await transport.close()
            do { try await pending.value; XCTFail("Unfinished upgrade must fail on close") } catch {}
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 5)
            await release.resume()
            await app.server.shutdown(); try await app.asyncShutdown()
        } catch {
            await transport.close(); await release.resume()
            await app.server.shutdown(); try await app.asyncShutdown()
            throw error
        }
    }

    func testVaporSocketRequiresProofThenPerformsProtectedReadWithNoServerSigner() async throws {
        try await protectedRead(multiplexed: false)
    }

    func testVaporMuxSocketPreservesOriginSigningProgressDuringProtectedRead() async throws {
        try await protectedRead(multiplexed: true)
    }

    func testHeldCellDoesNotBlockAnotherProtectedReadOnSameWebSocket() async throws {
        try await protectedRead(multiplexed: true, independentChannels: true)
    }

    private func protectedRead(multiplexed: Bool, independentChannels: Bool = false) async throws {
        let oldResolver = CellBase.defaultCellResolver, oldVault = CellBase.defaultIdentityVault
        defer { CellBase.defaultCellResolver = oldResolver; CellBase.defaultIdentityVault = oldVault }
        let vault = MockIdentityVault()
        let owner = await vault.identity(for: "loopback-client", makeNewIfNotFound: true)!
        let trap = SigningTrapVault(); CellBase.defaultIdentityVault = trap
        let cell = await GeneralCell(owner: owner.publicIdentitySnapshot())
        let releaseHeldRead = SocketUpgradeBarrier()
        let heldEntered = independentChannels ? expectation(description: "A entered actual Cell GET") : nil
        if let heldEntered {
            await cell.addInterceptForGet(requester: owner, key: "held") { _, _ in
                heldEntered.fulfill()
                await releaseHeldRead.wait()
                return .string("late-value")
            }
        }
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
                    if multiplexed {
                        return BridgeMultiplexServerSession(physicalTransport: transport,
                            bridgeOwner: owner.publicIdentitySnapshot(), inboundPublisherLookupIdentity: owner.publicIdentitySnapshot())
                    }
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
            let mux = multiplexed ? BridgeMultiplexSession(physicalTransport: gate) : nil
            let transport = try mux?.channelTransport(targetEndpoint: "Protected") ?? gate
            let bridge = try await BridgeBase(.init(owner: owner, transport: transport, connection: .outbound,
                identityProofScopes: [.init(domain: cell.identityDomain, resource: cell.uuid)]))
            try await bridge.setTransport(transport, connection: .outbound)
            try await transport.setup(url, identity: owner)
            let value = try await bridge.get(keypath: "secret", requester: owner)
            XCTAssertEqual(value, .string("socket-value"))
            if let heldEntered, let mux {
                let pending = Task { _ = try? await bridge.get(keypath: "held", requester: owner) }
                await fulfillment(of: [heldEntered], timeout: 3)
                let siblingFinished = expectation(description: "B completed protected GET while A awaits")
                let sibling = Task {
                    do {
                        let otherTransport = try mux.channelTransport(targetEndpoint: "Protected")
                        let other = try await BridgeBase(.init(owner: owner, transport: otherTransport,
                            connection: .outbound, identityProofScopes: [
                                .init(domain: cell.identityDomain, resource: cell.uuid)
                            ]))
                        try await other.setTransport(otherTransport, connection: .outbound)
                        try await otherTransport.setup(url, identity: owner)
                        let result = try await other.get(keypath: "secret", requester: owner)
                        XCTAssertEqual(result, .string("socket-value"))
                        siblingFinished.fulfill()
                        await otherTransport.close()
                    } catch { XCTFail("Independent protected read failed: \(error)") }
                }
                // The regression fails on the old physical dispatchTail. Always
                // release the held Cell afterward so red runs cannot hang teardown.
                await fulfillment(of: [siblingFinished], timeout: 3)
                await transport.close()
                await releaseHeldRead.resume()
                await pending.value
                await sibling.value
            }
            XCTAssertEqual(state.count, 1, "Both logical channels must share one admitted physical socket")
            let signerCalls = await trap.calls; XCTAssertEqual(signerCalls, 0)
            await transport.close()
            await gate.close()
            withExtendedLifetime(mux) {}
            for connection in state.gates { await connection.close() }
            XCTAssertEqual(limits.connectionCount, 0)
            await app.server.shutdown()
            try await app.asyncShutdown()
        } catch {
            await releaseHeldRead.resume()
            for connection in state.gates { await connection.close() }
            await app.server.shutdown()
            try await app.asyncShutdown()
            throw error
        }
    }
}

private actor SocketUpgradeBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() { released = true; continuation?.resume(); continuation = nil }
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
