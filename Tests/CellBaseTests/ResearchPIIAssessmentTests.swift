// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import CellBase

/// test.fd.pii-grad-gir-regler, test.fd.pii-haandheves (assessor-delen) og
/// test.fd.pii-regler-versjon fra PDD_forskningsdata-verktoy.
final class ResearchPIIAssessmentTests: XCTestCase {
    private struct CaseFile: Decodable {
        struct Case: Decodable {
            struct Expect: Decodable {
                var degree: String?
                var violations: [String]
                var applied: [String]?
                var rules: [String: JSONValue]?
            }
            var id: String
            var request: ResearchPIIRequest
            var expect: Expect
        }
        var rulesVersion: String
        var cases: [Case]
    }

    /// Bare de verditypene casene bruker.
    private enum JSONValue: Decodable, Equatable {
        case int(Int), string(String), bool(Bool), null
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Int.self) { self = .int(v) }
            else { self = .string(try c.decode(String.self)) }
        }
    }

    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ResearchPII")
    }

    private func loadRules() throws -> ResearchPIIRules {
        try ResearchPIIRules.decode(from: Data(contentsOf: fixtureDirectory.appendingPathComponent("research-pii-rules.v1.json")))
    }

    private func value(_ rule: ResearchPIIRules.Rule, _ key: String) -> JSONValue? {
        switch key {
        case "minGroupSize": return .int(rule.minGroupSize)
        case "finestBucket": return rule.finestBucket.map(JSONValue.string) ?? .null
        case "maxRetentionDays": return rule.maxRetentionDays.map(JSONValue.int) ?? .null
        case "export": return .string(rule.export)
        case "allowed": return .bool(rule.allowed)
        case "requiresInstitutionalApproval": return .bool(rule.requiresInstitutionalApproval)
        case "requiresJustificationForRows": return .bool(rule.requiresJustificationForRows)
        default: return nil
        }
    }

    func testRulesTableIsValid() throws {
        let rules = try loadRules()
        XCTAssertEqual(rules.validationErrors(), [])
        XCTAssertEqual(rules.schemaVersion, ResearchPIIRules.schemaVersion)
    }

    func testGoldenCasesMatchReference() throws {
        let rules = try loadRules()
        let file = try JSONDecoder().decode(
            CaseFile.self,
            from: Data(contentsOf: fixtureDirectory.appendingPathComponent("pii-assessment-cases.v1.json"))
        )
        XCTAssertEqual(file.rulesVersion, rules.rulesVersion)
        XCTAssertEqual(file.cases.count, 15)
        let assessor = ResearchPIIAssessor(rules: rules)
        for c in file.cases {
            let got = assessor.assess(c.request)
            XCTAssertEqual(got.degree, c.expect.degree, c.id)
            XCTAssertEqual(got.violations.sorted(), c.expect.violations.sorted(), c.id)
            XCTAssertEqual(got.applied.sorted(), (c.expect.applied ?? []).sorted(), c.id)
            for (key, expected) in c.expect.rules ?? [:] {
                let rule = try XCTUnwrap(got.rules, c.id)
                XCTAssertEqual(value(rule, key), expected, "\(c.id).\(key)")
            }
        }
    }

    /// test.fd.pii-grad-gir-regler: hver grad gir forventet svarform, k,
    /// oppløsning, lagringstid, eksport og godkjenningskrav.
    func testEachDegreeGivesItsRules() throws {
        let assessor = ResearchPIIAssessor(rules: try loadRules())
        let expected: [(kind: String, degree: String, forms: [String], k: Int, bucket: String?, days: Int?, export: String, approval: Bool)] = [
            ("nodeMetric", "none", ["aggregate", "rows"], 1, "day", nil, "full", false),
            ("count", "aggregate", ["aggregate"], 5, "day", 730, "full", false),
            ("cohort", "quasi", ["aggregate", "pseudonymousRows"], 10, "week", 365, "aggregateOnly", true),
            ("freeText", "direct", ["pseudonymousRows"], 10, "week", 365, "none", true),
            ("health", "special", [], 0, nil, 0, "none", true),
        ]
        for e in expected {
            let a = assessor.assess(ResearchPIIRequest(fields: [.init(name: e.kind, kind: e.kind)], answerForm: "aggregate"))
            XCTAssertEqual(a.degree, e.degree, e.kind)
            let rule = try XCTUnwrap(a.rules, e.kind)
            XCTAssertEqual(rule.answerForms, e.forms, e.kind)
            XCTAssertEqual(rule.minGroupSize, e.k, e.kind)
            XCTAssertEqual(rule.finestBucket, e.bucket, e.kind)
            XCTAssertEqual(rule.maxRetentionDays, e.days, e.kind)
            XCTAssertEqual(rule.export, e.export, e.kind)
            XCTAssertEqual(rule.requiresInstitutionalApproval, e.approval, e.kind)
        }
    }

    /// En kvasi-identifikator i et lite utvalg gir høyere k.
    func testQuasiIdentifierInSmallPopulationRaisesK() throws {
        let assessor = ResearchPIIAssessor(rules: try loadRules())
        let a = assessor.assess(ResearchPIIRequest(
            fields: [.init(name: "n", kind: "count"), .init(name: "kull", kind: "cohort")],
            answerForm: "aggregate", bucket: "week", populationSize: 30
        ))
        XCTAssertEqual(a.degree, "quasi")
        XCTAssertEqual(a.applied, ["small-population"])
        XCTAssertEqual(a.rules?.minGroupSize, 20)
        XCTAssertEqual(a.violations, [])
    }

    /// Assessor-delen av test.fd.pii-haandheves. Cellene (WP5, WP15) har egne tester.
    func testEnforceRejectsViolatingRequest() throws {
        let assessor = ResearchPIIAssessor(rules: try loadRules())
        let bad = ResearchPIIRequest(fields: [.init(name: "tekst", kind: "freeText")], answerForm: "pseudonymousRows", bucket: "day")
        XCTAssertThrowsError(try assessor.enforce(bad)) { error in
            let rejection = error as? ResearchPIIRejection
            XCTAssertEqual(rejection?.assessment.violations.sorted(), ["bucket_too_fine", "rows_require_justification"])
        }
        let good = ResearchPIIRequest(fields: [.init(name: "n", kind: "count")], answerForm: "aggregate", bucket: "day", populationSize: 40)
        XCTAssertNoThrow(try assessor.enforce(good))
        let unknownBucket = ResearchPIIRequest(fields: [.init(name: "n", kind: "count")], answerForm: "aggregate", bucket: "hour", populationSize: 40)
        XCTAssertThrowsError(try assessor.enforce(unknownBucket))
    }

    /// test.fd.pii-regler-versjon: en ny regelversjon endrer ikke en godkjent
    /// vurdering; nye vurderinger får den nye versjonen.
    func testNewRulesVersionDoesNotChangeApprovedAssessment() throws {
        let v1 = try loadRules()
        let request = ResearchPIIRequest(fields: [.init(name: "n", kind: "count")], answerForm: "aggregate", bucket: "day", populationSize: 40)
        let approved = try ResearchPIIAssessor(rules: v1).enforce(request)
        let stored = try JSONEncoder().encode(approved)

        var v2 = v1
        v2.rulesVersion = "1.1.0"
        v2.rules["aggregate"]?.finestBucket = "week"
        XCTAssertEqual(v2.validationErrors(), [])
        let fresh = ResearchPIIAssessor(rules: v2).assess(request)
        XCTAssertEqual(fresh.rulesVersion, "1.1.0")
        XCTAssertEqual(fresh.violations, ["bucket_too_fine"])

        let reloaded = try JSONDecoder().decode(ResearchPIIAssessment.self, from: stored)
        XCTAssertEqual(reloaded, approved)
        XCTAssertEqual(reloaded.rulesVersion, "1.0.0")
        XCTAssertEqual(reloaded.rules?.finestBucket, "day")
    }

    func testValidationCatchesLooserStricterDegree() throws {
        var rules = try loadRules()
        rules.rules["direct"]?.minGroupSize = 3
        XCTAssertTrue(rules.validationErrors().contains("direct has lower minGroupSize than quasi"))
    }
}
