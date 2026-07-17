// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum UserOwnedBackupError: Error, Equatable, LocalizedError {
    case invalidManifest(String)
    case signingUnavailable
    case encryptedEnvelopeInvalid
    case senderVerificationFailed

    public var errorDescription: String? {
        switch self {
        case let .invalidManifest(reason):
            return "The user-owned backup manifest is invalid: \(reason)"
        case .signingUnavailable:
            return "The owner signing authority is unavailable."
        case .encryptedEnvelopeInvalid:
            return "The reconstructed backup encryption envelope is invalid."
        case .senderVerificationFailed:
            return "The backup envelope did not verify as owner-signed."
        }
    }
}

/// Encrypts private storage routes before they enter the inventory or its
/// portable recovery root. The serialized envelope deliberately omits stable
/// recipient UUIDs; only approved recovery identities can open it.
public enum UserDataOwnerSealedLocatorCodec {
    public static func seal(
        locator: Data,
        inventoryID: String,
        representationID: String,
        owner: Identity,
        recoveryRecipients: [Identity],
        provider: IdentityKeyRoleProviderProtocol,
        envelopeGeneration: Int? = nil
    ) async throws -> Data {
        guard locator.isEmpty == false else {
            throw UserOwnedBackupError.encryptedEnvelopeInvalid
        }
        try [inventoryID, representationID].forEach(EntityAuthorityCanonical.validateIdentifier)
        let envelope = try await ContentCryptoEnvelopeUtility.seal(
            plaintext: locator,
            sender: owner,
            recipients: recoveryRecipients,
            provider: provider,
            suite: .userOwnedBackupV1,
            associatedDataContext: associatedDataContext(
                inventoryID: inventoryID,
                representationID: representationID
            ),
            envelopeGeneration: envelopeGeneration,
            includeRecipientIdentityMetadata: false
        )
        guard validates(
            sealedLocator: try EntityAuthorityCanonical.data(for: envelope),
            inventoryID: inventoryID,
            representationID: representationID,
            owner: owner
        ) else {
            throw UserOwnedBackupError.encryptedEnvelopeInvalid
        }
        return try EntityAuthorityCanonical.data(for: envelope)
    }

    public static func open(
        sealedLocator: Data,
        inventoryID: String,
        representationID: String,
        recipient: Identity,
        owner: Identity,
        provider: IdentityKeyRoleProviderProtocol
    ) async throws -> Data {
        guard validates(
            sealedLocator: sealedLocator,
            inventoryID: inventoryID,
            representationID: representationID,
            owner: owner
        ) else {
            throw UserOwnedBackupError.encryptedEnvelopeInvalid
        }
        let envelope = try JSONDecoder().decode(EncryptedContentEnvelope.self, from: sealedLocator)
        return try await ContentCryptoEnvelopeUtility.open(
            envelope: envelope,
            recipient: recipient,
            sender: owner,
            provider: provider
        ).plaintext
    }

    /// Public-key-only validation lets inventory verification reject plaintext,
    /// rebound, or unsigned locator bytes without requiring a recovery key.
    public static func validates(
        sealedLocator: Data,
        inventoryID: String,
        representationID: String,
        owner: Identity
    ) -> Bool {
        do {
            try [inventoryID, representationID].forEach(EntityAuthorityCanonical.validateIdentifier)
            let envelope = try JSONDecoder().decode(
                EncryptedContentEnvelope.self,
                from: sealedLocator
            )
            guard envelope.header.suiteID == ContentCryptoSuite.userOwnedBackupV1.id,
                  envelope.header.contentAlgorithm == .chachaPoly,
                  envelope.header.keyWrappingAlgorithm == .x25519SharedSecret,
                  envelope.header.associatedDataContext == associatedDataContext(
                    inventoryID: inventoryID,
                    representationID: representationID
                  ),
                  envelope.header.recipientKeys.isEmpty == false,
                  envelope.header.recipientKeys.allSatisfy({
                    $0.recipientIdentityUUID == nil
                        && $0.recipientKeyID.hasPrefix("opaque-key-")
                  }),
                  envelope.header.senderKeyID == nil,
                  let signature = envelope.senderSignature else {
                return false
            }
            let headerData = try CanonicalPayloadEncoder.data(for: envelope.header)
            return IdentityPublicKeySignatureVerifier.verify(
                signature: signature,
                messageData: headerData + envelope.combinedCiphertext,
                identity: owner
            )
        } catch {
            return false
        }
    }

    private static func associatedDataContext(
        inventoryID: String,
        representationID: String
    ) -> String {
        let material = Data(
            "HAVEN.UserDataLocator.Context.v1|\(inventoryID)|\(representationID)".utf8
        )
        return "locator-context-" + FlowHasher.sha256Hex(material)
    }
}

public struct UserOwnedBackupManifest: Codable, Equatable {
    public static let schema = "haven.user-owned-backup-manifest.v0"

    public var schema: String
    public var backupSetID: String
    public var inventoryID: String
    public var datasetID: String
    public var versionID: String
    public var encryptionSuiteID: String
    public var encryptedEnvelopeHash: String
    public var erasureSet: UserDataErasureSetDescriptor
    /// Hash commitments to opaque recipient key IDs. No stable Identity UUID is stored.
    public var recoveryRecipientKeyCommitments: [String]
    public var ownerIdentityUUID: String
    public var ownerSigningKeyFingerprint: String
    public var createdAtEpochMilliseconds: Int
    public var signature: Data

    public init(
        schema: String = Self.schema,
        backupSetID: String,
        inventoryID: String,
        datasetID: String,
        versionID: String,
        encryptionSuiteID: String,
        encryptedEnvelopeHash: String,
        erasureSet: UserDataErasureSetDescriptor,
        recoveryRecipientKeyCommitments: [String],
        ownerIdentityUUID: String,
        ownerSigningKeyFingerprint: String,
        createdAtEpochMilliseconds: Int,
        signature: Data
    ) {
        self.schema = schema
        self.backupSetID = backupSetID
        self.inventoryID = inventoryID
        self.datasetID = datasetID
        self.versionID = versionID
        self.encryptionSuiteID = encryptionSuiteID
        self.encryptedEnvelopeHash = encryptedEnvelopeHash
        self.erasureSet = erasureSet
        self.recoveryRecipientKeyCommitments = recoveryRecipientKeyCommitments
        self.ownerIdentityUUID = ownerIdentityUUID
        self.ownerSigningKeyFingerprint = ownerSigningKeyFingerprint
        self.createdAtEpochMilliseconds = createdAtEpochMilliseconds
        self.signature = signature
    }

    public func signingData() throws -> Data {
        try EntityAuthorityCanonical.data(for: UnsignedUserOwnedBackupManifest(self))
    }

    public func canonicalHash() throws -> String {
        FlowHasher.sha256Hex(try EntityAuthorityCanonical.data(for: self))
    }

    public func verifies(owner: Identity) -> Bool {
        do {
            try validateFields(owner: owner)
            return IdentityPublicKeySignatureVerifier.verify(
                signature: signature,
                messageData: try signingData(),
                identity: owner
            )
        } catch {
            return false
        }
    }

    public func backupSetRecord() throws -> UserDataBackupSetRecord {
        guard schema == Self.schema else {
            throw UserOwnedBackupError.invalidManifest("schema")
        }
        return UserDataBackupSetRecord(
            setID: backupSetID,
            datasetID: datasetID,
            versionID: versionID,
            manifestHash: try canonicalHash(),
            encryptionSuiteID: encryptionSuiteID,
            dataShardCount: erasureSet.dataShardCount,
            parityShardCount: erasureSet.parityShardCount,
            recoveryRecipientCount: recoveryRecipientKeyCommitments.count,
            createdAtEpochMilliseconds: createdAtEpochMilliseconds
        )
    }

    fileprivate func validateFields(owner: Identity) throws {
        guard schema == Self.schema else {
            throw UserOwnedBackupError.invalidManifest("schema")
        }
        try [inventoryID, datasetID, versionID].forEach(EntityAuthorityCanonical.validateIdentifier)
        try erasureSet.validate()
        guard backupSetID == erasureSet.setID,
              encryptionSuiteID == ContentCryptoSuite.userOwnedBackupV1.id,
              encryptedEnvelopeHash == erasureSet.payloadHash,
              recoveryRecipientKeyCommitments.isEmpty == false,
              recoveryRecipientKeyCommitments == recoveryRecipientKeyCommitments.sorted(),
              recoveryRecipientKeyCommitments.count == Set(recoveryRecipientKeyCommitments).count,
              recoveryRecipientKeyCommitments.allSatisfy(UserDataErasureSetDescriptor.isSHA256Hex),
              owner.uuid == ownerIdentityUUID,
              owner.signingPublicKeyFingerprint == ownerSigningKeyFingerprint,
              createdAtEpochMilliseconds >= 0 else {
            throw UserOwnedBackupError.invalidManifest("binding_or_canonical_order")
        }
    }
}

public struct UserOwnedBackupPackage: Codable, Equatable {
    public var manifest: UserOwnedBackupManifest
    public var fragments: [UserDataErasureFragment]

    public init(
        manifest: UserOwnedBackupManifest,
        fragments: [UserDataErasureFragment]
    ) {
        self.manifest = manifest
        self.fragments = fragments
    }
}

/// Composes authenticated encryption with systematic erasure coding. Storage
/// custodians receive ciphertext fragments; decryption authority stays in the
/// owner-controlled IdentityVaults holding the wrapped recovery keys.
public enum UserOwnedBackupCodec {
    public static func seal(
        plaintext: Data,
        inventoryID: String,
        datasetID: String,
        versionID: String,
        owner: Identity,
        recoveryRecipients: [Identity],
        provider: IdentityKeyRoleProviderProtocol,
        erasureProfile: UserDataErasureProfile = .default4Plus2,
        createdAtEpochMilliseconds: Int,
        envelopeGeneration: Int? = nil
    ) async throws -> UserOwnedBackupPackage {
        try [inventoryID, datasetID, versionID].forEach(EntityAuthorityCanonical.validateIdentifier)
        try erasureProfile.validate()
        guard let ownerFingerprint = owner.signingPublicKeyFingerprint else {
            throw UserOwnedBackupError.signingUnavailable
        }
        let context = associatedDataContext(
            inventoryID: inventoryID,
            datasetID: datasetID,
            versionID: versionID
        )
        let envelope = try await ContentCryptoEnvelopeUtility.seal(
            plaintext: plaintext,
            sender: owner,
            recipients: recoveryRecipients,
            provider: provider,
            suite: .userOwnedBackupV1,
            associatedDataContext: context,
            envelopeGeneration: envelopeGeneration,
            includeRecipientIdentityMetadata: false
        )
        guard envelope.header.recipientKeys.isEmpty == false,
              envelope.header.recipientKeys.allSatisfy({
                  $0.recipientIdentityUUID == nil && $0.recipientKeyID.hasPrefix("opaque-key-")
              }),
              envelope.header.senderKeyID == nil else {
            throw UserOwnedBackupError.encryptedEnvelopeInvalid
        }
        let envelopeData = try EntityAuthorityCanonical.data(for: envelope)
        let erasureSet = try UserDataErasureCoding.encode(
            encryptedPayload: envelopeData,
            profile: erasureProfile
        )
        let recipientCommitments = Array(Set(envelope.header.recipientKeys.map {
            FlowHasher.sha256Hex(Data($0.recipientKeyID.utf8))
        })).sorted()
        var manifest = UserOwnedBackupManifest(
            backupSetID: erasureSet.descriptor.setID,
            inventoryID: inventoryID,
            datasetID: datasetID,
            versionID: versionID,
            encryptionSuiteID: envelope.header.suiteID,
            encryptedEnvelopeHash: erasureSet.descriptor.payloadHash,
            erasureSet: erasureSet.descriptor,
            recoveryRecipientKeyCommitments: recipientCommitments,
            ownerIdentityUUID: owner.uuid,
            ownerSigningKeyFingerprint: ownerFingerprint,
            createdAtEpochMilliseconds: createdAtEpochMilliseconds,
            signature: Data()
        )
        try manifest.validateFields(owner: owner)
        guard let signature = try await owner.sign(data: manifest.signingData()) else {
            throw UserOwnedBackupError.signingUnavailable
        }
        manifest.signature = signature
        return UserOwnedBackupPackage(manifest: manifest, fragments: erasureSet.fragments)
    }

    public static func recover(
        fragments: [UserDataErasureFragment],
        manifest: UserOwnedBackupManifest,
        recipient: Identity,
        owner: Identity,
        provider: IdentityKeyRoleProviderProtocol
    ) async throws -> Data {
        guard manifest.verifies(owner: owner) else {
            throw UserOwnedBackupError.invalidManifest("signature_or_contents")
        }
        let envelopeData = try UserDataErasureCoding.reconstruct(
            fragments: fragments,
            descriptor: manifest.erasureSet
        )
        guard FlowHasher.sha256Hex(envelopeData) == manifest.encryptedEnvelopeHash,
              let envelope = try? JSONDecoder().decode(EncryptedContentEnvelope.self, from: envelopeData),
              envelope.header.suiteID == ContentCryptoSuite.userOwnedBackupV1.id,
              envelope.header.associatedDataContext == associatedDataContext(
                inventoryID: manifest.inventoryID,
                datasetID: manifest.datasetID,
                versionID: manifest.versionID
              ),
              envelope.header.recipientKeys.allSatisfy({
                  $0.recipientIdentityUUID == nil && $0.recipientKeyID.hasPrefix("opaque-key-")
              }) else {
            throw UserOwnedBackupError.encryptedEnvelopeInvalid
        }
        let opened = try await ContentCryptoEnvelopeUtility.open(
            envelope: envelope,
            recipient: recipient,
            sender: owner,
            provider: provider
        )
        guard opened.senderVerified else {
            throw UserOwnedBackupError.senderVerificationFailed
        }
        return opened.plaintext
    }

    private static func associatedDataContext(
        inventoryID: String,
        datasetID: String,
        versionID: String
    ) -> String {
        let material = Data("HAVEN.UserOwnedBackup.Context.v1|\(inventoryID)|\(datasetID)|\(versionID)".utf8)
        return "backup-context-" + FlowHasher.sha256Hex(material)
    }
}

private struct UnsignedUserOwnedBackupManifest: Codable {
    var schema: String
    var backupSetID: String
    var inventoryID: String
    var datasetID: String
    var versionID: String
    var encryptionSuiteID: String
    var encryptedEnvelopeHash: String
    var erasureSet: UserDataErasureSetDescriptor
    var recoveryRecipientKeyCommitments: [String]
    var ownerIdentityUUID: String
    var ownerSigningKeyFingerprint: String
    var createdAtEpochMilliseconds: Int

    init(_ manifest: UserOwnedBackupManifest) {
        schema = manifest.schema
        backupSetID = manifest.backupSetID
        inventoryID = manifest.inventoryID
        datasetID = manifest.datasetID
        versionID = manifest.versionID
        encryptionSuiteID = manifest.encryptionSuiteID
        encryptedEnvelopeHash = manifest.encryptedEnvelopeHash
        erasureSet = manifest.erasureSet
        recoveryRecipientKeyCommitments = manifest.recoveryRecipientKeyCommitments
        ownerIdentityUUID = manifest.ownerIdentityUUID
        ownerSigningKeyFingerprint = manifest.ownerSigningKeyFingerprint
        createdAtEpochMilliseconds = manifest.createdAtEpochMilliseconds
    }
}
