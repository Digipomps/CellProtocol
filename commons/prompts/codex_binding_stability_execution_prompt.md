# Binding Stability Execution Prompt

You are working in the `Binding` repository.

Your job is to execute the `Binding` stability pass after the initial P0
utility-cell tranche. This is not a greenfield prompt. Treat it as follow-up
stabilization work on top of already-landed changes.

The goal is simple:

- remove concrete regressions
- harden the new utility seams
- improve parity confidence
- leave `Binding` more deterministic than before

This prompt is driven by the fix list in:

- `CellProtocol/Docs/Binding_Stability_Fix_List.md`

## Primary Outcome

`Binding` must behave like a robust native host for portable scaffold surfaces.

That means:

- remote truth stays authoritative
- cache remains recovery-oriented, not silently authoritative
- typed admission flows are consistent
- attach/load/parity regressions are caught by tests
- new utility-cell support code does not carry avoidable Swift concurrency debt

## Read First

In `Binding`, inspect at minimum:

- `Documentation/BindingP0UtilityCellsImplementationNote.md`
- `Documentation/SkeletonPortabilityRequirement.md`
- `Documentation/SkeletonParitySuite.md`
- `Binding/PortableSurfaceSupport.swift`
- `Binding/BootstrapView.swift`
- `Binding/RemoteCatalogSupport.swift`
- `Cells/ConfigurationCatalogCell.swift`
- `BindingTests/CatalogAbsorbXCTest.swift`
- `BindingTests/BindingTests.swift`
- `BindingTests/SkeletonParityRemoteXCTest.swift`

In `CellProtocol`, align with:

- `Sources/CellBase/Agreement/AdmissionContracts.swift`
- `Sources/CellBase/Agreement/AdmissionSession.swift`
- `Sources/CellBase/ConfigurationCatalog/ConfigurationCatalogContracts.swift`
- `Docs/Admission_and_Catalog_Contracts.md`

## Work Items

### 1. Fix `ConfigurationCatalog` absorb/load regression first

There is already evidence that `CatalogAbsorbXCTest` can fail with `denied`
when `cell:///ConfigurationCatalog` is loaded in `Porthole`.

Your first job is to remove that regression cleanly.

Focus on:

- runtime registration versus test registration
- requester identity and admission scope
- `scaffoldUnique` and `identityDomain` consistency
- whether `catalog.state` is readable through the attach path
- whether the standalone absorb test and the parallel test in
  `BindingTests.swift` are asserting the same contract

Requirements:

- do not paper over the issue with a test-only exception
- do not broaden access in a way that weakens admission semantics
- keep one clear canonical explanation for why the catalog can be attached and
  read

Done means:

- `CatalogAbsorbXCTest` is green
- the parallel absorb coverage in `BindingTests.swift` is green
- the fix preserves actual runtime semantics

### 2. Remove avoidable actor-isolation fragility

The new portable-surface seams introduced useful structure, but they also
appear to carry Swift-6-relevant actor-isolation warnings.

Prioritize:

- `BindingAdmissionChallengeSnapshot`
- adjacent helpers in `PortableSurfaceSupport.swift`
- any new `BootstrapView` support code added in the same tranche

Requirements:

- remove unnecessary `nonisolated`
- prefer plain value types when actor isolation is not needed
- avoid `nonisolated(unsafe)` unless there is no safer alternative
- do not hide warnings by weakening correctness

Done means:

- the new stability-related support code is materially cleaner under current
  Swift concurrency checks
- the code is easier to reason about, not just quieter to compile

### 3. Finish typed admission normalization

The repository now has shared typed contracts for admission. `Binding` should
use them consistently.

Focus on:

- remaining raw `Object` parsing of `connect.challenge`
- review/approval surfaces that still reconstruct challenge state manually
- retry flows that should rely on shared session data

Requirements:

- route active challenge handling through one typed seam
- keep fallback handling only where older shapes genuinely require it
- ensure helper configuration, retry request, reason code, and session id come
  from the same decoded truth

Done means:

- active `connect.challenge` flows do not disagree with each other
- same-entity link review and retry are based on shared typed data

### 4. Harden cache behavior without weakening parity

The portable cache is useful only if it remains explicit and contract-faithful.

Focus on:

- separation of live remote contract versus cached remote contract
- preservation of remote `CellConfiguration`
- visibility into whether a rendered surface came from live or cached data

Requirements:

- do not retarget or rewrite cached remote contract data for convenience
- do not silently prefer cache when live data is available
- add focused tests for cache provenance and priority rules

Done means:

- cache helps resilience
- cache does not become invisible local authority
- parity drift is surfaced, not hidden

### 5. Use parity as a real gate

If the parity suite exists, it should validate the end result of this pass.

Requirements:

- run parity after the absorb/load and admission fixes are stable
- treat parity failures as contract or renderer problems first
- add fixtures only when a real missing contract surface is identified

Done means:

- parity is part of the verification story for this pass
- new fallback behavior is not justified by bypassing parity

## Non-Goals

Do not:

- add Binding-only fallback pages to hide remote drift
- fork scaffold truth into Binding-local domain models
- widen access policies just to make one test pass
- leave behind multiple competing ways to decode admission challenges

## Acceptance Criteria

The work is complete only when all of the following are true:

- the catalog absorb/load regression is fixed cleanly
- the new portable-surface support code is concurrency-safer than before
- typed admission handling is more uniform and less hand-parsed
- cache behavior is explicit, tested, and non-authoritative
- parity is included in verification
- documentation explains what was fixed, what remains intentionally local, and
  any residual risks

## Verification

At minimum, run the most relevant targeted checks, including:

- `CatalogAbsorbXCTest`
- the broader `BindingTests` suite or the targeted catalog/admission cases
- cache-focused tests
- parity coverage in `SkeletonParityRemoteXCTest`

If a full suite is too expensive, be explicit about what was run and what still
needs a broader pass.

## Deliverables

Return:

1. code changes
2. focused tests
3. a short implementation note covering:
   - root cause of the catalog absorb regression
   - concurrency cleanup performed
   - final shape of typed admission handling
   - cache guarantees and limitations
   - residual risks

## Reporting Expectations

In your final summary, be specific about:

- the exact cause of the `ConfigurationCatalog` failure
- which files own the durable fix
- whether any concurrency warnings remain in the new support seams
- what verifies that cache and parity still respect portability
