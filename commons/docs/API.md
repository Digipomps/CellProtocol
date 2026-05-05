# Local Service API (Library)

`CommonsLocalService` gir en enkel API-overflate for lokale kall.

Fil:
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/commons/resolver/keypath-resolver/Sources/KeyPathResolver/CommonsLocalService.swift`

## Endepunkter (metoder)

### `postResolveKeyPath(_ request)`
Input:
- `entity_id`
- `path`
- `context` (`role`, `consent_tokens`)
- valgfri `binding` (hvis ikke satt brukes seedet `EntityAnchorBinding`)

Output:
- `resolved_cell_id`
- `resolved_cell_type`
- `resolved_local_path`
- `type_ref`
- `permission`
- `audit_info`
- `storage_domain`

Merk:
- Uregistrerte/custom keypaths er tillatt og returneres som åpne referanser med `type_ref: "haven.core#/OpenValue"`.
- `audit_info.registry_matched` viser om path kom fra registry eller åpen fallback.

Eksempel (konseptuelt HTTP payload):
```json
{
  "entity_id": "entity-1",
  "path": "#/purposes",
  "context": {
    "role": "owner",
    "consent_tokens": []
  }
}
```

### `getTaxonomyTerm(id:namespace:)`
Input:
- `id` (`term_id`)
- valgfri `namespace`

Output:
- rå `Term` eller `nil`

### `getTaxonomyResolve(termId:lang:namespace:)`
Input:
- `term_id`
- `lang` (f.eks. `nb-NO`)
- valgfri `namespace`

Output:
- `ResolvedTaxonomyTerm` (term + label + source namespace + replacement hvis deprecated)
- inkluderer `requested_locale`, `resolved_locale` og `fallback_used`

### `getTaxonomyLocalizedTerm(termId:lang:namespace:)`
Input:
- `term_id`
- `lang` (f.eks. `nb-NO`)
- valgfri `namespace`

Output:
- `ResolvedLocalizedTerm` for UI-presentasjon uten å miste canonical `term_id`

### `getTaxonomyGuidance(namespace:)`
Input:
- `namespace`

Output:
- `TaxonomyPackage.Guidance` (root purpose, contribution purpose, article reference, goal policy)

### `getTaxonomyPurposeTreeValidation(namespace:)`
Input:
- `namespace`

Output:
- `PurposeTreeValidationResult`
  - `is_valid`, `error_count`, `warning_count`
  - `mandatory_purpose_term_ids`
  - `issues` med kode/severity/term-id

### `getTaxonomyLocalizationCoverage(namespace:requiredLocales:)`
Input:
- `namespace`
- `requiredLocales` (default `nb-NO`, `en-US`)

Output:
- `TaxonomyLocalizationCoverageResult`
  - `isComplete`, `warningCount`
  - `issues` for aktive terms som mangler label for et påkrevd språk

## Notes
- API-et er library-first; HTTP wrapping kan legges oppå uten å endre resolver-kjernen.
- Path URI parsing (`haven://entity/...`) støttes i `PathURI`.
- For CellScaffold er API-et pakket inn i `CommonsResolverCell` og `CommonsTaxonomyCell`.
  - se `commons/docs/CELLS.md`.
