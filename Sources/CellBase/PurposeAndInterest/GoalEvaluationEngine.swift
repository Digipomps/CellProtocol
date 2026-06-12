// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct GoalObservation: Codable, Hashable, Sendable {
    public var sourceID: String
    public var status: GoalEvidenceStatus
    public var observedAt: String?
    public var value: String?
    public var labels: [String]
    public var eventTypes: [String]
    public var consecutiveFailures: Int?
    public var confidence: Double?
    public var summary: String?

    private enum CodingKeys: String, CodingKey {
        case sourceID
        case status
        case observedAt
        case value
        case labels
        case eventTypes
        case consecutiveFailures
        case confidence
        case summary
    }

    public init(
        sourceID: String,
        status: GoalEvidenceStatus = .fresh,
        observedAt: String? = nil,
        value: String? = nil,
        labels: [String] = [],
        eventTypes: [String] = [],
        consecutiveFailures: Int? = nil,
        confidence: Double? = nil,
        summary: String? = nil
    ) {
        self.sourceID = sourceID
        self.status = status
        self.observedAt = observedAt
        self.value = value
        self.labels = labels
        self.eventTypes = eventTypes
        self.consecutiveFailures = consecutiveFailures
        self.confidence = confidence
        self.summary = summary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sourceID = try container.decode(String.self, forKey: .sourceID)
        self.status = try container.decodeIfPresent(GoalEvidenceStatus.self, forKey: .status) ?? .fresh
        self.observedAt = try container.decodeIfPresent(String.self, forKey: .observedAt)
        self.value = try container.decodeIfPresent(String.self, forKey: .value)
        self.labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
        self.eventTypes = try container.decodeIfPresent([String].self, forKey: .eventTypes) ?? []
        self.consecutiveFailures = try container.decodeIfPresent(Int.self, forKey: .consecutiveFailures)
        self.confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary)
    }
}

public enum GoalEvaluationEngine {
    public static func evaluate(
        definition: GoalDefinition,
        observations: [GoalObservation],
        evaluatedAt: String,
        nextCheckAt: String? = nil
    ) -> GoalEvaluation {
        let observationsBySource = Dictionary(uniqueKeysWithValues: observations.map { ($0.sourceID, $0) })
        let missingSourceIDs = definition.evidenceSources
            .map(\.sourceID)
            .filter { observationsBySource[$0] == nil }

        let evidence = definition.evidenceSources.map { source -> GoalEvaluationEvidence in
            if let observation = observationsBySource[source.sourceID] {
                return GoalEvaluationEvidence(
                    sourceID: source.sourceID,
                    status: observation.status,
                    summary: observation.summary ?? evidenceSummary(for: observation),
                    observedAt: observation.observedAt,
                    valueSummary: observation.value ?? labelSummary(observation.labels) ?? eventSummary(observation.eventTypes),
                    confidence: observation.confidence
                )
            }
            return GoalEvaluationEvidence(
                sourceID: source.sourceID,
                status: .missing,
                summary: "No observation was supplied for \(source.sourceID)."
            )
        }

        if missingSourceIDs.isEmpty == false {
            return GoalEvaluation(
                goalID: definition.goalID,
                purposeRef: definition.purposeRef,
                status: .unknown,
                progress: 0,
                confidence: 0,
                evaluatedAt: evaluatedAt,
                evidence: evidence,
                missing: missingSourceIDs.map { "evidence-source:\($0)" },
                nextCheckAt: nextCheckAt,
                emittedEvents: ["goal.evaluation.updated"]
            )
        }

        if let blockingStatus = observations.first(where: { $0.status == .denied || $0.status == .error })?.status {
            return GoalEvaluation(
                goalID: definition.goalID,
                purposeRef: definition.purposeRef,
                status: .blocked,
                progress: 0,
                confidence: aggregateConfidence(observations),
                evaluatedAt: evaluatedAt,
                evidence: evidence,
                blockers: ["evidence-\(blockingStatus.rawValue)"],
                nextCheckAt: nextCheckAt,
                emittedEvents: ["goal.evaluation.updated"]
            )
        }

        if observations.contains(where: { $0.status == .stale }) {
            return GoalEvaluation(
                goalID: definition.goalID,
                purposeRef: definition.purposeRef,
                status: .unknown,
                progress: 0,
                confidence: aggregateConfidence(observations),
                evaluatedAt: evaluatedAt,
                evidence: evidence,
                missing: ["fresh-evidence"],
                nextCheckAt: nextCheckAt,
                emittedEvents: ["goal.evaluation.updated"]
            )
        }

        if definition.evaluatorKind == .networkPing {
            return evaluateNetworkGoal(
                definition: definition,
                observations: observations,
                evidence: evidence,
                evaluatedAt: evaluatedAt,
                nextCheckAt: nextCheckAt
            )
        }

        let matched = definition.predicate.map { predicateMatches($0, observationsBySource: observationsBySource) } ?? false
        let status: GoalStatus = matched ? .satisfied : .active
        let progress = matched ? 1.0 : 0.0
        var emitted = ["goal.evaluation.updated"]
        if matched {
            emitted.append("goal.satisfied")
        }

        return GoalEvaluation(
            goalID: definition.goalID,
            purposeRef: definition.purposeRef,
            status: status,
            progress: progress,
            confidence: aggregateConfidence(observations),
            evaluatedAt: evaluatedAt,
            evidence: evidence,
            nextCheckAt: nextCheckAt,
            emittedEvents: emitted
        )
    }

    private static func evaluateNetworkGoal(
        definition: GoalDefinition,
        observations: [GoalObservation],
        evidence: [GoalEvaluationEvidence],
        evaluatedAt: String,
        nextCheckAt: String?
    ) -> GoalEvaluation {
        let failures = observations.compactMap(\.consecutiveFailures).max() ?? 0
        let policy = definition.statusPolicy
        let missedAfter = policy?.missedAfterFailures
        let atRiskAfter = policy?.atRiskAfterFailures

        let status: GoalStatus
        let progress: Double
        if let missedAfter, failures >= missedAfter {
            status = .missed
            progress = 0
        } else if let atRiskAfter, failures >= atRiskAfter {
            status = .atRisk
            progress = 0.5
        } else {
            status = .satisfied
            progress = 1
        }

        var emitted = ["goal.evaluation.updated"]
        if status == .satisfied {
            emitted.append("goal.satisfied")
        }

        return GoalEvaluation(
            goalID: definition.goalID,
            purposeRef: definition.purposeRef,
            status: status,
            progress: progress,
            confidence: aggregateConfidence(observations),
            evaluatedAt: evaluatedAt,
            evidence: evidence,
            nextCheckAt: nextCheckAt,
            emittedEvents: emitted
        )
    }

    private static func predicateMatches(
        _ predicate: GoalPredicate,
        observationsBySource: [String: GoalObservation]
    ) -> Bool {
        switch predicate.kind {
        case "all":
            return predicate.all.isEmpty == false
                && predicate.all.allSatisfy { predicateMatches($0, observationsBySource: observationsBySource) }
        case "any":
            return predicate.any.contains { predicateMatches($0, observationsBySource: observationsBySource) }
        case "contains-label":
            guard let expected = predicate.expected,
                  let sourceID = predicate.sourceID,
                  let observation = observationsBySource[sourceID] else {
                return false
            }
            let expectedLabel = normalize(expected)
            return observation.labels.map(normalize).contains(expectedLabel)
        case "event-seen":
            guard let expected = predicate.expected,
                  let sourceID = predicate.sourceID,
                  let observation = observationsBySource[sourceID] else {
                return false
            }
            return observation.eventTypes.contains(expected)
        case "value":
            return valuePredicateMatches(predicate, observationsBySource: observationsBySource)
        case "network-ping":
            guard let sourceID = predicate.sourceID,
                  let observation = observationsBySource[sourceID] else {
                return false
            }
            return observation.status == .fresh && (observation.consecutiveFailures ?? 0) == 0
        default:
            return false
        }
    }

    private static func valuePredicateMatches(
        _ predicate: GoalPredicate,
        observationsBySource: [String: GoalObservation]
    ) -> Bool {
        guard let sourceID = predicate.sourceID,
              let operation = predicate.operation,
              let expected = predicate.expected,
              let observed = observationsBySource[sourceID]?.value else {
            return false
        }

        switch operation {
        case "equals", "==":
            return observed == expected
        case "not-equals", "!=":
            return observed != expected
        case "contains":
            return observed.localizedCaseInsensitiveContains(expected)
        default:
            return false
        }
    }

    private static func aggregateConfidence(_ observations: [GoalObservation]) -> Double {
        let confidences = observations.compactMap(\.confidence)
        guard confidences.isEmpty == false else {
            return observations.isEmpty ? 0 : 0.8
        }
        return confidences.reduce(0, +) / Double(confidences.count)
    }

    private static func evidenceSummary(for observation: GoalObservation) -> String {
        if let summary = observation.summary {
            return summary
        }
        if let value = observation.value {
            return "\(observation.sourceID)=\(value)"
        }
        if let labels = labelSummary(observation.labels) {
            return "\(observation.sourceID) labels: \(labels)"
        }
        if let events = eventSummary(observation.eventTypes) {
            return "\(observation.sourceID) events: \(events)"
        }
        return "\(observation.sourceID) observation is \(observation.status.rawValue)."
    }

    private static func labelSummary(_ labels: [String]) -> String? {
        labels.isEmpty ? nil : labels.sorted().joined(separator: ",")
    }

    private static func eventSummary(_ eventTypes: [String]) -> String? {
        eventTypes.isEmpty ? nil : eventTypes.sorted().joined(separator: ",")
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }
}
