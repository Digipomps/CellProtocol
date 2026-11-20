// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
//
// Persondatavurdering for forskningsdata (PDD_forskningsdata-verktoy, WP2).
//
// Leser regeltabellen `research.pii-rules.v1` og gir en forespørsel en grad,
// reglene som gjelder og eventuelle brudd. Samme utfall som referansen
// `contract/pii_assess.py` i CellProtocolDocuments, og som Py/Go-portene,
// for hvert tilfelle i `research.pii-assessment-cases.v1`.
//
// Celler som utleverer forskningsdata kaller `enforce(_:)` selv, slik at en
// forespørsel som bryter reglene avvises i cellen og ikke bare i flaten.

import Foundation

/// Regeltabellen `research.pii-rules.v1`.
public struct ResearchPIIRules: Codable, Equatable, Sendable {
    public static let schemaVersion = "research.pii-rules.v1"

    public struct Degree: Codable, Equatable, Sendable {
        public var id: String
        public var rank: Int
        public var label: String?
        public var description: String?
    }

    public struct Rule: Codable, Equatable, Sendable {
        public var answerForms: [String]
        public var minGroupSize: Int
        public var finestBucket: String?
        public var maxRetentionDays: Int?
        public var export: String
        public var requiresJustificationForRows: Bool
        public var requiresInstitutionalApproval: Bool
        public var allowed: Bool

        enum CodingKeys: String, CodingKey {
            case answerForms, minGroupSize, finestBucket, maxRetentionDays, export
            case requiresJustificationForRows, requiresInstitutionalApproval, allowed
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            answerForms = try c.decode([String].self, forKey: .answerForms)
            minGroupSize = try c.decode(Int.self, forKey: .minGroupSize)
            finestBucket = try c.decodeIfPresent(String.self, forKey: .finestBucket)
            maxRetentionDays = try c.decodeIfPresent(Int.self, forKey: .maxRetentionDays)
            export = try c.decode(String.self, forKey: .export)
            requiresJustificationForRows = try c.decode(Bool.self, forKey: .requiresJustificationForRows)
            requiresInstitutionalApproval = try c.decode(Bool.self, forKey: .requiresInstitutionalApproval)
            allowed = try c.decode(Bool.self, forKey: .allowed)
        }

        // Null skrives ut eksplisitt, så JSON-formen er lik den i tabellen.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(answerForms, forKey: .answerForms)
            try c.encode(minGroupSize, forKey: .minGroupSize)
            try c.encode(finestBucket, forKey: .finestBucket)
            try c.encode(maxRetentionDays, forKey: .maxRetentionDays)
            try c.encode(export, forKey: .export)
            try c.encode(requiresJustificationForRows, forKey: .requiresJustificationForRows)
            try c.encode(requiresInstitutionalApproval, forKey: .requiresInstitutionalApproval)
            try c.encode(allowed, forKey: .allowed)
        }
    }

    public struct Escalation: Codable, Equatable, Sendable {
        public struct When: Codable, Equatable, Sendable {
            public var quasiFieldCountAtLeast: Int?
            public var populationBelowMultipleOfMinGroupSize: Int?
            public var researchQuestionLongitudinal: Bool?

            enum CodingKeys: String, CodingKey {
                case quasiFieldCountAtLeast
                case populationBelowMultipleOfMinGroupSize
                case researchQuestionLongitudinal = "researchQuestion.longitudinal"
            }
        }

        public struct Effect: Codable, Equatable, Sendable {
            public var raiseDegreeTo: String?
            public var multiplyMinGroupSize: Int?
            public var coarsenBucketTo: String?
        }

        public var id: String
        public var when: When
        public var effect: Effect
        public var reason: String?
    }

    public var schemaVersion: String
    public var rulesVersion: String
    public var status: String?
    public var owner: String?
    public var changePolicy: String?
    public var note: String?
    public var degrees: [Degree]
    public var fieldKinds: [String: String]
    public var rules: [String: Rule]
    public var escalations: [Escalation]
    public var bucketOrder: [String]
    public var answerFormOrder: [String]

    public static func decode(from data: Data) throws -> ResearchPIIRules {
        try JSONDecoder().decode(ResearchPIIRules.self, from: data)
    }

    /// Strukturelle feil i tabellen. Tom liste betyr at tabellen kan brukes.
    public func validationErrors() -> [String] {
        var errors: [String] = []
        if schemaVersion != Self.schemaVersion { errors.append("schemaVersion") }
        let ranks = degrees.map(\.rank)
        if ranks != ranks.sorted() || Set(ranks).count != ranks.count {
            errors.append("degree ranks must be unique and ascending")
        }
        let ids = Set(degrees.map(\.id))
        if Set(rules.keys) != ids { errors.append("rules must cover exactly the degrees") }
        for (id, rule) in rules.sorted(by: { $0.key < $1.key }) {
            for form in rule.answerForms where !answerFormOrder.contains(form) {
                errors.append("rule \(id): unknown answer form \(form)")
            }
            if let bucket = rule.finestBucket, !bucketOrder.contains(bucket) {
                errors.append("rule \(id): unknown bucket")
            }
            if !["full", "aggregateOnly", "none"].contains(rule.export) {
                errors.append("rule \(id): export")
            }
        }
        for (kind, degree) in fieldKinds.sorted(by: { $0.key < $1.key }) where !ids.contains(degree) {
            errors.append("fieldKind \(kind): unknown degree \(degree)")
        }
        let ordered = degrees.sorted { $0.rank < $1.rank }
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            guard let ra = rules[a.id], let rb = rules[b.id] else { continue }
            if rb.allowed && rb.minGroupSize < ra.minGroupSize {
                errors.append("\(b.id) has lower minGroupSize than \(a.id)")
            }
            if !Set(rb.answerForms).isSubset(of: Set(ra.answerForms).union(["pseudonymousRows"])) {
                errors.append("\(b.id) allows an answer form \(a.id) does not")
            }
        }
        return errors
    }
}

/// En forespørsel eller mal som skal vurderes.
public struct ResearchPIIRequest: Codable, Equatable, Sendable {
    public struct Field: Codable, Equatable, Sendable {
        public var name: String
        public var kind: String
        public init(name: String, kind: String) {
            self.name = name
            self.kind = kind
        }
    }

    public struct ResearchQuestion: Codable, Equatable, Sendable {
        public var longitudinal: Bool?
        public init(longitudinal: Bool? = nil) { self.longitudinal = longitudinal }
    }

    public var fields: [Field]
    public var answerForm: String?
    public var bucket: String?
    public var populationSize: Int?
    public var retentionDays: Int?
    public var export: Bool?
    public var justification: String?
    public var realParticipants: Bool?
    public var institutionalApproval: Bool?
    public var researchQuestion: ResearchQuestion?

    public init(
        fields: [Field],
        answerForm: String? = nil,
        bucket: String? = nil,
        populationSize: Int? = nil,
        retentionDays: Int? = nil,
        export: Bool? = nil,
        justification: String? = nil,
        realParticipants: Bool? = nil,
        institutionalApproval: Bool? = nil,
        researchQuestion: ResearchQuestion? = nil
    ) {
        self.fields = fields
        self.answerForm = answerForm
        self.bucket = bucket
        self.populationSize = populationSize
        self.retentionDays = retentionDays
        self.export = export
        self.justification = justification
        self.realParticipants = realParticipants
        self.institutionalApproval = institutionalApproval
        self.researchQuestion = researchQuestion
    }

    enum CodingKeys: String, CodingKey {
        case fields, answerForm, bucket, populationSize, retentionDays, export
        case justification, realParticipants, institutionalApproval, researchQuestion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fields = try c.decodeIfPresent([Field].self, forKey: .fields) ?? []
        answerForm = try c.decodeIfPresent(String.self, forKey: .answerForm)
        bucket = try c.decodeIfPresent(String.self, forKey: .bucket)
        populationSize = try c.decodeIfPresent(Int.self, forKey: .populationSize)
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays)
        export = try c.decodeIfPresent(Bool.self, forKey: .export)
        justification = try c.decodeIfPresent(String.self, forKey: .justification)
        realParticipants = try c.decodeIfPresent(Bool.self, forKey: .realParticipants)
        institutionalApproval = try c.decodeIfPresent(Bool.self, forKey: .institutionalApproval)
        researchQuestion = try c.decodeIfPresent(ResearchQuestion.self, forKey: .researchQuestion)
    }
}

/// Utfallet av en vurdering. `rulesVersion` følger med, så en godkjent
/// forespørsel kan beholde versjonen den ble godkjent under.
public struct ResearchPIIAssessment: Codable, Equatable, Sendable {
    public var rulesVersion: String
    public var degree: String?
    public var violations: [String]
    public var applied: [String]
    public var rules: ResearchPIIRules.Rule?

    public var isAllowed: Bool { degree != nil && violations.isEmpty }
}

public enum ResearchPIIViolation {
    public static let unknownFieldKind = "unknown_field_kind"
    public static let degreeNotAllowed = "degree_not_allowed"
    public static let answerFormNotAllowed = "answer_form_not_allowed"
    public static let rowsRequireJustification = "rows_require_justification"
    public static let bucketTooFine = "bucket_too_fine"
    public static let populationBelowMinGroupSize = "population_below_min_group_size"
    public static let retentionTooLong = "retention_too_long"
    public static let exportNotAllowed = "export_not_allowed"
    public static let institutionalApprovalRequired = "institutional_approval_required"
}

public struct ResearchPIIRejection: Error, Equatable, Sendable, CustomStringConvertible {
    public var assessment: ResearchPIIAssessment
    public var description: String {
        "research request rejected (rules \(assessment.rulesVersion), degree \(assessment.degree ?? "unknown")): "
            + assessment.violations.joined(separator: ", ")
    }
}

public struct ResearchPIIAssessor: Sendable {
    public let rules: ResearchPIIRules

    public init(rules: ResearchPIIRules) {
        self.rules = rules
    }

    public func assess(_ request: ResearchPIIRequest) -> ResearchPIIAssessment {
        let rank = Dictionary(uniqueKeysWithValues: rules.degrees.map { ($0.id, $0.rank) })
        let byRank = Dictionary(uniqueKeysWithValues: rules.degrees.map { ($0.rank, $0.id) })
        let buckets = rules.bucketOrder

        if request.fields.contains(where: { rules.fieldKinds[$0.kind] == nil }) {
            return ResearchPIIAssessment(
                rulesVersion: rules.rulesVersion, degree: nil,
                violations: [ResearchPIIViolation.unknownFieldKind], applied: [], rules: nil
            )
        }
        let kinds = request.fields.compactMap { rules.fieldKinds[$0.kind] }
        let maxRank = kinds.compactMap { rank[$0] }.max() ?? 0
        guard var degree = byRank[maxRank], var effective = rules.rules[degree] else {
            return ResearchPIIAssessment(
                rulesVersion: rules.rulesVersion, degree: nil,
                violations: [ResearchPIIViolation.unknownFieldKind], applied: [], rules: nil
            )
        }
        let quasiCount = kinds.filter { $0 == "quasi" }.count
        var applied: [String] = []

        for escalation in rules.escalations {
            let when = escalation.when
            var hit = false
            if let atLeast = when.quasiFieldCountAtLeast, quasiCount >= atLeast { hit = true }
            if let longitudinal = when.researchQuestionLongitudinal,
               request.researchQuestion?.longitudinal == longitudinal { hit = true }
            if let multiple = when.populationBelowMultipleOfMinGroupSize,
               let population = request.populationSize,
               effective.minGroupSize > 0,
               population < multiple * effective.minGroupSize { hit = true }
            guard hit else { continue }
            applied.append(escalation.id)

            let effect = escalation.effect
            if let raised = effect.raiseDegreeTo, let raisedRank = rank[raised], let current = rank[degree],
               raisedRank > current, let raisedRule = rules.rules[raised] {
                degree = raised
                effective = raisedRule
            }
            if let factor = effect.multiplyMinGroupSize {
                effective.minGroupSize *= factor
            }
            if let coarser = effect.coarsenBucketTo, let finest = effective.finestBucket,
               let to = buckets.firstIndex(of: coarser), let from = buckets.firstIndex(of: finest), to > from {
                effective.finestBucket = coarser
            }
        }

        var violations: [String] = []
        if !effective.allowed { violations.append(ResearchPIIViolation.degreeNotAllowed) }
        let form = request.answerForm
        if form.map({ !effective.answerForms.contains($0) }) ?? true {
            violations.append(ResearchPIIViolation.answerFormNotAllowed)
        }
        let isRows = form == "pseudonymousRows" || form == "rows"
        if isRows, effective.requiresJustificationForRows, (request.justification ?? "").isEmpty {
            violations.append(ResearchPIIViolation.rowsRequireJustification)
        }
        if let bucket = request.bucket, let finest = effective.finestBucket {
            // Ukjent bøtte regnes som finere enn alle kjente.
            let asked = buckets.firstIndex(of: bucket) ?? -1
            if let floor = buckets.firstIndex(of: finest), asked < floor {
                violations.append(ResearchPIIViolation.bucketTooFine)
            }
        }
        if form == "aggregate", let population = request.populationSize, population < effective.minGroupSize {
            violations.append(ResearchPIIViolation.populationBelowMinGroupSize)
        }
        if let maxDays = effective.maxRetentionDays, let days = request.retentionDays, days > maxDays {
            violations.append(ResearchPIIViolation.retentionTooLong)
        }
        if request.export == true {
            if effective.export == "none" || (effective.export == "aggregateOnly" && form != "aggregate") {
                violations.append(ResearchPIIViolation.exportNotAllowed)
            }
        }
        if effective.requiresInstitutionalApproval, request.realParticipants == true,
           request.institutionalApproval != true {
            violations.append(ResearchPIIViolation.institutionalApprovalRequired)
        }
        return ResearchPIIAssessment(
            rulesVersion: rules.rulesVersion, degree: degree,
            violations: violations, applied: applied, rules: effective
        )
    }

    /// Gir vurderingen hvis forespørselen er tillatt, ellers `ResearchPIIRejection`.
    @discardableResult
    public func enforce(_ request: ResearchPIIRequest) throws -> ResearchPIIAssessment {
        let assessment = assess(request)
        guard assessment.isAllowed else { throw ResearchPIIRejection(assessment: assessment) }
        return assessment
    }
}
