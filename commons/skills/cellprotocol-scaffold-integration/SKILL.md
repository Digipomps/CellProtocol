---
name: cellprotocol-scaffold-integration
description: Use when integrating CellProtocol Cells, CellConfigurations, resolver wiring, runtime bootstrapping, diagnostics, Porthole, Binding, CellScaffold, persisted cells, preview/commit workflows, or app-specific shells that host CellProtocol behavior.
---

# CellProtocol Scaffold Integration

Use this skill when the task is not core protocol design and not just JSON
authoring, but wiring CellProtocol into an app/scaffold runtime.

## Core Rules

- CellProtocol semantics remain in CellProtocol; scaffold code wires, renders,
  persists, supervises, and diagnoses.
- Prefer runtime skeleton preview/commit workflows before Swift factory
  promotion when changing UI surfaces.
- Do not hide broken portable skeleton behavior behind native shell polish.
- Resolver and identity assumptions must be explicit at app boundaries.
- Persisted state and source-backed editable configurations need reload tests.
- App-specific behavior belongs in the app repo unless it is shared protocol
  contract.

## Read First

For protocol context:

- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/07_Scaffold_Runtime.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/10_Quickstart.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/13_Agent_Instructions.md`

For scaffold/app behavior, inspect the actual app repo first, usually:

- `/Users/kjetil/Build/Digipomps/HAVEN/CellScaffold`
- `/Users/kjetil/Build/Digipomps/HAVEN/Binding`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellScaffold/Documentation`

If skeleton work is involved, also use `cellconfiguration-skeleton-authoring`.

## Required Workflow

1. Classify the integration:
   - register or instantiate Cell
   - provide CellConfiguration
   - render skeleton
   - persist source-backed configuration
   - bridge transport
   - add diagnostics/probe
   - connect app shell behavior
2. Inspect current initializer/registry/factory paths.
3. Trace identity and resolver setup from app entrypoint to Cell call.
4. Choose runtime configuration before factory changes where possible.
5. Verify the user-facing surface:
   - initial configuration renders
   - tabs/actions/fields bind to real keypaths
   - no debug/action-result text leaks into product copy
   - reload preserves committed runtime configuration when expected
6. Add tests or preview artifacts proportional to blast radius.

## Validation Targets

- Swift build/tests for shared code changes.
- App/scaffold tests for initializer and registration changes.
- Porthole skeleton iteration artifacts for UI configuration changes.
- Browser/native screenshots only when visual rendering is part of the request.
- Reload verification for persistent runtime overrides.

## Must Not

- Do not implement protocol policy in an app shell.
- Do not hardcode demo identities as production behavior.
- Do not promote a skeleton factory until runtime behavior has been checked or
  the user explicitly asked for source-only work.
- Do not leave a scaffold wired to stale endpoints or labels.
- If scaffold wiring reveals a gap that requires changing resolver policy,
  identity rules, or core runtime behavior, stop and switch to
  `cellprotocol-identity-capability-security` or
  `cellprotocol-core-runtime-implementation` before continuing scaffold changes.

## Completion Checklist

- Runtime path from app to Cell is clear.
- Configuration references real endpoints/keypaths.
- Relevant preview/build/tests were run.
- App-specific docs or notes were updated when behavior changed.
