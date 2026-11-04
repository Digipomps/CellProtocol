// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  AssistantDescriptorTests.swift
//  PDD_siri-ai fase 1, WP1.2 + WP1.3 (purpose://candidate.siri.celle-entitet,
//  purpose://candidate.siri.kontrakt-til-tool).
//
//  The projection from Explore contracts to assistant descriptors is pure and
//  deterministic. The golden fixtures hold the stable summary of what
//  ListsCell and VaultCell expose; they are the contract an adapter in
//  CellApple (App Intents, Foundation Models) builds on.
//
//  Regenerate after an intentional change to a cell's exposure:
//    HAVEN_WRITE_ASSISTANT_FIXTURES=1 swift test --filter AssistantDescriptorTests
//

import Foundation
import XCTest
@testable import CellBase

final class AssistantDescriptorTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        super.tearDown()
    }

    // MARK: - Stable summary (what the fixture pins)

    struct SurfaceSummary: Codable, Equatable {
        struct Parameter: Codable, Equatable {
            var name: String
            var type: String
            var required: Bool
            var options: [String]?
        }
        struct Tool: Codable, Equatable {
            var key: String
            var method: String
            var title: String
            var permission: String
            var authentication: String
            var inputType: String
            var returnType: String
            var parameters: [Parameter]
        }
        struct Property: Codable, Equatable {
            var name: String
            var type: String
            var required: Bool
        }
        struct Entity: Codable, Equatable {
            var key: String
            var method: String
            var typeName: String
            var permission: String
            var idKey: String
            var titleKey: String
            var itemsKey: String?
            var authentication: String
            var indexable: Bool
            var properties: [Property]
        }
        struct Grant: Codable, Equatable {
            var keypath: String
            var permission: String
        }

        var schemaVersion: String
        var cellType: String
        var tools: [Tool]
        var entities: [Entity]
        var grants: [Grant]

        init(_ surface: AssistantSurfaceDescriptor) {
            schemaVersion = surface.schemaVersion
            cellType = surface.cellType
            tools = surface.tools.map { tool in
                Tool(
                    key: tool.key,
                    method: tool.method,
                    title: tool.title,
                    permission: tool.permission,
                    authentication: tool.authentication.rawValue,
                    inputType: tool.inputType,
                    returnType: tool.returnType,
                    parameters: tool.parameters.map {
                        Parameter(name: $0.name, type: $0.type, required: $0.required, options: $0.options)
                    }
                )
            }
            entities = surface.entities.map { entity in
                Entity(
                    key: entity.key,
                    method: entity.method,
                    typeName: entity.typeName,
                    permission: entity.permission,
                    idKey: entity.idKey,
                    titleKey: entity.titleKey,
                    itemsKey: entity.itemsKey,
                    authentication: entity.authentication.rawValue,
                    indexable: entity.indexable,
                    properties: entity.properties.map { Property(name: $0.name, type: $0.type, required: $0.required) }
                )
            }
            grants = surface.grants.map { Grant(keypath: $0.keypath, permission: $0.permission) }
        }
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func assertMatchesFixture(
        _ surface: AssistantSurfaceDescriptor,
        fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let actual = SurfaceSummary(surface)
        let url = TestFixtures.fixtureURL(named: fixture)
        if ProcessInfo.processInfo.environment["HAVEN_WRITE_ASSISTANT_FIXTURES"] == "1" {
            try (Self.json(actual) + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        let data = try Data(contentsOf: url)
        let expected = try JSONDecoder().decode(SurfaceSummary.self, from: data)
        if actual != expected {
            let actualJSON = try Self.json(actual)
            XCTFail(
                "\(fixture) differs from the projected surface. Actual summary:\n\(actualJSON)",
                file: file,
                line: line
            )
        }
    }

    // MARK: - Lists

    func testListsCellSurfaceMatchesGoldenFixture() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await ListsCell(owner: owner)

        let surface = try await AssistantDescriptorProjection.project(for: cell, requester: owner)
        XCTAssertEqual(surface.cellType, "ListsCell")
        XCTAssertEqual(surface.tools.map(\.key), ListsCell.assistantToolKeys.sorted())
        XCTAssertEqual(surface.entities.map(\.key), [ListsCell.assistantEntityKey])
        XCTAssertEqual(
            surface.grants,
            ListsCell.assistantToolKeys.sorted().map { AssistantGrantRequirement(keypath: $0, permission: "-w--") }
                + [AssistantGrantRequirement(keypath: "lists.state", permission: "r---")]
        )

        let toggle = try XCTUnwrap(surface.tool(for: "lists.item.toggle"))
        XCTAssertEqual(toggle.parameters.map(\.name), ["itemId", "listId"])
        XCTAssertTrue(toggle.parameters.allSatisfy(\.required))
        XCTAssertEqual(toggle.title, "Lists item toggle")

        let rows = try XCTUnwrap(surface.entity(for: "lists.state"))
        XCTAssertEqual(rows.itemsKey, "lists")
        XCTAssertTrue(rows.indexable)
        XCTAssertTrue(rows.properties.contains { $0.name == "id" && $0.type == "string" })
        XCTAssertTrue(rows.properties.contains { $0.name == "title" && $0.type == "string" })

        try assertMatchesFixture(surface, fixture: "AssistantSurface.ListsCell.v1.json")
    }

    // MARK: - Vault

    func testVaultCellSurfaceMatchesGoldenFixture() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await VaultCell(owner: owner)

        let surface = try await AssistantDescriptorProjection.project(for: cell, requester: owner)
        XCTAssertEqual(surface.cellType, "VaultCell")
        XCTAssertEqual(surface.tools.map(\.key), VaultCell.assistantToolKeys.sorted())
        XCTAssertEqual(surface.entities.map(\.key), [VaultCell.assistantEntityKey])

        let notes = try XCTUnwrap(surface.entity(for: "vault.state"))
        XCTAssertEqual(notes.itemsKey, "notes")
        XCTAssertEqual(notes.properties.map(\.name), ["content", "createdAtEpochMs", "id", "slug", "tags", "title", "updatedAtEpochMs"])
        XCTAssertFalse(try XCTUnwrap(notes.properties.first { $0.name == "slug" }).required)

        try assertMatchesFixture(surface, fixture: "AssistantSurface.VaultCell.v1.json")
    }

    // MARK: - Projection properties

    func testProjectionIsDeterministicAndOrderIndependent() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await ListsCell(owner: owner)
        let contracts = try await cell.operationContracts(requester: owner)

        let forward = AssistantDescriptorProjection.project(cellType: "ListsCell", contracts: contracts)
        let reversed = AssistantDescriptorProjection.project(cellType: "ListsCell", contracts: contracts.reversed())
        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(try Self.json(forward), try Self.json(reversed))

        let decoded = try JSONDecoder().decode(AssistantSurfaceDescriptor.self, from: try JSONEncoder().encode(forward))
        XCTAssertEqual(decoded, forward, "descriptors round-trip through JSON")
    }

    func testContractsWithoutExposureProjectToAnEmptySurface() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        await cell.registerSet(key: "demo.set", owner: owner, input: ExploreContract.schema(type: "string"), permissions: ["-w--"]) { _, _ in ValueType.null }
        await cell.registerGet(key: "demo.state", owner: owner, returns: ExploreContract.schema(type: "object"), permissions: ["r---"]) { _ in ValueType.object([:]) }

        let surface = try await AssistantDescriptorProjection.project(for: cell, requester: owner)
        XCTAssertTrue(surface.isEmpty)
        XCTAssertTrue(surface.grants.isEmpty)
    }

    func testToolExposureOnAGetKeyYieldsNoTool() {
        let contract = ExploreContract.keyContract(
            key: "demo.state",
            method: .get,
            returns: ExploreContract.schema(type: "object"),
            permissions: ["r---"],
            assistant: .tool()
        )
        let surface = AssistantDescriptorProjection.project(cellType: "Demo", contracts: [contract])
        XCTAssertTrue(surface.tools.isEmpty, "only set keys become tools")
        XCTAssertTrue(surface.grants.isEmpty)
    }

    func testParametersFlattenObjectSchemasAndWrapEverythingElse() {
        let objectInput = ExploreContract.objectSchema(
            properties: [
                "title": ExploreContract.schema(type: "string", description: "The title."),
                "count": ExploreContract.schema(type: "integer")
            ],
            requiredKeys: ["title"]
        )
        let objectTool = AssistantDescriptorProjection.project(cellType: "Demo", contracts: [
            ExploreContract.keyContract(key: "demo.add", method: .set, input: objectInput, permissions: ["-w--"], assistant: .tool())
        ]).tools[0]
        XCTAssertEqual(objectTool.parameters, [
            AssistantParameterDescriptor(name: "count", type: "integer", description: nil, required: false, options: nil),
            AssistantParameterDescriptor(name: "title", type: "string", description: "The title.", required: true, options: nil)
        ])

        let oneOfInput = ExploreContract.oneOfSchema(options: [ExploreContract.schema(type: "string"), .null], description: "Text or nothing.")
        let oneOfTool = AssistantDescriptorProjection.project(cellType: "Demo", contracts: [
            ExploreContract.keyContract(key: "demo.say", method: .set, input: oneOfInput, assistant: .tool())
        ]).tools[0]
        XCTAssertEqual(oneOfTool.parameters, [
            AssistantParameterDescriptor(name: "value", type: "oneOf", description: "Text or nothing.", required: true, options: ["string", "null"])
        ])
        XCTAssertEqual(oneOfTool.permission, "-w--", "a set key without declared permissions defaults to -w--")

        let noInput = AssistantDescriptorProjection.project(cellType: "Demo", contracts: [
            ExploreContract.keyContract(key: "demo.ping", method: .set, input: .null, assistant: .tool())
        ]).tools[0]
        XCTAssertTrue(noInput.parameters.isEmpty)
    }

    func testHumaniseKeys() {
        XCTAssertEqual(AssistantDescriptorProjection.humanise("lists.item.add"), "Lists item add")
        XCTAssertEqual(AssistantDescriptorProjection.humanise("vault.state.notes"), "Vault state notes")
        XCTAssertEqual(AssistantDescriptorProjection.humanise("state"), "State")
    }
}
