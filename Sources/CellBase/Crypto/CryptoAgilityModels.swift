// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum CanonicalPayloadError: Error {
    case invalidJSONObject
}

public enum CanonicalPayloadEncoder {
    public static func data<T: Encodable>(
        for value: T,
        excludingTopLevelKeys keys: Set<String> = []
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        let jsonObject = try JSONSerialization.jsonObject(with: encoded, options: [])

        let filteredObject: Any
        if keys.isEmpty {
            filteredObject = jsonObject
        } else if var dictionary = jsonObject as? [String: Any] {
            for key in keys {
                dictionary.removeValue(forKey: key)
            }
            filteredObject = dictionary
        } else {
            filteredObject = jsonObject
        }

        guard JSONSerialization.isValidJSONObject(filteredObject) else {
            throw CanonicalPayloadError.invalidJSONObject
        }

        return try JSONSerialization.data(withJSONObject: filteredObject, options: [.sortedKeys])
    }
}

public enum ContentEncryptionAlgorithm: String, Codable, Sendable {
    case chachaPoly
    case aesGCM256
}

public enum ContentKeyAgreementAlgorithm: String, Codable, Sendable {
    case x25519HKDFSHA256
    case p256HKDFSHA256
}

public enum ContentKeyWrappingAlgorithm: String, Codable, Sendable {
    case directSymmetric
    case x25519SharedSecret
    case p256SharedSecret
}

public enum ContentCryptoPurpose: String, Codable, Sendable {
    case chatMessage
    case attachment
    case exportBundle
    case persistedCell
}

public struct ContentCryptoSuite: Codable, Equatable, Sendable {
    public var id: String
    public var version: Int
    public var purpose: ContentCryptoPurpose
    public var contentAlgorithm: ContentEncryptionAlgorithm
    public var keyAgreementAlgorithm: ContentKeyAgreementAlgorithm?
    public var keyWrappingAlgorithm: ContentKeyWrappingAlgorithm
    public var signatureAlgorithm: CurveAlgorithm?
    public var curveType: CurveType?
    public var requiresSenderSignature: Bool
    public var supportsForwardSecrecy: Bool

    public init(
        id: String,
        version: Int,
        purpose: ContentCryptoPurpose,
        contentAlgorithm: ContentEncryptionAlgorithm,
        keyAgreementAlgorithm: ContentKeyAgreementAlgorithm? = nil,
        keyWrappingAlgorithm: ContentKeyWrappingAlgorithm,
        signatureAlgorithm: CurveAlgorithm? = nil,
        curveType: CurveType? = nil,
        requiresSenderSignature: Bool,
        supportsForwardSecrecy: Bool
    ) {
        self.id = id
        self.version = version
        self.purpose = purpose
        self.contentAlgorithm = contentAlgorithm
        self.keyAgreementAlgorithm = keyAgreementAlgorithm
        self.keyWrappingAlgorithm = keyWrappingAlgorithm
        self.signatureAlgorithm = signatureAlgorithm
        self.curveType = curveType
        self.requiresSenderSignature = requiresSenderSignature
        self.supportsForwardSecrecy = supportsForwardSecrecy
    }

    public static let persistedCellV1 = ContentCryptoSuite(
        id: "haven.persisted-cell.v1",
        version: 1,
        purpose: .persistedCell,
        contentAlgorithm: .chachaPoly,
        keyWrappingAlgorithm: .directSymmetric,
        requiresSenderSignature: false,
        supportsForwardSecrecy: false
    )

    public static let chatMessageV1 = ContentCryptoSuite(
        id: "haven.chat.message.v1",
        version: 1,
        purpose: .chatMessage,
        contentAlgorithm: .chachaPoly,
        keyAgreementAlgorithm: .x25519HKDFSHA256,
        keyWrappingAlgorithm: .x25519SharedSecret,
        signatureAlgorithm: .EdDSA,
        curveType: .Curve25519,
        requiresSenderSignature: true,
        supportsForwardSecrecy: true
    )
}

public struct ContentCryptoPolicy: Codable, Equatable, Sendable {
    public var version: Int
    public var preferredSuiteID: String
    public var acceptedSuiteIDs: [String]
    public var allowLegacyFallback: Bool
    public var minimumRecipientCountForWrappedKeys: Int

    public init(
        version: Int = 1,
        preferredSuiteID: String,
        acceptedSuiteIDs: [String],
        allowLegacyFallback: Bool,
        minimumRecipientCountForWrappedKeys: Int = 1
    ) {
        self.version = version
        self.preferredSuiteID = preferredSuiteID
        self.acceptedSuiteIDs = acceptedSuiteIDs
        self.allowLegacyFallback = allowLegacyFallback
        self.minimumRecipientCountForWrappedKeys = minimumRecipientCountForWrappedKeys
    }

    public static let chatDefault = ContentCryptoPolicy(
        preferredSuiteID: ContentCryptoSuite.chatMessageV1.id,
        acceptedSuiteIDs: [ContentCryptoSuite.chatMessageV1.id],
        allowLegacyFallback: false
    )
}

public struct WrappedContentKeyDescriptor: Codable, Equatable, Sendable {
    public var recipientIdentityUUID: String?
    public var recipientKeyID: String
    public var algorithm: ContentKeyWrappingAlgorithm
    public var wrappedKeyMaterial: Data
    public var recipientCurveType: CurveType?
    public var recipientAlgorithm: CurveAlgorithm?
    public var ephemeralPublicKey: Data?

    public init(
        recipientIdentityUUID: String? = nil,
        recipientKeyID: String,
        algorithm: ContentKeyWrappingAlgorithm,
        wrappedKeyMaterial: Data,
        recipientCurveType: CurveType? = nil,
        recipientAlgorithm: CurveAlgorithm? = nil,
        ephemeralPublicKey: Data? = nil
    ) {
        self.recipientIdentityUUID = recipientIdentityUUID
        self.recipientKeyID = recipientKeyID
        self.algorithm = algorithm
        self.wrappedKeyMaterial = wrappedKeyMaterial
        self.recipientCurveType = recipientCurveType
        self.recipientAlgorithm = recipientAlgorithm
        self.ephemeralPublicKey = ephemeralPublicKey
    }
}

public struct EncryptedContentEnvelopeHeader: Codable, Equatable, Sendable {
    public var version: Int
    public var suiteID: String
    public var contentAlgorithm: ContentEncryptionAlgorithm
    public var keyWrappingAlgorithm: ContentKeyWrappingAlgorithm
    public var senderKeyID: String?
    public var recipientKeys: [WrappedContentKeyDescriptor]
    public var createdAt: String
    public var keyID: String?
    public var envelopeGeneration: Int?
    public var associatedDataContext: String?

    public init(
        version: Int = 1,
        suiteID: String,
        contentAlgorithm: ContentEncryptionAlgorithm,
        keyWrappingAlgorithm: ContentKeyWrappingAlgorithm,
        senderKeyID: String? = nil,
        recipientKeys: [WrappedContentKeyDescriptor],
        createdAt: String,
        keyID: String? = nil,
        envelopeGeneration: Int? = nil,
        associatedDataContext: String? = nil
    ) {
        self.version = version
        self.suiteID = suiteID
        self.contentAlgorithm = contentAlgorithm
        self.keyWrappingAlgorithm = keyWrappingAlgorithm
        self.senderKeyID = senderKeyID
        self.recipientKeys = recipientKeys
        self.createdAt = createdAt
        self.keyID = keyID
        self.envelopeGeneration = envelopeGeneration
        self.associatedDataContext = associatedDataContext
    }
}

public struct IdentityRolePublicKeyDescriptor: Codable, Equatable, Sendable {
    public var identityUUID: String
    public var displayName: String
    public var role: IdentityKeyRole
    public var keyID: String
    public var algorithm: CurveAlgorithm
    public var curveType: CurveType
    public var publicKey: Data

    public init(
        identityUUID: String,
        displayName: String,
        role: IdentityKeyRole,
        keyID: String,
        algorithm: CurveAlgorithm,
        curveType: CurveType,
        publicKey: Data
    ) {
        self.identityUUID = identityUUID
        self.displayName = displayName
        self.role = role
        self.keyID = keyID
        self.algorithm = algorithm
        self.curveType = curveType
        self.publicKey = publicKey
    }
}

public struct EncryptedContentEnvelope: Codable, Equatable, Sendable {
    public var header: EncryptedContentEnvelopeHeader
    public var combinedCiphertext: Data
    public var senderSignature: Data?

    public init(
        header: EncryptedContentEnvelopeHeader,
        combinedCiphertext: Data,
        senderSignature: Data? = nil
    ) {
        self.header = header
        self.combinedCiphertext = combinedCiphertext
        self.senderSignature = senderSignature
    }
}

public struct OpenedContentEnvelope: Codable, Equatable, Sendable {
    public var plaintext: Data
    public var suiteID: String
    public var recipientIdentityUUID: String
    public var recipientKeyID: String
    public var senderVerified: Bool
    public var associatedDataContext: String?
    public var envelopeGeneration: Int?
    public var contentAlgorithm: ContentEncryptionAlgorithm
    public var senderKeyID: String?

    public init(
        plaintext: Data,
        suiteID: String,
        recipientIdentityUUID: String,
        recipientKeyID: String,
        senderVerified: Bool,
        associatedDataContext: String?,
        envelopeGeneration: Int?,
        contentAlgorithm: ContentEncryptionAlgorithm,
        senderKeyID: String?
    ) {
        self.plaintext = plaintext
        self.suiteID = suiteID
        self.recipientIdentityUUID = recipientIdentityUUID
        self.recipientKeyID = recipientKeyID
        self.senderVerified = senderVerified
        self.associatedDataContext = associatedDataContext
        self.envelopeGeneration = envelopeGeneration
        self.contentAlgorithm = contentAlgorithm
        self.senderKeyID = senderKeyID
    }
}
