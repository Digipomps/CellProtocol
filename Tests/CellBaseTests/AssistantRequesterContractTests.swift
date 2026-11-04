// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  AssistantRequesterContractTests.swift
//  PDD_siri-ai fase 1, WP1.4 (purpose://candidate.siri.tillitsgrense).
//
//  An assistant is a requester, never the owner. Its Contract carries exactly
//  the exposed keys: an opted-in key answers, a key the cell did not expose is
//  denied, and the gateway refuses unexposed keys before the cell sees them.
//

import XCTest
@testable import CellBase

final class AssistantRequesterContractTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        super.tearDown()
    }

    private func identities() async -> (MockIdentityVault, Identity, Identity, Identity) {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let assistant = await vault.identity(for: "siri-assistant", makeNewIfNotFound: true)!
        let outsider = await vault.identity(for: "someone-else", makeNewIfNotFound: true)!
        return (vault, owner, assistant, outsider)
    }

    private func status(_ value: ValueType?) -> String? {
        guard case let .object(object)? = value, case let .string(status)? = object["status"] else { return nil }
        return status
    }

    // MARK: - Lists

    func testAgreementRequestCarriesExactlyTheSurfaceGrants() async throws {
        let (_, owner, _, _) = await identities()
        let cell = await ListsCell(owner: owner)
        let surface = try await AssistantDescriptorProjection.project(for: cell, requester: owner)

        let request = try XCTUnwrap(AssistantRequesterContract.agreementRequest(for: cell, surface: surface))
        XCTAssertEqual(request.name, AssistantRequesterContract.agreementName)
        XCTAssertEqual(
            Set(request.grants.map { "\($0.keypath):\($0.permission.permissionString)" }),
            Set(surface.grants.map { "\($0.keypath):\($0.permission)" })
        )
        XCTAssertFalse(request.grants.contains { $0.keypath == ListsCell.grantArea }, "no owner-area grant")
        XCTAssertFalse(request.grants.contains { $0.keypath == "feed" }, "no feed grant")
        XCTAssertLessThanOrEqual(request.duration, cell.agreementTemplate.duration)
        XCTAssertTrue(request.grants.allSatisfy { cell.agreementTemplate.checkGrant(requestedGrant: $0) }, "every grant is inside the cell's template")
    }

    func testAssistantReachesOptedInKeysAndNothingElse() async throws {
        let (_, owner, assistant, _) = await identities()
        let cell = await ListsCell(owner: owner)
        let created = try await cell.set(keypath: "lists.list.create", value: .string("Handleliste"), requester: owner)
        XCTAssertEqual(status(created), "ok")

        let surface = try await AssistantDescriptorProjection.project(for: cell, requester: owner)
        let state = await AssistantRequesterContract.admit(assistant: assistant, to: cell, surface: surface, authorizedBy: owner)
        XCTAssertEqual(state, .signed)

        // Opted-in tool: answers with the cell's ordinary result.
        let added = try await cell.set(keypath: "lists.item.add", value: .string("Melk"), requester: assistant)
        XCTAssertEqual(status(added), "ok", "assistant may add through its exact grant; got \(String(describing: added))")

        // Opted-in entity: readable.
        let listsState = try await cell.get(keypath: "lists.state", requester: assistant)
        guard case let .object(stateObject) = listsState, case let .list(rows)? = stateObject["lists"] else {
            return XCTFail("assistant should read lists.state as an object; got \(listsState)")
        }
        XCTAssertEqual(rows.count, 1)

        // Not opted in: denied although the owner-area grant would have covered it.
        try await CellContractHarness.assertSetDenied(on: cell, key: "lists.item.remove", input: .object(["listId": .string("x"), "itemId": .string("y")]), requester: assistant)
        try await CellContractHarness.assertSetDenied(on: cell, key: "lists.list.rename", input: .string("Annet navn"), requester: assistant)
        try await CellContractHarness.assertGetDenied(on: cell, key: "lists", requester: assistant)

        // The owner is unaffected.
        let ownerState = try await cell.get(keypath: "lists.state", requester: owner)
        XCTAssertEqual(status(ownerState), "ok")
    }

    func testGatewayRefusesUnexposedKeysBeforeTheCellAndValidatesPayloads() async throws {
        let (_, owner, assistant, outsider) = await identities()
        let cell = await ListsCell(owner: owner)
        _ = try await cell.set(keypath: "lists.list.create", value: .string("Handleliste"), requester: owner)
        let surface = try await AssistantDescriptorProjection.project(for: cell, requester: owner)
        let admission = await AssistantRequesterContract.admit(assistant: assistant, to: cell, surface: surface, authorizedBy: owner)
        XCTAssertEqual(admission, .signed)
        let gateway = AssistantGateway(cell: cell, surface: surface)

        let refused = try await gateway.invokeTool(key: "lists.item.remove", payload: .object(["listId": .string("x"), "itemId": .string("y")]), requester: assistant)
        XCTAssertEqual(refused, .refused(reason: AssistantGateway.reasonNotExposedAsTool))

        let unknown = try await gateway.invokeTool(key: "no.such.key", payload: .null, requester: assistant)
        XCTAssertEqual(unknown, .refused(reason: AssistantGateway.reasonNotExposedAsTool))

        let invalid = try await gateway.invokeTool(key: "lists.item.add", payload: .integer(1), requester: assistant)
        guard case let .invalidInput(report) = invalid else {
            return XCTFail("an integer is neither string nor object; got \(invalid)")
        }
        XCTAssertFalse(report.ok)
        XCTAssertFalse(report.issues.isEmpty)

        let added = try await gateway.invokeTool(key: "lists.item.add", payload: .string("Brød"), requester: assistant)
        guard case let .response(response) = added else {
            return XCTFail("expected a cell response; got \(added)")
        }
        XCTAssertEqual(status(response), "ok")

        let denied = try await gateway.invokeTool(key: "lists.item.add", payload: .string("Ost"), requester: outsider)
        XCTAssertEqual(denied, .denied, "no contract, no answer")

        let entities = try await gateway.readEntities(key: "lists.state", requester: assistant)
        guard case let .response(entityState) = entities else {
            return XCTFail("expected the state; got \(entities)")
        }
        XCTAssertEqual(status(entityState), "ok")
        let rootRead = try await gateway.readEntities(key: "lists", requester: assistant)
        XCTAssertEqual(rootRead, .refused(reason: AssistantGateway.reasonNotExposedAsEntity))
    }

    func testEmptySurfaceIsNeverAdmitted() async throws {
        let (_, owner, assistant, _) = await identities()
        let cell = await GeneralCell(owner: owner)
        await cell.registerSet(key: "demo.set", owner: owner, input: ExploreContract.schema(type: "string"), permissions: ["-w--"]) { _, _ in ValueType.null }
        let surface = try await AssistantDescriptorProjection.project(for: cell, requester: owner)
        XCTAssertTrue(surface.isEmpty)
        XCTAssertNil(AssistantRequesterContract.agreementRequest(for: cell, surface: surface))
        let state = await AssistantRequesterContract.admit(assistant: assistant, to: cell, surface: surface, authorizedBy: owner)
        XCTAssertEqual(state, .rejected)
        try await CellContractHarness.assertSetDenied(on: cell, key: "demo.set", input: .string("x"), requester: assistant)
    }

    func testSurfaceOutsideTheTemplateIsRejected() async throws {
        let (_, owner, assistant, _) = await identities()
        let cell = await GeneralCell(owner: owner)
        await cell.registerSet(key: "demo.set", owner: owner, input: ExploreContract.schema(type: "string"), permissions: ["-w--"], assistant: .tool()) { _, _ in ValueType.null }
        // The key is exposed but the cell never added it to its agreement template.
        let surface = try await AssistantDescriptorProjection.project(for: cell, requester: owner)
        XCTAssertEqual(surface.grants, [AssistantGrantRequirement(keypath: "demo.set", permission: "-w--")])
        let state = await AssistantRequesterContract.admit(assistant: assistant, to: cell, surface: surface, authorizedBy: owner)
        XCTAssertEqual(state, .rejected, "exposure without a template grant must not admit anyone")
    }

    // MARK: - Vault

    func testVaultAssistantCanCreateAndListNotesButNotUpdateThem() async throws {
        let (_, owner, assistant, _) = await identities()
        let cell = await VaultCell(owner: owner)
        let surface = try await AssistantDescriptorProjection.project(for: cell, requester: owner)
        let admission = await AssistantRequesterContract.admit(assistant: assistant, to: cell, surface: surface, authorizedBy: owner)
        XCTAssertEqual(admission, .signed)

        let note: ValueType = .object([
            "id": .string("note-siri-1"),
            "title": .string("Fra Siri"),
            "content": .string("Husk å kjøpe melk."),
            "tags": .list([.string("siri")]),
            "createdAtEpochMs": .integer(1_700_000_000_000),
            "updatedAtEpochMs": .integer(1_700_000_000_000)
        ])
        let created = try await cell.set(keypath: "vault.note.create", value: note, requester: assistant)
        XCTAssertEqual(status(created), "ok", "got \(String(describing: created))")

        let listed = try await cell.set(keypath: "vault.note.list", value: .null, requester: assistant)
        XCTAssertEqual(status(listed), "ok")

        let state = try await cell.get(keypath: "vault.state", requester: assistant)
        guard case let .object(stateObject) = state, case let .list(notes)? = stateObject["notes"] else {
            return XCTFail("assistant should read vault.state; got \(state)")
        }
        XCTAssertEqual(notes.count, 1)

        try await CellContractHarness.assertSetDenied(on: cell, key: "vault.note.update", input: note, requester: assistant)
        try await CellContractHarness.assertSetDenied(on: cell, key: "vault.link.add", input: .object([:]), requester: assistant)
        try await CellContractHarness.assertGetDenied(on: cell, key: "vault.retention.state", requester: assistant)
    }
}
