// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase
@_spi(Testing) @testable import CellVapor
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class VaporIdentityVaultStrictTests: XCTestCase {
    private var previousDocumentRootPath: String?
    private var roots: [URL] = []

    override func setUp() {
        super.setUp()
        previousDocumentRootPath = CellBase.documentRootPath
    }

    override func tearDown() {
        CellBase.documentRootPath = previousDocumentRootPath
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots.removeAll()
        super.tearDown()
    }

    func testMissingVaultInspectionIsCompletelyWriteFreeAndGeneratesNoKeys() async throws {
        await VaporIdentityVault.shared.resetStrictRuntimeModeForTesting()
        let parent = try makeTemporaryDirectory(label: "missing-parent")
        let missingRoot = parent.appendingPathComponent("does-not-exist", isDirectory: true)
        CellBase.documentRootPath = missingRoot.path

        let request = request(uuid: "service-a", context: "domain:service:a")
        let inspection = try await VaporIdentityVault.shared.inspectProvisioning([request])

        XCTAssertEqual(inspection.revision, .missing)
        XCTAssertEqual(inspection.items.map(\.action), [.create])
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingRoot.path))
    }

    func testStrictLoadRequireAndInspectionDoNotRewriteVaultOrMasterKey() async throws {
        let root = try await preparedVaultRoot(label: "read-only")
        let request = request(uuid: "service-read-only", context: "domain:service:read-only")
        let firstInspection = try await VaporIdentityVault.shared.inspectProvisioning([request])
        _ = try await VaporIdentityVault.shared.provisionIdentities(
            [request],
            expectedRevision: firstInspection.revision
        )
        let vaultURL = vaultURL(in: root)
        let keyURL = masterKeyURL(in: root)
        try setPermissions(0o400, at: keyURL)
        let vaultBytes = try Data(contentsOf: vaultURL)
        let keyBytes = try Data(contentsOf: keyURL)
        let vaultModificationDate = try modificationDate(vaultURL)
        let keyModificationDate = try modificationDate(keyURL)

        let loaded = try await VaporIdentityVault.shared.loadStrict()
        let required = try await VaporIdentityVault.shared.requireIdentity(
            expectedUUID: request.uuid,
            for: request.context
        )
        let secondInspection = try await VaporIdentityVault.shared.inspectProvisioning([request])

        XCTAssertEqual(loaded.revision, secondInspection.revision)
        XCTAssertEqual(secondInspection.items.map(\.action), [.keep])
        XCTAssertEqual(required.uuid, request.uuid)
        XCTAssertEqual(try Data(contentsOf: vaultURL), vaultBytes)
        XCTAssertEqual(try Data(contentsOf: keyURL), keyBytes)
        XCTAssertEqual(try modificationDate(vaultURL), vaultModificationDate)
        XCTAssertEqual(try modificationDate(keyURL), keyModificationDate)
    }

    func testRequestedBindingInventoryIsRequestedOnlyCanonicalAndWriteFree() async throws {
        let root = try await preparedVaultRoot(label: "requested-inventory")
        let requests = [
            request(uuid: "inventory-z", context: "domain:inventory:z"),
            request(uuid: "inventory-hidden", context: "domain:inventory:hidden"),
            request(uuid: "inventory-a", context: "domain:inventory:a")
        ]
        let plan = try await VaporIdentityVault.shared.inspectProvisioning(requests)
        let provisioned = try await VaporIdentityVault.shared.provisionIdentities(
            requests,
            expectedRevision: plan.revision
        )
        let vaultURL = vaultURL(in: root)
        let keyURL = masterKeyURL(in: root)
        try setPermissions(0o400, at: keyURL)
        let vaultBytes = try Data(contentsOf: vaultURL)
        let keyBytes = try Data(contentsOf: keyURL)
        let vaultModificationDate = try modificationDate(vaultURL)
        let keyModificationDate = try modificationDate(keyURL)
        await VaporIdentityVault.shared.resetStrictRuntimeModeForTesting()

        let first = try await VaporIdentityVault.shared.inspectExistingBindings(
            forRequestedContexts: [
                "domain:inventory:z",
                "domain:inventory:missing",
                "domain:inventory:a"
            ]
        )
        let second = try await VaporIdentityVault.shared.inspectExistingBindings(
            forRequestedContexts: [
                "domain:inventory:a",
                "domain:inventory:z",
                "domain:inventory:missing"
            ]
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.schema, VaporIdentityVaultRequestedBindingInventory.schema)
        XCTAssertEqual(first.revision, provisioned.revision)
        XCTAssertEqual(
            first.bindings.map(\.context),
            ["domain:inventory:a", "domain:inventory:z"]
        )
        XCTAssertEqual(first.bindings.map(\.uuid), ["inventory-a", "inventory-z"])
        XCTAssertTrue(first.bindings.allSatisfy { $0.signingKeyFingerprint.isEmpty == false })
        let provisionedFingerprints = Dictionary(
            uniqueKeysWithValues: provisioned.bindings.map { ($0.uuid, $0.signingKeyFingerprint) }
        )
        XCTAssertTrue(first.bindings.allSatisfy {
            provisionedFingerprints[$0.uuid] == $0.signingKeyFingerprint
        })
        XCTAssertFalse(first.bindings.contains { $0.uuid == "inventory-hidden" })
        XCTAssertEqual(
            try JSONDecoder().decode(
                VaporIdentityVaultRequestedBindingInventory.self,
                from: JSONEncoder().encode(first)
            ),
            first
        )
        XCTAssertEqual(try Data(contentsOf: vaultURL), vaultBytes)
        XCTAssertEqual(try Data(contentsOf: keyURL), keyBytes)
        XCTAssertEqual(try modificationDate(vaultURL), vaultModificationDate)
        XCTAssertEqual(try modificationDate(keyURL), keyModificationDate)
    }

    func testRequestedBindingInventoryRejectsInvalidDuplicateAndUnboundedInputsBeforeDiskAccess() async throws {
        await VaporIdentityVault.shared.resetStrictRuntimeModeForTesting()
        let parent = try makeTemporaryDirectory(label: "requested-inventory-invalid")
        let missingRoot = parent.appendingPathComponent("must-not-be-created", isDirectory: true)
        CellBase.documentRootPath = missingRoot.path

        try await assertRequestedInventoryError(.requestedContextSetEmpty, contexts: [])
        try await assertRequestedInventoryError(
            .requestedContextDuplicate,
            contexts: ["domain:duplicate", "domain:duplicate"]
        )
        try await assertRequestedInventoryError(
            .requestedContextInvalid,
            contexts: [" domain:leading-space"]
        )
        try await assertRequestedInventoryError(
            .requestedContextInvalid,
            contexts: ["domain:null\0byte"]
        )
        try await assertRequestedInventoryError(
            .requestedContextInvalid,
            contexts: [String(repeating: "x", count: 1_025)]
        )
        try await assertRequestedInventoryError(
            .requestedContextLimitExceeded,
            contexts: (0...VaporIdentityVaultRequestedBindingInventory.maximumRequestedContextCount)
                .map { "domain:bounded:\($0)" }
        )
        try await assertRequestedInventoryError(
            .vaultMissing,
            contexts: ["domain:valid-but-missing"]
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: missingRoot.path))
        XCTAssertEqual(
            VaporIdentityVaultStrictError.requestedContextDuplicate.reasonCode,
            "identity_vault_requested_context_duplicate"
        )
        XCTAssertEqual(
            VaporIdentityVaultStrictError.requestedContextLimitExceeded.reasonCode,
            "identity_vault_requested_context_limit_exceeded"
        )
    }

    func testRequestedBindingInventoryRejectsTamperAndMissingMasterKeyWithoutMutation() async throws {
        let root = try await preparedVaultRoot(label: "requested-inventory-tamper")
        let persisted = request(uuid: "inventory-tamper", context: "domain:inventory:tamper")
        let plan = try await VaporIdentityVault.shared.inspectProvisioning([persisted])
        _ = try await VaporIdentityVault.shared.provisionIdentities(
            [persisted],
            expectedRevision: plan.revision
        )
        let vaultFileURL = vaultURL(in: root)
        await VaporIdentityVault.shared.resetStrictRuntimeModeForTesting()

        var tamperedBytes = try Data(contentsOf: vaultFileURL)
        tamperedBytes[tamperedBytes.index(before: tamperedBytes.endIndex)] ^= 0x01
        try tamperedBytes.write(to: vaultFileURL)
        try setPermissions(0o600, at: vaultFileURL)
        try await assertRequestedInventoryError(
            .authenticationFailed,
            contexts: [persisted.context]
        )
        XCTAssertEqual(try Data(contentsOf: vaultFileURL), tamperedBytes)

        let restoredRoot = try await preparedVaultRoot(label: "requested-inventory-key-missing")
        let second = request(uuid: "inventory-key", context: "domain:inventory:key")
        let secondPlan = try await VaporIdentityVault.shared.inspectProvisioning([second])
        _ = try await VaporIdentityVault.shared.provisionIdentities(
            [second],
            expectedRevision: secondPlan.revision
        )
        let secondVaultURL = vaultURL(in: restoredRoot)
        let secondVaultBytes = try Data(contentsOf: secondVaultURL)
        try FileManager.default.removeItem(at: masterKeyURL(in: restoredRoot))
        await VaporIdentityVault.shared.resetStrictRuntimeModeForTesting()

        try await assertRequestedInventoryError(
            .masterKeyMissing,
            contexts: [second.context]
        )
        XCTAssertEqual(try Data(contentsOf: secondVaultURL), secondVaultBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: masterKeyURL(in: restoredRoot).path))
    }

    func testRequestedBindingInventoryRejectsActivatedStrictRuntimeWithoutReadingOrWriting() async throws {
        let root = try await preparedVaultRoot(label: "requested-inventory-offline-only")
        let persisted = request(uuid: "inventory-offline", context: "domain:inventory:offline")
        let plan = try await VaporIdentityVault.shared.inspectProvisioning([persisted])
        _ = try await VaporIdentityVault.shared.provisionIdentities(
            [persisted],
            expectedRevision: plan.revision
        )
        let vaultFileURL = vaultURL(in: root)
        let keyFileURL = masterKeyURL(in: root)
        let vaultBytes = try Data(contentsOf: vaultFileURL)
        let keyBytes = try Data(contentsOf: keyFileURL)
        let vaultModificationDate = try modificationDate(vaultFileURL)
        let keyModificationDate = try modificationDate(keyFileURL)
        _ = try await VaporIdentityVault.shared.activateStrictRuntimeMode()

        try await assertRequestedInventoryError(
            .requestedInventoryOfflineRequired,
            contexts: [persisted.context]
        )

        XCTAssertEqual(try Data(contentsOf: vaultFileURL), vaultBytes)
        XCTAssertEqual(try Data(contentsOf: keyFileURL), keyBytes)
        XCTAssertEqual(try modificationDate(vaultFileURL), vaultModificationDate)
        XCTAssertEqual(try modificationDate(keyFileURL), keyModificationDate)
        XCTAssertEqual(
            VaporIdentityVaultStrictError.requestedInventoryOfflineRequired.reasonCode,
            "identity_vault_requested_inventory_offline_required"
        )
        await VaporIdentityVault.shared.resetStrictRuntimeModeForTesting()
    }

    func testCompleteBindingInventoryIsCanonicalCompleteAndWriteFree() async throws {
        let root = try await preparedVaultRoot(label: "complete-inventory")
        let requests = [
            request(uuid: "complete-z", context: "domain:complete:z"),
            request(uuid: "complete-a", context: "domain:complete:a"),
            request(uuid: "complete-m", context: "domain:complete:m"),
            request(uuid: "complete-unicode-composed", context: "domain:complete:éa"),
            request(uuid: "complete-unicode-decomposed", context: "domain:complete:e\u{301}b")
        ]
        let plan = try await VaporIdentityVault.shared.inspectProvisioning(requests)
        let provisioned = try await VaporIdentityVault.shared.provisionIdentities(
            requests,
            expectedRevision: plan.revision
        )
        var expectedBindings: [VaporIdentityVaultBindingSummary] = []
        for request in requests {
            let identity = try await VaporIdentityVault.shared.requireIdentity(
                expectedUUID: request.uuid,
                for: request.context
            )
            expectedBindings.append(
                VaporIdentityVaultBindingSummary(
                    uuid: request.uuid,
                    context: request.context,
                    signingKeyFingerprint: try XCTUnwrap(identity.signingPublicKeyFingerprint)
                )
            )
        }
        expectedBindings.sort {
            if $0.context == $1.context {
                return $0.uuid.utf8.lexicographicallyPrecedes($1.uuid.utf8)
            }
            return $0.context.utf8.lexicographicallyPrecedes($1.context.utf8)
        }
        let vaultFileURL = vaultURL(in: root)
        let keyFileURL = masterKeyURL(in: root)
        try setPermissions(0o400, at: keyFileURL)
        let vaultBytes = try Data(contentsOf: vaultFileURL)
        let keyBytes = try Data(contentsOf: keyFileURL)
        let vaultModificationDate = try modificationDate(vaultFileURL)
        let keyModificationDate = try modificationDate(keyFileURL)
        await VaporIdentityVault.shared.resetStrictRuntimeModeForTesting()

        let inventory = try await VaporIdentityVault.shared.inspectAllExistingBindings()

        XCTAssertEqual(inventory.schema, VaporIdentityVaultCompleteBindingInventory.schema)
        XCTAssertEqual(inventory.revision, provisioned.revision)
        XCTAssertEqual(inventory.bindingCount, requests.count)
        XCTAssertEqual(inventory.bindings.count, inventory.bindingCount)
        XCTAssertEqual(inventory.bindings, expectedBindings)
        XCTAssertEqual(
            inventory.bindings.map(\.context),
            [
                "domain:complete:a",
                "domain:complete:e\u{301}b",
                "domain:complete:m",
                "domain:complete:z",
                "domain:complete:éa"
            ]
        )
        XCTAssertEqual(Set(inventory.bindings.map(\.uuid)), Set(requests.map(\.uuid)))
        XCTAssertTrue(inventory.bindings.allSatisfy {
            $0.signingKeyFingerprint.isEmpty == false
        })
        let encoded = try JSONEncoder().encode(inventory)
        XCTAssertEqual(
            try JSONDecoder().decode(
                VaporIdentityVaultCompleteBindingInventory.self,
                from: encoded
            ),
            inventory
        )
        let serialized = String(decoding: encoded, as: UTF8.self)
        for forbidden in ["privateKey", "privateSigningKey", "displayName", root.path] {
            XCTAssertFalse(serialized.contains(forbidden), forbidden)
        }
        XCTAssertEqual(try Data(contentsOf: vaultFileURL), vaultBytes)
        XCTAssertEqual(try Data(contentsOf: keyFileURL), keyBytes)
        XCTAssertEqual(try modificationDate(vaultFileURL), vaultModificationDate)
        XCTAssertEqual(try modificationDate(keyFileURL), keyModificationDate)
    }

    func testCompleteBindingInventoryRejectsServingRuntimeAndTamperWithoutMutation() async throws {
        let root = try await preparedVaultRoot(label: "complete-inventory-offline")
        let persisted = request(
            uuid: "complete-offline",
            context: "domain:complete:offline"
        )
        let plan = try await VaporIdentityVault.shared.inspectProvisioning([persisted])
        _ = try await VaporIdentityVault.shared.provisionIdentities(
            [persisted],
            expectedRevision: plan.revision
        )
        let vaultFileURL = vaultURL(in: root)
        let keyFileURL = masterKeyURL(in: root)
        let vaultBytes = try Data(contentsOf: vaultFileURL)
        let keyBytes = try Data(contentsOf: keyFileURL)
        _ = try await VaporIdentityVault.shared.activateStrictRuntimeMode()

        try await assertCompleteInventoryError(.requestedInventoryOfflineRequired)
        XCTAssertEqual(try Data(contentsOf: vaultFileURL), vaultBytes)
        XCTAssertEqual(try Data(contentsOf: keyFileURL), keyBytes)

        await VaporIdentityVault.shared.resetStrictRuntimeModeForTesting()
        var tampered = vaultBytes
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        try tampered.write(to: vaultFileURL)
        try setPermissions(0o600, at: vaultFileURL)
        try await assertCompleteInventoryError(.authenticationFailed)
        XCTAssertEqual(try Data(contentsOf: vaultFileURL), tampered)
        XCTAssertEqual(try Data(contentsOf: keyFileURL), keyBytes)
    }

    func testBatchProvisioningIsAtomicIdempotentAndSurvivesColdReload() async throws {
        let root = try await preparedVaultRoot(label: "batch")
        let requests = [
            request(uuid: "service-one", context: "domain:service:one"),
            request(uuid: "service-two", context: "domain:service:two")
        ]
        let inspection = try await VaporIdentityVault.shared.inspectProvisioning(requests)
        let result = try await VaporIdentityVault.shared.provisionIdentities(
            requests,
            expectedRevision: inspection.revision
        )
        XCTAssertEqual(Set(result.createdUUIDs), Set(requests.map(\.uuid)))
        XCTAssertEqual(Set(result.bindings.map(\.uuid)), Set(requests.map(\.uuid)))
        XCTAssertTrue(result.bindings.allSatisfy { $0.signingKeyFingerprint.isEmpty == false })
        XCTAssertGreaterThan(result.revision.fileVersion, result.previousRevision.fileVersion)
        let vaultBytes = try Data(contentsOf: vaultURL(in: root))

        let idempotentInspection = try await VaporIdentityVault.shared.inspectProvisioning(requests)
        XCTAssertEqual(idempotentInspection.items.map(\.action), [.keep, .keep])
        let idempotentResult = try await VaporIdentityVault.shared.provisionIdentities(
            requests,
            expectedRevision: idempotentInspection.revision
        )
        XCTAssertEqual(idempotentResult.revision, result.revision)
        XCTAssertEqual(idempotentResult.createdUUIDs, [])
        XCTAssertEqual(Set(idempotentResult.keptUUIDs), Set(requests.map(\.uuid)))
        XCTAssertEqual(try Data(contentsOf: vaultURL(in: root)), vaultBytes)

        let otherRoot = try await preparedVaultRoot(label: "reload-other")
        XCTAssertNotEqual(otherRoot.path, root.path)
        CellBase.documentRootPath = root.path
        let reloaded = try await VaporIdentityVault.shared.requireIdentity(
            expectedUUID: requests[0].uuid,
            for: requests[0].context
        )
        let payload = Data("strict-reload-continuity".utf8)
        let signature = try await VaporIdentityVault.shared.signMessageForIdentity(
            messageData: payload,
            identity: reloaded
        )
        let signatureIsValid = try await VaporIdentityVault.shared.verifySignature(
            signature: signature,
            messageData: payload,
            for: reloaded
        )
        XCTAssertTrue(signatureIsValid)
    }

    func testStaleRevisionCASRejectsWithoutPartialProvisioning() async throws {
        let root = try await preparedVaultRoot(label: "cas")
        let staleInspection = try await VaporIdentityVault.shared.inspectProvisioning([])
        let first = request(uuid: "cas-first", context: "domain:cas:first")
        _ = try await VaporIdentityVault.shared.provisionIdentities(
            [first],
            expectedRevision: staleInspection.revision
        )
        let bytesAfterFirst = try Data(contentsOf: vaultURL(in: root))
        let second = request(uuid: "cas-second", context: "domain:cas:second")

        do {
            _ = try await VaporIdentityVault.shared.provisionIdentities(
                [second],
                expectedRevision: staleInspection.revision
            )
            XCTFail("Expected stale CAS revision to be rejected")
        } catch let error as VaporIdentityVaultStrictError {
            XCTAssertEqual(error, .staleRevision)
            XCTAssertEqual(error.reasonCode, "identity_vault_revision_stale")
        }
        XCTAssertEqual(try Data(contentsOf: vaultURL(in: root)), bytesAfterFirst)
        let after = try await VaporIdentityVault.shared.inspectProvisioning([second])
        XCTAssertEqual(after.items.map(\.action), [.create])
    }

    func testConflictPlanAndProvisioningRejectEntireMixedBatch() async throws {
        let root = try await preparedVaultRoot(label: "conflict")
        let original = request(uuid: "bound-service", context: "domain:bound")
        let initial = try await VaporIdentityVault.shared.inspectProvisioning([original])
        _ = try await VaporIdentityVault.shared.provisionIdentities(
            [original],
            expectedRevision: initial.revision
        )
        let before = try Data(contentsOf: vaultURL(in: root))
        let conflicting = request(uuid: original.uuid, context: "domain:different")
        let otherwiseNew = request(uuid: "otherwise-new", context: "domain:otherwise-new")
        let plan = try await VaporIdentityVault.shared.inspectProvisioning([conflicting, otherwiseNew])
        XCTAssertEqual(plan.items.map(\.action), [.conflict, .create])

        do {
            _ = try await VaporIdentityVault.shared.provisionIdentities(
                [conflicting, otherwiseNew],
                expectedRevision: plan.revision
            )
            XCTFail("Expected one conflict to reject the complete batch")
        } catch let error as VaporIdentityVaultStrictError {
            XCTAssertEqual(error, .provisioningConflict)
        }
        XCTAssertEqual(try Data(contentsOf: vaultURL(in: root)), before)
        let after = try await VaporIdentityVault.shared.inspectProvisioning([otherwiseNew])
        XCTAssertEqual(after.items.map(\.action), [.create])
    }

    func testInspectionRejectsDuplicateRequestUUIDAndContextWithoutWriting() async throws {
        let root = try await preparedVaultRoot(label: "request-duplicates")
        let before = try Data(contentsOf: vaultURL(in: root))
        let requests = [
            request(uuid: "duplicate", context: "domain:first"),
            request(uuid: "duplicate", context: "domain:second"),
            request(uuid: "third", context: "domain:second")
        ]

        let plan = try await VaporIdentityVault.shared.inspectProvisioning(requests)

        XCTAssertTrue(plan.hasConflicts)
        XCTAssertEqual(plan.items.map(\.action), [.conflict, .conflict, .conflict])
        XCTAssertEqual(try Data(contentsOf: vaultURL(in: root)), before)
    }

    func testStrictLoadRejectsPersistedDuplicateUUIDAndDuplicateContext() async throws {
        let root = try await preparedVaultRoot(label: "persisted-duplicates")
        var first = VaporIdentityVault.VaultIdentity(uuid: "duplicate", displayName: "First")
        first.identityContext = "domain:first"
        var second = VaporIdentityVault.VaultIdentity(uuid: "duplicate", displayName: "Second")
        second.identityContext = "domain:second"
        try await writeLegacyRecords([first, second], root: root)
        try await assertStrictLoadError(.duplicateUUID)
        try await assertRequestedInventoryError(.duplicateUUID, contexts: ["domain:first"])

        second.uuid = "different"
        second.identityContext = first.identityContext
        try await writeLegacyRecords([first, second], root: root)
        try await assertStrictLoadError(.duplicateContext)
        try await assertRequestedInventoryError(.duplicateContext, contexts: ["domain:first"])
    }

    func testStrictLoadRejectsIncompleteAndCryptographicallyInconsistentKeys() async throws {
        let root = try await preparedVaultRoot(label: "keys")
        var incomplete = VaporIdentityVault.VaultIdentity()
        incomplete.uuid = "incomplete"
        incomplete.displayName = "Incomplete"
        incomplete.identityContext = "domain:incomplete"
        try await writeLegacyRecords([incomplete], root: root)
        try await assertStrictLoadError(.incompleteKeyMaterial)

        var inconsistent = VaporIdentityVault.VaultIdentity(uuid: "inconsistent", displayName: "Inconsistent")
        inconsistent.identityContext = "domain:inconsistent"
        inconsistent.publicKey = Data(repeating: 0xA5, count: 32)
        try await writeLegacyRecords([inconsistent], root: root)
        try await assertStrictLoadError(.inconsistentKeyMaterial)
    }

    func testStrictLoadRejectsTamperAndWrongMasterKeyWithoutRewriting() async throws {
        let root = try await preparedVaultRoot(label: "tamper")
        let request = request(uuid: "tamper-service", context: "domain:tamper")
        let inspection = try await VaporIdentityVault.shared.inspectProvisioning([request])
        _ = try await VaporIdentityVault.shared.provisionIdentities(
            [request],
            expectedRevision: inspection.revision
        )
        let vaultURL = vaultURL(in: root)
        let originalCiphertext = try Data(contentsOf: vaultURL)
        var tampered = originalCiphertext
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        try tampered.write(to: vaultURL, options: [.atomic])
        try setPermissions(0o600, at: vaultURL)
        try await assertStrictLoadError(.authenticationFailed)
        XCTAssertEqual(try Data(contentsOf: vaultURL), tampered)

        let otherRoot = try await preparedVaultRoot(label: "wrong-key-source")
        let otherKey = try Data(contentsOf: masterKeyURL(in: otherRoot))
        CellBase.documentRootPath = root.path
        try originalCiphertext.write(to: vaultURL, options: [.atomic])
        try setPermissions(0o600, at: vaultURL)
        try otherKey.write(to: masterKeyURL(in: root), options: [.atomic])
        try setPermissions(0o600, at: masterKeyURL(in: root))
        try await assertStrictLoadError(.authenticationFailed)
    }

    func testStrictLoadRejectsUnsafeModeAndSymlinkMetadata() async throws {
        let root = try await preparedVaultRoot(label: "metadata")
        let vaultURL = vaultURL(in: root)
        try setPermissions(0o640, at: vaultURL)
        try await assertStrictLoadError(.unsafeVaultMetadata)

        try setPermissions(0o600, at: vaultURL)
        let realVaultURL = root.appendingPathComponent("real-vault", isDirectory: false)
        try FileManager.default.moveItem(at: vaultURL, to: realVaultURL)
        try FileManager.default.createSymbolicLink(at: vaultURL, withDestinationURL: realVaultURL)
        try await assertStrictLoadError(.unsafeVaultMetadata)
    }

    func testStrictLoadRejectsHardlinksAndExtendedAttributes() async throws {
        let root = try await preparedVaultRoot(label: "metadata-hardening")
        let vaultURL = vaultURL(in: root)
        let vaultHardlink = root.appendingPathComponent("vault-hardlink", isDirectory: false)
        try FileManager.default.linkItem(at: vaultURL, to: vaultHardlink)
        try await assertStrictLoadError(.unsafeVaultMetadata)
        try FileManager.default.removeItem(at: vaultHardlink)

        let keyURL = masterKeyURL(in: root)
        let keyHardlink = root.appendingPathComponent("key-hardlink", isDirectory: false)
        try FileManager.default.linkItem(at: keyURL, to: keyHardlink)
        try await assertStrictLoadError(.unsafeMasterKeyMetadata)
        try FileManager.default.removeItem(at: keyHardlink)

#if canImport(Darwin)
        var marker: UInt8 = 1
        let setStatus = withUnsafePointer(to: &marker) { pointer in
            Darwin.setxattr(
                vaultURL.path,
                "org.digipomps.haven.strict-test",
                pointer,
                1,
                0,
                XATTR_NOFOLLOW
            )
        }
        XCTAssertEqual(setStatus, 0)
        try await assertStrictLoadError(.unsafeVaultMetadata)
        XCTAssertEqual(
            Darwin.removexattr(
                vaultURL.path,
                "org.digipomps.haven.strict-test",
                XATTR_NOFOLLOW
            ),
            0
        )
#endif
    }

    func testStrictVaultSizeCapRejectsOneByteOverAndProcessesExactBoundary() async throws {
        let root = try await preparedVaultRoot(label: "size-cap")
        let vaultURL = vaultURL(in: root)
        let handle = try FileHandle(forWritingTo: vaultURL)
        try handle.truncate(atOffset: 64 * 1024 * 1024 + 1)
        try handle.close()
        try await assertStrictLoadError(.vaultTooLarge)

        let exactBoundaryHandle = try FileHandle(forWritingTo: vaultURL)
        try exactBoundaryHandle.truncate(atOffset: 64 * 1024 * 1024)
        try exactBoundaryHandle.close()
        // The original CVLT1 prefix remains after sparse expansion, so reaching
        // authentication (rather than the size guard) proves the exact cap is processed.
        try await assertStrictLoadError(.authenticationFailed)
    }

    func testInjectedAtomicWriteFailureLeavesPersistedAndPublishedStateUnchanged() async throws {
        let root = try await preparedVaultRoot(label: "write-failure")
        let existing = request(uuid: "existing", context: "domain:existing")
        let initial = try await VaporIdentityVault.shared.inspectProvisioning([existing])
        _ = try await VaporIdentityVault.shared.provisionIdentities(
            [existing],
            expectedRevision: initial.revision
        )
        let next = request(uuid: "must-not-persist", context: "domain:must-not-persist")
        let plan = try await VaporIdentityVault.shared.inspectProvisioning([next])
        let before = try Data(contentsOf: vaultURL(in: root))

        await VaporIdentityVault.shared.setStrictWriteFailureForTesting(true)
        defer {
            Task { await VaporIdentityVault.shared.setStrictWriteFailureForTesting(false) }
        }
        do {
            _ = try await VaporIdentityVault.shared.provisionIdentities(
                [next],
                expectedRevision: plan.revision
            )
            XCTFail("Expected injected atomic write failure")
        } catch let error as VaporIdentityVaultStrictError {
            XCTAssertEqual(error, .persistenceFailed)
        }
        await VaporIdentityVault.shared.setStrictWriteFailureForTesting(false)

        XCTAssertEqual(try Data(contentsOf: vaultURL(in: root)), before)
        let existingReloaded = try await VaporIdentityVault.shared.requireIdentity(
            expectedUUID: existing.uuid,
            for: existing.context
        )
        XCTAssertEqual(existingReloaded.uuid, existing.uuid)
        let after = try await VaporIdentityVault.shared.inspectProvisioning([next])
        XCTAssertEqual(after.items.map(\.action), [.create])
    }

    func testDirectorySyncFailureLeavesNewFileUnpublishedUntilExplicitRecovery() async throws {
        let root = try await preparedVaultRoot(label: "directory-sync-failure")
        let existing = request(uuid: "sync-existing", context: "domain:sync:existing")
        let initial = try await VaporIdentityVault.shared.inspectProvisioning([existing])
        _ = try await VaporIdentityVault.shared.provisionIdentities(
            [existing],
            expectedRevision: initial.revision
        )
        let next = request(uuid: "sync-new", context: "domain:sync:new")
        let plan = try await VaporIdentityVault.shared.inspectProvisioning([next])
        let before = try Data(contentsOf: vaultURL(in: root))

        await VaporIdentityVault.shared.setStrictDirectorySyncFailureForTesting(true)
        do {
            _ = try await VaporIdentityVault.shared.provisionIdentities(
                [next],
                expectedRevision: plan.revision
            )
            XCTFail("Expected injected directory fsync failure")
        } catch let error as VaporIdentityVaultStrictError {
            XCTAssertEqual(error, .persistenceOutcomeUnknown)
            XCTAssertEqual(error.reasonCode, "identity_vault_persistence_outcome_unknown")
        }
        await VaporIdentityVault.shared.setStrictDirectorySyncFailureForTesting(false)

        let afterRename = try Data(contentsOf: vaultURL(in: root))
        XCTAssertNotEqual(afterRename, before)
        let unpublishedIdentity = await VaporIdentityVault.shared.identity(
            for: next.context,
            makeNewIfNotFound: false
        )
        XCTAssertNil(unpublishedIdentity)

        let recovered = try await VaporIdentityVault.shared.loadStrict()
        XCTAssertEqual(recovered.bindingCount, 2)
        let recoveredIdentity = try await VaporIdentityVault.shared.requireIdentity(
            expectedUUID: next.uuid,
            for: next.context
        )
        XCTAssertEqual(recoveredIdentity.uuid, next.uuid)
    }

    func testCrashLeftLockFailsClosedUntilExplicitManualRecovery() async throws {
        let root = try await preparedVaultRoot(label: "stale-lock")
        let next = request(uuid: "locked", context: "domain:locked")
        let plan = try await VaporIdentityVault.shared.inspectProvisioning([next])
        let before = try Data(contentsOf: vaultURL(in: root))
        let lockURL = root.appendingPathComponent(".OrganisationIdentities.lock", isDirectory: true)
        try FileManager.default.createDirectory(
            at: lockURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try setPermissions(0o700, at: lockURL)

        do {
            _ = try await VaporIdentityVault.shared.provisionIdentities(
                [next],
                expectedRevision: plan.revision
            )
            XCTFail("Expected a crash-left lock to fail closed")
        } catch let error as VaporIdentityVaultStrictError {
            XCTAssertEqual(error, .lockUnavailable)
        }
        XCTAssertEqual(try Data(contentsOf: vaultURL(in: root)), before)

        try FileManager.default.removeItem(at: lockURL)
        let recovered = try await VaporIdentityVault.shared.provisionIdentities(
            [next],
            expectedRevision: plan.revision
        )
        XCTAssertEqual(recovered.createdUUIDs, [next.uuid])
    }

    func testLockCleanupFailureIsTypedAndLeavesCommittedBindingRecoverable() async throws {
        let root = try await preparedVaultRoot(label: "lock-cleanup")
        let next = request(uuid: "cleanup-committed", context: "domain:cleanup:committed")
        let plan = try await VaporIdentityVault.shared.inspectProvisioning([next])
        await VaporIdentityVault.shared.setStrictLockCleanupFailureForTesting(true)
        do {
            _ = try await VaporIdentityVault.shared.provisionIdentities(
                [next],
                expectedRevision: plan.revision
            )
            XCTFail("Expected injected lock cleanup failure")
        } catch let error as VaporIdentityVaultStrictError {
            XCTAssertEqual(error, .lockCleanupRequired)
            XCTAssertEqual(error.reasonCode, "identity_vault_lock_cleanup_required")
        }
        await VaporIdentityVault.shared.setStrictLockCleanupFailureForTesting(false)

        let lockURL = root.appendingPathComponent(".OrganisationIdentities.lock", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
        try FileManager.default.removeItem(at: lockURL)
        let recovered = try await VaporIdentityVault.shared.loadStrict()
        XCTAssertEqual(recovered.bindingCount, 1)
        let required = try await VaporIdentityVault.shared.requireIdentity(
            expectedUUID: next.uuid,
            for: next.context
        )
        XCTAssertEqual(required.uuid, next.uuid)
    }

    func testStrictRuntimeModePinsAuthorityAndBlocksEveryLegacyPersistentMutation() async throws {
        let root = try await preparedVaultRoot(label: "strict-runtime")
        let persisted = request(uuid: "runtime-owner", context: "domain:runtime:owner")
        let plan = try await VaporIdentityVault.shared.inspectProvisioning([persisted])
        let provisioned = try await VaporIdentityVault.shared.provisionIdentities(
            [persisted],
            expectedRevision: plan.revision
        )
        let before = try Data(contentsOf: vaultURL(in: root))

        let activated = try await VaporIdentityVault.shared.activateStrictRuntimeMode()
        XCTAssertEqual(activated.revision, provisioned.revision)
        let verifiedBacking = try await VaporIdentityVault.shared.verifyStrictRuntimeBackingStore()
        XCTAssertEqual(verifiedBacking, activated)
        let loadedAgain = try await VaporIdentityVault.shared.loadStrict()
        XCTAssertEqual(loadedAgain, activated)
        let activatedAgain = try await VaporIdentityVault.shared.activateStrictRuntimeMode()
        XCTAssertEqual(activatedAgain, activated)

        let existingLookup = await VaporIdentityVault.shared.identity(
            for: persisted.context,
            makeNewIfNotFound: true
        )
        let existing = try XCTUnwrap(existingLookup)
        let payload = Data("strict-runtime-signing".utf8)
        let signature = try await VaporIdentityVault.shared.signMessageForIdentity(
            messageData: payload,
            identity: existing
        )
        let signatureIsValid = try await VaporIdentityVault.shared.verifySignature(
            signature: signature,
            messageData: payload,
            for: existing
        )
        XCTAssertTrue(signatureIsValid)

        let missingRuntimeIdentity = await VaporIdentityVault.shared.identity(
            for: "domain:runtime:missing",
            makeNewIfNotFound: true
        )
        XCTAssertNil(missingRuntimeIdentity)
        var attemptedPersistent = Identity(
            "runtime-attempted-add",
            displayName: "Attempted add",
            identityVault: VaporIdentityVault.shared
        )
        await VaporIdentityVault.shared.addIdentity(
            identity: &attemptedPersistent,
            for: "domain:runtime:attempted-add"
        )
        await VaporIdentityVault.shared.saveIdentity(attemptedPersistent)
        await VaporIdentityVault.shared.saveIdentities()
        do {
            try await VaporIdentityVault.shared.saveIdentities(jsonData: Data("[]".utf8))
            XCTFail("Expected direct legacy persistence to be prohibited")
        } catch let error as VaporIdentityVaultStrictError {
            XCTAssertEqual(error, .strictRuntimeWriteProhibited)
        }
        do {
            _ = try await VaporIdentityVault.shared.provisionIdentities(
                [request(uuid: "runtime-provision", context: "domain:runtime:provision")],
                expectedRevision: activated.revision
            )
            XCTFail("Expected strict provisioning to require an offline process")
        } catch let error as VaporIdentityVaultStrictError {
            XCTAssertEqual(error, .strictRuntimeWriteProhibited)
        }
        let attemptedAddLookup = await VaporIdentityVault.shared.identity(
            for: "domain:runtime:attempted-add",
            makeNewIfNotFound: false
        )
        XCTAssertNil(attemptedAddLookup)

        var visitor = Identity(
            "runtime-visitor",
            displayName: "Runtime visitor",
            identityVault: VaporIdentityVault.shared
        )
        await VaporIdentityVault.shared.addIdentity(
            identity: &visitor,
            for: visitor.uuid
        )
        let visitorLookup = await VaporIdentityVault.shared.getIdentity(by: visitor.uuid)
        XCTAssertEqual(visitorLookup?.uuid, visitor.uuid)
        XCTAssertEqual(try Data(contentsOf: vaultURL(in: root)), before)

        try FileManager.default.removeItem(at: vaultURL(in: root))
        _ = await VaporIdentityVault.shared.initialize()
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultURL(in: root).path))
        let pinnedLookup = await VaporIdentityVault.shared.identity(
            for: persisted.context,
            makeNewIfNotFound: true
        )
        let pinnedAfterDeletion = try XCTUnwrap(pinnedLookup)
        XCTAssertEqual(pinnedAfterDeletion.uuid, persisted.uuid)
        let stillMissingLookup = await VaporIdentityVault.shared.identity(
            for: "domain:runtime:still-missing",
            makeNewIfNotFound: true
        )
        XCTAssertNil(stillMissingLookup)
        do {
            _ = try await VaporIdentityVault.shared.verifyStrictRuntimeBackingStore()
            XCTFail("Expected readiness verification to detect the deleted backing vault")
        } catch let error as VaporIdentityVaultStrictError {
            XCTAssertEqual(error, .vaultMissing)
        }
        let failedClosedLookup = await VaporIdentityVault.shared.identity(
            for: persisted.context,
            makeNewIfNotFound: false
        )
        XCTAssertNil(failedClosedLookup)

        await VaporIdentityVault.shared.resetStrictRuntimeModeForTesting()
        do {
            _ = try await VaporIdentityVault.shared.activateStrictRuntimeMode()
            XCTFail("A cold strict runtime must reject a deleted vault")
        } catch let error as VaporIdentityVaultStrictError {
            XCTAssertEqual(error, .vaultMissing)
        }

        try before.write(to: vaultURL(in: root), options: [.atomic])
        try setPermissions(0o600, at: vaultURL(in: root))
        let coldActivated = try await VaporIdentityVault.shared.activateStrictRuntimeMode()
        XCTAssertEqual(coldActivated.revision, activated.revision)
        let coldVisitorLookup = await VaporIdentityVault.shared.getIdentity(by: visitor.uuid)
        XCTAssertNil(coldVisitorLookup)
        await VaporIdentityVault.shared.resetStrictRuntimeModeForTesting()
    }

    func testStrictRuntimeRootDriftFailsClosedAndRecoversOnlyAtPinnedRoot() async throws {
        let root = try await preparedVaultRoot(label: "runtime-root")
        let persisted = request(uuid: "root-owner", context: "domain:root:owner")
        let plan = try await VaporIdentityVault.shared.inspectProvisioning([persisted])
        _ = try await VaporIdentityVault.shared.provisionIdentities(
            [persisted],
            expectedRevision: plan.revision
        )
        _ = try await VaporIdentityVault.shared.activateStrictRuntimeMode()
        let identityLookup = await VaporIdentityVault.shared.identity(
            for: persisted.context,
            makeNewIfNotFound: false
        )
        let identity = try XCTUnwrap(identityLookup)
        let otherRoot = try makeTemporaryDirectory(label: "runtime-root-drift")
        CellBase.documentRootPath = otherRoot.path

        let driftedLookup = await VaporIdentityVault.shared.identity(
            for: persisted.context,
            makeNewIfNotFound: false
        )
        XCTAssertNil(driftedLookup)
        let driftedVaultReference = await VaporIdentityVault.shared.identityVaultReference()
        XCTAssertNil(driftedVaultReference)
        do {
            _ = try await VaporIdentityVault.shared.privateKeyData(
                for: Identity(
                    "unknown",
                    displayName: "Unknown",
                    identityVault: VaporIdentityVault.shared
                ),
                role: .signing
            )
            XCTFail("Expected private-key access to fail closed on root drift")
        } catch let error as VaporIdentityVaultStrictError {
            XCTAssertEqual(error, .strictRuntimeRootDrift)
        }
        do {
            _ = try await VaporIdentityVault.shared.verifyStrictRuntimeBackingStore()
            XCTFail("Expected readiness verification to detect root drift")
        } catch let error as VaporIdentityVaultStrictError {
            XCTAssertEqual(error, .strictRuntimeRootDrift)
        }
        do {
            _ = try await VaporIdentityVault.shared.signMessageForIdentity(
                messageData: Data("root-drift".utf8),
                identity: identity
            )
            XCTFail("Expected signing to fail closed on root drift")
        } catch let error as VaporIdentityVaultStrictError {
            XCTAssertEqual(error, .strictRuntimeRootDrift)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: otherRoot.appendingPathComponent(VaporIdentityVault.identitiesFileName).path
        ))

        CellBase.documentRootPath = root.path
        _ = try await VaporIdentityVault.shared.verifyStrictRuntimeBackingStore()
        let recoveredLookup = await VaporIdentityVault.shared.identity(
            for: persisted.context,
            makeNewIfNotFound: false
        )
        XCTAssertEqual(recoveredLookup?.uuid, persisted.uuid)
        await VaporIdentityVault.shared.resetStrictRuntimeModeForTesting()
    }

    func testStrictRuntimeBackingVerificationRejectsMasterKeyInodeOrDigestDrift() async throws {
        let root = try await preparedVaultRoot(label: "runtime-key-drift")
        let persisted = request(uuid: "key-owner", context: "domain:key:owner")
        let plan = try await VaporIdentityVault.shared.inspectProvisioning([persisted])
        _ = try await VaporIdentityVault.shared.provisionIdentities(
            [persisted],
            expectedRevision: plan.revision
        )
        _ = try await VaporIdentityVault.shared.activateStrictRuntimeMode()
        let keyURL = masterKeyURL(in: root)
        let originalKey = try Data(contentsOf: keyURL)
        let pinnedOriginalHandle = try FileHandle(forReadingFrom: keyURL)
        defer { try? pinnedOriginalHandle.close() }
        let originalInode = try inode(at: keyURL)
        let replacementKey = Data(repeating: 0x5A, count: 32).base64EncodedData()
        let replacementInode = try replaceRegularFileAtomically(
            at: keyURL,
            with: replacementKey
        )
        XCTAssertNotEqual(replacementInode, originalInode)

        do {
            _ = try await VaporIdentityVault.shared.verifyStrictRuntimeBackingStore()
            XCTFail("Expected changed master-key inode/digest to fail readiness")
        } catch let error as VaporIdentityVaultStrictError {
            XCTAssertEqual(error, .strictMasterKeyChanged)
        }
        let failedClosedLookup = await VaporIdentityVault.shared.identity(
            for: persisted.context,
            makeNewIfNotFound: false
        )
        XCTAssertNil(failedClosedLookup)

        let restoredInode = try replaceRegularFileAtomically(
            at: keyURL,
            with: originalKey
        )
        XCTAssertNotEqual(restoredInode, originalInode)
        XCTAssertNotEqual(restoredInode, replacementInode)
        do {
            _ = try await VaporIdentityVault.shared.verifyStrictRuntimeBackingStore()
            XCTFail("Restoring bytes on a different inode must still require a restart")
        } catch let error as VaporIdentityVaultStrictError {
            XCTAssertEqual(error, .strictMasterKeyChanged)
        }

        await VaporIdentityVault.shared.resetStrictRuntimeModeForTesting()
        let cold = try await VaporIdentityVault.shared.activateStrictRuntimeMode()
        XCTAssertEqual(cold.bindingCount, 1)
        await VaporIdentityVault.shared.resetStrictRuntimeModeForTesting()
    }

    private func request(uuid: String, context: String) -> VaporIdentityProvisioningRequest {
        VaporIdentityProvisioningRequest(
            uuid: uuid,
            context: context,
            displayName: "Service \(uuid)"
        )
    }

    private func preparedVaultRoot(label: String) async throws -> URL {
        await VaporIdentityVault.shared.resetStrictRuntimeModeForTesting()
        let root = try makeTemporaryDirectory(label: label)
        CellBase.documentRootPath = root.path
        _ = await VaporIdentityVault.shared.initialize()
        try setPermissions(0o700, at: root)
        try setPermissions(0o700, at: root.appendingPathComponent(".secrets", isDirectory: true))
        try setPermissions(0o600, at: masterKeyURL(in: root))
        try setPermissions(0o600, at: vaultURL(in: root))
        return root
    }

    private func makeTemporaryDirectory(label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VaporIdentityVaultStrict-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try setPermissions(0o700, at: root)
        roots.append(root)
        return root
    }

    private func writeLegacyRecords(
        _ records: [VaporIdentityVault.VaultIdentity],
        root: URL
    ) async throws {
        CellBase.documentRootPath = root.path
        try await VaporIdentityVault.shared.saveIdentities(jsonData: JSONEncoder().encode(records))
        try setPermissions(0o600, at: vaultURL(in: root))
    }

    private func assertStrictLoadError(
        _ expected: VaporIdentityVaultStrictError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            _ = try await VaporIdentityVault.shared.loadStrict()
            XCTFail("Expected strict vault load to fail", file: file, line: line)
        } catch let error as VaporIdentityVaultStrictError {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    private func assertRequestedInventoryError(
        _ expected: VaporIdentityVaultStrictError,
        contexts: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            _ = try await VaporIdentityVault.shared.inspectExistingBindings(
                forRequestedContexts: contexts
            )
            XCTFail("Expected requested binding inventory to fail", file: file, line: line)
        } catch let error as VaporIdentityVaultStrictError {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    private func assertCompleteInventoryError(
        _ expected: VaporIdentityVaultStrictError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            _ = try await VaporIdentityVault.shared.inspectAllExistingBindings()
            XCTFail("Expected complete binding inventory to fail", file: file, line: line)
        } catch let error as VaporIdentityVaultStrictError {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    private func vaultURL(in root: URL) -> URL {
        root.appendingPathComponent(VaporIdentityVault.identitiesFileName, isDirectory: false)
    }

    private func masterKeyURL(in root: URL) -> URL {
        root.appendingPathComponent(".secrets", isDirectory: true)
            .appendingPathComponent("vault-master.key", isDirectory: false)
    }

    private func modificationDate(_ url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }

    private func inode(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value
    }

    private func replaceRegularFileAtomically(at targetURL: URL, with data: Data) throws -> UInt64 {
        let temporaryURL = targetURL.deletingLastPathComponent().appendingPathComponent(
            ".\(targetURL.lastPathComponent).strict-test-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor: Int32
#if canImport(Darwin)
        descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
#elseif canImport(Glibc)
        descriptor = Glibc.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
#else
        descriptor = -1
#endif
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var shouldRemoveTemporaryFile = true
        defer {
            if shouldRemoveTemporaryFile {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try setPermissions(0o600, at: temporaryURL)

        let stagedInode = try inode(at: temporaryURL)
        let targetInode = try inode(at: targetURL)
        guard stagedInode != targetInode else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST))
        }
#if canImport(Darwin)
        let renameStatus = Darwin.rename(temporaryURL.path, targetURL.path)
#elseif canImport(Glibc)
        let renameStatus = Glibc.rename(temporaryURL.path, targetURL.path)
#else
        let renameStatus = -1
#endif
        guard renameStatus == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        shouldRemoveTemporaryFile = false

        let installedInode = try inode(at: targetURL)
        guard installedInode == stagedInode else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        return installedInode
    }

    private func setPermissions(_ permissions: Int, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }
}
