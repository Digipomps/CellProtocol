// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import XCTest
@testable import CellBase

final class UserDataResilienceTests: XCTestCase {
    func testErasureDescriptorMatchesCrossRuntimeGoldenFixture() throws {
        let encoded = try UserDataErasureCoding.encode(
            encryptedPayload: Data("HAVEN user data erasure fixture v0".utf8)
        )
        let fixtureData = TestFixtures.loadJSON(named: "UserDataErasureSetDescriptor.v0.json")
        let fixture = try JSONDecoder().decode(
            UserDataErasureSetDescriptor.self,
            from: fixtureData
        )
        XCTAssertEqual(encoded.descriptor, fixture)
        XCTAssertNoThrow(try fixture.validate())
    }

    func testFourPlusTwoReconstructsFromEveryFourFragmentCombination() throws {
        let payload = Data((0..<1_037).map { UInt8(($0 * 31) % 251) })
        let encoded = try UserDataErasureCoding.encode(encryptedPayload: payload)

        XCTAssertEqual(encoded.fragments.count, 6)
        XCTAssertEqual(encoded.descriptor.dataShardCount, 4)
        XCTAssertEqual(encoded.descriptor.parityShardCount, 2)
        XCTAssertEqual(combinations(of: Array(0..<6), taking: 4).count, 15)

        for indexes in combinations(of: Array(0..<6), taking: 4) {
            let selected = indexes.map { encoded.fragments[$0] }
            XCTAssertEqual(
                try UserDataErasureCoding.reconstruct(
                    fragments: selected,
                    descriptor: encoded.descriptor
                ),
                payload,
                "Failed reconstruction from fragment indexes \(indexes)"
            )
        }
    }

    func testErasureCodingRejectsCorruptionDuplicatesAndInsufficientFragments() throws {
        let payload = Data("ciphertext-like-test-payload".utf8)
        let encoded = try UserDataErasureCoding.encode(encryptedPayload: payload)

        var corrupted = encoded.fragments[0]
        corrupted.bytes[corrupted.bytes.startIndex] ^= 0xFF
        XCTAssertThrowsError(try UserDataErasureCoding.reconstruct(
            fragments: [corrupted] + Array(encoded.fragments[1...3]),
            descriptor: encoded.descriptor
        )) { error in
            XCTAssertEqual(error as? UserDataErasureCodingError, .corruptFragment(0))
        }

        XCTAssertThrowsError(try UserDataErasureCoding.reconstruct(
            fragments: [encoded.fragments[0], encoded.fragments[0], encoded.fragments[1], encoded.fragments[2]],
            descriptor: encoded.descriptor
        )) { error in
            XCTAssertEqual(error as? UserDataErasureCodingError, .duplicateFragment(0))
        }

        XCTAssertThrowsError(try UserDataErasureCoding.reconstruct(
            fragments: Array(encoded.fragments.prefix(3)),
            descriptor: encoded.descriptor
        )) { error in
            XCTAssertEqual(
                error as? UserDataErasureCodingError,
                .insufficientFragments(required: 4, actual: 3)
            )
        }

        let repaired = try UserDataErasureCoding.repair(
            fragments: [encoded.fragments[0], encoded.fragments[2], encoded.fragments[4], encoded.fragments[5]],
            descriptor: encoded.descriptor
        )
        XCTAssertEqual(repaired, encoded)
    }

    func testBackupEncryptsBeforeErasureCodingAndEitherRecoveryIdentityCanRestore() async throws {
        let vault = UserDataTestIdentityVault()
        let owner = try await identity(named: "owner", in: vault)
        let recovery = try await identity(named: "recovery", in: vault)
        let stranger = try await identity(named: "stranger", in: vault)
        let plaintext = Data("private user bytes that must survive loss".utf8)

        let package = try await UserOwnedBackupCodec.seal(
            plaintext: plaintext,
            inventoryID: "inventory-primary",
            datasetID: "dataset-profile",
            versionID: "version-7",
            owner: owner,
            recoveryRecipients: [owner, recovery],
            provider: vault,
            createdAtEpochMilliseconds: 1_000
        )

        XCTAssertTrue(package.manifest.verifies(owner: owner))
        XCTAssertEqual(package.manifest.recoveryRecipientKeyCommitments.count, 2)
        let secondPackage = try await UserOwnedBackupCodec.seal(
            plaintext: plaintext,
            inventoryID: "inventory-primary",
            datasetID: "dataset-profile",
            versionID: "version-8",
            owner: owner,
            recoveryRecipients: [owner, recovery],
            provider: vault,
            createdAtEpochMilliseconds: 1_001
        )
        XCTAssertNotEqual(
            package.manifest.recoveryRecipientKeyCommitments,
            secondPackage.manifest.recoveryRecipientKeyCommitments,
            "Opaque key identifiers must not link separate backup envelopes"
        )
        let selected = [0, 2, 4, 5].map { package.fragments[$0] }
        let recoveredByRecoveryIdentity = try await UserOwnedBackupCodec.recover(
            fragments: selected,
            manifest: package.manifest,
            recipient: recovery,
            owner: owner,
            provider: vault
        )
        let recoveredByOwner = try await UserOwnedBackupCodec.recover(
            fragments: selected,
            manifest: package.manifest,
            recipient: owner,
            owner: owner,
            provider: vault
        )
        XCTAssertEqual(recoveredByRecoveryIdentity, plaintext)
        XCTAssertEqual(recoveredByOwner, plaintext)

        let envelopeData = try UserDataErasureCoding.reconstruct(
            fragments: selected,
            descriptor: package.manifest.erasureSet
        )
        let envelopeJSON = try XCTUnwrap(String(data: envelopeData, encoding: .utf8))
        XCTAssertFalse(envelopeJSON.contains(owner.uuid))
        XCTAssertFalse(envelopeJSON.contains(recovery.uuid))
        XCTAssertTrue(envelopeJSON.contains("opaque-key-"))

        do {
            _ = try await UserOwnedBackupCodec.recover(
                fragments: selected,
                manifest: package.manifest,
                recipient: stranger,
                owner: owner,
                provider: vault
            )
            XCTFail("An identity without a wrapped recovery key must not decrypt the backup")
        } catch {
            XCTAssertTrue(error is ContentCryptoEnvelopeError)
        }

        var tamperedManifest = package.manifest
        tamperedManifest.datasetID = "dataset-attacker"
        XCTAssertFalse(tamperedManifest.verifies(owner: owner))
    }

    func testStorageEvidenceIsOwnerGrantedCustodianSignedAndTimeBound() async throws {
        let vault = UserDataTestIdentityVault()
        let owner = try await identity(named: "owner", in: vault)
        let custodian = try await identity(named: "custodian", in: vault)
        let impostor = try await identity(named: "impostor", in: vault)
        let locatorPlaintext = Data("custodian://private-route/object-1".utf8)
        let locator = try await UserDataOwnerSealedLocatorCodec.seal(
            locator: locatorPlaintext,
            inventoryID: "inventory-primary",
            representationID: "representation-object-1",
            owner: owner,
            recoveryRecipients: [owner],
            provider: vault
        )
        let contentHash = FlowHasher.sha256Hex(Data("fragment".utf8))
        let grant = try await UserDataStorageGrant.signed(
            grantID: "grant-object-1",
            inventoryID: "inventory-primary",
            datasetID: "dataset-profile",
            versionID: "version-7",
            representationID: "representation-object-1",
            representationKind: .backupFragment,
            contentHash: contentHash,
            byteCount: 8,
            faultDomainID: "provider-a.region-1.disk-1",
            ownerSealedLocator: locator,
            custodian: custodian,
            owner: owner,
            issuedAtEpochMilliseconds: 100,
            expiresAtEpochMilliseconds: 1_000
        )
        let receipt = try await UserDataStorageReceipt.signed(
            grant: grant,
            custodian: custodian,
            durabilityLevel: .fsyncFileAndParentDirectory,
            storedAtEpochMilliseconds: 120,
            verifiedAtEpochMilliseconds: 150,
            verificationKind: .fullRestore,
            verificationProofHash: contentHash
        )

        XCTAssertTrue(grant.verifies(owner: owner, atEpochMilliseconds: 500))
        XCTAssertFalse(grant.verifies(owner: owner, atEpochMilliseconds: 1_001))
        XCTAssertTrue(receipt.verifies(grant: grant, atEpochMilliseconds: 500))
        XCTAssertFalse(receipt.verifies(grant: grant, atEpochMilliseconds: 1_001))
        let openedLocator = try await UserDataOwnerSealedLocatorCodec.open(
            sealedLocator: locator,
            inventoryID: "inventory-primary",
            representationID: "representation-object-1",
            recipient: owner,
            owner: owner,
            provider: vault
        )
        XCTAssertEqual(openedLocator, locatorPlaintext)
        XCTAssertFalse(String(data: locator, encoding: .utf8)?.contains("custodian://private-route") ?? true)
        XCTAssertFalse(UserDataOwnerSealedLocatorCodec.validates(
            sealedLocator: locator,
            inventoryID: "inventory-primary",
            representationID: "representation-rebound",
            owner: owner
        ))

        do {
            _ = try await UserDataStorageGrant.signed(
                grantID: "grant-plaintext-locator",
                inventoryID: "inventory-primary",
                datasetID: "dataset-profile",
                versionID: "version-7",
                representationID: "representation-plaintext-locator",
                representationKind: .canonical,
                contentHash: contentHash,
                byteCount: 8,
                faultDomainID: "provider-a.region-1.disk-1",
                ownerSealedLocator: locatorPlaintext,
                custodian: custodian,
                owner: owner,
                issuedAtEpochMilliseconds: 100,
                expiresAtEpochMilliseconds: 1_000
            )
            XCTFail("Plaintext locator bytes must be rejected")
        } catch let error as UserDataResilienceError {
            XCTAssertEqual(error, .invalidGrant("owner_sealed_locator"))
        }

        var tamperedReceipt = receipt
        tamperedReceipt.byteCount += 1
        XCTAssertFalse(tamperedReceipt.verifies(grant: grant, atEpochMilliseconds: 500))

        do {
            _ = try await UserDataStorageReceipt.signed(
                grant: grant,
                custodian: impostor,
                durabilityLevel: .fsyncFileAndParentDirectory,
                storedAtEpochMilliseconds: 120,
                verifiedAtEpochMilliseconds: 150,
                verificationKind: .fullRestore,
                verificationProofHash: contentHash
            )
            XCTFail("Only the owner-admitted custodian may issue the receipt")
        } catch let error as UserDataResilienceError {
            XCTAssertEqual(error, .invalidReceipt("custodian_or_durability"))
        }
    }

    func testInventoryChainRemainsVerifiableAfterGrantExpiryButLiveAssessmentDoesNot() async throws {
        let vault = UserDataTestIdentityVault()
        let owner = try await identity(named: "owner", in: vault)
        let custodian = try await identity(named: "custodian", in: vault)
        let record = try await storedRepresentation(
            id: "representation-canonical",
            datasetID: "dataset-profile",
            versionID: "version-1",
            kind: .canonical,
            contentHash: FlowHasher.sha256Hex(Data("canonical".utf8)),
            byteCount: 9,
            faultDomainID: "home-device",
            owner: owner,
            custodian: custodian,
            expiresAt: 1_000
        )
        let first = try await UserDataInventorySnapshot.signed(
            inventoryID: "inventory-primary",
            previous: nil,
            policy: UserDataResiliencePolicy(),
            representations: [record],
            backupSets: [],
            owner: owner,
            createdAtEpochMilliseconds: 300
        )
        let second = try await UserDataInventorySnapshot.signed(
            inventoryID: "inventory-primary",
            previous: first,
            policy: first.policy,
            representations: [record],
            backupSets: [],
            owner: owner,
            createdAtEpochMilliseconds: 400
        )

        XCTAssertTrue(first.verifies(owner: owner, atEpochMilliseconds: 2_000))
        XCTAssertTrue(second.verifiesSuccessor(
            of: first,
            owner: owner,
            atEpochMilliseconds: 2_000
        ))
        let assessment = try UserDataRecoveryEvaluator.assess(
            snapshot: second,
            owner: owner,
            atEpochMilliseconds: 2_000
        )
        XCTAssertEqual(assessment.status, .unrecoverable)
        XCTAssertEqual(assessment.staleRepresentationCount, 1)

        var tampered = second
        tampered.representations[0].contentHash = FlowHasher.sha256Hex(Data("tampered".utf8))
        XCTAssertFalse(tampered.verifies(owner: owner, atEpochMilliseconds: 2_000))

        let wire = try second.valueType()
        XCTAssertEqual(try UserDataInventorySnapshot(value: wire), second)
    }

    func testRecoveryAssessmentAndRootSurviveLossOfHomeScaffold() async throws {
        let vault = UserDataTestIdentityVault()
        let owner = try await identity(named: "owner", in: vault)
        let recovery = try await identity(named: "recovery", in: vault)
        let backup = try await UserOwnedBackupCodec.seal(
            plaintext: Data("restorable user state".utf8),
            inventoryID: "inventory-primary",
            datasetID: "dataset-profile",
            versionID: "version-9",
            owner: owner,
            recoveryRecipients: [owner, recovery],
            provider: vault,
            createdAtEpochMilliseconds: 100
        )

        var representations: [UserDataRepresentationRecord] = []
        for index in 0..<3 {
            let custodian = try await identity(named: "inventory-custodian-\(index)", in: vault)
            representations.append(try await storedRepresentation(
                id: "inventory-replica-\(index)",
                datasetID: "inventory-metadata",
                versionID: "revision-1",
                kind: .inventoryReplica,
                contentHash: FlowHasher.sha256Hex(Data("inventory-snapshot".utf8)),
                byteCount: 1_024,
                faultDomainID: "inventory-domain-\(index)",
                owner: owner,
                custodian: custodian
            ))
        }
        for fragment in backup.fragments {
            let custodian = try await identity(named: "fragment-custodian-\(fragment.index)", in: vault)
            representations.append(try await storedRepresentation(
                id: "backup-fragment-\(fragment.index)",
                datasetID: backup.manifest.datasetID,
                versionID: backup.manifest.versionID,
                kind: .backupFragment,
                contentHash: fragment.fragmentHash,
                byteCount: fragment.bytes.count,
                faultDomainID: "fragment-domain-\(fragment.index)",
                owner: owner,
                custodian: custodian,
                backupFragment: UserDataBackupFragmentPlacement(
                    setID: backup.manifest.backupSetID,
                    fragmentIndex: fragment.index,
                    dataShardCount: 4,
                    parityShardCount: 2
                )
            ))
        }
        let snapshot = try await UserDataInventorySnapshot.signed(
            inventoryID: "inventory-primary",
            previous: nil,
            policy: UserDataResiliencePolicy(maximumVerificationAgeMilliseconds: 10_000),
            representations: representations,
            backupSets: [try backup.manifest.backupSetRecord()],
            owner: owner,
            createdAtEpochMilliseconds: 300
        )
        let root = try await UserDataRecoveryRoot.signed(
            snapshot: snapshot,
            previous: nil,
            owner: owner,
            createdAtEpochMilliseconds: 350
        )
        let rootCopies = try await recoveryRootCopies(
            for: root,
            owner: owner,
            vault: vault
        )

        let healthy = try UserDataRecoveryEvaluator.assess(
            snapshot: snapshot,
            owner: owner,
            atEpochMilliseconds: 500,
            recoveryRoot: root,
            recoveryRootCopies: rootCopies
        )
        XCTAssertEqual(healthy.status, .healthy)
        XCTAssertEqual(healthy.inventoryReplicaCount, 3)
        XCTAssertEqual(healthy.inventoryFaultDomainCount, 3)
        XCTAssertEqual(healthy.recoveryRootCopyCount, 2)
        XCTAssertEqual(healthy.recoveryRootFaultDomainCount, 2)
        XCTAssertEqual(healthy.datasets.map(\.status), [.healthy])
        XCTAssertTrue(root.verifies(owner: owner))
        XCTAssertEqual(root.inventoryReplicaLocators.count, 3)
        XCTAssertEqual(root.inventorySnapshotHash, try snapshot.canonicalHash())

        let missingBootstrap = try UserDataRecoveryEvaluator.assess(
            snapshot: snapshot,
            owner: owner,
            atEpochMilliseconds: 500
        )
        XCTAssertEqual(missingBootstrap.status, .unrecoverable)
        XCTAssertTrue(missingBootstrap.issues.contains("current_recovery_root_missing_or_invalid"))

        let singleRootCopy = try UserDataRecoveryEvaluator.assess(
            snapshot: snapshot,
            owner: owner,
            atEpochMilliseconds: 500,
            recoveryRoot: root,
            recoveryRootCopies: [rootCopies[0]]
        )
        XCTAssertEqual(singleRootCopy.status, .degraded)
        XCTAssertEqual(singleRootCopy.recoveryRootCopyCount, 1)

        let degradedRecords = representations.filter {
            $0.representationID != "backup-fragment-4"
                && $0.representationID != "backup-fragment-5"
        }
        let degradedSnapshot = try await UserDataInventorySnapshot.signed(
            inventoryID: "inventory-primary",
            previous: snapshot,
            policy: snapshot.policy,
            representations: degradedRecords,
            backupSets: snapshot.backupSets,
            owner: owner,
            createdAtEpochMilliseconds: 400
        )
        let degradedRoot = try await UserDataRecoveryRoot.signed(
            snapshot: degradedSnapshot,
            previous: root,
            owner: owner,
            createdAtEpochMilliseconds: 425
        )
        XCTAssertTrue(degradedRoot.verifiesSuccessor(of: root, owner: owner))
        let degradedRootCopies = try await recoveryRootCopies(
            for: degradedRoot,
            owner: owner,
            vault: vault
        )
        let degraded = try UserDataRecoveryEvaluator.assess(
            snapshot: degradedSnapshot,
            owner: owner,
            atEpochMilliseconds: 500,
            recoveryRoot: degradedRoot,
            recoveryRootCopies: degradedRootCopies
        )
        XCTAssertEqual(degraded.status, .degraded)
        XCTAssertEqual(degraded.datasets.first?.availableFragmentCount, 4)
        XCTAssertEqual(degraded.datasets.first?.recoverableBackupSetIDs, [backup.manifest.backupSetID])

        let unrecoverableRecords = degradedRecords.filter {
            $0.representationID != "backup-fragment-3"
        }
        let unrecoverableSnapshot = try await UserDataInventorySnapshot.signed(
            inventoryID: "inventory-primary",
            previous: degradedSnapshot,
            policy: snapshot.policy,
            representations: unrecoverableRecords,
            backupSets: snapshot.backupSets,
            owner: owner,
            createdAtEpochMilliseconds: 450
        )
        let unrecoverableRoot = try await UserDataRecoveryRoot.signed(
            snapshot: unrecoverableSnapshot,
            previous: degradedRoot,
            owner: owner,
            createdAtEpochMilliseconds: 475
        )
        let unrecoverableRootCopies = try await recoveryRootCopies(
            for: unrecoverableRoot,
            owner: owner,
            vault: vault
        )
        let unrecoverable = try UserDataRecoveryEvaluator.assess(
            snapshot: unrecoverableSnapshot,
            owner: owner,
            atEpochMilliseconds: 500,
            recoveryRoot: unrecoverableRoot,
            recoveryRootCopies: unrecoverableRootCopies
        )
        XCTAssertEqual(unrecoverable.status, .unrecoverable)
        XCTAssertEqual(unrecoverable.datasets.first?.availableFragmentCount, 3)
    }

    private func recoveryRootCopies(
        for root: UserDataRecoveryRoot,
        owner: Identity,
        vault: UserDataTestIdentityVault
    ) async throws -> [UserDataRepresentationRecord] {
        let rootHash = try root.canonicalHash()
        var copies: [UserDataRepresentationRecord] = []
        for index in 0..<2 {
            let custodian = try await identity(named: "root-\(root.rootGeneration)-custodian-\(index)", in: vault)
            copies.append(try await storedRepresentation(
                id: "recovery-root-\(root.rootGeneration)-copy-\(index)",
                datasetID: root.inventoryID,
                versionID: "root-\(root.rootGeneration)",
                kind: .recoveryRoot,
                contentHash: rootHash,
                byteCount: try JSONEncoder().encode(root).count,
                faultDomainID: "recovery-root-domain-\(index)",
                owner: owner,
                custodian: custodian
            ))
        }
        return copies
    }

    func testInventorySnapshotCommitsAndReplaysThroughEntityAuthorityJournal() async throws {
        let vault = UserDataTestIdentityVault()
        let owner = try await identity(named: "owner", in: vault)
        let snapshot = try await UserDataInventorySnapshot.signed(
            inventoryID: "inventory-primary",
            previous: nil,
            policy: UserDataResiliencePolicy(),
            representations: [],
            backupSets: [],
            owner: owner,
            createdAtEpochMilliseconds: 100
        )
        let base: Entity = ["dataInventory": .object([:])]
        var envelope = EntityBatchPersistEnvelope(
            schema: "haven.entity-turn.v1",
            mutations: [EntityBatchPersistMutation(
                keypath: "dataInventory",
                value: try snapshot.valueType()
            )]
        )
        envelope.commitRequest = try await EntityAuthorityCommitRequest.signed(
            envelope: envelope,
            mutationID: "inventory-snapshot-1",
            epoch: 1,
            expectedRevision: 0,
            expectedPreviousHash: nil,
            requester: owner,
            purposeRef: "purpose://data.resilience"
        )
        let committed = try await EntityAuthorityJournalDocument().appending(
            envelope: envelope,
            to: base,
            requester: owner,
            authority: owner,
            authorityCellUUID: "entity-anchor-inventory-test",
            committedAtEpochMilliseconds: 200
        )

        let rebuilt = try committed.journal.replay(on: base)
        let restoredValue = try rebuilt.get(keypath: "dataInventory")
        let restoredSnapshot = try UserDataInventorySnapshot(value: restoredValue)
        XCTAssertEqual(restoredSnapshot, snapshot)
        XCTAssertTrue(restoredSnapshot.verifies(owner: owner, atEpochMilliseconds: 500))
        XCTAssertTrue(try committed.journal.verifyReceipts(authority: owner))
    }

    private func storedRepresentation(
        id: String,
        datasetID: String,
        versionID: String,
        kind: UserDataRepresentationKind,
        contentHash: String,
        byteCount: Int,
        faultDomainID: String,
        owner: Identity,
        custodian: Identity,
        backupFragment: UserDataBackupFragmentPlacement? = nil,
        expiresAt: Int = 10_000
    ) async throws -> UserDataRepresentationRecord {
        guard let provider = owner.identityVault as? IdentityKeyRoleProviderProtocol else {
            throw UserOwnedBackupError.signingUnavailable
        }
        let locator = try await UserDataOwnerSealedLocatorCodec.seal(
            locator: Data("custodian://private-route/\(id)".utf8),
            inventoryID: "inventory-primary",
            representationID: id,
            owner: owner,
            recoveryRecipients: [owner],
            provider: provider
        )
        let grant = try await UserDataStorageGrant.signed(
            grantID: "grant-\(id)",
            inventoryID: "inventory-primary",
            datasetID: datasetID,
            versionID: versionID,
            representationID: id,
            representationKind: kind,
            contentHash: contentHash,
            byteCount: byteCount,
            faultDomainID: faultDomainID,
            ownerSealedLocator: locator,
            custodian: custodian,
            owner: owner,
            issuedAtEpochMilliseconds: 100,
            expiresAtEpochMilliseconds: expiresAt
        )
        let receipt = try await UserDataStorageReceipt.signed(
            grant: grant,
            custodian: custodian,
            durabilityLevel: .fsyncFileAndParentDirectory,
            storedAtEpochMilliseconds: 150,
            verifiedAtEpochMilliseconds: 200,
            verificationKind: .fullRestore,
            verificationProofHash: contentHash
        )
        return UserDataRepresentationRecord(
            representationID: id,
            datasetID: datasetID,
            versionID: versionID,
            kind: kind,
            state: .available,
            contentHash: contentHash,
            byteCount: byteCount,
            ownerSealedLocator: locator,
            storageGrant: grant,
            storageReceipt: receipt,
            backupFragment: backupFragment,
            createdAtEpochMilliseconds: 100,
            updatedAtEpochMilliseconds: 200
        )
    }

    private func identity(
        named name: String,
        in vault: UserDataTestIdentityVault
    ) async throws -> Identity {
        let candidate = await vault.identity(for: name, makeNewIfNotFound: true)
        return try XCTUnwrap(candidate)
    }

    private func combinations<T>(of values: [T], taking count: Int) -> [[T]] {
        guard count > 0 else { return [[]] }
        guard values.count >= count else { return [] }
        if values.count == count { return [values] }
        let first = values[0]
        let remainder = Array(values.dropFirst())
        return combinations(of: remainder, taking: count - 1).map { [first] + $0 }
            + combinations(of: remainder, taking: count)
    }
}

private actor UserDataTestIdentityVault: IdentityVaultProtocol, IdentityKeyRoleProviderProtocol {
    private var identitiesByContext: [String: Identity] = [:]
    private var signingKeysByIdentityUUID: [String: Curve25519.Signing.PrivateKey] = [:]
    private var keyAgreementKeysByIdentityUUID: [String: Curve25519.KeyAgreement.PrivateKey] = [:]
    private var idCounter = 1

    func identityVaultReference() async -> String? { "test-vault://user-data-resilience" }

    func initialize() async -> IdentityVaultProtocol { self }

    func addIdentity(identity: inout Identity, for identityContext: String) async {
        identity.identityVault = self
        identitiesByContext[identityContext] = identity
    }

    func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity? {
        if let existing = identitiesByContext[identityContext] { return existing }
        guard makeNewIfNotFound else { return nil }

        let suffix = String(format: "%012d", idCounter)
        idCounter += 1
        let uuid = "10000000-0000-0000-0000-\(suffix)"
        let signingKey = Curve25519.Signing.PrivateKey()
        let keyAgreementKey = Curve25519.KeyAgreement.PrivateKey()
        let identity = Identity(uuid, displayName: identityContext, identityVault: self)
        identity.publicSecureKey = SecureKey(
            date: Date(),
            privateKey: false,
            use: .signature,
            algorithm: .EdDSA,
            size: 256,
            curveType: .Curve25519,
            x: nil,
            y: nil,
            compressedKey: signingKey.publicKey.rawRepresentation
        )
        identity.publicKeyAgreementSecureKey = SecureKey(
            date: Date(),
            privateKey: false,
            use: .keyAgreement,
            algorithm: .X25519,
            size: 256,
            curveType: .Curve25519,
            x: nil,
            y: nil,
            compressedKey: keyAgreementKey.publicKey.rawRepresentation
        )
        signingKeysByIdentityUUID[uuid] = signingKey
        keyAgreementKeysByIdentityUUID[uuid] = keyAgreementKey
        identitiesByContext[identityContext] = identity
        return identity
    }

    func identity(forUUID uuid: String) async -> Identity? {
        identitiesByContext.values.first { $0.uuid == uuid }
    }

    func identityExistInVault(_ identity: Identity) async -> Bool {
        identitiesByContext.values.contains { $0.uuid == identity.uuid }
    }

    func identityDomainBinding(for identity: Identity) async -> IdentityDomainBinding? {
        _ = identity
        return nil
    }

    func saveIdentity(_ identity: Identity) async {
        identitiesByContext[identity.displayName] = identity
    }

    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        guard let key = signingKeysByIdentityUUID[identity.uuid] else {
            throw IdentityVaultError.signingFailed
        }
        return try key.signature(for: messageData)
    }

    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool {
        guard let compressedKey = identity.publicSecureKey?.compressedKey else { return false }
        return try Curve25519.Signing.PublicKey(rawRepresentation: compressedKey)
            .isValidSignature(signature, for: messageData)
    }

    func randomBytes64() async -> Data? { Data(repeating: 0xA5, count: 64) }

    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) {
        ("user-data-test-key-\(tag)", "user-data-test-iv-\(tag)")
    }

    func publicSecureKey(for identity: Identity, role: IdentityKeyRole) async throws -> SecureKey? {
        switch role {
        case .signing: return identity.publicSecureKey
        case .keyAgreement: return identity.publicKeyAgreementSecureKey
        }
    }

    func privateKeyData(for identity: Identity, role: IdentityKeyRole) async throws -> Data? {
        switch role {
        case .signing: return signingKeysByIdentityUUID[identity.uuid]?.rawRepresentation
        case .keyAgreement: return keyAgreementKeysByIdentityUUID[identity.uuid]?.rawRepresentation
        }
    }
}
