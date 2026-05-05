# ContractProbeCell RAG Follow-up

Status: started

## Goal

Make `ContractProbeCell` output a first-class source for:

- documentation freshness
- developer lookup
- agent retrieval
- staging verification history

The practical target is that a human or code agent can ask:

- "What does this cell claim to do?"
- "Was that claim verified recently?"
- "Which keys or flow topics are failing?"

and get one coherent answer from indexed contract + probe data.

## Problem

The codebase now has two strong building blocks:

1. `exploreContractCatalog(requester:)`
2. `ContractProbeCell` reports

They are useful separately, but the docs/RAG pipeline still lacks a canonical
combined artifact that says:

- declared interface
- observed verification result
- verification time
- failing assertions
- source cell endpoint

Without that join, retrieval can find what a cell claims, but not whether the
claim was actually validated.

## Scope

This follow-up should cover one narrow vertical slice:

1. define a canonical combined record shape
2. export it as JSON + Markdown
3. make it chunkable per key and per assertion
4. attach freshness metadata suitable for RAG filters
5. add tests for the export shape

Do not build a full UI or full RAG service here.

## Deliverables

### 1. Combined verification record

Implemented:

- `ContractProbeVerificationRecord`
- builder from `ExploreContractCatalog` + `ContractProbeReport`
- convenience API on `CellProtocol`
- real-cell test coverage for JSON roundtrip and Markdown failure summary

Still missing:

- stricter metadata envelopes per chunk for external indexers
- staging pipeline integration

Add a record model that combines:

- target endpoint
- cell type or label when known
- contract catalog items
- latest probe report
- verification timestamp
- verification summary

Minimum JSON fields:

```json
{
  "record_type": "cell_contract_verification",
  "repo": "CellProtocol",
  "target_endpoint": "cell:///Vault",
  "target_label": "vault",
  "verified_at": "2026-03-08T18:22:10Z",
  "verification_status": "completed",
  "passed_count": 7,
  "failed_count": 0,
  "skipped_count": 0,
  "contract_items": [],
  "assertions": []
}
```

### 2. Markdown export for indexing

Implemented in first form via `ContractProbeVerificationRecord.markdown`.

Still needed:

- tighter section conventions for automated chunking
- direct failed-assertion chunk export

Produce a Markdown companion document with stable sections:

- summary
- target identity
- declared keys
- latest verification result
- failing assertions
- observed flow topics

This Markdown should be optimized for retrieval and quoting, not prose.

### 3. Chunking contract

Implemented in first form:

- one summary chunk per cell
- one chunk per key contract
- one chunk per failed assertion
- one chunk per flow assertion group

Current API:

- `ContractProbeVerificationRecord.ragChunks()`
- `cell.exploreContractVerificationChunks(...)`

Define chunk units for RAG:

- one summary chunk per cell
- one chunk per key contract
- one chunk per failed assertion
- one chunk per flow assertion group

Each chunk should carry stable metadata:

- `repo`
- `target_endpoint`
- `key`
- `phase`
- `status`
- `verified_at`
- `document_kind`

### 4. Freshness metadata

Add fields that allow filtering and ranking:

- `last_verified_at`
- `verification_status`
- `failed_assertion_count`
- `has_runtime_probe`
- `contract_version`

This is needed so retrieval can prefer recent, passing, runtime-verified
records over stale or purely declarative ones.

### 5. Tests

Add tests that verify:

- combined export is structurally stable
- Markdown export includes key summary + failure summary
- failing probe assertions appear in exported records
- freshness metadata is present

## Proposed implementation order

1. Add `ContractProbeVerificationRecord` model.
2. Add exporter that joins `exploreContractCatalog(requester:)` with a
   `ContractProbeReport`.
3. Add Markdown renderer for the joined record.
4. Add tests in `CellBaseTests`.
5. Document the record shape where docs/RAG tooling can rely on it.

## Acceptance criteria

- A single function can emit a combined JSON record from contract catalog +
  probe report.
- The same data can be emitted as Markdown for indexing.
- Failed assertions are visible without reading raw test logs.
- A retriever can filter on `verification_status` and `last_verified_at`.
- At least one real-cell test proves the export is stable.

## Suggested file targets

- `Sources/CellBase/Cells/GeneralCell/ExploreContractCatalog.swift`
- `Sources/CellBase/Cells/Testing/ContractProbeCell.swift`
- `Tests/CellBaseTests/RealCellContractTests.swift`
- optionally a small dedicated exporter file under
  `Sources/CellBase/Cells/Testing/`

## Non-goals

- building full search UI
- building the full staging RAG gateway
- replacing `XCTest` with runtime probes
- storing historical probe records outside the cell runtime
