// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum ContentCryptoEnvelopeError: Error {
    case unsupportedSuite
    case noRecipients
    case missingKeyProvider
    case missingSenderSigningIdentity
    case missingSenderKeyAgreementKey
    case missingRecipientKeyAgreementKey(String)
    case invalidRecipientKey(String)
    case invalidSenderKeyAgreementKey
    case missingRecipientPrivateKey(String)
    case wrappedKeyNotFound(String)
    case invalidEphemeralKey(String)
    case wrappedKeyOpenFailed(String)
    case ciphertextOpenFailed
    case missingSenderSignature
    case senderVerificationFailed
    case signingFailed
}

public enum ContentCryptoEnvelopeUtility {
    private static let wrapSalt = Data("HAVEN.ContentWrapSalt.v1".utf8)
    private static let wrapInfoPrefix = "HAVEN.ContentWrap.v1"

    public static func recipientDescriptors(
        for recipients: [Identity],
        provider: IdentityKeyRoleProviderProtocol
    ) async throws -> [IdentityRolePublicKeyDescriptor] {
        var descriptors: [IdentityRolePublicKeyDescriptor] = []

        for recipient in recipients {
            guard let secureKey = try await provider.publicSecureKey(for: recipient, role: .keyAgreement),
                  let publicKey = secureKey.compressedKey else {
                continue
            }

            let keyID = provider.keyIdentifier(for: recipient, role: .keyAgreement, secureKey: secureKey)
            descriptors.append(
                IdentityRolePublicKeyDescriptor(
                    identityUUID: recipient.uuid,
                    displayName: recipient.displayName,
                    role: .keyAgreement,
                    keyID: keyID,
                    algorithm: secureKey.algorithm,
                    curveType: secureKey.curveType,
                    publicKey: publicKey
                )
            )
        }

        return descriptors
    }

    public static func seal(
        plaintext: Data,
        sender: Identity,
        recipients: [Identity],
        provider: IdentityKeyRoleProviderProtocol,
        suite: ContentCryptoSuite,
        associatedDataContext: String? = nil,
        envelopeGeneration: Int? = nil
    ) async throws -> EncryptedContentEnvelope {
        guard suite.keyAgreementAlgorithm == .x25519HKDFSHA256,
              suite.keyWrappingAlgorithm == .x25519SharedSecret,
              suite.contentAlgorithm == .chachaPoly else {
            throw ContentCryptoEnvelopeError.unsupportedSuite
        }

        let normalizedRecipients = deduplicateRecipients(recipients, including: sender)
        guard normalizedRecipients.isEmpty == false else {
            throw ContentCryptoEnvelopeError.noRecipients
        }

        guard let senderPrivateKeyData = try await provider.privateKeyData(for: sender, role: .keyAgreement) else {
            throw ContentCryptoEnvelopeError.missingSenderKeyAgreementKey
        }

        do {
            _ = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: senderPrivateKeyData)
        } catch {
            throw ContentCryptoEnvelopeError.invalidSenderKeyAgreementKey
        }

        let contentKey = SymmetricKey(size: .bits256)
        let contentKeyData = contentKey.withUnsafeBytes { Data($0) }

        var wrappedRecipients: [WrappedContentKeyDescriptor] = []
        for recipient in normalizedRecipients {
            guard let recipientKey = try await provider.publicSecureKey(for: recipient, role: .keyAgreement) else {
                throw ContentCryptoEnvelopeError.missingRecipientKeyAgreementKey(recipient.uuid)
            }
            guard recipientKey.curveType == .Curve25519,
                  let recipientPublicKeyData = recipientKey.compressedKey else {
                throw ContentCryptoEnvelopeError.invalidRecipientKey(recipient.uuid)
            }

            let recipientPublicKey: Curve25519.KeyAgreement.PublicKey
            do {
                recipientPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKeyData)
            } catch {
                throw ContentCryptoEnvelopeError.invalidRecipientKey(recipient.uuid)
            }

            let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
            let sharedSecret = try ephemeralKey.sharedSecretFromKeyAgreement(with: recipientPublicKey)
            let recipientInfo = Data("\(wrapInfoPrefix)|\(suite.id)|\(recipient.uuid)".utf8)
            let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: wrapSalt,
                sharedInfo: recipientInfo,
                outputByteCount: 32
            )
            let wrappedKeyBox = try ChaChaPoly.seal(contentKeyData, using: wrappingKey)

            let keyID = provider.keyIdentifier(for: recipient, role: .keyAgreement, secureKey: recipientKey)
            wrappedRecipients.append(
                WrappedContentKeyDescriptor(
                    recipientIdentityUUID: recipient.uuid,
                    recipientKeyID: keyID,
                    algorithm: .x25519SharedSecret,
                    wrappedKeyMaterial: wrappedKeyBox.combined,
                    recipientCurveType: recipientKey.curveType,
                    recipientAlgorithm: recipientKey.algorithm,
                    ephemeralPublicKey: ephemeralKey.publicKey.rawRepresentation
                )
            )
        }

        let senderKeyID: String?
        if let signingKey = sender.publicSecureKey {
            senderKeyID = provider.keyIdentifier(for: sender, role: .signing, secureKey: signingKey)
        } else {
            senderKeyID = nil
        }

        let header = EncryptedContentEnvelopeHeader(
            suiteID: suite.id,
            contentAlgorithm: suite.contentAlgorithm,
            keyWrappingAlgorithm: suite.keyWrappingAlgorithm,
            senderKeyID: senderKeyID,
            recipientKeys: wrappedRecipients,
            createdAt: isoTimestamp(),
            envelopeGeneration: envelopeGeneration,
            associatedDataContext: associatedDataContext
        )
        let headerAAD = try CanonicalPayloadEncoder.data(for: header)
        let encryptedContent = try ChaChaPoly.seal(plaintext, using: contentKey, authenticating: headerAAD)

        var senderSignature: Data?
        if suite.requiresSenderSignature {
            guard let signature = try await sender.sign(data: headerAAD + encryptedContent.combined) else {
                throw ContentCryptoEnvelopeError.signingFailed
            }
            senderSignature = signature
        }

        return EncryptedContentEnvelope(
            header: header,
            combinedCiphertext: encryptedContent.combined,
            senderSignature: senderSignature
        )
    }

    public static func open(
        envelope: EncryptedContentEnvelope,
        recipient: Identity,
        sender: Identity?,
        provider: IdentityKeyRoleProviderProtocol
    ) async throws -> OpenedContentEnvelope {
        let suite = try supportedSuite(for: envelope.header)

        guard suite.keyAgreementAlgorithm == .x25519HKDFSHA256,
              suite.keyWrappingAlgorithm == .x25519SharedSecret,
              suite.contentAlgorithm == .chachaPoly else {
            throw ContentCryptoEnvelopeError.unsupportedSuite
        }

        guard let recipientPrivateKeyData = try await provider.privateKeyData(for: recipient, role: .keyAgreement) else {
            throw ContentCryptoEnvelopeError.missingRecipientPrivateKey(recipient.uuid)
        }

        let recipientPrivateKey: Curve25519.KeyAgreement.PrivateKey
        do {
            recipientPrivateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: recipientPrivateKeyData)
        } catch {
            throw ContentCryptoEnvelopeError.invalidRecipientKey(recipient.uuid)
        }

        let wrappedDescriptor = try await matchingWrappedKey(
            for: recipient,
            envelope: envelope,
            provider: provider,
            recipientPrivateKey: recipientPrivateKey
        )
        let headerAAD = try CanonicalPayloadEncoder.data(for: envelope.header)

        let senderVerified: Bool
        if suite.requiresSenderSignature {
            guard let sender else {
                throw ContentCryptoEnvelopeError.missingSenderSigningIdentity
            }
            guard let senderSignature = envelope.senderSignature else {
                throw ContentCryptoEnvelopeError.missingSenderSignature
            }
            let verified = await sender.verify(
                signature: senderSignature,
                for: headerAAD + envelope.combinedCiphertext
            )
            guard verified else {
                throw ContentCryptoEnvelopeError.senderVerificationFailed
            }
            senderVerified = true
        } else {
            senderVerified = false
        }

        let contentSealedBox: ChaChaPoly.SealedBox
        do {
            contentSealedBox = try ChaChaPoly.SealedBox(combined: envelope.combinedCiphertext)
        } catch {
            throw ContentCryptoEnvelopeError.ciphertextOpenFailed
        }

        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(contentSealedBox, using: wrappedDescriptor.contentKey, authenticating: headerAAD)
        } catch {
            throw ContentCryptoEnvelopeError.ciphertextOpenFailed
        }

        return OpenedContentEnvelope(
            plaintext: plaintext,
            suiteID: envelope.header.suiteID,
            recipientIdentityUUID: recipient.uuid,
            recipientKeyID: wrappedDescriptor.descriptor.recipientKeyID,
            senderVerified: senderVerified,
            associatedDataContext: envelope.header.associatedDataContext,
            envelopeGeneration: envelope.header.envelopeGeneration,
            contentAlgorithm: envelope.header.contentAlgorithm,
            senderKeyID: envelope.header.senderKeyID
        )
    }

    private static func deduplicateRecipients(_ recipients: [Identity], including sender: Identity) -> [Identity] {
        var seen = Set<String>()
        var ordered: [Identity] = []

        for identity in [sender] + recipients {
            if seen.insert(identity.uuid).inserted {
                ordered.append(identity)
            }
        }

        return ordered
    }

    private static func isoTimestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private struct WrappedContentKeyMatch {
        var descriptor: WrappedContentKeyDescriptor
        var contentKey: SymmetricKey
    }

    private static func supportedSuite(for header: EncryptedContentEnvelopeHeader) throws -> ContentCryptoSuite {
        switch header.suiteID {
        case ContentCryptoSuite.chatMessageV1.id:
            return .chatMessageV1
        default:
            throw ContentCryptoEnvelopeError.unsupportedSuite
        }
    }

    private static func matchingWrappedKey(
        for recipient: Identity,
        envelope: EncryptedContentEnvelope,
        provider: IdentityKeyRoleProviderProtocol,
        recipientPrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) async throws -> WrappedContentKeyMatch {
        let declaredKeyID: String? = {
            guard let secureKey = recipient.publicKeyAgreementSecureKey else { return nil }
            return provider.keyIdentifier(for: recipient, role: .keyAgreement, secureKey: secureKey)
        }()

        let prioritizedDescriptors = envelope.header.recipientKeys.sorted { lhs, rhs in
            let lhsPriority = descriptorPriority(lhs, recipientUUID: recipient.uuid, keyID: declaredKeyID)
            let rhsPriority = descriptorPriority(rhs, recipientUUID: recipient.uuid, keyID: declaredKeyID)
            return lhsPriority < rhsPriority
        }

        for descriptor in prioritizedDescriptors {
            guard descriptor.algorithm == .x25519SharedSecret else { continue }
            guard let ephemeralKeyMaterial = descriptor.ephemeralPublicKey else { continue }

            let ephemeralPublicKey: Curve25519.KeyAgreement.PublicKey
            do {
                ephemeralPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralKeyMaterial)
            } catch {
                throw ContentCryptoEnvelopeError.invalidEphemeralKey(descriptor.recipientKeyID)
            }

            let sharedSecret = try recipientPrivateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
            let recipientInfo = Data("\(wrapInfoPrefix)|\(envelope.header.suiteID)|\(recipient.uuid)".utf8)
            let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: wrapSalt,
                sharedInfo: recipientInfo,
                outputByteCount: 32
            )

            do {
                let wrappedKeyBox = try ChaChaPoly.SealedBox(combined: descriptor.wrappedKeyMaterial)
                let contentKeyData = try ChaChaPoly.open(wrappedKeyBox, using: wrappingKey)
                return WrappedContentKeyMatch(
                    descriptor: descriptor,
                    contentKey: SymmetricKey(data: contentKeyData)
                )
            } catch {
                continue
            }
        }

        if envelope.header.recipientKeys.contains(where: { $0.recipientIdentityUUID == recipient.uuid || $0.recipientKeyID == declaredKeyID }) {
            throw ContentCryptoEnvelopeError.wrappedKeyOpenFailed(recipient.uuid)
        }
        throw ContentCryptoEnvelopeError.wrappedKeyNotFound(recipient.uuid)
    }

    private static func descriptorPriority(
        _ descriptor: WrappedContentKeyDescriptor,
        recipientUUID: String,
        keyID: String?
    ) -> Int {
        if descriptor.recipientIdentityUUID == recipientUUID {
            return 0
        }
        if let keyID, descriptor.recipientKeyID == keyID {
            return 1
        }
        return 2
    }
}
