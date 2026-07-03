// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// Claim vocabulary is shared with the text reliability analysis contract in
// CellProtocolDocuments/Book/27_Text_Reliability_Analysis.md. Raw values must
// stay wire-identical with that contract so analysis artifacts and runtime
// claim structures can exchange claims without translation.

public enum ClaimType: String, Codable, Hashable, Sendable {
    case factual
    case causal
    case normative
    case predictive
    case statistical
    case projectCapability = "project_capability"
}

public enum ClaimStrength: String, Codable, Hashable, Sendable {
    case assertive
    case moderated
    case speculative
}

public enum ClaimSourceAuditStatus: String, Codable, Hashable, Sendable {
    case supported
    case partlySupported = "partly_supported"
    case contradicted
    case sourceMissing = "source_missing"
    case notFound = "not_found"
    case notCheckable = "not_checkable"
    case textOnlyNotAudited = "text_only_not_audited"
    case needsExternalSourceAudit = "needs_external_source_audit"
    case sourceCueWithoutAnchor = "source_cue_without_anchor"
}

// Support-node kinds mirror the argument-graph layer-1 node types:
// evidens, antakelse, kvalifikator, motargument.
public enum ClaimSupportKind: String, Codable, Hashable, Sendable {
    case evidence
    case assumption
    case qualifier
    case counterargument
}

public struct ClaimSupportNode: Codable, Hashable, Sendable {
    public var supportID: String
    public var kind: ClaimSupportKind
    public var statement: String
    public var sourceRefs: [String]
    public var sourceAuditStatus: ClaimSourceAuditStatus
    public var confidence: Double?

    public init(
        supportID: String,
        kind: ClaimSupportKind,
        statement: String,
        sourceRefs: [String] = [],
        sourceAuditStatus: ClaimSourceAuditStatus = .textOnlyNotAudited,
        confidence: Double? = nil
    ) {
        self.supportID = supportID
        self.kind = kind
        self.statement = statement
        self.sourceRefs = sourceRefs
        self.sourceAuditStatus = sourceAuditStatus
        self.confidence = confidence.map { max(0.0, min(1.0, $0)) }
    }
}

public struct ClaimDefinition: Codable, Equatable, Sendable {
    public static let schemaID = "haven.claim-definition.v0"

    public var schema: String
    public var claimID: String
    public var statement: String
    public var claimType: ClaimType
    public var strength: ClaimStrength
    // Exact quote anchor when the claim was extracted from a source text.
    // Authored claims (for example investor-case artifacts) may leave it nil.
    public var quote: String?
    public var isInferred: Bool
    public var sourceRefs: [String]
    // Optional link to the declared Purpose (Formål) this claim belongs to.
    public var purposeRef: String?
    // Optional link to a GoalDefinition that makes this claim testable
    // (metric, baseline, target, evidence sources).
    public var goalID: String?
    public var supports: [ClaimSupportNode]
    public var composition: ClaimComposition?
    public var tags: [String]

    public init(
        schema: String = ClaimDefinition.schemaID,
        claimID: String,
        statement: String,
        claimType: ClaimType,
        strength: ClaimStrength = .assertive,
        quote: String? = nil,
        isInferred: Bool = false,
        sourceRefs: [String] = [],
        purposeRef: String? = nil,
        goalID: String? = nil,
        supports: [ClaimSupportNode] = [],
        composition: ClaimComposition? = nil,
        tags: [String] = []
    ) {
        self.schema = schema
        self.claimID = claimID
        self.statement = statement
        self.claimType = claimType
        self.strength = strength
        self.quote = quote
        self.isInferred = isInferred
        self.sourceRefs = sourceRefs
        self.purposeRef = purposeRef
        self.goalID = goalID
        self.supports = supports
        self.composition = composition
        self.tags = tags
    }
}

public extension ClaimDefinition {
    func evaluateComposition(in context: ClaimCompositionEvaluationContext) -> ClaimCompositionEvaluation {
        let expression = composition ?? .claim(ClaimCompositionLeaf(claimRef: claimID, name: statement))
        return expression.evaluate(in: context)
    }
}
