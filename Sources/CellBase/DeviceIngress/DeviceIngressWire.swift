// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Transport-neutral operation names for the notification-device boundary.
///
/// HTTP methods and paths are deliberately absent. An adapter may bind these
/// operations to HTTP, WebSocket, IPC, or another transport, but authority is
/// always evaluated from the Cell resource, action, capability, requester and
/// Agreement carried by this protocol contract.
public enum DeviceIngressOperation: String, Codable, CaseIterable, Sendable {
    case register
    case resolve
    case submit

    public var resource: String {
        switch self {
        case .register:
            return "cell:///DeviceRegistration"
        case .resolve, .submit:
            return "cell:///DeviceCallbackBridge"
        }
    }

    public var action: String {
        switch self {
        case .register:
            return "registerOrUpdateDevice"
        case .resolve:
            return "resolveTicket"
        case .submit:
            return "submitTicketResult"
        }
    }

    public var capability: String {
        switch self {
        case .register:
            return "device.registration.write"
        case .resolve:
            return "device.callback.resolve"
        case .submit:
            return "device.callback.submit"
        }
    }

    public var requiredAccess: String { "-w--" }
}

public enum DeviceIngressEnvelopeKind: String, Codable, Sendable {
    case challenge
    case request
}

/// A non-secret pointer to resolver-owned authorization state.
///
/// These identifiers grant no authority. The Scaffold-signed reference pins
/// the resolver target Cell, owner signing key, exact signed Agreement bytes,
/// subject, authority generation and revocation generation before an ingress
/// request can be admitted.
public struct DeviceIngressAuthorityReference: Codable, Equatable, Sendable {
    public static let currentSchema = "cellprotocol.device-ingress.authority-reference.v2"
    public static let maximumAuthorityLifetimeMilliseconds: Int64 = 30 * 24 * 60 * 60 * 1_000
    public static let maximumJSONSafeGeneration: UInt64 = 9_007_199_254_740_991

    public var schema: String
    public var authorityID: String
    public var agreementID: String
    public var targetCellUUID: String
    public var targetOwnerIdentityUUID: String
    public var targetOwnerSigningKeyFingerprint: String
    public var signedAgreementSHA256: Data
    public var subjectIdentityUUID: String
    public var subjectSigningKeyFingerprint: String
    public var authorityGeneration: UInt64
    public var revocationLedgerID: String
    public var revocationGeneration: UInt64
    public var issuedAtMilliseconds: Int64
    public var validUntilMilliseconds: Int64

    @_spi(HAVENRuntime)
    public init(
        schema: String = Self.currentSchema,
        authorityID: String,
        agreementID: String,
        targetCellUUID: String,
        targetOwnerIdentityUUID: String,
        targetOwnerSigningKeyFingerprint: String,
        signedAgreementSHA256: Data,
        subjectIdentityUUID: String,
        subjectSigningKeyFingerprint: String,
        authorityGeneration: UInt64,
        revocationLedgerID: String,
        revocationGeneration: UInt64,
        issuedAtMilliseconds: Int64,
        validUntilMilliseconds: Int64
    ) {
        self.schema = schema
        self.authorityID = authorityID
        self.agreementID = agreementID
        self.targetCellUUID = targetCellUUID
        self.targetOwnerIdentityUUID = targetOwnerIdentityUUID
        self.targetOwnerSigningKeyFingerprint = targetOwnerSigningKeyFingerprint
        self.signedAgreementSHA256 = signedAgreementSHA256
        self.subjectIdentityUUID = subjectIdentityUUID
        self.subjectSigningKeyFingerprint = subjectSigningKeyFingerprint
        self.authorityGeneration = authorityGeneration
        self.revocationLedgerID = revocationLedgerID
        self.revocationGeneration = revocationGeneration
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.validUntilMilliseconds = validUntilMilliseconds
    }
}

public struct DeviceIngressIdentityProof: Codable, Equatable, Sendable {
    public static let currentSchema = "cellprotocol.device-ingress.identity-proof.v1"
    public static let identitySignatureType = "identity_signature"

    public var schema: String
    public var type: String
    public var signerIdentityUUID: String
    public var signature: Data

    public init(
        schema: String = Self.currentSchema,
        type: String = Self.identitySignatureType,
        signerIdentityUUID: String,
        signature: Data
    ) {
        self.schema = schema
        self.type = type
        self.signerIdentityUUID = signerIdentityUUID
        self.signature = signature
    }
}

/// One canonical wire type is used for both the server-signed challenge and
/// the requester-signed registration/callback request.
///
/// The challenge pins the subject and authority reference. The request repeats
/// those fields and additionally binds the exact challenge bytes and protected
/// body bytes by SHA-256. `proof` is excluded from signing material but included
/// in the canonical on-wire representation.
public struct DeviceIngressEnvelope: Codable, Equatable, Sendable, CanonicalPayloadSignable {
    public static let currentSchema = "cellprotocol.device-ingress.envelope.v2"
    public static let purpose = "purpose://access.audit.privacy/device-notification-callback"
    public static let identityDomain = "domain:device:notification-callback"
    public static let maximumEncodedBytes = 65_536
    public static let maximumBodyBytes = 65_536
    public static let minimumNonceBytes = 32
    public static let maximumNonceBytes = 64
    public static let maximumChallengeLifetimeMilliseconds: Int64 = 5 * 60 * 1_000
    public static let maximumRequestLifetimeMilliseconds: Int64 = 2 * 60 * 1_000
    public static let maximumClockSkewMilliseconds: Int64 = 30 * 1_000
    public static let maximumJSONSafeTimestampMilliseconds: Int64 = 9_007_199_254_740_991

    public var schema: String
    public var kind: DeviceIngressEnvelopeKind
    public var envelopeID: String
    public var challengeID: String
    public var nonce: Data
    public var operation: DeviceIngressOperation
    public var purpose: String
    public var audience: String
    public var identityDomain: String
    public var resource: String
    public var action: String
    public var capability: String
    public var requiredAccess: String
    public var subject: IdentityPublicKeyDescriptor
    public var authority: DeviceIngressAuthorityReference
    public var bodySHA256: Data?
    public var challengeSHA256: Data?
    public var issuedAtMilliseconds: Int64
    public var expiresAtMilliseconds: Int64
    public var signer: IdentityPublicKeyDescriptor
    public var domainBinding: IdentityDomainBinding?
    public var proof: DeviceIngressIdentityProof?

    public init(
        schema: String = Self.currentSchema,
        kind: DeviceIngressEnvelopeKind,
        envelopeID: String,
        challengeID: String,
        nonce: Data,
        operation: DeviceIngressOperation,
        purpose: String = Self.purpose,
        audience: String,
        identityDomain: String = Self.identityDomain,
        resource: String? = nil,
        action: String? = nil,
        capability: String? = nil,
        requiredAccess: String? = nil,
        subject: IdentityPublicKeyDescriptor,
        authority: DeviceIngressAuthorityReference,
        bodySHA256: Data? = nil,
        challengeSHA256: Data? = nil,
        issuedAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64,
        signer: IdentityPublicKeyDescriptor,
        domainBinding: IdentityDomainBinding? = nil,
        proof: DeviceIngressIdentityProof? = nil
    ) {
        self.schema = schema
        self.kind = kind
        self.envelopeID = envelopeID
        self.challengeID = challengeID
        self.nonce = nonce
        self.operation = operation
        self.purpose = purpose
        self.audience = audience
        self.identityDomain = identityDomain
        self.resource = resource ?? operation.resource
        self.action = action ?? operation.action
        self.capability = capability ?? operation.capability
        self.requiredAccess = requiredAccess ?? operation.requiredAccess
        self.subject = subject
        self.authority = authority
        self.bodySHA256 = bodySHA256
        self.challengeSHA256 = challengeSHA256
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.signer = signer
        self.domainBinding = domainBinding
        self.proof = proof
    }

    public func canonicalPayloadData() throws -> Data {
        try DeviceIngressCanonicalWire.signingData(for: self)
    }

    public func canonicalWireData() throws -> Data {
        try DeviceIngressCanonicalWire.encode(self)
    }
}

public enum DeviceIngressCanonicalWireError: Error, Equatable, Sendable {
    case emptyPayload
    case payloadTooLarge
    case malformedPayload
    case nonCanonicalPayload
    case invalidEnvelope
    case invalidSigner
    case signingFailed
}

public enum DeviceIngressCanonicalWire {
    public static func encode(_ envelope: DeviceIngressEnvelope) throws -> Data {
        let data = try canonicalData(for: envelope, excludingTopLevelKeys: [])
        guard data.count <= DeviceIngressEnvelope.maximumEncodedBytes else {
            throw DeviceIngressCanonicalWireError.payloadTooLarge
        }
        return data
    }

    /// Decodes only the exact canonical representation. Whitespace, alternate
    /// key ordering, duplicate-key normalizations and re-encoded variants are
    /// rejected so every signer and verifier hashes the same raw bytes.
    public static func decodeCanonical(_ data: Data) throws -> DeviceIngressEnvelope {
        guard data.isEmpty == false else {
            throw DeviceIngressCanonicalWireError.emptyPayload
        }
        guard data.count <= DeviceIngressEnvelope.maximumEncodedBytes else {
            throw DeviceIngressCanonicalWireError.payloadTooLarge
        }
        let envelope: DeviceIngressEnvelope
        do {
            envelope = try JSONDecoder().decode(DeviceIngressEnvelope.self, from: data)
        } catch {
            throw DeviceIngressCanonicalWireError.malformedPayload
        }
        guard try encode(envelope) == data else {
            throw DeviceIngressCanonicalWireError.nonCanonicalPayload
        }
        return envelope
    }

    public static func signingData(for envelope: DeviceIngressEnvelope) throws -> Data {
        try canonicalData(for: envelope, excludingTopLevelKeys: ["proof"])
    }

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func canonicalData<T: Encodable>(
        for value: T,
        excludingTopLevelKeys keys: Set<String>
    ) throws -> Data {
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(value)
        } catch {
            throw DeviceIngressCanonicalWireError.invalidEnvelope
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: encoded, options: [])
        } catch {
            throw DeviceIngressCanonicalWireError.invalidEnvelope
        }
        let filtered: Any
        if keys.isEmpty {
            filtered = object
        } else if var dictionary = object as? [String: Any] {
            for key in keys {
                dictionary.removeValue(forKey: key)
            }
            filtered = dictionary
        } else {
            throw DeviceIngressCanonicalWireError.invalidEnvelope
        }
        guard JSONSerialization.isValidJSONObject(filtered) else {
            throw DeviceIngressCanonicalWireError.invalidEnvelope
        }
        return try JSONSerialization.data(
            withJSONObject: filtered,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}

enum DeviceIngressEnvelopeSigner {
    static func sign(
        _ unsignedEnvelope: DeviceIngressEnvelope,
        with identity: Identity
    ) async throws -> DeviceIngressEnvelope {
        guard unsignedEnvelope.proof == nil,
              let signer = IdentityPublicKeySignatureVerifier.descriptor(for: identity),
              descriptorsReferenceSameIdentity(signer, unsignedEnvelope.signer) else {
            throw DeviceIngressCanonicalWireError.invalidSigner
        }
        let signingData = try unsignedEnvelope.canonicalPayloadData()
        guard let signature = try await identity.sign(data: signingData),
              IdentityPublicKeySignatureVerifier.verify(
                signature: signature,
                messageData: signingData,
                descriptor: signer
              ) else {
            throw DeviceIngressCanonicalWireError.signingFailed
        }
        var signed = unsignedEnvelope
        signed.proof = DeviceIngressIdentityProof(
            signerIdentityUUID: signer.uuid,
            signature: signature
        )
        _ = try signed.canonicalWireData()
        return signed
    }

    private static func descriptorsReferenceSameIdentity(
        _ lhs: IdentityPublicKeyDescriptor,
        _ rhs: IdentityPublicKeyDescriptor
    ) -> Bool {
        lhs.uuid == rhs.uuid
            && lhs.publicKey == rhs.publicKey
            && lhs.algorithm == rhs.algorithm
            && lhs.curveType == rhs.curveType
    }
}

public enum DeviceIngressIdentityDescriptor {
    /// Device ingress never serializes a person's display name. UUID and public
    /// signing key are sufficient for subject and issuer binding.
    public static func publicDescriptor(for identity: Identity) -> IdentityPublicKeyDescriptor? {
        guard let descriptor = IdentityPublicKeySignatureVerifier.descriptor(for: identity) else {
            return nil
        }
        return IdentityPublicKeyDescriptor(
            uuid: descriptor.uuid,
            displayName: nil,
            publicKey: descriptor.publicKey,
            algorithm: descriptor.algorithm,
            curveType: descriptor.curveType
        )
    }
}

public enum DeviceIngressChallengeFactory {
    @_spi(HAVENRuntime)
    public static func issue(
        operation: DeviceIngressOperation,
        audience: String,
        subject: IdentityPublicKeyDescriptor,
        authority: DeviceIngressAuthorityReference,
        issuer: Identity,
        now: Date = Date(),
        lifetimeMilliseconds: Int64 = DeviceIngressEnvelope.maximumChallengeLifetimeMilliseconds
    ) async throws -> Data {
        guard lifetimeMilliseconds > 0,
              lifetimeMilliseconds <= DeviceIngressEnvelope.maximumChallengeLifetimeMilliseconds else {
            throw DeviceIngressCanonicalWireError.invalidEnvelope
        }
        var generator = SystemRandomNumberGenerator()
        let nonce = Data((0..<DeviceIngressEnvelope.minimumNonceBytes).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        })
        return try await issue(
            operation: operation,
            audience: audience,
            subject: subject,
            authority: authority,
            issuer: issuer,
            now: now,
            lifetimeMilliseconds: lifetimeMilliseconds,
            envelopeID: UUID().uuidString,
            challengeID: UUID().uuidString,
            nonce: nonce
        )
    }

    static func issue(
        operation: DeviceIngressOperation,
        audience: String,
        subject: IdentityPublicKeyDescriptor,
        authority: DeviceIngressAuthorityReference,
        issuer: Identity,
        now: Date,
        lifetimeMilliseconds: Int64,
        envelopeID: String,
        challengeID: String,
        nonce: Data
    ) async throws -> Data {
        guard let issuerDescriptor = DeviceIngressIdentityDescriptor.publicDescriptor(
            for: issuer
        ) else {
            throw DeviceIngressCanonicalWireError.invalidSigner
        }
        let sanitizedSubject = IdentityPublicKeyDescriptor(
            uuid: subject.uuid,
            displayName: nil,
            publicKey: subject.publicKey,
            algorithm: subject.algorithm,
            curveType: subject.curveType
        )
        let nowMilliseconds = Int64((now.timeIntervalSince1970 * 1_000).rounded(.towardZero))
        let unsigned = DeviceIngressEnvelope(
            kind: .challenge,
            envelopeID: envelopeID,
            challengeID: challengeID,
            nonce: nonce,
            operation: operation,
            audience: audience,
            subject: sanitizedSubject,
            authority: authority,
            issuedAtMilliseconds: nowMilliseconds,
            expiresAtMilliseconds: nowMilliseconds + lifetimeMilliseconds,
            signer: issuerDescriptor
        )
        let canonicalData = try await DeviceIngressEnvelopeSigner.sign(
            unsigned,
            with: issuer
        ).canonicalWireData()
        _ = try DeviceIngressEnvelopeVerifier.verifyChallenge(
            canonicalData: canonicalData,
            expectedAudience: audience,
            expectedIssuer: issuerDescriptor,
            now: now
        )
        return canonicalData
    }
}

public enum DeviceIngressRequestFactory {
    public static func sign(
        canonicalChallengeData: Data,
        protectedBody: Data,
        requester: Identity,
        domainBinding: IdentityDomainBinding,
        expectedAudience: String,
        expectedChallengeIssuer: IdentityPublicKeyDescriptor,
        now: Date = Date()
    ) async throws -> Data {
        let challenge = try DeviceIngressEnvelopeVerifier.verifyChallenge(
            canonicalData: canonicalChallengeData,
            expectedAudience: expectedAudience,
            expectedIssuer: expectedChallengeIssuer,
            now: now
        )
        guard protectedBody.isEmpty == false,
              protectedBody.count <= DeviceIngressEnvelope.maximumBodyBytes,
              let requesterDescriptor = DeviceIngressIdentityDescriptor.publicDescriptor(
                for: requester
              ),
              descriptorsReferenceSameIdentity(requesterDescriptor, challenge.subject) else {
            throw DeviceIngressCanonicalWireError.invalidEnvelope
        }
        let issuedAt = Int64((now.timeIntervalSince1970 * 1_000).rounded(.towardZero))
        let expiresAt = min(
            issuedAt + DeviceIngressEnvelope.maximumRequestLifetimeMilliseconds,
            challenge.expiresAtMilliseconds,
            challenge.authority.validUntilMilliseconds
        )
        guard expiresAt > issuedAt else {
            throw DeviceIngressCanonicalWireError.invalidEnvelope
        }
        let unsigned = DeviceIngressEnvelope(
            kind: .request,
            envelopeID: UUID().uuidString,
            challengeID: challenge.challengeID,
            nonce: challenge.nonce,
            operation: challenge.operation,
            purpose: challenge.purpose,
            audience: challenge.audience,
            identityDomain: challenge.identityDomain,
            resource: challenge.resource,
            action: challenge.action,
            capability: challenge.capability,
            requiredAccess: challenge.requiredAccess,
            subject: challenge.subject,
            authority: challenge.authority,
            bodySHA256: DeviceIngressCanonicalWire.sha256(protectedBody),
            challengeSHA256: DeviceIngressCanonicalWire.sha256(canonicalChallengeData),
            issuedAtMilliseconds: issuedAt,
            expiresAtMilliseconds: expiresAt,
            signer: requesterDescriptor,
            domainBinding: domainBinding
        )
        return try await DeviceIngressEnvelopeSigner.sign(
            unsigned,
            with: requester
        ).canonicalWireData()
    }

    private static func descriptorsReferenceSameIdentity(
        _ lhs: IdentityPublicKeyDescriptor,
        _ rhs: IdentityPublicKeyDescriptor
    ) -> Bool {
        lhs.uuid == rhs.uuid
            && lhs.publicKey == rhs.publicKey
            && lhs.algorithm == rhs.algorithm
            && lhs.curveType == rhs.curveType
    }
}
