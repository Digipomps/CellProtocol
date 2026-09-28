// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import Foundation
import Crypto

/// Mutual Multipeer admission. Peer labels correlate an explicitly accepted
/// invitation, never grant Cell authority. This is not the WebSocket profile.
public enum BridgePeerChannelAuthentication {
    public typealias Auth = BridgeChannelAuthentication
    public static let profile = "org.haven.bridge-peer-channel.v2"
    public enum Role: String, Codable, Sendable {
        case initiator, responder
        var opposite: Self { self == .initiator ? .responder : .initiator }
    }
    public struct Endpoint: Codable, Equatable, Sendable {
        public let initiator: String
        public let responder: String
        public let setupID: String
        public let domain: String
        public init(initiator: String, responder: String, setupID: String, domain: String) throws {
            self.initiator = initiator; self.responder = responder; self.setupID = setupID; self.domain = domain
            try validate()
        }
        func validate() throws {
            guard !initiator.isEmpty, !responder.isEmpty, initiator != responder,
                  initiator.utf8.count <= 512, responder.utf8.count <= 512,
                  UUID(uuidString: setupID) != nil, !domain.isEmpty, domain.utf8.count <= 512 else { throw Auth.Failure.malformed }
        }
        var audience: String { profile + ":" + Auth.digest(try! Auth.encode(self)) }
    }
    public struct Hello: Codable, Equatable, Sendable {
        public let profile: String
        public let endpoint: Endpoint
        public let role: Role
        public let identity: Auth.PublicIdentity
        public let ephemeralPublicKey: Data
        public let nonce: Data
        public let generation: String
        public let issuedAtMilliseconds: Int64
    }
    public struct Transcript: Codable, Equatable, Sendable {
        public let initiator: Hello
        public let responder: Hello
        public let signer: Role
        var signedHello: Hello { signer == .initiator ? initiator : responder }
        var verifierHello: Hello { signer == .initiator ? responder : initiator }
        var issued: Int64 { min(initiator.issuedAtMilliseconds, responder.issuedAtMilliseconds) }
    }
    struct Challenge: Equatable, Sendable {
        let transcript: Transcript
        let signingData: Data
        var identity: Auth.PublicIdentity { transcript.signedHello.identity }
        var generation: String { transcript.verifierHello.generation }
        var sessionID: String { transcript.initiator.endpoint.setupID }
    }
    public struct Offer: Codable, Sendable {
        public let hello: Hello
        public let proof: Auth.Proof
    }
    static func challenge(local: Hello, remote: Hello, signer: Role) throws -> Challenge {
        let transcript = Transcript(initiator: local.role == .initiator ? local : remote,
                                    responder: local.role == .responder ? local : remote, signer: signer)
        let identity = transcript.signedHello.identity.makeIdentity()
        let signing = IdentitySigningChallenge(identityUUID: identity.uuid,
            publicKeyFingerprint: identity.signingPublicKeyFingerprint, domain: local.endpoint.domain,
            resource: profile + ":" + Auth.digest(try Auth.encode(transcript)), action: "openPeerBridgeChannel",
            audience: local.endpoint.audience, nonce: transcript.verifierHello.nonce,
            issuedAt: Date(timeIntervalSince1970: Double(transcript.issued) / 1000), validity: Auth.challengeLifetime)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Challenge(transcript: transcript, signingData: try encoder.encode(signing))
    }

    /// The same one-shot local-vault discipline as the WS connect operation,
    /// with a separately validated mutual transcript and no URL interpretation.
    actor Operation {
        nonisolated let hello: Hello
        private let owner: Identity
        private let deadline = ProcessInfo.processInfo.systemUptime + 10
        private var active = true
        private var outgoing: Challenge?
        private var signingStarted = false
        private var ephemeral: Curve25519.KeyAgreement.PrivateKey?
        init(owner: Identity, endpoint: Endpoint, role: Role, generation: String) throws {
            try endpoint.validate()
            self.owner = owner.publicIdentitySnapshot(); self.owner.identityVault = owner.identityVault
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            self.ephemeral = ephemeral
            hello = Hello(profile: profile, endpoint: endpoint, role: role, identity: try Auth.PublicIdentity(owner),
                          ephemeralPublicKey: ephemeral.publicKey.rawRepresentation, nonce: Auth.randomNonce(), generation: generation, issuedAtMilliseconds: Auth.milliseconds(Date()))
        }
        func prepare(_ remote: Hello) throws -> Challenge {
            guard active, outgoing == nil, ProcessInfo.processInfo.systemUptime < deadline,
                  remote.profile == profile, remote.endpoint == hello.endpoint, remote.role == hello.role.opposite,
                  remote.ephemeralPublicKey.count == 32, remote.nonce.count == 32, UUID(uuidString: remote.generation) != nil,
                  remote.issuedAtMilliseconds <= Auth.milliseconds(Date()) + 5_000,
                  remote.issuedAtMilliseconds > Auth.milliseconds(Date()) - 10_000 else { throw Auth.Failure.invalidProof }
            try remote.identity.validate()
            outgoing = try challenge(local: hello, remote: remote, signer: hello.role)
            return try challenge(local: hello, remote: remote, signer: remote.role)
        }
        func sign() async throws -> Auth.Proof {
            guard active, !signingStarted, let outgoing, ProcessInfo.processInfo.systemUptime < deadline,
                  let vault = owner.identityVault, !(vault is BridgeIdentityVault) else { throw Auth.Failure.invalidProof }
            _ = try IdentitySigningChallenge.validateSigningData(outgoing.signingData, for: owner)
            signingStarted = true
            guard await vault.identityExistInVault(owner), active else { throw Auth.Failure.identityMismatch }
            let signature = try await vault.signMessageForIdentity(messageData: outgoing.signingData, identity: owner)
            guard active, ProcessInfo.processInfo.systemUptime < deadline,
                  IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: outgoing.signingData, identity: owner) else { throw Auth.Failure.staleGeneration }
            _ = try IdentitySigningChallenge.validateSigningData(outgoing.signingData, for: owner)
            return Auth.Proof(sessionID: outgoing.sessionID, generation: outgoing.generation, signature: signature)
        }
        func finish(_ acknowledgement: Auth.Authenticated) throws {
            guard active, signingStarted, let outgoing, ProcessInfo.processInfo.systemUptime < deadline,
                  acknowledgement.sessionID == outgoing.sessionID, acknowledgement.generation == outgoing.generation,
                  acknowledgement.transcriptDigest == Auth.digest(try Auth.encode(outgoing.transcript)) else { throw Auth.Failure.invalidProof }
            active = false
        }
        func deriveRecordLayer() throws -> BridgePeerRecordLayer {
            guard active, signingStarted, let outgoing, let ephemeral else { throw Auth.Failure.unexpectedMessage }
            // One use, including failure. Never persist or export the ephemeral secret.
            defer { self.ephemeral = nil }
            return try BridgePeerRecordLayer(local: hello, remote: outgoing.transcript.verifierHello, privateKey: ephemeral)
        }
        func cancel() { active = false; outgoing = nil; ephemeral = nil }
    }
}
