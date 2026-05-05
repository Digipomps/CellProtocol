// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class CommonsCellsTests: XCTestCase {
    private var previousDebugFlag = false

    override func setUp() {
        super.setUp()
        previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
    }

    override func tearDown() {
        CellBase.debugValidateAccessForEverything = previousDebugFlag
        super.tearDown()
    }

    private func commonsRootPath() -> String {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("commons", isDirectory: true)
            .path
    }

    private func object(_ value: ValueType, file: StaticString = #filePath, line: UInt = #line) -> Object {
        guard case let .object(object) = value else {
            XCTFail("Expected object ValueType", file: file, line: line)
            return [:]
        }
        return object
    }

    private func list(_ value: ValueType, file: StaticString = #filePath, line: UInt = #line) -> ValueTypeList {
        guard case let .list(list) = value else {
            XCTFail("Expected list ValueType", file: file, line: line)
            return []
        }
        return list
    }

    private func string(_ value: ValueType?, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let value else {
            XCTFail("Expected string ValueType but got nil", file: file, line: line)
            return ""
        }
        if case let .string(string) = value {
            return string
        }
        XCTFail("Expected string ValueType", file: file, line: line)
        return ""
    }

    private func int(_ value: ValueType?, file: StaticString = #filePath, line: UInt = #line) -> Int {
        guard let value else {
            XCTFail("Expected integer ValueType but got nil", file: file, line: line)
            return 0
        }
        switch value {
        case .integer(let integer):
            return integer
        case .number(let number):
            return number
        default:
            XCTFail("Expected integer-like ValueType", file: file, line: line)
            return 0
        }
    }

    func testCommonsResolverCellResolvesKnownAndCustomPath() async throws {
        let owner = Identity()
        let cell = await CommonsResolverCell(owner: owner)

        _ = try await cell.set(
            keypath: "commons.configure.rootPath",
            value: .string(commonsRootPath()),
            requester: owner
        )

        let knownRequest: ValueType = .object([
            "entity_id": .string("entity-k1"),
            "path": .string("#/purposes"),
            "context": .object([
                "role": .string("owner"),
                "consent_tokens": .list([])
            ])
        ])

        let knownResponse = try await cell.set(
            keypath: "commons.resolve.keypath",
            value: knownRequest,
            requester: owner
        )

        let knownResponseObject = object(knownResponse ?? .null)
        XCTAssertEqual(string(knownResponseObject["status"]), "ok")
        let knownResult = object(knownResponseObject["result"] ?? .null)
        XCTAssertEqual(string(knownResult["canonical_path"]), "#/perspective")

        let customResponse = try await cell.set(
            keypath: "commons.resolve.keypath",
            value: .object([
                "entity_id": .string("entity-c1"),
                "path": .string("#/custom/local-football-club/initiative"),
                "context": .object([
                    "role": .string("member"),
                    "consent_tokens": .list([])
                ])
            ]),
            requester: owner
        )

        let customResponseObject = object(customResponse ?? .null)
        XCTAssertEqual(string(customResponseObject["status"]), "ok")
        let customResult = object(customResponseObject["result"] ?? .null)
        XCTAssertEqual(string(customResult["type_ref"]), "haven.core#/OpenValue")
    }

    func testCommonsResolverCellBatchDataset() async throws {
        let owner = Identity()
        let cell = await CommonsResolverCell(owner: owner)

        _ = try await cell.set(
            keypath: "commons.configure.rootPath",
            value: .string(commonsRootPath()),
            requester: owner
        )

        let dataset = TestFixtures.loadJSON(named: "CommonsKeypathRequests.json")
        let payload = try JSONDecoder().decode(ValueType.self, from: dataset)

        let response = try await cell.set(
            keypath: "commons.resolve.batchKeypaths",
            value: payload,
            requester: owner
        )

        let responseObject = object(response ?? .null)
        XCTAssertEqual(string(responseObject["status"]), "ok")
        XCTAssertEqual(int(responseObject["count"]), 30)

        let items = list(responseObject["items"] ?? .list([]))
        XCTAssertEqual(items.count, 30)
    }

    func testCommonsTaxonomyCellGuidanceAndBatchDataset() async throws {
        let owner = Identity()
        let cell = await CommonsTaxonomyCell(owner: owner)

        _ = try await cell.set(
            keypath: "taxonomy.configure.rootPath",
            value: .string(commonsRootPath()),
            requester: owner
        )

        let guidanceResponse = try await cell.set(
            keypath: "taxonomy.resolve.guidance",
            value: .object(["namespace": .string("haven.conference")]),
            requester: owner
        )

        let guidanceResponseObject = object(guidanceResponse ?? .null)
        XCTAssertEqual(string(guidanceResponseObject["status"]), "ok")
        let guidance = object(guidanceResponseObject["result"] ?? .null)
        XCTAssertEqual(string(guidance["root_purpose_term_id"]), "purpose.human-equal-worth")
        XCTAssertEqual(string(guidance["contribution_purpose_term_id"]), "purpose.net-positive-contribution")

        let policyResponse = try await cell.set(
            keypath: "taxonomy.validate.purposeTree",
            value: .object(["namespace": .string("haven.core")]),
            requester: owner
        )
        let policyResponseObject = object(policyResponse ?? .null)
        XCTAssertEqual(string(policyResponseObject["status"]), "ok")
        let policyResult = object(policyResponseObject["result"] ?? .null)
        XCTAssertEqual(string(policyResult["namespace"]), "haven.core")
        XCTAssertEqual(int(policyResult["error_count"]), 0)

        let dataset = TestFixtures.loadJSON(named: "CommonsTermRequests.json")
        let payload = try JSONDecoder().decode(ValueType.self, from: dataset)

        let batchResponse = try await cell.set(
            keypath: "taxonomy.resolve.batchTerms",
            value: payload,
            requester: owner
        )

        let batchResponseObject = object(batchResponse ?? .null)
        XCTAssertEqual(string(batchResponseObject["status"]), "ok")
        XCTAssertEqual(int(batchResponseObject["count"]), 20)
        XCTAssertEqual(list(batchResponseObject["items"] ?? .list([])).count, 20)

        let localizedBatchResponse = try await cell.set(
            keypath: "taxonomy.resolve.batchTerms",
            value: .object([
                "locale": .string("nb-NO"),
                "namespace": .string("haven.core"),
                "terms": .list([.string("interest.ai")])
            ]),
            requester: owner
        )

        let localizedBatchObject = object(localizedBatchResponse ?? .null)
        XCTAssertEqual(string(localizedBatchObject["status"]), "ok")
        let localizedItems = list(localizedBatchObject["items"] ?? .list([]))
        let localizedItem = object(localizedItems.first ?? .null)
        XCTAssertEqual(string(localizedItem["status"]), "ok")
        let localizedResult = object(localizedItem["result"] ?? .null)
        XCTAssertEqual(string(localizedResult["label"]), "Kunstig intelligens")
        XCTAssertEqual(string(localizedResult["requested_locale"]), "nb-NO")
        XCTAssertEqual(string(localizedResult["resolved_locale"]), "nb-NO")

        let coverageResponse = try await cell.set(
            keypath: "taxonomy.validate.localizationCoverage",
            value: .object([
                "namespace": .string("haven.core"),
                "required_locales": .list([.string("nb-NO"), .string("en-US")])
            ]),
            requester: owner
        )

        let coverageObject = object(coverageResponse ?? .null)
        XCTAssertTrue(["ok", "warnings"].contains(string(coverageObject["status"])))
        let coverageResult = object(coverageObject["result"] ?? .null)
        XCTAssertEqual(string(coverageResult["namespace"]), "haven.core")
    }

    func testHelperCellExamplesFixtureDecodes() throws {
        let data = TestFixtures.loadJSON(named: "CommonsHelperCellExamples.json")
        let configs = try JSONDecoder().decode([CellConfiguration].self, from: data)
        XCTAssertEqual(configs.count, 5)
        XCTAssertEqual(configs[0].name, "Auto Climate Remediator")
        XCTAssertEqual(configs[1].name, "Community Guidance Helper")
        XCTAssertEqual(configs[2].name, "Climate Pilot Baseline Helper")
        XCTAssertEqual(configs[3].name, "Child Participation Pilot Evidence Router")
        XCTAssertEqual(configs[4].name, "Accountability Pilot Fairness Guardrail")
    }
}
