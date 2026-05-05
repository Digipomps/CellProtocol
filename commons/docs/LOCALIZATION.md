# Localization and Semantic Labels

HAVEN localization is deterministic. Agents and runtime code must not use AI to
translate taxonomy labels on the fly.

## Core Model

- `term_id` is the stable semantic meaning.
- `namespace` scopes and versions the vocabulary.
- `labels` are localized presentation strings only.
- `relations` define language-independent meaning between terms.

Example:

```json
{
  "term_id": "interest.ai",
  "labels": {
    "nb-NO": "Kunstig intelligens",
    "en-US": "Artificial Intelligence"
  },
  "kind": "interest",
  "relations": [{"kind": "related", "target": "topic.interoperability"}]
}
```

User interfaces should show the localized label, but matching, filtering,
storage, cache keys, agreements, and audits should use `term_id`/`namespace`.

## Fallback Order

The resolver uses the same fallback order everywhere:

1. exact locale, for example `nb-NO`
2. base language, for example `nb`
3. `nb-NO`
4. `nb`
5. `en-US`
6. `en`
7. first available label sorted by locale key
8. `term_id`

Resolved payloads include:

- `label`
- `requested_locale`
- `resolved_locale`
- `fallback_used`

This lets Binding and CellScaffold explain when a display value is a fallback
without changing the canonical meaning.

## Catalog and Discovery Contracts

`ConfigurationCatalogQueryRequest` supports:

- `locale`
- `includeLocalizedLabels`

`ConfigurationCatalogEntryContract` may include `localizedDisplay` with
localized purpose and interest labels. Existing fields like `purpose`,
`displayName`, `summary`, and `interests` remain legacy/fallback presentation
fields.

`CellConfigurationDiscovery` supports:

- `purposeRefs`
- `interestRefs`
- `localizedText`

The old `purpose`, `purposeDescription`, and `interests` fields remain valid.
New code should prefer refs for meaning and localized text for presentation.

## CommonsTaxonomyCell

Use `taxonomy.resolve.batchTerms` for localized display labels. The preferred
payload shape is:

```json
{
  "locale": "nb-NO",
  "namespace": "haven.core",
  "terms": ["interest.ai", "purpose.learn"]
}
```

Legacy list payloads still work:

```json
[
  {"term_id": "interest.ai", "lang": "nb-NO", "namespace": "haven.core"}
]
```

Use `taxonomy.validate.localizationCoverage` to warn when required labels are
missing:

```json
{
  "namespace": "haven.core",
  "required_locales": ["nb-NO", "en-US"]
}
```

## Implementation Rule

If a requested UI label cannot be represented by existing taxonomy labels or
`localizedText`, report the gap to Kjetil before adding new skeleton or renderer
capabilities.
