# Vault And Graph Contracts (Sprint 1 / CP-01 + CP-02)

This document defines the first runtime contracts for vault notes/links and markdown graph indexing.

## Cell Contracts

### `cell:///Vault`
Operations are implemented as `set` keypaths unless explicitly marked as `get`.

1. `vault.note.create` (`set`)
- Input: `VaultNoteRecord` or `{ "note": VaultNoteRecord }`
- Output: `{ status, operation, result }` with created note

2. `vault.note.update` (`set`)
- Input: `VaultNoteRecord` or `{ "note": VaultNoteRecord }`
- Output: `{ status, operation, result }` with updated note

3. `vault.note.get` (`set`)
- Input: `"note-id"` or `{ "id": "note-id" }`
- Output: `{ status, operation, result }` with one note

4. `vault.note.list` (`set`)
- Input: `VaultQuery` or `{ "query": VaultQuery }`
- Output: `{ status, operation, result }`, where `result` contains:
  - `items`: note list
  - `count`
  - `total`
  - `offset`
  - `limit`

5. `vault.link.add` (`set`)
- Input: `VaultLinkRecord` or `{ "link": VaultLinkRecord }`
- Output: `{ status, operation, result }` with normalized link

6. `vault.links.forward` (`set`)
- Input: `"note-id"` or `{ "id": "note-id" }`
- Output: `{ status, operation, result }`, where `result.links` is links from source note

7. `vault.links.backlinks` (`set`)
- Input: `"note-id"` or `{ "id": "note-id" }`
- Output: `{ status, operation, result }`, where `result.links` is links pointing to target note

8. `vault.state` (`get`)
- Output: operational metadata and counts

### `cell:///GraphIndex`
Operations are implemented as `set` keypaths unless explicitly marked as `get`.

1. `graph.reindex` (`set`)
- Input: `{ "notes": [ { "id": "...", "content": "..." } ] }`
- Behavior: rebuilds outgoing/incoming index from `[[wikilinks]]`
- Output: `{ status, operation, result }` with node/edge counts

2. `graph.outgoing` (`set`)
- Input: `"node-id"` or `{ "id": "node-id" }`
- Output: ordered linked node IDs

3. `graph.incoming` (`set`)
- Input: `"node-id"` or `{ "id": "node-id" }`
- Output: ordered backlink node IDs

4. `graph.neighbors` (`set`)
- Input: `"node-id"` or `{ "id": "node-id" }`
- Output: union of incoming/outgoing node IDs

5. `graph.state` (`get`)
- Output: operational metadata and counts

## Canonical Data Schemas

### `VaultNoteRecord`
- `id: String` (required)
- `slug: String?`
- `title: String` (required)
- `content: String`
- `tags: [String]`
- `createdAtEpochMs: Int`
- `updatedAtEpochMs: Int`

### `VaultLinkRecord`
- `fromNoteID: String`
- `toNoteID: String`
- `relationship: String` (default: `wiki`)
- `createdAtEpochMs: Int`

### `VaultQuery`
- `ids: [String]?`
- `text: String?`
- `tags: [String]?`
- `limit: Int?` (clamped)
- `offset: Int?` (clamped)
- `sortBy: VaultSortBy?` (`id`, `title`, `createdAt`, `updatedAt`)
- `descending: Bool?`

## Error Contract

Validation failures return structured errors:

```json
{
  "status": "error",
  "operation": "vault.note.create",
  "code": "validation_error",
  "message": "Validation failed for note create",
  "field_errors": [
    { "field": "title", "code": "missing", "message": "title is required" }
  ]
}
```

Notes:
- `code` is machine-readable (`validation_error`, `not_found`, `encoding_failed`, ...).
- `field_errors` is always present for validation-style failures.

