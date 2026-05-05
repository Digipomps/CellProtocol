// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import HavenCoreSchemas

public struct PurposeTreeValidationIssue: Codable, Hashable, Sendable {
    public enum Severity: String, Codable, CaseIterable, Sendable {
        case error
        case warning
    }

    public var severity: Severity
    public var code: String
    public var message: String
    public var termID: String?
    public var relatedTermID: String?

    public init(
        severity: Severity,
        code: String,
        message: String,
        termID: String? = nil,
        relatedTermID: String? = nil
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.termID = termID
        self.relatedTermID = relatedTermID
    }

    enum CodingKeys: String, CodingKey {
        case severity
        case code
        case message
        case termID = "term_id"
        case relatedTermID = "related_term_id"
    }
}

public struct PurposeTreeValidationResult: Codable, Hashable, Sendable {
    public var namespace: String
    public var mandatoryPurposeTermIDs: [String]
    public var issues: [PurposeTreeValidationIssue]
    public var errorCount: Int
    public var warningCount: Int
    public var isValid: Bool

    public init(
        namespace: String,
        mandatoryPurposeTermIDs: [String],
        issues: [PurposeTreeValidationIssue]
    ) {
        self.namespace = namespace
        self.mandatoryPurposeTermIDs = mandatoryPurposeTermIDs
        self.issues = issues
        self.errorCount = issues.filter { $0.severity == .error }.count
        self.warningCount = issues.filter { $0.severity == .warning }.count
        self.isValid = errorCount == 0
    }

    enum CodingKeys: String, CodingKey {
        case namespace
        case mandatoryPurposeTermIDs = "mandatory_purpose_term_ids"
        case issues
        case errorCount = "error_count"
        case warningCount = "warning_count"
        case isValid = "is_valid"
    }
}

public struct ResolvedTaxonomyTerm: Codable, Hashable, Sendable {
    public var term: Term
    public var sourceNamespace: String
    public var label: String
    public var requestedLocale: String?
    public var resolvedLocale: String?
    public var fallbackUsed: Bool
    public var replacementTerm: Term?

    public init(
        term: Term,
        sourceNamespace: String,
        label: String,
        replacementTerm: Term?,
        requestedLocale: String? = nil,
        resolvedLocale: String? = nil,
        fallbackUsed: Bool = false
    ) {
        self.term = term
        self.sourceNamespace = sourceNamespace
        self.label = label
        self.requestedLocale = LocalizationDefaults.normalizedLocale(requestedLocale)
        self.resolvedLocale = LocalizationDefaults.normalizedLocale(resolvedLocale)
        self.fallbackUsed = fallbackUsed
        self.replacementTerm = replacementTerm
    }

    enum CodingKeys: String, CodingKey {
        case term
        case sourceNamespace = "source_namespace"
        case label
        case requestedLocale = "requested_locale"
        case resolvedLocale = "resolved_locale"
        case fallbackUsed = "fallback_used"
        case replacementTerm = "replacement_term"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        term = try container.decode(Term.self, forKey: .term)
        sourceNamespace = try container.decode(String.self, forKey: .sourceNamespace)
        label = try container.decode(String.self, forKey: .label)
        requestedLocale = try container.decodeIfPresent(String.self, forKey: .requestedLocale)
        resolvedLocale = try container.decodeIfPresent(String.self, forKey: .resolvedLocale)
        fallbackUsed = try container.decodeIfPresent(Bool.self, forKey: .fallbackUsed) ?? false
        replacementTerm = try container.decodeIfPresent(Term.self, forKey: .replacementTerm)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(term, forKey: .term)
        try container.encode(sourceNamespace, forKey: .sourceNamespace)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(requestedLocale, forKey: .requestedLocale)
        try container.encodeIfPresent(resolvedLocale, forKey: .resolvedLocale)
        try container.encode(fallbackUsed, forKey: .fallbackUsed)
        try container.encodeIfPresent(replacementTerm, forKey: .replacementTerm)
    }
}

public struct TaxonomyTermResolver: Sendable {
    public let registry: TaxonomyRegistry

    public init(registry: TaxonomyRegistry) {
        self.registry = registry
    }

    public func resolve(termID: String, lang: String, namespace: String? = nil) throws -> ResolvedTaxonomyTerm? {
        guard let record = try registry.lookupTerm(termID: termID, namespace: namespace) else {
            return nil
        }

        let term = record.term
        let replacementTerm: Term?
        if let replacementID = term.replacedBy {
            replacementTerm = try registry.lookupTerm(termID: replacementID, namespace: namespace)?.term
        } else {
            replacementTerm = nil
        }

        let labelResolution = localizedLabelResolution(for: term, lang: lang)

        return ResolvedTaxonomyTerm(
            term: term,
            sourceNamespace: record.namespace,
            label: labelResolution.value,
            replacementTerm: replacementTerm,
            requestedLocale: labelResolution.requestedLocale,
            resolvedLocale: labelResolution.resolvedLocale,
            fallbackUsed: labelResolution.fallbackUsed
        )
    }

    public func resolveLocalizedTerm(termID: String, lang: String, namespace: String? = nil) throws -> ResolvedLocalizedTerm? {
        guard let resolved = try resolve(termID: termID, lang: lang, namespace: namespace) else {
            return nil
        }

        return ResolvedLocalizedTerm(
            termID: resolved.term.termId,
            namespace: resolved.sourceNamespace,
            kind: resolved.term.kind,
            label: resolved.label,
            requestedLocale: resolved.requestedLocale,
            resolvedLocale: resolved.resolvedLocale,
            fallbackUsed: resolved.fallbackUsed
        )
    }

    public func term(termID: String, namespace: String? = nil) throws -> Term? {
        try registry.lookupTerm(termID: termID, namespace: namespace)?.term
    }

    public func guidance(namespace: String) throws -> TaxonomyPackage.Guidance? {
        for package in try registry.resolutionOrder(startingAt: namespace) {
            if let guidance = package.guidance {
                return guidance
            }
        }

        return nil
    }

    public func validatePurposeTree(namespace: String) throws -> PurposeTreeValidationResult {
        var issues: [PurposeTreeValidationIssue] = []
        guard let guidance = try guidance(namespace: namespace) else {
            issues.append(
                PurposeTreeValidationIssue(
                    severity: .error,
                    code: "guidance.missing",
                    message: "No taxonomy guidance found for namespace '\(namespace)'."
                )
            )
            return PurposeTreeValidationResult(namespace: namespace, mandatoryPurposeTermIDs: [], issues: issues)
        }

        let packages = try registry.resolutionOrder(startingAt: namespace)

        // Respect namespace precedence: first package wins for duplicate term ids.
        var effectiveTerms: [String: Term] = [:]
        for package in packages {
            for term in package.terms where effectiveTerms[term.termId] == nil {
                effectiveTerms[term.termId] = term
            }
        }

        let activePurposes = effectiveTerms.values.filter { $0.kind == .purpose && !$0.deprecated }
        let purposesByID = Dictionary(uniqueKeysWithValues: activePurposes.map { ($0.termId, $0) })
        let goals = effectiveTerms.values.filter { $0.kind == .goal && !$0.deprecated }

        let mandatoryPurposeIDs = guidance.mandatoryInheritedPurposes
        let mandatoryPurposeSet = Set(mandatoryPurposeIDs)
        let forbiddenRelations = Set(guidance.forbiddenRelationsToMandatory)

        for mandatoryID in mandatoryPurposeIDs {
            guard let mandatoryPurpose = purposesByID[mandatoryID] else {
                issues.append(
                    PurposeTreeValidationIssue(
                        severity: .error,
                        code: "mandatory_purpose.missing",
                        message: "Mandatory purpose '\(mandatoryID)' is not present as an active purpose term.",
                        termID: mandatoryID
                    )
                )
                continue
            }

            if mandatoryPurpose.kind != .purpose {
                issues.append(
                    PurposeTreeValidationIssue(
                        severity: .error,
                        code: "mandatory_purpose.invalid_kind",
                        message: "Mandatory term '\(mandatoryID)' must be kind=purpose.",
                        termID: mandatoryID
                    )
                )
            }
        }

        var goalsByPurposeID: [String: Set<String>] = [:]
        for goal in goals {
            for relation in goal.relations where relation.kind == .usedWith {
                goalsByPurposeID[relation.target, default: []].insert(goal.termId)
            }
        }

        for mandatoryID in mandatoryPurposeIDs {
            if (goalsByPurposeID[mandatoryID] ?? []).isEmpty {
                issues.append(
                    PurposeTreeValidationIssue(
                        severity: .error,
                        code: "mandatory_purpose.goal_missing",
                        message: "Mandatory purpose '\(mandatoryID)' must have at least one linked goal (relation kind=used_with).",
                        termID: mandatoryID
                    )
                )
            }
        }

        let inheritanceRelationKinds: Set<Term.RelationKind> = [.broader, .narrower, .related]
        var adjacency: [String: Set<String>] = [:]
        for purpose in activePurposes {
            for relation in purpose.relations where inheritanceRelationKinds.contains(relation.kind) {
                guard purposesByID[relation.target] != nil else { continue }
                adjacency[purpose.termId, default: []].insert(relation.target)
                adjacency[relation.target, default: []].insert(purpose.termId)
            }
        }

        func hasPathToMandatory(start: String) -> Bool {
            if mandatoryPurposeSet.contains(start) {
                return true
            }

            var queue: [String] = [start]
            var visited: Set<String> = [start]

            while !queue.isEmpty {
                let current = queue.removeFirst()
                for next in adjacency[current] ?? [] {
                    if mandatoryPurposeSet.contains(next) {
                        return true
                    }
                    if visited.insert(next).inserted {
                        queue.append(next)
                    }
                }
            }

            return false
        }

        for purpose in activePurposes where !mandatoryPurposeSet.contains(purpose.termId) {
            if !hasPathToMandatory(start: purpose.termId) {
                issues.append(
                    PurposeTreeValidationIssue(
                        severity: .error,
                        code: "purpose.inheritance_missing",
                        message: "Purpose '\(purpose.termId)' has no inheritance path to mandatory purpose roots.",
                        termID: purpose.termId
                    )
                )
            }
        }

        for purpose in activePurposes {
            for relation in purpose.relations where forbiddenRelations.contains(relation.kind) {
                if mandatoryPurposeSet.contains(relation.target), relation.target != purpose.termId {
                    issues.append(
                        PurposeTreeValidationIssue(
                            severity: .error,
                            code: "purpose.conflicts_with_mandatory",
                            message: "Purpose '\(purpose.termId)' has forbidden relation '\(relation.kind.rawValue)' to mandatory purpose '\(relation.target)'.",
                            termID: purpose.termId,
                            relatedTermID: relation.target
                        )
                    )
                }
            }
        }

        if guidance.goalPolicy.mode == .encouraged {
            for purpose in activePurposes where !mandatoryPurposeSet.contains(purpose.termId) {
                if (goalsByPurposeID[purpose.termId] ?? []).isEmpty {
                    issues.append(
                        PurposeTreeValidationIssue(
                            severity: .warning,
                            code: "purpose.goal_encouraged_missing",
                            message: "Purpose '\(purpose.termId)' has no linked goals. Guidance mode is encouraged.",
                            termID: purpose.termId
                        )
                    )
                }
            }
        }

        return PurposeTreeValidationResult(
            namespace: namespace,
            mandatoryPurposeTermIDs: mandatoryPurposeIDs,
            issues: issues
        )
    }

    public func validateLocalizationCoverage(
        namespace: String,
        requiredLocales: [String] = LocalizationDefaults.defaultRequiredLocales
    ) throws -> TaxonomyLocalizationCoverageResult {
        let packages = try registry.resolutionOrder(startingAt: namespace)
        let requiredLocales = LocalizationDefaults.unique(requiredLocales)

        // Respect namespace precedence: first package wins for duplicate term ids.
        var effectiveTerms: [(term: Term, namespace: String)] = []
        var seen = Set<String>()
        for package in packages {
            for term in package.terms where seen.insert(term.termId).inserted {
                effectiveTerms.append((term, package.namespace))
            }
        }

        var issues: [TaxonomyLocalizationCoverageIssue] = []
        for record in effectiveTerms where !record.term.deprecated {
            for locale in requiredLocales where record.term.labels[locale] == nil {
                issues.append(
                    TaxonomyLocalizationCoverageIssue(
                        namespace: record.namespace,
                        termID: record.term.termId,
                        kind: record.term.kind,
                        locale: locale,
                        message: "Term '\(record.term.termId)' is missing label for locale '\(locale)'."
                    )
                )
            }
        }

        return TaxonomyLocalizationCoverageResult(
            namespace: namespace,
            requiredLocales: requiredLocales,
            issues: issues.sorted {
                if $0.namespace == $1.namespace {
                    if $0.termID == $1.termID {
                        return $0.locale < $1.locale
                    }
                    return $0.termID < $1.termID
                }
                return $0.namespace < $1.namespace
            }
        )
    }

    public func localizedLabel(for term: Term, lang: String) -> String {
        localizedLabelResolution(for: term, lang: lang).value
    }

    public func localizedLabelResolution(for term: Term, lang: String) -> ResolvedLocalizedText {
        LocalizationDefaults.resolveText(
            values: term.labels,
            requestedLocale: lang,
            fallbackValue: term.termId
        ) ?? ResolvedLocalizedText(
            value: term.termId,
            requestedLocale: lang,
            resolvedLocale: nil,
            fallbackUsed: true
        )
    }
}
