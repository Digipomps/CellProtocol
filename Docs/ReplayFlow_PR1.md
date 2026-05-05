# Replay and Provenance: PR1 Foundations

This document captures the first implementation slice for replay/provenance support.

## Scope

PR1 introduces model and hashing foundations only:

- `FlowEnvelope` as transport-neutral event wrapper.
- `FlowProvenance` for origin proof metadata.
- `FlowRevisionLink` for revision-chain pointers.
- Canonical encoding for deterministic hashing.
- SHA-256 helpers for payload and envelope hashes.

Runtime enforcement, signing, replay engine, and bridge protocol migration are intentionally deferred to later PRs.

## Concepts

### FlowEnvelope

A `FlowEnvelope` wraps a `FlowElement` with fields required for replay and integrity:

- stream identity (`streamId`)
- strict order (`sequence`)
- domain scope (`domain`)
- producer identity (`producerIdentity`)
- producer cell (`producerCell`)
- payload hash (`payloadHash`)
- chain linkage (`previousEnvelopeHash`)

The envelope is the unit that will later be signed, persisted, verified, and replayed.

### Provenance

`FlowProvenance` stores origin-level information independent of transport:

- `originCell`
- `originIdentity`
- optional origin signature/hash fields

This creates a stable place to prove where a `FlowElement` was first emitted.

### Revision Link (lightweight blockchain primitive)

`FlowRevisionLink` provides a revision pointer (`previousRevisionHash`) plus `revision` counter.

This is the minimal primitive needed for a per-flow append-only revision chain when `FlowElement`s evolve over time.

### Canonical encoding

Hashing requires deterministic bytes. The canonical encoder therefore:

- converts envelopes and payloads into JSON-compatible objects
- tags typed values so semantically distinct variants cannot collide
- serializes with sorted object keys

Equivalent payloads with different dictionary insertion order now produce identical hashes.

## Process Used

1. Added new core types in `Sources/CellBase/Flow`.
2. Added `FlowCanonicalEncoder` that converts `FlowElement`, `FlowEnvelope`, and nested `ValueType` trees to deterministic JSON.
3. Added `FlowHasher` with SHA-256 (`swift-crypto`).
4. Added tests for:
- envelope roundtrip coding
- payload hash stability across key-order variance
- envelope hash change on sequence change

## Test Coverage Added

- `Tests/CellBaseTests/FlowEnvelopeSerializationTests.swift`

These tests assert deterministic hashing and baseline serialization behavior for the new model.

## Known limitations in PR1

- No runtime signature generation/verification yet.
- No resolver-side sequence enforcement yet.
- No append-only ledger storage or replay engine yet.
- No bridge wire format migration yet.

## Next steps (PR2+)

- Add envelope signing/verification against identity vault.
- Move flow publication path to envelope-first.
- Persist envelopes in append-only ledger and implement replay engine.
- Extend bridge protocol with envelope payload support.
