// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct PurposeCompositionLeaf: Codable, Equatable {
    public var purposeRef: String
    public var name: String?

    public init(purposeRef: String, name: String? = nil) {
        self.purposeRef = purposeRef
        self.name = name
    }

    public init(_ purpose: Purpose) {
        self.init(purposeRef: purpose.reference, name: purpose.name)
    }
}

public enum PurposeCompositionStatus: String, Codable, Equatable {
    case satisfied
    case partial
    case unsatisfied
}

public struct PurposeCompositionEvaluationContext: Codable, Equatable {
    public var evaluatedAt: TimeInterval
    public var purposeResolutions: [PurposeResolutionRecord]

    public init(
        evaluatedAt: TimeInterval = Date().timeIntervalSince1970,
        purposeResolutions: [PurposeResolutionRecord] = []
    ) {
        self.evaluatedAt = evaluatedAt
        self.purposeResolutions = purposeResolutions
    }

    public func latestResolution(
        for purposeRef: String,
        status: PurposeResolutionStatus = .succeeded
    ) -> PurposeResolutionRecord? {
        purposeResolutions
            .filter { record in
                record.purposeRef == purposeRef &&
                    record.status == status &&
                    record.resolvedAt <= evaluatedAt
            }
            .max { lhs, rhs in
                lhs.resolvedAt < rhs.resolvedAt
            }
    }
}

public struct PurposeCompositionEvaluation: Codable, Equatable {
    public var composition: PurposeComposition
    public var status: PurposeCompositionStatus
    public var score: Double
    public var satisfiedPurposeRefs: [String]
    public var missingPurposeRefs: [String]
    public var completedAt: TimeInterval?
    public var childResults: [PurposeCompositionEvaluation]
    public var blockingIndex: Int?
    public var blockingReason: String?

    public init(
        composition: PurposeComposition,
        status: PurposeCompositionStatus,
        score: Double,
        satisfiedPurposeRefs: [String],
        missingPurposeRefs: [String],
        completedAt: TimeInterval? = nil,
        childResults: [PurposeCompositionEvaluation] = [],
        blockingIndex: Int? = nil,
        blockingReason: String? = nil
    ) {
        self.composition = composition
        self.status = status
        self.score = max(0.0, min(1.0, score))
        self.satisfiedPurposeRefs = Self.stableUnique(satisfiedPurposeRefs)
        self.missingPurposeRefs = Self.stableUnique(missingPurposeRefs)
        self.completedAt = completedAt
        self.childResults = childResults
        self.blockingIndex = blockingIndex
        self.blockingReason = blockingReason
    }

    public var isSatisfied: Bool {
        status == .satisfied
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

public indirect enum PurposeComposition: Codable, Equatable {
    case purpose(PurposeCompositionLeaf)
    case allOf([PurposeComposition])
    case anyOf([PurposeComposition])
    case sequence([PurposeComposition])
    case atLeast(requiredCount: Int, children: [PurposeComposition])

    enum CodingKeys: String, CodingKey {
        case type
        case purposeRef
        case name
        case children
        case requiredCount
    }

    enum CompositionType: String, Codable {
        case purpose
        case allOf
        case anyOf
        case sequence
        case atLeast
    }

    public static func leaf(_ purposeRef: String, name: String? = nil) -> PurposeComposition {
        .purpose(PurposeCompositionLeaf(purposeRef: purposeRef, name: name))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(CompositionType.self, forKey: .type)
        switch type {
        case .purpose:
            self = .purpose(
                PurposeCompositionLeaf(
                    purposeRef: try container.decode(String.self, forKey: .purposeRef),
                    name: try container.decodeIfPresent(String.self, forKey: .name)
                )
            )
        case .allOf:
            self = .allOf(try container.decode([PurposeComposition].self, forKey: .children))
        case .anyOf:
            self = .anyOf(try container.decode([PurposeComposition].self, forKey: .children))
        case .sequence:
            self = .sequence(try container.decode([PurposeComposition].self, forKey: .children))
        case .atLeast:
            self = .atLeast(
                requiredCount: try container.decode(Int.self, forKey: .requiredCount),
                children: try container.decode([PurposeComposition].self, forKey: .children)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .purpose(let leaf):
            try container.encode(CompositionType.purpose, forKey: .type)
            try container.encode(leaf.purposeRef, forKey: .purposeRef)
            try container.encodeIfPresent(leaf.name, forKey: .name)
        case .allOf(let children):
            try container.encode(CompositionType.allOf, forKey: .type)
            try container.encode(children, forKey: .children)
        case .anyOf(let children):
            try container.encode(CompositionType.anyOf, forKey: .type)
            try container.encode(children, forKey: .children)
        case .sequence(let children):
            try container.encode(CompositionType.sequence, forKey: .type)
            try container.encode(children, forKey: .children)
        case .atLeast(let requiredCount, let children):
            try container.encode(CompositionType.atLeast, forKey: .type)
            try container.encode(requiredCount, forKey: .requiredCount)
            try container.encode(children, forKey: .children)
        }
    }

    public func evaluate(in context: PurposeCompositionEvaluationContext) -> PurposeCompositionEvaluation {
        switch self {
        case .purpose(let leaf):
            return evaluateLeaf(leaf, in: context)
        case .allOf(let children):
            return evaluateAll(children, in: context)
        case .anyOf(let children):
            return evaluateAny(children, in: context)
        case .sequence(let children):
            return evaluateSequence(children, in: context)
        case .atLeast(let requiredCount, let children):
            return evaluateAtLeast(requiredCount: requiredCount, children: children, in: context)
        }
    }

    public var leafPurposeRefs: [String] {
        switch self {
        case .purpose(let leaf):
            return [leaf.purposeRef]
        case .allOf(let children), .anyOf(let children), .sequence(let children):
            return PurposeCompositionEvaluation.stableUnique(children.flatMap(\.leafPurposeRefs))
        case .atLeast(_, let children):
            return PurposeCompositionEvaluation.stableUnique(children.flatMap(\.leafPurposeRefs))
        }
    }

    private func evaluateLeaf(
        _ leaf: PurposeCompositionLeaf,
        in context: PurposeCompositionEvaluationContext
    ) -> PurposeCompositionEvaluation {
        guard let record = context.latestResolution(for: leaf.purposeRef) else {
            return PurposeCompositionEvaluation(
                composition: self,
                status: .unsatisfied,
                score: 0.0,
                satisfiedPurposeRefs: [],
                missingPurposeRefs: [leaf.purposeRef],
                blockingReason: "missingPurposeResolution"
            )
        }

        return PurposeCompositionEvaluation(
            composition: self,
            status: .satisfied,
            score: 1.0,
            satisfiedPurposeRefs: [leaf.purposeRef],
            missingPurposeRefs: [],
            completedAt: record.resolvedAt
        )
    }

    private func evaluateAll(
        _ children: [PurposeComposition],
        in context: PurposeCompositionEvaluationContext
    ) -> PurposeCompositionEvaluation {
        let childResults = children.map { $0.evaluate(in: context) }
        guard !childResults.isEmpty else {
            return PurposeCompositionEvaluation(
                composition: self,
                status: .satisfied,
                score: 1.0,
                satisfiedPurposeRefs: [],
                missingPurposeRefs: [],
                childResults: []
            )
        }

        let satisfiedCount = childResults.filter(\.isSatisfied).count
        let score = childResults.map(\.score).reduce(0.0, +) / Double(childResults.count)
        let status = statusForSatisfiedCount(satisfiedCount, total: childResults.count)

        return PurposeCompositionEvaluation(
            composition: self,
            status: status,
            score: score,
            satisfiedPurposeRefs: childResults.flatMap(\.satisfiedPurposeRefs),
            missingPurposeRefs: childResults.flatMap(\.missingPurposeRefs),
            completedAt: childResults.compactMap(\.completedAt).max(),
            childResults: childResults,
            blockingIndex: status == .satisfied ? nil : childResults.firstIndex { !$0.isSatisfied },
            blockingReason: status == .satisfied ? nil : "requiredChildUnsatisfied"
        )
    }

    private func evaluateAny(
        _ children: [PurposeComposition],
        in context: PurposeCompositionEvaluationContext
    ) -> PurposeCompositionEvaluation {
        let childResults = children.map { $0.evaluate(in: context) }
        guard !childResults.isEmpty else {
            return PurposeCompositionEvaluation(
                composition: self,
                status: .unsatisfied,
                score: 0.0,
                satisfiedPurposeRefs: [],
                missingPurposeRefs: [],
                childResults: [],
                blockingReason: "noAlternatives"
            )
        }

        let hasSatisfiedChild = childResults.contains { $0.isSatisfied }
        let hasPartialChild = childResults.contains { $0.status == .partial }
        let status: PurposeCompositionStatus = hasSatisfiedChild ? .satisfied : (hasPartialChild ? .partial : .unsatisfied)

        return PurposeCompositionEvaluation(
            composition: self,
            status: status,
            score: childResults.map(\.score).max() ?? 0.0,
            satisfiedPurposeRefs: childResults.flatMap(\.satisfiedPurposeRefs),
            missingPurposeRefs: status == .satisfied ? [] : childResults.flatMap(\.missingPurposeRefs),
            completedAt: childResults
                .filter(\.isSatisfied)
                .compactMap(\.completedAt)
                .max(),
            childResults: childResults,
            blockingIndex: status == .satisfied ? nil : 0,
            blockingReason: status == .satisfied ? nil : "noAlternativeSatisfied"
        )
    }

    private func evaluateSequence(
        _ children: [PurposeComposition],
        in context: PurposeCompositionEvaluationContext
    ) -> PurposeCompositionEvaluation {
        let childResults = children.map { $0.evaluate(in: context) }
        guard !childResults.isEmpty else {
            return PurposeCompositionEvaluation(
                composition: self,
                status: .satisfied,
                score: 1.0,
                satisfiedPurposeRefs: [],
                missingPurposeRefs: [],
                childResults: []
            )
        }

        var previousCompletion: TimeInterval?
        var prefixSatisfiedCount = 0
        var blockingIndex: Int?
        var blockingReason: String?

        for (index, childResult) in childResults.enumerated() {
            guard childResult.isSatisfied, let completedAt = childResult.completedAt else {
                blockingIndex = index
                blockingReason = "requiredChildUnsatisfied"
                break
            }
            if let previousCompletion, completedAt < previousCompletion {
                blockingIndex = index
                blockingReason = "outOfOrderResolution"
                break
            }
            previousCompletion = completedAt
            prefixSatisfiedCount += 1
        }

        let score = Double(prefixSatisfiedCount) / Double(childResults.count)
        let status: PurposeCompositionStatus
        if blockingIndex == nil {
            status = .satisfied
        } else if prefixSatisfiedCount > 0 || childResults.contains(where: { $0.status == .partial }) {
            status = .partial
        } else {
            status = .unsatisfied
        }

        return PurposeCompositionEvaluation(
            composition: self,
            status: status,
            score: score,
            satisfiedPurposeRefs: childResults.flatMap(\.satisfiedPurposeRefs),
            missingPurposeRefs: childResults.flatMap(\.missingPurposeRefs),
            completedAt: status == .satisfied ? previousCompletion : nil,
            childResults: childResults,
            blockingIndex: blockingIndex,
            blockingReason: blockingReason
        )
    }

    private func evaluateAtLeast(
        requiredCount: Int,
        children: [PurposeComposition],
        in context: PurposeCompositionEvaluationContext
    ) -> PurposeCompositionEvaluation {
        let childResults = children.map { $0.evaluate(in: context) }
        let boundedRequiredCount = max(0, requiredCount)
        guard boundedRequiredCount > 0 else {
            return PurposeCompositionEvaluation(
                composition: self,
                status: .satisfied,
                score: 1.0,
                satisfiedPurposeRefs: childResults.flatMap(\.satisfiedPurposeRefs),
                missingPurposeRefs: [],
                completedAt: childResults.compactMap(\.completedAt).max(),
                childResults: childResults
            )
        }

        let satisfiedCount = childResults.filter(\.isSatisfied).count
        let status: PurposeCompositionStatus
        if satisfiedCount >= boundedRequiredCount {
            status = .satisfied
        } else if satisfiedCount > 0 || childResults.contains(where: { $0.status == .partial }) {
            status = .partial
        } else {
            status = .unsatisfied
        }

        return PurposeCompositionEvaluation(
            composition: self,
            status: status,
            score: min(1.0, Double(satisfiedCount) / Double(boundedRequiredCount)),
            satisfiedPurposeRefs: childResults.flatMap(\.satisfiedPurposeRefs),
            missingPurposeRefs: status == .satisfied ? [] : childResults.flatMap(\.missingPurposeRefs),
            completedAt: childResults
                .filter(\.isSatisfied)
                .compactMap(\.completedAt)
                .max(),
            childResults: childResults,
            blockingIndex: status == .satisfied ? nil : childResults.firstIndex { !$0.isSatisfied },
            blockingReason: status == .satisfied ? nil : "tooFewChildrenSatisfied"
        )
    }

    private func statusForSatisfiedCount(_ satisfiedCount: Int, total: Int) -> PurposeCompositionStatus {
        if satisfiedCount == total {
            return .satisfied
        }
        if satisfiedCount > 0 {
            return .partial
        }
        return .unsatisfied
    }
}

public extension Purpose {
    func evaluateComposition(in context: PurposeCompositionEvaluationContext) -> PurposeCompositionEvaluation {
        let expression = composition ?? .purpose(PurposeCompositionLeaf(self))
        return expression.evaluate(in: context)
    }
}
