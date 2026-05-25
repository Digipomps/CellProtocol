---
name: cellprotocol-cell-authoring
description: Use when creating, editing, reviewing, or testing individual HAVEN/CellProtocol Cells in the existing Swift runtime, including GeneralCell subclasses, get/set intercepts, flow emission, Explore schema, resolver registration, CellConfiguration samples, and minimal skeletons. Do not use for pure CellConfiguration-only work; use cellconfiguration-skeleton-authoring for that.
---

# CellProtocol Cell Authoring

Use this skill when the task is to build or change a concrete Cell in the
current Swift implementation.

This skill sits above `cellconfiguration-skeleton-authoring` and below
`cellprotocol-core-runtime-implementation`: it is for normal cell development,
not for changing protocol semantics.

## Core Rules

- Treat the current codebase as source of truth.
- Prefer `GeneralCell` and existing local patterns unless the task truly needs a
  lower-level protocol type.
- Keep Cell behavior explicit through `get`, `set`, flow emission, and Explore
  metadata. Do not add hidden mutable APIs.
- All mutation must go through explicit `set`/Meddle-style paths or current
  approved runtime mechanisms.
- Register exposed keys with schema/explore metadata. Read-only keys still need
  explicit schema when they are part of the contract.
- Emit `FlowElement`s for observable behavior that consumers should replay or
  audit.
- Define identity, capability, persistence, and resolver assumptions explicitly.
- Provide a minimal `CellConfiguration` only when it helps use the Cell; do not
  turn this into skeleton design work.
- If a change requires new resolver semantics, transport behavior, identity
  rules, or replay semantics, switch to the relevant deeper skill.
- If registering the Cell requires new scaffold wiring, new initializer entries,
  or factory registration outside existing patterns, switch to
  `cellprotocol-scaffold-integration`.

## Read First

Always inspect the target cell or nearest existing pattern first. Then read only
the docs needed for the task:

- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/10_Quickstart.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/11_Developer_Guide_Cell.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/13_Agent_Instructions.md`

Common source references:

- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Sources/CellBase/Cells/GeneralCell/GeneralCell.swift`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Sources/CellBase/Protocols/CellProtocol.swift`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Sources/CellBase/Cells/CellResolver/CellResolver.swift`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Sources/CellBase/CellConfiguration/CellConfiguration.swift`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Tests/CellBaseTests`

## Required Workflow

1. Identify the Cell's responsibility in one sentence.
2. Find the nearest existing Cell pattern and match its style.
3. Define the public contract:
   - get keypaths
   - set/action keypaths
   - emitted flow topics/types
   - Explore schema entries
   - identity/capability assumptions
   - persistence expectations
4. Implement the smallest Cell change that satisfies the contract.
5. Register the Cell with the resolver or scaffold only where that is already
   the local pattern.
6. Add focused tests for at least one get path, one set/action path when present,
   and emitted flow behavior when behavior is observable.
7. Add or update a minimal `CellConfiguration` sample only when the user needs a
   usable surface.
8. Run the narrowest relevant Swift tests. Broaden tests if resolver, identity,
   replay, or shared helpers are touched.

## Output Requirements

When finishing a cell task, report:

- files changed
- the Cell contract added or changed
- tests run and result
- any follow-up needed for UI skeleton, resolver policy, docs, or scaffold wiring

## Guardrails

- Do not bypass resolver/policy checks for convenience.
- Do not invent keypaths that are not implemented.
- Do not make UI-only state authoritative protocol state.
- Do not silently change a flow payload or schema shape used by other cells.
- Do not introduce transport or network assumptions inside normal Cell logic.
- Do not promote a demo/helper path to a stable contract without tests.
