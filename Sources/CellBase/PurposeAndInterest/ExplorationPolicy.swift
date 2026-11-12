// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

/// An owner-declared route that has already passed the caller's eligibility checks.
/// A nil weight denotes an untried route, ranked below every known weight.
public struct ExplorationCandidate: Codable, Equatable, Sendable {
    public var id: String
    public var weight: Double?
    public var requiresOwnerConsent: Bool
    /// Explicit consecutive failed outcomes on this exact route, reset on success.
    /// The caller supplies this from declared outcomes, never observed user behaviour.
    public var consecutiveFailures: Int

    public init(id: String, weight: Double?, requiresOwnerConsent: Bool,
                consecutiveFailures: Int = 0) {
        self.id = id
        self.weight = weight
        self.requiresOwnerConsent = requiresOwnerConsent
        self.consecutiveFailures = consecutiveFailures
    }
}

/// Evidence for a recommendation, not authority to execute it.
public struct ExplorationSelection: Codable, Equatable, Sendable {
    public let selectedID: String?
    public let greedyID: String?
    public let explored: Bool
    public let effectiveEpsilon: Double
    /// All input weights, consent flags and failure counts in deterministic rank order.
    public let candidates: [ExplorationCandidate]
    public let explorationCandidateIDs: [String]
}

public enum ExplorationPolicyError: Error, Equatable {
    case invalidProbability
    case invalidFailureThreshold
    case invalidCandidate(String)
    case duplicateCandidate(String)
}

/// Opt-in epsilon-greedy selection for weighted purpose/route matching (F1, F2).
/// It does not infer declarations, ingest events, change weights or authorize actions.
public struct ExplorationPolicy: Codable, Equatable, Sendable {
    public var epsilon: Double
    public var failureThreshold: Int
    /// Optional uplift; zero by default so failure history alone cannot enable exploration.
    public var epsilonAfterFailures: Double

    public init(epsilon: Double = 0, failureThreshold: Int = 2,
                epsilonAfterFailures: Double = 0) {
        self.epsilon = epsilon
        self.failureThreshold = failureThreshold
        self.epsilonAfterFailures = epsilonAfterFailures
    }

    /// Highest known weight wins normally; equal weights use ascending route ID.
    /// Exploration chooses uniformly among *other* routes that do not require consent.
    /// No entropy is consumed for epsilon zero, an empty set or no safe alternatives.
    /// Replay requires the same policy, candidates and generator state/call sequence.
    public func select<R: RandomNumberGenerator>(
        from candidates: [ExplorationCandidate], using generator: inout R
    ) throws -> ExplorationSelection {
        guard epsilon.isFinite, (0...1).contains(epsilon),
              epsilonAfterFailures.isFinite, (0...1).contains(epsilonAfterFailures) else {
            throw ExplorationPolicyError.invalidProbability
        }
        guard failureThreshold > 0 else { throw ExplorationPolicyError.invalidFailureThreshold }
        var ids = Set<String>()
        for candidate in candidates {
            guard !candidate.id.isEmpty, candidate.consecutiveFailures >= 0,
                  candidate.weight.map({ $0.isFinite }) ?? true else {
                throw ExplorationPolicyError.invalidCandidate(candidate.id)
            }
            guard ids.insert(candidate.id).inserted else {
                throw ExplorationPolicyError.duplicateCandidate(candidate.id)
            }
        }

        let ranked = candidates.sorted {
            let lhs = $0.weight ?? -.infinity
            let rhs = $1.weight ?? -.infinity
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
        let greedy = ranked.first
        let alternatives = ranked.filter { $0.id != greedy?.id && !$0.requiresOwnerConsent }
        let effectiveEpsilon = (greedy?.consecutiveFailures ?? 0) >= failureThreshold
            ? max(epsilon, epsilonAfterFailures) : epsilon
        var selected = greedy
        var explored = false
        if !alternatives.isEmpty, effectiveEpsilon > 0 {
            // Fixed mapping instead of stdlib random(in:), whose algorithm may change.
            let draw = Double(generator.next() >> 11) * 0x1.0p-53
            if draw < effectiveEpsilon {
                selected = alternatives[Self.uniformIndex(count: alternatives.count, using: &generator)]
                explored = true
            }
        }
        return ExplorationSelection(
            selectedID: selected?.id, greedyID: greedy?.id, explored: explored,
            effectiveEpsilon: effectiveEpsilon, candidates: ranked,
            explorationCandidateIDs: alternatives.map(\.id)
        )
    }

    private static func uniformIndex<R: RandomNumberGenerator>(count: Int, using generator: inout R) -> Int {
        let bound = UInt64(count)
        // Rejection avoids modulo bias. Arithmetic and draw consumption are replay contract v1.
        let threshold = (0 &- bound) % bound
        var value = generator.next()
        while value < threshold { value = generator.next() }
        return Int(value % bound)
    }
}

/// SplitMix64 v1: portable, checkpointable replay entropy, never cryptographic entropy.
public struct ExplorationSeededGenerator: RandomNumberGenerator, Codable, Equatable, Sendable {
    public private(set) var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}

public extension RelationalPurposeScore {
    /// Keep the engine's score and explicit consent classification at the selection boundary.
    func explorationCandidate(requiresOwnerConsent: Bool, consecutiveFailures: Int = 0) -> ExplorationCandidate {
        ExplorationCandidate(id: purposeId, weight: score, requiresOwnerConsent: requiresOwnerConsent,
                             consecutiveFailures: consecutiveFailures)
    }
}
