// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// One candidate advertising what it is good for, as interest weights.
///
/// `matchPurposeID` is the identity the caller gets back in the result, and is
/// used verbatim as the purpose node's name, so it must be unique within one
/// call.
public struct InterestPurposeCandidate: Sendable, Equatable {
    public var matchPurposeID: String
    public var description: String
    public var interestWeights: [String: Double]

    public init(
        matchPurposeID: String,
        description: String = "",
        interestWeights: [String: Double]
    ) {
        self.matchPurposeID = matchPurposeID
        self.description = description
        self.interestWeights = interestWeights
    }
}

/// One scored candidate. `matchedInterestRefs` is always sorted.
public struct InterestPurposeMatch: Sendable, Equatable {
    public var matchPurposeID: String
    public var score: Double
    public var matchedInterestRefs: [String]

    public init(matchPurposeID: String, score: Double, matchedInterestRefs: [String]) {
        self.matchPurposeID = matchPurposeID
        self.score = score
        self.matchedInterestRefs = matchedInterestRefs
    }
}

/// The outcome of one weighted-sum match.
///
/// `complete` is false when at least one interest's traversal reached its
/// deadline before it finished. The scores in `matches` are then computed from
/// a partial search. They are returned anyway, so the caller can decide what a
/// partial answer is worth — but the caller has to go through this type to get
/// them, and so cannot miss that the answer is incomplete.
///
/// Before this flag existed the function returned the matches directly, and an
/// expired traversal was indistinguishable from a complete one. Of the four
/// matchers in HAVEN on 2026-09-24, only PalazzoSignalGraphMatcher told the two
/// apart.
public struct InterestPurposeWeightedSumResult: Sendable, Equatable {
    public var matches: [InterestPurposeMatch]
    public var complete: Bool
    /// Interests whose traversal expired, sorted. Empty exactly when `complete`.
    public var incompleteInterestIDs: [String]

    public init(matches: [InterestPurposeMatch], complete: Bool, incompleteInterestIDs: [String]) {
        self.matches = matches
        self.complete = complete
        self.incompleteInterestIDs = incompleteInterestIDs
    }
}

/// The flat weighted-sum match: join a requester's interests against candidates
/// that advertise the same interests, score each candidate by the sum of
/// `requesterWeight × candidateWeight` over the interests they share, and rank.
///
/// This existed twice, written by hand, in
/// `commons/benchmarks/purpose-interest/…/RestaurantPurposeScenarioSupport.swift`
/// and `…/ConferenceSwarmScenarioSupport.swift`. The two copies were the same
/// algorithm; they differed only in that one of them sorted for determinism and
/// carried local variables, and the other did neither. Determinism is not
/// something each caller should have to remember, so it is built in here:
/// interests are visited in sorted key order and edges in sorted reference
/// order, which makes the floating-point sum reproducible.
///
/// The traversal itself still goes through ``WeightedGraphRuntime`` so that this
/// stays a faithful extraction of what the two copies did, and so the runtime
/// keeps being exercised by the benchmarks that call it.
public enum InterestPurposeWeightedSum {

    /// - Parameters:
    ///   - requesterInterestWeights: the requester's interests and how much each matters.
    ///   - candidates: what is on offer. Candidates advertising no shared interest score 0.
    ///   - tokenPrefix: prepended to the signal token, for tracing. One token per interest.
    ///   - localVariables: carried into the signal and the traversal configuration.
    ///   - ttl: traversal deadline per interest.
    /// - Returns: every candidate, scored, ranked by descending score with
    ///   `matchPurposeID` as the tie-break, together with whether every
    ///   interest's traversal finished before its deadline.
    public static func match(
        requesterInterestWeights: [String: Double],
        candidates: [InterestPurposeCandidate],
        tokenPrefix: String,
        localVariables: Object = [:],
        ttl: TimeInterval = 5.0
    ) async throws -> InterestPurposeWeightedSumResult {
        let purposeNodes = purposeNodesByMatchID(candidates)
        let edgesByInterest = edgesByInterest(
            candidates: candidates,
            purposeNodes: purposeNodes,
            requesterInterestWeights: requesterInterestWeights
        )

        let runtime = WeightedGraphRuntime()
        var traversals = [InterestTraversal]()

        for (interestID, requesterWeight) in requesterInterestWeights.sorted(by: { $0.key < $1.key }) {
            let interest = Interest(
                name: interestID,
                types: [],
                parts: [],
                partOf: [],
                purposes: edgesByInterest[interestID] ?? []
            )
            let signal = Signal(
                relationship: .purposes,
                weight: 0.5,
                tolerance: Double.greatestFiniteMagnitude,
                token: "\(tokenPrefix).\(interestID)",
                ttl: ttl,
                hops: 1,
                localVariables: localVariables
            )
            let configuration = WeightedGraphRuntimeConfiguration(
                relationships: [.purposes],
                maxHops: 1,
                ttl: ttl,
                maxHits: Int.max,
                minScore: 0.0,
                localVariables: localVariables
            )
            let result = try await runtime.match(
                start: interest,
                signal: signal,
                configuration: configuration
            )

            traversals.append(
                InterestTraversal(interestID: interestID, requesterWeight: requesterWeight, result: result)
            )
        }

        return aggregate(candidates: candidates, traversals: traversals)
    }

    /// One interest's traversal, kept whole so the aggregation can see whether it finished.
    struct InterestTraversal {
        let interestID: String
        let requesterWeight: Double
        let result: MatchResult
    }

    /// Sums scores and decides completeness. Separate from the traversal so the
    /// flag can be tested with a constructed, expired `MatchResult` instead of a
    /// test that hopes the clock has moved past a zero deadline.
    ///
    /// Traversals must arrive in sorted interest order; summation follows that
    /// order, which keeps the floating-point sum reproducible.
    static func aggregate(
        candidates: [InterestPurposeCandidate],
        traversals: [InterestTraversal]
    ) -> InterestPurposeWeightedSumResult {
        var scoresByMatchID = [String: Double]()
        var matchedInterestsByMatchID = [String: Set<String>]()
        var incompleteInterestIDs = Set<String>()

        for traversal in traversals {
            if traversal.result.expired {
                incompleteInterestIDs.insert(traversal.interestID)
            }
            for hit in traversal.result.hits.sorted(by: { $0.ref < $1.ref }) where hit.node.kind == .purpose {
                let candidateWeight = hit.evidence
                    .last(where: { $0.relationship == .purposes })?
                    .edgeWeight ?? 0.0
                scoresByMatchID[hit.ref, default: 0.0] += traversal.requesterWeight * candidateWeight
                matchedInterestsByMatchID[hit.ref, default: []].insert(traversal.interestID)
            }
        }

        let matches = candidates
            .map { candidate in
                InterestPurposeMatch(
                    matchPurposeID: candidate.matchPurposeID,
                    score: scoresByMatchID[candidate.matchPurposeID] ?? 0.0,
                    matchedInterestRefs: Array(
                        matchedInterestsByMatchID[candidate.matchPurposeID] ?? []
                    ).sorted()
                )
            }
            .sorted {
                if $0.score == $1.score {
                    return $0.matchPurposeID < $1.matchPurposeID
                }
                return $0.score > $1.score
            }

        return InterestPurposeWeightedSumResult(
            matches: matches,
            complete: incompleteInterestIDs.isEmpty,
            incompleteInterestIDs: incompleteInterestIDs.sorted()
        )
    }

    private static func purposeNodesByMatchID(
        _ candidates: [InterestPurposeCandidate]
    ) -> [String: Purpose] {
        var nodes = [String: Purpose]()
        for candidate in candidates where nodes[candidate.matchPurposeID] == nil {
            nodes[candidate.matchPurposeID] = Purpose(
                name: candidate.matchPurposeID,
                description: candidate.description
            )
        }
        return nodes
    }

    private static func edgesByInterest(
        candidates: [InterestPurposeCandidate],
        purposeNodes: [String: Purpose],
        requesterInterestWeights: [String: Double]
    ) -> [String: [Weight<Purpose>]] {
        var edges = [String: [Weight<Purpose>]]()
        for candidate in candidates {
            guard let purpose = purposeNodes[candidate.matchPurposeID] else { continue }
            for (interestID, candidateWeight) in candidate.interestWeights
                where requesterInterestWeights[interestID] != nil {
                edges[interestID, default: []].append(
                    Weight<Purpose>(weight: candidateWeight, value: purpose)
                )
            }
        }
        for key in Array(edges.keys) {
            edges[key]?.sort {
                ($0.value?.reference ?? $0.reference ?? "") < ($1.value?.reference ?? $1.reference ?? "")
            }
        }
        return edges
    }
}
