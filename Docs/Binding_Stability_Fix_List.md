# Binding Stability Fix List

Denne listen er laget etter cross-repo-gjennomgang av `CellProtocol`,
`CellScaffold` og `Binding` etter P0 utility-cell-tranchen.

Målet er ikke bare å få `Binding` "til å fungere", men å gjøre den robust,
forutsigbar og superstabil som host for portable scaffold surfaces.

## Målbilde

`Binding` skal være:

- en stabil klient/host for scaffold-flater
- strikt i forhold til portabilitet og parity
- eksplisitt i forhold til admission, cache og link approval
- fri for skjøre fallback-mekanismer som skjuler drift

Det betyr at følgende egenskaper må holdes:

- remote scaffold truth skal konsumeres, ikke omskrives
- typed shared contracts skal brukes der de finnes
- regressjoner i attach/load/parity skal fanges i tester
- Swift concurrency warnings må ryddes før de blir Swift 6-feil

## P0: Må fikses først

### 1. Fiks `ConfigurationCatalog`-absorbering i Porthole

Status:

- `BindingTests/CatalogAbsorbXCTest` feiler når `cell:///ConfigurationCatalog`
  lastes inn i `Porthole`
- feilen er `denied`, ikke timeout eller decode-feil

Konsekvens:

- `Binding` kan ikke kalles superstabil når en grunnleggende scaffold-surface
  ikke kan attach-es deterministisk i test

Sannsynlige steder å undersøke:

- `BindingTests/CatalogAbsorbXCTest.swift`
- `BindingTests/BindingTests.swift` sin parallelle absorb-test
- `Binding/BootstrapView.swift` sin faktiske resolver-registrering
- `Binding/Cells/ConfigurationCatalogCell.swift`
- eventuell mismatch mellom `scaffoldUnique`, `identityDomain`, `persistency`
  og requester-identitet

Konkrete oppgaver:

- verifiser at testregistreringen er identisk med runtime-registreringen
- sammenlign `CatalogAbsorbXCTest` og den nyere absorb-testen i
  `BindingTests.swift`
- bekreft at `ConfigurationCatalogCell` kan leses gjennom `catalog.state` i
  attach-scenario, ikke bare i direkte celleoppslag
- bekreft at `Porthole` bruker riktig requester når referansen lastes
- undersøk om `ConfigurationCatalogCell` faktisk trenger ekstra eksplisitt
  grants for attach-scenariet eller om problemet ligger i resolver-scope

Akseptansekriterier:

- `CatalogAbsorbXCTest` er grønn
- parallell absorb-test i `BindingTests.swift` er grønn
- `catalog.state` returnerer objekt deterministisk etter attach
- ingen lokal workaround som skjuler admission/access-bug

### 2. Rydd actor-isolation i nye portable-surface seams

Status:

- `Binding` bygger, men produserer mange Swift-6-relevante warnings
- de mest direkte nye warningene kommer fra:
  - `Binding/PortableSurfaceSupport.swift`
  - deler av `Binding/BootstrapView.swift`

Konsekvens:

- dette er teknisk gjeld som lett blir ekte compiler-feil
- concurrency-feil i host-laget er særlig farlige fordi de ofte blir
  intermitterende og vanskelige å debugge

Konkrete oppgaver:

- fjern unødvendig `nonisolated` fra `BindingAdmissionChallengeSnapshot`
- gjør typed snapshot-seamene til rene value types uten skjulte actor-antagelser
- rydd alle nye warnings som gjelder:
  - actor-isolated property access
  - actor-isolated method calls
  - `@MainActor`-lekkasje inn i tester og hjelpefunksjoner
- unngå å løse dette med `nonisolated(unsafe)` med mindre det er helt nødvendig

Akseptansekriterier:

- ingen nye Swift-6 actor warnings i de nyinnførte utility-cell-filene
- `PortableSurfaceSupport.swift` er ren for warning-klassen som kom i denne
  trancheringen
- testkoden for admission/cache bruker riktig actor-kontekst

## P1: Må til for robusthet

### 3. Fullfør typed `connect.challenge`-adopsjon

Status:

- `BindingAdmissionChallengeSupport` og `BindingAdmissionChallengeSnapshot`
  finnes
- implementasjonsnoten sier eksplisitt at ikke alle konsumenter er flyttet

Konsekvens:

- blanding av typed decode og manuell `Object`-parsing er en klassisk kilde til
  drift og skjulte regressjoner

Konkrete oppgaver:

- finn alle resterende `connect.challenge`-parser i `Binding`
- bruk `AdmissionChallengePayload` som standard inngang
- behold fallback bare der eldre shape eller ufullstendig payload faktisk må
  støttes
- standardiser ett sted for:
  - session-id
  - helper-konfigurasjon
  - retry request
  - requiredAction
  - reasonCode

Akseptansekriterier:

- alle aktive `connect.challenge`-baner går gjennom samme typed decode-seam
- fallback-kode er eksplisitt og begrenset
- identity-link review, helper-open og retry-data viser samme sannhet

### 4. Hardn cache-seamen så den ikke glir over i lokal sannhet

Status:

- `PortableSurfaceCacheStore` er riktig i retning
- men cache i host-laget er alltid en potensiell kilde til stille drift

Konsekvens:

- hvis cache brukes for aggressivt, kan `Binding` vise gammel eller lokal sannhet
  uten at parity-bruddet blir synlig

Konkrete oppgaver:

- skill tydelig mellom:
  - live remote contract
  - cached remote contract
  - locally synthesized fallback
- legg til tester for at cached `CellConfiguration` ikke retargetes eller
  normaliseres destruktivt ved lagring
- legg til tester for at live remote svar prioriteres over cache
- legg til synlig metadata i debug/status for:
  - cache-hit
  - cache-age
  - fallback årsak

Akseptansekriterier:

- cache kan brukes for resilience uten å bli authoritativ
- det er mulig å se om en flate kommer fra live eller cache
- parity-feil skjules ikke av cache

### 5. Stabiliser same-entity link review/approval som host-flyt

Status:

- `Binding` viser typed admission- og helper-data i identity-link intake
- men notatet sier at full retry/approval ikke er fullført i host-laget

Konsekvens:

- identitetsflyter må være ekstra robuste; ellers blir onboarding og linking
  skjøre og vanskelige å stole på

Konkrete oppgaver:

- sørg for at deep-link og pasted payload havner i samme review-seam
- standardiser local review state mot typed admission data
- sørg for at helper-open, retry-data og approval-status ikke divergerer
- bekreft eksplisitt at transport ikke blir authority
- logg og presenter tydelig forskjellen på:
  - pending review
  - helper remediation available
  - retry available
  - approved elsewhere
  - denied

Akseptansekriterier:

- identity-link intake er deterministisk uansett entry path
- approval/review-status er lesbar og konsistent
- retry-data kommer fra delt session, ikke lokal gjetning

## P2: Må til for superstabil drift

### 6. Gjør parity-suiten til fast gate

Konkrete oppgaver:

- få `BindingTests/SkeletonParityRemoteXCTest.swift` inn i fast verifikasjon
- krev grønn parity før nye renderer-/fallback-endringer anses som ferdige
- hvis parity feiler:
  - fiks renderer eller kontrakt først
  - legg bare til ny fixture hvis en reell manglende kontrakt er identifisert

Akseptansekriterier:

- parity-suiten er kjørbar uten manuell improvisasjon
- resultatene brukes som sann gate, ikke bare som dokumentasjon

### 7. Stram inn testmatrisa rundt portable surfaces

Konkrete oppgaver:

- behold én kanonisk test for hver type problem:
  - absorb/load
  - typed admission decode
  - retry payload
  - cache roundtrip
  - parity fixture loading
- fjern eller konsolider overlappende tester som nå gjør samme jobb
- sørg for at testene speiler runtime-registreringen i `BootstrapView`

Akseptansekriterier:

- testene er mindre overlappende og lettere å stole på
- regressjoner blir lettere å lokalisere

### 8. Legg på diagnostikk for host-stabilitet

Konkrete oppgaver:

- eksponer enkel debug-status for:
  - live vs cache
  - challenge decode status
  - helper presence
  - resolver/load failures
- bruk eksisterende `FlowProbeCell` / `StateSnapshotCell` der det hjelper
- sørg for at parity-avvik og attach-feil gir forklarbare signaler

Akseptansekriterier:

- en attach/load/parity-feil kan forklares uten å grave tilfeldig i logg

## Anbefalt rekkefølge

1. `ConfigurationCatalog` absorb/regresjon
2. actor-isolation i nye seams
3. fullfør typed challenge-adopsjon
4. hardn cache og visible fallback-status
5. hardn same-entity review/approval-flyt
6. gjør parity til fast gate
7. konsolider testmatrise
8. legg på målrettet diagnostikk

## Minimum verifikasjon etter hver fix-runde

Kjør minst:

- `xcodebuild test -project Binding.xcodeproj -scheme Binding -destination 'platform=macOS' -only-testing:BindingTests/CatalogAbsorbXCTest`
- `xcodebuild test -project Binding.xcodeproj -scheme Binding -destination 'platform=macOS' -only-testing:BindingTests`

Kjør deretter parity:

- `BindingTests/SkeletonParityRemoteXCTest.swift`

Og vurder arbeidet som superstabilt først når:

- catalog absorb er grønn
- nye utility seams er fri for relevante Swift-6 actor warnings
- typed admission brukes konsistent
- cache ikke skjuler drift
- parity går grønt
