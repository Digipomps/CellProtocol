# CellScaffold Stability Execution Prompt

You are working in the `CellScaffold` repository.

Your job is to execute the scaffold-side stability pass after the initial P0
utility-cell tranche. This is follow-up hardening work, not a blank-slate
refactor.

The goal is to make `CellScaffold` safer as the reusable product/scaffold layer
without regressing existing conference behavior.

Focus on:

- preserving existing behavior
- tightening reusable seams
- reducing contract drift
- improving parity confidence for `Binding`

## Primary Outcome

`CellScaffold` must remain the canonical reusable host layer for scaffold-level
truth.

That means:

- scaffold-common control-plane flows are explicit
- parity fixtures are durable and deterministic
- extracted notification seams stay infrastructure-shaped, not product-shaped
- shared `CellProtocol` contracts are used where they reduce drift
- current conference routes and staging behavior keep working

## Read First

In `CellScaffold`, inspect at minimum:

- `Documentation/Scaffold_Utility_Cells_P0_Implementation_Note.md`
- `Documentation/ContextEventEmitters_Architecture_and_MigrationPlan.md`
- `Documentation/Scaffold_Install_and_Identity_Link_Plan.md`
- `Sources/App/Cells/Admin/ScaffoldSetupCell.swift`
- `Sources/App/Cells/ConfigurationCatalog/ConfigurationCatalogCell.swift`
- `Sources/App/Cells/SkeletonParity/SkeletonParityFixtureCells.swift`
- notification-related cells, contracts, and routes
- scaffold tests covering setup and notifications

In `CellProtocol`, align with:

- `Sources/CellBase/Agreement/AdmissionContracts.swift`
- `Sources/CellBase/Agreement/AdmissionSession.swift`
- `Sources/CellBase/ConfigurationCatalog/ConfigurationCatalogContracts.swift`
- `Docs/Admission_and_Catalog_Contracts.md`

## Work Items

### 1. Harden `ScaffoldSetupCell` as a control-plane surface

`ScaffoldSetupCell` now has a clearer split between bootstrap, same-entity
linking, and the role-grant boundary. Preserve that direction and tighten it.

Focus on:

- durable challenge and accepted-link state
- clean separation between transport intake and authority state
- explicit distinction between same-entity linking and role/access grants
- additive structure that does not break existing routes

Requirements:

- do not let URL tokens, QR contents, or transport metadata become authority
- do not collapse bootstrap and identity-link flows back together
- keep current conference install/setup behavior working

Done means:

- the control-plane responsibilities are easier to inspect and test
- state remains durable and explainable across the flow

### 2. Treat parity fixtures as owned scaffold contracts

The parity fixtures should not be demo residue. They should be stable scaffold
truth that `Binding` can rely on.

Focus on:

- deterministic fixture cells
- deterministic fixture catalog entries
- stable payload shapes and identifiers
- avoiding hidden dependence on conference preview state

Requirements:

- keep fixtures scaffold-owned rather than conference-owned
- keep them deterministic enough for repeatable parity assertions
- do not add fixture churn unless it reflects a real contract need

Done means:

- `Binding` parity can depend on scaffold-owned fixture surfaces
- fixture outputs remain stable across runs

### 3. Harden notification seams without over-generalizing them

The scaffold repo now has notification contract seams. Keep them reusable, but
do not pretend they are a complete generic notification framework unless the
code already supports that claim.

Focus on:

- job envelope semantics
- policy request and decision payloads
- callback/status request seams
- compatibility with current conference flows

Requirements:

- do not bake conference copy or conference-only routing into scaffold
  contracts
- do not break the current event topic or delivery path unless there is a
  verified migration plan
- keep the extraction additive and low-risk

Done means:

- the contracts are clearer and more reusable
- existing conference notification behavior still works

### 4. Keep shared-contract adoption disciplined

`CellScaffold` should converge on shared admission and catalog contracts where
that reduces drift, but without causing avoidable payload churn.

Focus on:

- additive use of shared catalog entry contracts
- internal typed handling of admission/helper payloads where helpful
- preserving outward compatibility where existing consumers rely on it

Requirements:

- do not fork shared contract shapes into scaffold-local variants
- do not break existing `ConfigurationCatalogCell` behavior
- keep migrations explicit when both old and new representations coexist

Done means:

- scaffold internals are more aligned with `CellProtocol`
- outward behavior remains stable

### 5. Use tests as the stability gate

This pass is only successful if scaffold behavior stays intact while seams are
cleaned up.

Requirements:

- run setup/control-plane tests
- run notification contract tests
- add targeted tests where parity fixture determinism or durable link state
  could regress
- prefer extending existing test infrastructure over parallel test stacks

Done means:

- the key scaffold-reusable paths are verified directly
- regressions in setup, notifications, and fixture determinism are easier to
  catch

## Non-Goals

Do not:

- replace current conference surfaces with placeholder generic UI
- generalize every conference detail into scaffold-common abstractions
- change payload shapes just for neatness if current consumers depend on them
- introduce a large new framework layer without an immediate concrete use case

## Acceptance Criteria

The work is complete only when all of the following are true:

- `ScaffoldSetupCell` remains clearer and more durable than before
- transport does not become authority in identity-link state
- scaffold parity fixtures are stable, deterministic, and scaffold-owned
- notification seams are reusable without regressing conference behavior
- shared contract adoption reduces drift without breaking outward behavior
- relevant scaffold tests are green

## Verification

At minimum, run the most relevant targeted checks, including:

- `ScaffoldSetupCellTests`
- `ScaffoldNotificationContractsTests`
- any fixture/parity-focused tests added in this pass
- targeted catalog/setup tests if shared-contract adoption touches them

If a broader suite is too expensive, be explicit about what was run and what
still needs a wider pass.

## Deliverables

Return:

1. code changes
2. focused tests
3. a short implementation note covering:
   - what was hardened in `ScaffoldSetupCell`
   - what parity fixtures were stabilized
   - what notification seams remain intentionally scaffold-level
   - where shared contract adoption was completed or deferred
   - residual risks

## Reporting Expectations

In your final summary, be specific about:

- which files now own the durable scaffold control-plane boundaries
- what guarantees the parity fixtures now provide
- what stayed conference-owned on purpose
- how shared `CellProtocol` contracts are now consumed
