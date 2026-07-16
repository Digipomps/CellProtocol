// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase
@testable import CellVapor

final class VaporCellRuntimeReadinessContractTests: XCTestCase {
    func testVaporEntityAnchorPersistsVerifiedContractAndRejectsImmutableConflict() async throws {
        let previousVault = CellBase.defaultIdentityVault
        let previousDocumentRoot = CellBase.documentRootPath
        defer {
            CellBase.defaultIdentityVault = previousVault
            CellBase.documentRootPath = previousDocumentRoot
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellprotocol-signed-agreement-vapor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CellBase.documentRootPath = root.path
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let ownerCandidate = await vault.identity(for: "private", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(ownerCandidate)
        let entity = await EntityAnchorCell(owner: owner)

        let agreement = Agreement(owner: owner)
        agreement.name = "Owner agreement archive"
        agreement.conditions = []
        agreement.grants = [Grant(keypath: "document.body", permission: "r---")]
        let contract = try await Contract.ownerSignedSnapshot(
            agreement: agreement,
            signer: owner,
            domain: SignedAgreementEntitySupport.ownerEntityDomain(for: owner)
        )
        let contractObject = try SignedAgreementEntitySupport.contractObject(contract)
        let commit = try await entity.set(
            keypath: "signedAgreementEntity.commit",
            value: .object([
                "contract": .object(contractObject),
                "metadata": .object(["templateID": .string("owner-archive")])
            ]),
            requester: owner
        )

        guard case let .object(commitObject)? = commit,
              case .string("persisted")? = commitObject["status"],
              case let .object(receiptObject)? = commitObject["receipt"] else {
            return XCTFail("Expected persisted signed Agreement result, got \(String(describing: commit))")
        }
        let receipt = try SignedAgreementEntityCommitReceipt.from(object: receiptObject)
        XCTAssertTrue(receipt.verifySignature())
        XCTAssertEqual(receipt.recordID, contract.uuid)

        let stored = try await entity.get(
            keypath: "signedAgreementEntity.records.\(contract.uuid)",
            requester: owner
        )
        guard case let .object(storedRecord) = stored else {
            return XCTFail("Expected stored signed Agreement record")
        }
        XCTAssertEqual(storedRecord["signatureValidationState"], .string("verified"))
        XCTAssertEqual(storedRecord["counterpartySignatureState"], .string("not_present"))

        let repeatedPayload: ValueType = .object([
            "contract": .object(contractObject),
            "metadata": .object(["templateID": .string("owner-archive")])
        ])
        let repeatedResults = try await withThrowingTaskGroup(of: ValueType?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await entity.set(
                        keypath: "signedAgreementEntity.commit",
                        value: repeatedPayload,
                        requester: owner
                    )
                }
            }
            var results = [ValueType?]()
            for try await result in group {
                results.append(result)
            }
            return results
        }
        XCTAssertEqual(repeatedResults.count, 8)
        for result in repeatedResults {
            guard case let .object(resultObject)? = result else {
                return XCTFail("Expected serialized commit result")
            }
            XCTAssertEqual(resultObject["status"], .string("persisted"))
        }
        let storedReceipts = try await entity.get(
            keypath: "signedAgreementEntity.receipts",
            requester: owner
        )
        guard case let .object(receiptsObject) = storedReceipts else {
            return XCTFail("Expected signed Agreement commit receipts")
        }
        XCTAssertEqual(receiptsObject.count, 9)

        let conflict = try await entity.set(
            keypath: "signedAgreementEntity.commit",
            value: .object([
                "contract": .object(contractObject),
                "metadata": .object(["templateID": .string("mutated-after-commit")])
            ]),
            requester: owner
        )
        guard case let .object(conflictObject)? = conflict else {
            return XCTFail("Expected immutable conflict result")
        }
        XCTAssertEqual(conflictObject["status"], .string("conflict"))
        XCTAssertEqual(conflictObject["error"], .string("immutable_record_conflict"))
    }

    func testVaporDecodedCellsAreImmediatelyAndConcurrentlyReady() async throws {
        let previousVault = CellBase.defaultIdentityVault
        let previousResolver = CellBase.defaultCellResolver
        let previousDocumentRoot = CellBase.documentRootPath
        defer {
            CellBase.defaultIdentityVault = previousVault
            CellBase.defaultCellResolver = previousResolver
            CellBase.documentRootPath = previousDocumentRoot
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellprotocol-readiness-vapor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CellBase.documentRootPath = root.path
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let resolvedOwner = await vault.identity(for: "private", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(resolvedOwner)

        try await assertDecodedReadiness(
            await EntityAnchorCell(owner: owner),
            owner: owner,
            expectedKey: "person",
            requiredGrant: Grant(keypath: "person", permission: "rw--")
        )
        try await assertDecodedReadiness(
            await OrchestratorCell(owner: owner),
            owner: owner,
            expectedKey: "outwardMenu",
            requiredGrant: Grant(keypath: "skeleton", permission: "r---")
        )
    }

    func testVaporEntityAnchorAndOrchestratorDispatchAfterStrictDecode() async throws {
        let previousVault = CellBase.defaultIdentityVault
        let previousDocumentRoot = CellBase.documentRootPath
        let previousExploreMode = CellBase.exploreContractEnforcementMode
        defer {
            CellBase.defaultIdentityVault = previousVault
            CellBase.documentRootPath = previousDocumentRoot
            CellBase.exploreContractEnforcementMode = previousExploreMode
        }

        CellBase.exploreContractEnforcementMode = .strict
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellprotocol-strict-vapor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CellBase.documentRootPath = root.path
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let ownerCandidate = await vault.identity(for: "private", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(ownerCandidate)
        let outsiderCandidate = await vault.identity(for: "strict-outsider", makeNewIfNotFound: true)
        let outsider = try XCTUnwrap(outsiderCandidate)
        CellBase.defaultCellResolver = MockCellResolver()

        let entity = await EntityAnchorCell(owner: owner)
        try await CellContractHarness.assertAdvertisedKey(
            on: entity,
            key: "signedAgreementEntity.commit",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "object",
            expectedReturnType: "object"
        )
        try await CellContractHarness.assertAdvertisedKey(
            on: entity,
            key: "identityLinks.completeEnrollment",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "object",
            expectedReturnType: "oneOf"
        )
        _ = try await entity.set(keypath: "person.headline", value: .string("strict-ready"), requester: owner)
        let storedHeadline = try await entity.get(keypath: "person.headline", requester: owner)
        XCTAssertEqual(storedHeadline, .string("strict-ready"))
        let decodedEntity = try JSONDecoder().decode(
            EntityAnchorCell.self,
            from: JSONEncoder().encode(entity)
        )
        guard case .object = try await decodedEntity.get(keypath: "identityLinks.state", requester: owner) else {
            return XCTFail("Decoded strict Vapor EntityAnchor did not dispatch identityLinks.state")
        }
        for action in [
            "identityLinks.approveEnrollment",
            "identityLinks.completeEnrollment",
            "identityLinks.revoke"
        ] {
            let result = try await decodedEntity.set(
                keypath: action,
                value: .object([:]),
                requester: owner
            )
            guard case let .object(resultObject)? = result else {
                return XCTFail("Strict Vapor EntityAnchor action \(action) did not dispatch")
            }
            XCTAssertEqual(resultObject["status"], .string("error"))
        }
        try await CellContractHarness.assertSetDenied(
            on: decodedEntity,
            key: "identityLinks.completeEnrollment",
            input: .object([:]),
            requester: outsider
        )

        let orchestrator = await OrchestratorCell(owner: owner)
        try await CellContractHarness.assertAdvertisedKey(
            on: orchestrator,
            key: "addReference",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "object",
            expectedReturnType: "string"
        )
        guard case .string = try await orchestrator.get(keypath: "skeleton", requester: owner) else {
            return XCTFail("Strict Vapor Orchestrator skeleton handler was not installed")
        }
        let decodedOrchestrator = try JSONDecoder().decode(
            OrchestratorCell.self,
            from: JSONEncoder().encode(orchestrator)
        )
        let configuration = CellConfiguration(name: "Strict Vapor Configuration", cellReferences: [])
        let configurationResult = try await decodedOrchestrator.set(
            keypath: "setConfiguration",
            value: .cellConfiguration(configuration),
            requester: owner
        )
        XCTAssertEqual(configurationResult, .string("ok"))
        XCTAssertEqual(decodedOrchestrator.getCellConfiguration()?.name, configuration.name)
        let restartedOrchestrator = try JSONDecoder().decode(
            OrchestratorCell.self,
            from: JSONEncoder().encode(decodedOrchestrator)
        )
        _ = try await restartedOrchestrator.keys(requester: owner)
        XCTAssertEqual(restartedOrchestrator.getCellConfiguration()?.name, configuration.name)
        try await CellContractHarness.assertSetDenied(
            on: decodedOrchestrator,
            key: "addReference",
            input: .object([:]),
            requester: outsider
        )
    }

    private func assertDecodedReadiness<T: GeneralCell>(
        _ source: T,
        owner: Identity,
        expectedKey: String,
        requiredGrant: Grant,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let encoded = try JSONEncoder().encode(source)
        let immediate = try JSONDecoder().decode(T.self, from: encoded)
        let immediateKeys = try await immediate.keys(requester: owner)
        XCTAssertTrue(immediateKeys.contains(expectedKey), file: file, line: line)
        XCTAssertTrue(immediate.agreementTemplate.checkGrant(requestedGrant: requiredGrant), file: file, line: line)

        let concurrent = try JSONDecoder().decode(T.self, from: encoded)
        let persistedGrantCount = concurrent.agreementTemplate.grants.count
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask { try await concurrent.ensureRuntimeReady() }
            }
            try await group.waitForAll()
        }
        let concurrentKeys = try await concurrent.keys(requester: owner)
        XCTAssertTrue(concurrentKeys.contains(expectedKey), file: file, line: line)
        XCTAssertEqual(concurrent.agreementTemplate.grants.count, persistedGrantCount, file: file, line: line)
    }
}
