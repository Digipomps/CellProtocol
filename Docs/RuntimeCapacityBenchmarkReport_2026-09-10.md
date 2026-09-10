# Målerapport: CellProtocol runtimekapasitet, 10. september 2026

## Konklusjon

Dette er en **før-integrasjons, enkeltrepetisjonsmåling**, ikke en universell kapasitetsgrense. Den er en reproduserbar lokal baseline for CellProtocol-kjernen på én maskin. De syntetiske CPU-arbeidslastene slutter å gi bedre throughput etter 2--4 samtidige worker-tasker, mens p99-latenstiden fortsetter opp. Målingen kan ikke brukes til å oppgi antall brukere, celler eller meldinger et generelt system "tåler".

Persistensdelen er **ikke godkjent som resultat**: alle fire kjøringer stoppet før en operasjon ble målt på grunn av et macOS `/private/tmp`--`/tmp`-aliasproblem i benchmarkens midlertidige rot. I/O-grensen er dermed ikke funnet. Swift Concurrency/Instruments-tracen er heller ikke tatt, fordi volumet nå har bare 2,86 GiB ledig plass. Ingen videre last, bygg eller profilering skal startes før disktrykket er avklart.

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

PR 35-sikkerhetsendringene (`fbc856ff00e210848ca48276633ffbdb31763a6a`, kilde `f1036dcf422f7834cd896d7231407d269b422b3f`) var ikke ancestor av `cde2e0a` da matrisen startet. Den integrerte `main`-revisjonen er senere bekreftet som `ced03d403704f206dcdf83567989959812e49164` (`ced03d4`), men er ikke benchmarket. Resultatene er derfor ikke bevis på den integrerte revisjonen.

`ced03d4` oppgraderer Swift Crypto, SwiftNIO, NIO SSL og NIO HTTP/2 samt `Package.resolved`. Den eksisterende benchmark-scratchen er bygd mot de gamle avhengighetene. Med 2,85 GiB ledig plass kan en "inkrementell" sluttbygging dermed hente og kompilere nye avhengigheter; den kan ikke holdes innenfor en dokumenterbar liten plassgrense. Sluttmålingen er eksplisitt plassblokkert, ikke hoppet over.

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

Alle fire persistensløp (`c1`, `c2`, `c4`, `c8`, 100 operasjoner) returnerte exit-status 1 før måling. `CellStoragePathPolicy` vurderte benchmarkroten som `/tmp/...` etter symlink-resolusjon, mens et ikke-eksisterende barn fortsatt var skrevet som `/private/tmp/...`; da ble barnet korrekt avvist som utenfor rot. Dette er et konkret funksjonsfunn for harnessen/rotvalget, ikke en ytelsesverdi.

Harnessen oppretter nå den forespurte lagringsroten før den kanonikaliserer den, slik at rot og barn blir i samme navnerom. Endringen er **ikke bygget eller kjørt** på grunn av disktrykket. Ingen I/O-kapasitet, `fsync`-durabilitet eller persistenskonkurranse kan derfor rapporteres nå. `getrusage` viste null prosessattribuerte blokk-I/O-operasjoner for de validerte CPU/flow-kjøringene; det sier ikke noe om cachet persistens-I/O.

### Swift tasks kontra OS-tråder

`workerTasksCreated` og `peakConfiguredInFlightTasks` i JSON beskriver bare harnessens 1/2/4/8 worker-tasker. De er ikke runtimeens samlede Swift-tasker. `top` rakk bare å sample idle-tilfellet robust (4 OS-tråder); de korte CPU/flow-prosessene mangler ofte et helt intervallsample. Det finnes dermed ikke forsvarlig observerte OS-tråd- eller Swift-task-skaleringsverdier i denne rapporten.

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
