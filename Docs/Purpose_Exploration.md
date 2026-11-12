# Declared route exploration

F1/F2 (`purpose://candidate.delivery.exploration`): opt-in epsilon-greedy
recommendations in `Sources/CellBase/PurposeAndInterest/ExplorationPolicy.swift`.
The canonical runtime description is in CellProtocolDocuments
`Book/14_Perspective_Runtime_Matching.md`, section 9.

```swift
let scores = await engine.scorePurposes(contextSnapshot: snapshot, at: replayTimestamp)
// Resolve consent and consecutive failures from explicit, domain-local declarations
// and outcomes. Missing consent classification must not be treated as permission.
let candidates = scores.map {
    $0.explorationCandidate(
        requiresOwnerConsent: consentRequired[$0.purposeId] ?? true,
        consecutiveFailures: declaredFailures[$0.purposeId] ?? 0
    )
}
var generator = ExplorationSeededGenerator(seed: 42)
let selection = try ExplorationPolicy(epsilon: 0.05, epsilonAfterFailures: 0.1)
    .select(from: candidates, using: &generator)
// Record selection plus inputs/policy and generator checkpoint for replay.
// Perform the usual owner/capability checks before executing any recommendation.
```

Callers can append an explicitly declared untried route with `weight: nil`.
The policy does not discover candidates or derive consent from weights.
Both probabilities default to zero; the failure threshold defaults to two.
Uplift is `max(epsilon, epsilonAfterFailures)` only when the greedy route's
explicit consecutive failure count reaches the threshold. The caller counts
deduplicated declared outcomes for that exact route and resets its count on
success; failures on a different route do not raise this decision's probability.
No observed user behaviour is ingested, and no weights or declarations change.

Known finite weights sort descending, ties by ID ascending; untried routes
sort last. This preserves `RelationalLearningEngine.scorePurposes` ranking
when adapted with zero epsilon. Candidates with `requiresOwnerConsent: true`
are never in the exploration pool, including when the highest-ranked candidate
itself requires consent. Missing consent in decoded input is an error.
The pool excludes the greedy candidate. With a nonempty pool, `explored` has
probability ε, and an alternative is chosen uniformly. With no pool, the
greedy recommendation is returned with `explored: false`; an empty input
returns nil IDs. Neither result grants authority to execute anything.

`ExplorationSelection` includes the ranked input candidates (weights, consent
and failure counts), greedy/selected IDs, effective epsilon, alternative IDs
and the actual `explored` flag. Invalid probabilities, nonpositive thresholds,
nonfinite weights, empty/duplicate IDs and negative failure counts throw before
consuming entropy. Duplicate IDs cannot hide contradictory consent metadata.

Replay uses injected `RandomNumberGenerator` state. The supplied Codable
`ExplorationSeededGenerator` is SplitMix64 v1, not a cryptographic generator.
The probability draw uses the high 53 bits scaled by 2^-53; alternative
selection uses rejection sampling followed by UInt64 modulo. These mappings
and lexical ordering are fixed independently of Swift's standard random APIs.
Identical policy/candidates and seed/call sequence produce identical choices
and explanations. An empty pool or zero effective epsilon consumes no entropy.
Persist policy, candidate inputs and generator state for restart replay;
the policy itself does not persist them or append to the learning journal.

Existing matching, decay, strategy planning and Cell wire contracts are unchanged.
This is an explicit Swift selection API, not an automatic runtime/host rollout.
`MatchStrategyPlanner` selects compute strategies by cost and requirements;
`WeightedGraphRuntime` ranks graph hits, with a separate depth tie-break.
Do not silently replace either one's hard eligibility checks with exploration.

Validation is in `ExplorationPolicyTests`, including seeded golden vectors,
10,000 draws, existing relational ranking, consent rejection, explanations,
failure uplift and checkpoint replay. The task receipt records executed results.

Local verification on 12 November 2026 (Apple Swift 6.4.2, arm64 macOS):
`swift build` passed with locked resolution. The 14 exploration tests and 51
existing matching/learning tests passed with zero failures. The sample was
2,046 exploratory choices out of 10,000 (20.46%, ε=20%, tolerance ±1.5 percentage
points). SwiftPM's nested manifest sandbox could not start in the managed shell;
the successful runs used `--disable-sandbox` and a worktree-local cache/module
cache. `Package.swift` and `Package.resolved` remained unchanged. The full
repository suite, other platforms and deployed host adoption were not tested.
