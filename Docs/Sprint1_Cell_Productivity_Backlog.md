# Sprint 1 Backlog - CellProtocol (Core Runtime)

## Sprint Objective
Deliver the runtime contracts needed for a cell-based productivity tool: vault graph primitives, AI orchestration contracts, and purpose/interest-driven matching integration.

## Issues

### CP-01 (P0, 3 days): VaultCell Contract v1
Goal:
- Add a canonical note and link contract for vault operations.

Implementation touchpoints:
- `Sources/CellBase` for portable value contracts.
- `Sources/CellApple` runtime registration/bootstrap.

Deliverables:
- Keypaths: `vault.note.create`, `vault.note.update`, `vault.note.get`, `vault.note.list`.
- Link keypaths: `vault.link.add`, `vault.links.forward`, `vault.links.backlinks`.
- Schema types: `VaultNoteRecord`, `VaultLinkRecord`, `VaultQuery`.

Acceptance criteria:
1. Invalid payloads return structured `CellError` objects with field-level details.
2. All keypaths are documented in a new markdown contract section in `Docs`.
3. Stable JSON encoding/decoding roundtrip tests exist for note and link records.
4. Runtime supports deterministic ordering for list queries.

### CP-02 (P0, 4 days): GraphIndexCell v1
Goal:
- Build an index cell that computes forward links and backlinks from markdown notes.

Implementation touchpoints:
- New `GraphIndexCell` under `Sources/CellApple`.
- Shared parsing helpers under `Sources/CellBase` if needed.

Deliverables:
- Markdown wiki-link extraction (`[[note-id]]`).
- Rebuild endpoint: `graph.reindex`.
- Query endpoints: `graph.outgoing`, `graph.incoming`, `graph.neighbors`.

Acceptance criteria:
1. Reindexing same input twice produces byte-equal sorted outputs.
2. Backlinks reflect updates when notes are edited or deleted.
3. Unit tests cover empty graph, cyclic links, and orphan nodes.
4. Query latency for 1k notes stays within agreed benchmark envelope in tests.

### CP-03 (P0, 3 days): AIOrchestrator Contract + Provider Routing Policy
Goal:
- Introduce a provider-agnostic orchestration contract with subscription vs BYOK routing.

Implementation touchpoints:
- New orchestrator cell and provider adapter protocol.
- `KeychainManager` integration for secure key lookup.

Deliverables:
- Keypaths: `ai.route.plan`, `ai.route.execute`, `ai.providers.list`.
- Policy input fields: `planType`, `apiKeyAlias`, `costLimit`, `latencyClass`, `privacyMode`.

Acceptance criteria:
1. Routing decision object includes selected provider and reject reason when blocked.
2. BYOK requests fail closed when key alias is missing.
3. Subscription mode can execute with no user API key.
4. Contract tests verify deterministic routing for fixed policy fixtures.

### CP-04 (P0, 2 days): Complete GraphMatchTool Integration
Goal:
- Replace placeholder `GraphMatchTool` behavior with real Perspective matching.

Implementation touchpoints:
- `Sources/CellApple/Intelligence/Tools/GraphMatchTool.swift`.
- `PerspectiveCell` keypath integration.

Deliverables:
- Tool request includes purpose and interest refs.
- Response returns ranked candidates and score explanation.

Acceptance criteria:
1. Tool no longer returns stub-only text responses.
2. Ranking output includes direct and via-interest score components.
3. Tool execution is covered by at least one integration test with seeded fixture data.
4. Failure paths return machine-readable errors, not plain strings.

### CP-05 (P1, 2 days): Core Contract Regression Pack
Goal:
- Add a focused regression suite for new Sprint 1 runtime contracts.

Deliverables:
- Test matrix document for vault, graph index, and orchestrator routing.
- Snapshot fixtures for stable response contracts.

Acceptance criteria:
1. `swift test` includes a dedicated Sprint 1 test group.
2. Contract snapshots are deterministic across repeated runs.
3. CI fails when contract shape changes without fixture update.

## Dependency Order
1. CP-01
2. CP-02
3. CP-03 and CP-04 in parallel after CP-01
4. CP-05 after CP-01 to CP-04

## Definition of Done
1. All P0 issues merged with tests.
2. Keypaths and payload contracts documented in `Docs`.
3. No unresolved TODO markers in Sprint 1 core files.
