// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// ClaimComposition follows the PurposeComposition shape but adds the two
// argumentation-specific semantics Purpose structures do not have:
// counterarguments with polarity (rebuts/undercuts) and graded leaf
// evaluation from source-audit evidence instead of binary resolution.
// Argument validity is evaluated here; the WeightedGraphRuntime remains a
// discovery/matching surface and must not be used for argument evaluation.

public struct ClaimCompositionLeaf: Codable, Equatable, Sendable {
    public var claimRef: String
    public var name: String?

    public init(claimRef: String, name: String? = nil) {
        self.claimRef = claimRef
        self.name = name
    }

    public init(_ claim: ClaimDefinition) {
        self.init(claimRef: claim.claimID, name: claim.statement)
    }
}

public enum ClaimCounterRole: String, Codable, Equatable, Sendable {
    // rebuts: argues the claim itself is false.
    case rebuts
    // undercuts: argues the support does not establish the claim.
    case undercuts
}

public struct ClaimCounter: Codable, Equatable, Sendable {
    public var role: ClaimCounterRole
    public var composition: ClaimComposition

    public init(role: ClaimCounterRole, composition: ClaimComposition) {
        self.role = role
        self.composition = composition
    }
}

public struct ClaimSupportRecord: Codable, Equatable, Sendable {
    public var claimRef: String
    public var sourceAuditStatus: ClaimSourceAuditStatus
    public var confidence: Double?
    public var checkedAt: TimeInterval

    public init(
        claimRef: String,
        sourceAuditStatus: ClaimSourceAuditStatus,
        confidence: Double? = nil,
        checkedAt: TimeInterval
    ) {
        self.claimRef = claimRef
        self.sourceAuditStatus = sourceAuditStatus
        self.confidence = confidence.map { max(0.0, min(1.0, $0)) }
        self.checkedAt = checkedAt
    }
}

// Conservative by default: unaudited or missing sources contribute no support.
// This matches the Book 27 acceptance criterion that source support is not
// claimed unless a source-auditor step has checked it.
public struct ClaimScorePolicy: Codable, Equatable, Sendable {
    public var supportedScore: Double
    public var partlySupportedScore: Double
    public var unauditedScore: Double
    public var missingScore: Double
    public var contradictedScore: Double

    public static let conservative = ClaimScorePolicy()

    public init(
        supportedScore: Double = 1.0,
        partlySupportedScore: Double = 0.5,
        unauditedScore: Double = 0.0,
        missingScore: Double = 0.0,
        contradictedScore: Double = 0.0
    ) {
        self.supportedScore = max(0.0, min(1.0, supportedScore))
        self.partlySupportedScore = max(0.0, min(1.0, partlySupportedScore))
        self.unauditedScore = max(0.0, min(1.0, unauditedScore))
        self.missingScore = max(0.0, min(1.0, missingScore))
        self.contradictedScore = max(0.0, min(1.0, contradictedScore))
    }

    public func score(for status: ClaimSourceAuditStatus) -> Double {
        switch status {
        case .supported:
            return supportedScore
        case .partlySupported:
            return partlySupportedScore
        case .contradicted:
            return contradictedScore
        case .sourceMissing, .notFound:
            return missingScore
        case .notCheckable, .textOnlyNotAudited, .needsExternalSourceAudit, .sourceCueWithoutAnchor:
            return unauditedScore
        }
    }
}

public struct ClaimCompositionEvaluationContext: Codable, Equatable {
    public var evaluatedAt: TimeInterval
    public var supportRecords: [ClaimSupportRecord]
    public var scorePolicy: ClaimScorePolicy

    public init(
        evaluatedAt: TimeInterval = Date().timeIntervalSince1970,
        supportRecords: [ClaimSupportRecord] = [],
        scorePolicy: ClaimScorePolicy = .conservative
    ) {
        self.evaluatedAt = evaluatedAt
        self.supportRecords = supportRecords
        self.scorePolicy = scorePolicy
    }

    public func latestSupportRecord(for claimRef: String) -> ClaimSupportRecord? {
        supportRecords
            .filter { record in
                record.claimRef == claimRef && record.checkedAt <= evaluatedAt
            }
            .max { lhs, rhs in
                lhs.checkedAt < rhs.checkedAt
            }
    }
}

public enum ClaimCompositionStatus: String, Codable, Equatable, Sendable {
    case supported
    case partial
    case unsupported
    // contradicted means a dominant rebuttal or contradicting evidence hit the
    // claim itself. A contradicted premise makes a parent unsupported, not
    // contradicted: denying a premise does not prove the negated conclusion.
    case contradicted
}

public struct ClaimCompositionEvaluation: Codable, Equatable {
    public var composition: ClaimComposition
    public var status: ClaimCompositionStatus
    public var score: Double
    public var supportedClaimRefs: [String]
    public var contradictedClaimRefs: [String]
    public var missingClaimRefs: [String]
    public var childResults: [ClaimCompositionEvaluation]
    public var blockingIndex: Int?
    public var blockingReason: String?

    public init(
        composition: ClaimComposition,
        status: ClaimCompositionStatus,
        score: Double,
        supportedClaimRefs: [String],
        contradictedClaimRefs: [String],
        missingClaimRefs: [String],
        childResults: [ClaimCompositionEvaluation] = [],
        blockingIndex: Int? = nil,
        blockingReason: String? = nil
    ) {
        self.composition = composition
        self.status = status
        self.score = max(0.0, min(1.0, score))
        self.supportedClaimRefs = Self.stableUnique(supportedClaimRefs)
        self.contradictedClaimRefs = Self.stableUnique(contradictedClaimRefs)
        self.missingClaimRefs = Self.stableUnique(missingClaimRefs)
        self.childResults = childResults
        self.blockingIndex = blockingIndex
        self.blockingReason = blockingReason
    }

    public var isSupported: Bool {
        status == .supported
    }

    static func stableUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result = [String]()
        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }
}

public indirect enum ClaimComposition: Codable, Equatable {
    case claim(ClaimCompositionLeaf)
    // allOf: linked premises, weakest link decides the score.
    case allOf([ClaimComposition])
    // anyOf: convergent support, strongest alternative decides the score.
    case anyOf([ClaimComposition])
    // atLeast: quorum support from independent lines of argument.
    case atLeast(requiredCount: Int, children: [ClaimComposition])
    // countered: a support expression under attack from counterarguments.
    case countered(base: ClaimComposition, counters: [ClaimCounter])

    enum CodingKeys: String, CodingKey {
        case type
        case claimRef
        case name
        case children
        case requiredCount
        case base
        case counters
    }

    enum CompositionType: String, Codable {
        case claim
        case allOf
        case anyOf
        case atLeast
        case countered
    }

    public static func leaf(_ claimRef: String, name: String? = nil) -> ClaimComposition {
        .claim(ClaimCompositionLeaf(claimRef: claimRef, name: name))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(CompositionType.self, forKey: .type)
        switch type {
        case .claim:
            self = .claim(
                ClaimCompositionLeaf(
                    claimRef: try container.decode(String.self, forKey: .claimRef),
                    name: try container.decodeIfPresent(String.self, forKey: .name)
                )
            )
        case .allOf:
            self = .allOf(try container.decode([ClaimComposition].self, forKey: .children))
        case .anyOf:
            self = .anyOf(try container.decode([ClaimComposition].self, forKey: .children))
        case .atLeast:
            self = .atLeast(
                requiredCount: try container.decode(Int.self, forKey: .requiredCount),
                children: try container.decode([ClaimComposition].self, forKey: .children)
            )
        case .countered:
            self = .countered(
                base: try container.decode(ClaimComposition.self, forKey: .base),
                counters: try container.decode([ClaimCounter].self, forKey: .counters)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .claim(let leaf):
            try container.encode(CompositionType.claim, forKey: .type)
            try container.encode(leaf.claimRef, forKey: .claimRef)
            try container.encodeIfPresent(leaf.name, forKey: .name)
        case .allOf(let children):
            try container.encode(CompositionType.allOf, forKey: .type)
            try container.encode(children, forKey: .children)
        case .anyOf(let children):
            try container.encode(CompositionType.anyOf, forKey: .type)
            try container.encode(children, forKey: .children)
        case .atLeast(let requiredCount, let children):
            try container.encode(CompositionType.atLeast, forKey: .type)
            try container.encode(requiredCount, forKey: .requiredCount)
            try container.encode(children, forKey: .children)
        case .countered(let base, let counters):
            try container.encode(CompositionType.countered, forKey: .type)
            try container.encode(base, forKey: .base)
            try container.encode(counters, forKey: .counters)
        }
    }

    // Structural enumeration of every referenced claim, including claims that
    // only appear inside counterarguments.
    public var leafClaimRefs: [String] {
        switch self {
        case .claim(let leaf):
            return [leaf.claimRef]
        case .allOf(let children), .anyOf(let children):
            return ClaimCompositionEvaluation.stableUnique(children.flatMap(\.leafClaimRefs))
        case .atLeast(_, let children):
            return ClaimCompositionEvaluation.stableUnique(children.flatMap(\.leafClaimRefs))
        case .countered(let base, let counters):
            return ClaimCompositionEvaluation.stableUnique(
                base.leafClaimRefs + counters.flatMap(\.composition.leafClaimRefs)
            )
        }
    }

    public func evaluate(in context: ClaimCompositionEvaluationContext) -> ClaimCompositionEvaluation {
        switch self {
        case .claim(let leaf):
            return evaluateLeaf(leaf, in: context)
        case .allOf(let children):
            return evaluateAll(children, in: context)
        case .anyOf(let children):
            return evaluateAny(children, in: context)
        case .atLeast(let requiredCount, let children):
            return evaluateAtLeast(requiredCount: requiredCount, children: children, in: context)
        case .countered(let base, let counters):
            return evaluateCountered(base: base, counters: counters, in: context)
        }
    }

    private func evaluateLeaf(
        _ leaf: ClaimCompositionLeaf,
        in context: ClaimCompositionEvaluationContext
    ) -> ClaimCompositionEvaluation {
        guard let record = context.latestSupportRecord(for: leaf.claimRef) else {
            return ClaimCompositionEvaluation(
                composition: self,
                status: .unsupported,
                score: 0.0,
                supportedClaimRefs: [],
                contradictedClaimRefs: [],
                missingClaimRefs: [leaf.claimRef],
                blockingReason: "missingSupportRecord"
            )
        }

        let confidence = record.confidence ?? 1.0
        let score = context.scorePolicy.score(for: record.sourceAuditStatus) * confidence

        switch record.sourceAuditStatus {
        case .supported:
            return ClaimCompositionEvaluation(
                composition: self,
                status: .supported,
                score: score,
                supportedClaimRefs: [leaf.claimRef],
                contradictedClaimRefs: [],
                missingClaimRefs: []
            )
        case .partlySupported:
            return ClaimCompositionEvaluation(
                composition: self,
                status: .partial,
                score: score,
                supportedClaimRefs: [],
                contradictedClaimRefs: [],
                missingClaimRefs: [],
                blockingReason: "partlySupportedEvidence"
            )
        case .contradicted:
            return ClaimCompositionEvaluation(
                composition: self,
                status: .contradicted,
                score: score,
                supportedClaimRefs: [],
                contradictedClaimRefs: [leaf.claimRef],
                missingClaimRefs: [],
                blockingReason: "contradictedEvidence"
            )
        case .sourceMissing, .notFound:
            return ClaimCompositionEvaluation(
                composition: self,
                status: .unsupported,
                score: score,
                supportedClaimRefs: [],
                contradictedClaimRefs: [],
                missingClaimRefs: [leaf.claimRef],
                blockingReason: "sourceMissing"
            )
        case .notCheckable, .textOnlyNotAudited, .needsExternalSourceAudit, .sourceCueWithoutAnchor:
            return ClaimCompositionEvaluation(
                composition: self,
                status: .unsupported,
                score: score,
                supportedClaimRefs: [],
                contradictedClaimRefs: [],
                missingClaimRefs: [leaf.claimRef],
                blockingReason: "sourceNotAudited"
            )
        }
    }

    private func evaluateAll(
        _ children: [ClaimComposition],
        in context: ClaimCompositionEvaluationContext
    ) -> ClaimCompositionEvaluation {
        let childResults = children.map { $0.evaluate(in: context) }
        guard !childResults.isEmpty else {
            return ClaimCompositionEvaluation(
                composition: self,
                status: .supported,
                score: 1.0,
                supportedClaimRefs: [],
                contradictedClaimRefs: [],
                missingClaimRefs: [],
                childResults: []
            )
        }

        let supportedCount = childResults.filter(\.isSupported).count
        let score = childResults.map(\.score).min() ?? 0.0
        let firstContradictedIndex = childResults.firstIndex { $0.status == .contradicted }

        let status: ClaimCompositionStatus
        let blockingIndex: Int?
        let blockingReason: String?
        if supportedCount == childResults.count {
            status = .supported
            blockingIndex = nil
            blockingReason = nil
        } else if let firstContradictedIndex {
            status = .unsupported
            blockingIndex = firstContradictedIndex
            blockingReason = "premiseContradicted"
        } else if supportedCount > 0 || childResults.contains(where: { $0.status == .partial }) {
            status = .partial
            blockingIndex = childResults.firstIndex { !$0.isSupported }
            blockingReason = "requiredChildUnsupported"
        } else {
            status = .unsupported
            blockingIndex = childResults.firstIndex { !$0.isSupported }
            blockingReason = "requiredChildUnsupported"
        }

        return ClaimCompositionEvaluation(
            composition: self,
            status: status,
            score: status == .unsupported ? 0.0 : score,
            supportedClaimRefs: childResults.flatMap(\.supportedClaimRefs),
            contradictedClaimRefs: childResults.flatMap(\.contradictedClaimRefs),
            missingClaimRefs: childResults.flatMap(\.missingClaimRefs),
            childResults: childResults,
            blockingIndex: blockingIndex,
            blockingReason: blockingReason
        )
    }

    private func evaluateAny(
        _ children: [ClaimComposition],
        in context: ClaimCompositionEvaluationContext
    ) -> ClaimCompositionEvaluation {
        let childResults = children.map { $0.evaluate(in: context) }
        guard !childResults.isEmpty else {
            return ClaimCompositionEvaluation(
                composition: self,
                status: .unsupported,
                score: 0.0,
                supportedClaimRefs: [],
                contradictedClaimRefs: [],
                missingClaimRefs: [],
                childResults: [],
                blockingReason: "noAlternatives"
            )
        }

        let hasSupportedChild = childResults.contains { $0.isSupported }
        let hasPartialChild = childResults.contains { $0.status == .partial }
        let status: ClaimCompositionStatus = hasSupportedChild ? .supported : (hasPartialChild ? .partial : .unsupported)

        return ClaimCompositionEvaluation(
            composition: self,
            status: status,
            score: childResults.map(\.score).max() ?? 0.0,
            supportedClaimRefs: childResults.flatMap(\.supportedClaimRefs),
            contradictedClaimRefs: childResults.flatMap(\.contradictedClaimRefs),
            missingClaimRefs: status == .supported ? [] : childResults.flatMap(\.missingClaimRefs),
            childResults: childResults,
            blockingIndex: status == .supported ? nil : 0,
            blockingReason: status == .supported ? nil : "noAlternativeSupported"
        )
    }

    private func evaluateAtLeast(
        requiredCount: Int,
        children: [ClaimComposition],
        in context: ClaimCompositionEvaluationContext
    ) -> ClaimCompositionEvaluation {
        let childResults = children.map { $0.evaluate(in: context) }
        let boundedRequiredCount = max(0, requiredCount)
        guard boundedRequiredCount > 0 else {
            return ClaimCompositionEvaluation(
                composition: self,
                status: .supported,
                score: 1.0,
                supportedClaimRefs: childResults.flatMap(\.supportedClaimRefs),
                contradictedClaimRefs: childResults.flatMap(\.contradictedClaimRefs),
                missingClaimRefs: [],
                childResults: childResults
            )
        }

        let supportedCount = childResults.filter(\.isSupported).count
        let topScores = childResults.map(\.score).sorted(by: >).prefix(boundedRequiredCount)
        let score = topScores.reduce(0.0, +) / Double(boundedRequiredCount)

        let status: ClaimCompositionStatus
        if supportedCount >= boundedRequiredCount {
            status = .supported
        } else if supportedCount > 0 || childResults.contains(where: { $0.status == .partial }) {
            status = .partial
        } else {
            status = .unsupported
        }

        return ClaimCompositionEvaluation(
            composition: self,
            status: status,
            score: score,
            supportedClaimRefs: childResults.flatMap(\.supportedClaimRefs),
            contradictedClaimRefs: childResults.flatMap(\.contradictedClaimRefs),
            missingClaimRefs: status == .supported ? [] : childResults.flatMap(\.missingClaimRefs),
            childResults: childResults,
            blockingIndex: status == .supported ? nil : childResults.firstIndex { !$0.isSupported },
            blockingReason: status == .supported ? nil : "tooFewChildrenSupported"
        )
    }

    // Counter evaluations appear in childResults after the base result, but
    // their supported/missing ledgers are not merged into the parent: a claim
    // that supports a counterargument does not support the countered claim.
    private func evaluateCountered(
        base: ClaimComposition,
        counters: [ClaimCounter],
        in context: ClaimCompositionEvaluationContext
    ) -> ClaimCompositionEvaluation {
        let baseResult = base.evaluate(in: context)
        let counterResults = counters.map { counter in
            (role: counter.role, result: counter.composition.evaluate(in: context))
        }

        let rebutScore = counterResults
            .filter { $0.role == .rebuts }
            .map(\.result.score)
            .max() ?? 0.0
        let undercutScore = counterResults
            .filter { $0.role == .undercuts }
            .map(\.result.score)
            .max() ?? 0.0

        let effectiveScore = max(0.0, baseResult.score - rebutScore) * (1.0 - undercutScore)
        let childResults = [baseResult] + counterResults.map(\.result)

        let status: ClaimCompositionStatus
        let blockingReason: String?
        if rebutScore > 0.0 && rebutScore >= baseResult.score {
            status = .contradicted
            blockingReason = "rebuttalDominates"
        } else if effectiveScore >= baseResult.score {
            status = baseResult.status
            blockingReason = baseResult.blockingReason
        } else if effectiveScore > 0.0 {
            status = .partial
            blockingReason = "counteredSupportReduced"
        } else if baseResult.score > 0.0 {
            status = .unsupported
            blockingReason = "counteredSupportEliminated"
        } else {
            status = baseResult.status
            blockingReason = baseResult.blockingReason
        }

        return ClaimCompositionEvaluation(
            composition: self,
            status: status,
            score: status == .contradicted ? 0.0 : effectiveScore,
            supportedClaimRefs: baseResult.supportedClaimRefs,
            contradictedClaimRefs: baseResult.contradictedClaimRefs,
            missingClaimRefs: baseResult.missingClaimRefs,
            childResults: childResults,
            blockingIndex: status == baseResult.status ? baseResult.blockingIndex : nil,
            blockingReason: blockingReason
        )
    }
}
