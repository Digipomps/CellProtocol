# Testing

## Kjør tester
```bash
cd /Users/kjetil/Build/Digipomps/HAVEN/CellProtocol
swift test --filter HavenCommonsTests
```

## Testdekning i MVP

### KeyPath routing
- `#/chronicle/events` rutes til `ChronicleCell`
- alias/deprecation `#/purposes -> #/perspective`
- kryss-celle resolution gjennom `EntityAnchorBinding`
- uregistrert path (f.eks. `#/custom/...`) resolves som åpen referanse uten feil

### Permissions
- sponsor får kun `aggregated` paths
- `consent` krever token for `member`

### Taxonomy inheritance
- term fra `haven.core` løses via `haven.conference` namespace
- conference-spesifikke term løses fra extension-pakken
- SDG-spesifikke term løses fra `haven.sdg`
- deprecated term har `replaced_by`
- guidance arves fra `haven.core` (root purpose + contribution purpose + goal policy)
- purpose-tree policy valideres:
  - mandatory inherited purposes finnes
  - mandatory purposes har minst ett linked goal
  - purpose som går på tvers av mandatory via forbudt relasjon feiler
  - purpose uten arvebane til mandatory feiler
  - `haven.sdg` kan vaere gyldig med warnings fordi goal-policy er `encouraged`, ikke hard requirement, for alle ikke-mandatory purposes

### Cell wrappers (CellScaffold)
- `CommonsResolverCell` testes med enkeltoppslag + batch-datasett (30 keypath requests)
- `CommonsTaxonomyCell` testes med guidance + batch-datasett (20 term requests)
- helper-cell-eksempler valideres via fixture decode

### SDG pilot runtime templates
- `SDGPilotPurposeCatalog` tester at tre pilotdomener finnes
- hver pilot-purpose har konkret goal + tre helper cells
- helper bundles gjenbruker eksisterende Commons-, Vault- og atlas-celler

### SDG pilot perspective examples
- `commons/examples/perspectives/sdg-climate-mobility.json` dekoder som `PerspectiveDocument`
- `commons/examples/perspectives/sdg-local-child-participation.json` dekoder som `PerspectiveDocument`
- `commons/examples/perspectives/sdg-institutional-accountability.json` dekoder som `PerspectiveDocument`
- eksemplene inkluderer root-purpose guardrails i `pre.purposes`
- eksemplene binder hvert pilot-goal til riktig `purpose_id`, `metric`, `timeframe`, `data_source` og `evidence_rule`

## Hurtigsjekk (CLI)
```bash
./.build/debug/haven-commons lint keypaths
./.build/debug/haven-commons validate schema
./.build/debug/haven-commons validate purposes --namespace haven.core
./.build/debug/haven-commons validate purposes --namespace haven.sdg
swift test --filter PerspectiveSchemaTests/testSDGPilotPerspectiveExamplesDecode
```

## Kontraktbasert celle-testing

For implementert arkitektur og runtime-probe:

- standardisert kontraktmodell for `Explore`
- runtime probe-celle for å teste andre celler
- lint-regler for `Purpose` og `Goal`

se:

- `Docs/Cell_Contract_Testing_Architecture.md`
- `Docs/Observability_and_Runtime_Diagnostics.md`

Det som faktisk er implementert nå:

- reelle kontrakter for `CommonsResolverCell`, `CommonsTaxonomyCell`,
  `VaultCell` og `GraphIndexCell`
- `RealCellContractTests` for permissions og ugyldig input
- `ContractProbeCell` for runtime- og staging-probing av andre celler gjennom
  vanlig `CellProtocol`-API
- `ContractProbeVerificationRecord` som kombinerer kontraktkatalog og siste
  probe-resultat til ett JSON/Markdown-artifact for docs/RAG
- `exploreContractCatalog(requester:)` som eksporterer kontrakter som
  JSON/Markdown for dokumentasjon og RAG-indeksering

## Runtime probing med `ContractProbeCell`

Bruk `ContractProbeCell` når du vil verifisere en celle i et kjørende miljø og
ikke bare i `swift test`.

Praktisk sekvens:

1. sett `probe.target`
2. sett eventuelt `probe.contract`
3. sett `probe.run`
4. les `probe.lastReport` eller `probe.reports`
5. abonner på `flow(...)` hvis du vil ha løpende status

Viktige runtime keys:

- `probe.target`
- `probe.contract`
- `probe.run`
- `probe.status`
- `probe.target.current`
- `probe.contract.current`
- `probe.lastReport`
- `probe.reports`

Se full dokumentasjon i:

- `Docs/ContractProbeCell.md`

Når probe-resultater skal gjøres søkbare i dokumentasjons-RAG, push
`ContractProbeVerificationRecord` til:

- `POST /v1/cell/cases/{case_id}/contract-verification`
