# Entity Atlas Phase 1

## Formaal
Phase 1 innforer en ren service/projeksjon i `CellBase` som bygger et forklarbart atlas over faktisk celle-topologi, scaffold-konfigurasjoner og typed Vault-dokumenter.

Atlaset er ikke en egen sannhetsmotor. Det er en deterministisk projeksjon over:
- `CellResolver`-registreringer og aktive instanser
- `CellUsageScope`
- `CellConfiguration` og `CellConfigurationDiscovery`
- `ExploreContract`
- eksplisitte `EntityAtlasDescribing`-deskriptorer
- typed Vault-dokumenter for prompts, context, provider-profiler, assistant-profiler og credential handles

## Scope
Phase 1 dekker:
- cells og kontrollstatus
- scaffold-kandidater
- purpose/capability/dependency-visning
- credential handle-metadata
- provider- og assistant-profiler
- prompt/context-dokumenter
- deterministisk prompt-resolusjon
- redigert JSON/Markdown-eksport for menneskelig inspeksjon
- en tynn query-cell (`cell:///EntityAtlas`) som wrapper projeksjonen uten egen lagret sannhet

Phase 1 dekker ikke:
- full atlas-aware relasjonslaering
- automatisk inferens av purpose eller knowledge-roller uten eksplisitt metadata
- sync av raw secrets

## Invarianter
- Atlas bygges uten AI.
- Resolver-registrering er lavere tillit enn runtime-observasjon.
- `runtimeAttached` og `persistedAttachment` holdes separate; `absorbed` er `runtimeAttached || persistedAttachment`.
- Rå secrets skal aldri inn i `ValueType`, `FlowElement`, `VaultNoteRecord.content` eller generic dokumentlagring.
- Prompt-resolusjon skal gi samme resultat ved samme input.

## Byggeinput
`EntityAtlasProjectionContext` tar inn:
- `resolver`
- `requester`
- `scaffoldConfigurations`
- `documents` (`AtlasVaultDocumentSnapshot`)

## Query-modell
`EntityAtlasProjection` eksponerer blant annet:
- `build(context:)`
- `cells(forPurpose:in:)`
- `purposes(forCellID:in:)`
- `cellsRequiringCredentials(in:)`
- `scaffoldCandidates(forPurpose:in:)`
- `cellsKnowingAboutOtherCells(in:)`
- `dependencies(forCellID:in:)`
- `explainCoverage(for:in:)`

`EntityAtlasService` legger pa:
- `buildSnapshot(...)`
- `exportRedactedJSON(snapshot:policy:)`
- `exportRedactedMarkdown(snapshot:policy:)`

`EntityAtlasInspectorCell` eksponerer dette som cell-kontrakt via:
- `atlas.snapshot`
- `atlas.export.redactedJSON`
- `atlas.export.redactedMarkdown`
- `atlas.query.*`

## Determinisme
Snapshoten sorterer cells, scaffolds, dokumenter og relasjoner. Tidsstempelet `generatedAtEpochMs` varierer mellom bygg, men de strukturelle delene skal være like for samme input.

## Redigert eksport
Default eksport skjuler dokumentkropper og eksporterer bare metadata, referanser og kontrollstatus. Dokument-preview maa slas pa eksplisitt via `EntityAtlasExportPolicy`.

## Neste fase
Neste fase bor utvide atlaset med:
- flere eksplisitte cell descriptors i faktiske celler
- mer presis scaffold discovery
- atlas-aware læring med egne edge-typer og tillitsnivaa
