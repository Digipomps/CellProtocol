# Cell Contract Testing Architecture

Status: partially implemented

## Why this exists

`CellProtocol` already has the core runtime hooks needed to inspect and test a
cell through its public surface:

- `get(keypath:requester:)`
- `set(keypath:value:requester:)`
- `keys(requester:)`
- `typeForKey(key:requester:)`
- `flow(requester:)`

Those hooks are enough for ad hoc tests, but they are not yet strong enough to
act as a complete machine-readable contract for:

- repeatable interface testing
- runtime probing of remote cells
- documentation generation
- RAG indexing for agent and developer discovery
- validation of purpose and goal quality

This note proposes three related pieces:

1. `CellContract`: a canonical machine-readable contract for a cell
2. `ContractProbeCell`: a runtime cell that can execute contract checks against
   another cell
3. `PurposeGoalLint`: a validator for purpose/goal quality and achievability

The intended architecture is:

- use `XCTest` for deterministic local verification
- use `ContractProbeCell` for runtime, integration, and staging verification
- use `PurposeGoalLint` for semantic quality checks

## Current implementation status

The following pieces from this note are now implemented:

- standardized `typeForKey(...)` contract objects through `ExploreContract`
- `oneOf` schema support for keys that accept multiple payload shapes
- explicit contracts on:
  - `CommonsResolverCell`
  - `CommonsTaxonomyCell`
  - `VaultCell`
  - `GraphIndexCell`
- `CellContractHarness` checks for:
  - advertised keys
  - contract shape
  - permissions
  - invalid input behavior
  - declared flow effects
- `ContractProbeCell` for runtime/staging probing, report storage, and flow
  emission
- `ContractProbeVerificationRecord` to combine declared contract catalog and
  latest probe result into one JSON/Markdown artifact for docs and RAG
- chunk-level verification export through
  `cell.exploreContractVerificationChunks(...)`
- `exploreContractCatalog(requester:)` export for JSON + Markdown records that
  can be indexed by documentation and RAG tooling

Implementation notes:

- because `GeneralCell` currently stores one contract object per key,
  `ContractProbeCell` uses `.current` getter keys for readback instead of
  sharing one key for both `get` and `set`
- see `Docs/ContractProbeCell.md` for the implemented runtime API

## Current constraints in the codebase

Current relevant code:

- `Sources/CellBase/Protocols/CellProtocol.swift`
- `Sources/CellBase/Cells/GeneralCell/GeneralCell.swift`
- `Sources/CellBase/PurposeAndInterest/Purpose.swift`
- `Sources/CellBase/PurposeAndInterest/Goal.swift`
- `Tests/CellBaseTests/GeneralCellInterfaceTests.swift`
- `Tests/CellBaseTests/PurposeAndInterestMatchingTests.swift`

Important constraints:

1. `Explore` currently guarantees only `keys(...)` and `typeForKey(...)`.
2. `GeneralCell` has `schemaDescriptionForKey(...)`, but that is not part of the
   formal protocol.
3. Flow side effects are observable via `flow(...)`, but they are not formally
   declared as part of an interface contract.
4. `Purpose.goal` currently stores `CellConfiguration?`, while `Goal` itself is
   still mostly conceptual and does not provide a formal success condition.

Because of that, a self-describing cell can currently describe itself
incompletely, or incorrectly, without a standard way to prove the mismatch.

## Proposal 1: `CellContract`

### Goal

Define one canonical contract model that can be used by:

- tests
- runtime probing
- documentation generators
- admin/explore UIs
- RAG ingestion pipelines

### Design principles

1. The contract must describe behavior, not just key names.
2. The contract must be serializable as `ValueType.object(...)` so it can travel
   through current `Explore` APIs.
3. The contract must support both human-readable descriptions and
   machine-checkable rules.
4. The contract must declare flow side effects explicitly.
5. The contract must separate interface validation from purpose/goal validation.

### Suggested Swift model

```swift
public struct CellContract: Codable, Sendable {
    public var cellType: String
    public var version: String
    public var summary: String
    public var keys: [KeyContract]
    public var purpose: PurposeContract?
}

public struct KeyContract: Codable, Sendable {
    public var key: String
    public var operation: ContractOperation
    public var input: ValueSchema?
    public var output: ValueSchema?
    public var permissions: [String]
    public var required: Bool
    public var sideEffects: [FlowEffectContract]
    public var examples: [ContractExample]
}

public enum ContractOperation: String, Codable, Sendable {
    case get
    case set
}

public indirect enum ValueSchema: Codable, Sendable {
    case scalar(type: String, description: String?)
    case object(
        requiredKeys: [String],
        properties: [String: ValueSchema],
        description: String?
    )
    case list(item: ValueSchema, description: String?)
    case oneOf(options: [ValueSchema], description: String?)
}

public struct FlowEffectContract: Codable, Sendable {
    public var trigger: String
    public var topic: String
    public var contentType: String
    public var minimumCount: Int
}

public struct ContractExample: Codable, Sendable {
    public var name: String
    public var input: ValueType?
    public var expectedOutput: ValueType?
}

public struct PurposeContract: Codable, Sendable {
    public var summary: String
    public var goalSummary: String?
    public var measurableOutcome: String?
}
```

The exact Swift names are less important than the shape. The key point is that
this becomes the canonical contract model used everywhere else.

### Suggested `Explore` encoding

The existing `Explore` API can carry this without protocol breakage if
`typeForKey(...)` returns a standardized object shape.

Suggested `typeForKey(...)` payload for one key:

```json
{
  "method": "set",
  "input": {
    "type": "object",
    "requiredKeys": ["title", "body"],
    "shape": {
      "title": { "type": "string" },
      "body": { "type": "string" }
    }
  },
  "returns": {
    "type": "object",
    "shape": {
      "status": { "type": "string" }
    }
  },
  "permissions": ["-w--"],
  "required": true,
  "flowEffects": [
    {
      "trigger": "set",
      "topic": "note.created",
      "contentType": "object",
      "minimumCount": 1
    }
  ]
}
```

Suggested mapping to current API:

- `keys(...)` returns all declared keys
- `typeForKey(...)` returns the key contract object
- `schemaDescriptionForKey(...)` returns a concise human-facing summary

This keeps compatibility with the current `GeneralCell.registerExploreSchema(...)`
pattern while making the schema useful for testing and documentation.

### What a contract harness should verify

A deterministic contract harness should validate:

1. Every advertised key can be explored.
2. `typeForKey(...)` returns a well-formed contract object.
3. `get(...)` keys return data matching `output`.
4. `set(...)` keys accept data matching `input`.
5. Invalid input fails in the expected way.
6. Permission-gated keys deny access correctly.
7. Declared flow side effects actually appear on `flow(...)`.
8. Undeclared side effects are flagged.

This should live first in the test target, not as a runtime cell.

## Component 2: `ContractProbeCell`

### Goal

Provide a cell-native way to run contract checks against another cell through
normal runtime APIs.

This is useful for:

- staging checks
- remote/runtime diagnostics
- agent-driven verification
- admin UI tooling
- post-deploy verification where `XCTest` is not available

### What it should not replace

`ContractProbeCell` should not replace `XCTest`.

It should reuse the same contract model and verification logic, but the primary
source of truth for deterministic correctness should still be the test suite.

### Interface shape and implemented API

The original design goal was:

- one setter key for target configuration
- one setter key for expected contract configuration
- one setter key to run the probe
- getter keys for status and stored reports

The implemented runtime keys are:

- set:
  - `probe.target`
  - `probe.contract`
  - `probe.run`
- get:
  - `probe.status`
  - `probe.target.current`
  - `probe.contract.current`
  - `probe.lastReport`
  - `probe.reports`

Suggested flow topics:

- `contract.run.started`
- `contract.assertion.passed`
- `contract.assertion.failed`
- `contract.flow.observed`
- `contract.run.finished`

See `Docs/ContractProbeCell.md` for accepted payload shapes and example
responses.

### Implemented report model

```swift
public struct ContractProbeReport: Codable, Sendable {
    public var id: String
    public var targetCell: String
    public var startedAt: String
    public var finishedAt: String?
    public var status: ContractProbeRunState
    public var usedExpectedContracts: Bool
    public var options: ContractProbeRunOptions
    public var passedCount: Int
    public var failedCount: Int
    public var skippedCount: Int
    public var assertions: [ContractProbeAssertionResult]
    public var errorMessage: String?
}

public struct ContractProbeAssertionResult: Codable, Sendable {
    public var key: String
    public var phase: String
    public var status: ContractProbeAssertionStatus
    public var message: String
    public var expected: ValueType?
    public var observed: ValueType?
}
```

### Implemented execution model

1. Resolve target cell.
2. Read the target cell's advertised keys.
3. Load and normalize the declared contract for each selected key.
4. Compare against configured expected contracts if present.
5. Subscribe to `flow(...)` when the declared contract includes `flowEffects`.
6. Execute declared `get` and `set` checks.
7. Compare observed values and observed flow events to the declared contract.
8. Store a structured report and append it to bounded history.
9. Emit flow events for run start, assertion pass/fail, observed target flow,
   and run finish.

### Why this matters for documentation and RAG

The probe report can be indexed alongside the contract. That gives both humans
and agents:

- the intended behavior
- the observed behavior
- the freshness of the validation
- the exact failing keys or topics

That is much more useful than prose-only documentation.

## Proposal 3: `PurposeGoalLint`

### Goal

Validate whether a cell's declared purpose and goals are:

- understandable
- outcome-oriented
- measurable
- plausibly achievable
- aligned with helper cells and runtime behavior

This should start as a validator utility and test helper. It can later be
wrapped in a cell if runtime linting is needed.

### Why this must be separate

Purpose/goal validation is not the same as interface validation.

`get/set/Explore/flow` checks answer:

- does the cell behave as declared?

Purpose/goal lint answers:

- is the declaration itself useful, coherent, and testable?

Those are related, but they are not the same concern.

### Suggested lint severities

- `error`: the purpose/goal is missing or unusable
- `warning`: the purpose/goal is present but too vague to validate
- `info`: suggested improvement

### Suggested rules

#### Presence rules

1. `Purpose.name` must be present.
2. `Purpose.description` should be present and non-trivial.
3. A production-facing purpose should normally have either:
   - a goal
   - helper cells that explain or remediate
   - an explicit reason why no goal is defined

#### Clarity rules

4. The purpose description should state an intended outcome, not just an
   implementation detail.
5. Generic descriptions such as "handles data", "does stuff", or "utility cell"
   should trigger warnings.
6. The goal should identify who benefits or what state changes.

#### Achievability rules

7. The goal should describe a success condition that can be observed.
8. The goal should describe, directly or indirectly, how success is checked.
9. The goal should avoid purely open-ended aspirations unless explicitly marked
   as ongoing.
10. A goal should have either:
   - a measurable signal
   - a resolver cell
   - a bounded human action

#### Alignment rules

11. If helper cells are declared, they should support the stated goal or provide
    remediation for likely failure modes.
12. If interface contract side effects are declared, they should not contradict
    the purpose statement.
13. If a key triggers critical flow events, the purpose should mention the
    outcome those events represent.

#### Documentation quality rules

14. The purpose should be summarizable in one sentence.
15. The goal should be translatable into a short machine-oriented check summary.
16. Ambiguous temporal language such as "soon", "eventually", or "better"
    should trigger warnings unless bounded.

### Suggested output model

```swift
public struct PurposeGoalLintReport: Codable, Sendable {
    public var findings: [PurposeGoalFinding]
    public var summary: String
}

public struct PurposeGoalFinding: Codable, Sendable {
    public var severity: String
    public var code: String
    public var message: String
    public var suggestion: String?
}
```

### Recommended future refinement

The current `Goal` type should eventually move from free-form
`goalDefinitionString` to a structured goal definition, for example:

```swift
public struct GoalDefinition: Codable, Sendable {
    public var outcome: String
    public var successSignal: String?
    public var resolver: CellConfiguration?
    public var timeoutSeconds: Int?
    public var ongoing: Bool
    public var failureConditions: [String]
}
```

Without something like this, "goal achievability" can only be linted
heuristically, not validated rigorously.

## Completed implementation steps

1. Standardized the object shape returned by `typeForKey(...)`.
2. Added `CellContractHarness` in `Tests/CellBaseTests/TestSupport`.
3. Converted interface coverage to use the harness where it improved clarity.
4. Added flow-side-effect assertions to the harness.
5. Added `PurposeGoalLint` as a test utility.
6. Added `ContractProbeCell` for runtime and staging probing.

## Recommended next increments

1. Add more production cells to explicit `registerExploreContract(...)`
   coverage.
2. Extend the new combined verification export so it can emit chunk-level
   records and freshness-aware metadata for retrieval.
3. Add stricter negative-path checks for cells with richer permission models.
4. Introduce a more structured goal model so purpose/goal validation can move
   from heuristic linting to stronger validation.

The concrete follow-up task for item 2 is captured in:

- `Docs/ContractProbeCell_RAG_Followup.md`

## Expected benefits

- fewer undocumented keys
- better alignment between `Explore` and actual behavior
- testable flow-trigger behavior
- more useful documentation for humans
- structured source material for RAG
- clearer quality bar for `Purpose` and `Goal`
