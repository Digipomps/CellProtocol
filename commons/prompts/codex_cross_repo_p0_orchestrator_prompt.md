# Cross-Repo P0 Orchestrator Prompt

You are coordinating parallel P0 work across three repositories:

- `CellProtocol`
- `CellScaffold`
- `Binding`

The goal is to land a coherent first utility-cell tranche without causing the
repos to drift, duplicate logic, or block each other unnecessarily.

This is not an implementation prompt for one repo. It is a coordination prompt
for sequencing, scoping, and handoff discipline across all three.

## Overall Objective

Deliver the first portable utility-cell layer so that:

- `CellProtocol` owns the shared contracts and universal diagnostics building
  blocks
- `CellScaffold` owns reusable scaffold-hosted control-plane and parity surfaces
- `Binding` owns native/client bridges, portable caching, and host-side approval
  flows

The work must strengthen shared truth, not create three parallel versions of
the same idea.

## Current Assumptions

Assume the following already exists in `CellProtocol`:

- `FlowProbeCell`
- `StateSnapshotCell`
- additive admission contracts in
  `Sources/CellBase/Agreement/AdmissionContracts.swift`
- additive configuration catalog contracts in
  `Sources/CellBase/ConfigurationCatalog/ConfigurationCatalogContracts.swift`
- contract documentation in `Docs/Admission_and_Catalog_Contracts.md`

Assume separate repo-specific prompts already exist for:

- `Binding`
- `CellScaffold`

Your job is to make sure those efforts are sequenced correctly and remain
compatible.

## Repository Responsibilities

### `CellProtocol`

Owns:

- typed portable contracts
- universal diagnostics/probe primitives
- low-level invariants and compatibility guarantees
- docs describing contract meaning and migration direction

Must not own:

- product-specific scaffold logic
- native host UX
- repo-specific fallback behavior

### `CellScaffold`

Owns:

- reusable scaffold control-plane surfaces
- stable parity fixtures for portable rendering
- scaffold-level extraction seams from product implementations
- durable identity-link/bootstrap scaffolding

Must not own:

- low-level protocol truth that belongs in `CellProtocol`
- native Binding-only transport/caching logic
- conference-specific copy or product behavior disguised as generic scaffold

### `Binding`

Owns:

- native host boundaries
- portable cache and resume behavior
- deep-link / QR / import-export / notification intent bridges
- typed consumption of shared admission/catalog contracts

Must not own:

- scaffold product truth
- rewritten copies of remote `CellConfiguration`
- Binding-only replacements for canonical scaffold surfaces

## Required Order Of Work

Follow this order unless there is a concrete reason to deviate:

1. stabilize shared `CellProtocol` contracts and docs
2. harden scaffold-owned parity fixtures and identity-link control plane in
   `CellScaffold`
3. adopt those shared/scaffold surfaces in `Binding`
4. run parity and compatibility verification across repos

Why this order matters:

- `Binding` should consume scaffold truth, not invent it
- `CellScaffold` should consume protocol contracts, not redefine them
- `CellProtocol` should remain the lowest shared layer

## Handoff Contracts

Before `CellScaffold` work is considered ready for `Binding` adoption, it should
provide:

- stable fixture surface names/endpoints
- deterministic fixture payloads
- explicit identity-link challenge/accepted-link state model
- clear statement of what remains conference-owned

Before `Binding` work is considered complete, it should prove:

- typed decoding of current `connect.challenge`
- cache of remote scaffold truth without local rewrites
- same-entity link approval flow against scaffold-owned semantics
- no new Binding-only canonical product surfaces

Before any repo changes shared contract meaning, it must first be reflected in
`CellProtocol` docs and tests.

## Coordination Rules

- Prefer additive changes over rewrites.
- Keep outward payloads stable unless all consuming repos are updated together.
- Do not fix drift by copying code or payload shapes across repos.
- When a repo needs a new shared concept, push it downward:
  - from `Binding`/`CellScaffold` to `CellProtocol` if it is protocol-common
  - from product code to `CellScaffold` if it is scaffold-common
- Do not let transport metadata become authority for identity-link acceptance.
- Preserve deterministic fixture behavior for parity work.

## When To Stop And Escalate

Pause and escalate if any of the following happens:

- `Binding` needs to invent a local shape because scaffold truth is unclear
- `CellScaffold` needs to invent a local shape because protocol truth is unclear
- a change would alter current outward payload shape in a non-additive way
- parity requires product-specific hacks to pass
- identity-link, role-grant, and bootstrap concerns start collapsing together

Escalation should include:

- what repo is blocked
- what contract or ownership boundary is unclear
- which lower layer should own the fix

## Minimum Cross-Repo Verification

At the end of the tranche, verify at minimum:

- `CellProtocol` typed admission/catalog contracts still decode current payloads
- `CellScaffold` exposes deterministic parity fixtures
- `Binding` consumes those fixtures without rewriting them
- same-entity link flow remains distinct from role/access grant flow
- probe/snapshot diagnostics can still be used to debug parity drift

## Deliverables

Return:

1. a short coordination summary
2. the recommended execution order
3. any blocked handoffs
4. any contract decisions that must be made centrally in `CellProtocol`

## Reporting Expectations

In your summary, be explicit about:

- what each repo owns after this tranche
- which assumptions `Binding` now relies on from `CellScaffold`
- which assumptions `CellScaffold` now relies on from `CellProtocol`
- any remaining ambiguity that should be resolved before the next tranche
