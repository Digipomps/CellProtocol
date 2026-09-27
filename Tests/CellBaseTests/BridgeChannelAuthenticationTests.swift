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

    func testReplayWrongConnectionRouteDomainGenerationAndParallelConsume() async throws {
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

    func testAbsoluteAndMonotonicChannelExpiry() async throws {
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

    func testClientRejectsWrongScopeFutureTimeAndChangedTranscriptBeforeSigning() async throws {
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
                    "wss://bridge.example/a#fragment", "wss://bridge.example:443/a", "wss://bridge.example/a/%2e%2e/b"] {
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
    func advance(_ seconds: TimeInterval, advanceWall: Bool = true) {
        lock.withLock { time += seconds; if advanceWall { date.addTimeInterval(seconds) } }
    }
}

private actor SigningTrapVault: IdentityVaultProtocol {
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
