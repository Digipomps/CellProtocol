// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@testable import CellBase

final class BridgeFactoryLifetimeTests: XCTestCase {
    typealias A = BridgeChannelAuthentication
    func testWSLateFactoryBoundBeforeOrAfterCloseRetiresSubscriptionExactlyOnce() async throws {
        for bindBeforeHold in [true, false] {
            for reason in ["close", "revoke", "expiry"] {
                let owner = await MockIdentityVault().identity(for: "owner", makeNewIfNotFound: true)!
                let wire = BridgeLifecycleWire(), clock = BridgeLifecycleClock(), limits = BridgeChannelLimits()
                let hold = BridgeLifecycleBarrier(), cleanup = BridgeLifecycleBarrier(), stats = BridgeFactoryLifetimeStats()
                let endpoint = try A.Endpoint(url: URL(string: "wss://lifetime.example/bridge")!, domain: "bridge")
                let gate = try BridgeChannelTransport(underlying: wire, endpoint: endpoint, limits: limits,
                    source: UUID().uuidString, wallClock: { clock.now }, monotonic: { clock.monotonic }) { transport, _ in
                        try await BridgeFactoryLifetimeSpy.make(owner: owner, transport: transport, stats: stats,
                            hold: hold, cleanup: cleanup, bindBeforeHold: bindBeforeHold)
                    }
                let operation = try BridgeChannelClientOperation(owner: owner, endpoint: endpoint)
                let proof = try await operation.sign(gate.session.issueChallenge(operation.hello))
                let command = BridgeCommand(cmd: "channelAuthProof", payload: .string(String(decoding: try A.encode(proof), as: UTF8.self)), cid: 0)
                let opening = Task { try await gate.consumeCommand(command: command) }
                await fulfillment(of: [hold.entered], timeout: 2)
                XCTAssertFalse(gate.hasDelegate, "Construction is not adoption")
                if reason == "revoke" { gate.session.revoke() }
                if reason == "expiry" { clock.advance(wall: 301, monotonic: 301) }
                if reason == "close" { await gate.close() }
                await hold.release()
                await fulfillment(of: [cleanup.entered], timeout: 2)
                XCTAssertGreaterThan(limits.outstandingWorkCount, 0)
                XCTAssertEqual(stats.snapshot.retired, 1)
                XCTAssertEqual(stats.snapshot.subscriptions, 1, "Cleanup has not finished")
                await cleanup.release()
                _ = try? await opening.value
                await gate.close()
                XCTAssertFalse(gate.hasDelegate)
                gate.setDelegate(BridgeBase(owner: owner))
                XCTAssertFalse(gate.hasDelegate)
                do { try await gate.ready(); XCTFail("Stopped gate ready") } catch {}
                XCTAssertEqual(stats.snapshot.retired, 1); XCTAssertEqual(stats.snapshot.subscriptions, 0)
                XCTAssertEqual(stats.snapshot.deinitialized, 1)
                XCTAssertEqual(limits.outstandingWorkCount, 0); XCTAssertEqual(limits.retainedConnectionCount, 0)
                XCTAssertFalse(wire.commands.contains { $0.cmd == "channelAuthAccepted" })
            }
        }
    }

    func testMuxLateFactoryRetiresResultWhenSessionCheckThrowsOrLogicalOpenIsCancelled() async throws {
        for reason in ["physical", "logical", "revoke"] {
            let owner = await MockIdentityVault().identity(for: "owner", makeNewIfNotFound: true)!
            let wire = BridgeLifecycleWire(); wire.channelSession = try await authenticatedSessionFixture(principal: owner)
            let hold = BridgeLifecycleBarrier(), cleanup = BridgeLifecycleBarrier(), stats = BridgeFactoryLifetimeStats()
            let mux = BridgeMultiplexServerSession(physicalTransport: wire) { target, _, transport in
                if target == "held" {
                    return try await BridgeFactoryLifetimeSpy.make(owner: owner, transport: transport, stats: stats,
                        hold: hold, cleanup: cleanup, bindBeforeHold: false)
                }
                return try await BridgeFactoryLifetimeSpy.make(owner: owner, transport: transport, stats: .init())
            }
            try await mux.consumeCommand(command: lifecycleMuxCommand("openChannel", owner, "healthy", target: "healthy"))
            let opening = Task { try await mux.consumeCommand(command: lifecycleMuxCommand("openChannel", owner, "held", target: "held")) }
            await fulfillment(of: [hold.entered], timeout: 2)
            if reason == "physical" { await mux.close() }
            if reason == "logical" { try await mux.consumeCommand(command: lifecycleMuxCommand("closeChannel", owner, "held")) }
            if reason == "revoke" { wire.channelSession?.revoke() }
            await hold.release()
            await fulfillment(of: [cleanup.entered], timeout: 2)
            XCTAssertEqual(stats.snapshot.subscriptions, 1)
            await cleanup.release(); _ = try? await opening.value
            XCTAssertEqual(stats.snapshot.retired, 1); XCTAssertEqual(stats.snapshot.subscriptions, 0)
            XCTAssertEqual(stats.snapshot.deinitialized, 1)
            XCTAssertFalse(wire.commands.contains { $0.cmd == "channelOpened" && $0.channelID == "held" })
            if reason == "logical" {
                try await mux.consumeCommand(command: lifecycleMuxCommand("get", owner, "healthy"))
                XCTAssertEqual(wire.commands.last?.payload, .string("healthy"))
            }
            await mux.close()
        }
    }
}

func lifecycleMuxCommand(_ name: String, _ owner: Identity, _ id: String, target: String = "cell", cid: Int = 1) -> BridgeCommand {
    .init(cmd: name, identity: owner, payload: name == "get" ? .string("value") : nil, cid: cid,
        protocolVersion: 2, channelID: id, targetEndpoint: name == "openChannel" ? target : nil)
}

final class BridgeFactoryLifetimeStats: @unchecked Sendable {
    struct Snapshot { var retired = 0; var deinitialized = 0; var subscriptions = 0 }
    private let lock = NSLock(); private var value = Snapshot()
    var snapshot: Snapshot { lock.withLock { value } }
    func update(_ change: (inout Snapshot) -> Void) { lock.withLock { change(&value) } }
}

/// Holds a real transport-bound Base plus a factory-owned subscription with a
/// deliberate self-retain. Only retirement can cancel it and permit deinit.
final class BridgeFactoryLifetimeSpy: BridgeDelegateProtocol, @unchecked Sendable {
    let uuid = UUID().uuidString
    let base: BridgeBase
    let stats: BridgeFactoryLifetimeStats
    let transport: BridgeTransportProtocol
    private let cleanup: BridgeLifecycleBarrier?
    private let events = PassthroughSubject<Void, Never>()
    private var subscription: AnyCancellable?
    var reply = "healthy"
    private init(owner: Identity, transport: BridgeTransportProtocol, stats: BridgeFactoryLifetimeStats, cleanup: BridgeLifecycleBarrier?) {
        base = BridgeBase(owner: owner); self.transport = transport; self.stats = stats; self.cleanup = cleanup
        subscription = events.handleEvents(receiveSubscription: { _ in stats.update { $0.subscriptions += 1 } },
            receiveCancel: { stats.update { $0.subscriptions -= 1 } }).sink { [self] in _ = self.uuid }
    }
    static func make(owner: Identity, transport: BridgeTransportProtocol, stats: BridgeFactoryLifetimeStats,
                     hold: BridgeLifecycleBarrier? = nil, cleanup: BridgeLifecycleBarrier? = nil,
                     bindBeforeHold: Bool = true) async throws -> BridgeFactoryLifetimeSpy {
        if !bindBeforeHold { await hold?.hold() }
        let spy = BridgeFactoryLifetimeSpy(owner: owner, transport: transport, stats: stats, cleanup: cleanup)
        try await spy.base.setTransport(transport, connection: .outbound)
        transport.setDelegate(spy)
        if bindBeforeHold { await hold?.hold() }
        return spy
    }
    func consumeCommand(command: BridgeCommand) async throws {
        try await transport.sendData(JSONEncoder().encode(BridgeCommand(cmd: "response", payload: .string(reply), cid: command.cid)))
    }
    func consumeResponse(command: BridgeCommand) async throws {}
    func sendCommand(command: Command, identity: Identity, payload: ValueType?) async {}
    func sendSetValueState(for requestedKey: String, setValueState: SetValueState) async {}
    func ready() async throws {}
    func pushError(errorMessage: String?, error: Error?) async {
        stats.update { $0.retired += 1 }
        await cleanup?.hold()
        subscription?.cancel(); subscription = nil
        await base.retireLogicalChannel()
    }
    deinit { stats.update { $0.deinitialized += 1 } }
}
