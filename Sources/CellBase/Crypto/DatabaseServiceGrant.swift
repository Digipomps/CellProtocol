// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A service asks for exactly one database file. A fresh ephemeral recipient is required per request.
/// The signature authenticates an identity, not the trustworthiness of its host.
public struct DatabaseServiceRequest: Codable, Sendable {
    public struct Scope: Codable, Equatable, Sendable {
        public let format: String
        public let context: DatabaseSecretContext
        public let recordDigest: String
        public let filename: String
        public let purpose: String
        public let action: String
        public let audience: String
        public let runtimeFingerprint: String
        public let recipient: SecretRecipient
        public let nonce: String
        public let issuedAt: Int64
        public let expiresAt: Int64
    }
    public let scope: Scope
    public let runtime: Identity
    public let signature: Data
    public static func signed(record: SealedDatabaseSecret, filename: String, purpose: String,
                              audience: String, runtime: Identity, recipient: SecretRecipient,
                              duration: Int = 300, now: Date = Date()) async throws -> Self {
        guard let fingerprint = runtime.signingPublicKeyFingerprint, (1...900).contains(duration) else {
            throw SecretCredentialError.invalidContract
        }
        let scope = Scope(format: "haven.database-service-request.v1", context: record.context,
            recordDigest: try record.digest(), filename: filename, purpose: purpose, action: "database.read-write",
            audience: audience, runtimeFingerprint: fingerprint, recipient: recipient,
            nonce: UUID().uuidString.lowercased(), issuedAt: Int64(now.timeIntervalSince1970),
            expiresAt: Int64(now.timeIntervalSince1970) + Int64(duration))
        guard let signature = try await runtime.sign(data: CanonicalPayloadEncoder.data(for: scope)) else { throw SecretCredentialError.denied }
        let request = Self(scope: scope, runtime: runtime.publicIdentitySnapshot(), signature: signature)
        try request.validate(now: now)
        return request
    }
    public func validate(now: Date = Date()) throws {
        try scope.context.validate()
        let s = scope; let time = Int64(now.timeIntervalSince1970)
        guard s.format == "haven.database-service-request.v1", s.action == "database.read-write",
              Self.validFilename(s.filename), s.purpose.hasPrefix("purpose://"), s.purpose.count <= 256,
              !s.audience.isEmpty, s.audience.count <= 256, s.recordDigest.count == 64,
              s.runtimeFingerprint == runtime.signingPublicKeyFingerprint, UUID(uuidString: s.nonce) != nil,
              IdentityPublicKeySignatureVerifier.verify(signature: signature,
                messageData: try CanonicalPayloadEncoder.data(for: s), identity: runtime) else { throw SecretCredentialError.denied }
        guard s.issuedAt >= time - 900, s.issuedAt <= time, s.expiresAt > time,
              s.expiresAt <= s.issuedAt + 900 else { throw SecretCredentialError.expired }
    }
    public static func validFilename(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && name != "." && name != ".." &&
        name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }
}

/// Explicit owner-approved, recipient-encrypted file key. Never contains the cell root.
/// Expiry constrains cooperating runtimes; a hostile authorized recipient can retain plaintext/key material.
public struct DatabaseServiceGrant: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let request: DatabaseServiceRequest
    public let encapsulatedKey: Data
    public let ciphertext: Data
    public let ownerSignature: Data
    public var description: String { "<database service grant redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
    private func signingData() throws -> Data {
        // Identity's convenience Codable normalizes metadata on decode. Sign only immutable authority
        // fields plus the runtime proof; request.validate separately verifies its pinned public key.
        struct Body: Encodable {
            let format = "haven.database-service-grant.v1"
            let scope: DatabaseServiceRequest.Scope
            let runtimeSignature: Data
            let encapsulatedKey: Data
            let ciphertext: Data
        }
        return try CanonicalPayloadEncoder.data(for: Body(scope: request.scope, runtimeSignature: request.signature,
            encapsulatedKey: encapsulatedKey, ciphertext: ciphertext))
    }
    public func validate(owner: Identity, record: SealedDatabaseSecret, now: Date = Date()) throws {
        try request.validate(now: now); try record.validate(owner: owner)
        guard request.scope.context == record.context, try request.scope.recordDigest == record.digest(),
              encapsulatedKey.count == 32, ciphertext.count == 48,
              IdentityPublicKeySignatureVerifier.verify(signature: ownerSignature, messageData: try signingData(), identity: owner)
        else { throw SecretCredentialError.denied }
    }
    /// Invoke only after a native owner approval of the displayed runtime, audience, file, purpose and expiry.
    public static func approve(_ request: DatabaseServiceRequest, record: SealedDatabaseSecret, owner: Identity,
                               unwrapper: any SecretUnwrappingProvider, transport: any SecretCredentialTransport,
                               now: Date = Date()) async throws -> Self {
        guard #available(macOS 14, iOS 17, tvOS 17, watchOS 10, *) else { throw SecretCredentialError.unavailable }
        try request.validate(now: now); try record.validate(owner: owner)
        guard request.scope.context == record.context, try request.scope.recordDigest == record.digest() else { throw SecretCredentialError.staleVersion }
        let recipient = try await unwrapper.recipient()
        let read = try await SecretCredentialRequest.signed(operation: .read, record: record, recipient: recipient, owner: owner, now: now)
        guard let latest = try await transport.exchange(read), try latest.digest() == record.digest(),
              let envelope = latest.envelopes.first(where: { $0.recipient == recipient }) else { throw SecretCredentialError.staleVersion }
        let root = try await unwrapper.open(envelope, context: record.context)
        try Task.checkCancellation()
        // User presence and transport can take time. Never mint a grant after the request expired.
        try request.validate(now: Date())
        let key = try DatabaseFileKeyDerivation.derive(root: root, cellUUID: record.context.cellUUID, filename: request.scope.filename)
        let aad = try CanonicalPayloadEncoder.data(for: request.scope)
        var sender = try HPKE.Sender(recipientKey: Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.scope.recipient.publicKey),
            ciphersuite: .Curve25519_SHA256_ChachaPoly, info: aad)
        let ciphertext = try key.withBytes { try sender.seal($0, authenticating: aad) }
        let unsigned = Self(request: request, encapsulatedKey: sender.encapsulatedKey, ciphertext: ciphertext, ownerSignature: Data())
        guard let signature = try await owner.sign(data: unsigned.signingData()) else { throw SecretCredentialError.denied }
        return Self(request: request, encapsulatedKey: sender.encapsulatedKey, ciphertext: ciphertext, ownerSignature: signature)
    }
    /// Runtime-owned ephemeral key, not an owner wrapping key. No key export endpoint is provided.
    public func open(privateKey: Curve25519.KeyAgreement.PrivateKey, owner: Identity, record: SealedDatabaseSecret,
                     expectedRequest: DatabaseServiceRequest, now: Date = Date()) throws -> SecretKeyMaterial {
        guard #available(macOS 14, iOS 17, tvOS 17, watchOS 10, *) else { throw SecretCredentialError.unavailable }
        try validate(owner: owner, record: record, now: now)
        guard request.scope == expectedRequest.scope, privateKey.publicKey.rawRepresentation == request.scope.recipient.publicKey else {
            throw SecretCredentialError.denied
        }
        let aad = try CanonicalPayloadEncoder.data(for: request.scope)
        do {
            var recipient = try HPKE.Recipient(privateKey: privateKey, ciphersuite: .Curve25519_SHA256_ChachaPoly,
                info: aad, encapsulatedKey: encapsulatedKey)
            return try SecretKeyMaterial(recipient.open(ciphertext, authenticating: aad))
        } catch { throw SecretCredentialError.integrity }
    }
}

/// Stable v1 derivation, shared by owner and delegated runtimes. A per-file key cannot derive siblings.
public enum DatabaseFileKeyDerivation {
    public static func derive(root: SecretKeyMaterial, cellUUID: String, filename: String) throws -> SecretKeyMaterial {
        guard UUID(uuidString: cellUUID) != nil, DatabaseServiceRequest.validFilename(filename) else { throw SecretCredentialError.invalidContract }
        return root.withBytes { bytes in
            let result = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes),
                salt: Data(cellUUID.lowercased().utf8), info: Data(("haven.cell.database.sqlcipher.v1/" + filename).utf8), outputByteCount: 32)
            return try! SecretKeyMaterial(result.withUnsafeBytes { Data($0) })
        }
    }
}

/// Private, typed interchange for the native owner workflow. No raw keys or generic Cell/Flow actions.
public struct DatabaseOwnerApprovalPackage: Codable, Sendable {
    public let record: SealedDatabaseSecret
    public let request: DatabaseServiceRequest
    public let secretEndpoint: URL
    public init(record: SealedDatabaseSecret, request: DatabaseServiceRequest, secretEndpoint: URL) {
        self.record = record; self.request = request; self.secretEndpoint = secretEndpoint
    }
    public func validate(owner: Identity, now: Date = Date()) throws {
        try record.validate(owner: owner); try request.validate(now: now)
        guard request.scope.context == record.context, try request.scope.recordDigest == record.digest(),
              secretEndpoint.scheme == "https", secretEndpoint.user == nil, secretEndpoint.password == nil,
              secretEndpoint.query == nil, secretEndpoint.fragment == nil,
              secretEndpoint.path == "/cell-secrets/v1/\(record.context.audience)/exchange" else { throw SecretCredentialError.denied }
    }
}
