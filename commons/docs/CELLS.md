# Commons Cells for CellScaffold

Commons-funksjonaliteten er pakket inn i tre Cells i `CellBase`:

- `CommonsResolverCell` (`cell:///CommonsResolver`)
- `CommonsTaxonomyCell` (`cell:///CommonsTaxonomy`)
- `EntityAtlasInspectorCell` (`cell:///EntityAtlas`)

`Explore`-kontraktene for disse cellene er nå den strukturerte sannhetskilden
for input/output-dokumentasjon:

- `typeForKey(key:requester:)` returnerer en standardisert kontrakt per key
- `exploreContractCatalog(requester:)` eksporterer JSON + Markdown for docs/RAG

Markdown-dokumentasjonen under er fortsatt nyttig som oversikt, men ved drift i
staging eller automatisk dokumentgenerering bør kontraktkatalogen behandles som
kanonisk kilde.

Disse registreres i app-oppsett:
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Sources/CellApple/Cells/Porthole/Utility Views/Skeleton/AppInitializer.swift`

## Endpoints

### `cell:///CommonsResolver`
Set-operasjoner:
- `commons.configure.rootPath`
- `commons.resolve.keypath`
- `commons.resolve.batchKeypaths`
- `commons.lint.keypaths`
- `commons.validate.schemas`

Get-operasjoner:
- `commons.status`
- `commons.samples.keypathRequests`

Eksempel payload (`commons.resolve.keypath`):
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

### `cell:///CommonsTaxonomy`
Set-operasjoner:
- `taxonomy.configure.rootPath`
- `taxonomy.resolve.term`
- `taxonomy.resolve.batchTerms`
- `taxonomy.resolve.guidance`
- `taxonomy.validate.purposeTree`
- `taxonomy.validate.localizationCoverage`

Get-operasjoner:
- `taxonomy.status`
- `taxonomy.samples.termRequests`

Eksempel payload (`taxonomy.resolve.term`):
```json
{
  "term_id": "goal.support-local-community",
  "lang": "nb-NO",
  "namespace": "haven.conference"
}
```

Eksempel payload (`taxonomy.resolve.batchTerms` med felles språk):
```json
{
  "locale": "nb-NO",
  "namespace": "haven.core",
  "terms": ["interest.ai", "purpose.learn"]
}
```

Eksempel payload (`taxonomy.validate.localizationCoverage`):
```json
{
  "namespace": "haven.core",
  "required_locales": ["nb-NO", "en-US"]
}
```

### `cell:///EntityAtlas`
Set-operasjoner:
- `atlas.snapshot`
- `atlas.export.redactedJSON`
- `atlas.export.redactedMarkdown`
- `atlas.query.cellsForPurpose`
- `atlas.query.scaffoldCandidates`
- `atlas.query.purposesForCell`
- `atlas.query.cellsRequiringCredentials`
- `atlas.query.knowledgeCells`
- `atlas.query.dependencies`
- `atlas.query.coverage`

Get-operasjoner:
- `atlas.status`
- `atlas.samples.requests`

Eksempel payload (`atlas.query.coverage`):
```json
{
  "purpose_ref": "purpose.net-positive-contribution"
}
```

Eksempel payload (`atlas.export.redactedJSON`):
```json
{
  "include_document_body_previews": false,
  "include_relation_explanations": true
}
```

Eksempel payload (`taxonomy.validate.purposeTree`):
```json
{
  "namespace": "haven.core"
}
```

## Konfigurasjon
Begge cellene kan bruke default `./commons` eller settes eksplisitt med:
- `commons.configure.rootPath`
- `taxonomy.configure.rootPath`

## Purpose helperCells
`Purpose` støtter `helperCells: [CellConfiguration]`.
Dette gjør det enkelt å koble måloppnåelse mot Commons-celler:
- auto-fiksing via cell med automatiske set/get-steg
- veiledning via cell som returnerer instruksjoner/innsikt
- `SDGPilotPurposeCatalog` viser dette i praksis for climate mobility, local child participation og institutional accountability

## Testdata
Store testdatasett ligger i:
- `Tests/CellBaseTests/Fixtures/CommonsKeypathRequests.json`
- `Tests/CellBaseTests/Fixtures/CommonsTermRequests.json`
- `Tests/CellBaseTests/Fixtures/CommonsHelperCellExamples.json`
