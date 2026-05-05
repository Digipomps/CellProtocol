# Observability and Runtime Diagnostics

This note defines the current logging policy for `CellProtocol`, the minimum
diagnostic hooks now implemented, and the next recommended runtime inspection
cells.

## Goal

The goal is to keep default execution quiet while still allowing targeted,
high-signal diagnostics when debugging runtime behavior, flow routing, or
contract mismatches.

The wrong default is:

- noisy `print(...)` calls in hot paths
- no clear separation between debug traces and actual runtime failures
- no structured way to inspect flow/state without editing code

## Current policy

Default runtime behavior should be quiet.

Pure debug traces should not print unless explicitly enabled.

Actual failures may still be surfaced through:

- thrown errors
- `FlowElement` alerts/events
- explicit warning/error logs where the runtime would otherwise fail silently

## Implemented diagnostic hook

`CellBase` now exposes an opt-in diagnostic logger:

```swift
CellBase.enabledDiagnosticLogDomains = [.flow, .resolver]
CellBase.diagnosticLogHandler = { domain, message in
    print("[\(domain.rawValue)] \(message)")
}
```

Available domains:

- `.lifecycle`
- `.flow`
- `.resolver`
- `.skeleton`
- `.agreement`
- `.semantics`
- `.identity`
- `.credentials`

If no custom handler is installed, enabled diagnostics fall back to:

```swift
[CellBase][<domain>] <message>
```

## What was quieted

Pure debug output in these hot paths now goes through `CellBase.diagnosticLog`
instead of unconditional `print(...)`:

- `Sources/CellBase/Cells/GeneralCell/GeneralCell.swift`
- `Sources/CellBase/Cells/CellResolver/CellResolver.swift`
- `Sources/CellBase/Skeleton/SkeletonDescription.swift`
- `Sources/CellBase/Agreement/Agreement.swift`
- `Sources/CellBase/Agreement/Condition/Implementation/LookupCondition.swift`
- `Sources/CellBase/Agreement/Condition/Implementation/GrantCondition.swift`
- `Sources/CellBase/PurposeAndInterest/Interest.swift`
- `Sources/CellBase/PurposeAndInterest/Purpose.swift`
- `Sources/CellBase/PurposeAndInterest/Weight.swift`
- `Sources/CellBase/Identity/Identity.swift`
- `Sources/CellBase/Identity/Identity+DID.swift`
- `Sources/CellBase/Identity/BridgeIdentityVault.swift`
- `Sources/CellBase/Identity/IdentitiesCell.swift`
- `Sources/CellBase/VerifiableCredentials/VCProof.swift`
- `Sources/CellBase/VerifiableCredentials/VCClaim.swift`
- `Sources/CellBase/VerifiableCredentials/DIDDocument.swift`
- `Sources/CellBase/VerifiableCredentials/DIDIdentityVault.swift`

This specifically removes the noise that previously dominated:

- `GeneralCell` lifecycle traces
- resolver `get`/`set`/subscription traces
- skeleton decoder fallback spam
- low-level interaction traces emitted by `CellResolver.logAction(...)`

## Recommended logging model

Use two layers:

1. Opt-in in-process diagnostics for developer debugging.
2. Stable operational logs at service boundaries.

For `CellProtocol`, the in-process diagnostic hook is the right primitive.

For `rag_service`, use standard Python `logging` and `LOG_LEVEL`; do not add a
parallel ad-hoc print-based system.

## Recommended runtime inspection cells

Some questions are better answered by cells than by logs.

Already available:

- `ContractProbeCell`
  - verifies declared contract vs runtime behavior
  - produces JSON/Markdown/chunk artifacts for docs and RAG
- `EntityAtlasInspectorCell`
  - snapshots resolver-visible cells, purposes, dependencies, and coverage

Recommended next cells:

### `FlowProbeCell`

Purpose:

- attach to selected flows
- filter by topic, origin, endpoint, or label
- collect a bounded in-memory trace
- expose trace via `get` keys and optional export keys

Why:

- better than raw logs for causality and event ordering
- can run in staging without code edits
- can be indexed later if needed

### `StateSnapshotCell`

Purpose:

- query selected `get` keys from target cells on demand
- capture point-in-time state with timestamps and probe context
- compare snapshots before/after a flow or contract run

Why:

- reduces the need for temporary debug getters
- makes runtime state inspection explicit and repeatable

## When to use logs vs probe cells

Use diagnostic logs for:

- tracing resolver decisions
- understanding flow attachment/detachment
- following skeleton decode fallbacks
- short-lived local debugging

Use probe/inspection cells for:

- staging verification
- agent-driven debugging
- repeatable runtime audits
- flow/state inspection that should remain available after debugging

## RAG bridge

`ContractProbeVerificationRecord` and
`cell.exploreContractVerificationChunks(...)` are the current bridge from
runtime verification into searchable documentation.

The expected downstream ingest route is:

- `POST /v1/cell/cases/{case_id}/contract-verification`

That route stores probe verification artifacts as ordinary RAG documents, which
means both human developers and AI code assistants can retrieve:

- declared keys
- failed assertions
- flow-side effect expectations
- verification freshness metadata

## Practical recommendation

Do this in order:

1. Keep hot-path debug output behind `CellBase.diagnosticLog`.
2. Leave actual failures visible.
3. Add `FlowProbeCell` and `StateSnapshotCell` instead of adding more prints.
4. Feed contract verification artifacts into docs/RAG through the dedicated
   contract-verification ingest route.
