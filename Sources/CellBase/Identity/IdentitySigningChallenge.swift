// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum IdentitySigningChallengeError: Error {
    case invalidPayload
    case wrongType
    case unsupportedVersion
    case wrongPurpose
    case identityMismatch
    case missingPublicKeyFingerprint
    case publicKeyMismatch
    case expired
    case issuedInFuture
    case missingNonce
    case missingChallengeScope
    case invalidValidity
    case payloadTooLarge
}

public struct IdentitySigningChallenge: Codable, Equatable, Sendable {
    public static let type = "org.haven.cellprotocol.identity-signing-challenge"
    public static let version = 1
    public static let identityOriginProofPurpose = "identity-origin-proof"
    public static let defaultValidity: TimeInterval = 60
    public static let allowedClockSkew: TimeInterval = 300
    public static let maximumEncodedBytes = 8 * 1024
    public static let minimumNonceBytes = 32
    public static let maximumNonceBytes = 128
    public static let maximumScopeCharacters = 512

    public var type: String
    public var version: Int
    public var purpose: String
    public var identityUUID: String
    public var publicKeyFingerprint: String?
    public var domain: String
    public var resource: String
    public var action: String
    public var audience: String
    public var nonce: Data
    public var issuedAt: TimeInterval
    public var expiresAt: TimeInterval

    public init(
        purpose: String = Self.identityOriginProofPurpose,
        identityUUID: String,
        publicKeyFingerprint: String?,
        domain: String,
        resource: String,
        action: String,
        audience: String,
        nonce: Data,
        issuedAt: Date = Date(),
        validity: TimeInterval = Self.defaultValidity
    ) {
        self.type = Self.type
        self.version = Self.version
        self.purpose = purpose
        self.identityUUID = identityUUID
        self.publicKeyFingerprint = publicKeyFingerprint
        self.domain = domain
        self.resource = resource
        self.action = action
        self.audience = audience
        self.nonce = nonce
        self.issuedAt = issuedAt.timeIntervalSince1970
        self.expiresAt = issuedAt.addingTimeInterval(validity).timeIntervalSince1970
    }

    public static func signingData(
        for identity: Identity,
        trustedIdentity: Identity,
        domain: String,
        resource: String,
        action: String,
        audience: String,
        nonce: Data,
        issuedAt: Date = Date()
    ) throws -> Data {
        guard let trustedFingerprint = trustedIdentity.signingPublicKeyFingerprint,
              !trustedFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IdentitySigningChallengeError.missingPublicKeyFingerprint
        }
        let challenge = IdentitySigningChallenge(
            identityUUID: identity.uuid,
            publicKeyFingerprint: trustedFingerprint,
            domain: domain,
            resource: resource,
            action: action,
            audience: audience,
            nonce: nonce,
            issuedAt: issuedAt
        )
        return try canonicalEncoder().encode(challenge)
    }

    @discardableResult
    public static func validateSigningData(
        _ data: Data,
        for identity: Identity,
        now: Date = Date()
    ) throws -> IdentitySigningChallenge {
        guard data.count <= Self.maximumEncodedBytes else {
            throw IdentitySigningChallengeError.payloadTooLarge
        }
        let challenge: IdentitySigningChallenge
        do {
            challenge = try JSONDecoder().decode(IdentitySigningChallenge.self, from: data)
        } catch {
            throw IdentitySigningChallengeError.invalidPayload
        }

        guard challenge.type == Self.type else {
            throw IdentitySigningChallengeError.wrongType
        }
        guard challenge.version == Self.version else {
            throw IdentitySigningChallengeError.unsupportedVersion
        }
        guard challenge.purpose == Self.identityOriginProofPurpose else {
            throw IdentitySigningChallengeError.wrongPurpose
        }
        guard challenge.identityUUID == identity.uuid else {
            throw IdentitySigningChallengeError.identityMismatch
        }
        guard let expectedFingerprint = challenge.publicKeyFingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !expectedFingerprint.isEmpty else {
            throw IdentitySigningChallengeError.missingPublicKeyFingerprint
        }
        guard let presentedFingerprint = identity.signingPublicKeyFingerprint,
              expectedFingerprint == presentedFingerprint else {
            throw IdentitySigningChallengeError.publicKeyMismatch
        }
        guard challenge.nonce.count >= Self.minimumNonceBytes else {
            throw IdentitySigningChallengeError.missingNonce
        }
        guard challenge.nonce.count <= Self.maximumNonceBytes else {
            throw IdentitySigningChallengeError.payloadTooLarge
        }
        guard !challenge.domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !challenge.resource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !challenge.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !challenge.audience.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IdentitySigningChallengeError.missingChallengeScope
        }
        guard [challenge.domain, challenge.resource, challenge.action, challenge.audience]
            .allSatisfy({ $0.count <= Self.maximumScopeCharacters }) else {
            throw IdentitySigningChallengeError.payloadTooLarge
        }
        guard challenge.expiresAt >= challenge.issuedAt,
              challenge.expiresAt - challenge.issuedAt <= Self.defaultValidity else {
            throw IdentitySigningChallengeError.invalidValidity
        }

        let nowInterval = now.timeIntervalSince1970
        guard challenge.issuedAt <= nowInterval + Self.allowedClockSkew else {
            throw IdentitySigningChallengeError.issuedInFuture
        }
        guard challenge.expiresAt >= nowInterval else {
            throw IdentitySigningChallengeError.expired
        }
        return challenge
    }

    public static func proveControl(
        of identity: Identity,
        domain: String,
        resource: String,
        action: String,
        audience: String,
        now: Date = Date()
    ) async -> Bool {
        guard let vault = identity.identityVault,
              let homeVaultReference = identity.homeVaultReference,
              await vault.identityVaultReference() == homeVaultReference,
              identity.signingPublicKeyFingerprint != nil,
              await vault.identityExistInVault(identity),
              let nonce = await vault.randomBytes64(),
              nonce.count >= Self.minimumNonceBytes,
              nonce.count <= Self.maximumNonceBytes else {
            return false
        }

        do {
            let data = try signingData(
                for: identity,
                trustedIdentity: identity,
                domain: domain,
                resource: resource,
                action: action,
                audience: audience,
                nonce: nonce,
                issuedAt: now
            )
            _ = try validateSigningData(data, for: identity, now: now)
            guard let signature = try await identity.sign(data: data) else {
                return false
            }
            return IdentityPublicKeySignatureVerifier.verify(
                signature: signature,
                messageData: data,
                identity: identity
            )
        } catch {
            return false
        }
    }

    private static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public extension Identity {
    var signingPublicKeyFingerprint: String? {
        guard
            let publicSecureKey,
            let compressedKey = publicSecureKey.compressedKey,
            compressedKey.isEmpty == false
        else {
            return nil
        }
        return [
            publicSecureKey.algorithm.rawValue,
            publicSecureKey.curveType.rawValue,
            compressedKey.base64EncodedString()
        ].joined(separator: ":")
    }
}
