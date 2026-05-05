// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class RealCellContractTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousDebugFlag = false

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = false
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.debugValidateAccessForEverything = previousDebugFlag
        super.tearDown()
    }

    func testCommonsResolverContractsIncludePermissionsAndRuntimeErrors() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let outsider = await vault.identity(for: "other", makeNewIfNotFound: true)!
        let cell = await CommonsResolverCell(owner: owner)

        _ = try await cell.set(
            keypath: "commons.configure.rootPath",
            value: .string(commonsRootPath()),
            requester: owner
        )

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "commons.resolve.keypath",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "oneOf",
            expectedReturnType: "oneOf"
        )
        try await CellContractHarness.assertPermissions(
            on: cell,
            key: "commons.resolve.keypath",
            requester: owner,
            expected: ["-w--"]
        )
        try await CellContractHarness.assertSetDenied(
            on: cell,
            key: "commons.resolve.keypath",
            input: .string("#/purposes"),
            requester: outsider
        )
        try await CellContractHarness.assertSetReportsError(
            on: cell,
            key: "commons.resolve.keypath",
            input: .object([:]),
            requester: owner,
            expectedOperation: "commons.resolve.keypath"
        )
    }

    func testCommonsTaxonomyContractCatalogProducesRAGReadyMarkdown() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await CommonsTaxonomyCell(owner: owner)

        _ = try await cell.set(
            keypath: "taxonomy.configure.rootPath",
            value: .string(commonsRootPath()),
            requester: owner
        )

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "taxonomy.validate.purposeTree",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "oneOf",
            expectedReturnType: "oneOf"
        )
        try await CellContractHarness.assertPermissions(
            on: cell,
            key: "taxonomy.validate.purposeTree",
            requester: owner,
            expected: ["-w--"]
        )

        let catalog = try await cell.exploreContractCatalog(requester: owner)
        let record = try XCTUnwrap(catalog.records.first { $0.key == "taxonomy.validate.purposeTree" })

        XCTAssertEqual(record.method, "set")
        XCTAssertTrue(record.markdown.contains("mandatory_purpose_term_ids"))
        XCTAssertTrue(record.markdown.contains("taxonomy.validate.purposeTree"))
        XCTAssertTrue(catalog.markdown.contains("## `taxonomy.validate.purposeTree`"))
    }

    func testCommonsTaxonomyVerificationRecordCombinesCatalogAndProbeReport() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await CommonsTaxonomyCell(owner: owner)

        _ = try await cell.set(
            keypath: "taxonomy.configure.rootPath",
            value: .string(commonsRootPath()),
            requester: owner
        )

        let report = ContractProbeReport(
            targetCell: "cell:///CommonsTaxonomy",
            startedAt: "2026-03-08T18:22:10Z",
            finishedAt: "2026-03-08T18:22:12Z",
            status: .failed,
            usedExpectedContracts: false,
            options: ContractProbeRunOptions(keys: ["taxonomy.validate.purposeTree"]),
            passedCount: 3,
            failedCount: 1,
            skippedCount: 0,
            assertions: [
                ContractProbeAssertionResult(
                    key: "taxonomy.validate.purposeTree",
                    phase: "flow.taxonomy.validate.completed",
                    status: .failed,
                    message: "Expected flow topic `taxonomy.validate.completed` at least 1 time(s), observed 0.",
                    expected: .integer(1),
                    observed: .integer(0)
                )
            ]
        )

        let verification = try await cell.exploreContractVerificationRecord(
            requester: owner,
            probeReport: report,
            targetEndpoint: "cell:///CommonsTaxonomy",
            targetLabel: "taxonomy"
        )

        XCTAssertEqual(verification.recordType, "cell_contract_verification")
        XCTAssertEqual(verification.repo, "CellProtocol")
        XCTAssertEqual(verification.cellType, "CommonsTaxonomyCell")
        XCTAssertEqual(verification.targetEndpoint, "cell:///CommonsTaxonomy")
        XCTAssertEqual(verification.targetLabel, "taxonomy")
        XCTAssertEqual(verification.verificationStatus, "failed")
        XCTAssertEqual(verification.lastVerifiedAt, "2026-03-08T18:22:12Z")
        XCTAssertEqual(verification.failedAssertionCount, 1)
        XCTAssertTrue(verification.hasRuntimeProbe)
        XCTAssertEqual(verification.contractVersion, ExploreContract.version)
        XCTAssertFalse(verification.contractItems.isEmpty)
        XCTAssertEqual(verification.failingAssertions.count, 1)
        XCTAssertEqual(verification.failingAssertions.first?.phase, "flow.taxonomy.validate.completed")
        XCTAssertTrue(verification.markdown.contains("# Cell Contract Verification"))
        XCTAssertTrue(verification.markdown.contains("## Declared Keys"))
        XCTAssertTrue(verification.markdown.contains("## Failing Assertions"))
        XCTAssertTrue(verification.markdown.contains("taxonomy.validate.purposeTree"))
        XCTAssertTrue(verification.markdown.contains("Failed assertions: 1"))

        let encoded = try JSONEncoder().encode(verification)
        let decoded = try JSONDecoder().decode(ContractProbeVerificationRecord.self, from: encoded)
        XCTAssertEqual(decoded.recordType, verification.recordType)
        XCTAssertEqual(decoded.failedAssertionCount, verification.failedAssertionCount)
        XCTAssertEqual(decoded.contractItems.count, verification.contractItems.count)
    }

    func testCommonsTaxonomyVerificationRecordProducesRAGChunks() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await CommonsTaxonomyCell(owner: owner)

        _ = try await cell.set(
            keypath: "taxonomy.configure.rootPath",
            value: .string(commonsRootPath()),
            requester: owner
        )

        let report = ContractProbeReport(
            targetCell: "cell:///CommonsTaxonomy",
            startedAt: "2026-03-08T18:22:10Z",
            finishedAt: "2026-03-08T18:22:12Z",
            status: .failed,
            usedExpectedContracts: false,
            options: ContractProbeRunOptions(keys: ["taxonomy.validate.purposeTree"]),
            passedCount: 3,
            failedCount: 1,
            skippedCount: 0,
            assertions: [
                ContractProbeAssertionResult(
                    key: "taxonomy.validate.purposeTree",
                    phase: "flow.taxonomy.validate.completed",
                    status: .failed,
                    message: "Expected flow topic `taxonomy.validate.completed` at least 1 time(s), observed 0.",
                    expected: .integer(1),
                    observed: .integer(0)
                )
            ]
        )

        let chunks = try await cell.exploreContractVerificationChunks(
            requester: owner,
            probeReport: report,
            targetEndpoint: "cell:///CommonsTaxonomy",
            targetLabel: "taxonomy"
        )

        XCTAssertFalse(chunks.isEmpty)

        let summaryChunk = try XCTUnwrap(chunks.first { $0.documentKind == "summary" })
        XCTAssertEqual(summaryChunk.repo, "CellProtocol")
        XCTAssertEqual(summaryChunk.targetEndpoint, "cell:///CommonsTaxonomy")
        XCTAssertEqual(summaryChunk.verifiedAt, "2026-03-08T18:22:12Z")
        XCTAssertTrue(summaryChunk.content.contains("Declared key count"))

        let keyChunk = try XCTUnwrap(chunks.first { $0.documentKind == "key_contract" && $0.key == "taxonomy.validate.purposeTree" })
        XCTAssertEqual(keyChunk.status, "failed")
        XCTAssertTrue(keyChunk.content.contains("mandatory_purpose_term_ids"))

        let failedChunk = try XCTUnwrap(chunks.first {
            $0.documentKind == "failed_assertion" &&
            $0.key == "taxonomy.validate.purposeTree" &&
            $0.phase == "flow.taxonomy.validate.completed"
        })
        XCTAssertEqual(failedChunk.status, "failed")
        XCTAssertTrue(failedChunk.content.contains("Expected flow topic"))

        let flowGroupChunk = try XCTUnwrap(chunks.first {
            $0.documentKind == "flow_assertion_group" &&
            $0.key == "taxonomy.validate.purposeTree"
        })
        XCTAssertEqual(flowGroupChunk.phase, "flow")
        XCTAssertEqual(flowGroupChunk.status, "failed")
        XCTAssertTrue(flowGroupChunk.content.contains("flow.taxonomy.validate.completed"))

        let encoded = try JSONEncoder().encode(chunks)
        let decoded = try JSONDecoder().decode([ContractProbeVerificationChunk].self, from: encoded)
        XCTAssertEqual(decoded.count, chunks.count)
        XCTAssertTrue(decoded.contains(where: { $0.documentKind == "summary" }))
    }

    func testExploreManifestIncludesDeclaredPurposeAndAdvertisedOperations() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await CommonsTaxonomyCell(owner: owner)

        _ = try await cell.set(
            keypath: "taxonomy.configure.rootPath",
            value: .string(commonsRootPath()),
            requester: owner
        )

        let manifest = try await cell.exploreManifest(requester: owner)
        XCTAssertEqual(manifest.manifestVersion, ExploreManifest.version)
        XCTAssertEqual(manifest.contractVersion, ExploreContract.version)
        XCTAssertEqual(manifest.cellType, "CommonsTaxonomyCell")
        XCTAssertEqual(manifest.cellUUID, cell.uuid)
        XCTAssertEqual(manifest.identityDomain, "private")
        XCTAssertEqual(manifest.intent.purposeRefs, ["purpose.commons-taxonomy-governance"])
        XCTAssertTrue(manifest.intent.capabilityHints.contains("taxonomy.resolve.term"))
        XCTAssertTrue(manifest.intent.capabilityHints.contains("taxonomy.validate.purposeTree"))

        let operation = try XCTUnwrap(manifest.operations.first { $0.key == "taxonomy.validate.purposeTree" })
        XCTAssertEqual(operation.method, "set")
        XCTAssertEqual(operation.permissions, ["-w--"])
        XCTAssertEqual(operation.inputType, "oneOf")
        XCTAssertEqual(operation.returnType, "oneOf")
        XCTAssertTrue(manifest.markdown.contains("Declared purposes: `purpose.commons-taxonomy-governance`"))
        XCTAssertTrue(manifest.markdown.contains("## `taxonomy.validate.purposeTree`"))

        let advertised = await cell.advertise(for: owner)
        let advertisedManifest = try XCTUnwrap(advertised.exploreManifest)
        XCTAssertEqual(advertisedManifest.intent.purposeRefs, manifest.intent.purposeRefs)
        XCTAssertEqual(advertisedManifest.operations.count, manifest.operations.count)

        let encoded = try JSONEncoder().encode(advertised)
        let decoded = try JSONDecoder().decode(AnyCell.self, from: encoded)
        XCTAssertEqual(decoded.exploreManifest?.intent.purposeRefs, ["purpose.commons-taxonomy-governance"])
    }

    func testEntityAtlasInspectorContractsAdvertiseCoverageAndExportKeys() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let outsider = await vault.identity(for: "other", makeNewIfNotFound: true)!
        let cell = await EntityAtlasInspectorCell(owner: owner)

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "atlas.query.coverage",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "oneOf",
            expectedReturnType: "oneOf"
        )
        try await CellContractHarness.assertPermissions(
            on: cell,
            key: "atlas.export.redactedJSON",
            requester: owner,
            expected: ["-w--"]
        )
        try await CellContractHarness.assertSetDenied(
            on: cell,
            key: "atlas.query.coverage",
            input: .string("purpose.local-graph-index"),
            requester: outsider
        )
        try await CellContractHarness.assertSetReportsError(
            on: cell,
            key: "atlas.query.coverage",
            input: .object([:]),
            requester: owner,
            expectedOperation: "atlas.query.coverage"
        )
    }

    func testVaultContractsIncludeStructuredErrorsAndPermissionChecks() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let outsider = await vault.identity(for: "other", makeNewIfNotFound: true)!
        let cell = await VaultCell(owner: owner)

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "vault.note.create",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "oneOf",
            expectedReturnType: "oneOf"
        )
        try await CellContractHarness.assertPermissions(
            on: cell,
            key: "vault.note.create",
            requester: owner,
            expected: ["-w--"]
        )
        try await CellContractHarness.assertSetDenied(
            on: cell,
            key: "vault.note.create",
            input: .string("bad"),
            requester: outsider
        )
        try await CellContractHarness.assertSetReportsError(
            on: cell,
            key: "vault.note.create",
            input: .string("bad"),
            requester: owner,
            expectedOperation: "vault.note.create",
            expectedCode: "validation_error",
            messageContains: "Invalid payload"
        )
    }

    func testGraphContractsIncludeStructuredErrorsAndPermissionChecks() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let outsider = await vault.identity(for: "other", makeNewIfNotFound: true)!
        let cell = await GraphIndexCell(owner: owner)

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "graph.reindex",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "oneOf",
            expectedReturnType: "oneOf"
        )
        try await CellContractHarness.assertPermissions(
            on: cell,
            key: "graph.reindex",
            requester: owner,
            expected: ["-w--"]
        )
        try await CellContractHarness.assertSetDenied(
            on: cell,
            key: "graph.reindex",
            input: .string("bad"),
            requester: outsider
        )
        try await CellContractHarness.assertSetReportsError(
            on: cell,
            key: "graph.reindex",
            input: .string("bad"),
            requester: owner,
            expectedOperation: "graph.reindex",
            expectedCode: "validation_error",
            messageContains: "Expected payload with notes list"
        )
    }

    private func commonsRootPath() -> String {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("commons", isDirectory: true)
            .path
    }
}
