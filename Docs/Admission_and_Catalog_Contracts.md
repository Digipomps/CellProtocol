# Admission And Catalog Contracts

Dette dokumentet beskriver to additive kontraktspor i `CellProtocol`:

1. typed admission-/challenge-modeller
2. typed katalog-/discovery-modeller

Målet er ikke å endre eksisterende runtime-oppførsel i ett stort løft. Målet er
å etablere et felles kontraktslag som `CellProtocol`, `CellScaffold` og
`Binding` kan konvergere mot uten å knekke dagens flyter.

## Hvorfor dette finnes

To flater har begynt å bli tydelige nok til å fortjene egne delte modeller:

- `connect.challenge` / admission-retry
- `ConfigurationCatalog` / query / facets / metadata

Begge finnes allerede i praksis, men har hittil vært representert gjennom mer
ad hoc objekter og host-spesifikke modeller.

Ved å legge dem i `CellProtocol` får vi:

- én portabel sannhetskilde for payload-shape
- enklere testing og dokumentasjon
- mindre risiko for at `Binding` og `CellScaffold` driver fra hverandre

## Admission Contracts

Filer:

- `Sources/CellBase/Agreement/AdmissionSession.swift`
- `Sources/CellBase/Agreement/AdmissionContracts.swift`

### Hva som allerede var i runtime

`GeneralCell` emitter allerede `connect.challenge` med:

- `state`
- `connectState`
- `agreement`
- `context`
- `issues`
- `issueCount`
- `sessionId`
- `session`
- `reasonCode`
- `userMessage`
- `requiredAction`
- `canAutoResolve`
- `helperCellConfiguration`
- `developerHint`

### Payload mapping

Dette er den eksplisitte mappingen mellom dagens runtime-payload og de nye
modellene:

- top-level `state` -> `AdmissionChallengePayload.state`
- top-level `connectState` -> `AdmissionChallengePayload.connectState`
- top-level `agreement` -> `AdmissionChallengePayload.agreement`
- top-level `context` -> `AdmissionChallengePayload.context`
- top-level `issues` -> `[AdmissionChallengeIssueRecord]`
- top-level `issueCount` -> `AdmissionChallengePayload.issueCount`
- top-level `sessionId` -> `AdmissionChallengePayload.sessionId`
- top-level `session` -> `AdmissionChallengePayload.session`
- top-level `reasonCode` -> primary issue mirror on `AdmissionChallengePayload`
- top-level `userMessage` -> primary issue mirror on `AdmissionChallengePayload`
- top-level `requiredAction` -> primary issue mirror on `AdmissionChallengePayload`
- top-level `canAutoResolve` -> primary issue mirror on `AdmissionChallengePayload`
- top-level `helperCellConfiguration` -> primary issue mirror on
  `AdmissionChallengePayload`
- top-level `developerHint` -> primary issue mirror on
  `AdmissionChallengePayload`

Mirror-feltene på top-level finnes fordi dagens runtime eksponerer primary issue
to steder:

- som første element i `issues`
- som convenience-felter på root-objektet

Det nye typed laget bevarer denne virkeligheten i stedet for å forsøke å rydde
den bort i samme endring.

Det nye her er ikke en runtime-endring, men en typed modell som kan decode den
payloaden eksplisitt:

- `AdmissionChallengePayload`
- `AdmissionChallengeIssueRecord`
- `AdmissionRetryRequest`

### Viktige invariants

- `connect.challenge` er fortsatt runtime-kilden for admission-problemer.
- Ingen helper får authority; de peker bare til remediering.
- `AdmissionChallengePayload` beskriver payloaden, men endrer ikke
  `GeneralCell`-flyten.
- `AdmissionRetryRequest` er en portabel request-form, ikke en garanti for at
  alle hosts allerede bruker den.
- `AdmissionChallengeIssueRecord` er bevisst `Codable`, ikke `Hashable`,
  fordi `helperCellConfiguration` fortsatt er en transportstruktur uten stabil
  hash-/equatable-semantikk.

### Hvorfor dette er viktig

Dette lar oss senere:

- la `Binding` decode challenge payloads eksplisitt i stedet for å håndparse
  `Object`
- la `CellScaffold` bygge workbench-/helper-flyt mot samme kontrakt
- skrive stabil dokumentasjon og testfixturer rundt admission

## Catalog Contracts

Fil:

- `Sources/CellBase/ConfigurationCatalog/ConfigurationCatalogContracts.swift`

### Hva som standardiseres

Det nye delte kataloglaget beskriver:

- entry metadata
- IO-signatur
- insertion modes
- query request
- query response
- facet count request/response

Nye sentrale typer:

- `ConfigurationCatalogEntryContract`
- `ConfigurationCatalogIOSignature`
- `ConfigurationCatalogInsertionMode`
- `ConfigurationCatalogQueryRequest`
- `ConfigurationCatalogQueryMatch`
- `ConfigurationCatalogQueryResponse`
- `ConfigurationCatalogFacetCountsRequest`
- `ConfigurationCatalogFacetBucket`
- `ConfigurationCatalogFacetCountsResponse`

### Designvalg

Disse modellene er bevisst:

- additive
- host-agnostiske
- normaliserende

Normalisering betyr blant annet:

- trimmede strenger
- de-dupliserte lister
- sorterte metadatafelt der rekkefølge ikke er semantisk viktig
- clamp av `limit` og `offset`

Dette gir mer deterministiske snapshots og bedre testbarhet.

### Feltgrupper i katalogkontrakten

For å gjøre migrasjon enklere er katalogfeltene ment å leses i fire grupper:

- identitet og opphav
  - `id`, `sourceCellEndpoint`, `sourceCellName`
- semantikk og presentasjon
  - `purpose`, `purposeDescription`, `displayName`, `summary`
  - `purposeRefs`, `interestRefs`, `categoryPath`, `tags`, `menuSlots`
- operativ egnethet
  - `supportedInsertionModes`, `supportedTargetKinds`, `ioSignature`
  - `authRequired`, `flowDriven`, `editable`, `recommendedContexts`
- materialisering
  - `goal`, `configuration`, `updatedAtEpochMs`

Denne inndelingen er bare dokumentasjonsmessig, men den gjør det tydeligere hva
som bør kunne brukes til henholdsvis discovery, ranking, rendering og
instansiering.

### Hva som ikke standardiseres ennå

Dette dokumentet gjør ikke `ConfigurationCatalogCell` i `Binding` eller
`CellScaffold` automatisk identiske. Det etablerer bare en delt modell som de
kan migrere til.

Det betyr at følgende fortsatt er host-ansvar inntil videre:

- rankinglogikk
- facet-beregning
- hvilke katalogentrys som publiseres
- hvordan katalogen mappes til produktspesifikke library-flater

## Migrasjonsretning

Anbefalt rekkefølge videre:

1. la hosts bruke de nye modellene internt uten å endre payload-shape utad
2. flytt query/facet response-shapes over til disse typene
3. bruk de samme modellene i docs, fixtures og parity-tester
4. først deretter vurder felles codec-/service-lag

## Teststrategi

Det bør finnes to typer tester:

1. kompatibilitetstester
   - dagens `connect.challenge` skal kunne decode til
     `AdmissionChallengePayload`
2. modelltester
   - katalogmodeller skal normalisere og roundtrippe deterministisk

Denne iterasjonen dekker begge deler.

Mer konkret verifiserer testene nå at:

- eksisterende `connect.challenge` med `state=unmet` dekodes til
  `AdmissionChallengePayload`
- eksisterende `connect.challenge` med `state=denied` dekodes til samme modell
- `AdmissionRetryRequest` roundtripper gjennom `ValueType`
- katalogentry/query/response normaliseres og roundtripper deterministisk

## Risiko og kompatibilitet

Denne endringen er laget for å være lavrisiko:

- ingen eksisterende runtime-flyt er omskrevet
- ingen eksisterende keys eller payload-felt er fjernet
- nye typer brukes først og fremst til decoding, dokumentasjon og senere
  migrasjon

Det betyr også at eventuell videre integrasjon i `Binding` og `CellScaffold`
kan gjøres gradvis og med tydelige rollback-punkter.
