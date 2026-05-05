# Binding P0 Utility Cells Prompt

You are working in the `Binding` repository. Your job is to implement the
Binding-side P0 slice of the utility-cell plan in a way that preserves
portability, parity, and existing user-facing behavior.

This prompt assumes `CellProtocol` has already landed additive shared contracts
for:

- `AdmissionChallengePayload`
- `AdmissionRetryRequest`
- `AdmissionSession`
- `ConfigurationCatalogEntryContract`
- `ConfigurationCatalogQueryRequest` and related catalog types

The important constraint is that `Binding` should start consuming those shared
contracts without rewriting remote truth into local Binding-only truth.

## Primary Goal

Make `Binding` a stronger native host for portable scaffold surfaces by focusing
on:

1. typed admission/challenge handling
2. contract-faithful local caching
3. same-entity link approval flow
4. extraction of reusable client-only utility seams from large local bootstrap
   code

Do not turn `Binding` into a second product runtime. It should host, preserve,
cache, and bridge portable surfaces, not fork them.

## Read This First

In `Binding`, inspect at minimum:

- `Documentation/SkeletonPortabilityRequirement.md`
- `Documentation/SkeletonParitySuite.md`
- files around `BootstrapView`
- files that parse or react to `connect.challenge`
- any local cache, deep-link, QR-scan, notification, or import/export flows

In `CellProtocol`, align with these shared contracts and docs:

- `Sources/CellBase/Agreement/AdmissionContracts.swift`
- `Sources/CellBase/Agreement/AdmissionSession.swift`
- `Sources/CellBase/ConfigurationCatalog/ConfigurationCatalogContracts.swift`
- `Docs/Admission_and_Catalog_Contracts.md`

## Required Outcomes

### 1. Typed Admission Decoding

Replace hand-parsed `connect.challenge` handling where practical with decoding
through `AdmissionChallengePayload`.

Expectations:

- preserve all existing user-visible admission flows unless there is a clear bug
- keep support for both `unmet` and `denied`
- keep `sessionId` / `AdmissionSession` intact for retry flows
- do not remove support for helper-driven remediation
- if the existing code still needs a fallback path, make that explicit and
  narrow

Likely places include view models or event handlers that currently pull values
out of raw `Object` payloads.

### 2. Portable Surface Cache

Introduce a reusable cache utility surface for remote scaffold contracts.

This should likely take the shape of a `PortableSurfaceCacheCell` or an
equivalent clearly named utility with cell-like boundaries.

The cache should support at least:

- cached remote `CellConfiguration`
- cached last-known snapshots for selected remote state
- timestamp or freshness metadata
- explicit distinction between cached remote truth and live remote truth

Critical rules:

- cache the remote contract faithfully
- do not mutate the cached configuration into a Binding-specific rewritten
  configuration
- do not silently substitute local fallback UI when parity drifts
- if cache is used for resilience or startup, make that explicit

### 3. Same-Entity Link Approval Flow

Add or harden a clean Binding-side flow for receiving, opening, scanning, and
approving same-entity link challenges.

This can involve QR, deep links, open-url handling, or local scanner flows, but
the transport must not become the authority.

Expectations:

- keep bootstrap/install flow separate from same-entity linking
- keep same-entity linking separate from role/access grants
- preserve or improve current deep-link behavior
- make approval/retry paths explicit and testable
- use the shared admission/session contracts where helpful

### 4. Local Utility Extraction

Find private local snapshot/proxy/helper logic in `BootstrapView.swift` and
adjacent files that should become explicit reusable client utilities.

Examples of acceptable extraction:

- snapshot proxy utilities
- cached surface readers
- deep-link dispatch helpers
- scanner/attachment bridges

Examples of unacceptable extraction:

- copying product-specific conference truth into Binding-only cells
- inventing new local domain models that shadow scaffold contracts
- replacing remote renderable surfaces with custom Binding screens unless
  strictly necessary

## Non-Goals

Do not:

- add more Binding-only fallback pages just to paper over parity gaps
- fork canonical scaffold/catalog contracts into Binding-local variants
- rewrite remote `CellConfiguration` into a different structure for convenience
- over-generalize unfinished ideas into large framework layers

## Constraints

- Follow `SkeletonPortabilityRequirement` strictly.
- Strengthen parity visibility instead of hiding drift.
- Prefer additive, low-risk changes.
- Preserve current onboarding, bootstrap, and deep-link flows unless you are
  fixing a concrete bug.
- If a change would alter user-facing behavior, keep the old path working until
  the new one is verified.

## Suggested Work Plan

1. Map current `connect.challenge` handling and replace raw parsing with typed
   decoding where safe.
2. Design and implement the portable surface cache with minimal surface area.
3. Wire the cache into startup/offline/resume paths where it clearly improves
   resilience.
4. Harden same-entity link intake and approval using explicit session/challenge
   semantics.
5. Extract the smallest reusable local utility seams from `BootstrapView` and
   related files.
6. Add tests and parity-oriented verification.

## Acceptance Criteria

The work is done only if all of the following are true:

- `Binding` can decode current `connect.challenge` payloads through
  `AdmissionChallengePayload`
- same-entity link approval flows remain functional and clearer than before
- portable remote surfaces can be cached and restored without being rewritten
- no existing scaffold surfaces are replaced by Binding-only forks
- the resulting utilities are clearly reusable by multiple scaffolds
- tests cover the new typed decoding and cache behavior

## Verification

Run the most relevant local tests and add new ones where needed.

At minimum, verify:

- typed decode of current `connect.challenge` payloads
- retry flow still works when `sessionId` is present
- cache preserves byte-faithful or semantically faithful remote contract data
- startup/resume behavior does not regress
- same-entity link challenge intake still works from the supported entry points

If there is an existing parity suite, extend it rather than inventing parallel
test scaffolding.

## Deliverables

Return:

1. code changes
2. focused tests
3. a short implementation note that says:
   - which local utilities became reusable
   - which helpers intentionally remain local/product-specific
   - any residual risks

## Reporting Expectations

In your final summary, be explicit about:

- where you adopted `AdmissionChallengePayload`
- where the portable cache lives and what exactly it stores
- how same-entity linking is now routed
- what you deliberately did not generalize yet
