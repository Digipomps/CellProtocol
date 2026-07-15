// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class ExploreContractValidatorTests: XCTestCase {
    func testValidateObjectReportsPathSpecificRequiredAndTypeIssues() {
        let schema = ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "details": ExploreContract.objectSchema(
                    properties: [
                        "message": ExploreContract.schema(type: "string")
                    ],
                    requiredKeys: ["message"]
                )
            ],
            requiredKeys: ["status", "details"]
        )

        let report = ExploreContractValidator.validate(
            value: .object([
                "status": .integer(200),
                "details": .object([:])
            ]),
            against: schema
        )

        XCTAssertFalse(report.ok)
        XCTAssertTrue(
            report.issues.contains(
                ExploreValidationIssue(
                    path: "$.status",
                    expected: "string",
                    observed: "integer",
                    message: "Expected string, observed integer."
                )
            )
        )
        XCTAssertTrue(
            report.issues.contains(
                ExploreValidationIssue(
                    path: "$.details.message",
                    expected: "required property",
                    observed: "missing",
                    message: "Expected required property, observed missing."
                )
            )
        )
    }

    func testValidateListReportsItemPath() {
        let schema = ExploreContract.listSchema(item: ExploreContract.schema(type: "string"))

        let report = ExploreContractValidator.validate(
            value: .list([
                .string("ok"),
                .integer(1)
            ]),
            against: schema
        )

        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.issues.count, 1)
        XCTAssertEqual(report.issues.first?.path, "$[1]")
        XCTAssertEqual(report.issues.first?.expected, "string")
        XCTAssertEqual(report.issues.first?.observed, "integer")
    }

    func testOneOfAcceptsAnyMatchingExploreOptionAndRejectsNonMatchingValue() {
        let schema = ExploreContract.oneOfSchema(
            options: [
                ExploreContract.schema(type: "string"),
                ExploreContract.schema(type: "integer")
            ]
        )

        XCTAssertTrue(ExploreContractValidator.validate(value: .string("ok"), against: schema).ok)
        XCTAssertTrue(ExploreContractValidator.validate(value: .integer(1), against: schema).ok)

        let rejected = ExploreContractValidator.validate(value: .bool(true), against: schema)
        XCTAssertFalse(rejected.ok)
        XCTAssertEqual(rejected.issues.first?.path, "$")
        XCTAssertEqual(rejected.issues.first?.observed, "bool")
    }

    func testUnknownSchemaAndMissingOptionalPropertiesMatchCurrentExploreSemantics() {
        XCTAssertTrue(
            ExploreContractValidator.validate(
                value: .object(["anything": .list([.bool(true)])]),
                against: ExploreContract.unknownSchema()
            ).ok
        )

        let schema = ExploreContract.objectSchema(
            properties: [
                "optional": ExploreContract.schema(type: "string")
            ],
            requiredKeys: []
        )

        XCTAssertTrue(ExploreContractValidator.validate(value: .object([:]), against: schema).ok)
    }

    func testDefaultSampleAndInvalidInputUseExploreSchemaDialect() {
        let schema = ExploreContract.objectSchema(
            properties: [
                "message": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["message"]
        )

        let sample = ExploreContractValidator.defaultSample(for: schema)
        XCTAssertTrue(ExploreContractValidator.matches(value: sample, schema: schema))

        let invalid = ExploreContractValidator.invalidInput(for: schema)
        XCTAssertNotNil(invalid)
        XCTAssertFalse(ExploreContractValidator.matches(value: invalid, schema: schema))
    }

    func testCanonicalNamedValueTypesPreserveWireCaseAndValidateLegacyLowercaseSchemas() {
        let canonicalTypes = [
            "flowElement",
            "keyValue",
            "setValueState",
            "setValueResponse",
            "cellConfiguration",
            "cellReference",
            "verifiableCredential",
            "connectContext",
            "connectState",
            "contractState",
            "signData",
            "agreementPayload"
        ]

        for canonicalType in canonicalTypes {
            XCTAssertEqual(
                ExploreContract.canonicalTypeName(canonicalType),
                canonicalType
            )
            XCTAssertEqual(
                ExploreContract.canonicalTypeName(canonicalType.lowercased()),
                canonicalType
            )
            XCTAssertEqual(
                ExploreContract.schemaType(from: ExploreContract.schema(type: canonicalType)),
                canonicalType
            )
        }

        let configuration = ValueType.cellConfiguration(
            CellConfiguration(name: "Explore canonical type regression")
        )
        XCTAssertTrue(
            ExploreContractValidator.validate(
                value: configuration,
                against: ExploreContract.schema(type: "cellconfiguration")
            ).ok
        )
    }

    func testDeepEqualPreservesContractProbeComparisonSemantics() {
        XCTAssertTrue(
            ExploreContractValidator.deepEqual(
                .object([
                    "items": .list([.string("a"), .integer(1)])
                ]),
                .object([
                    "items": .list([.string("a"), .integer(1)])
                ])
            )
        )
        XCTAssertFalse(
            ExploreContractValidator.deepEqual(
                .object([
                    "items": .list([.string("a"), .integer(1)])
                ]),
                .object([
                    "items": .list([.string("a"), .integer(2)])
                ])
            )
        )
    }

    func testValidatorIssueCanBeEncodedForProbeArtifacts() throws {
        let issue = ExploreValidationIssue(
            path: "$.status",
            expected: "string",
            observed: "integer",
            message: "Expected string, observed integer."
        )
        let report = ExploreValidationReport(ok: false, issues: [issue])

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(ExploreValidationReport.self, from: data)

        XCTAssertEqual(decoded, report)
    }
}
