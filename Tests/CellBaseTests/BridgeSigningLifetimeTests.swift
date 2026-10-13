// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import XCTest
@testable import CellBase

final class BridgeSigningLifetimeTests: XCTestCase {
    typealias A = BridgeChannelAuthentication

    func testWSHeldExistenceChecksBothClocksAndCancellationBeforeAnySigning() async throws {
        for reason in ["monotonic", "wall", "cancel", "task", "valid"] {
            let keys = MockIdentityVault(), clock = BridgeLifecycleClock(), barrier = BridgeLifecycleBarrier()
            let vault = BridgeLifecycleVault(keys)
            let owner = await keys.identity(for: "owner", makeNewIfNotFound: true)!
            owner.identityVault = vault
            await vault.holdExistence(barrier)
            let endpoint = try A.Endpoint(url: URL(string: "wss://lifetime.example/bridge")!, domain: "bridge")
            let session = try BridgeChannelSession(endpoint: endpoint, wallClock: { clock.now })
            let operation = try BridgeChannelClientOperation(owner: owner, endpoint: endpoint,
                wallClock: { clock.now }, monotonic: { clock.monotonic })
            let challenge = try session.issueChallenge(operation.hello)
            let task = Task { try await operation.sign(challenge) }
            await fulfillment(of: [barrier.entered], timeout: 2)
            if reason == "monotonic" { clock.advance(wall: -3600, monotonic: 10) }
            if reason == "wall" { clock.advance(wall: 30) }
            if reason == "cancel" { await operation.cancel() }
            if reason == "task" { task.cancel() }
            await barrier.release()
            do { _ = try await task.value; XCTAssertEqual(reason, "valid") }
            catch { XCTAssertNotEqual(reason, "valid", "\(error)") }
            let count = await vault.signCount
            XCTAssertEqual(count, reason == "valid" ? 1 : 0, reason)
            session.close()
        }
    }

    func testOriginHeldExistenceOrReplayCannotSignExpiredChallengeWithLiveFeedPermit() async throws {
        for stage in ["existence", "replay"] {
            for reason in ["wall", "monotonic", "close", "permit", "cancel", "valid"] {
                let keys = MockIdentityVault(), clock = BridgeLifecycleClock(), barrier = BridgeLifecycleBarrier()
                let vault = BridgeLifecycleVault(keys)
                let owner = await keys.identity(for: "owner", makeNewIfNotFound: true)!
                let session = try await authenticatedSessionFixture(principal: owner)
                owner.identityVault = vault
                let wire = BridgeLifecycleWire(); wire.channelSession = session
                let bridge = try await BridgeBase(.init(owner: owner, transport: wire,
                    identityProofScopes: [.init(domain: "bridge", resource: "protected")]))
                try await bridge.setTransport(wire, connection: .outbound)
                try bridge.activateAuthenticatedChannel()
                bridge.signingWallClock = { clock.now }; bridge.signingMonotonic = { clock.monotonic }
                let store = CellSecuritySigningChallengeReplayStore()
                bridge.consumeSigningChallenge = { challenge, now in
                    let decision = await store.consume(challenge, now: now)
                    if stage == "replay" { await barrier.hold() }
                    return decision
                }
                // A feed lease has no ordinary five-second operation expiry.
                await bridge.sendCommand(command: reason == "permit" ? .get : .feed, identity: owner, payload: .string("value"))
                let feed = try XCTUnwrap(wire.commands.last { $0.command == .feed || $0.command == .get })
                if stage == "existence" { await vault.holdExistence(barrier) }
                let challenge = IdentitySigningChallenge(identityUUID: owner.uuid,
                    publicKeyFingerprint: owner.signingPublicKeyFingerprint, domain: "bridge", resource: "protected",
                    action: "checkIdentityOrigin", audience: "GeneralCell", nonce: Data(repeating: 9, count: 32),
                    issuedAt: clock.now, validity: 2)
                let data = try A.encode(challenge)
                let task = Task { try await bridge.consumeCommand(command: .init(cmd: "sign",
                    identity: owner.publicIdentitySnapshot(), payload: .signData(data), cid: 99)) }
                await fulfillment(of: [barrier.entered], timeout: 2)
                if reason == "wall" { clock.advance(wall: 3) }
                if reason == "monotonic" { clock.advance(wall: -10, monotonic: 2) }
                if reason == "close" { await bridge.channelDidClose(session) }
                if reason == "permit" {
                    // Explicitly end the local feed; the channel stays live.
                    try await bridge.consumeResponse(command: .init(cmd: "response", payload: .string("done"), cid: feed.cid))
                    // A new operation in the same scope cannot revive the old permit.
                    await bridge.sendCommand(command: .feed, identity: owner, payload: nil)
                }
                if reason == "cancel" { task.cancel() }
                await barrier.release()
                _ = try? await task.value
                let count = await vault.signCount
                XCTAssertEqual(count, reason == "valid" ? 1 : 0, "\(stage)/\(reason), feed \(feed.cid)")
                XCTAssertEqual(wire.commands.filter { if case .signature? = $0.payload { return true }; return false }.count,
                    reason == "valid" ? 1 : 0)
                await bridge.channelDidClose(session)
                await wire.close()
            }
        }
    }
}
