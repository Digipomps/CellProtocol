// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import XCTest
import Crypto
@testable import CellBase

final class BridgeCanonicalKeyQuotaTests: XCTestCase {
    typealias A = BridgeChannelAuthentication
    typealias P = BridgePeerChannelAuthentication

    // Real signatures over each profile's exact transcript, without OS key storage.
    private struct Key {
        let p256 = P256.Signing.PrivateKey()
        let ed25519 = Curve25519.Signing.PrivateKey()
        let ed: Bool
        func identity(_ index: Int) throws -> A.PublicIdentity {
            let identity = Identity("synthetic-uuid-\(index)", displayName: "", identityVault: nil)
            identity.publicSecureKey = SecureKey(date: Date(), privateKey: false, use: .signature,
                algorithm: ed ? .EdDSA : .ECDSA, size: 256, curveType: ed ? .Curve25519 : .P256,
                x: nil, y: nil, compressedKey: ed ? ed25519.publicKey.rawRepresentation
                    : index.isMultiple(of: 2) ? p256.publicKey.compressedRepresentation : p256.publicKey.x963Representation)
            return try A.PublicIdentity(identity)
        }
        func sign(_ data: Data) throws -> Data {
            if ed { return try ed25519.signature(for: data) }
            return try p256.signature(for: data).derRepresentation
        }
    }
    private func open(_ key: Key, _ index: Int, peer: Bool, limits: BridgeChannelLimits) throws -> BridgeChannelSession {
        let identity = try key.identity(index), domain = "domain-\(index)"
        let session: BridgeChannelSession, proof: A.Proof
        if peer {
            let endpoint = try P.Endpoint(initiator: "remote", responder: "local", setupID: UUID().uuidString, domain: domain)
            let localIdentity = try Key(ed: false).identity(999)
            session = try BridgeChannelSession(peerEndpoint: endpoint, localIdentity: localIdentity, limits: limits, source: "peer-\(index)")
            func hello(_ role: P.Role, _ identity: A.PublicIdentity, _ generation: String) -> P.Hello {
                .init(profile: P.profile, endpoint: endpoint, role: role, identity: identity,
                      ephemeralPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                      nonce: A.randomNonce(), generation: generation, issuedAtMilliseconds: A.milliseconds(Date()))
            }
            let challenge = try P.challenge(local: hello(.responder, localIdentity, session.generation),
                remote: hello(.initiator, identity, UUID().uuidString), signer: .initiator)
            try session.issuePeerChallenge(challenge)
            proof = .init(sessionID: challenge.sessionID, generation: challenge.generation, signature: try key.sign(challenge.signingData))
        } else {
            let endpoint = try A.Endpoint(url: URL(string: "wss://quota.example/bridgehead/test/\(index)")!, domain: domain)
            session = try BridgeChannelSession(endpoint: endpoint, limits: limits, source: "ws-\(index)")
            let challenge = try session.issueChallenge(.init(identity: identity))
            proof = .init(sessionID: challenge.transcript.sessionID, generation: session.generation, signature: try key.sign(challenge.signingData))
        }
        do {
            try session.reserveOpen(proof)
            _ = try session.activate()
            try session.check(identity: identity.makeIdentity(), requiresIdentity: true)
            return session
        } catch { session.close(); throw error }
    }

    func testCanonicalKeyNormalizesP256AndEd25519ButPreservesAuthorizationPrincipal() throws {
        for ed in [false, true] {
            let key = Key(ed: ed), first = try key.identity(0)
            for index in 1...20 {
                let alias = try key.identity(index)
                XCTAssertEqual(try first.quotaKeyIdentifier(), try alias.quotaKeyIdentifier())
                XCTAssertNotEqual(BridgeChannelLimits.principal(identity: first, domain: "one"),
                                  BridgeChannelLimits.principal(identity: alias, domain: "one"))
            }
            XCTAssertNotEqual(try first.quotaKeyIdentifier(), try Key(ed: ed).identity(0).quotaKeyIdentifier())
            let limits = BridgeChannelLimits()
            let firstSession = try open(key, 0, peer: false, limits: limits)
            let aliasSession = try open(key, 1, peer: true, limits: limits)
            XCTAssertThrowsError(try firstSession.check(identity: key.identity(1).makeIdentity(), requiresIdentity: true))
            limits.revoke(identity: first, domain: "domain-0")
            XCTAssertEqual(firstSession.state, .revoked)
            XCTAssertEqual(aliasSession.state, .authenticated)
            aliasSession.close()
        }
    }

    func testConnectionQuotaRejectsManyUUIDsAndEncodingsWithoutUndercountingForWSAndPeer() throws {
        for peer in [false, true] {
            for ed in [false, true] {
                var config = BridgeChannelLimits.Configuration()
                config.maximumConnectionsPerKey = 2
                config.maximumVerifiedHandshakesPerKeyPerMinute = 64
                let limits = BridgeChannelLimits(configuration: config), key = Key(ed: ed)
                let first = try open(key, 0, peer: peer, limits: limits)
                let second = try open(key, 1, peer: peer, limits: limits)
                // A closed connection still owns its lease and its key slot.
                let lease = try BridgeChannelResourceLease(session: first, resource: .operation)
                first.close()
                for index in 2...17 {
                    XCTAssertThrowsError(try open(key, index, peer: peer, limits: limits)) {
                        XCTAssertEqual($0 as? A.Failure, .capacity)
                    }
                    XCTAssertEqual(limits.retainedConnectionCount, 2)
                }
                let independent = try open(Key(ed: ed), 100, peer: peer, limits: limits)
                try independent.check()
                lease.release()
                let replacement = try open(key, 18, peer: peer, limits: limits)
                first.close(); lease.release()
                XCTAssertThrowsError(try open(key, 19, peer: peer, limits: limits))
                second.close(); replacement.close(); independent.close()
                XCTAssertEqual(limits.retainedConnectionCount, 0)
            }
        }
    }

    func testVerifiedHandshakeRateSurvivesUUIDEncodingDomainAndTransportRotation() throws {
        for peer in [false, true] {
            for ed in [false, true] {
                var config = BridgeChannelLimits.Configuration()
                config.maximumVerifiedHandshakesPerKeyPerMinute = 3
                let clock = QuotaWindowClock(), limits = BridgeChannelLimits(configuration: config, monotonic: { clock.now })
                let key = Key(ed: ed)
                for index in 0..<3 { try open(key, index, peer: peer, limits: limits).close() }
                for index in 3...18 {
                    XCTAssertThrowsError(try open(key, index, peer: index.isMultiple(of: 2) ? peer : !peer, limits: limits)) {
                        XCTAssertEqual($0 as? A.Failure, .capacity)
                    }
                    XCTAssertEqual(limits.retainedConnectionCount, 0)
                }
                try open(Key(ed: ed), 100, peer: peer, limits: limits).close()
                clock.advance(60)
                try open(key, 19, peer: peer, limits: limits).close()
            }
        }
    }

    func testOperationFeedAndChannelQuotasShareCanonicalKeyAcrossWSAndPeerAndRetainLeases() throws {
        for resource in [BridgeChannelLimits.Resource.operation, .feed, .channel] {
            for ed in [false, true] {
                var config = BridgeChannelLimits.Configuration()
                config.maximumConnectionsPerKey = 32
                config.maximumVerifiedHandshakesPerKeyPerMinute = 32
                config.maximumOperationsPerKey = 2; config.maximumFeedsPerKey = 2; config.maximumChannelsPerKey = 2
                let limits = BridgeChannelLimits(configuration: config), key = Key(ed: ed)
                var sessions: [BridgeChannelSession] = []
                defer { sessions.forEach { $0.close() } }
                for index in 0..<12 { sessions.append(try open(key, index, peer: index.isMultiple(of: 2), limits: limits)) }
                let first = try BridgeChannelResourceLease(session: sessions[0], resource: resource)
                let second = try BridgeChannelResourceLease(session: sessions[1], resource: resource)
                sessions[0].close()
                for session in sessions.dropFirst(2) {
                    XCTAssertThrowsError(try BridgeChannelResourceLease(session: session, resource: resource)) {
                        XCTAssertEqual($0 as? A.Failure, .capacity)
                    }
                }
                let independent = try open(Key(ed: ed), 100, peer: false, limits: limits)
                let independentLease = try BridgeChannelResourceLease(session: independent, resource: resource)
                first.release()
                let replacement = try BridgeChannelResourceLease(session: sessions[2], resource: resource)
                first.release()
                XCTAssertThrowsError(try BridgeChannelResourceLease(session: sessions[3], resource: resource))
                second.release(); replacement.release(); independentLease.release(); independent.close()
                sessions.forEach { $0.close() }
                XCTAssertEqual(limits.retainedConnectionCount, 0)
            }
        }
    }
}

private final class QuotaWindowClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}
