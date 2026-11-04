// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  AssistantExposureContractTests.swift
//  PDD_siri-ai fase 1, WP1.1 (purpose://candidate.siri.kontrakt-til-tool).
//
//  The `assistant` field on an Explore contract is additive and opt-in:
//  contracts that do not set it encode exactly as before, and the field
//  survives registration and normalisation unchanged.
//

import XCTest
@testable import CellBase

final class AssistantExposureContractTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        super.tearDown()
    }

    func testContractWithoutAssistantHasNoAssistantField() throws {
        let contract = ExploreContract.keyContract(
            key: "demo.set",
            method: .set,
            input: ExploreContract.schema(type: "string"),
            permissions: ["-w--"],
            summary: "Demo"
        )
        let object = try XCTUnwrap(ExploreContract.object(from: contract))
        XCTAssertNil(object[ExploreContract.Field.assistant])
        XCTAssertNil(ExploreContract.assistantExposure(from: contract))

        let off = ExploreContract.keyContract(key: "demo.set", method: .set, assistant: .off)
        XCTAssertNil(ExploreContract.object(from: off)?[ExploreContract.Field.assistant], "an exposure that exposes nothing is omitted")
    }

    func testToolExposureRoundTripsThroughTheContract() throws {
        let exposure = AssistantExposure.tool(authentication: .requiresLocalDeviceAuthentication)
        let contract = ExploreContract.keyContract(
            key: "demo.set",
            method: .set,
            input: ExploreContract.schema(type: "string"),
            permissions: ["-w--"],
            summary: "Demo",
            assistant: exposure
        )
        let decoded = try XCTUnwrap(ExploreContract.assistantExposure(from: contract))
        XCTAssertEqual(decoded, exposure)
        XCTAssertTrue(decoded.exposeAsTool)
        XCTAssertFalse(decoded.exposeAsEntity)
        XCTAssertFalse(decoded.indexable)

        let object = try XCTUnwrap(ExploreContract.object(from: contract))
        let field = try XCTUnwrap(ExploreContract.object(from: object[ExploreContract.Field.assistant]))
        XCTAssertEqual(field[AssistantExposure.Field.exposeAsTool], .bool(true))
        XCTAssertEqual(field[AssistantExposure.Field.authentication], .string("requiresLocalDeviceAuthentication"))
        XCTAssertNil(field[AssistantExposure.Field.entityItemsKey], "nil strings are omitted")
    }

    func testEntityExposureRoundTripsWithItemsKey() throws {
        let exposure = AssistantExposure.entity(idKey: "noteID", titleKey: "heading", itemsKey: "notes", indexable: true)
        let contract = ExploreContract.keyContract(key: "demo.state", method: .get, assistant: exposure)
        let decoded = try XCTUnwrap(ExploreContract.assistantExposure(from: contract))
        XCTAssertEqual(decoded, exposure)
        XCTAssertEqual(decoded.entityItemsKey, "notes")
        XCTAssertEqual(decoded.authentication, .requiresAuthentication, "the strict level is the default")
    }

    func testUnknownAuthenticationFailsClosed() {
        let value: ValueType = .object([
            AssistantExposure.Field.exposeAsTool: .bool(true),
            AssistantExposure.Field.authentication: .string("trustMe")
        ])
        XCTAssertNil(AssistantExposure(value: value))
        XCTAssertNil(AssistantExposure(value: .string("tool")))
        XCTAssertNil(AssistantExposure(value: nil))
    }

    func testRegisteredContractKeepsAssistantFieldAndCatalogTagsIt() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.registerSet(
            key: "demo.add",
            owner: owner,
            input: ExploreContract.objectSchema(
                properties: ["title": ExploreContract.schema(type: "string", description: "What to add.")],
                requiredKeys: ["title"]
            ),
            returns: ExploreContract.schema(type: "object"),
            permissions: ["-w--"],
            description: .string("Adds a demo item."),
            assistant: .tool()
        ) { _, _ in ValueType.object(["status": .string("ok")]) }
        await cell.registerSet(
            key: "demo.remove",
            owner: owner,
            input: ExploreContract.schema(type: "string"),
            permissions: ["-w--"],
            description: .string("Removes a demo item.")
        ) { _, _ in ValueType.object(["status": .string("ok")]) }

        let exposed = try await cell.typeForKey(key: "demo.add", requester: owner)
        XCTAssertEqual(ExploreContract.assistantExposure(from: exposed), .tool())
        XCTAssertEqual(ExploreContract.string(from: ExploreContract.object(from: exposed)?[ExploreContract.Field.summary]), "Adds a demo item.")

        let plain = try await cell.typeForKey(key: "demo.remove", requester: owner)
        XCTAssertNil(ExploreContract.assistantExposure(from: plain))

        let catalog = try await cell.exploreContractCatalog(requester: owner)
        let addRecord = try XCTUnwrap(catalog.records.first { $0.key == "demo.add" })
        XCTAssertTrue(addRecord.tags.contains("assistant.tool"), "tags: \(addRecord.tags)")
        XCTAssertFalse(addRecord.tags.contains("assistant.entity"))
        let removeRecord = try XCTUnwrap(catalog.records.first { $0.key == "demo.remove" })
        XCTAssertFalse(removeRecord.tags.contains("assistant.tool"))
    }
}
