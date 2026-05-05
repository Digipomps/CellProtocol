# HAVEN Commons (Taxonomy + KeyPath Registry)

Dette er en library-first Commons-implementasjon med lokal service API, seed-data, resolvere, CLI og tester.

## Prinsipper
- Keypaths er anbefalte, normaliserte referanser for interoperabilitet.
- Uregistrerte keypaths er tillatt og resolves som åpne referanser (`haven.core#/OpenValue`) slik at brukere kan utvide modellen uten blokkering.
- Taxonomy er også incentiv-basert: ikke tvangsregler.
- `haven.core` definerer et root purpose basert på menneskerettighetenes artikkel 1 (`purpose.human-equal-worth`) og et overliggende bidragspurpose (`purpose.net-positive-contribution`).
- Purposes bør følges av konkrete mål (`goal`), men dette håndheves som insentiv, ikke hard policy.
- `haven.sdg` oversetter FNs baerekraftsmaal til HAVEN `purpose families` og maalbare `goal`-templates uten aa lage en ny normativ rot.
- `commons/examples/perspectives/` holder concrete `PerspectiveDocument` examples for the first SDG pilot domains.

## Dokumentasjon
- `commons/docs/ARCHITECTURE.md`
- `commons/docs/API.md`
- `commons/docs/CLI.md`
- `commons/docs/CELLS.md`
- `commons/docs/SEED_DATA.md`
- `commons/docs/TESTING.md`

## Prompt-maler
- `commons/prompts/codex_commons_mvp_prompt.md`
- `commons/prompts/codex_add_taxonomy_prompt.md`
- `commons/prompts/codex_add_keypath_prompt.md`
- `commons/prompts/codex_review_prompt.md`

## Plan (MVP)
1. Opprette Commons-monorepo med taxonomies, keypaths, schemas, resolvere, CLI og tester.
2. Definere formater: `TaxonomyPackage`, `Term`, `KeyPathSpec`, `PathRoute`.
3. Implementere `TaxonomyRegistry` + `TaxonomyTermResolver` (arv, i18n, deprecations).
4. Implementere `KeyPathRegistry` + `KeyPathResolver` (prefix-routing, alias, permissions).
5. Legge inn local service API (`CommonsLocalService`) for resolve-endpoints.
6. Eksponere CLI: lint/validate/resolve.
7. Teste routing, alias/deprecation, permissions og taxonomy inheritance.

## Filstruktur
```text
commons/
  taxonomies/
    haven.core/package.json
    haven.conference/package.json
    haven.sdg/package.json
  keypaths/
    haven.core/keypaths.json
    haven.core/routes.json
  schemas/
    haven.core/taxonomy-package.schema.json
    haven.core/keypath-spec.schema.json
    haven.core/path-route.schema.json
    haven.perspective/perspective.schema.json
  examples/
    perspectives/*.json
  resolver/
    taxonomy-resolver/Sources/TaxonomyResolver/*.swift
    keypath-resolver/Sources/KeyPathResolver/*.swift
  cli/
    haven-commons/Sources/haven-commons/main.swift
  README.md
Tests/
  CellBaseTests/Fixtures/CommonsKeypathRequests.json
  CellBaseTests/Fixtures/CommonsTermRequests.json
  CellBaseTests/Fixtures/CommonsHelperCellExamples.json
Tests/
  HavenCommonsTests/*.swift
```

## Viktige egenskaper
- `#/purposes` er deprecated og mappes til `#/perspective`.
- `#/chronicle/*` rutes til `ChronicleCell` og er merket med `storage_domain: chronicle-store`.
- Kryss-celle resolution bruker `EntityAnchorBinding` (absorbed/linked/external).
- Permission classes støttes: `public`, `private`, `consent`, `aggregated`.
- KeyPath resolver støtter åpne/custom paths som ikke ligger i registry.

## Local Service API (library)
`CommonsLocalService` i `commons/resolver/keypath-resolver/Sources/KeyPathResolver/CommonsLocalService.swift`.

- `postResolveKeyPath(_ request)`
  - input: `entity_id`, `path`, `context` (+ optional `binding`)
  - output: `resolved_cell_id`, `resolved_local_path`, `type_ref`, `permission`, `audit_info`
- `getTaxonomyTerm(id:namespace:)`
- `getTaxonomyResolve(termId:lang:namespace:)`
- `getTaxonomyGuidance(namespace:)`
- `getTaxonomyPurposeTreeValidation(namespace:)`

## CellScaffold integrasjon
- `cell:///CommonsResolver` (keypath resolve/lint/validate)
- `cell:///CommonsTaxonomy` (term/guidance resolve)
- Registreres i app bootstrap (`AppInitializer`) for enkel bruk fra CellScaffold.
- Se `commons/docs/CELLS.md` for keypaths, payloads og eksempelbruk.

## CLI
Bygg CLI:
```bash
swift build --target HavenCommonsCLI
```

Kjør kommandoer:
```bash
swift run haven-commons lint keypaths
swift run haven-commons validate schema
swift run haven-commons validate purposes --namespace haven.core
swift run haven-commons resolve keypath --entity entity-1 --path '#/chronicle/events' --role member
swift run haven-commons resolve keypath --entity entity-1 --path 'haven://entity/self#/purposes' --role owner
swift run haven-commons resolve keypath --entity entity-1 --path '#/custom/football-club/initiative' --role member
swift run haven-commons resolve term --id purpose.learn --lang nb-NO --namespace haven.conference
swift run haven-commons resolve guidance --namespace haven.conference
swift run haven-commons resolve term --id purpose.sdg.no-poverty --lang nb-NO --namespace haven.sdg
```

## Tester
Kjør kun Commons-testene:
```bash
swift test --filter HavenCommonsTests
```

Decode pilot perspective examples directly:
```bash
swift test --filter PerspectiveSchemaTests/testSDGPilotPerspectiveExamplesDecode
```

## Legge til ny taxonomy
1. Opprett ny mappe under `commons/taxonomies/<namespace>/`.
2. Legg inn `package.json` i samme format som `haven.core`.
3. Sett `depends_on` for arv.
4. Kjør:
```bash
swift run haven-commons validate schema
swift run haven-commons validate purposes --namespace <namespace>
swift test --filter HavenCommonsTests
```

## Legge til nye keypaths
1. Oppdater `commons/keypaths/<namespace>/keypaths.json` med nye `KeyPathSpec`.
2. Oppdater `routes.json` ved ny prefix-routing til cell-type.
3. Kjør:
```bash
swift run haven-commons lint keypaths
swift run haven-commons resolve keypath --entity entity-1 --path '#/din/path' --role member
```
