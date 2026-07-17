// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum UserDataResilienceError: Error, Equatable, LocalizedError {
    case invalidIdentifier(String)
    case invalidPolicy(String)
    case invalidGrant(String)
    case invalidReceipt(String)
    case invalidRepresentation(String)
    case invalidInventory(String)
    case invalidRecoveryRoot(String)
    case signingUnavailable

    public var errorDescription: String? {
        switch self {
        case let .invalidIdentifier(value):
            return "Invalid opaque user-data identifier: \(value)"
        case let .invalidPolicy(reason):
            return "Invalid user-data resilience policy: \(reason)"
        case let .invalidGrant(reason):
            return "Invalid user-data storage grant: \(reason)"
        case let .invalidReceipt(reason):
            return "Invalid user-data storage receipt: \(reason)"
        case let .invalidRepresentation(reason):
            return "Invalid user-data representation record: \(reason)"
        case let .invalidInventory(reason):
            return "Invalid user-data inventory snapshot: \(reason)"
        case let .invalidRecoveryRoot(reason):
            return "Invalid user-data recovery root: \(reason)"
        case .signingUnavailable:
            return "The required owner or custodian signing authority is unavailable."
        }
    }
}

public enum UserDataRepresentationKind: String, Codable, Sendable {
    case canonical
    case fullReplica = "full_replica"
    case cache
    case backupFragment = "backup_fragment"
    case inventoryReplica = "inventory_replica"
    case keyRecoveryEnvelope = "key_recovery_envelope"
    case recoveryRoot = "recovery_root"
}

public enum UserDataRepresentationState: String, Codable, Sendable {
    case planned
    case available
    case degraded
    case deletionRequested = "deletion_requested"
    case deleted
    case lost
}

public enum UserDataVerificationKind: String, Codable, Sendable {
    case readBack = "read_back"
    case hashChallenge = "hash_challenge"
    case fullRestore = "full_restore"
    case deletionConfirmation = "deletion_confirmation"
}

/// Owner-signed authorization for one exact representation at one admitted
/// custodian. A route, endpoint, or successful byte delivery is not a grant.
public struct UserDataStorageGrant: Codable, Equatable {
    public static let schema = "haven.user-data-storage-grant.v0"
    public static let capability = "userData.representation.store"

    public var schema: String
    public var grantID: String
    public var inventoryID: String
    public var datasetID: String
    public var versionID: String
    public var representationID: String
    public var representationKind: UserDataRepresentationKind
    public var contentHash: String
    public var byteCount: Int
    public var faultDomainID: String
    public var locatorCommitment: String
    public var custodianIdentity: IdentityPublicKeyDescriptor
    public var custodianSigningKeyFingerprint: String
    public var capability: String
    public var ownerIdentityUUID: String
    public var ownerSigningKeyFingerprint: String
    public var issuedAtEpochMilliseconds: Int
    public var expiresAtEpochMilliseconds: Int
    public var signature: Data

    public init(
        schema: String = Self.schema,
        grantID: String,
        inventoryID: String,
        datasetID: String,
        versionID: String,
        representationID: String,
        representationKind: UserDataRepresentationKind,
        contentHash: String,
        byteCount: Int,
        faultDomainID: String,
        locatorCommitment: String,
        custodianIdentity: IdentityPublicKeyDescriptor,
        custodianSigningKeyFingerprint: String,
        capability: String = Self.capability,
        ownerIdentityUUID: String,
        ownerSigningKeyFingerprint: String,
        issuedAtEpochMilliseconds: Int,
        expiresAtEpochMilliseconds: Int,
        signature: Data
    ) {
        self.schema = schema
        self.grantID = grantID
        self.inventoryID = inventoryID
        self.datasetID = datasetID
        self.versionID = versionID
        self.representationID = representationID
        self.representationKind = representationKind
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.faultDomainID = faultDomainID
        self.locatorCommitment = locatorCommitment
        self.custodianIdentity = custodianIdentity
        self.custodianSigningKeyFingerprint = custodianSigningKeyFingerprint
        self.capability = capability
        self.ownerIdentityUUID = ownerIdentityUUID
        self.ownerSigningKeyFingerprint = ownerSigningKeyFingerprint
        self.issuedAtEpochMilliseconds = issuedAtEpochMilliseconds
        self.expiresAtEpochMilliseconds = expiresAtEpochMilliseconds
        self.signature = signature
    }

    public static func signed(
        grantID: String,
        inventoryID: String,
        datasetID: String,
        versionID: String,
        representationID: String,
        representationKind: UserDataRepresentationKind,
        contentHash: String,
        byteCount: Int,
        faultDomainID: String,
        ownerSealedLocator: Data,
        custodian: Identity,
        owner: Identity,
        issuedAtEpochMilliseconds: Int,
        expiresAtEpochMilliseconds: Int
    ) async throws -> Self {
        guard let custodianDescriptor = IdentityPublicKeySignatureVerifier.descriptor(for: custodian),
              let custodianFingerprint = custodian.signingPublicKeyFingerprint,
              let ownerFingerprint = owner.signingPublicKeyFingerprint else {
            throw UserDataResilienceError.signingUnavailable
        }
        guard UserDataOwnerSealedLocatorCodec.validates(
            sealedLocator: ownerSealedLocator,
            inventoryID: inventoryID,
            representationID: representationID,
            owner: owner
        ) else {
            throw UserDataResilienceError.invalidGrant("owner_sealed_locator")
        }
        var grant = Self(
            grantID: grantID,
            inventoryID: inventoryID,
            datasetID: datasetID,
            versionID: versionID,
            representationID: representationID,
            representationKind: representationKind,
            contentHash: contentHash,
            byteCount: byteCount,
            faultDomainID: faultDomainID,
            locatorCommitment: FlowHasher.sha256Hex(ownerSealedLocator),
            custodianIdentity: custodianDescriptor,
            custodianSigningKeyFingerprint: custodianFingerprint,
            ownerIdentityUUID: owner.uuid,
            ownerSigningKeyFingerprint: ownerFingerprint,
            issuedAtEpochMilliseconds: issuedAtEpochMilliseconds,
            expiresAtEpochMilliseconds: expiresAtEpochMilliseconds,
            signature: Data()
        )
        try grant.validateFields(atEpochMilliseconds: issuedAtEpochMilliseconds)
        guard let signature = try await owner.sign(data: grant.signingData()) else {
            throw UserDataResilienceError.signingUnavailable
        }
        grant.signature = signature
        return grant
    }

    public func signingData() throws -> Data {
        try UserDataResilienceCanonical.data(for: UnsignedUserDataStorageGrant(self))
    }

    public func canonicalHash() throws -> String {
        FlowHasher.sha256Hex(try UserDataResilienceCanonical.data(for: self))
    }

    public func verifies(owner: Identity, atEpochMilliseconds: Int) -> Bool {
        do {
            try validateFields(atEpochMilliseconds: atEpochMilliseconds)
            guard owner.uuid == ownerIdentityUUID,
                  owner.signingPublicKeyFingerprint == ownerSigningKeyFingerprint else {
                return false
            }
            return IdentityPublicKeySignatureVerifier.verify(
                signature: signature,
                messageData: try signingData(),
                identity: owner
            )
        } catch {
            return false
        }
    }

    fileprivate func validateFields(atEpochMilliseconds: Int) throws {
        guard schema == Self.schema else {
            throw UserDataResilienceError.invalidGrant("schema")
        }
        try [grantID, inventoryID, datasetID, versionID, representationID, faultDomainID]
            .forEach(UserDataResilienceCanonical.validateIdentifier)
        guard capability == Self.capability else {
            throw UserDataResilienceError.invalidGrant("capability")
        }
        guard UserDataResilienceCanonical.isSHA256Hex(contentHash),
              UserDataResilienceCanonical.isSHA256Hex(locatorCommitment),
              byteCount >= 0 else {
            throw UserDataResilienceError.invalidGrant("content_binding")
        }
        guard custodianIdentity.uuid.isEmpty == false,
              custodianIdentity.userDataSigningKeyFingerprint == custodianSigningKeyFingerprint else {
            throw UserDataResilienceError.invalidGrant("custodian_identity_binding")
        }
        guard issuedAtEpochMilliseconds >= 0,
              expiresAtEpochMilliseconds > issuedAtEpochMilliseconds,
              atEpochMilliseconds >= issuedAtEpochMilliseconds,
              atEpochMilliseconds <= expiresAtEpochMilliseconds else {
            throw UserDataResilienceError.invalidGrant("validity_window")
        }
    }
}

/// Custodian-signed evidence that exact bytes were durably stored and checked.
/// The proof kind is a claim by the admitted custodian; owner-side full-restore
/// tests remain the strongest evidence and should refresh this receipt.
public struct UserDataStorageReceipt: Codable, Equatable {
    public static let schema = "haven.user-data-storage-receipt.v0"

    public var schema: String
    public var receiptID: String
    public var status: String
    public var grantHash: String
    public var representationID: String
    public var contentHash: String
    public var byteCount: Int
    public var custodianIdentityUUID: String
    public var custodianSigningKeyFingerprint: String
    public var durabilityLevel: EntityAuthorityReplicaDurabilityLevel
    public var storedAtEpochMilliseconds: Int
    public var verifiedAtEpochMilliseconds: Int
    public var verificationKind: UserDataVerificationKind
    public var verificationProofHash: String
    public var signature: Data

    public init(
        schema: String = Self.schema,
        receiptID: String,
        status: String = "representation_persisted",
        grantHash: String,
        representationID: String,
        contentHash: String,
        byteCount: Int,
        custodianIdentityUUID: String,
        custodianSigningKeyFingerprint: String,
        durabilityLevel: EntityAuthorityReplicaDurabilityLevel,
        storedAtEpochMilliseconds: Int,
        verifiedAtEpochMilliseconds: Int,
        verificationKind: UserDataVerificationKind,
        verificationProofHash: String,
        signature: Data
    ) {
        self.schema = schema
        self.receiptID = receiptID
        self.status = status
        self.grantHash = grantHash
        self.representationID = representationID
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.custodianIdentityUUID = custodianIdentityUUID
        self.custodianSigningKeyFingerprint = custodianSigningKeyFingerprint
        self.durabilityLevel = durabilityLevel
        self.storedAtEpochMilliseconds = storedAtEpochMilliseconds
        self.verifiedAtEpochMilliseconds = verifiedAtEpochMilliseconds
        self.verificationKind = verificationKind
        self.verificationProofHash = verificationProofHash
        self.signature = signature
    }

    public static func signed(
        grant: UserDataStorageGrant,
        custodian: Identity,
        durabilityLevel: EntityAuthorityReplicaDurabilityLevel,
        storedAtEpochMilliseconds: Int,
        verifiedAtEpochMilliseconds: Int,
        verificationKind: UserDataVerificationKind,
        verificationProofHash: String
    ) async throws -> Self {
        guard durabilityLevel != .transportDeliveryOnly,
              custodian.uuid == grant.custodianIdentity.uuid,
              custodian.signingPublicKeyFingerprint == grant.custodianSigningKeyFingerprint else {
            throw UserDataResilienceError.invalidReceipt("custodian_or_durability")
        }
        let grantHash = try grant.canonicalHash()
        let receiptIDMaterial = Data(
            "\(grantHash)|\(verifiedAtEpochMilliseconds)|\(verificationKind.rawValue)|\(verificationProofHash)".utf8
        )
        var receipt = Self(
            receiptID: "storage-receipt-" + FlowHasher.sha256Hex(receiptIDMaterial),
            grantHash: grantHash,
            representationID: grant.representationID,
            contentHash: grant.contentHash,
            byteCount: grant.byteCount,
            custodianIdentityUUID: custodian.uuid,
            custodianSigningKeyFingerprint: grant.custodianSigningKeyFingerprint,
            durabilityLevel: durabilityLevel,
            storedAtEpochMilliseconds: storedAtEpochMilliseconds,
            verifiedAtEpochMilliseconds: verifiedAtEpochMilliseconds,
            verificationKind: verificationKind,
            verificationProofHash: verificationProofHash,
            signature: Data()
        )
        try receipt.validateFields(grant: grant, atEpochMilliseconds: verifiedAtEpochMilliseconds)
        guard let signature = try await custodian.sign(data: receipt.signingData()) else {
            throw UserDataResilienceError.signingUnavailable
        }
        receipt.signature = signature
        return receipt
    }

    public func signingData() throws -> Data {
        try UserDataResilienceCanonical.data(for: UnsignedUserDataStorageReceipt(self))
    }

    public func canonicalHash() throws -> String {
        FlowHasher.sha256Hex(try UserDataResilienceCanonical.data(for: self))
    }

    public func verifies(
        grant: UserDataStorageGrant,
        atEpochMilliseconds: Int
    ) -> Bool {
        do {
            try validateFields(grant: grant, atEpochMilliseconds: atEpochMilliseconds)
            return IdentityPublicKeySignatureVerifier.verify(
                signature: signature,
                messageData: try signingData(),
                descriptor: grant.custodianIdentity
            )
        } catch {
            return false
        }
    }

    private func validateFields(
        grant: UserDataStorageGrant,
        atEpochMilliseconds: Int
    ) throws {
        guard schema == Self.schema, status == "representation_persisted" else {
            throw UserDataResilienceError.invalidReceipt("schema_or_status")
        }
        try UserDataResilienceCanonical.validateIdentifier(receiptID)
        guard grantHash == (try grant.canonicalHash()),
              representationID == grant.representationID,
              contentHash == grant.contentHash,
              byteCount == grant.byteCount,
              custodianIdentityUUID == grant.custodianIdentity.uuid,
              custodianSigningKeyFingerprint == grant.custodianSigningKeyFingerprint else {
            throw UserDataResilienceError.invalidReceipt("grant_binding")
        }
        guard durabilityLevel != .transportDeliveryOnly,
              UserDataResilienceCanonical.isSHA256Hex(verificationProofHash),
              storedAtEpochMilliseconds >= grant.issuedAtEpochMilliseconds,
              verifiedAtEpochMilliseconds >= storedAtEpochMilliseconds,
              verifiedAtEpochMilliseconds <= grant.expiresAtEpochMilliseconds,
              atEpochMilliseconds >= verifiedAtEpochMilliseconds,
              atEpochMilliseconds <= grant.expiresAtEpochMilliseconds else {
            throw UserDataResilienceError.invalidReceipt("verification_or_validity")
        }
    }
}

public struct UserDataBackupFragmentPlacement: Codable, Equatable, Sendable {
    public var setID: String
    public var fragmentIndex: Int
    public var dataShardCount: Int
    public var parityShardCount: Int

    public init(
        setID: String,
        fragmentIndex: Int,
        dataShardCount: Int,
        parityShardCount: Int
    ) {
        self.setID = setID
        self.fragmentIndex = fragmentIndex
        self.dataShardCount = dataShardCount
        self.parityShardCount = parityShardCount
    }
}

public struct UserDataRepresentationRecord: Codable, Equatable {
    public var representationID: String
    public var datasetID: String
    public var versionID: String
    public var kind: UserDataRepresentationKind
    public var state: UserDataRepresentationState
    public var contentHash: String
    public var byteCount: Int
    public var ownerSealedLocator: Data?
    public var storageGrant: UserDataStorageGrant?
    public var storageReceipt: UserDataStorageReceipt?
    public var backupFragment: UserDataBackupFragmentPlacement?
    public var deletionReceiptHash: String?
    public var createdAtEpochMilliseconds: Int
    public var updatedAtEpochMilliseconds: Int

    public init(
        representationID: String,
        datasetID: String,
        versionID: String,
        kind: UserDataRepresentationKind,
        state: UserDataRepresentationState,
        contentHash: String,
        byteCount: Int,
        ownerSealedLocator: Data?,
        storageGrant: UserDataStorageGrant?,
        storageReceipt: UserDataStorageReceipt?,
        backupFragment: UserDataBackupFragmentPlacement? = nil,
        deletionReceiptHash: String? = nil,
        createdAtEpochMilliseconds: Int,
        updatedAtEpochMilliseconds: Int
    ) {
        self.representationID = representationID
        self.datasetID = datasetID
        self.versionID = versionID
        self.kind = kind
        self.state = state
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.ownerSealedLocator = ownerSealedLocator
        self.storageGrant = storageGrant
        self.storageReceipt = storageReceipt
        self.backupFragment = backupFragment
        self.deletionReceiptHash = deletionReceiptHash
        self.createdAtEpochMilliseconds = createdAtEpochMilliseconds
        self.updatedAtEpochMilliseconds = updatedAtEpochMilliseconds
    }

    public var faultDomainID: String? { storageGrant?.faultDomainID }
    public var lastVerifiedAtEpochMilliseconds: Int? {
        storageReceipt?.verifiedAtEpochMilliseconds
    }

    fileprivate func validate(owner: Identity, atEpochMilliseconds: Int) throws {
        try [representationID, datasetID, versionID]
            .forEach(UserDataResilienceCanonical.validateIdentifier)
        guard UserDataResilienceCanonical.isSHA256Hex(contentHash),
              byteCount >= 0,
              createdAtEpochMilliseconds >= 0,
              updatedAtEpochMilliseconds >= createdAtEpochMilliseconds else {
            throw UserDataResilienceError.invalidRepresentation("content_or_time")
        }
        if kind == .backupFragment {
            guard let backupFragment,
                  backupFragment.fragmentIndex >= 0,
                  backupFragment.fragmentIndex < backupFragment.dataShardCount + backupFragment.parityShardCount,
                  backupFragment.setID.hasPrefix("ers-") else {
                throw UserDataResilienceError.invalidRepresentation("backup_fragment")
            }
        } else if backupFragment != nil {
            throw UserDataResilienceError.invalidRepresentation("unexpected_backup_fragment")
        }

        switch state {
        case .available, .degraded:
            guard let ownerSealedLocator,
                  ownerSealedLocator.isEmpty == false,
                  let storageGrant,
                  let storageReceipt,
                  storageGrant.inventoryID.isEmpty == false,
                  storageGrant.representationID == representationID,
                  storageGrant.datasetID == datasetID,
                  storageGrant.versionID == versionID,
                  storageGrant.representationKind == kind,
                  storageGrant.contentHash == contentHash,
                  storageGrant.byteCount == byteCount,
                  storageGrant.locatorCommitment == FlowHasher.sha256Hex(ownerSealedLocator),
                  UserDataOwnerSealedLocatorCodec.validates(
                    sealedLocator: ownerSealedLocator,
                    inventoryID: storageGrant.inventoryID,
                    representationID: representationID,
                    owner: owner
                  ),
                  storageGrant.verifies(owner: owner, atEpochMilliseconds: atEpochMilliseconds),
                  storageReceipt.verifies(grant: storageGrant, atEpochMilliseconds: atEpochMilliseconds) else {
                throw UserDataResilienceError.invalidRepresentation("storage_evidence")
            }
        case .deleted:
            guard let deletionReceiptHash,
                  UserDataResilienceCanonical.isSHA256Hex(deletionReceiptHash) else {
                throw UserDataResilienceError.invalidRepresentation("deletion_evidence")
            }
        case .planned, .deletionRequested, .lost:
            break
        }
    }
}

public struct UserDataBackupSetRecord: Codable, Equatable, Sendable {
    public var setID: String
    public var datasetID: String
    public var versionID: String
    public var manifestHash: String
    public var encryptionSuiteID: String
    public var dataShardCount: Int
    public var parityShardCount: Int
    public var recoveryRecipientCount: Int
    public var createdAtEpochMilliseconds: Int

    public init(
        setID: String,
        datasetID: String,
        versionID: String,
        manifestHash: String,
        encryptionSuiteID: String,
        dataShardCount: Int,
        parityShardCount: Int,
        recoveryRecipientCount: Int,
        createdAtEpochMilliseconds: Int
    ) {
        self.setID = setID
        self.datasetID = datasetID
        self.versionID = versionID
        self.manifestHash = manifestHash
        self.encryptionSuiteID = encryptionSuiteID
        self.dataShardCount = dataShardCount
        self.parityShardCount = parityShardCount
        self.recoveryRecipientCount = recoveryRecipientCount
        self.createdAtEpochMilliseconds = createdAtEpochMilliseconds
    }

    fileprivate func validate() throws {
        try [datasetID, versionID].forEach(UserDataResilienceCanonical.validateIdentifier)
        let profile = UserDataErasureProfile(
            dataShardCount: dataShardCount,
            parityShardCount: parityShardCount
        )
        try profile.validate()
        guard setID.hasPrefix("ers-"),
              UserDataResilienceCanonical.isSHA256Hex(manifestHash),
              encryptionSuiteID == ContentCryptoSuite.userOwnedBackupV1.id,
              recoveryRecipientCount > 0,
              createdAtEpochMilliseconds >= 0 else {
            throw UserDataResilienceError.invalidInventory("backup_set")
        }
    }
}

public struct UserDataResiliencePolicy: Codable, Equatable, Sendable {
    public static let schema = "haven.user-data-resilience-policy.v0"

    public var schema: String
    public var erasureProfile: UserDataErasureProfile
    public var minimumInventoryReplicaCount: Int
    public var minimumInventoryFaultDomainCount: Int
    public var minimumRecoveryRecipientCount: Int
    public var minimumRecoveryRootCopyCount: Int
    public var maximumVerificationAgeMilliseconds: Int
    public var requireDistinctFragmentFaultDomains: Bool

    public init(
        schema: String = Self.schema,
        erasureProfile: UserDataErasureProfile = .default4Plus2,
        minimumInventoryReplicaCount: Int = 3,
        minimumInventoryFaultDomainCount: Int = 3,
        minimumRecoveryRecipientCount: Int = 2,
        minimumRecoveryRootCopyCount: Int = 2,
        maximumVerificationAgeMilliseconds: Int = 30 * 24 * 60 * 60 * 1_000,
        requireDistinctFragmentFaultDomains: Bool = true
    ) {
        self.schema = schema
        self.erasureProfile = erasureProfile
        self.minimumInventoryReplicaCount = minimumInventoryReplicaCount
        self.minimumInventoryFaultDomainCount = minimumInventoryFaultDomainCount
        self.minimumRecoveryRecipientCount = minimumRecoveryRecipientCount
        self.minimumRecoveryRootCopyCount = minimumRecoveryRootCopyCount
        self.maximumVerificationAgeMilliseconds = maximumVerificationAgeMilliseconds
        self.requireDistinctFragmentFaultDomains = requireDistinctFragmentFaultDomains
    }

    public func validate() throws {
        guard schema == Self.schema else {
            throw UserDataResilienceError.invalidPolicy("schema")
        }
        try erasureProfile.validate()
        guard minimumInventoryReplicaCount > 0,
              minimumInventoryFaultDomainCount > 0,
              minimumInventoryFaultDomainCount <= minimumInventoryReplicaCount,
              minimumRecoveryRecipientCount > 0,
              minimumRecoveryRootCopyCount > 0,
              maximumVerificationAgeMilliseconds > 0 else {
            throw UserDataResilienceError.invalidPolicy("bounds")
        }
    }

    public func canonicalHash() throws -> String {
        try validate()
        return FlowHasher.sha256Hex(try UserDataResilienceCanonical.data(for: self))
    }
}

/// Private, owner-signed canonical metadata snapshot. Successive snapshots form
/// an anti-rollback chain and are themselves committed through EntityAuthority.
public struct UserDataInventorySnapshot: Codable, Equatable {
    public static let schema = "haven.user-data-inventory-snapshot.v0"

    public var schema: String
    public var inventoryID: String
    public var revision: Int
    public var previousSnapshotHash: String?
    public var ownerIdentityUUID: String
    public var ownerSigningKeyFingerprint: String
    public var policy: UserDataResiliencePolicy
    public var representations: [UserDataRepresentationRecord]
    public var backupSets: [UserDataBackupSetRecord]
    public var createdAtEpochMilliseconds: Int
    public var signature: Data

    public init(
        schema: String = Self.schema,
        inventoryID: String,
        revision: Int,
        previousSnapshotHash: String?,
        ownerIdentityUUID: String,
        ownerSigningKeyFingerprint: String,
        policy: UserDataResiliencePolicy,
        representations: [UserDataRepresentationRecord],
        backupSets: [UserDataBackupSetRecord],
        createdAtEpochMilliseconds: Int,
        signature: Data
    ) {
        self.schema = schema
        self.inventoryID = inventoryID
        self.revision = revision
        self.previousSnapshotHash = previousSnapshotHash
        self.ownerIdentityUUID = ownerIdentityUUID
        self.ownerSigningKeyFingerprint = ownerSigningKeyFingerprint
        self.policy = policy
        self.representations = representations
        self.backupSets = backupSets
        self.createdAtEpochMilliseconds = createdAtEpochMilliseconds
        self.signature = signature
    }

    public static func signed(
        inventoryID: String,
        previous: UserDataInventorySnapshot?,
        policy: UserDataResiliencePolicy,
        representations: [UserDataRepresentationRecord],
        backupSets: [UserDataBackupSetRecord],
        owner: Identity,
        createdAtEpochMilliseconds: Int
    ) async throws -> Self {
        guard let fingerprint = owner.signingPublicKeyFingerprint else {
            throw UserDataResilienceError.signingUnavailable
        }
        if let previous {
            guard previous.inventoryID == inventoryID,
                  previous.ownerIdentityUUID == owner.uuid,
                  previous.createdAtEpochMilliseconds <= createdAtEpochMilliseconds,
                  previous.verifies(
                    owner: owner,
                    atEpochMilliseconds: createdAtEpochMilliseconds
                  ) else {
                throw UserDataResilienceError.invalidInventory("previous_binding_or_signature")
            }
        }
        var snapshot = Self(
            inventoryID: inventoryID,
            revision: (previous?.revision ?? 0) + 1,
            previousSnapshotHash: try previous?.canonicalHash(),
            ownerIdentityUUID: owner.uuid,
            ownerSigningKeyFingerprint: fingerprint,
            policy: policy,
            representations: representations.sorted { $0.representationID < $1.representationID },
            backupSets: backupSets.sorted { $0.setID < $1.setID },
            createdAtEpochMilliseconds: createdAtEpochMilliseconds,
            signature: Data()
        )
        try snapshot.validateFields(owner: owner, atEpochMilliseconds: createdAtEpochMilliseconds)
        guard let signature = try await owner.sign(data: snapshot.signingData()) else {
            throw UserDataResilienceError.signingUnavailable
        }
        snapshot.signature = signature
        return snapshot
    }

    public func signingData() throws -> Data {
        try UserDataResilienceCanonical.data(for: UnsignedUserDataInventorySnapshot(self))
    }

    public func canonicalHash() throws -> String {
        FlowHasher.sha256Hex(try UserDataResilienceCanonical.data(for: self))
    }

    public func verifies(owner: Identity, atEpochMilliseconds: Int) -> Bool {
        do {
            try validateFields(owner: owner, atEpochMilliseconds: atEpochMilliseconds)
            return IdentityPublicKeySignatureVerifier.verify(
                signature: signature,
                messageData: try signingData(),
                identity: owner
            )
        } catch {
            return false
        }
    }

    public func verifiesSuccessor(
        of previous: UserDataInventorySnapshot,
        owner: Identity,
        atEpochMilliseconds: Int
    ) -> Bool {
        guard verifies(owner: owner, atEpochMilliseconds: atEpochMilliseconds),
              previous.verifies(owner: owner, atEpochMilliseconds: atEpochMilliseconds),
              inventoryID == previous.inventoryID,
              ownerIdentityUUID == previous.ownerIdentityUUID,
              revision == previous.revision + 1,
              previousSnapshotHash == (try? previous.canonicalHash()) else {
            return false
        }
        return true
    }

    public init(value: ValueType) throws {
        self = try UserDataResilienceCanonical.decode(Self.self, from: value)
    }

    public func valueType() throws -> ValueType {
        try UserDataResilienceCanonical.valueType(self)
    }

    private func validateFields(owner: Identity, atEpochMilliseconds: Int) throws {
        guard schema == Self.schema else {
            throw UserDataResilienceError.invalidInventory("schema")
        }
        try UserDataResilienceCanonical.validateIdentifier(inventoryID)
        try policy.validate()
        guard revision > 0,
              (revision == 1) == (previousSnapshotHash == nil),
              previousSnapshotHash == nil || UserDataResilienceCanonical.isSHA256Hex(previousSnapshotHash!),
              owner.uuid == ownerIdentityUUID,
              owner.signingPublicKeyFingerprint == ownerSigningKeyFingerprint,
              createdAtEpochMilliseconds >= 0,
              atEpochMilliseconds >= createdAtEpochMilliseconds else {
            throw UserDataResilienceError.invalidInventory("owner_revision_or_time")
        }
        guard representations == representations.sorted(by: { $0.representationID < $1.representationID }),
              Set(representations.map(\.representationID)).count == representations.count,
              backupSets == backupSets.sorted(by: { $0.setID < $1.setID }),
              Set(backupSets.map(\.setID)).count == backupSets.count else {
            throw UserDataResilienceError.invalidInventory("noncanonical_or_duplicate_records")
        }
        try representations.forEach {
            // A snapshot is immutable historical evidence. Validate the embedded
            // grants and receipts at the snapshot's creation time so a correctly
            // signed snapshot does not become cryptographically invalid merely
            // because a grant expires later. Live recoverability is checked
            // separately by UserDataRecoveryEvaluator at the requested epoch.
            try $0.validate(owner: owner, atEpochMilliseconds: createdAtEpochMilliseconds)
            guard $0.updatedAtEpochMilliseconds <= createdAtEpochMilliseconds,
                  $0.storageGrant?.inventoryID == inventoryID || $0.storageGrant == nil else {
                throw UserDataResilienceError.invalidInventory("representation_inventory_binding")
            }
        }
        try backupSets.forEach { try $0.validate() }
    }
}

public enum UserDataRecoveryStatus: String, Codable, Sendable {
    case healthy
    case degraded
    case unrecoverable
    case unknown
}

public struct UserDataDatasetRecoveryAssessment: Codable, Equatable, Sendable {
    public var datasetID: String
    public var versionID: String
    public var status: UserDataRecoveryStatus
    public var availableFullCopyCount: Int
    public var availableFragmentCount: Int
    public var distinctFragmentFaultDomainCount: Int
    public var recoverableBackupSetIDs: [String]
    public var issues: [String]
}

public struct UserDataRecoveryAssessment: Codable, Equatable, Sendable {
    public static let schema = "haven.user-data-recovery-assessment.v0"

    public var schema: String
    public var status: UserDataRecoveryStatus
    public var inventoryReplicaCount: Int
    public var inventoryFaultDomainCount: Int
    public var recoveryRootCopyCount: Int
    public var recoveryRootFaultDomainCount: Int
    public var staleRepresentationCount: Int
    public var datasets: [UserDataDatasetRecoveryAssessment]
    public var issues: [String]

    public init(
        schema: String = Self.schema,
        status: UserDataRecoveryStatus,
        inventoryReplicaCount: Int,
        inventoryFaultDomainCount: Int,
        recoveryRootCopyCount: Int,
        recoveryRootFaultDomainCount: Int,
        staleRepresentationCount: Int,
        datasets: [UserDataDatasetRecoveryAssessment],
        issues: [String]
    ) {
        self.schema = schema
        self.status = status
        self.inventoryReplicaCount = inventoryReplicaCount
        self.inventoryFaultDomainCount = inventoryFaultDomainCount
        self.recoveryRootCopyCount = recoveryRootCopyCount
        self.recoveryRootFaultDomainCount = recoveryRootFaultDomainCount
        self.staleRepresentationCount = staleRepresentationCount
        self.datasets = datasets
        self.issues = issues
    }
}

public enum UserDataRecoveryEvaluator {
    public static func assess(
        snapshot: UserDataInventorySnapshot,
        owner: Identity,
        atEpochMilliseconds: Int,
        recoveryRoot: UserDataRecoveryRoot? = nil,
        recoveryRootCopies: [UserDataRepresentationRecord] = []
    ) throws -> UserDataRecoveryAssessment {
        guard snapshot.verifies(owner: owner, atEpochMilliseconds: atEpochMilliseconds) else {
            throw UserDataResilienceError.invalidInventory("signature_or_contents")
        }
        let policy = snapshot.policy
        let currentRepresentations = snapshot.representations.filter {
            guard ($0.state == .available || $0.state == .degraded),
                  let verifiedAt = $0.lastVerifiedAtEpochMilliseconds else {
                return false
            }
            guard (try? $0.validate(owner: owner, atEpochMilliseconds: atEpochMilliseconds)) != nil else {
                return false
            }
            return atEpochMilliseconds - verifiedAt <= policy.maximumVerificationAgeMilliseconds
        }
        let staleCount = snapshot.representations.filter {
            guard ($0.state == .available || $0.state == .degraded),
                  let verifiedAt = $0.lastVerifiedAtEpochMilliseconds else {
                return $0.state == .available || $0.state == .degraded
            }
            return (try? $0.validate(owner: owner, atEpochMilliseconds: atEpochMilliseconds)) == nil
                || atEpochMilliseconds - verifiedAt > policy.maximumVerificationAgeMilliseconds
        }.count

        let inventoryReplicas = currentRepresentations.filter { $0.kind == .inventoryReplica }
        let inventoryFaultDomains = Set(inventoryReplicas.compactMap(\.faultDomainID))
        let snapshotHash = try snapshot.canonicalHash()
        let policyHash = try snapshot.policy.canonicalHash()
        let validRecoveryRoot: UserDataRecoveryRoot? = {
            guard let recoveryRoot,
                  recoveryRoot.verifies(owner: owner),
                  recoveryRoot.inventoryID == snapshot.inventoryID,
                  recoveryRoot.inventoryRevision == snapshot.revision,
                  recoveryRoot.inventorySnapshotHash == snapshotHash,
                  recoveryRoot.policyHash == policyHash,
                  recoveryRoot.createdAtEpochMilliseconds <= atEpochMilliseconds else {
                return nil
            }
            return recoveryRoot
        }()
        let recoveryRootHash = try validRecoveryRoot?.canonicalHash()
        let recoveryRootInventoryLocatorCount = validRecoveryRoot?.inventoryReplicaLocators.count ?? 0
        let recoveryRootInventoryFaultDomains = Set(
            validRecoveryRoot?.inventoryReplicaLocators.map(\.faultDomainID) ?? []
        )
        var uniqueRecoveryRootCopies: [String: UserDataRepresentationRecord] = [:]
        if let validRecoveryRoot, let recoveryRootHash {
            for record in recoveryRootCopies where
                record.kind == .recoveryRoot
                    && (record.state == .available || record.state == .degraded)
                    && record.datasetID == snapshot.inventoryID
                    && record.versionID == "root-\(validRecoveryRoot.rootGeneration)"
                    && record.contentHash == recoveryRootHash
                    && record.storageGrant?.inventoryID == snapshot.inventoryID
                    && (try? record.validate(
                        owner: owner,
                        atEpochMilliseconds: atEpochMilliseconds
                    )) != nil
                    && atEpochMilliseconds - (record.lastVerifiedAtEpochMilliseconds ?? 0)
                        <= policy.maximumVerificationAgeMilliseconds {
                if uniqueRecoveryRootCopies[record.representationID] == nil {
                    uniqueRecoveryRootCopies[record.representationID] = record
                }
            }
        }
        let recoveryRootCopyRecords = Array(uniqueRecoveryRootCopies.values)
        let recoveryRootFaultDomains = Set(recoveryRootCopyRecords.compactMap(\.faultDomainID))
        var globalIssues: [String] = []
        if inventoryReplicas.count < policy.minimumInventoryReplicaCount {
            globalIssues.append("inventory_replica_count_below_policy")
        }
        if inventoryFaultDomains.count < policy.minimumInventoryFaultDomainCount {
            globalIssues.append("inventory_fault_domains_below_policy")
        }
        if staleCount > 0 {
            globalIssues.append("stale_storage_verification")
        }
        if currentRepresentations.contains(where: { $0.state == .degraded }) {
            globalIssues.append("degraded_representation_present")
        }
        if validRecoveryRoot == nil {
            globalIssues.append("current_recovery_root_missing_or_invalid")
        }
        if recoveryRootCopyRecords.count < policy.minimumRecoveryRootCopyCount {
            globalIssues.append("recovery_root_copy_count_below_policy")
        }
        if recoveryRootFaultDomains.count < policy.minimumRecoveryRootCopyCount {
            globalIssues.append("recovery_root_fault_domains_below_policy")
        }
        if recoveryRootInventoryLocatorCount < policy.minimumInventoryReplicaCount {
            globalIssues.append("recovery_root_inventory_locator_count_below_policy")
        }
        if recoveryRootInventoryFaultDomains.count < policy.minimumInventoryFaultDomainCount {
            globalIssues.append("recovery_root_inventory_fault_domains_below_policy")
        }

        let datasetKeys = Set(snapshot.backupSets.map {
            UserDataDatasetKey(datasetID: $0.datasetID, versionID: $0.versionID)
        }).union(snapshot.representations.compactMap {
            guard $0.kind != .inventoryReplica,
                  $0.kind != .keyRecoveryEnvelope,
                  $0.kind != .recoveryRoot else { return nil }
            return UserDataDatasetKey(datasetID: $0.datasetID, versionID: $0.versionID)
        })
        var datasetAssessments: [UserDataDatasetRecoveryAssessment] = []
        for key in datasetKeys.sorted(by: {
            ($0.datasetID, $0.versionID) < ($1.datasetID, $1.versionID)
        }) {
            let datasetRepresentations = currentRepresentations.filter {
                $0.datasetID == key.datasetID && $0.versionID == key.versionID
            }
            let fullCopies = datasetRepresentations.filter {
                $0.kind == .canonical || $0.kind == .fullReplica
            }
            let backupRecords = snapshot.backupSets.filter {
                $0.datasetID == key.datasetID && $0.versionID == key.versionID
            }
            var recoverableSetIDs: [String] = []
            var bestFragmentCount = 0
            var bestFaultDomainCount = 0
            var hasFullyHealthySet = false
            var issues: [String] = []

            for backup in backupRecords {
                let fragments = datasetRepresentations.filter {
                    $0.kind == .backupFragment && $0.backupFragment?.setID == backup.setID
                }
                let uniqueFragments = Dictionary(
                    fragments.map { ($0.backupFragment!.fragmentIndex, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                let fragmentCount = uniqueFragments.count
                let faultDomainCount = Set(uniqueFragments.values.compactMap(\.faultDomainID)).count
                bestFragmentCount = max(bestFragmentCount, fragmentCount)
                bestFaultDomainCount = max(bestFaultDomainCount, faultDomainCount)
                if fragmentCount >= backup.dataShardCount {
                    recoverableSetIDs.append(backup.setID)
                }
                let requiredFaultDomains = policy.requireDistinctFragmentFaultDomains
                    ? backup.dataShardCount + backup.parityShardCount
                    : backup.dataShardCount
                if fragmentCount == backup.dataShardCount + backup.parityShardCount,
                   faultDomainCount >= requiredFaultDomains,
                   backup.recoveryRecipientCount >= policy.minimumRecoveryRecipientCount {
                    hasFullyHealthySet = true
                }
                if backup.recoveryRecipientCount < policy.minimumRecoveryRecipientCount {
                    issues.append("recovery_recipient_count_below_policy:\(backup.setID)")
                }
            }

            let status: UserDataRecoveryStatus
            if hasFullyHealthySet {
                status = .healthy
            } else if fullCopies.isEmpty == false || recoverableSetIDs.isEmpty == false {
                status = .degraded
                issues.append("backup_redundancy_below_policy")
            } else {
                status = .unrecoverable
                issues.append("no_current_full_copy_or_reconstructable_backup")
            }
            datasetAssessments.append(UserDataDatasetRecoveryAssessment(
                datasetID: key.datasetID,
                versionID: key.versionID,
                status: status,
                availableFullCopyCount: fullCopies.count,
                availableFragmentCount: bestFragmentCount,
                distinctFragmentFaultDomainCount: bestFaultDomainCount,
                recoverableBackupSetIDs: recoverableSetIDs.sorted(),
                issues: issues.sorted()
            ))
        }

        let metadataUnrecoverable = inventoryReplicas.isEmpty
            || recoveryRootCopyRecords.isEmpty
            || recoveryRootInventoryLocatorCount == 0
        let globalStatus: UserDataRecoveryStatus
        if metadataUnrecoverable || datasetAssessments.contains(where: { $0.status == .unrecoverable }) {
            globalStatus = .unrecoverable
        } else if datasetAssessments.isEmpty {
            globalStatus = .unknown
        } else if globalIssues.isEmpty && datasetAssessments.allSatisfy({ $0.status == .healthy }) {
            globalStatus = .healthy
        } else {
            globalStatus = .degraded
        }
        return UserDataRecoveryAssessment(
            status: globalStatus,
            inventoryReplicaCount: inventoryReplicas.count,
            inventoryFaultDomainCount: inventoryFaultDomains.count,
            recoveryRootCopyCount: recoveryRootCopyRecords.count,
            recoveryRootFaultDomainCount: recoveryRootFaultDomains.count,
            staleRepresentationCount: staleCount,
            datasets: datasetAssessments,
            issues: globalIssues.sorted()
        )
    }
}

public struct UserDataRecoveryLocator: Codable, Equatable, Sendable {
    public var representationID: String
    public var faultDomainID: String
    public var locatorCommitment: String
    public var ownerSealedLocator: Data
    public var storageReceiptHash: String
}

/// Small bootstrap artifact that breaks the recursive metadata-discovery
/// problem. It contains no plaintext route; locators remain owner-sealed.
public struct UserDataRecoveryRoot: Codable, Equatable {
    public static let schema = "haven.user-data-recovery-root.v0"

    public var schema: String
    public var rootGeneration: Int
    public var previousRootHash: String?
    public var inventoryID: String
    public var inventoryRevision: Int
    public var inventorySnapshotHash: String
    public var policyHash: String
    public var inventoryReplicaLocators: [UserDataRecoveryLocator]
    public var ownerIdentityUUID: String
    public var ownerSigningKeyFingerprint: String
    public var createdAtEpochMilliseconds: Int
    public var signature: Data

    public init(
        schema: String = Self.schema,
        rootGeneration: Int,
        previousRootHash: String?,
        inventoryID: String,
        inventoryRevision: Int,
        inventorySnapshotHash: String,
        policyHash: String,
        inventoryReplicaLocators: [UserDataRecoveryLocator],
        ownerIdentityUUID: String,
        ownerSigningKeyFingerprint: String,
        createdAtEpochMilliseconds: Int,
        signature: Data
    ) {
        self.schema = schema
        self.rootGeneration = rootGeneration
        self.previousRootHash = previousRootHash
        self.inventoryID = inventoryID
        self.inventoryRevision = inventoryRevision
        self.inventorySnapshotHash = inventorySnapshotHash
        self.policyHash = policyHash
        self.inventoryReplicaLocators = inventoryReplicaLocators
        self.ownerIdentityUUID = ownerIdentityUUID
        self.ownerSigningKeyFingerprint = ownerSigningKeyFingerprint
        self.createdAtEpochMilliseconds = createdAtEpochMilliseconds
        self.signature = signature
    }

    public static func signed(
        snapshot: UserDataInventorySnapshot,
        previous: UserDataRecoveryRoot?,
        owner: Identity,
        createdAtEpochMilliseconds: Int
    ) async throws -> Self {
        guard snapshot.verifies(owner: owner, atEpochMilliseconds: createdAtEpochMilliseconds),
              let fingerprint = owner.signingPublicKeyFingerprint else {
            throw UserDataResilienceError.invalidRecoveryRoot("inventory_or_owner")
        }
        if let previous {
            guard previous.verifies(owner: owner),
                  previous.inventoryID == snapshot.inventoryID,
                  previous.inventoryRevision <= snapshot.revision,
                  previous.createdAtEpochMilliseconds <= createdAtEpochMilliseconds else {
                throw UserDataResilienceError.invalidRecoveryRoot("previous_binding_or_signature")
            }
        }
        let locators = try snapshot.representations.compactMap { record -> UserDataRecoveryLocator? in
            guard record.kind == .inventoryReplica,
                  (record.state == .available || record.state == .degraded),
                  let grant = record.storageGrant,
                  let receipt = record.storageReceipt,
                  let sealedLocator = record.ownerSealedLocator,
                  (try? record.validate(
                    owner: owner,
                    atEpochMilliseconds: createdAtEpochMilliseconds
                  )) != nil,
                  createdAtEpochMilliseconds - receipt.verifiedAtEpochMilliseconds
                    <= snapshot.policy.maximumVerificationAgeMilliseconds else {
                return nil
            }
            return UserDataRecoveryLocator(
                representationID: record.representationID,
                faultDomainID: grant.faultDomainID,
                locatorCommitment: grant.locatorCommitment,
                ownerSealedLocator: sealedLocator,
                storageReceiptHash: try receipt.canonicalHash()
            )
        }.sorted { $0.representationID < $1.representationID }
        guard locators.isEmpty == false else {
            throw UserDataResilienceError.invalidRecoveryRoot("no_current_inventory_locator")
        }
        var root = Self(
            rootGeneration: (previous?.rootGeneration ?? 0) + 1,
            previousRootHash: try previous?.canonicalHash(),
            inventoryID: snapshot.inventoryID,
            inventoryRevision: snapshot.revision,
            inventorySnapshotHash: try snapshot.canonicalHash(),
            policyHash: try snapshot.policy.canonicalHash(),
            inventoryReplicaLocators: locators,
            ownerIdentityUUID: owner.uuid,
            ownerSigningKeyFingerprint: fingerprint,
            createdAtEpochMilliseconds: createdAtEpochMilliseconds,
            signature: Data()
        )
        try root.validateFields(owner: owner)
        guard let signature = try await owner.sign(data: root.signingData()) else {
            throw UserDataResilienceError.signingUnavailable
        }
        root.signature = signature
        return root
    }

    public func signingData() throws -> Data {
        try UserDataResilienceCanonical.data(for: UnsignedUserDataRecoveryRoot(self))
    }

    public func canonicalHash() throws -> String {
        FlowHasher.sha256Hex(try UserDataResilienceCanonical.data(for: self))
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

    public func verifiesSuccessor(
        of previous: UserDataRecoveryRoot,
        owner: Identity
    ) -> Bool {
        guard verifies(owner: owner),
              previous.verifies(owner: owner),
              inventoryID == previous.inventoryID,
              ownerIdentityUUID == previous.ownerIdentityUUID,
              rootGeneration == previous.rootGeneration + 1,
              previousRootHash == (try? previous.canonicalHash()),
              inventoryRevision >= previous.inventoryRevision,
              createdAtEpochMilliseconds >= previous.createdAtEpochMilliseconds else {
            return false
        }
        return true
    }

    private func validateFields(owner: Identity) throws {
        guard schema == Self.schema else {
            throw UserDataResilienceError.invalidRecoveryRoot("schema")
        }
        try UserDataResilienceCanonical.validateIdentifier(inventoryID)
        guard rootGeneration > 0,
              (rootGeneration == 1) == (previousRootHash == nil),
              previousRootHash == nil || UserDataResilienceCanonical.isSHA256Hex(previousRootHash!),
              inventoryRevision > 0,
              UserDataResilienceCanonical.isSHA256Hex(inventorySnapshotHash),
              UserDataResilienceCanonical.isSHA256Hex(policyHash),
              owner.uuid == ownerIdentityUUID,
              owner.signingPublicKeyFingerprint == ownerSigningKeyFingerprint,
              createdAtEpochMilliseconds >= 0,
              inventoryReplicaLocators == inventoryReplicaLocators.sorted(by: { $0.representationID < $1.representationID }),
              Set(inventoryReplicaLocators.map(\.representationID)).count == inventoryReplicaLocators.count else {
            throw UserDataResilienceError.invalidRecoveryRoot("binding_or_canonical_order")
        }
        for locator in inventoryReplicaLocators {
            try [locator.representationID, locator.faultDomainID]
                .forEach(UserDataResilienceCanonical.validateIdentifier)
            guard locator.ownerSealedLocator.isEmpty == false,
                  locator.locatorCommitment == FlowHasher.sha256Hex(locator.ownerSealedLocator),
                  UserDataResilienceCanonical.isSHA256Hex(locator.storageReceiptHash) else {
                throw UserDataResilienceError.invalidRecoveryRoot("locator")
            }
        }
    }
}

private struct UserDataDatasetKey: Hashable {
    var datasetID: String
    var versionID: String
}

private struct UnsignedUserDataStorageGrant: Codable {
    var schema: String
    var grantID: String
    var inventoryID: String
    var datasetID: String
    var versionID: String
    var representationID: String
    var representationKind: UserDataRepresentationKind
    var contentHash: String
    var byteCount: Int
    var faultDomainID: String
    var locatorCommitment: String
    var custodianIdentity: IdentityPublicKeyDescriptor
    var custodianSigningKeyFingerprint: String
    var capability: String
    var ownerIdentityUUID: String
    var ownerSigningKeyFingerprint: String
    var issuedAtEpochMilliseconds: Int
    var expiresAtEpochMilliseconds: Int

    init(_ grant: UserDataStorageGrant) {
        schema = grant.schema
        grantID = grant.grantID
        inventoryID = grant.inventoryID
        datasetID = grant.datasetID
        versionID = grant.versionID
        representationID = grant.representationID
        representationKind = grant.representationKind
        contentHash = grant.contentHash
        byteCount = grant.byteCount
        faultDomainID = grant.faultDomainID
        locatorCommitment = grant.locatorCommitment
        custodianIdentity = grant.custodianIdentity
        custodianSigningKeyFingerprint = grant.custodianSigningKeyFingerprint
        capability = grant.capability
        ownerIdentityUUID = grant.ownerIdentityUUID
        ownerSigningKeyFingerprint = grant.ownerSigningKeyFingerprint
        issuedAtEpochMilliseconds = grant.issuedAtEpochMilliseconds
        expiresAtEpochMilliseconds = grant.expiresAtEpochMilliseconds
    }
}

private struct UnsignedUserDataStorageReceipt: Codable {
    var schema: String
    var receiptID: String
    var status: String
    var grantHash: String
    var representationID: String
    var contentHash: String
    var byteCount: Int
    var custodianIdentityUUID: String
    var custodianSigningKeyFingerprint: String
    var durabilityLevel: EntityAuthorityReplicaDurabilityLevel
    var storedAtEpochMilliseconds: Int
    var verifiedAtEpochMilliseconds: Int
    var verificationKind: UserDataVerificationKind
    var verificationProofHash: String

    init(_ receipt: UserDataStorageReceipt) {
        schema = receipt.schema
        receiptID = receipt.receiptID
        status = receipt.status
        grantHash = receipt.grantHash
        representationID = receipt.representationID
        contentHash = receipt.contentHash
        byteCount = receipt.byteCount
        custodianIdentityUUID = receipt.custodianIdentityUUID
        custodianSigningKeyFingerprint = receipt.custodianSigningKeyFingerprint
        durabilityLevel = receipt.durabilityLevel
        storedAtEpochMilliseconds = receipt.storedAtEpochMilliseconds
        verifiedAtEpochMilliseconds = receipt.verifiedAtEpochMilliseconds
        verificationKind = receipt.verificationKind
        verificationProofHash = receipt.verificationProofHash
    }
}

private struct UnsignedUserDataInventorySnapshot: Codable {
    var schema: String
    var inventoryID: String
    var revision: Int
    var previousSnapshotHash: String?
    var ownerIdentityUUID: String
    var ownerSigningKeyFingerprint: String
    var policy: UserDataResiliencePolicy
    var representations: [UserDataRepresentationRecord]
    var backupSets: [UserDataBackupSetRecord]
    var createdAtEpochMilliseconds: Int

    init(_ snapshot: UserDataInventorySnapshot) {
        schema = snapshot.schema
        inventoryID = snapshot.inventoryID
        revision = snapshot.revision
        previousSnapshotHash = snapshot.previousSnapshotHash
        ownerIdentityUUID = snapshot.ownerIdentityUUID
        ownerSigningKeyFingerprint = snapshot.ownerSigningKeyFingerprint
        policy = snapshot.policy
        representations = snapshot.representations
        backupSets = snapshot.backupSets
        createdAtEpochMilliseconds = snapshot.createdAtEpochMilliseconds
    }
}

private struct UnsignedUserDataRecoveryRoot: Codable {
    var schema: String
    var rootGeneration: Int
    var previousRootHash: String?
    var inventoryID: String
    var inventoryRevision: Int
    var inventorySnapshotHash: String
    var policyHash: String
    var inventoryReplicaLocators: [UserDataRecoveryLocator]
    var ownerIdentityUUID: String
    var ownerSigningKeyFingerprint: String
    var createdAtEpochMilliseconds: Int

    init(_ root: UserDataRecoveryRoot) {
        schema = root.schema
        rootGeneration = root.rootGeneration
        previousRootHash = root.previousRootHash
        inventoryID = root.inventoryID
        inventoryRevision = root.inventoryRevision
        inventorySnapshotHash = root.inventorySnapshotHash
        policyHash = root.policyHash
        inventoryReplicaLocators = root.inventoryReplicaLocators
        ownerIdentityUUID = root.ownerIdentityUUID
        ownerSigningKeyFingerprint = root.ownerSigningKeyFingerprint
        createdAtEpochMilliseconds = root.createdAtEpochMilliseconds
    }
}

private extension IdentityPublicKeyDescriptor {
    var userDataSigningKeyFingerprint: String {
        [algorithm.rawValue, curveType.rawValue, publicKey.base64EncodedString()]
            .joined(separator: ":")
    }
}

private enum UserDataResilienceCanonical {
    static func data<T: Encodable>(for value: T) throws -> Data {
        try EntityAuthorityCanonical.data(for: value)
    }

    static func valueType<T: Encodable>(_ value: T) throws -> ValueType {
        try EntityAuthorityCanonical.valueType(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: ValueType) throws -> T {
        try EntityAuthorityCanonical.decode(type, from: value)
    }

    static func validateIdentifier(_ identifier: String) throws {
        guard identifier.isEmpty == false,
              identifier.utf8.count <= 256,
              identifier.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics
                      .union(CharacterSet(charactersIn: "-_.:"))
                      .contains($0)
              }) else {
            throw UserDataResilienceError.invalidIdentifier(identifier)
        }
    }

    static func isSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }
}
