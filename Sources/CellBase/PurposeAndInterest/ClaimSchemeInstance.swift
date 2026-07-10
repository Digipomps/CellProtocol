// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// A scheme applied to a specific claim, with the state of each critical
// question. Evaluation turns that state into the two things the panel workflow
// consumes: unexamined questions become deduced subtasks, challenged questions
// become undercutting defeaters that plug into ClaimComposition evaluation.

public enum CriticalQuestionStatus: String, Codable, Hashable, Sendable {
    // unexamined: the default on instantiation; a gap the loop should close.
    case unexamined
    // answered: addressed satisfactorily; no longer a gap.
    case answered
    // challenged: raised and the answer undermines the argument (undercut).
    case challenged
    // notApplicable: the question does not apply to this instance.
    case notApplicable = "not-applicable"
}

public struct CriticalQuestionState: Codable, Equatable, Sendable {
    public var cqID: String
    public var question: String
    public var status: CriticalQuestionStatus
    // Link to the claim that answers or challenges the question, when one exists.
    public var addressedByClaimRef: String?
    public var note: String?

    public init(
        cqID: String,
        question: String,
        status: CriticalQuestionStatus = .unexamined,
        addressedByClaimRef: String? = nil,
        note: String? = nil
    ) {
        self.cqID = cqID
        self.question = question
        self.status = status
        self.addressedByClaimRef = addressedByClaimRef
        self.note = note
    }
}

public struct ClaimSchemeInstance: Codable, Equatable, Sendable {
    public static let schemaID = "haven.claim-scheme.v0"

    public var schema: String
    public var instanceID: String
    public var kind: ClaimSchemeKind
    // The claim whose inferential step this scheme describes.
    public var claimRef: String
    // Scheme premise role -> claimRef or literal text.
    public var slotBindings: [String: String]
    public var criticalQuestions: [CriticalQuestionState]

    // When criticalQuestions is left empty, the catalog populates the full set
    // as unexamined. This makes the catalog the default source of truth and
    // keeps authored instances honest: you cannot silently drop a question.
    public init(
        schema: String = ClaimSchemeInstance.schemaID,
        instanceID: String,
        kind: ClaimSchemeKind,
        claimRef: String,
        slotBindings: [String: String] = [:],
        criticalQuestions: [CriticalQuestionState] = []
    ) {
        self.schema = schema
        self.instanceID = instanceID
        self.kind = kind
        self.claimRef = claimRef
        self.slotBindings = slotBindings
        if criticalQuestions.isEmpty {
            self.criticalQuestions = ClaimSchemeCatalog.criticalQuestions(for: kind).map {
                CriticalQuestionState(cqID: $0.cqID, question: $0.question, status: .unexamined)
            }
        } else {
            self.criticalQuestions = criticalQuestions
        }
    }
}

public enum ClaimSchemeStatus: String, Codable, Equatable, Sendable {
    // wellSupported: every applicable critical question is answered.
    case wellSupported = "well-supported"
    // open: some questions are unexamined, none challenged.
    case open
    // challenged: at least one critical question is challenged.
    case challenged
}

public struct ClaimSchemeEvaluation: Codable, Equatable, Sendable {
    public var instanceID: String
    public var kind: ClaimSchemeKind
    public var claimRef: String
    public var status: ClaimSchemeStatus
    public var applicableCQCount: Int
    public var answeredCQCount: Int
    // answered / applicable, or 1.0 when nothing applies.
    public var completeness: Double
    public var unexaminedCQs: [CriticalQuestionState]
    public var challengedCQs: [CriticalQuestionState]

    public init(
        instanceID: String,
        kind: ClaimSchemeKind,
        claimRef: String,
        status: ClaimSchemeStatus,
        applicableCQCount: Int,
        answeredCQCount: Int,
        completeness: Double,
        unexaminedCQs: [CriticalQuestionState],
        challengedCQs: [CriticalQuestionState]
    ) {
        self.instanceID = instanceID
        self.kind = kind
        self.claimRef = claimRef
        self.status = status
        self.applicableCQCount = applicableCQCount
        self.answeredCQCount = answeredCQCount
        self.completeness = max(0.0, min(1.0, completeness))
        self.unexaminedCQs = unexaminedCQs
        self.challengedCQs = challengedCQs
    }
}

public extension ClaimSchemeInstance {
    // Deterministic: iterates criticalQuestions in stored order, so the same
    // instance always yields the same evaluation.
    func evaluate() -> ClaimSchemeEvaluation {
        var applicable = 0
        var answered = 0
        var unexamined = [CriticalQuestionState]()
        var challenged = [CriticalQuestionState]()

        for cq in criticalQuestions {
            switch cq.status {
            case .notApplicable:
                continue
            case .answered:
                applicable += 1
                answered += 1
            case .unexamined:
                applicable += 1
                unexamined.append(cq)
            case .challenged:
                applicable += 1
                challenged.append(cq)
            }
        }

        let status: ClaimSchemeStatus
        if !challenged.isEmpty {
            status = .challenged
        } else if !unexamined.isEmpty {
            status = .open
        } else {
            status = .wellSupported
        }

        let completeness = applicable == 0 ? 1.0 : Double(answered) / Double(applicable)

        return ClaimSchemeEvaluation(
            instanceID: instanceID,
            kind: kind,
            claimRef: claimRef,
            status: status,
            applicableCQCount: applicable,
            answeredCQCount: answered,
            completeness: completeness,
            unexaminedCQs: unexamined,
            challengedCQs: challenged
        )
    }

    // Bridge to the graded argument evaluation: each challenged critical
    // question becomes an undercutting defeater. A challenged CQ argues the
    // support does not establish the claim, which is exactly Pollock's
    // undercut, so it maps to ClaimCounterRole.undercuts. The counter leaf
    // uses the answering/challenging claim when one is linked, otherwise the
    // question id, so the undercut can be scored like any other claim.
    func undercutCounters() -> [ClaimCounter] {
        criticalQuestions
            .filter { $0.status == .challenged }
            .map { cq in
                let ref = cq.addressedByClaimRef ?? cq.cqID
                return ClaimCounter(role: .undercuts, composition: .leaf(ref, name: cq.question))
            }
    }

    // Wrap a base composition with the undercuts implied by challenged CQs.
    // Returns the base unchanged when nothing is challenged, so it is safe to
    // apply unconditionally.
    func applyingChallenges(to base: ClaimComposition) -> ClaimComposition {
        let counters = undercutCounters()
        guard !counters.isEmpty else { return base }
        return .countered(base: base, counters: counters)
    }

    // The unexamined critical questions, phrased as the work items a panel
    // round should schedule. Each is tagged with the claim it belongs to.
    func deducedSubtasks() -> [String] {
        criticalQuestions
            .filter { $0.status == .unexamined }
            .map { "[\(claimRef)] \($0.question)" }
    }
}
