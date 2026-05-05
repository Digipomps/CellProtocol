# CellScaffold P0 Utility Cells Prompt

You are working in the `CellScaffold` repository. Your job is to implement the
scaffold-side P0 slice of the utility-cell plan without breaking existing
conference/product behavior.

This prompt assumes `CellProtocol` has already landed additive shared contracts
for admission and configuration catalog payloads. Your task is to make
`CellScaffold` a better reusable host layer by adopting those contracts and
extracting the right common seams.

## Primary Goal

Strengthen `CellScaffold` as the reusable product scaffolding layer by focusing
on:

1. identity-link/bootstrap control plane
2. portable skeleton parity fixtures
3. extraction of notification contract seams
4. gradual convergence on shared catalog/admission contracts

Do not flatten product-specific conference logic into generic abstractions just
because it exists. Extract only the parts that are clearly scaffold-common.

## Read This First

In `CellScaffold`, inspect at minimum:

- `Documentation/ContextEventEmitters_Architecture_and_MigrationPlan.md`
- `Documentation/Scaffold_Install_and_Identity_Link_Plan.md`
- files around `ScaffoldSetupCell`
- scaffold catalog/discovery cells
- conference notification cells and related admin/ops flows
- any existing skeleton fixture/demo/test surfaces

In `CellProtocol`, align with:

- `Sources/CellBase/Agreement/AdmissionContracts.swift`
- `Sources/CellBase/Agreement/AdmissionSession.swift`
- `Sources/CellBase/ConfigurationCatalog/ConfigurationCatalogContracts.swift`
- `Docs/Admission_and_Catalog_Contracts.md`

## Required Outcomes

### 1. Harden `ScaffoldSetupCell`

Turn `ScaffoldSetupCell` into a more explicit reusable control-plane surface for:

- scaffold install/bootstrap
- same-entity identity linking
- durable link challenge/accepted-link state

Expectations:

- keep bootstrap concerns separate from same-entity linking
- keep same-entity linking separate from role grants / access policy
- make challenge state explicit, durable, and inspectable
- avoid letting QR, URL tokens, or transport metadata become the source of
  authority

If the current name no longer fits, you may introduce a clearer reusable seam,
but do not break the existing routes lightly.

### 2. Expose Stable Skeleton Parity Fixtures

Create or harden scaffold-owned fixture surfaces used for renderer parity in
`Binding`.

Expectations:

- fixtures must be stable and deterministic
- fixtures must not be conference-only demo surfaces in disguise
- they should represent portable scaffold truth, not one-off marketing/demo
  state
- keep payloads and contracts deterministic enough for parity assertions

Examples:

- stable fixture cells
- deterministic fixture catalog entries
- portable renderer samples that can be consumed by Binding parity tests

### 3. Extract Notification Contract Seams

Study the current conference notification implementation and extract only the
parts that clearly belong in scaffold-common infrastructure.

Good candidates:

- outbox/job envelope semantics
- registration/state models
- delivery policy seams
- callback or status contract surfaces

Bad candidates:

- conference wording/copy
- conference-specific routing assumptions
- UI abstractions that are only used by one product flow

The outcome does not need to be a full `NotificationHubCell` yet, but it should
leave a clean path toward one.

### 4. Start Converging on Shared Contracts

Adopt the new shared admission/catalog contracts where it is safe to do so.

Expectations:

- use shared catalog model types where internal scaffold catalog logic benefits
- do not break existing `ConfigurationCatalogCell` behavior
- keep outward payloads stable unless the repo already expects the shared shape
- where admission/helper flows parse raw objects, consider typed decoding
  through `AdmissionChallengePayload`

## Non-Goals

Do not:

- break current conference staging routes
- replace conference surfaces with placeholder generic UI
- force premature generalization of every helper or admin flow
- introduce a new generic framework layer without an immediate use case

## Constraints

- preserve existing conference behavior
- prefer additive changes and extraction seams over rewrites
- keep determinism high for parity fixtures
- avoid inventing scaffold-local contract shapes that diverge from
  `CellProtocol`
- do not break current `ConfigurationCatalogCell` expectations

## Suggested Work Plan

1. Map `ScaffoldSetupCell` responsibilities into bootstrap, same-entity link,
   and role-grant concerns.
2. Separate durable identity-link state from transport-specific intake.
3. Expose stable parity fixtures owned by scaffold, not by conference demo code.
4. Extract the minimum useful notification contracts from conference flows.
5. Adopt shared admission/catalog types where they reduce drift.
6. Add focused tests and a short migration note.

## Acceptance Criteria

The work is done only if all of the following are true:

- identity-link/bootstrap flow is clearer and more durable than before
- transport does not become authority in link acceptance
- scaffold exposes stable parity fixtures consumable by `Binding`
- reusable notification seams are clearer, even if a full hub is not built yet
- shared admission/catalog contracts are used where helpful without breaking
  existing product behavior
- tests cover the new durable state and fixture determinism

## Verification

Run the most relevant scaffold tests and add focused new ones.

At minimum, verify:

- durable link challenge and accepted-link state
- bootstrap/install flow still works
- same-entity link path remains distinct from role/access grant path
- parity fixture payloads are deterministic across runs
- current catalog/discovery behavior remains intact

If there is already test or fixture infrastructure for conference/scaffold
surfaces, extend it instead of inventing a parallel stack.

## Deliverables

Return:

1. code changes
2. focused tests
3. a short implementation note that says:
   - which surfaces are now scaffold-reusable
   - which pieces remain conference-owned on purpose
   - any residual risks or follow-up work

## Reporting Expectations

In your final summary, be explicit about:

- how `ScaffoldSetupCell` responsibilities are now separated
- what parity fixtures were added or hardened
- what notification contracts were extracted
- where you adopted shared `CellProtocol` contract types
- what you deliberately left product-specific
