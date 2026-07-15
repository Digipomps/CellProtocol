// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@_spi(Testing) @_spi(CellRuntimeRecovery) @testable import CellBase
import Foundation

#if canImport(CellVapor)
import CellVapor
#endif

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class ResolverTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousResolver: CellResolverProtocol?
    private var previousScopedSecretProvider: ScopedSecretProviderProtocol?
    private var previousPersistedCellMasterKey: Data?
    private var previousDocumentRootPath: String?
    private var previousTypedCellUtility: TypedCellUtility?
    private var previousGlobalTypedCellUtility: TypedCellProtocol?

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousResolver = CellBase.defaultCellResolver
        previousScopedSecretProvider = CellBase.defaultScopedSecretProvider
        previousPersistedCellMasterKey = CellBase.persistedCellMasterKey
        previousDocumentRootPath = CellBase.documentRootPath
        previousGlobalTypedCellUtility = CellBase.typedCellUtility
        CellBase.defaultIdentityVault = MockIdentityVault()
        CellBase.defaultCellResolver = CellResolver.sharedInstance
        previousTypedCellUtility = CellResolver.sharedInstance.tcUtility
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.defaultCellResolver = previousResolver
        CellBase.defaultScopedSecretProvider = previousScopedSecretProvider
        CellBase.persistedCellMasterKey = previousPersistedCellMasterKey
        CellBase.documentRootPath = previousDocumentRootPath
        CellBase.typedCellUtility = previousGlobalTypedCellUtility
        CellResolver.sharedInstance.tcUtility = previousTypedCellUtility
        super.tearDown()
    }

    func testTemplateResolveCreatesNewInstances() async throws {
        let resolver = CellResolver.sharedInstance
        let name = "Template-\(UUID().uuidString)"
        try await resolver.addCellResolve(name: name, cellScope: .template, identityDomain: "private", type: GeneralCell.self)

        let identity = await CellBase.defaultIdentityVault?.identity(for: "private", makeNewIfNotFound: true)
        let first = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identity!)
        let second = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identity!)

        XCTAssertNotEqual(first.uuid, second.uuid)
    }

    func testTemplateResolveUsesRequesterAsOwner() async throws {
        let resolver = CellResolver.sharedInstance
        let name = "TemplateRequesterOwner-\(UUID().uuidString)"
        try await resolver.addCellResolve(name: name, cellScope: .template, identityDomain: "scaffold-template-owner", type: GeneralCell.self)

        guard let requesterA = await CellBase.defaultIdentityVault?.identity(for: "template-requester-a", makeNewIfNotFound: true),
              let requesterB = await CellBase.defaultIdentityVault?.identity(for: "template-requester-b", makeNewIfNotFound: true) else {
            return XCTFail("Expected requester identities")
        }

        guard let first = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: requesterA) as? GeneralCell,
              let second = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: requesterB) as? GeneralCell else {
            return XCTFail("Expected template resolves to create GeneralCell instances")
        }

        let firstOwner = try await first.getOwner(requester: requesterA)
        let secondOwner = try await second.getOwner(requester: requesterB)

        XCTAssertNotEqual(first.uuid, second.uuid)
        XCTAssertEqual(firstOwner.uuid, requesterA.uuid)
        XCTAssertEqual(secondOwner.uuid, requesterB.uuid)
    }

    func testScaffoldUniqueReturnsSameInstance() async throws {
        let resolver = CellResolver.sharedInstance
        let name = "Scaffold-\(UUID().uuidString)"
        try await resolver.addCellResolve(name: name, cellScope: .scaffoldUnique, identityDomain: "private", type: GeneralCell.self)

        let identity = await CellBase.defaultIdentityVault?.identity(for: "private", makeNewIfNotFound: true)
        let first = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identity!)
        let second = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identity!)

        XCTAssertEqual(first.uuid, second.uuid)
    }

    func testRuntimeResetClearsNamedResolvesAndLoadedInstances() async throws {
        let resolver = CellResolver.sharedInstance
        let name = "ResettableResolverState-\(UUID().uuidString)"
        let resolvedIdentity = await CellBase.defaultIdentityVault?.identity(
            for: "private",
            makeNewIfNotFound: true
        )
        let identity = try XCTUnwrap(resolvedIdentity)

        try await resolver.addCellResolve(
            name: name,
            cellScope: .scaffoldUnique,
            identityDomain: "private",
            type: GeneralCell.self
        )
        let first = try await resolver.cellAtEndpoint(
            endpoint: "cell:///\(name)",
            requester: identity
        )

        await resolver.resetRuntimeStateForTesting()

        try await resolver.addCellResolve(
            name: name,
            cellScope: .scaffoldUnique,
            identityDomain: "private",
            type: GeneralCell.self
        )
        let second = try await resolver.cellAtEndpoint(
            endpoint: "cell:///\(name)",
            requester: identity
        )

        XCTAssertNotEqual(first.uuid, second.uuid)
    }

    func testScaffoldUniqueSameForDifferentIdentities() async throws {
        let resolver = CellResolver.sharedInstance
        let name = "ScaffoldShared-\(UUID().uuidString)"
        try await resolver.addCellResolve(name: name, cellScope: .scaffoldUnique, identityDomain: "private", type: GeneralCell.self)

        let identityA = await CellBase.defaultIdentityVault?.identity(for: "private", makeNewIfNotFound: true)
        let identityB = await CellBase.defaultIdentityVault?.identity(for: "privateB", makeNewIfNotFound: true)

        let first = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identityA!)
        let second = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identityB!)

        XCTAssertEqual(first.uuid, second.uuid)
    }

    func testIdentityUniqueDifferentPerIdentity() async throws {
        let resolver = CellResolver.sharedInstance
        let name = "Identity-\(UUID().uuidString)"
        try await resolver.addCellResolve(name: name, cellScope: .identityUnique, identityDomain: "private", type: GeneralCell.self)

        let identityA = await CellBase.defaultIdentityVault?.identity(for: "private", makeNewIfNotFound: true)
        let identityB = await CellBase.defaultIdentityVault?.identity(for: "privateB", makeNewIfNotFound: true)

        let first = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identityA!)
        let second = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identityB!)
        let third = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identityA!)

        XCTAssertNotEqual(first.uuid, second.uuid)
        XCTAssertEqual(first.uuid, third.uuid)
    }

    func testIdentityUniqueDirectUUIDResolutionAcceptsVerifiedContractOnly() async throws {
        let resolver = CellResolver.sharedInstance
        let vault = try XCTUnwrap(CellBase.defaultIdentityVault)
        let resolvedOwner = await vault.identity(
            for: "direct-contract-owner-\(UUID().uuidString)",
            makeNewIfNotFound: true
        )
        let resolvedMember = await vault.identity(
            for: "direct-contract-member-\(UUID().uuidString)",
            makeNewIfNotFound: true
        )
        let resolvedOutsider = await vault.identity(
            for: "direct-contract-outsider-\(UUID().uuidString)",
            makeNewIfNotFound: true
        )
        let resolvedUnrelatedKey = await vault.identity(
            for: "direct-contract-unrelated-key-\(UUID().uuidString)",
            makeNewIfNotFound: true
        )
        let owner = try XCTUnwrap(resolvedOwner)
        let member = try XCTUnwrap(resolvedMember)
        let outsider = try XCTUnwrap(resolvedOutsider)
        let unrelatedKey = try XCTUnwrap(resolvedUnrelatedKey)

        let cell = await GeneralCell(owner: owner)
        cell.cellScope = .identityUnique
        await cell.addInterceptForGet(requester: owner, key: "shared") { _, _ in
            .string("visible through contract")
        }
        await cell.addInterceptForGet(requester: owner, key: "secret") { _, _ in
            .string("owner only")
        }
        cell.agreementTemplate.addGrant("r---", for: "shared")
        let agreement = Agreement(owner: owner)
        agreement.addGrant("r---", for: "shared")
        let agreementState = await cell.addAgreement(
            agreement,
            for: member,
            authorizedBy: owner
        )
        XCTAssertEqual(agreementState, .signed)

        let name = "DirectContractCell-\(UUID().uuidString)"
        try await resolver.addCellResolve(
            name: name,
            cellScope: .identityUnique,
            identityDomain: "direct-contract-resolution",
            type: GeneralCell.self
        )
        try await resolver.registerNamedEmitCell(
            name: name,
            emitCell: cell,
            scope: .identityUnique,
            identity: owner
        )
        defer { Task { await resolver.unregisterEmitCell(uuid: cell.uuid) } }

        let directEndpoint = "cell:///\(cell.uuid)"
        let resolved = try await resolver.cellAtEndpoint(
            endpoint: directEndpoint,
            requester: member
        )
        XCTAssertEqual(resolved.uuid, cell.uuid)
        let sharedValue = try await (resolved as? GeneralCell)?.get(
            keypath: "shared",
            requester: member
        )
        XCTAssertEqual(sharedValue, .string("visible through contract"))

        do {
            _ = try await (resolved as? GeneralCell)?.get(keypath: "secret", requester: member)
            XCTFail("Resolving a concrete UUID must not grant an unlisted keypath")
        } catch let CellAuthorizationError.denied(decision) {
            XCTAssertEqual(decision.path, .deniedNoGrant)
        }

        do {
            _ = try await resolver.cellAtEndpoint(endpoint: directEndpoint, requester: outsider)
            XCTFail("An unrelated Identity must not resolve an identity-unique Cell UUID")
        } catch CellSetupError.ownerAuthorityUnavailable {
            // Expected.
        }

        let forgedMember = Identity(member.uuid, displayName: "Forged member", identityVault: vault)
        forgedMember.publicSecureKey = unrelatedKey.publicSecureKey
        do {
            _ = try await resolver.cellAtEndpoint(endpoint: directEndpoint, requester: forgedMember)
            XCTFail("A matching UUID with a different signing key must not satisfy the Contract")
        } catch CellSetupError.ownerAuthorityUnavailable {
            // Expected.
        }

        let memberNamedCell = try await resolver.cellAtEndpoint(
            endpoint: "cell:///\(name)",
            requester: member
        )
        XCTAssertNotEqual(
            memberNamedCell.uuid,
            cell.uuid,
            "Named identity-unique resolution must remain scoped to the active requester"
        )

        let persistedSnapshot = try JSONEncoder().encode(cell)
        await resolver.unregisterEmitCell(uuid: cell.uuid)
        let decodedCell = try JSONDecoder().decode(GeneralCell.self, from: persistedSnapshot)
        CellBase.typedCellUtility = FixedDecodedCellUtility(cell: decodedCell)
        let restored = try await resolver.loadTypedEmitCell(
            with: cell.uuid,
            requester: member
        )
        let restoredCell = try XCTUnwrap(restored as? GeneralCell)
        let restoredDecision = await restoredCell.authorizationDecision(
            requestedAccess: "r---",
            at: "shared",
            for: member
        )
        XCTAssertTrue(restoredDecision.allowed)
        XCTAssertEqual(restoredDecision.path, .signedContract)
    }

    func testIdentitySetFollowsReplacedEntityAnchorMapping() async throws {
        let resolver = CellResolver.sharedInstance
        await resolver.resetRuntimeStateForTesting()

        let resolvedOwner = await CellBase.defaultIdentityVault?.identity(
            for: "identity-anchor-rebinding",
            makeNewIfNotFound: true
        )
        let owner = try XCTUnwrap(resolvedOwner)
        let firstAnchor = await IdentityEntityAnchorProbeCell(owner: owner)
        let secondAnchor = await IdentityEntityAnchorProbeCell(owner: owner)
        await firstAnchor.installProbeBindings(owner: owner)
        await secondAnchor.installProbeBindings(owner: owner)

        try await resolver.registerNamedEmitCell(
            name: "EntityAnchor",
            emitCell: firstAnchor,
            scope: .identityUnique,
            identity: owner
        )
        try await resolver.registerNamedEmitCell(
            name: "ReplacementEntityAnchor-\(UUID().uuidString)",
            emitCell: secondAnchor,
            scope: .identityUnique,
            identity: owner
        )

        _ = try await owner.set(
            keypath: "identity.proofs.runtime",
            value: .string("first"),
            requester: owner
        )
        let firstRecordedValue = await firstAnchor.recordedValue(for: "proofs.runtime")
        XCTAssertEqual(firstRecordedValue, .string("first"))

        var mappings = await resolver.identityNamedCells(requester: owner)
        mappings[owner.uuid, default: [:]]["EntityAnchor"] = secondAnchor.uuid
        await resolver.setIdentityNamedCells(mappings, requester: owner)

        _ = try await owner.set(
            keypath: "identity.proofs.runtime",
            value: .string("second"),
            requester: owner
        )

        let staleAnchorValue = await firstAnchor.recordedValue(for: "proofs.runtime")
        let currentAnchorValue = await secondAnchor.recordedValue(for: "proofs.runtime")
        XCTAssertEqual(
            staleAnchorValue,
            .string("first"),
            "Replacing the resolver mapping must stop subsequent Identity mutations from reaching the stale EntityAnchor."
        )
        XCTAssertEqual(
            currentAnchorValue,
            .string("second"),
            "Identity.set must resolve the current identity-scoped EntityAnchor for every mutation."
        )
    }

    func testPersistedIdentityUniqueCellRejectsCrossSigningIdentityMappingBeforeReadiness() async throws {
        let resolver = CellResolver.sharedInstance
        await resolver.resetRuntimeStateForTesting()

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-owner-isolation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver
        CellBase.persistedCellMasterKey = Data(repeating: 0x51, count: 32)
        CellBase.documentRootPath = tempRoot.appendingPathComponent("CellsContainer").path

        let resolvedOwnerA = await vault.identity(for: "owner-a", makeNewIfNotFound: true)
        let resolvedOwnerB = await vault.identity(for: "owner-b", makeNewIfNotFound: true)
        let ownerA = try XCTUnwrap(resolvedOwnerA)
        let ownerB = try XCTUnwrap(resolvedOwnerB)
        let name = "PersistedIdentityOwnerIsolation-\(UUID().uuidString)"

        let firstUtility = TypedCellUtility(storage: FileSystemCellStorage())
        resolver.tcUtility = firstUtility
        CellBase.typedCellUtility = firstUtility
        try await resolver.addCellResolve(
            name: name,
            cellScope: .identityUnique,
            persistency: .persistant,
            identityDomain: "owner-a",
            type: GeneralCell.self
        )
        let ownerACell = try await resolver.cellAtEndpoint(
            endpoint: "cell:///\(name)",
            requester: ownerA
        )

        let copiedPublicDescriptor = ownerA.publicIdentitySnapshot()
        await XCTAssertThrowsErrorAsync {
            _ = try await resolver.cellAtEndpoint(
                endpoint: "cell:///\(name)",
                requester: copiedPublicDescriptor
            )
        }
        let ownerAAfterCopiedLiveAttempt = try await resolver.cellAtEndpoint(
            endpoint: "cell:///\(name)",
            requester: ownerA
        )
        XCTAssertEqual(ownerAAfterCopiedLiveAttempt.uuid, ownerACell.uuid)

        let resolvedOtherKeyOwner = await vault.identity(
            for: "other-signing-key",
            makeNewIfNotFound: true
        )
        let otherKeyOwner = try XCTUnwrap(resolvedOtherKeyOwner)
        let sameUUIDDifferentKey = Identity(
            ownerA.uuid,
            displayName: "same UUID, different signing key",
            identityVault: vault
        )
        sameUUIDDifferentKey.publicSecureKey = otherKeyOwner.publicSecureKey
        await XCTAssertThrowsErrorAsync {
            _ = try await resolver.cellAtEndpoint(
                endpoint: "cell:///\(name)",
                requester: sameUUIDDifferentKey
            )
        }
        let ownerAAfterWrongKeyLiveAttempt = try await resolver.cellAtEndpoint(
            endpoint: "cell:///\(name)",
            requester: ownerA
        )
        XCTAssertEqual(ownerAAfterWrongKeyLiveAttempt.uuid, ownerACell.uuid)

        // Simulate stale/corrupt persisted resolver metadata assigning owner
        // A's Cell UUID to owner B, then start with a clean runtime.
        await resolver.resetRuntimeStateForTesting()
        let restartedUtility = TypedCellUtility(storage: FileSystemCellStorage())
        resolver.tcUtility = restartedUtility
        CellBase.typedCellUtility = restartedUtility
        try await resolver.addCellResolve(
            name: name,
            cellScope: .identityUnique,
            persistency: .persistant,
            identityDomain: "owner-a",
            type: GeneralCell.self
        )
        await resolver.setIdentityNamedCells(
            [ownerB.uuid: [name: ownerACell.uuid]],
            requester: ownerB
        )

        let ownerBCell = try await resolver.cellAtEndpoint(
            endpoint: "cell:///\(name)",
            requester: ownerB
        )
        let restoredOwner = try await ownerBCell.getOwner(requester: ownerB)

        XCTAssertNotEqual(ownerACell.uuid, ownerBCell.uuid)
        XCTAssertTrue(restoredOwner.referencesSameSigningIdentity(as: ownerB))

        await resolver.resetRuntimeStateForTesting()
        let forgedAttemptUtility = TypedCellUtility(storage: FileSystemCellStorage())
        resolver.tcUtility = forgedAttemptUtility
        CellBase.typedCellUtility = forgedAttemptUtility
        try await resolver.addCellResolve(
            name: name,
            cellScope: .identityUnique,
            persistency: .persistant,
            identityDomain: "owner-a",
            type: GeneralCell.self
        )
        await resolver.setIdentityNamedCells(
            [ownerA.uuid: [name: ownerACell.uuid]],
            requester: ownerA
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await resolver.cellAtEndpoint(
                endpoint: "cell:///\(name)",
                requester: copiedPublicDescriptor
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await resolver.cellAtEndpoint(
                endpoint: "cell:///\(name)",
                requester: sameUUIDDifferentKey
            )
        }
        let ownerAAfterRestartedAttacks = try await resolver.cellAtEndpoint(
            endpoint: "cell:///\(name)",
            requester: ownerA
        )
        XCTAssertEqual(
            ownerAAfterRestartedAttacks.uuid,
            ownerACell.uuid,
            "Denied public-descriptor and signing-key-collision attempts must preserve the legitimate persisted mapping."
        )
    }

    func testIdentityMappingSurvivesAmbiguousPersistenceFailureButReplacesExplicitlyMissingRecord() async throws {
        let resolver = CellResolver.sharedInstance
        await resolver.resetRuntimeStateForTesting()
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver
        let resolvedOwner = await vault.identity(for: "storage-failure-owner", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(resolvedOwner)
        let name = "StorageFailure-\(UUID().uuidString)"
        let mappedUUID = UUID().uuidString

        try await resolver.addCellResolve(
            name: name,
            cellScope: .identityUnique,
            identityDomain: "storage-failure-owner",
            type: GeneralCell.self
        )
        await resolver.setIdentityNamedCells(
            [owner.uuid: [name: mappedUUID]],
            requester: owner
        )
        CellBase.typedCellUtility = StatusDecodedCellUtility(result: .unavailable)

        await XCTAssertThrowsErrorAsync {
            _ = try await resolver.cellAtEndpoint(
                endpoint: "cell:///\(name)",
                requester: owner
            )
        }
        var mappings = await resolver.identityNamedCells(requester: owner)
        XCTAssertEqual(mappings[owner.uuid]?[name], mappedUUID)

        CellBase.typedCellUtility = StatusDecodedCellUtility(result: .missing)
        let replacement = try await resolver.cellAtEndpoint(
            endpoint: "cell:///\(name)",
            requester: owner
        )
        mappings = await resolver.identityNamedCells(requester: owner)
        XCTAssertNotEqual(replacement.uuid, mappedUUID)
        XCTAssertEqual(mappings[owner.uuid]?[name], replacement.uuid)
    }

    func testScaffoldMappingSurvivesUnavailableEncryptedPersistenceWithoutReplacement() async throws {
        let resolver = CellResolver.sharedInstance
        await resolver.resetRuntimeStateForTesting()
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver
        let resolvedOwner = await vault.identity(
            for: "shared-storage-failure-owner",
            makeNewIfNotFound: true
        )
        let owner = try XCTUnwrap(resolvedOwner)
        let name = "SharedStorageFailure-\(UUID().uuidString)"
        let mappedUUID = UUID().uuidString
        let registrationUtility = TypedCellUtility(storage: ResolverTestCellStorage())
        resolver.tcUtility = registrationUtility

        try await resolver.addCellResolve(
            name: name,
            cellScope: .scaffoldUnique,
            persistency: .persistant,
            identityDomain: "shared-storage-failure-owner",
            type: GeneralCell.self
        )
        await resolver.setNamedCells([name: mappedUUID], requester: owner)
        CellBase.typedCellUtility = StatusDecodedCellUtility(result: .unavailable)

        await XCTAssertThrowsErrorAsync {
            _ = try await resolver.cellAtEndpoint(
                endpoint: "cell:///\(name)",
                requester: owner
            )
        }
        let mappings = await resolver.namedCells(requester: owner)
        XCTAssertEqual(
            mappings[name],
            mappedUUID,
            "Unreadable encrypted persistence must not be replaced with a fresh shared Cell."
        )
    }

    func testConcurrentOwnerScopedMappingReplacementPreservesEveryOwner() async throws {
        let resolver = CellResolver.sharedInstance
        await resolver.resetRuntimeStateForTesting()
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let resolvedOwnerA = await vault.identity(for: "map-owner-a", makeNewIfNotFound: true)
        let resolvedOwnerB = await vault.identity(for: "map-owner-b", makeNewIfNotFound: true)
        let ownerA = try XCTUnwrap(resolvedOwnerA)
        let ownerB = try XCTUnwrap(resolvedOwnerB)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await resolver.replaceIdentityNamedCells(
                    ["OwnerAEndpoint": "owner-a-cell"],
                    requester: ownerA
                )
            }
            group.addTask {
                try await resolver.replaceIdentityNamedCells(
                    ["OwnerBEndpoint": "owner-b-cell"],
                    requester: ownerB
                )
            }
            try await group.waitForAll()
        }

        let mappings = await resolver.identityNamedCells(requester: ownerA)
        XCTAssertEqual(mappings[ownerA.uuid]?["OwnerAEndpoint"], "owner-a-cell")
        XCTAssertEqual(mappings[ownerB.uuid]?["OwnerBEndpoint"], "owner-b-cell")

        await XCTAssertThrowsErrorAsync {
            try await resolver.replaceIdentityNamedCells(
                ["Forged": "forged-cell"],
                requester: ownerA.publicIdentitySnapshot()
            )
        }
        let mappingsAfterDenial = await resolver.identityNamedCells(requester: ownerA)
        XCTAssertNil(mappingsAfterDenial[ownerA.uuid]?["Forged"])
    }

    func testAtomicIdentityRestoreFillsGapsWithoutLosingConcurrentLiveRegistration() async throws {
        let auditor = ResolverAuditor()
        let owner = Identity(
            "atomic-restore-owner",
            displayName: "Atomic Restore Owner",
            identityVault: nil
        )
        let existing = TestEmitCell(owner: owner, uuid: "existing-live-cell")
        let concurrent = TestEmitCell(owner: owner, uuid: "concurrent-live-cell")
        try await auditor.registerPersonalReference(
            existing,
            endpoint: "Existing",
            identity: owner
        )

        async let restored = auditor.restoreIdentityNamedCellsFillingGaps([
            owner.uuid: [
                "Existing": "stale-persisted-cell",
                "RestoredOnly": "restored-cell"
            ]
        ])
        async let registered: Void = auditor.registerPersonalReference(
            concurrent,
            endpoint: "Concurrent",
            identity: owner
        )
        _ = await restored
        try await registered

        let mappings = await auditor.identityNamedCells()
        XCTAssertEqual(mappings[owner.uuid]?["Existing"], existing.uuid)
        XCTAssertEqual(mappings[owner.uuid]?["Concurrent"], concurrent.uuid)
        XCTAssertEqual(mappings[owner.uuid]?["RestoredOnly"], "restored-cell")
    }

    func testResolverRecoveryRequiresRequesterSigningControl() async throws {
        let resolver = CellResolver.sharedInstance
        await resolver.resetRuntimeStateForTesting()
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let resolvedOwner = await vault.identity(for: "mapping-recovery-owner", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(resolvedOwner)
        let restored = [
            "persisted-owner": ["Recovered": "persisted-cell"]
        ]

        await XCTAssertThrowsErrorAsync {
            _ = try await resolver.restoreIdentityNamedCellsFillingGaps(
                restored,
                requester: owner.publicIdentitySnapshot(),
                authorization: CellResolverRecoveryAuthorization()
            )
        }

        let merged = try await resolver.restoreIdentityNamedCellsFillingGaps(
            restored,
            requester: owner,
            authorization: CellResolverRecoveryAuthorization()
        )
        XCTAssertEqual(merged["persisted-owner"]?["Recovered"], "persisted-cell")
    }

    func testUnsupportedSchemeThrows() async {
        let resolver = CellResolver.sharedInstance
        let identity = await CellBase.defaultIdentityVault?.identity(for: "private", makeNewIfNotFound: true)
        await XCTAssertThrowsErrorAsync {
            _ = try await resolver.cellAtEndpoint(endpoint: "http://example.com", requester: identity!)
        }
    }

    func testInvalidUrlThrows() async {
        let resolver = CellResolver.sharedInstance
        let identity = await CellBase.defaultIdentityVault?.identity(for: "private", makeNewIfNotFound: true)
        await XCTAssertThrowsErrorAsync {
            _ = try await resolver.cellAtEndpoint(endpoint: "://", requester: identity!)
        }
    }

    func testDuplicateResolveThrows() async throws {
        let resolver = CellResolver.sharedInstance
        let name = "Dup-\(UUID().uuidString)"
        try await resolver.addCellResolve(name: name, cellScope: .template, identityDomain: "private", type: GeneralCell.self)

        await XCTAssertThrowsErrorAsync {
            try await resolver.addCellResolve(name: name, cellScope: .template, identityDomain: "private", type: GeneralCell.self)
        }
    }

    func testAuditorThrowsInsteadOfCrashingForAlreadyRegisteredPersonalInstance() async throws {
        let auditor = ResolverAuditor()
        let identity = Identity("personal-auditor-owner", displayName: "Personal Auditor Owner", identityVault: nil)
        let cell = TestEmitCell(owner: identity, uuid: "personal-auditor-cell")
        try await auditor.registerReference(cell)

        do {
            try await auditor.registerPersonalReference(cell, endpoint: "PersonalCell", identity: identity)
            XCTFail("Expected personalInstanceAlreadyRegistered")
        } catch ResolverAuditor.AuditorError.personalInstanceAlreadyRegistered {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRegistrationWaitsForReadinessAndFailureNeverPublishesCell() async throws {
        let resolver = CellResolver.sharedInstance
        let resolvedOwner = await CellBase.defaultIdentityVault?.identity(
            for: "resolver-readiness",
            makeNewIfNotFound: true
        )
        let owner = try XCTUnwrap(resolvedOwner)
        let delayedName = "DelayedReadiness-\(UUID().uuidString)"
        let delayedCell = await ResolverReadinessProbeCell(owner: owner)
        let gate = ResolverReadinessGate()
        delayedCell.readinessGate = gate

        let registration = Task {
            try await resolver.registerNamedEmitCell(
                name: delayedName,
                emitCell: delayedCell,
                scope: .scaffoldUnique,
                identity: owner
            )
        }

        await gate.waitUntilInstallationStarts()
        let installedBeforeRelease = await delayedCell.readinessState.isInstalled()
        let publishedBeforeRelease = await resolver.cellUUID(for: delayedName)
        XCTAssertFalse(installedBeforeRelease)
        XCTAssertNil(
            publishedBeforeRelease,
            "A Cell must not be visible in the resolver while runtime bindings are still installing."
        )

        await gate.releaseInstallation()
        try await registration.value
        let installedAfterRelease = await delayedCell.readinessState.isInstalled()
        let publishedAfterRelease = await resolver.cellUUID(for: delayedName)
        XCTAssertTrue(installedAfterRelease)
        XCTAssertEqual(publishedAfterRelease, delayedCell.uuid)

        let failingName = "FailingReadiness-\(UUID().uuidString)"
        let failingCell = await ResolverReadinessProbeCell(owner: owner)
        failingCell.failInstallation = true
        do {
            try await resolver.registerNamedEmitCell(
                name: failingName,
                emitCell: failingCell,
                scope: .scaffoldUnique,
                identity: owner
            )
            XCTFail("Expected readiness failure")
        } catch ResolverReadinessProbeError.installationFailed {
            // Expected: registration must fail before resolver publication.
        }
        let failingPublishedUUID = await resolver.cellUUID(for: failingName)
        XCTAssertNil(failingPublishedUUID)

        await resolver.unregisterEmitCell(uuid: delayedCell.uuid)
    }

    func testResolverPreparesFreshAndDecodedCellsBeforeReturningThem() async throws {
        let resolver = CellResolver.sharedInstance
        let resolvedOwner = await CellBase.defaultIdentityVault?.identity(
            for: "resolver-ready-return",
            makeNewIfNotFound: true
        )
        let owner = try XCTUnwrap(resolvedOwner)

        let templateName = "ReadyTemplate-\(UUID().uuidString)"
        try await resolver.addCellResolve(
            name: templateName,
            cellScope: .template,
            identityDomain: "resolver-ready-return",
            type: ResolverReadinessProbeCell.self
        )
        let resolvedFresh = try await resolver.cellAtEndpoint(
            endpoint: "cell:///\(templateName)",
            requester: owner
        )
        let fresh = try XCTUnwrap(resolvedFresh as? ResolverReadinessProbeCell)
        let freshInstalled = await fresh.readinessState.isInstalled()
        XCTAssertTrue(freshInstalled)

        let persistedSource = await ResolverReadinessProbeCell(owner: owner)
        let rawDecoded = try JSONDecoder().decode(
            ResolverReadinessProbeCell.self,
            from: JSONEncoder().encode(persistedSource)
        )
        let rawDecodedInstalled = await rawDecoded.readinessState.isInstalled()
        XCTAssertFalse(rawDecodedInstalled)
        CellBase.typedCellUtility = FixedDecodedCellUtility(cell: rawDecoded)

        let resolvedLoaded = try await resolver.loadTypedEmitCell(with: rawDecoded.uuid)
        let loaded = try XCTUnwrap(resolvedLoaded as? ResolverReadinessProbeCell)
        let loadedInstalled = await loaded.readinessState.isInstalled()
        XCTAssertTrue(
            loadedInstalled,
            "Resolver persistence APIs must not return a raw decoded Cell before runtime bindings are installed."
        )
        await resolver.unregisterEmitCell(uuid: loaded.uuid)
    }

    func testResolverHonorsExplicitReadRequirementForSideEffectFreeSetQuery() async throws {
        let resolver = CellResolver.sharedInstance
        let resolvedOwner = await CellBase.defaultIdentityVault?.identity(
            for: "resolver-operation-owner",
            makeNewIfNotFound: true
        )
        let resolvedReader = await CellBase.defaultIdentityVault?.identity(
            for: "resolver-operation-reader",
            makeNewIfNotFound: true
        )
        let owner = try XCTUnwrap(resolvedOwner)
        let reader = try XCTUnwrap(resolvedReader)
        let cell = await ResolverOperationAuthorizationProbeCell(owner: owner)
        let name = "ReadOnlySetQuery-\(UUID().uuidString)"
        try await resolver.registerNamedEmitCell(
            name: name,
            emitCell: cell,
            scope: .scaffoldUnique,
            identity: owner
        )
        defer { Task { await resolver.unregisterEmitCell(uuid: cell.uuid) } }

        let agreement = Agreement(owner: owner)
        agreement.addGrant("r---", for: "query")
        let agreementState = await cell.addAgreement(
            agreement,
            for: reader,
            authorizedBy: owner
        )
        XCTAssertEqual(agreementState, .signed)

        let queryURL = try XCTUnwrap(URL(string: "cell:///\(name)/query"))
        let result = try await resolver.set(
            value: .object(["selector": .string("known")]),
            into: queryURL,
            requester: reader
        )
        XCTAssertEqual(result, .string("query:known"))

        let directResult = try await cell.set(
            keypath: "query",
            value: .object(["selector": .string("direct")]),
            requester: reader
        )
        XCTAssertEqual(directResult, .string("query:direct"))

        let resolvedOutsider = await CellBase.defaultIdentityVault?.identity(
            for: "resolver-operation-outsider",
            makeNewIfNotFound: true
        )
        let outsider = try XCTUnwrap(resolvedOutsider)
        for invoke in [
            { try await resolver.set(
                value: .object(["selector": .string("resolver-outsider")]),
                into: queryURL,
                requester: outsider
            ) },
            { try await cell.set(
                keypath: "query",
                value: .object(["selector": .string("direct-outsider")]),
                requester: outsider
            ) },
        ] {
            do {
                _ = try await invoke()
                XCTFail("A requester without a read Contract must not execute the SET query")
            } catch let CellAuthorizationError.denied(decision) {
                XCTAssertEqual(decision.path, .deniedNoGrant)
                XCTAssertEqual(decision.request.requestedAccess, "r---")
            }
        }

        let mutationURL = try XCTUnwrap(URL(string: "cell:///\(name)/mutate"))
        do {
            _ = try await resolver.set(value: .bool(true), into: mutationURL, requester: reader)
            XCTFail("A read Contract must not authorize a mutating SET operation")
        } catch let CellAuthorizationError.denied(decision) {
            XCTAssertEqual(decision.path, .deniedNoGrant)
            XCTAssertEqual(decision.request.requestedAccess, "-w--")
        }
        let wasMutated = await cell.state.wasMutated()
        XCTAssertFalse(wasMutated)
    }

    func testDirectAndResolverGetHonorStrengthenedOperationRequirement() async throws {
        let resolver = CellResolver.sharedInstance
        let resolvedOwner = await CellBase.defaultIdentityVault?.identity(
            for: "resolver-operation-get-owner",
            makeNewIfNotFound: true
        )
        let resolvedPrivilegedReader = await CellBase.defaultIdentityVault?.identity(
            for: "resolver-operation-get-privileged-reader",
            makeNewIfNotFound: true
        )
        let resolvedBasicReader = await CellBase.defaultIdentityVault?.identity(
            for: "resolver-operation-get-basic-reader",
            makeNewIfNotFound: true
        )
        let owner = try XCTUnwrap(resolvedOwner)
        let privilegedReader = try XCTUnwrap(resolvedPrivilegedReader)
        let basicReader = try XCTUnwrap(resolvedBasicReader)
        let cell = await ResolverOperationAuthorizationProbeCell(owner: owner)
        let name = "StrengthenedGet-\(UUID().uuidString)"
        try await resolver.registerNamedEmitCell(
            name: name,
            emitCell: cell,
            scope: .scaffoldUnique,
            identity: owner
        )
        defer { Task { await resolver.unregisterEmitCell(uuid: cell.uuid) } }

        let privilegedAgreement = Agreement(owner: owner)
        privilegedAgreement.addGrant("r--s", for: "sensitive")
        let privilegedAgreementState = await cell.addAgreement(
            privilegedAgreement,
            for: privilegedReader,
            authorizedBy: owner
        )
        XCTAssertEqual(privilegedAgreementState, .signed)

        let basicAgreement = Agreement(owner: owner)
        basicAgreement.addGrant("r---", for: "sensitive")
        let basicAgreementState = await cell.addAgreement(
            basicAgreement,
            for: basicReader,
            authorizedBy: owner
        )
        XCTAssertEqual(basicAgreementState, .signed)

        let sensitiveURL = try XCTUnwrap(URL(string: "cell:///\(name)/sensitive"))
        let resolverResult = try await resolver.get(from: sensitiveURL, requester: privilegedReader)
        XCTAssertEqual(resolverResult, .string("sensitive"))
        let directResult = try await cell.get(keypath: "sensitive", requester: privilegedReader)
        XCTAssertEqual(directResult, .string("sensitive"))

        for invoke in [
            { try await resolver.get(from: sensitiveURL, requester: basicReader) },
            { try await cell.get(keypath: "sensitive", requester: basicReader) },
        ] {
            do {
                _ = try await invoke()
                XCTFail("A basic read Contract must not satisfy a strengthened GET requirement")
            } catch let CellAuthorizationError.denied(decision) {
                XCTAssertEqual(decision.path, .deniedNoGrant)
                XCTAssertEqual(decision.request.requestedAccess, "r--s")
            }
        }
    }

    func testResolverFailsClosedForInvalidOrUndeclaredOperationRequirement() async throws {
        let resolver = CellResolver.sharedInstance
        let resolvedOwner = await CellBase.defaultIdentityVault?.identity(
            for: "resolver-operation-mismatch-owner",
            makeNewIfNotFound: true
        )
        let owner = try XCTUnwrap(resolvedOwner)

        let mismatchCell = await ResolverOperationAuthorizationProbeCell(owner: owner)
        mismatchCell.declaredQueryPermissions = ["-w--"]
        mismatchCell.queryRequirement = "r---"
        let mismatchName = "MismatchedSetQuery-\(UUID().uuidString)"
        try await resolver.registerNamedEmitCell(
            name: mismatchName,
            emitCell: mismatchCell,
            scope: .scaffoldUnique,
            identity: owner
        )
        defer { Task { await resolver.unregisterEmitCell(uuid: mismatchCell.uuid) } }

        do {
            _ = try await resolver.set(
                value: .object(["selector": .string("known")]),
                into: try XCTUnwrap(URL(string: "cell:///\(mismatchName)/query")),
                requester: owner
            )
            XCTFail("Resolver must reject a requirement missing from the Explore contract")
        } catch let error as MeddleOperationAuthorizationRequirementError {
            XCTAssertEqual(
                error,
                .permissionNotDeclared(permission: "r---", method: "set", keypath: "query")
            )
        }

        let multiPermissionCell = await ResolverOperationAuthorizationProbeCell(owner: owner)
        multiPermissionCell.declaredQueryPermissions = ["r---", "-w--"]
        let multiPermissionName = "MultiPermissionSetQuery-\(UUID().uuidString)"
        try await resolver.registerNamedEmitCell(
            name: multiPermissionName,
            emitCell: multiPermissionCell,
            scope: .scaffoldUnique,
            identity: owner
        )
        defer { Task { await resolver.unregisterEmitCell(uuid: multiPermissionCell.uuid) } }

        do {
            _ = try await resolver.set(
                value: .object(["selector": .string("known")]),
                into: try XCTUnwrap(URL(string: "cell:///\(multiPermissionName)/query")),
                requester: owner
            )
            XCTFail("Resolver must reject ambiguous multi-permission operation Contracts")
        } catch let error as MeddleOperationAuthorizationRequirementError {
            XCTAssertEqual(
                error,
                .permissionNotDeclared(permission: "r---", method: "set", keypath: "query")
            )
        }

        let missingSetContractCell = await ResolverOperationAuthorizationProbeCell(owner: owner)
        missingSetContractCell.registerQuerySetContract = false
        missingSetContractCell.registerQueryGetContract = true
        let missingSetContractName = "MissingSetContractQuery-\(UUID().uuidString)"
        try await resolver.registerNamedEmitCell(
            name: missingSetContractName,
            emitCell: missingSetContractCell,
            scope: .scaffoldUnique,
            identity: owner
        )
        defer { Task { await resolver.unregisterEmitCell(uuid: missingSetContractCell.uuid) } }

        do {
            _ = try await resolver.set(
                value: .object(["selector": .string("known")]),
                into: try XCTUnwrap(URL(string: "cell:///\(missingSetContractName)/query")),
                requester: owner
            )
            XCTFail("A GET Contract must not satisfy a missing SET Contract")
        } catch let error as MeddleOperationAuthorizationRequirementError {
            XCTAssertEqual(
                error,
                .missingExploreContract(method: "set", keypath: "query")
            )
        }

        let invalidCell = await ResolverOperationAuthorizationProbeCell(owner: owner)
        invalidCell.queryRequirement = "read"
        let invalidName = "InvalidSetQuery-\(UUID().uuidString)"
        try await resolver.registerNamedEmitCell(
            name: invalidName,
            emitCell: invalidCell,
            scope: .scaffoldUnique,
            identity: owner
        )
        defer { Task { await resolver.unregisterEmitCell(uuid: invalidCell.uuid) } }

        do {
            _ = try await resolver.set(
                value: .object(["selector": .string("known")]),
                into: try XCTUnwrap(URL(string: "cell:///\(invalidName)/query")),
                requester: owner
            )
            XCTFail("Resolver must reject a non-canonical operation requirement")
        } catch let error as MeddleOperationAuthorizationRequirementError {
            XCTAssertEqual(error, .invalidPermission("read"))
        }
    }

    func testScopedSecretProviderSeedsPersistedCellMasterKeyBeforeLegacyVaultAPI() async throws {
#if canImport(CellVapor)
        let resolver = CellResolver.sharedInstance
        let secretSeed = Data(repeating: 0x42, count: 48)
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-secret-provider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let countingVault = CountingLegacyKeyVault()
        CellBase.defaultIdentityVault = countingVault
        CellBase.defaultScopedSecretProvider = FixedScopedSecretProvider(secretData: secretSeed)
        CellBase.persistedCellMasterKey = nil
        CellBase.documentRootPath = tempRoot.appendingPathComponent("CellsContainer").path
        resolver.tcUtility = TypedCellUtility(storage: FileSystemCellStorage())

        let name = "Persisted-\(UUID().uuidString)"
        try await resolver.addCellResolve(
            name: name,
            cellScope: .scaffoldUnique,
            persistency: .persistant,
            identityDomain: "private",
            type: GeneralCell.self
        )

        guard let identity = await countingVault.identity(for: "private", makeNewIfNotFound: true) else {
            XCTFail("Expected test vault identity")
            return
        }
        _ = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identity)

        let expected = Data(SHA256.hash(data: secretSeed))
        XCTAssertEqual(CellBase.persistedCellMasterKey, expected)
        let acquireCallCount = await countingVault.acquireCallCount
        XCTAssertEqual(acquireCallCount, 0)
#else
        throw XCTSkip("CellVapor-backed file storage is unavailable in this test environment")
#endif
    }

    func testEncryptedPersistedLoadRestoresScopedMasterKeyAfterProcessReset() async throws {
#if canImport(CellVapor)
        let resolver = CellResolver.sharedInstance
        let secretSeed = Data(repeating: 0x63, count: 48)
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-cold-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultScopedSecretProvider = FixedScopedSecretProvider(secretData: secretSeed)
        CellBase.documentRootPath = tempRoot.appendingPathComponent("CellsContainer").path
        let utility = TypedCellUtility(storage: FileSystemCellStorage())
        try utility.register(name: "GeneralCell", type: GeneralCell.self)
        resolver.tcUtility = utility
        CellBase.typedCellUtility = utility

        let resolvedOwner = await vault.identity(for: "private", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(resolvedOwner)
        let source = await GeneralCell(owner: owner)
        source.cellScope = .scaffoldUnique
        source.persistancy = .persistant
        CellBase.configurePersistedCellMasterKey(seedData: secretSeed)
        utility.storeAsTypedCell(
            cellName: "GeneralCell",
            cell: source,
            uuid: source.uuid,
            options: CellStorageWriteOptions(
                ownerIdentityUUID: owner.uuid,
                encryptedAtRestRequired: true
            )
        )

        let persistedURL = tempRoot
            .appendingPathComponent("CellsContainer")
            .appendingPathComponent(source.uuid)
            .appendingPathComponent("typedCell.json")
        XCTAssertTrue(
            CellPersistenceCrypto.isEncryptedEnvelope(try Data(contentsOf: persistedURL))
        )

        // Simulate a new process: the in-memory key is gone, while the scoped
        // provider and encrypted container remain.
        CellBase.persistedCellMasterKey = nil
        let restored = try await resolver.loadTypedEmitCell(with: source.uuid)
        let loaded = try XCTUnwrap(restored as? GeneralCell)
        XCTAssertEqual(
            CellBase.persistedCellMasterKey,
            Data(SHA256.hash(data: secretSeed))
        )
        let loadedOwner = try await loaded.getOwner(requester: owner)
        XCTAssertEqual(loadedOwner.uuid, owner.uuid)
        _ = try await loaded.keys(requester: owner)
#else
        throw XCTSkip("CellVapor-backed file storage is unavailable in this test environment")
#endif
    }
}

private actor IdentityEntityAnchorProbeState {
    private var values: [String: ValueType] = [:]

    func set(_ value: ValueType, for keypath: String) {
        values[keypath] = value
    }

    func value(for keypath: String) -> ValueType? {
        values[keypath]
    }
}

private final class IdentityEntityAnchorProbeCell: GeneralCell {
    private let probeState = IdentityEntityAnchorProbeState()

    required init(owner: Identity) async {
        await super.init(owner: owner)
    }

    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }

    func installProbeBindings(owner: Identity) async {
        await registerExploreContract(
            requester: owner,
            key: "proofs",
            method: .set,
            input: ExploreContract.schema(type: "string"),
            returns: .null
        )
        await addInterceptForSet(requester: owner, key: "proofs") { [probeState] keypath, value, _ in
            await probeState.set(value, for: keypath)
            return nil
        }
    }

    func recordedValue(for keypath: String) async -> ValueType? {
        await probeState.value(for: keypath)
    }
}

private actor FixedScopedSecretProvider: ScopedSecretProviderProtocol {
    let secretData: Data

    init(secretData: Data) {
        self.secretData = secretData
    }

    func scopedSecretData(tag: String, minimumLength: Int) async throws -> Data {
        if secretData.count >= minimumLength {
            return secretData
        }
        return secretData + Data(repeating: 0x00, count: minimumLength - secretData.count)
    }
}

private enum ResolverReadinessProbeError: Error {
    case installationFailed
}

private actor ResolverReadinessState {
    private var installed = false

    func markInstalled() {
        installed = true
    }

    func isInstalled() -> Bool {
        installed
    }
}

private actor ResolverReadinessGate {
    private var installationStarted = false
    private var installationReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilInstallationStarts() async {
        if installationStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func blockInstallationUntilReleased() async {
        installationStarted = true
        let pendingStartWaiters = startWaiters
        startWaiters.removeAll()
        pendingStartWaiters.forEach { $0.resume() }

        if installationReleased { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func releaseInstallation() {
        installationReleased = true
        let pendingReleaseWaiters = releaseWaiters
        releaseWaiters.removeAll()
        pendingReleaseWaiters.forEach { $0.resume() }
    }
}

private final class ResolverReadinessProbeCell: GeneralCell {
    let readinessState = ResolverReadinessState()
    var readinessGate: ResolverReadinessGate?
    var failInstallation = false

    required init(owner: Identity) async {
        await super.init(owner: owner)
    }

    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }

    override func installCellRuntimeBindingsForAccess() async throws {
        if failInstallation {
            throw ResolverReadinessProbeError.installationFailed
        }
        if let readinessGate {
            await readinessGate.blockInstallationUntilReleased()
        }
        await readinessState.markInstalled()
    }
}

private actor ResolverOperationAuthorizationProbeState {
    private var mutated = false

    func markMutated() {
        mutated = true
    }

    func wasMutated() -> Bool {
        mutated
    }
}

private final class ResolverOperationAuthorizationProbeCell:
    GeneralCell,
    MeddleOperationAuthorizationRequirementProviding
{
    let state = ResolverOperationAuthorizationProbeState()
    var queryRequirement: String? = "r---"
    var sensitiveGetRequirement: String? = "r--s"
    var declaredQueryPermissions = ["r---"]
    var registerQuerySetContract = true
    var registerQueryGetContract = false

    required init(owner: Identity) async {
        await super.init(owner: owner)
    }

    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }

    override func installCellRuntimeBindingsForAccess() async throws {
        let owner = storedOwnerIdentity
        for permission in declaredQueryPermissions {
            agreementTemplate.addGrant(permission, for: "query")
        }
        agreementTemplate.addGrant("-w--", for: "mutate")
        agreementTemplate.addGrant("r--s", for: "sensitive")
        if registerQuerySetContract {
            await registerSet(
                key: "query",
                owner: owner,
                input: ExploreContract.objectSchema(
                    properties: ["selector": ExploreContract.schema(type: "string")],
                    requiredKeys: ["selector"]
                ),
                returns: ExploreContract.schema(type: "string"),
                permissions: declaredQueryPermissions,
                description: .string("Side-effect-free parameterized read probe.")
            ) { _, payload in
                guard case let .object(object) = payload,
                      case let .string(selector)? = object["selector"] else {
                    return .string("error: selector required")
                }
                return .string("query:\(selector)")
            }
        }
        if registerQueryGetContract {
            await registerGet(
                key: "query",
                owner: owner,
                returns: ExploreContract.schema(type: "string"),
                permissions: declaredQueryPermissions,
                description: .string("GET-only contract probe.")
            ) { _ in .string("get-only") }
        }
        await registerGet(
            key: "sensitive",
            owner: owner,
            returns: ExploreContract.schema(type: "string"),
            permissions: ["r--s"],
            description: .string("Strengthened GET authorization probe.")
        ) { _ in .string("sensitive") }
        await registerSet(
            key: "mutate",
            owner: owner,
            input: ExploreContract.schema(type: "bool"),
            returns: ExploreContract.schema(type: "bool"),
            permissions: ["-w--"],
            description: .string("Mutation probe.")
        ) { [weak self, state] requester, _ in
            guard let self,
                  await self.validateAccess("-w--", at: "mutate", for: requester) else {
                return .string("denied")
            }
            await state.markMutated()
            return .bool(true)
        }
    }

    func meddleAuthorizationRequirement(
        for method: ExploreContractMethod,
        keypath: String
    ) async throws -> String? {
        if method == .set && keypath == "query" {
            return queryRequirement
        }
        if method == .get && keypath == "sensitive" {
            return sensitiveGetRequirement
        }
        return nil
    }
}

private final class FixedDecodedCellUtility: TypedCellProtocol {
    private let cell: Emit?

    init(cell: Emit) {
        self.cell = cell
    }

    required init(storage: CellStorage) {
        cell = nil
    }

    func loadTypedEmitCell(with uuid: String) -> Emit? {
        cell?.uuid == uuid ? cell : nil
    }

    func loadTypedEmitCell(at path: String) -> Emit? {
        cell
    }

    func storeAsTypedCell(cellName: String, cell: Codable, uuid: String) {}

    func storeAsTypedCell(
        cellName: String,
        cell: Codable,
        uuid: String,
        options: CellStorageWriteOptions
    ) {}
}

private final class StatusDecodedCellUtility: TypedCellProtocol {
    private let result: TypedCellLoadResult

    init(result: TypedCellLoadResult) {
        self.result = result
    }

    required init(storage: CellStorage) {
        result = .unavailable
    }

    func loadTypedEmitCell(with uuid: String) -> Emit? {
        guard case .loaded(let cell) = result else { return nil }
        return cell
    }

    func loadTypedEmitCellResult(with uuid: String) -> TypedCellLoadResult {
        result
    }

    func loadTypedEmitCell(at path: String) -> Emit? { nil }
    func storeAsTypedCell(cellName: String, cell: Codable, uuid: String) {}
    func storeAsTypedCell(
        cellName: String,
        cell: Codable,
        uuid: String,
        options: CellStorageWriteOptions
    ) {}
}

private struct ResolverTestCellStorage: CellStorage {
    enum StorageError: Error {
        case unavailable
    }

    func loadEmitCell(with uuid: String, decoder: CellJSONCoder) throws -> Emit {
        throw StorageError.unavailable
    }

    func loadEmitCell(at path: String, decoder: CellJSONCoder) throws -> Emit {
        throw StorageError.unavailable
    }

    func storeCell(cellName: String, cell: Codable, uuid: String) throws {}
}

private actor CountingLegacyKeyVault: IdentityVaultProtocol {
    private var identitiesByContext: [String: Identity] = [:]
    private(set) var acquireCallCount = 0

    func initialize() async -> IdentityVaultProtocol {
        self
    }

    func addIdentity(identity: inout Identity, for identityContext: String) async {
        identity.identityVault = self
        identitiesByContext[identityContext] = identity
    }

    func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity? {
        if let existing = identitiesByContext[identityContext] {
            return existing
        }
        guard makeNewIfNotFound else {
            return nil
        }
        let identity = Identity(UUID().uuidString, displayName: identityContext, identityVault: self)
        identitiesByContext[identityContext] = identity
        return identity
    }

    func saveIdentity(_ identity: Identity) async {
        identitiesByContext[identity.displayName] = identity
    }

    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        messageData + Data(identity.uuid.utf8)
    }

    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool {
        signature == messageData + Data(identity.uuid.utf8)
    }

    func randomBytes64() async -> Data? {
        Data(repeating: 0x22, count: 64)
    }

    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) {
        acquireCallCount += 1
        return ("legacy-\(tag)", "legacy-iv-\(tag)")
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        // expected
    }
}
