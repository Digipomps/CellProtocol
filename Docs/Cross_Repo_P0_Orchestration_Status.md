# Cross-Repo P0 Orchestration Status

Denne noten er resultatet av orkestreringsprompten i:

- `commons/prompts/codex_cross_repo_p0_orchestrator_prompt.md`

Maalet er aa gi en faktisk cross-repo status for `CellProtocol`,
`CellScaffold` og `Binding` etter P0 utility-cell-tranchen, med tydelige
handoffs, blokkere og sentrale kontraktsbeslutninger.

## Kort koordinasjonssammendrag

Status akkurat naa:

- `CellProtocol` ser ut til aa vaere klart som felles kontraktgrunnlag for
  admission og katalog.
- `CellScaffold` ser ut til aa vaere klart som scaffold-lag for kontrollplan,
  parity-fixtures og additive notification-seams.
- `Binding` har kommet langt i typed admission, cache og host-seams, men er
  fortsatt det repoet som bestemmer om trancheringen faktisk blir superstabil.

Det viktigste bildet er:

- `CellProtocol` eier felles kontraktsannhet og diagnoseprimitiver.
- `CellScaffold` eier scaffold truth som `Binding` skal konsumere.
- `Binding` maa fortsatt bevise at den konsumerer denne sannheten robust, uten
  lokale omskrivinger og uten aa bli hengende igjen paa actor-isolation-gjeld.

## Faktisk verifisering i denne gjennomgangen

### `CellProtocol`

Kjoert:

- `swift test --filter AdmissionAndCatalogContractModelsTests`

Resultat:

- groen

Det bekrefter at:

- dagens `connect.challenge` payload fortsatt dekodes til
  `AdmissionChallengePayload`
- denied-varianten fortsatt dekodes riktig
- `AdmissionRetryRequest` roundtripper
- katalogkontraktene roundtripper og normaliserer deterministisk

### `CellScaffold`

Kjoert:

- `swift test --filter ScaffoldSetupCellTests`
- `swift test --filter ScaffoldNotificationContractsTests`

Resultat:

- begge groene

Det bekrefter at:

- `ScaffoldSetupCell` holder bootstrap, same-entity linking og role-grant
  grensen adskilt i testene som naa finnes
- notification-seamene roundtripper og normaliserer som forventet

### `Binding`

Kjoert:

- `xcodebuild -project /Users/kjetil/Build/Digipomps/HAVEN/Binding/Binding.xcodeproj -scheme Binding -destination 'platform=macOS' -derivedDataPath /tmp/BindingDD test -only-testing:BindingTests/CatalogAbsorbXCTest/testPortholeAbsorbsConfigurationCatalogAsCatalogLabel`

Observasjon:

- builden fullfores og testcaset starter
- i observasjonsvinduet mitt fullfoerte ikke testen, saa jeg kan ikke lokalt
  bekrefte groen status paa selve caset i denne runden
- `Binding` viser fortsatt mange Swift-6-relevante actor warnings i baade
  appkode og testkode

I tillegg sier repoets egen implementasjonsnote:

- `CatalogAbsorbXCTest` skal vaere fikset
- parity er delvis groen, men ikke hard gate ennå
- concurrency-opprydding er fortsatt ikke helt i mal

## Anbefalt kjorerekkefolge videre

1. Hold `CellProtocol` frosset som kontraktgrunnlag for admission og katalog.
2. La `CellScaffold` vaere kilden til parity-fixtures og kontrollplan-semantikk.
3. La `Binding` fullfore stabiliseringspasset sitt mot disse flatene.
4. Kjor parity og kompatibilitetsverifikasjon pa tvers etter at `Binding` er
   ryddet ferdig.

Hvorfor:

- `Binding` skal konsumere scaffold truth, ikke finne den opp
- `CellScaffold` skal konsumere protokollkontrakter, ikke definere egne
- `CellProtocol` skal vaere det laveste og mest stabile laget

## Hva hvert repo eier etter denne trancheringen

### `CellProtocol` eier

- `AdmissionChallengePayload`, `AdmissionRetryRequest`, `AdmissionSession`
- `ConfigurationCatalogEntryContract` og tilhorende query/facet-typer
- `FlowProbeCell` og `StateSnapshotCell`
- kontraktdokumentasjon og kompatibilitetstester

`CellScaffold` bygger naa paa dette ved aa anta at:

- admission-shape er additivt stabil
- katalogkontraktene er delte og host-agnostiske
- helper/remediation ikke faar authority

### `CellScaffold` eier

- kontrollplan for bootstrap, same-entity linking og role-grant-grense
- scaffold-eide parity-fixtures
- additive scaffold-seams for notifications
- additive `catalogContracts` over delte katalogtyper

`Binding` bygger naa paa dette ved aa anta at:

- parity-fixture endpoints og payloads er stabile
- same-entity link-state er tydelig modellert og varig
- conference-spesifikke flater fortsatt er tydelig avgrenset

### `Binding` eier

- typed konsum av admission-kontraktene
- portable cache og resume behavior
- native host-intake for deep-link / QR / local review
- den siste robusthetsgaten for om portable scaffold surfaces faktisk oppleves
  stabile i klienten

## Blokkerte eller delvis blokkerte handoffs

### Ingen tydelig blokk fra `CellProtocol` til `CellScaffold`

Kontrakt- og kataloggrunnlaget ser klart nok ut til at `CellScaffold` kan
jobbe videre uten aa finne opp lokale payload-shapes.

### Ingen tydelig blokk fra `CellScaffold` til `Binding`

`CellScaffold` ser ut til aa ha levert:

- tydeligere `ScaffoldSetupCell`
- scaffold-eide parity-fixtures
- scaffold notification contracts
- additive shared-contract adoption

Dette ser tilstrekkelig ut som handoff til `Binding`.

### Delvis blokk i `Binding` mot sluttgate

Dette er den reelle blokken akkurat naa:

- actor-isolation / Swift-6 warnings er fortsatt mange og konkrete
- parity er ikke bekreftet som hard gate
- den viktigste katalog-absorberingstesten ble ikke lokalt bekreftet ferdig i
  denne runden, selv om repoets egen note sier at den er fikset

Det betyr:

- trancheringen kan ikke kalles fullt stabil paa tvers foer `Binding` har
  bekreftet disse gatene med fullfoert testkjoring

## Kontraktsbeslutninger som maa holdes sentralt i `CellProtocol`

Dette maa fortsatt eies sentralt i `CellProtocol`, ikke i host-lagene:

- den delte shape-en for `connect.challenge`
- hva `sessionId`, `session`, helper-konfigurasjon og retry faktisk betyr
- den delte shape-en for katalogentry, query og facet-respons
- regelen om at helper/remediation er veiviser, ikke authority
- regelen om at cache og host-transport aldri skal redefinere remote truth

Hvis noe av dette maa endres, maa det skje her foerst:

- docs
- kontrakttester
- additive modeller

Foerst deretter skal `CellScaffold` og `Binding` adoptere endringen.

## Gjenstaende uklarhet som boer lukkes foer neste tranche

Det er tre ting som fortsatt boer lukkes sentralt:

1. Om parity i `Binding` skal regnes som hard gate allerede naa, eller om
   bridge-backed staging-fixtures fortsatt er for skjore til det.
2. Om de nye typed/cache-seamene i `Binding` skal flyttes ut av
   main-actor-default ved arkitektur, eller bare ryddes lokalt innenfor dagens
   target.
3. Om videre query/facet-migrasjon i katalogen skal tas i `CellScaffold`
   foerst, eller om det boer fa en egen additiv kontraktrunde i `CellProtocol`
   foer hostene bygger videre.

## Operativ slutning

Cross-repo-tranchen er naermest klar, men ikke helt lukket.

Det riktige neste trekket er:

- la `CellProtocol` staa stille som delt kontraktgrunnlag
- la `CellScaffold` beholdes som leverandor av scaffold truth
- la `Binding` fullfore stabilitetsarbeidet sitt og bevise:
  - groen katalog-absorbering
  - ryddet actor-isolation i de nye seamene
  - parity som faktisk verifikasjon, ikke bare notat

Foerst naar det er bekreftet, er denne P0-trancheringen virkelig koordinert og
stabil paa tvers av alle tre repoene.
