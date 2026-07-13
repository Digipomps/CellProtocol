# `haven-commons` CLI

Kilde:
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/commons/cli/haven-commons/Sources/haven-commons/main.swift`

## Bygg
```bash
cd /Users/kjetil/Build/Digipomps/HAVEN/CellProtocol
swift build --target HavenCommonsCLI
```

## Kjør
I dette miljøet er kjøring via bygget binær mest robust:
```bash
./.build/debug/haven-commons lint keypaths
./.build/debug/haven-commons validate schema
./.build/debug/haven-commons validate purposes --namespace haven.core
./.build/debug/haven-commons validate purposes --namespace haven.sdg
./.build/debug/haven-commons resolve keypath --entity entity-1 --path '#/chronicle/events' --role member
./.build/debug/haven-commons resolve keypath --entity entity-1 --path 'haven://entity/self#/purposes' --role owner
./.build/debug/haven-commons resolve keypath --entity entity-1 --path '#/custom/football-club/initiative' --role member
./.build/debug/haven-commons resolve term --id purpose.learn --lang nb-NO --namespace haven.conference
./.build/debug/haven-commons resolve term --id purpose.sdg.no-poverty --lang nb-NO --namespace haven.sdg
./.build/debug/haven-commons resolve guidance --namespace haven.conference
./.build/debug/haven-commons benchmark purpose-interest --format markdown
./.build/debug/haven-commons benchmark purpose-interest --format markdown --tuning Docs/benchmarks/purpose_interest_local_tuning_example.json
./.build/debug/haven-commons benchmark purpose-interest --runtime-comparison --iterations 100 --format markdown
./.build/debug/haven-commons benchmark purpose-interest --runtime-comparison --conference-dataset --iterations 100 --format markdown
./.build/debug/haven-commons benchmark purpose-interest --conference-swarm --iterations 100 --format markdown
./.build/debug/haven-commons benchmark purpose-interest --scale --profiles 20,200,2000 --iterations 10 --format markdown
```

Alternativt:
```bash
swift run haven-commons lint keypaths
```

## Kommandoer
- `lint keypaths`
  - sjekker alias/deprecation/routing-konsistens
- `validate schema`
  - parser schema JSON + laster taxonomy/keypath registries
- `validate purposes`
  - validerer purpose-tree mot guidance-policy (mandatory inherited purposes, konfliktregler, goal-link checks)
  - `haven.sdg` valideres uten errors, men kan returnere warnings for ikke-mandatory purposes uten linked goals i `encouraged` mode
- `resolve keypath`
  - løser global keypath til cell/local path/type/permission
  - ukjente paths resolves som åpne/advisory referanser
- `resolve term`
  - løser taxonomy term med i18n/inheritance
- `resolve guidance`
  - returnerer taxonomy incentive guidance (root purpose + goal policy)
- `benchmark purpose-interest`
  - kjører kuraterte Purpose/Interest-scenarier mot weighted og cosine baseline
  - `--tuning <path>` legger lokale vektjusteringer oppå felles baseline uten å endre checked-in truth
  - `--runtime-comparison` sammenlikner `weightedSignal`, sparse `cosine` og `weightedRaw` med latency/RSS-sampling
  - `--conference-dataset` kjører runtime-sammenligningen mot et større deterministisk konferansedatasett
  - `--conference-swarm` kjører den deterministiske konferanse-swarm-fixturen med privacy- og capability-kontrakt
  - `--scale` lager syntetiske deterministiske datasett med flere profilstørrelser, unike anchor-interesser, latency/RSS og top-1/top-3-kvalitet
  - scale-modus sammenlikner `weightedSignalIndexed`, `weightedSignal` og `cosine`; den indekserte varianten bygger Interest -> Purpose adjacency en gang per profilsett
  - `--profiles 20,200,2000`, `--branch-factor <n>`, `--case-count <n>` og `--active-interests <n>` styrer skaleringsdatasettet
  - scale-rapporten viser også en Strategy Planner-tabell for CPU-only og GPU-available plassering; GPU her betyr foreløpig egnethet/anbefalt plassering, ikke at benchmarken krever faktisk GPU
  - `--iterations <n>` styrer antall gjennomløp for runtime-sammenligningen
  - rapporten viser felles guardrails (`purpose.human-equal-worth`, `purpose.net-positive-contribution`) og eventuelle top-resultatendringer
