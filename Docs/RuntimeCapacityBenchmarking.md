# CellProtocol runtimekapasitet: reproduserbar, avgrenset måling

Dette oppsettet måler ytelse på én definert maskin og revisjon. Det etablerer
ikke et generelt antall CellProtocol-brukere, celler, tråder eller meldinger som
systemet «tåler». Målingene gjelder bare syntetiske data, lokal prosess og de
konkrete runtime-veisystemene under.

## Formål og avgrensning

`CellRuntimeBenchmarks` er en release-bygget SwiftPM-executable. Den er laget
for å finne regresjoner og knekkpunkter før en konkret tjeneste eller demo
kjøres under realistisk ende-til-ende-last. Den åpner ingen nettforbindelser og
benytter ikke brukerdata, Keychain-verdier eller produksjonslagring.

Bygg og resultater holdes utenfor arbeidskopiens vanlige `.build`:

```sh
BENCHMARK_BUILD_JOBS=2 Scripts/run-runtime-capacity-benchmark.sh
```

Standardmatrisen er konservativ: én idle-baseline, så `1 2 4 8` workere for
cell, resolver, flow og persistens. Hvert delkjør har en prosess-stoppgrense på
60 sekunder. Følgende miljøvariabler endrer grensene eksplisitt:

- `BENCHMARK_LOAD_LEVELS` (standard `1 2 4 8`; aldri øk uten ledig maskin)
- `BENCHMARK_OPERATIONS` (standard `1000`)
- `BENCHMARK_FLOW_OPERATIONS` (standard `256`)
- `BENCHMARK_PERSISTENCE_OPERATIONS` (standard `80`)
- `BENCHMARK_MAX_WALL_SECONDS` (standard `60`)
- `BENCHMARK_OUTPUT_DIR` og `BENCHMARK_SCRATCH_DIR`

Wrapperen bygger med `--jobs 2` som standard og med en separat
`--scratch-path` under `/private/tmp`. Den starter ikke en vanlig `.build`-jobb
og skal ikke kjøres parallelt med CPU-tunge integrasjons-/Xcode-kjøringer uten
at operatøren bevisst velger det.

## Arbeidslaster

| Navn | Hver målt operasjon | Hva det belyser | Ikke dekket |
| --- | --- | --- | --- |
| `idle` | Holder en konfigurert `GeneralCell` og resolverregistrering uten arbeid | Prosessens runtime-baseline | Tjeneste-/nettverks-idle, faktisk brukerlast |
| `cell` | Autorisert `GeneralCell.set` etterfulgt av `get`, med registrerte intercepts | Cell-/intercept-/autoriseringsoverhead | Signaturverifisering, stor applikasjonsstate |
| `resolver` | Resolver-URL-splitting, endpointoppslag, autorisering, så samme set/get | Resolverens lokale vei | WebSocket, fjerntransport, database |
| `flow` | Lokal `FlowElementPusherCell` til `GeneralCell.attach/absorbFlow`, med ende-til-ende-kvittering | Flow-overføring og latenstid | Ubegrenset multiwriter-Combine-produksjon |
| `flow-overflow` | Bevisst treg flow-consumer mottar en burst | Den faktiske `AsyncStream.bufferingOldest(256)`-grensen og fail-closed respons | Produsent-propagert backpressure |
| `persistence` | Ny syntetisk persistent `GeneralCell`, kryptert atomisk write, `TypedCellUtility`-load og runtime-overflatekontroll | Lokal encode/kryptering/filsystem/load via den testede `CellVapor.FileSystemCellStorage`-adapteren | `fsync`-/strømtapsdurabilitet, stor state, en publisert multiskriverkontrakt |

Flowets normale benchmark låser selve `PassthroughSubject.send` på én
produsentinngang. Det er bevisst: denne runtimeflaten publiserer ikke en
multiwriter-kontrakt som dette verktøyet kan anta. Worker-taskene kan fortsatt
vente samtidig på den asynkrone consumer-veien. `flow-overflow` er særlig viktig
å tolke riktig: den begrensede køen stanser abonnementet når elementer droppes;
den bremser ikke automatisk produsenten. Det er en sikkerhets-/minnegrense, ikke
full backpressure til kilden.

Persistensdriveren er en actor fordi `TypedCellUtility` ikke dokumenterer
samtidig bruk. Økt caller-concurrency synliggjør derfor køtid og I/O-latenstid,
uten at benchmarken påstår at samtidige writes er en støttet API-egenskap.

## Rådata og målepunkter

Hver kjøring oppretter en egen katalog med:

- `result.json`: revisjon, konfigurasjon, throughput, p50/p95/p99/max,
  `getrusage`-delta (bruker-/system-CPU, RSS-high-water, kontekstskift,
  reelle blokkin-/ut-operasjoner og sidehendelser).
- `top.txt`: intervallbasert CPU samt OS-tråder (`th`, totalt/kjørende), RSS og
  virtuell størrelse for benchmarkprosessen.
- `iostat.txt` og `vm_stat.txt`: systemomfattende korrelasjonsdata for disk og
  virtuelt minne. De er ikke prosessattribuerte og må aldri tolkes alene som
  CellProtocol-I/O.
- `synthetic-storage/` for persistenskjøringer: kun genererte, krypterte test-
  celler under den aktuelle resultatkatalogen.

macOS `getrusage` angir `ru_maxrss` i byte og blokktellerne omfatter bare reell
I/O, ikke cache-treff. RSS i `top` er et punktutvalg; `ru_maxrss` er
prosessens high-water. CPU-kapasitet i `result.json` betyr
`(bruker + system-CPUtid) / veggklokketid`; den kan overstige 100 % når flere
kjerner utfører arbeid. Den er ikke hele maskinens CPU-prosent.

`workerTasksCreated` og `peakConfiguredInFlightTasks` teller bare runnerens
arbeider. De er ikke det samme som schedulerens totale Swift tasks. For en
faktisk runtime-observasjon brukes den separate Instruments-kjøringen:

```sh
Scripts/record-runtime-swift-tasks-trace.sh \
  /private/tmp/CellProtocol-runtime-trace \
  --workload flow --concurrency 4 --operations 1000 --revision "$(git rev-parse HEAD)"
```

`SwiftConcurrency.trace` og `trace-toc.xml` må leses i Instruments. Se
`Running Tasks`, `Alive Tasks`, `Total Tasks`, Task Forest og actor-/executor-
spor sammen med `top.txt`; ikke erstatt task-tall med OS-trådtall.

## Tolking og stoppregler

1. Kjør idle først og sammenlign alltid RSS/CPU med den før du tilskriver
   endring til en arbeidslast.
2. Øk bare ett concurrency-trinn om gangen. Stopp videre opptrapping når p99
   vokser uforholdsmessig, RSS fortsetter å vokse etter hvile, CPU-kapasitet
   ligger tett på praktisk maskinbudsjett, eller `flow-overflow` avviker fra
   forventet bounded/fail-closed atferd.
3. Ikke sammenlign CPU-, I/O- eller RSS-tall mellom ulike macOS-/Xcode-/Swift-
   versjoner uten å markere miljøet som endret. Resultatkatalogen inneholder
   `system.txt` og eksakt git-revisjon for dette formålet.
4. Kjør én Instruments-trace først etter at en uten-profileringsmåling har
   pekt på en konkret last. Instrumentering endrer kostnaden og erstatter ikke
   benchmarkens uten-profileringsbaseline.
5. Verifiser funksjonelt resultat før enhver ytelseskonklusjon: alle JSON-filer
   må ha exit-status 0 og forventet antall fullførte operasjoner. En timeout,
   ufullstendig JSON eller dropp utenfor overflow-arbeidslasten er et
   undersøkelsesfunn, ikke en kapasitetsscore.

## Metodisk grunnlag

- [Swift.org: Debugging Performance Issues](https://www.swift.org/documentation/server/guides/performance.html)
  anbefaler release-bygg før ytelsesmåling og å bruke profileringsverktøy for
  å finne årsak etter måling.
- [Swift.org: Benchmark Package](https://www.swift.org/blog/benchmarks/)
  beskriver latencyfordelinger, throughput, CPU, resident memory,
  kontekstskift og trådmålinger som relevante metrikker og skiller benchmark
  fra årsaksprofilering.
- [Apple: Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
  forklarer hvorfor Swift Concurrency/Dispatch bruker en enhetstilpasset
  worker-pool, og hvorfor mange egne tråder er skadelig.
- [Apple: Visualize and optimize Swift concurrency](https://developer.apple.com/videos/play/wwdc2022/110350/)
  dokumenterer Swift Tasks-instrumentets `Running`, `Alive` og `Total Tasks`
  samt Task Forest; det er grunnen til at task- og trådtall holdes atskilt.
- [Apple: xctrace](https://developer.apple.com/documentation/xcode-release-notes/xcode-12-release-notes)
  dokumenterer at `xctrace` erstatter den gamle `instruments`-kommandoen.
- [Swift Async Algorithms Channel guide](https://github.com/apple/swift-async-algorithms/blob/main/Sources/AsyncAlgorithms/AsyncAlgorithms.docc/Guides/Channel.md)
  illustrerer forskjellen mellom faktisk producer/consumer-backpressure og en
  ren buffergrense. CellProtocols flow-kø måles som det den er i dagens kode.

## Integrasjonsrevisjon og registrert baseline

Denne benchmarktargeten registrerer både harnessens faktiske git-SHA i
`run-configuration.txt` og runtime-SHA-en i hvert `result.json`. De er like
som standard. `BENCHMARK_RUNTIME_REVISION` kan bare brukes når en CI-jobb
verifiserer at runtime-SHA-en er ancestor av harness-SHA-en og at `Sources`,
`Tests` og `Package.resolved` er uendret mellom dem; dette skiller en liten
benchmark-harnesscommit fra runtimekilden den måler. Ved målingen 10.
september 2026 var arbeidskopiens `main` `cde2e0a`; den ventende
CellProtocol PR 35 (`fbc856ff00e210848ca48276633ffbdb31763a6a`, kilde
`f1036dcf422f7834cd896d7231407d269b422b3f`) var ikke ancestor av `main`.
Den senere integrerte revisjonen `ced03d403704f206dcdf83567989959812e49164`
er målt separat i isolert macOS CI etter denne verifikasjonen. Den lokale
maskinen har fortsatt ikke nok diskbuffer til å gjenta den med oppgraderte
SwiftPM-avhengigheter, så resultatkatalogene beholdes som separate
sammenligninger. Den faktiske kjøringen på `cde2e0a`, CI-kjøringen på `ced03d4`
og deres kvalifiserte begrensninger er dokumentert i
[RuntimeCapacityBenchmarkReport_2026-09-10.md](RuntimeCapacityBenchmarkReport_2026-09-10.md).
