// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import XCTest
@testable import CellBase

final class BridgeMuxSendLifetimeTests: XCTestCase {
    func testWSMuxHeldPhysicalSubmissionFencesReusedIDAndCIDWhileSiblingWorks() async throws {
        let owner = await MockIdentityVault().identity(for: "owner", makeNewIfNotFound: true)!
        let endpoint = try BridgeChannelAuthentication.Endpoint(url: URL(string: "wss://lifetime.example/mux")!, domain: "bridge")
        let wire = BridgeLifecycleWire(), frames = BridgeMuxLifetimeFrames(), hold = BridgeLifecycleBarrier()
        let stats = BridgeFactoryLifetimeStats()
        let gate = try BridgeChannelTransport(underlying: wire, endpoint: endpoint, limits: .init(), source: "mux") { transport, _ in
            BridgeMultiplexServerSession(physicalTransport: transport, maximumChannels: 3) { target, _, logical in
                let result = try await BridgeFactoryLifetimeSpy.make(owner: owner, transport: logical,
                    stats: target == "old" ? stats : .init())
                result.reply = target
                return result
            }
        }
        let client = try BridgeChannelClientOperation(owner: owner, endpoint: endpoint)
        let proof = try await client.sign(gate.session.issueChallenge(client.hello))
        try await gate.consumeCommand(command: .init(cmd: "channelAuthProof",
            payload: .string(String(decoding: try BridgeChannelAuthentication.encode(proof), as: UTF8.self)), cid: 0))
        wire.beforeAccept = { frame in if frame.payload == .string("old") { await hold.hold() } }
        wire.accepted = { frames.append($0) }
        try await exerciseMuxSubmissionLifetime(owner: owner, hold: hold, frames: frames, stats: stats) {
            try await gate.consumeCommand(command: $0)
        }
        await gate.close()
    }
}

final class BridgeMuxLifetimeFrames: @unchecked Sendable {
    private let lock = NSLock(); private var stored: [BridgeCommand] = []
    var frames: [BridgeCommand] { lock.withLock { stored } }
    func append(_ command: BridgeCommand) { lock.withLock { stored.append(command) } }
}

func exerciseMuxSubmissionLifetime(owner: Identity, hold: BridgeLifecycleBarrier, frames: BridgeMuxLifetimeFrames,
                                   stats: BridgeFactoryLifetimeStats,
                                   submit: @escaping @Sendable (BridgeCommand) async throws -> Void) async throws {
    try await submit(lifecycleMuxCommand("openChannel", owner, "reused", target: "old", cid: 7))
    try await submit(lifecycleMuxCommand("openChannel", owner, "sibling", target: "healthy", cid: 7))
    let old = Task { try await submit(lifecycleMuxCommand("get", owner, "reused", cid: 1)) }
    await XCTWaiter.fulfillment(of: [hold.entered], timeout: 2)
    try await submit(lifecycleMuxCommand("closeChannel", owner, "reused"))
    XCTAssertEqual(stats.snapshot.retired, 1)
    XCTAssertEqual(stats.snapshot.deinitialized, 0, "Admitted physical send must retain the old record/quota")
    try await submit(lifecycleMuxCommand("openChannel", owner, "reused", target: "fresh", cid: 7))
    XCTAssertEqual(frames.frames.last?.cmd, "channelRejected", "ID is fenced after object guard and before physical acceptance")
    try await submit(lifecycleMuxCommand("get", owner, "sibling", cid: 1))
    XCTAssertEqual(frames.frames.last?.payload, .string("healthy"))
    XCTAssertFalse(frames.frames.contains { $0.payload == .string("old") })
    await hold.release(); _ = try? await old.value
    // The old bytes may be handed over now, but the reused ID has no new owner.
    XCTAssertEqual(frames.frames.last?.payload, .string("old"))
    XCTAssertEqual(stats.snapshot.deinitialized, 1)
    try await submit(lifecycleMuxCommand("openChannel", owner, "reused", target: "fresh", cid: 7))
    XCTAssertEqual(frames.frames.last?.cmd, "channelOpened")
    try await submit(lifecycleMuxCommand("get", owner, "reused", cid: 1))
    XCTAssertEqual(frames.frames.last?.payload, .string("fresh"))
    XCTAssertEqual(frames.frames.last?.cid, 1)
    XCTAssertEqual(frames.frames.last?.channelID, "reused")
    try await submit(lifecycleMuxCommand("get", owner, "sibling", cid: 1))
    XCTAssertEqual(frames.frames.last?.payload, .string("healthy"))
}
