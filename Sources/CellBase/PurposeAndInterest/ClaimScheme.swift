// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// Argumentation schemes (Walton) layered on top of the claim model. A scheme
// names the inferential pattern a claim relies on and carries a fixed set of
// critical questions. Unexamined critical questions are the gaps a panel loop
// turns into deduced subtasks; a challenged critical question is an
// undercutting defeater on the claim's support. This keeps the model in the
// service of making reasoning inspectable rather than computing a verdict.

public enum ClaimSchemeKind: String, Codable, Hashable, Sendable, CaseIterable {
    case expertOpinion = "expert-opinion"
    case analogy
    case causeToEffect = "cause-to-effect"
    case sign
    case practicalReasoning = "practical-reasoning"
    case popularOpinion = "popular-opinion"
    case positiveConsequences = "positive-consequences"
    case negativeConsequences = "negative-consequences"
    case example
    case verbalClassification = "verbal-classification"
}

public struct CriticalQuestion: Codable, Hashable, Sendable {
    public var cqID: String
    public var question: String

    public init(_ cqID: String, _ question: String) {
        self.cqID = cqID
        self.question = question
    }
}

// The catalog is the normative source of critical questions per scheme. Keeping
// it deterministic and code-local (rather than free-form per instance) is what
// lets the panel loop rely on the same gap set every time a scheme is used.
public enum ClaimSchemeCatalog {
    public static func criticalQuestions(for kind: ClaimSchemeKind) -> [CriticalQuestion] {
        switch kind {
        case .expertOpinion:
            return [
                CriticalQuestion("expert-opinion.expertise", "How credible is the source as an expert?"),
                CriticalQuestion("expert-opinion.field", "Is the source an expert in the field the claim falls under?"),
                CriticalQuestion("expert-opinion.assertion", "Did the source actually assert the claim, quoted accurately and in context?"),
                CriticalQuestion("expert-opinion.trustworthiness", "Is the source personally reliable and free of bias or conflict of interest?"),
                CriticalQuestion("expert-opinion.consistency", "Is the claim consistent with what other experts assert?"),
                CriticalQuestion("expert-opinion.evidence", "Is the source's assertion based on evidence?")
            ]
        case .analogy:
            return [
                CriticalQuestion("analogy.similarity", "Are the two cases similar in the respects cited?"),
                CriticalQuestion("analogy.differences", "Are there relevant differences that weaken the analogy?"),
                CriticalQuestion("analogy.counter-analogy", "Is there a more similar case that points to a different conclusion?")
            ]
        case .causeToEffect:
            return [
                CriticalQuestion("cause-to-effect.causal-law", "Is there a general causal relationship linking the cause and the effect?"),
                CriticalQuestion("cause-to-effect.strength", "Is the causal link strong, or could it be mere correlation?"),
                CriticalQuestion("cause-to-effect.interference", "Could intervening factors prevent the effect in this case?")
            ]
        case .sign:
            return [
                CriticalQuestion("sign.reliability", "Is the sign a reliable indicator of the claimed event?"),
                CriticalQuestion("sign.alternatives", "Could other events account for the sign equally well?")
            ]
        case .practicalReasoning:
            return [
                CriticalQuestion("practical-reasoning.alternatives", "Are there alternative actions that would reach the goal?"),
                CriticalQuestion("practical-reasoning.efficiency", "Is the proposed action the best or most efficient means?"),
                CriticalQuestion("practical-reasoning.side-effects", "Does the action have side effects or conflict with other goals?"),
                CriticalQuestion("practical-reasoning.feasibility", "Is the action actually possible to carry out?")
            ]
        case .popularOpinion:
            return [
                CriticalQuestion("popular-opinion.actual", "Does the majority actually accept the claim?"),
                CriticalQuestion("popular-opinion.relevance", "Is popular acceptance a relevant reason to accept it here?"),
                CriticalQuestion("popular-opinion.evidence", "Is there evidence for the claim beyond its popularity?")
            ]
        case .positiveConsequences:
            return [
                CriticalQuestion("positive-consequences.likelihood", "How likely are the cited positive consequences to occur?"),
                CriticalQuestion("positive-consequences.evidence", "Is there evidence that the consequences will follow from the action?"),
                CriticalQuestion("positive-consequences.counterbalance", "Are there negative consequences that outweigh them?")
            ]
        case .negativeConsequences:
            return [
                CriticalQuestion("negative-consequences.likelihood", "How likely are the cited negative consequences to occur?"),
                CriticalQuestion("negative-consequences.evidence", "Is there evidence that the consequences will follow from the action?"),
                CriticalQuestion("negative-consequences.counterbalance", "Are there positive consequences that outweigh them?")
            ]
        case .example:
            return [
                CriticalQuestion("example.instance", "Is the example actually an instance of the generalization?"),
                CriticalQuestion("example.representative", "Is the example typical rather than exceptional?"),
                CriticalQuestion("example.counterexamples", "Are there counterexamples to the generalization?")
            ]
        case .verbalClassification:
            return [
                CriticalQuestion("verbal-classification.property", "Does the thing actually have the property used to classify it?"),
                CriticalQuestion("verbal-classification.definition", "Is the classification based on a precise, non-vague definition?")
            ]
        }
    }

    // Named premise slots a scheme instance can bind to claim refs or text.
    // Advisory only; the critical questions carry the analytic weight.
    public static func premiseRoles(for kind: ClaimSchemeKind) -> [String] {
        switch kind {
        case .expertOpinion:
            return ["source", "field", "assertion"]
        case .analogy:
            return ["sourceCase", "targetCase", "mappedProperty"]
        case .causeToEffect:
            return ["cause", "effect"]
        case .sign:
            return ["sign", "event"]
        case .practicalReasoning:
            return ["goal", "action"]
        case .popularOpinion:
            return ["proposition", "population"]
        case .positiveConsequences, .negativeConsequences:
            return ["action", "consequence"]
        case .example:
            return ["example", "generalization"]
        case .verbalClassification:
            return ["entity", "class"]
        }
    }
}
