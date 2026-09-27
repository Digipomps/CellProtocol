// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// A single locally initiated connect operation, distinct from the GeneralCell
/// origin-proof lease. A peer can neither create this permit nor broaden it.
public actor BridgeChannelClientOperation {
    public typealias Auth = BridgeChannelAuthentication
    public nonisolated let hello: Auth.Hello
    public nonisolated let endpoint: Auth.Endpoint
    private let owner: Identity
    private let deadline: TimeInterval
    private var active = true
    private var signingStarted = false
    private var challengeValue: Auth.Challenge?

    public init(owner: Identity, endpoint: Auth.Endpoint) throws {
        self.owner = owner.publicIdentitySnapshot()
        self.owner.identityVault = owner.identityVault
        self.endpoint = endpoint
        hello = Auth.Hello(identity: try Auth.PublicIdentity(owner))
        deadline = ProcessInfo.processInfo.systemUptime + 10
    }
    public func cancel() { active = false; challengeValue = nil }

    public func sign(_ challenge: Auth.Challenge, now: Date = Date()) async throws -> Auth.Proof {
        let t = challenge.transcript
        guard active, !signingStarted, ProcessInfo.processInfo.systemUptime < deadline,
              t.profile == Auth.profile, t.direction == "client-to-server", t.endpoint == endpoint,
              t.identity == hello.identity, t.clientNonce == hello.clientNonce,
              t.serverNonce.count == 32, UUID(uuidString: t.sessionID) != nil,
              UUID(uuidString: t.generation) != nil,
              t.issuedAtMilliseconds > 0, t.issuedAtMilliseconds < 9_000_000_000_000_000,
              t.channelExpiresAtMilliseconds > 0, t.channelExpiresAtMilliseconds < 9_000_000_000_000_000,
              t.issuedAtMilliseconds <= Auth.milliseconds(now) + 5_000,
              t.issuedAtMilliseconds > Auth.milliseconds(now) - 30_000,
              t.channelExpiresAtMilliseconds > Auth.milliseconds(now),
              t.channelExpiresAtMilliseconds - t.issuedAtMilliseconds == Int64(Auth.channelLifetime * 1000),
              challenge.signingData == (try Auth.signingData(t)),
              let vault = owner.identityVault,
              !(vault is BridgeIdentityVault) else { throw Auth.Failure.invalidProof }
        _ = try IdentitySigningChallenge.validateSigningData(challenge.signingData, for: owner, now: now)
        // Consume before the first await: one malicious challenge cannot trigger
        // concurrent signing or extend a permit while the vault is suspended.
        signingStarted = true
        guard await vault.identityExistInVault(owner), active else { throw Auth.Failure.identityMismatch }
        let signature = try await vault.signMessageForIdentity(messageData: challenge.signingData, identity: owner)
        guard active, ProcessInfo.processInfo.systemUptime < deadline,
              IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: challenge.signingData, identity: hello.identity.makeIdentity()) else {
            throw Auth.Failure.staleGeneration
        }
        challengeValue = challenge
        return Auth.Proof(sessionID: t.sessionID, generation: t.generation, signature: signature)
    }
    func finish(_ acknowledgement: Auth.Authenticated, session: BridgeChannelSession) throws {
        guard active, let challengeValue, ProcessInfo.processInfo.systemUptime < deadline else { throw Auth.Failure.unexpectedMessage }
        try session.acceptAcknowledgement(acknowledgement, challenge: challengeValue)
        active = false
        self.challengeValue = nil
    }
}
