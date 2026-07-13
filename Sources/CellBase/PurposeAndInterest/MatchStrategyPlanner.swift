// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum MatchCognitiveMode: String, Codable, Equatable, Sendable {
    case system1Preconfigured
    case system2Reconfiguration
}

public enum MatchStrategyKind: String, Codable, Equatable, Sendable {
    case cachedWeightedSignal
    case sparseVectorFilter
    case layeredSignal
    case deepReconfiguration
}

public enum MatchComputePlacement: String, Codable, Equatable, Sendable {
    case cpuLocal
    case cpuParallel
    case gpuBatch
    case remoteAccelerated
}

public enum MatchStrategyEscalationTrigger: String, Codable, Equatable, Hashable, Sendable {
    case lowConfidence
    case ambiguousTopK
    case missingPreconfiguredCoverage
    case requiresNewKnowledge
    case privacyOrCapabilityGate
    case latencyBudgetExceeded
}

public struct MatchTaskProfile: Codable, Equatable, Sendable {
    public var candidateCount: Int
    public var activeInterestCount: Int
    public var preconfiguredGraphAvailable: Bool
    public var precomputedAdjacencyAvailable: Bool
    public var localVariableLayerCount: Int
    public var requiresNewKnowledgeExtraction: Bool
    public var requiresExplanation: Bool
    public var privacySensitivity: Double
    public var ambiguity: Double
    public var latencyBudgetMilliseconds: Double?
    public var batchSize: Int
    public var gpuAvailable: Bool

    public init(
        candidateCount: Int,
        activeInterestCount: Int,
        preconfiguredGraphAvailable: Bool,
        precomputedAdjacencyAvailable: Bool = false,
        localVariableLayerCount: Int = 1,
        requiresNewKnowledgeExtraction: Bool = false,
        requiresExplanation: Bool = false,
        privacySensitivity: Double = 0.0,
        ambiguity: Double = 0.0,
        latencyBudgetMilliseconds: Double? = nil,
        batchSize: Int = 1,
        gpuAvailable: Bool = false
    ) {
        self.candidateCount = max(0, candidateCount)
        self.activeInterestCount = max(0, activeInterestCount)
        self.preconfiguredGraphAvailable = preconfiguredGraphAvailable
        self.precomputedAdjacencyAvailable = precomputedAdjacencyAvailable
        self.localVariableLayerCount = max(1, localVariableLayerCount)
        self.requiresNewKnowledgeExtraction = requiresNewKnowledgeExtraction
        self.requiresExplanation = requiresExplanation
        self.privacySensitivity = Self.clamp01(privacySensitivity)
        self.ambiguity = Self.clamp01(ambiguity)
        self.latencyBudgetMilliseconds = latencyBudgetMilliseconds.map { max(0.0, $0) }
        self.batchSize = max(1, batchSize)
        self.gpuAvailable = gpuAvailable
    }

    var isPrivacySensitive: Bool {
        privacySensitivity >= 0.65
    }

    var isAmbiguous: Bool {
        ambiguity >= 0.55
    }

    var isLargeCandidateSet: Bool {
        candidateCount >= 1_000
    }

    var isBatchFriendly: Bool {
        batchSize >= 16 || candidateCount >= 2_000
    }

    private static func clamp01(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}

public struct MatchStrategyEstimate: Codable, Equatable, Sendable {
    public var kind: MatchStrategyKind
    public var cognitiveMode: MatchCognitiveMode
    public var computePlacement: MatchComputePlacement
    public var estimatedCostUnits: Double
    public var expectedQuality: Double
    public var gpuSuitability: Double
    public var recommendedBatchSize: Int?
    public var rationale: [String]

    public init(
        kind: MatchStrategyKind,
        cognitiveMode: MatchCognitiveMode,
        computePlacement: MatchComputePlacement,
        estimatedCostUnits: Double,
        expectedQuality: Double,
        gpuSuitability: Double,
        recommendedBatchSize: Int? = nil,
        rationale: [String]
    ) {
        self.kind = kind
        self.cognitiveMode = cognitiveMode
        self.computePlacement = computePlacement
        self.estimatedCostUnits = max(0.0, estimatedCostUnits)
        self.expectedQuality = min(1.0, max(0.0, expectedQuality))
        self.gpuSuitability = min(1.0, max(0.0, gpuSuitability))
        self.recommendedBatchSize = recommendedBatchSize.map { max(1, $0) }
        self.rationale = rationale
    }
}

public struct MatchStrategyPlan: Codable, Equatable, Sendable {
    public var primary: MatchStrategyEstimate
    public var fallbacks: [MatchStrategyEstimate]
    public var escalationTriggers: [MatchStrategyEscalationTrigger]
    public var summary: String

    public init(
        primary: MatchStrategyEstimate,
        fallbacks: [MatchStrategyEstimate],
        escalationTriggers: [MatchStrategyEscalationTrigger],
        summary: String
    ) {
        self.primary = primary
        self.fallbacks = fallbacks
        self.escalationTriggers = escalationTriggers
        self.summary = summary
    }
}

public struct MatchStrategyPlanner: Sendable {
    public init() {}

    public func plan(for task: MatchTaskProfile) -> MatchStrategyPlan {
        let estimates = candidateEstimates(for: task).sorted {
            if $0.estimatedCostUnits == $1.estimatedCostUnits {
                return $0.expectedQuality > $1.expectedQuality
            }
            return $0.estimatedCostUnits < $1.estimatedCostUnits
        }
        let triggers = escalationTriggers(for: task)
        let qualityFloor = task.requiresExplanation || task.isPrivacySensitive ? 0.78 : 0.70
        let primary = estimates.first { estimate in
            estimate.expectedQuality >= qualityFloor && satisfiesHardRequirements(estimate, task: task)
        } ?? estimates.first ?? deepReconfigurationEstimate(for: task)
        let fallbacks = estimates
            .filter { $0.kind != primary.kind }
            .sorted {
                if $0.cognitiveMode == $1.cognitiveMode {
                    return $0.estimatedCostUnits < $1.estimatedCostUnits
                }
                return $0.cognitiveMode == .system1Preconfigured
            }

        return MatchStrategyPlan(
            primary: primary,
            fallbacks: fallbacks,
            escalationTriggers: triggers,
            summary: summary(primary: primary, task: task, triggers: triggers)
        )
    }

    private func candidateEstimates(for task: MatchTaskProfile) -> [MatchStrategyEstimate] {
        var estimates = [MatchStrategyEstimate]()
        if task.preconfiguredGraphAvailable {
            estimates.append(cachedWeightedSignalEstimate(for: task))
        }
        estimates.append(sparseVectorEstimate(for: task))
        if task.localVariableLayerCount > 1 || task.isPrivacySensitive {
            estimates.append(layeredSignalEstimate(for: task))
        }
        if task.requiresNewKnowledgeExtraction || task.isAmbiguous || !task.preconfiguredGraphAvailable {
            estimates.append(deepReconfigurationEstimate(for: task))
        }
        return estimates
    }

    private func satisfiesHardRequirements(_ estimate: MatchStrategyEstimate, task: MatchTaskProfile) -> Bool {
        if task.requiresNewKnowledgeExtraction && estimate.kind != .deepReconfiguration {
            return false
        }
        if task.localVariableLayerCount > 1 && estimate.kind == .sparseVectorFilter {
            return false
        }
        if task.isPrivacySensitive && estimate.kind == .sparseVectorFilter {
            return false
        }
        return true
    }

    private func escalationTriggers(for task: MatchTaskProfile) -> [MatchStrategyEscalationTrigger] {
        var triggers = [MatchStrategyEscalationTrigger]()
        if task.isAmbiguous {
            triggers.append(.ambiguousTopK)
        }
        if !task.preconfiguredGraphAvailable {
            triggers.append(.missingPreconfiguredCoverage)
        }
        if task.requiresNewKnowledgeExtraction {
            triggers.append(.requiresNewKnowledge)
        }
        if task.isPrivacySensitive || task.localVariableLayerCount > 1 {
            triggers.append(.privacyOrCapabilityGate)
        }
        if task.latencyBudgetMilliseconds != nil {
            triggers.append(.latencyBudgetExceeded)
        }
        triggers.append(.lowConfidence)
        return stableUnique(triggers)
    }

    private func cachedWeightedSignalEstimate(for task: MatchTaskProfile) -> MatchStrategyEstimate {
        let edgeLookupCost = task.precomputedAdjacencyAvailable
            ? Double(max(1, task.activeInterestCount)) * log2(Double(max(2, task.candidateCount)))
            : Double(max(1, task.activeInterestCount * max(1, task.candidateCount)))
        let indexNote = task.precomputedAdjacencyAvailable
            ? "adjacency index is precomputed"
            : "semantic graph is available, but adjacency is not precomputed for this batch"
        return MatchStrategyEstimate(
            kind: .cachedWeightedSignal,
            cognitiveMode: .system1Preconfigured,
            computePlacement: .cpuLocal,
            estimatedCostUnits: edgeLookupCost,
            expectedQuality: task.isAmbiguous ? 0.76 : 0.86,
            gpuSuitability: 0.20,
            rationale: [
                "preconfigured graph available",
                indexNote,
                "uses cached weighted edges before deeper reconstruction",
                "low GPU suitability because traversal is branchy and usually memory-bound"
            ]
        )
    }

    private func sparseVectorEstimate(for task: MatchTaskProfile) -> MatchStrategyEstimate {
        let gpuPlacement = task.gpuAvailable && task.isLargeCandidateSet && task.isBatchFriendly
        return MatchStrategyEstimate(
            kind: .sparseVectorFilter,
            cognitiveMode: .system1Preconfigured,
            computePlacement: gpuPlacement ? .gpuBatch : .cpuParallel,
            estimatedCostUnits: Double(max(1, task.candidateCount * max(1, task.activeInterestCount))) * (gpuPlacement ? 0.18 : 0.45),
            expectedQuality: task.isAmbiguous ? 0.68 : 0.74,
            gpuSuitability: task.isLargeCandidateSet ? 0.88 : 0.55,
            recommendedBatchSize: gpuPlacement ? max(64, task.batchSize) : nil,
            rationale: [
                "candidate scoring is data-parallel",
                "good first-pass top-k filter for large candidate sets",
                "does not by itself enforce layered privacy or capability context"
            ]
        )
    }

    private func layeredSignalEstimate(for task: MatchTaskProfile) -> MatchStrategyEstimate {
        MatchStrategyEstimate(
            kind: .layeredSignal,
            cognitiveMode: .system1Preconfigured,
            computePlacement: .cpuLocal,
            estimatedCostUnits: Double(max(1, task.activeInterestCount * task.localVariableLayerCount)) * log2(Double(max(2, task.candidateCount))) * 1.6,
            expectedQuality: task.isAmbiguous ? 0.80 : 0.88,
            gpuSuitability: 0.25,
            rationale: [
                "carries local variables across match layers",
                "fits privacy and capability gates before expensive analysis",
                "branching control flow is less GPU-friendly than vector scoring"
            ]
        )
    }

    private func deepReconfigurationEstimate(for task: MatchTaskProfile) -> MatchStrategyEstimate {
        MatchStrategyEstimate(
            kind: .deepReconfiguration,
            cognitiveMode: .system2Reconfiguration,
            computePlacement: task.gpuAvailable && task.isBatchFriendly ? .remoteAccelerated : .cpuParallel,
            estimatedCostUnits: Double(max(1, task.candidateCount + task.activeInterestCount)) * (task.requiresNewKnowledgeExtraction ? 8.0 : 4.0),
            expectedQuality: 0.92,
            gpuSuitability: task.gpuAvailable ? 0.72 : 0.50,
            recommendedBatchSize: task.gpuAvailable && task.isBatchFriendly ? max(16, task.batchSize) : nil,
            rationale: [
                "reconfigures or extracts missing purpose/interest structure",
                "use only when preconfigured routes are weak, ambiguous, or missing",
                "embedding and reranking substeps can be batched on GPU when available"
            ]
        )
    }

    private func summary(
        primary: MatchStrategyEstimate,
        task: MatchTaskProfile,
        triggers: [MatchStrategyEscalationTrigger]
    ) -> String {
        let mode = primary.cognitiveMode == .system1Preconfigured ? "system1" : "system2"
        let gpuNote = primary.computePlacement == .gpuBatch || primary.computePlacement == .remoteAccelerated
            ? " GPU/batch placement is recommended for this profile."
            : ""
        let triggerText = triggers.map(\.rawValue).joined(separator: ", ")
        return "Choose \(primary.kind.rawValue) as \(mode) primary for \(task.candidateCount) candidates; escalate on \(triggerText).\(gpuNote)"
    }

    private func stableUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        var result = [T]()
        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }
}
