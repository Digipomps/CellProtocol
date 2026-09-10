# Målerapport: CellProtocol runtimekapasitet, 10. september 2026

## Konklusjon

Denne rapporten inneholder to **enkeltrepetisjoner på to ulike maskiner**. Den første er en lokal før-integrasjonsbaseline. Den andre er en isolert GitHub Actions-måling av den integrerte runtime-revisjonen `ced03d4`, utført i release-modus og fullført med 14 resultater. Ingen av dem er en universell kapasitetsgrense eller et grunnlag for å oppgi antall brukere, celler eller meldinger et generelt system «tåler».

CI-resultatet viser konkrete knekkpunkter på en tildelt macOS-runner med tre aktive prosessorer: cell- og resolverarbeidslastene får ikke en meningsfull throughput-gevinst ved fire workere, mens p99 øker. Persistensveien, som den lokale prøven ikke rakk å validere, lykkes i CI for 100 operasjoner per punkt. Swift Concurrency/Instruments-trace er fortsatt ikke tatt; den lokale maskinen har bare 2,86 GiB ledig plass, og ingen videre lokal last, bygg eller profilering skal startes før disktrykket er avklart.

## Isolert CI-måling av integrert runtime

Den vellykkede [GitHub Actions-kjøringen](https://github.com/Digipomps/CellProtocol/actions/runs/34453379470) (`bounded synthetic runtime matrix`, 12 m 36 s totalt; selve release-matrisen 12 m 20 s) målte runtime-revisjon `ced03d403704f206dcdf83567989959812e49164`. Harnessen var commit `69f048f917a07680c544b026f166b9a1d9db4c07` i [PR 36](https://github.com/Digipomps/CellProtocol/pull/36), som står åpen og umerget.

Workflowen verifiserte før måling at runtime-revisjonen er ancestor av harness-committen, og at `Sources`, `Tests` og `Package.resolved` er uendret mellom dem. Dermed er dette en måling av den eksakte integrerte runtime-kilden, med bare benchmark-/CI-infrastruktur lagt oppå. Jobbens ene annotasjon er en GitHub-advarsel om at `actions/checkout@v4` flyttes fra Node 20 til Node 24; den er ikke et benchmark- eller testavvik.

| Felt | Faktisk CI-miljø |
| --- | --- |
| OS | macOS 26.6.2 (build 25G83) |
| Tildelte ressurser | 3 aktive prosessorer, 7 516 192 768 byte RAM (7 GiB) |
| Build | SwiftPM release, separat runner-temp-scratch, `--jobs 2` |
| Matrise | cell/resolver: 5 000 operasjoner; flow: 1 024; persistens: 100; concurrency 1, 2, 4; 60 s prosessgrense |
| Rådata | 14 `result.json`-filer, exit-status og systemkorrelasjon i Actions-jobbloggen |

`workerTasksCreated` under er harnessens konfigurerte arbeidsoppgaver, ikke det totale antallet Swift tasks eller OS-tråder. Latens er millisekunder. RSS er `getrusage` high-water. CPU-kapasitet er prosessens CPU-tid dividert med veggklokketid og kan derfor overstige 100 %.

### CI: autorisert cell set + get

| Workere | Gjennomstrømning ops/s | p50 | p95 | p99 | CPU-kapasitet | RSS |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1 009,31 | 0,896 | 1,672 | 2,298 | 103,16 % | 14,34 MiB |
| 2 | 987,95 | 1,921 | 2,605 | 3,654 | 150,77 % | 14,45 MiB |
| 4 | 991,89 | 3,857 | 4,890 | 6,161 | 160,90 % | 14,58 MiB |

På akkurat denne tre-prosessor-runneren økte arbeidstallet CPU-forbruk og hale-latens, men ikke throughput. Dette er et målt knekkpunkt for denne syntetiske lokale veien, ikke en global concurrency-anbefaling.

### CI: resolver-URL + autorisert set + get

| Workere | Gjennomstrømning ops/s | p50 | p95 | p99 | CPU-kapasitet | RSS |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 718,98 | 1,307 | 2,003 | 2,939 | 101,99 % | 14,72 MiB |
| 2 | 617,94 | 3,033 | 4,265 | 5,977 | 155,52 % | 14,88 MiB |
| 4 | 710,72 | 5,652 | 8,093 | 11,891 | 163,44 % | 14,95 MiB |

Resolverveien viser samme retning. Workloaden måler URL-splitting, endpointoppslag, autorisering og lokal `GeneralCell` set/get med en syntetisk eier. Den måler ikke signaturverifisering eller fjerntransport.

### CI: lokal flow med ende-til-ende-kvittering

| Workere | Gjennomstrømning ops/s | p50 | p95 | p99 | CPU-kapasitet | RSS |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 20 795,38 | 0,047 | 0,076 | 0,110 | 152,80 % | 14,88 MiB |
| 2 | 39 897,79 | 0,031 | 0,123 | 0,388 | 185,90 % | 14,89 MiB |
| 4 | 55 851,88 | 0,053 | 0,158 | 0,204 | 176,97 % | 14,98 MiB |

Flowserien har bare 1 024 observasjoner og varer bare titalls millisekunder, så den er for kort til å kalles en stabil kapasitetstest. Den viser en observerbar throughput-økning mot fire workere på denne runneren, men også høyere median- og p95-latens enn ved én worker. `PassthroughSubject.send` er fortsatt serialisert ved produsentinngangen; resultatet hevder ikke en multiwriter-Combine-kontrakt.

### CI: persistens og I/O

| Workere | Gjennomstrømning ops/s | p50 | p95 | p99 | CPU-kapasitet | RSS |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 326,25 | 2,524 | 5,828 | 10,309 | 82,38 % | 15,45 MiB |
| 2 | 466,64 | 3,969 | 8,492 | 9,264 | 88,39 % | 15,50 MiB |
| 4 | 579,43 | 6,191 | 10,527 | 14,457 | 90,84 % | 15,45 MiB |

Alle 300 persistensoperasjonene lyktes. Hver operasjon oppretter en syntetisk persistent `GeneralCell`, krypterer og atomisk skriver den, laster den gjennom `TypedCellUtility`, og kontrollerer runtime-overflaten. Driveren er actor-serialisert fordi det ikke finnes en publisert kontrakt for samtidig bruk av `TypedCellUtility`; høyere caller-concurrency viser derfor køtid, ikke godkjent multiwriter-sikkerhet. `getrusage` rapporterte 0 blokkinn- og blokkut-operasjoner i disse korte løpene, noe som er forenlig med cachet I/O og ikke beviser fravær av diskarbeid. `Data.write(.atomic)` er heller ikke en `fsync`- eller strømtapsdurabilitetsmåling.

### CI: idle og bevisst flow-overflow

Idle holdt én konfigurert `GeneralCell` og resolverregistrering i 5,332 s: 0,042 % CPU-kapasitet og 12,83 MiB RSS-high-water. Ingen applikasjonsoperasjoner ble utført.

I overflow-prøven ble 512 elementer sendt mot en consumer med 5 ms forsinkelse per element. Etter 3,124 s var ett element levert. Det bekrefter det forventede, avgrensede utfallet for `AsyncStream.bufferingOldest(256)`: abonnementet lukkes når en dropp oppstår. Dette er en fail-closed minnegrense, ikke produsent-propagert backpressure og ikke en throughput-score.

### CI-begrensninger

Dette er én kjøring per punkt på en delt, liten macOS-host. Den er ikke direkte sammenlignbar med den lokale M5-baselinen nedenfor, og inneholder verken nettverk, ekstern bridge, database, reell identitet/signaturverifisering, større runtime-state eller stabilitets-/soak-last. De systemomfattende overskriftene i `top`, samt `iostat` og `vm_stat`, er kun korrelasjonsdata. Den enkelte `top`-raden er derimot samlet med benchmarkprosessens PID og er prosessattribuert; de observerte OS-trådene for cell og resolver er spesifisert nedenfor. En GitHub CLI-rate-limit under observasjon av jobben påvirket kun lokal polling; den ferdige jobben ble deretter verifisert via GitHub-grensesnittet og ingen testfeil er knyttet til den hendelsen.

## Identitet og repeterbarhet

| Felt | Verdi |
| --- | --- |
| Runtime-revisjon | `cde2e0aa759704d46f15e5312262e34db4c9ad8c` (`cde2e0a`) |
| Kjøretid | 2026-09-10 07:27:46--07:28:31 UTC |
| Maskin | Apple M5, 10 logiske/10 fysiske CPU-er, 32 GiB RAM |
| OS / verktøykjede | macOS 26.5.1 (25F80), Xcode 26.3 (17C519), Swift 6.2.4 |
| Build | SwiftPM release, separat scratch-path, `--jobs 2` |
| Matrise | idle 5 s; cell/resolver 3 000 operasjoner; flow 512; concurrency 1, 2, 4, 8; prosessgrense 60 s |
| Rådata | `/private/tmp/CellProtocol-runtime-capacity-cde2e0a-20260910T0729Z` |

PR 35-sikkerhetsendringene (`fbc856ff00e210848ca48276633ffbdb31763a6a`, kilde `f1036dcf422f7834cd896d7231407d269b422b3f`) var ikke ancestor av `cde2e0a` da den lokale matrisen startet. Den integrerte `main`-revisjonen `ced03d403704f206dcdf83567989959812e49164` (`ced03d4`) er nå målt isolert i CI, som beskrevet over. De lokale tallene under er fortsatt ikke bevis på den integrerte revisjonen.

`ced03d4` oppgraderer Swift Crypto, SwiftNIO, NIO SSL og NIO HTTP/2 samt `Package.resolved`. Den eksisterende lokale benchmark-scratchen er bygd mot de gamle avhengighetene. Med 2,85 GiB ledig plass kan en lokal "inkrementell" sluttbygging dermed hente og kompilere nye avhengigheter; den kan ikke holdes innenfor en dokumenterbar liten plassgrense. Den lokale sluttmålingen er eksplisitt plassblokkert, ikke hoppet over; CI-resultatet erstatter den ikke som lokal maskinbaseline.

## Validerte kjøringer

Alle tabelltall under kommer fra `result.json`, har exit-status 0 og akkurat forventet antall vellykkede operasjoner. Latens er mikrosekunder; RSS er prosessens `getrusage`-high-water etter oppsett og last; CPU-kapasitet er prosessens CPU-tid dividert med veggklokketid.

### Idle

| Tid | CPU-kapasitet | RSS-high-water | OS-tråder observert |
| ---: | ---: | ---: | ---: |
| 5,152 s | 0,01 % | 13,23 MiB | 4 i `top` |

Dette er bare baseline for den konfigurerte lokale prosessen med én `GeneralCell` og resolverregistrering. Det dekker ikke server, nettverk eller produksjonslagring.

### Autorisert cell set + get

| Workere | Throughput ops/s | p50 | p95 | p99 | CPU-kapasitet | RSS |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1 983,69 | 459,29 | 717,33 | 947,58 | 99,71 % | 14,45 MiB |
| 2 | **3 344,80** | 527,13 | 944,58 | 1 110,63 | 186,16 % | 14,63 MiB |
| 4 | 2 958,73 | 1 182,50 | 2 035,88 | 2 285,21 | 185,66 % | 14,67 MiB |
| 8 | 2 598,24 | 3 201,75 | 4 206,71 | 4 480,38 | 190,56 % | 14,95 MiB |

I denne veien var to samtidige worker-tasker raskest. Ved fire og åtte var CPU-kapasiteten fortsatt omtrent to kjerner, men kø-/kontensjonslatensen vokste klart. Dette er en lokal knekkindikasjon, ikke en rett til å sette en global concurrency-grense.

### Resolver-URL + autorisert set + get

| Workere | Throughput ops/s | p50 | p95 | p99 | CPU-kapasitet | RSS |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1 251,96 | 714,21 | 1 260,21 | 1 770,08 | 98,96 % | 14,73 MiB |
| 2 | 1 845,33 | 994,00 | 1 661,21 | 1 911,96 | 177,31 % | 14,91 MiB |
| 4 | **2 024,95** | 1 797,54 | 2 908,96 | 3 322,96 | 188,92 % | 15,00 MiB |
| 8 | 1 957,68 | 3 755,38 | 5 729,29 | 6 257,17 | 190,99 % | 15,22 MiB |

Resolverveien har samme mønster: vesentlig høyere p99 ved åtte enn ved én worker, uten tilsvarende throughput-gevinst.

### Lokal flow med ende-til-ende-kvittering

| Workere | Throughput ops/s | p50 | p95 | p99 | CPU-kapasitet | RSS |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | **109 756,42** | 7,33 | 15,00 | 21,96 | 182,28 % | 14,69 MiB |
| 2 | 95 768,06 | 13,13 | 44,04 | 57,63 | 191,31 % | 14,88 MiB |
| 4 | 87 229,35 | 38,38 | 81,00 | 111,38 | 208,28 % | 14,98 MiB |
| 8 | 86 942,38 | 70,79 | 146,96 | 237,83 | 203,74 % | 15,11 MiB |

Flow-arbeidslasten bruker bare 512 elementer og er derfor for kort til å bli tolket som en stabil kapasitetstest. Likevel er retningen konsistent: høyere konfigurert samtidighet ga ikke høyere throughput, men høyere hale-latens. Runneren serialiserer `PassthroughSubject.send`; den måler ikke en påstått støttet multiwriter-Combine-kontrakt.

### Bevisst flow-overflow

512 elementer ble sendt til en consumer som forsinker hvert element 5 ms. Etter 3,080 s var 1 element levert. Observasjonen stemmer med dagens `AsyncStream.bufferingOldest(256)`-oppførsel: når en dropp oppstår, lukkes abonnementet. Dette er en begrenset, fail-closed kø; det er ikke produsent-propagert backpressure og ikke en throughput-score.

## Ikke-validerte deler og avvik

### Persistens og I/O

Alle fire lokale persistensløp (`c1`, `c2`, `c4`, `c8`, 100 operasjoner) returnerte exit-status 1 før måling. `CellStoragePathPolicy` vurderte benchmarkroten som `/tmp/...` etter symlink-resolusjon, mens et ikke-eksisterende barn fortsatt var skrevet som `/private/tmp/...`; da ble barnet korrekt avvist som utenfor rot. Dette er et konkret funksjonsfunn for harnessen/rotvalget, ikke en ytelsesverdi.

Harnessen oppretter nå den forespurte lagringsroten før den kanonikaliserer den, slik at rot og barn blir i samme navnerom. Den korrigerte veien er bygget og funksjonelt validert i CI-resultatet over, men ikke på den plasspressede lokale maskinen. Ingen lokal I/O-kapasitet, `fsync`-durabilitet eller persistenskonkurranse kan derfor rapporteres. `getrusage` viste null prosessattribuerte blokk-I/O-operasjoner også i de korte CI-persistensløpene; det sier ikke noe om cachet persistens-I/O.

### Swift tasks kontra OS-tråder

`workerTasksCreated` og `peakConfiguredInFlightTasks` i JSON beskriver bare harnessens 1/2/4/8 worker-tasker. De er ikke runtimeens samlede Swift-tasker. I den eldre lokale M5-baselinen rakk `top` bare å sample idle-tilfellet robust (4 OS-tråder); de korte CPU/flow-prosessene der mangler ofte et helt intervallsample.

Den integrerte CI-kjøringen har lengre cell- og resolver-serier. Harnessen kjørte `top -l 0 -s 1 -pid <benchmark-PID>` for hver separat benchmarkprosess, så hver `#TH`-rad nedenfor er tilskrevet prosessen for den angitte arbeidslasten. Formatet er `totalt/kjørende` OS-tråder. Verdiene er minimum--maksimum blant de innsamlede radene, ikke harnessens worker-tasks og ikke et løfte om at en kortvarig tråd mellom énsekundsprøvene ikke fantes.

| CI-arbeidslast | Workere | `top`-prøver | `#TH` totalt, observert min--maks | `#TH` kjørende, observert min--maks |
| --- | ---: | ---: | ---: | ---: |
| cell | 1 | 5 | 4--4 | 1--2 |
| cell | 2 | 5 | 4--4 | 1--3 |
| cell | 4 | 5 | 4--5 | 1--3 |
| resolver | 1 | 7 | 4--4 | 1--2 |
| resolver | 2 | 8 | 4--5 | 2--3 |
| resolver | 4 | 7 | 4--5 | 1--3 |

`top` startet etter at prosessen var opprettet og dekker hele prosesslevetiden, mens `wallSeconds` i `result.json` dekker harnessens målte execute-del. Prøvetallet og `top`-tid er derfor ikke identisk med den rapporterte målte veggklokketiden. Dette er prosessens OS-tråder, ikke hele vertens trådtall og fortsatt ikke runtimeens samlede Swift-tasker.

Den medfølgende `Scripts/record-runtime-swift-tasks-trace.sh` skal kjøres etter en normal baseline med Instruments' *Swift Concurrency*-template. Da leses `Running Tasks`, `Alive Tasks`, `Total Tasks` og Task Forest separat fra `top`-trådtallet. Tracen ble utsatt før den startet, fordi Instruments kan skrive vesentlig profilmateriale når disken er kritisk full.

### Støy og statistikk

Det var samtidig maskinaktivitet: `top` under idle viste load average 4,92, 7,15 og 9,20 og bare rundt 57--71 % system-idle. Det finnes bare én repetisjon per punkt og ingen tilfeldig rekkefølge eller konfidensintervall. Tallene brukes derfor som regresjonsbaseline og hypoteser for videre profilering, ikke som publiserbar absolutt kapasitet.

## Ressursstatus og trygg videreføring

En metadata-only inventering var komplett uten feil. Datavolumet hadde 3 069 136 896 byte (2,86 GiB; 0,309 %) ledig, mot prosedyrets minimumsbuffer på 40 GiB. Mine isolerte, aktuelle artefakter eies av `kjetil`:

| Eksakt sti | Allokert størrelse | Status |
| --- | ---: | --- |
| `/private/tmp/CellProtocol-runtime-capacity-build` | 1 471 706 925 byte (1,37 GiB) | Regenererbar SwiftPM-scratch, men inneholder også checkouts/repositories og er ikke vurdert som slettbar som helhet |
| `/private/tmp/CellProtocol-runtime-capacity-cde2e0a-20260910T0729Z` | 508 384 byte | Verifiserbar rådata; bevares |
| `/private/tmp/CellProtocol-runtime-capacity-cde2e0a-20260910T0727Z` | 41 568 byte | Avbrutt kjøring; bevares inntil en uttrykkelig, avgrenset oppryddingsplan finnes |

Det er ikke utført opprydding. Eventuell frigjøring krever en separat allowlisted dry-run-plan og en ny, eksakt autorisasjonstoken fra brukeren.

## Neste avgrensede måling, først når maskinen er klar

1. Bruk `ced03d403704f206dcdf83567989959812e49164` (eller en senere eksplisitt valgt `main`-SHA) og minst 40 GiB ledig plass.
2. Bygg harnessen med den korrigerte persistensroten, release/`--jobs 2`.
3. Kjør idle og de korte cell/resolver/flow-seriene minst tre ganger i tilfeldig rekkefølge; behold alle rådata.
4. Valider persistens først med liten mengde. Øk bare mot en forhåndsdefinert I/O-stoppgrense og korreler prosessens `getrusage` med systemdata fra `iostat`/`vm_stat`; ikke kall systemtall prosess-I/O.
5. Ta én avgrenset Swift Concurrency-trace på en arbeidslast som allerede er reprodusert uten Instruments. Sammenlign tasks og OS-tråder, ikke erstatt det ene med det andre.
6. Stopp ved timeout, manglende funksjonell kvittering, vedvarende RSS-vekst, tydelig p99-knekk eller før maskinen nærmer seg diskterskelen.

Se [RuntimeCapacityBenchmarking.md](RuntimeCapacityBenchmarking.md) for arbeidslastdefinisjoner, rådataformat, stoppregler og primærkilder.
