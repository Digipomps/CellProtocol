# Avgrenset SwiftPM-buildrunner

`Scripts/haven-swiftpm.sh` hindrer at lokale og agentstyrte SwiftPM-bygg lager stadig nye, ubegrensede scratch-kataloger. Runneren endrer ikke CellProtocol-runtime eller protokollsemantikk.

## Sikkerhets- og ressursinvarianter

- Bygg som tilhører samme repository, pakke og Swift-binær deler én stabil cache og serialiseres med en lease.
- SwiftPM scratch, SwiftPMs nedlastingscache og Clang/Swift-modulcache legges under den samme forvaltede roten.
- En eksplisitt `--cache-key` hashes sammen med Swift-binæren før den brukes som katalognavn. Rå remote-URL eller cache-key lagres ikke.
- Leasen bindes til PID og prosessens starttid. Dette reduserer risikoen for at gjenbruk av PID gjør en foreldet lease gyldig.
- Runneren bruker privat `umask`, krever at cache-roten eies av aktiv bruker og avviser symbolske lenker på forvaltede grenser og cache-underkataloger.
- Garbage collection sletter bare direkte underkataloger i `caches/` med eksakt `.haven-swiftpm-cache-v1`-markør.
- En cache slettes ikke mens den har en levende lease. Når `lsof` finnes, hoppes den også over dersom en prosess har åpne filer i katalogen. Det samme gjelder før gjenbruk etter en stale lease, slik at et foreldreløst Swift-barn ikke deler cache med en ny build.
- Swift sin exit-status returneres uendret. `SIGINT`, `SIGHUP` og `SIGTERM` videresendes til Swift-prosessen, og leasen ryddes ved kontrollert avslutning.
- Konkurrerende bruk av samme cache venter som standard. Utløpt eller deaktivert venting returnerer exit-kode `75` (`EX_TEMPFAIL`).

Runneren forvalter bare sin egen cache-rot. Den rydder ikke vilkårlige eldre kataloger i `/private/tmp`, DerivedData eller andre verktøys data.

## Bruk

Fra roten av en Swift-pakke:

```bash
Scripts/haven-swiftpm.sh -- test
Scripts/haven-swiftpm.sh -- test --filter ResolverTests
Scripts/haven-swiftpm.sh -- build -c release
```

Midlertidig, isolert verifikasjon som ikke skal beholde build-produkter:

```bash
Scripts/haven-swiftpm.sh --ephemeral -- test --filter SecurityTests
```

En eksplisitt nøkkel er nyttig utenfor et Git-repository eller når flere arbeidsområder bevisst skal dele cache:

```bash
Scripts/haven-swiftpm.sh --cache-key cellprotocol-main -- test
```

Runneren avviser en manuelt angitt `--scratch-path`, `--build-path`, `--cache-path` eller `--package-path`, siden dette ellers omgår livssyklusen eller kan blande en annen pakke inn i samme cacheidentitet. Kjør kommandoen fra pakken som skal bygges. `CLANG_MODULE_CACHE_PATH` og `SWIFTPM_MODULECACHE_OVERRIDE` settes alltid til den forvaltede cachen for Swift-prosessen.

## Retensjon og opprydding

Standardene er:

- maksimal inaktivitet: 72 timer (`259200` sekunder)
- samlet cache-tak: 24 GiB (`25165824` KiB)
- venting på opptatt cache: 30 minutter

`0` deaktiverer henholdsvis alders- eller størrelsesgrensen. Se først hva garbage collection ville gjort:

```bash
Scripts/haven-swiftpm.sh --gc-only --dry-run
Scripts/haven-swiftpm.sh --gc-only
```

Verdiene kan styres med flagg eller miljøvariablene:

- `HAVEN_SWIFTPM_CACHE_ROOT`
- `HAVEN_SWIFTPM_CACHE_KEY`
- `HAVEN_SWIFTPM_MAX_AGE_SECONDS`
- `HAVEN_SWIFTPM_MAX_CACHE_KIB`
- `HAVEN_SWIFTPM_WAIT_SECONDS`
- `HAVEN_SWIFTPM_POLL_SECONDS`
- `SWIFT_BIN`

For lokale agentjobber og parallelle arbeidsområder bør alle `swift build`, `swift test`, `swift run` og `swift package`-operasjoner gå gjennom runneren. Forvaltede cacher skal ikke slettes manuelt mens en jobb kjører; bruk `--gc-only`.

## Verifikasjon

De deterministiske testene bruker en falsk Swift-binær og gjør ingen nettverkskall:

```bash
Tests/Scripts/HavenSwiftPMRunnerTests.sh
```

Testene dekker stabil cache, låsekonflikt, foreldet lease, foreldreløse åpne filer, pakkeidentitet, symlink-flukt, markeringsgrensen for sletting, levende lease, alders- og størrelsestak, ephemeral opprydding og bevaring av Swift sin exit-status.
