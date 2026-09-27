// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import Crypto

/// Transport admission only: this profile grants no Cell permissions.
public enum BridgeChannelAuthentication {
    public static let profile = "org.haven.bridge-channel.v1"
    public static let action = "openBridgeChannel"
    public static let maximumEnvelopeBytes = 16 * 1024
    public static let challengeLifetime: TimeInterval = 30
    public static let channelLifetime: TimeInterval = 300

    public enum Failure: String, Error, Sendable {
        case malformed, unexpectedMessage, identityMismatch, invalidProof, expired
        case revoked, closed, capacity, insecureEndpoint, staleGeneration, unavailable
    }

    /// Intentionally not Identity.Codable: no properties, grants, vault reference,
    /// key-agreement key, display name or private-key flag can enter this envelope.
    public struct PublicIdentity: Codable, Equatable, Sendable {
        public let uuid: String
        public let algorithm: CurveAlgorithm
        public let curve: CurveType
        public let publicKey: Data

        public init(_ identity: Identity) throws {
            guard let descriptor = IdentityPublicKeySignatureVerifier.descriptor(for: identity) else {
                throw Failure.malformed
            }
            uuid = descriptor.uuid
            algorithm = descriptor.algorithm
            curve = descriptor.curveType
            publicKey = descriptor.publicKey
            try validate()
        }

        public func validate() throws {
            guard !uuid.isEmpty, uuid.utf8.count <= 512 else { throw Failure.malformed }
            switch (algorithm, curve) {
            case (.EdDSA, .Curve25519):
                guard (try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)) != nil else { throw Failure.malformed }
            case (.ECDSA, .P256):
                guard (try? P256.Signing.PublicKey(compressedRepresentation: publicKey)) != nil
                    || (try? P256.Signing.PublicKey(x963Representation: publicKey)) != nil else { throw Failure.malformed }
            default: throw Failure.malformed
            }
        }

        public func makeIdentity() -> Identity {
            let identity = Identity(uuid, displayName: "", identityVault: nil)
            identity.publicSecureKey = SecureKey(date: Date(timeIntervalSince1970: 0), privateKey: false,
                use: .signature, algorithm: algorithm, size: 256, curveType: curve,
                x: nil, y: nil, compressedKey: publicKey)
            identity.properties = nil
            identity.homeVaultReference = nil
            return identity
        }
    }

    /// Construct from a locally selected URL, never Host/Forwarded headers or a
    /// peer-supplied audience. No redirects or insecure remote fallback are allowed.
    public struct Endpoint: Codable, Equatable, Sendable {
        public let origin: String
        public let route: String
        public let domain: String
        public var audience: String { origin + route }

        public func validate() throws {
            guard let url = URL(string: audience),
                  try Endpoint(url: url, domain: domain, allowInsecureLoopback: origin.hasPrefix("ws://")) == self else {
                throw Failure.malformed
            }
        }

        public init(url: URL, domain: String, allowInsecureLoopback: Bool = false) throws {
            guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let scheme = c.scheme, let host = c.host,
                  c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
                  scheme == scheme.lowercased(), host == host.lowercased(),
                  !host.isEmpty, !host.hasSuffix("."),
                  !c.path.isEmpty, c.path.hasPrefix("/"), !c.path.contains("//"),
                  !c.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
                  c.percentEncodedPath == c.path,
                  !domain.isEmpty, domain.utf8.count <= 512 else { throw Failure.malformed }
            guard scheme == "wss" || (allowInsecureLoopback && scheme == "ws"
                && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)) else { throw Failure.insecureEndpoint }
            guard c.port != 443 || scheme != "wss", c.port != 80 || scheme != "ws" else { throw Failure.malformed }
            var originComponents = c
            originComponents.path = ""
            guard let origin = originComponents.string, (origin + c.path).utf8.count <= 512 else { throw Failure.malformed }
            self.origin = origin
            route = c.path
            self.domain = domain
        }
    }

    public struct Hello: Codable, Equatable, Sendable {
        public let profile: String
        public let identity: PublicIdentity
        public let clientNonce: Data
        public init(identity: PublicIdentity) {
            profile = BridgeChannelAuthentication.profile
            self.identity = identity
            clientNonce = randomNonce()
        }
    }

    /// Canonical JSON object (sorted UTF-8 keys, unescaped slashes, base64 Data,
    /// integer milliseconds). SHA-256 is domain separated by the fixed profile.
    /// Route contains publisher and bridge ID without ambiguous concatenation.
    public struct Transcript: Codable, Equatable, Sendable {
        public let profile: String
        public let endpoint: Endpoint
        public let identity: PublicIdentity
        public let clientNonce: Data
        public let serverNonce: Data
        public let sessionID: String
        public let generation: String
        public let direction: String
        public let issuedAtMilliseconds: Int64
        public let channelExpiresAtMilliseconds: Int64
    }

    public struct Challenge: Codable, Equatable, Sendable {
        public let transcript: Transcript
        public let signingData: Data
    }
    public struct Proof: Codable, Equatable, Sendable {
        public let sessionID: String
        public let generation: String
        public let signature: Data
        public init(sessionID: String, generation: String, signature: Data) {
            self.sessionID = sessionID; self.generation = generation; self.signature = signature
        }
    }
    public struct Authenticated: Codable, Equatable, Sendable {
        public let sessionID: String
        public let generation: String
        public let transcriptDigest: String
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Codable>(_ type: T.Type, from bytes: Data) throws -> T {
        guard bytes.count <= maximumEnvelopeBytes,
              let value = try? JSONDecoder().decode(type, from: bytes),
              try encode(value) == bytes else { throw Failure.malformed }
        return value
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func randomNonce() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    static func milliseconds(_ now: Date) -> Int64 { Int64((now.timeIntervalSince1970 * 1000).rounded(.down)) }

    static func challenge(hello: Hello, endpoint: Endpoint, generation: String, now: Date) throws -> Challenge {
        guard hello.profile == profile, hello.clientNonce.count == 32 else { throw Failure.malformed }
        try hello.identity.validate()
        let issued = milliseconds(now)
        let transcript = Transcript(profile: profile, endpoint: endpoint, identity: hello.identity,
            clientNonce: hello.clientNonce, serverNonce: randomNonce(), sessionID: UUID().uuidString,
            generation: generation, direction: "client-to-server", issuedAtMilliseconds: issued,
            channelExpiresAtMilliseconds: issued + Int64(channelLifetime * 1000))
        return Challenge(transcript: transcript, signingData: try signingData(transcript))
    }

    static func signingData(_ transcript: Transcript) throws -> Data {
        let identity = transcript.identity.makeIdentity()
        let challenge = IdentitySigningChallenge(identityUUID: identity.uuid,
            publicKeyFingerprint: identity.signingPublicKeyFingerprint,
            domain: transcript.endpoint.domain,
            resource: profile + ":" + digest(try encode(transcript)), action: action,
            audience: transcript.endpoint.audience, nonce: transcript.serverNonce,
            issuedAt: Date(timeIntervalSince1970: Double(transcript.issuedAtMilliseconds) / 1000),
            validity: challengeLifetime)
        // Reuse IdentitySigningChallenge's exact canonical JSON encoding.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(challenge)
    }
}
