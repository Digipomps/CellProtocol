// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum SecretCredentialError: Error, Equatable {
    case invalidContract, denied, unavailable, missing, alreadyExists, staleVersion, replay, expired, locked, cancelled, integrity
}

/// Trusted-process material only. Never Codable, Flow content, Explore, logging or a model tool argument.
public struct SecretKeyMaterial: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let bytes: Data
    public init(_ bytes: Data) throws {
        guard bytes.count == 32 else { throw SecretCredentialError.invalidContract }
        self.bytes = bytes
    }
    public static func generate() -> Self {
        try! Self(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }
    public func withBytes<T>(_ use: (Data) throws -> T) rethrows -> T { try use(bytes) }
    public var description: String { "<secret material redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct SecretRecipient: Codable, Equatable, Sendable {
    public let publicKey: Data
    public var keyID: String { "x25519:" + FlowHasher.sha256Hex(publicKey) }
    public init(publicKey: Data) throws {
        _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        self.publicKey = publicKey
    }
}

/// Immutable binding, signed by the owner and authenticated inside every recipient envelope.
public struct DatabaseSecretContext: Codable, Equatable, Sendable {
    public static let purpose = "purpose://access.audit.privacy.database-key-custody"
    public let format: String
    public let secretID: String
    public let cellUUID: String
    public let ownerFingerprint: String
    public let domain: String
    public let audience: String
    public let purpose: String
    public let keyVersion: Int
    public let policyVersion: Int
    public let revision: Int
    public init(secretID: String, cellUUID: String, ownerFingerprint: String, domain: String, audience: String,
                keyVersion: Int = 1, policyVersion: Int = 1, revision: Int = 1) throws {
        self.format = "haven.database-secret.v1"
        self.secretID = secretID.lowercased(); self.cellUUID = cellUUID.lowercased()
        self.ownerFingerprint = ownerFingerprint; self.domain = domain; self.audience = audience.lowercased()
        self.purpose = Self.purpose; self.keyVersion = keyVersion; self.policyVersion = policyVersion; self.revision = revision
        try validate()
    }
    public func validate() throws {
        guard format == "haven.database-secret.v1", purpose == Self.purpose,
              UUID(uuidString: secretID) != nil, secretID == secretID.lowercased(),
              UUID(uuidString: cellUUID) != nil, cellUUID == cellUUID.lowercased(),
              UUID(uuidString: audience) != nil, audience == audience.lowercased(),
              !ownerFingerprint.isEmpty, !domain.isEmpty, domain.count <= 256,
              (1...1_000_000).contains(keyVersion), (1...1_000_000).contains(policyVersion), (1...1_000_000).contains(revision) else { throw SecretCredentialError.invalidContract }
    }
}

public struct SealedDatabaseSecret: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public struct Envelope: Codable, Equatable, Sendable {
        public let recipient: SecretRecipient
        public let encapsulatedKey: Data
        public let ciphertext: Data
        public init(recipient: SecretRecipient, encapsulatedKey: Data, ciphertext: Data) {
            self.recipient = recipient; self.encapsulatedKey = encapsulatedKey; self.ciphertext = ciphertext
        }
    }
    public let context: DatabaseSecretContext
    public let envelopes: [Envelope]
    public let ownerSignature: Data
    public var description: String { "<sealed database secret redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
    public init(context: DatabaseSecretContext, envelopes: [Envelope], ownerSignature: Data) {
        self.context = context; self.envelopes = envelopes; self.ownerSignature = ownerSignature
    }
    public func signingData() throws -> Data {
        struct Body: Encodable { let context: DatabaseSecretContext; let envelopes: [Envelope] }
        return try CanonicalPayloadEncoder.data(for: Body(context: context, envelopes: envelopes))
    }
    public func digest() throws -> String { FlowHasher.sha256Hex(try signingData() + ownerSignature) }
    public func validate(owner: Identity) throws {
        try context.validate()
        guard context.ownerFingerprint == owner.signingPublicKeyFingerprint,
              (2...8).contains(envelopes.count), Set(envelopes.map { $0.recipient.keyID }).count == envelopes.count,
              envelopes.allSatisfy({ $0.recipient.publicKey.count == 32 && $0.encapsulatedKey.count == 32 && $0.ciphertext.count == 48 }),
              IdentityPublicKeySignatureVerifier.verify(signature: ownerSignature, messageData: try signingData(), identity: owner)
        else { throw SecretCredentialError.denied }
    }
}

/// Operations, not exported private keys. An OS adapter may prompt here, outside database locks.
public protocol SecretUnwrappingProvider: Sendable {
    func recipient() async throws -> SecretRecipient
    func open(_ envelope: SealedDatabaseSecret.Envelope, context: DatabaseSecretContext) async throws -> SecretKeyMaterial
}

/// RFC 9180 base-mode HPKE + an explicit owner signature. No implicit sender recipient.
public enum DatabaseSecretCrypto {
    private struct Binding: Codable { let context: DatabaseSecretContext; let recipientKeyID: String; let suite: String }
    public static func authenticatedContext(_ context: DatabaseSecretContext, recipient: SecretRecipient) throws -> Data {
        try context.validate()
        return try CanonicalPayloadEncoder.data(for: Binding(context: context, recipientKeyID: recipient.keyID,
            suite: "HPKE-X25519-HKDF-SHA256-ChaChaPoly-v1"))
    }
    public static func seal(_ key: SecretKeyMaterial, context: DatabaseSecretContext,
                            recipients: [SecretRecipient], owner: Identity) async throws -> SealedDatabaseSecret {
        guard #available(macOS 14, iOS 17, tvOS 17, watchOS 10, *) else { throw SecretCredentialError.unavailable }
        guard context.ownerFingerprint == owner.signingPublicKeyFingerprint,
              (2...8).contains(recipients.count), Set(recipients.map(\.keyID)).count == recipients.count else {
            throw SecretCredentialError.invalidContract
        }
        let envelopes = try recipients.sorted { $0.keyID < $1.keyID }.map { recipient in
            let aad = try authenticatedContext(context, recipient: recipient)
            var sender = try HPKE.Sender(recipientKey: Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient.publicKey),
                                        ciphersuite: .Curve25519_SHA256_ChachaPoly, info: aad)
            return try SealedDatabaseSecret.Envelope(recipient: recipient, encapsulatedKey: sender.encapsulatedKey,
                ciphertext: key.withBytes { try sender.seal($0, authenticating: aad) })
        }
        let unsigned = SealedDatabaseSecret(context: context, envelopes: envelopes, ownerSignature: Data())
        guard let signature = try await owner.sign(data: unsigned.signingData()) else { throw SecretCredentialError.denied }
        return SealedDatabaseSecret(context: context, envelopes: envelopes, ownerSignature: signature)
    }
    /// Called only inside a trusted platform adapter. Never returns the private wrapping key.
    public static func open(_ envelope: SealedDatabaseSecret.Envelope, context: DatabaseSecretContext,
                            privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> SecretKeyMaterial {
        guard #available(macOS 14, iOS 17, tvOS 17, watchOS 10, *) else { throw SecretCredentialError.unavailable }
        let recipient = try SecretRecipient(publicKey: privateKey.publicKey.rawRepresentation)
        guard envelope.recipient == recipient else { throw SecretCredentialError.denied }
        do {
            let aad = try authenticatedContext(context, recipient: recipient)
            var receiver = try HPKE.Recipient(privateKey: privateKey, ciphersuite: .Curve25519_SHA256_ChachaPoly,
                info: aad, encapsulatedKey: envelope.encapsulatedKey)
            return try SecretKeyMaterial(receiver.open(envelope.ciphertext, authenticating: aad))
        } catch { throw SecretCredentialError.integrity }
    }
}

public struct SecretCredentialRequest: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public enum Operation: String, Codable, Sendable { case create, read, rewrap, rotate, revoke }
    public struct Authorization: Codable, Sendable {
        public let format: String
        public let operation: Operation
        public let context: DatabaseSecretContext
        public let recordDigest: String
        public let recipientKeyID: String
        public let nonce: String
        public let issuedAt: Int64
        public let expiresAt: Int64
    }
    public let requesterIdentity: Identity
    public let authorization: Authorization
    public let signature: Data
    public let record: SealedDatabaseSecret?
    public init(requesterIdentity: Identity, authorization: Authorization, signature: Data, record: SealedDatabaseSecret?) {
        self.requesterIdentity = requesterIdentity.publicIdentitySnapshot()
        self.authorization = authorization; self.signature = signature; self.record = record
    }
    public static func signed(operation: Operation, record: SealedDatabaseSecret, recipient: SecretRecipient,
                              owner: Identity, now: Date = Date()) async throws -> Self {
        try record.validate(owner: owner)
        let body = Authorization(format: "haven.secret-use.v1", operation: operation, context: record.context,
            recordDigest: try record.digest(), recipientKeyID: recipient.keyID,
            nonce: UUID().uuidString.lowercased(), issuedAt: Int64(now.timeIntervalSince1970),
            expiresAt: Int64(now.timeIntervalSince1970) + 60)
        guard let signature = try await owner.sign(data: CanonicalPayloadEncoder.data(for: body)) else { throw SecretCredentialError.denied }
        return Self(requesterIdentity: owner, authorization: body, signature: signature, record: [.create, .rewrap, .rotate].contains(operation) ? record : nil)
    }
    public func verify(owner: Identity, audience: String, domain: String, now: Date) throws {
        let a = authorization; let time = Int64(now.timeIntervalSince1970)
        try a.context.validate()
        guard a.format == "haven.secret-use.v1", a.context.ownerFingerprint == owner.signingPublicKeyFingerprint,
              a.context.audience == audience.lowercased(), a.context.domain == domain,
              UUID(uuidString: a.nonce) != nil,
              IdentityPublicKeySignatureVerifier.verify(signature: signature,
                messageData: try CanonicalPayloadEncoder.data(for: a), identity: owner) else { throw SecretCredentialError.denied }
        guard a.issuedAt >= time - 60, a.issuedAt <= time, a.expiresAt > time,
              a.expiresAt <= a.issuedAt + 60 else { throw SecretCredentialError.expired }
    }
    public var description: String { "<secret request redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Private data plane: must not be implemented as a generic get/Flow/model tool.
public protocol SecretCredentialTransport: Sendable {
    func exchange(_ request: SecretCredentialRequest) async throws -> SealedDatabaseSecret?
}
