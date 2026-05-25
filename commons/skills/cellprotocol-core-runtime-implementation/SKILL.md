---
name: cellprotocol-core-runtime-implementation
description: Use when changing HAVEN/CellProtocol core runtime semantics or shared protocol machinery: Emit, Absorb, Meddle, Explore, FlowElement, ValueType, CellResolver enforcement, lifecycle, replay, deterministic execution, storage contracts, schema/explore behavior, or protocol-level APIs. This is a high-guardrail skill for core changes, not normal cell authoring.
---

# CellProtocol Core Runtime Implementation

Use this skill only for protocol/runtime-level work. Normal Cell feature work
belongs in `cellprotocol-cell-authoring`; pure UI configuration work belongs in
`cellconfiguration-skeleton-authoring`.

## Non-Negotiable Concepts

- Determinism: same input plus same history must produce the same outcome.
- Replay first: observable behavior must be reconstructable from ordered flow.
- Capability security: no authority without explicit identity, capability,
  condition, or contract path.
- Domain-scoped identity: do not introduce global identity assumptions.
- Transport independence: bridges carry events/payloads; they do not define
  protocol semantics.
- Explicit mutation: no hidden side channels for state changes.
- Explore transparency: cells expose useful side-effect-free contract metadata.
- Isolation: one Cell or transport failure must not corrupt unrelated Cells.

## Read First

Always start with the current source touched by the task. Then read:

- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/01_CellProtocol_Core.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/02_Cell_Interfaces.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/05_Flows_Lifecycle.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/06_CellResolver.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/07_Scaffold_Runtime.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Gap_Analysis.md`

Common source anchors:

- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Sources/CellBase/Protocols/CellProtocol.swift`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Sources/CellBase/Cells/CellResolver`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Sources/CellBase/Cells/GeneralCell`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Sources/CellBase/Common`

## Required Workflow

1. State the runtime invariant affected by the change.
2. Classify the change:
   - bug fix preserving semantics
   - new protocol capability
   - internal refactor
   - compatibility/migration change
3. Inspect all affected call paths before editing.
4. Preserve existing wire and JSON contracts unless the user explicitly approves
   a migration.
5. Add or update contract tests before broad refactors when possible.
6. Update `CellProtocolDocuments` when behavior, guarantees, boundaries, or
   developer-facing APIs change.
7. Run focused tests first, then wider Swift test targets for shared changes.

## Compatibility Rules

- Prefer additive behavior and explicit versioning over silent shape changes.
- Keep legacy decode where current persisted data requires it.
- When changing encode behavior, add golden tests.
- If migration is needed, document old shape, new shape, and transition plan.
- Do not turn scaffold/app convenience into core protocol semantics.
- Policy rule changes, such as new conditions, new capability checks, or
  identity-domain rules, belong in `cellprotocol-identity-capability-security`.
  This skill owns the resolver/runtime engine that executes those rules.

## Escalate Before Implementing

Ask before proceeding when a task would:

- weaken capability enforcement
- allow direct mutable access around resolver paths
- introduce global IDs or cross-domain tracking
- make transport behavior authoritative
- remove replay/audit evidence
- break stored JSON/flow compatibility
- require coordinated changes across CellProtocol, CellScaffold, Binding, and
  CellProtocolDocuments

## Completion Checklist

- Invariant preserved or intentionally changed with approval.
- Tests cover positive and rejection paths where relevant.
- Docs updated for protocol-level behavior.
- Migration/compatibility notes are explicit.
- No unrelated dirty work was reverted.
