// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct PurposeInterestAdjacencyRanking: Codable, Equatable, Sendable {
    public var purposeRef: String
    public var score: Double
    public var matchedInterestRefs: [String]
    public var evidence: [PurposeInterestAdjacencyIndex.Edge]

    public init(
        purposeRef: String,
        score: Double,
        matchedInterestRefs: [String],
        evidence: [PurposeInterestAdjacencyIndex.Edge]
    ) {
        self.purposeRef = purposeRef
        self.score = score
        self.matchedInterestRefs = matchedInterestRefs
        self.evidence = evidence
    }
}

public struct PurposeInterestAdjacencyIndex: Codable, Equatable, Sendable {
    public struct Edge: Codable, Equatable, Sendable {
        public var interestRef: String
        public var purposeRef: String
        public var weight: Double

        public init(interestRef: String, purposeRef: String, weight: Double) {
            self.interestRef = interestRef
            self.purposeRef = purposeRef
            self.weight = weight.isFinite ? max(0.0, weight) : 0.0
        }
    }

    public var purposeRefs: [String]
    public var edgesByInterestRef: [String: [Edge]]

    public init(purposeRefs: [String], edges: [Edge]) {
        self.purposeRefs = Array(Set(purposeRefs + edges.map(\.purposeRef))).sorted()
        var indexedEdges = [String: [Edge]]()
        for edge in edges {
            indexedEdges[edge.interestRef, default: []].append(edge)
        }
        self.edgesByInterestRef = indexedEdges.mapValues { edges in
            edges.sorted {
                if $0.purposeRef == $1.purposeRef {
                    return $0.interestRef < $1.interestRef
                }
                return $0.purposeRef < $1.purposeRef
            }
        }
    }

    public func edges(for interestRef: String) -> [Edge] {
        edgesByInterestRef[interestRef] ?? []
    }

    public func rankedPurposes(for interestRefs: [String]) -> [PurposeInterestAdjacencyRanking] {
        let activeInterestRefs = Array(Set(interestRefs)).sorted()
        var scoresByPurpose = Dictionary(uniqueKeysWithValues: purposeRefs.map { ($0, 0.0) })
        var evidenceByPurpose = [String: [Edge]]()
        var matchedInterestRefsByPurpose = [String: Set<String>]()

        for interestRef in activeInterestRefs {
            for edge in edges(for: interestRef) {
                scoresByPurpose[edge.purposeRef, default: 0.0] += edge.weight
                evidenceByPurpose[edge.purposeRef, default: []].append(edge)
                matchedInterestRefsByPurpose[edge.purposeRef, default: []].insert(interestRef)
            }
        }

        return purposeRefs.map { purposeRef in
            PurposeInterestAdjacencyRanking(
                purposeRef: purposeRef,
                score: scoresByPurpose[purposeRef] ?? 0.0,
                matchedInterestRefs: Array(matchedInterestRefsByPurpose[purposeRef] ?? []).sorted(),
                evidence: (evidenceByPurpose[purposeRef] ?? []).sorted {
                    if $0.interestRef == $1.interestRef {
                        return $0.weight > $1.weight
                    }
                    return $0.interestRef < $1.interestRef
                }
            )
        }
        .sorted {
            if $0.score == $1.score {
                return $0.purposeRef < $1.purposeRef
            }
            return $0.score > $1.score
        }
    }
}
