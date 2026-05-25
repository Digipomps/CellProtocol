---
name: cellprotocol-cross-language-porting
description: Use when implementing, reviewing, or planning CellProtocol in another language or runtime, especially Kotlin, Java, Rust, or Go. Covers protocol invariants, language-specific concurrency and serialization choices, stable JSON/wire contracts, golden fixtures, resolver policy, replay determinism, and Scaffold/runtime parity. Do not use for simple CellConfiguration JSON authoring.
---

# CellProtocol Cross-Language Porting

Use this skill when CellProtocol is being implemented outside the current Swift
reference runtime, or when designing fixtures that another runtime must pass.

## Porting Goal

The target language does not need to mirror Swift structure 1:1. It must preserve
CellProtocol semantics, contracts, and testable behavior.

If the port includes a skeleton parser or renderer, use this skill together with
`cellprotocol-skeleton-renderer-porting`. This skill owns protocol/runtime
parity; the renderer skill owns skeleton JSON parity, element inventory, and UI
behavior.

## Non-Negotiable Concepts

- Deterministic execution and replay.
- Ordered, auditable flow as the source of observable behavior.
- Explicit capability and contract enforcement.
- Domain-scoped identity, never global account identity.
- Transport-neutral semantics.
- Stable JSON/wire contracts with golden fixtures.
- Side-effect-free `Explore` metadata.
- Resolver-mediated access for Absorb/Meddle behavior.
- Isolated Cells supervised by a Scaffold/runtime.

## Read First

Required:

- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/01_CellProtocol_Core.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/02_Cell_Interfaces.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/03_Identity_Model.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/04_Agreements_Contracts.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/05_Flows_Lifecycle.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/06_CellResolver.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/07_Scaffold_Runtime.md`

For Kotlin/Java:

- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Deliverables/Vegar_CellProtocol_Scaffold_Kotlin_Pack/README_Vegar_Kotlin.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Deliverables/Vegar_CellProtocol_Scaffold_Kotlin_Pack/Kotlin_Implementation_Checklist.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Deliverables/Vegar_CellProtocol_Scaffold_Kotlin_Pack/Swift_to_Kotlin_Mapping.md`

For skeleton/UI parity:

- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/12_Skeleton_Spec.md`

## Language Guidance

Kotlin/Java:

- Model `ValueType` as an explicit sealed hierarchy or equivalent tagged type.
- Use coroutines plus `Mutex`, an actor, or a single-threaded dispatcher per
  Cell to preserve deterministic mutation.
- Keep resolver as an injected policy engine, not a global bypassable singleton.
- Use kotlinx serialization/Jackson only with explicit field names and fixtures.
- For skeleton parser/renderer implementation, follow
  `cellprotocol-skeleton-renderer-porting` in full. Do not add element types or
  renderer behavior from this skill.

Rust:

- Prefer explicit enums for protocol values and errors.
- Make mutation boundaries visible through traits and async-safe state guards.
- Avoid deriving wire formats without golden fixtures.
- Treat `Send`/`Sync` decisions as part of the safety model.

Go:

- Use interfaces for `Emit`, `Absorb`, `Meddle`, `Explore`, but keep mutation
  serialized through an explicit runtime/supervisor.
- Avoid map-order-dependent encoding in tests.
- Make context cancellation a transport/runtime concern, not protocol semantics.

## Required Implementation Slices

1. Core values: `Identity`, `ValueType`, `FlowElement`, agreements/conditions.
2. Interfaces: `Emit`, `Absorb`, `Meddle`, `Explore`.
3. Resolver: all policy decisions pass through it.
4. Scaffold/runtime: lifecycle, storage, replay, supervisor.
5. CellConfiguration: discovery, references, initial sets, skeleton.
6. Skeleton parser/renderer only if the target runtime renders UI; use
   `cellprotocol-skeleton-renderer-porting` for this slice.
7. Transport bridge only after local deterministic behavior works.

## Test Gate Before Claiming Parity

- Golden JSON fixtures for core values and skeleton.
- Replay determinism tests.
- Resolver rejection tests for missing capability/condition.
- Interface tests for `Emit`, `Absorb`, `Meddle`, and `Explore`.
- Transport neutrality tests if a bridge exists.
- Cross-runtime fixture comparison against Swift where feasible.

## Must Not

- Do not call a port "CellProtocol-compatible" because it has similar class
  names. Compatibility is behavioral and fixture-tested.
- Do not move authority into transport.
- Do not use global users/accounts as protocol identity.
- Do not add implicit mutation APIs for language convenience.
- Do not silently reinterpret Swift JSON shapes.
- Do not start a new language port without explicit approval from Kjetil.
  Approval should name the target language, intended scope, and golden fixtures
  required before compatibility is claimed.

## Output Pattern

For plans or reviews, report:

- target language/runtime
- supported CellProtocol surface
- explicit gaps
- fixtures/tests required next
- any semantics that need Kjetil approval before changing
