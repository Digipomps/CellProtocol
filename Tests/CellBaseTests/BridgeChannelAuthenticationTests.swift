// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class BridgeChannelAuthenticationTests: XCTestCase {
    typealias A = BridgeChannelAuthentication
    private func endpoint(_ route: String = "/bridgehead/Protected/connection") throws -> A.Endpoint {
        try .init(url: XCTUnwrap(URL(string: "wss://bridge.example" + route)), domain: "bridge")
    }
    private func owner() async -> Identity {
        await MockIdentityVault().identity(for: "client", makeNewIfNotFound: true)!
    }
    private func handshake(_ owner: Identity, endpoint: A.Endpoint? = nil,
                           limits: BridgeChannelLimits? = nil) async throws -> (BridgeChannelSession, BridgeChannelClientOperation, A.Challenge, A.Proof) {
        let target = try endpoint ?? self.endpoint()
        let server = try BridgeChannelSession(endpoint: target, limits: limits)
        let client = try BridgeChannelClientOperation(owner: owner, endpoint: target)
        let challenge = try server.issueChallenge(client.hello)
        let proof = try await client.sign(challenge)
        return (server, client, challenge, proof)
    }

    func testRoundTripHasOnlyPublicIdentityAndDoesNotConsultServerVault() async throws {
        let identity = await owner()
        identity.properties = ["private-test-property": .string("must-not-cross-wire")]
        identity.homeVaultReference = "local-secret-vault-reference"
        let serverVault = SigningTrapVault()
        let previous = CellBase.defaultIdentityVault
        CellBase.defaultIdentityVault = serverVault
        defer { CellBase.defaultIdentityVault = previous }
        let (server, client, challenge, proof) = try await handshake(identity)
        let bytes = try A.encode(client.hello)
        let json = String(decoding: bytes, as: UTF8.self)
        for forbidden in ["privateKey", "vault", "properties", "displayName", "must-not-cross-wire", "homeVaultReference"] {
            XCTAssertFalse(json.contains(forbidden))
        }
        XCTAssertEqual(challenge.transcript.serverNonce.count, 32)
        XCTAssertEqual(server.state, .challengeIssued)
        try server.reserveOpen(proof)
        XCTAssertEqual(server.state, .verifying)
        XCTAssertThrowsError(try server.check())
        try server.recheckBeforeActivation()
        let accepted = try server.activate()
        try server.check(identity: identity, requiresIdentity: true)
        let clientSession = try BridgeChannelSession(endpoint: endpoint())
        try await client.finish(accepted, session: clientSession)
        try clientSession.check(identity: identity, requiresIdentity: true)
        let calls = await serverVault.calls
        XCTAssertEqual(calls, 0)
        server.close(); clientSession.close()
    }

    func testReplayWrongConnectionGenerationAndParallelConsume() async throws {
        let identity = await owner()
        let (server, _, _, proof) = try await handshake(identity)
        let another = try BridgeChannelSession(endpoint: endpoint())
        let otherClient = try BridgeChannelClientOperation(owner: identity, endpoint: endpoint())
        _ = try another.issueChallenge(otherClient.hello)
        XCTAssertThrowsError(try another.reserveOpen(proof))
        let changed = A.Proof(sessionID: proof.sessionID, generation: UUID().uuidString, signature: proof.signature)
        XCTAssertThrowsError(try server.reserveOpen(changed))
        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 { group.addTask { (try? server.reserveOpen(proof)) != nil } }
            var winners = 0
            for await accepted in group { if accepted { winners += 1 } }
            return winners
        }
        XCTAssertEqual(winners, 1)
        _ = try server.activate()
        XCTAssertThrowsError(try server.reserveOpen(proof))
        server.close()
        XCTAssertThrowsError(try server.reserveOpen(proof))
        XCTAssertThrowsError(try server.check())
        another.close()
    }

    func testDescriptorAloneAndForgedSignatureCannotActivate() async throws {
        let identity = await owner()
        let (server, _, _, proof) = try await handshake(identity)
        let forged = A.Proof(sessionID: proof.sessionID, generation: proof.generation, signature: Data(repeating: 0, count: 64))
        XCTAssertThrowsError(try server.reserveOpen(forged))
        XCTAssertEqual(server.state, .closed)
        XCTAssertThrowsError(try server.activate())
    }

    func testImmutablePrincipalRejectsSameUUIDWithAnotherKeyNilAndAnotherUUID() async throws {
        let identity = await owner()
        let (server, _, _, proof) = try await handshake(identity)
        try server.reserveOpen(proof); _ = try server.activate()
        let attacker = await owner() // same fixture UUID, independently generated key
        XCTAssertEqual(attacker.uuid, identity.uuid)
        XCTAssertThrowsError(try server.check(identity: attacker, requiresIdentity: true))
        XCTAssertThrowsError(try server.check(requiresIdentity: true))
        let changedUUID = Identity(UUID().uuidString, displayName: "", identityVault: nil)
        changedUUID.publicSecureKey = identity.publicSecureKey
        XCTAssertThrowsError(try server.check(identity: changedUUID, requiresIdentity: true))
        try server.check(identity: identity, requiresIdentity: true)
        server.close()
    }

    func testDeadlineRecheckedAfterVerificationAndRevocation() async throws {
        let clock = ChannelTestClock()
        let identity = await owner()
        let target = try endpoint()
        let server = try BridgeChannelSession(endpoint: target, wallClock: { clock.now }, monotonic: { clock.uptime })
        let client = try BridgeChannelClientOperation(owner: identity, endpoint: target)
        let challenge = try server.issueChallenge(client.hello)
        let proof = try await client.sign(challenge, now: clock.now)
        try server.reserveOpen(proof)
        clock.advance(11)
        XCTAssertThrowsError(try server.recheckBeforeActivation())
        XCTAssertThrowsError(try server.activate())
        server.close()
        let (revoked, _, _, otherProof) = try await handshake(identity)
        try revoked.reserveOpen(otherProof)
        revoked.revoke()
        XCTAssertThrowsError(try revoked.activate())
        XCTAssertEqual(revoked.state, .revoked)
    }

    func testMonotonicChannelExpiryWithStationaryWallClock() async throws {
        let clock = ChannelTestClock()
        let identity = await owner(), target = try endpoint()
        let server = try BridgeChannelSession(endpoint: target, wallClock: { clock.now }, monotonic: { clock.uptime })
        let client = try BridgeChannelClientOperation(owner: identity, endpoint: target)
        let challenge = try server.issueChallenge(client.hello)
        try server.reserveOpen(try await client.sign(challenge, now: clock.now))
        _ = try server.activate()
        clock.advance(301, advanceWall: false)
        XCTAssertThrowsError(try server.check())
        server.close()
    }

    func testClientRejectsNoncanonicalTranscriptMutationsBeforeSigning() async throws {
        let identity = await owner(), target = try endpoint()
        for key in ["profile", "endpoint", "clientNonce", "serverNonce", "direction", "channelExpiresAtMilliseconds", "issuedAtMilliseconds"] {
            let client = try BridgeChannelClientOperation(owner: identity, endpoint: target)
            let server = try BridgeChannelSession(endpoint: target)
            let challenge = try server.issueChallenge(client.hello)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: A.encode(challenge)) as? [String: Any])
            var transcript = try XCTUnwrap(object["transcript"] as? [String: Any])
            switch key {
            case "endpoint": transcript[key] = ["origin": "wss://attacker.example", "route": target.route, "domain": target.domain]
            case "clientNonce", "serverNonce": transcript[key] = Data(repeating: 1, count: 31).base64EncodedString()
            case "channelExpiresAtMilliseconds", "issuedAtMilliseconds": transcript[key] = A.milliseconds(Date()) + 1_000_000
            default: transcript[key] = "wrong"
            }
            object["transcript"] = transcript
            let changed = try JSONDecoder().decode(A.Challenge.self, from: JSONSerialization.data(withJSONObject: object))
            do { _ = try await client.sign(changed); XCTFail("Signed changed \(key)") } catch {}
            server.close()
        }
    }

    func testSelfConsistentWrongPublisherBridgeIDHostEnvironmentAndDomainAreRejected() async throws {
        let identity = await owner(), expected = try endpoint()
        for (url, domain) in [
            ("wss://bridge.example/bridgehead/Other/connection", "bridge"),
            ("wss://bridge.example/bridgehead/Protected/other", "bridge"),
            ("wss://other.example/bridgehead/Protected/connection", "bridge"),
            ("wss://staging.bridge.example/bridgehead/Protected/connection", "bridge"),
            (expected.audience, "other-domain")
        ] {
            let client = try BridgeChannelClientOperation(owner: identity, endpoint: expected)
            let other = try A.Endpoint(url: URL(string: url)!, domain: domain)
            let server = try BridgeChannelSession(endpoint: other)
            let challenge = try server.issueChallenge(client.hello)
            XCTAssertEqual(challenge.signingData, try A.signingData(challenge.transcript))
            do { _ = try await client.sign(challenge); XCTFail("Signed wrong scope \(url) \(domain)") } catch {}
            server.close()
        }
    }

    func testProofFromOtherInstanceOrBeforeRestartNeverMatchesNewPendingState() async throws {
        let identity = await owner(), target = try endpoint()
        let client = try BridgeChannelClientOperation(owner: identity, endpoint: target)
        let original = try BridgeChannelSession(endpoint: target)
        let challenge = try original.issueChallenge(client.hello), proof = try await client.sign(challenge)
        for restart in [false, true] {
            if restart { original.close() }
            let independent = try BridgeChannelSession(endpoint: target)
            let fresh = try independent.issueChallenge(client.hello)
            XCTAssertEqual(fresh.signingData, try A.signingData(fresh.transcript))
            XCTAssertNotEqual(fresh.transcript.sessionID, challenge.transcript.sessionID)
            XCTAssertThrowsError(try independent.reserveOpen(proof))
            XCTAssertEqual(independent.state, .challengeIssued)
            independent.close()
        }
    }

    func testSelfConsistentClockSkewBoundariesAndExcessiveValidity() async throws {
        let identity = await owner(), target = try endpoint()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (offset, allowed) in [(5.0, true), (5.001, false), (-29.999, true), (-30.0, false), (-30.001, false)] {
            let client = try BridgeChannelClientOperation(owner: identity, endpoint: target, wallClock: { now })
            let server = try BridgeChannelSession(endpoint: target, wallClock: { now.addingTimeInterval(offset) })
            let challenge = try server.issueChallenge(client.hello)
            do { _ = try await client.sign(challenge); XCTAssertTrue(allowed, "offset \(offset)") }
            catch { XCTAssertFalse(allowed, "offset \(offset): \(error)") }
            server.close()
        }
        for excessive in [false, true] {
            let client = try BridgeChannelClientOperation(owner: identity, endpoint: target, wallClock: { now })
            let server = try BridgeChannelSession(endpoint: target, wallClock: { now })
            let original = try server.issueChallenge(client.hello)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: A.encode(original.transcript)) as? [String: Any])
            if excessive { object["channelExpiresAtMilliseconds"] = original.transcript.channelExpiresAtMilliseconds + 1 }
            else {
                object["issuedAtMilliseconds"] = A.milliseconds(now) - 31_000
                object["channelExpiresAtMilliseconds"] = A.milliseconds(now) - 31_000 + 300_000
            }
            let transcript = try JSONDecoder().decode(A.Transcript.self, from: JSONSerialization.data(withJSONObject: object))
            let challenge = A.Challenge(transcript: transcript, signingData: try A.signingData(transcript))
            do { _ = try await client.sign(challenge); XCTFail("Self-consistent expired/excessive challenge") } catch {}
            server.close()
        }
    }

    func testWallClockExpiryAndBackwardSkewCannotExtendMonotonicLease() async throws {
        for wallOnly in [true, false] {
            let clock = ChannelTestClock(), identity = await owner(), target = try endpoint()
            let server = try BridgeChannelSession(endpoint: target, wallClock: { clock.now }, monotonic: { clock.uptime })
            let client = try BridgeChannelClientOperation(owner: identity, endpoint: target, wallClock: { clock.now }, monotonic: { clock.uptime })
            try server.reserveOpen(try await client.sign(server.issueChallenge(client.hello)))
            _ = try server.activate()
            if wallOnly { clock.moveWall(301) }
            else { clock.moveWall(-3600); clock.advance(301, advanceWall: false) }
            XCTAssertThrowsError(try server.check())
            server.close()
        }
        let clock = ChannelTestClock(), identity = await owner(), target = try endpoint()
        let server = try BridgeChannelSession(endpoint: target, wallClock: { clock.now }, monotonic: { clock.uptime })
        let client = try BridgeChannelClientOperation(owner: identity, endpoint: target, wallClock: { clock.now })
        try server.reserveOpen(try await client.sign(server.issueChallenge(client.hello)))
        clock.moveWall(31)
        XCTAssertThrowsError(try server.recheckBeforeActivation())
        XCTAssertThrowsError(try server.activate())
        server.close()
    }

    func testSuspendedLocalSignerCannotReturnProofAfterCancelOrClockExpiry() async throws {
        for action in ["cancel", "wall", "monotonic"] {
            let vault = SuspendingChannelVault(), identity = await owner(), clock = ChannelTestClock(), target = try endpoint()
            vault.underlying = identity.identityVault
            identity.identityVault = vault
            let entered = expectation(description: action)
            vault.entered = { entered.fulfill() }
            let client = try BridgeChannelClientOperation(owner: identity, endpoint: target, wallClock: { clock.now }, monotonic: { clock.uptime })
            let server = try BridgeChannelSession(endpoint: target, wallClock: { clock.now })
            let challenge = try server.issueChallenge(client.hello)
            let signing = Task { try await client.sign(challenge) }
            await fulfillment(of: [entered], timeout: 2)
            if action == "cancel" { await client.cancel() }
            if action == "wall" { clock.moveWall(31) }
            if action == "monotonic" { clock.advance(11, advanceWall: false) }
            await vault.resume()
            do { _ = try await signing.value; XCTFail("Late proof after \(action)") } catch {}
            server.close()
        }
    }

    func testConnectLeaseCannotSignTwiceOrAfterCancellation() async throws {
        let identity = await owner()
        let (_, client, challenge, _) = try await handshake(identity)
        do { _ = try await client.sign(challenge); XCTFail("Repeated signing") } catch {}
        let target = try endpoint()
        let cancelled = try BridgeChannelClientOperation(owner: identity, endpoint: target)
        let server = try BridgeChannelSession(endpoint: target)
        let fresh = try server.issueChallenge(cancelled.hello)
        await cancelled.cancel()
        do { _ = try await cancelled.sign(fresh); XCTFail("Cancelled signing") } catch {}
        server.close()
    }

    func testCanonicalDecodeRejectsIgnoredAndDuplicateFieldsAndOversize() async throws {
        let client = try BridgeChannelClientOperation(owner: await owner(), endpoint: endpoint())
        let bytes = try A.encode(client.hello)
        XCTAssertEqual(try A.decode(A.Hello.self, from: bytes), client.hello)
        var text = String(decoding: bytes, as: UTF8.self)
        text.insert(contentsOf: "\"ignored\":true,", at: text.index(after: text.startIndex))
        XCTAssertThrowsError(try A.decode(A.Hello.self, from: Data(text.utf8)))
        text = String(decoding: bytes, as: UTF8.self)
        text.insert(contentsOf: "\"profile\":\"\(A.profile)\",", at: text.index(after: text.startIndex))
        XCTAssertThrowsError(try A.decode(A.Hello.self, from: Data(text.utf8)))
        XCTAssertThrowsError(try A.decode(A.Hello.self, from: Data(repeating: 32, count: A.maximumEnvelopeBytes + 1)))
    }

    func testCanonicalEndpointRejectsInsecureNonlocalAndAmbiguousTargets() throws {
        for url in ["ws://remote.example/bridgehead/a/b", "wss://u:p@bridge.example/a", "wss://bridge.example/a?token=x",
                    "wss://bridge.example/a#fragment", "wss://bridge.example:443/a",
                    "wss://bridge.example:0/a", "wss://bridge.example:65536/a", "wss://bridge.example/a/%2e%2e/b"] {
            XCTAssertThrowsError(try A.Endpoint(url: XCTUnwrap(URL(string: url)), domain: "bridge", allowInsecureLoopback: true), url)
        }
        XCTAssertThrowsError(try A.Endpoint(url: XCTUnwrap(URL(string: "ws://localhost/a")), domain: "bridge"))
        _ = try A.Endpoint(url: XCTUnwrap(URL(string: "ws://127.0.0.1:9000/a")), domain: "bridge", allowInsecureLoopback: true)
    }

    func testQuotasAreGlobalPerSourceAndPerProvenKeyAndReleaseOnClose() async throws {
        var configuration = BridgeChannelLimits.Configuration()
        configuration.maximumConnections = 2; configuration.maximumPending = 2
        configuration.maximumPendingPerSource = 1; configuration.maximumConnectionsPerKey = 1
        let limits = BridgeChannelLimits(configuration: configuration)
        let first = try BridgeChannelSession(endpoint: endpoint(), limits: limits, source: "one")
        XCTAssertThrowsError(try BridgeChannelSession(endpoint: endpoint(), limits: limits, source: "one"))
        let second = try BridgeChannelSession(endpoint: endpoint(), limits: limits, source: "two")
        XCTAssertThrowsError(try BridgeChannelSession(endpoint: endpoint(), limits: limits, source: "three"))
        let identity = await owner(), client = try BridgeChannelClientOperation(owner: identity, endpoint: endpoint())
        try first.reserveOpen(try await client.sign(first.issueChallenge(client.hello)))
        _ = try first.activate()
        let another = try BridgeChannelClientOperation(owner: identity, endpoint: endpoint())
        let proof = try await another.sign(second.issueChallenge(another.hello))
        XCTAssertThrowsError(try second.reserveOpen(proof))
        second.close()
        limits.revoke(identity: try A.PublicIdentity(identity), domain: "bridge")
        XCTAssertEqual(first.state, .revoked)
        XCTAssertEqual(limits.connectionCount, 0)
    }

    func testVerifyingConnectionRetainsPreAuthQuotaUntilActivation() async throws {
        var config = BridgeChannelLimits.Configuration()
        config.maximumPending = 1; config.maximumPendingPerSource = 1
        let limits = BridgeChannelLimits(configuration: config)
        let identity = await owner()
        let session = try BridgeChannelSession(endpoint: endpoint(), limits: limits, source: "one")
        let client = try BridgeChannelClientOperation(owner: identity, endpoint: endpoint())
        try session.reserveOpen(try await client.sign(session.issueChallenge(client.hello)))
        XCTAssertEqual(session.state, .verifying)
        XCTAssertThrowsError(try BridgeChannelSession(endpoint: endpoint(), limits: limits, source: "two"))
        _ = try session.activate()
        let next = try BridgeChannelSession(endpoint: endpoint(), limits: limits, source: "two")
        next.close(); session.close()
        XCTAssertEqual(limits.connectionCount, 0)
    }

    func testRateLimitsSurviveCloseAndDoNotUseUnprovedVictimIdentity() async throws {
        let clock = ChannelTestClock()
        var config = BridgeChannelLimits.Configuration()
        config.maximumAttemptsPerMinute = 3
        config.maximumAttemptsPerSourcePerMinute = 1
        config.maximumVerifiedHandshakesPerKeyPerMinute = 1
        let limits = BridgeChannelLimits(configuration: config, monotonic: { clock.uptime })
        let identity = await owner()
        func prove(_ source: String) async throws -> BridgeChannelSession {
            let session = try BridgeChannelSession(endpoint: endpoint(), limits: limits, source: source)
            let client = try BridgeChannelClientOperation(owner: identity, endpoint: endpoint())
            do { try session.reserveOpen(try await client.sign(session.issueChallenge(client.hello))); _ = try session.activate() }
            catch { session.close(); throw error }
            return session
        }
        let first = try await prove("one")
        first.close()
        XCTAssertThrowsError(try BridgeChannelSession(endpoint: endpoint(), limits: limits, source: "one"))
        do { _ = try await prove("two"); XCTFail("Verified key rate survives disconnect") } catch {}
        XCTAssertThrowsError(try BridgeChannelSession(endpoint: endpoint(), limits: limits, source: "three"))
        XCTAssertEqual(limits.connectionCount, 0)
        clock.advance(61)
        let renewed = try await prove("one")
        renewed.close()
        var tiny = BridgeChannelLimits.Configuration(); tiny.maximumRateBuckets = 1
        let bounded = BridgeChannelLimits(configuration: tiny)
        XCTAssertThrowsError(try BridgeChannelSession(endpoint: endpoint(), limits: bounded, source: "new-source"))
        XCTAssertEqual(bounded.connectionCount, 0)
    }

    func testSharedResourceQuotasAndPendingAuditReleaseWithoutEviction() async throws {
        var config = BridgeChannelLimits.Configuration()
        config.maximumOperationsPerKey = 1; config.maximumFeedsPerKey = 1; config.maximumChannelsPerKey = 1
        config.maximumPendingSendBytes = 10; config.maximumPendingSendBytesPerConnection = 8
        let limits = BridgeChannelLimits(configuration: config), identity = await owner()
        var sessions: [BridgeChannelSession] = []
        for source in ["one", "two"] {
            let session = try BridgeChannelSession(endpoint: endpoint(), limits: limits, source: source)
            let client = try BridgeChannelClientOperation(owner: identity, endpoint: endpoint())
            try session.reserveOpen(try await client.sign(session.issueChallenge(client.hello))); _ = try session.activate()
            sessions.append(session)
        }
        for resource in [BridgeChannelLimits.Resource.operation, .feed, .channel] {
            try sessions[0].acquire(resource)
            XCTAssertThrowsError(try sessions[1].acquire(resource))
            sessions[0].release(resource)
            try sessions[1].acquire(resource); sessions[1].release(resource)
        }
        try sessions[0].acquireSend(bytes: 8)
        XCTAssertThrowsError(try sessions[0].acquireSend(bytes: 1))
        XCTAssertThrowsError(try sessions[1].acquireSend(bytes: 3))
        try sessions[1].acquireSend(bytes: 2)
        sessions[0].close()
        XCTAssertThrowsError(try sessions[1].acquireSend(bytes: 6))
        sessions[0].releaseSend(bytes: 8)
        try sessions[1].acquireSend(bytes: 6)
        sessions[1].releaseSend(bytes: 8)
        sessions[1].close(); XCTAssertEqual(limits.connectionCount, 0)
        let audit = BridgeBaseAuditor(maximumPendingCommands: 1)
        let command = BridgeCommand(cmd: "set", payload: nil, cid: 1)
        let accepted = await audit.storeBridgeCommand(command, for: 1)
        let refused = await audit.storeBridgeCommand(command, for: 2)
        let retained = await audit.loadBridgeCommandForCommandId(1)
        XCTAssertTrue(accepted); XCTAssertFalse(refused); XCTAssertNotNil(retained)
        await audit.clear()
        let count = await audit.pendingCommandCount(); XCTAssertEqual(count, 0)
    }

    func testBoundedReplayStoreDoesNotEvictUnexpiredUsedNonce() async throws {
        let identity = await owner(), store = CellSecuritySigningChallengeReplayStore(maximumEntries: 1)
        let challenge = try IdentitySigningChallenge.validateSigningData(IdentitySigningChallenge.signingData(
            for: identity, trustedIdentity: identity, domain: "bridge", resource: "resource", action: "checkIdentityOrigin",
            audience: "GeneralCell", nonce: Data(repeating: 1, count: 32)), for: identity)
        var next = challenge; next.nonce = Data(repeating: 2, count: 32)
        let first = await store.consume(challenge), full = await store.consume(next), repeated = await store.consume(challenge)
        XCTAssertEqual(first, .accepted); XCTAssertEqual(full, .capacity); XCTAssertEqual(repeated, .replay)
    }
}

private final class ChannelTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    private var time: TimeInterval = 100
    var now: Date { lock.withLock { date } }
    var uptime: TimeInterval { lock.withLock { time } }
    func moveWall(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
    func advance(_ seconds: TimeInterval, advanceWall: Bool = true) {
        lock.withLock { time += seconds; if advanceWall { date.addTimeInterval(seconds) } }
    }
}

actor SigningTrapVault: IdentityVaultProtocol {
    var calls = 0
    func initialize() async -> IdentityVaultProtocol { self }
    func addIdentity(identity: inout Identity, for identityContext: String) async { XCTFail("Server must not store client identity") }
    func saveIdentity(_ identity: Identity) async { XCTFail("Server must not store client identity") }
    func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity? { nil }
    func identityExistInVault(_ identity: Identity) async -> Bool { false }
    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        calls += 1; XCTFail("Server signer must never be used for channel authentication")
        throw BridgeChannelAuthentication.Failure.invalidProof
    }
    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool { false }
    func randomBytes64() async -> Data? { nil }
    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) { throw BridgeChannelAuthentication.Failure.unavailable }
}

private final class SuspendingChannelVault: IdentityVaultProtocol, @unchecked Sendable {
    var underlying: IdentityVaultProtocol?
    var entered: (() -> Void)?
    private let barrier = SigningBarrier()
    func resume() async { await barrier.resume() }
    func initialize() async -> IdentityVaultProtocol { self }
    func addIdentity(identity: inout Identity, for identityContext: String) async {}
    func saveIdentity(_ identity: Identity) async {}
    func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity? { nil }
    func identityExistInVault(_ identity: Identity) async -> Bool { await underlying?.identityExistInVault(identity) ?? false }
    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        entered?(); await barrier.wait()
        return try await underlying!.signMessageForIdentity(messageData: messageData, identity: identity)
    }
    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool { false }
    func randomBytes64() async -> Data? { nil }
    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) { throw BridgeChannelAuthentication.Failure.unavailable }
}
private actor SigningBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func resume() { released = true; continuation?.resume(); continuation = nil }
}
