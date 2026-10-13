# AUDIT-BYGG-20260924

Kjørt 24. september 2026 i `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/_wt-audit-20260924`.

Bygg med tester fullført uten kompileringsfeil. Alle fire audit-tester bestod. Hele CellBase-suiten fullførte med **1239 tester, 9 hoppet over og 3 feil (3 unexpected)**. De tre feilene gjelder AppleIdentityVaultKeyStorageTests og er gjengitt nedenfor. Fullsuiten er dermed ikke grønn.

## Kommandoer, ordrett

Kommandoene ble kjørt én gang hver, i denne rekkefølgen:

```sh
Scripts/haven-swiftpm.sh -- build --build-tests --disable-sandbox
Scripts/haven-swiftpm.sh -- test --filter RegisteredKeypathAuditTests --disable-sandbox
Scripts/haven-swiftpm.sh -- test --filter CellBaseTests --disable-sandbox
```

`--disable-sandbox` virket gjennom wrapperen. Det var ikke nødvendig å kjøre Swift direkte. Ingen `sandbox-exec: sandbox_apply` / `Invalid manifest`-feil oppstod denne gangen. SwiftPMs manifest-sandkasse ble deaktivert som instruert; testutvalg, assertions og kvalitetskrav ble ikke endret.

Verktøykjede, ordrett:

```text
swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)
Target: arm64-apple-macosx27.0.0
```

## Kompileringsfeil og endringer

**Ingen kompileringsfeil. Ingen rettelser.** Det finnes derfor ingen rettet kompileringsfeilmelding eller kodediff å gjengi. Signaturene for `registerExploreContract`, `addInterceptForGet` og `registerGet(key:owner:handler:)` var gyldige. Både `.integer(Int)` og `.number(Int)` finnes i `ValueType`, og `MockIdentityVault` finnes i testmålet.

De tre angitte Swift-filene er byte-for-byte uendret fra før byggingen. `Package.resolved` er også uendret. Ingen test ble endret, ingen commit/push eller worktree-reparasjon ble utført. Denne rapporten erstatter forrige rapport. Rålogger og tidsmålinger ligger i den midlertidige katalogen oppgitt nederst.

Bygget ga advarsler, blant annet om utilgjengelige bruker-cacher, ubehandlede Markdown-filer, Sendable, utdaterte API-er og variabler som ikke muteres. Ingen advarsler ble undertrykt eller rettet som del av dette oppdraget.

## De fire audit-testene — ordrette resultatlinjer

Fra den separate kjøringen med `--filter RegisteredKeypathAuditTests`:

```text
Test Case '-[CellBaseTests.RegisteredKeypathAuditTests testAuditInvokesNoHandlerAndChangesNothing]' passed (0.009 seconds).
Test Case '-[CellBaseTests.RegisteredKeypathAuditTests testDeclaredContractWithoutHandlerIsReported]' passed (0.001 seconds).
Test Case '-[CellBaseTests.RegisteredKeypathAuditTests testHandlerWithoutDeclaredContractIsReported]' passed (0.000 seconds).
Test Case '-[CellBaseTests.RegisteredKeypathAuditTests testRegisteredKeypathsReportsExactlyWhatWasWired]' passed (0.001 seconds).
```

Ordrett oppsummering:

```text
Test Suite 'RegisteredKeypathAuditTests' passed at 2026-09-24 20:18:53.034.
	 Executed 4 tests, with 0 failures (0 unexpected) in 0.011 (0.011) seconds
```

Exitkode: **0**. Ingen av de fire hadde innholdsfeil. Alle fire bestod også i fullsuiten.

## Full CellBase-suite

Ordrett XCTest-oppsummering:

```text
Test Suite 'CellBaseTests.xctest' failed at 2026-09-24 20:21:10.403.
	 Executed 1239 tests, with 9 tests skipped and 3 failures (3 unexpected) in 125.922 (125.984) seconds
Test Suite 'Selected tests' failed at 2026-09-24 20:21:10.403.
	 Executed 1239 tests, with 9 tests skipped and 3 failures (3 unexpected) in 125.922 (125.985) seconds
```

Exitkode: **1**. Suiten kjørte ferdig; ingen tester ble avbrutt av assistenten.

### Feil: forventet mot faktisk

Alle tre feilene oppstod i kjøring av ferdig kompilerte tester. Ingen av testene eller implementasjonene ble endret.

| Test i AppleIdentityVaultKeyStorageTests | Forventet fra testkoden | Faktisk i denne kjøringen |
| --- | --- | --- |
| `testLegacyEmbeddedPrivateKeyMigratesToApplicationTagAndSigns` | Nøkkelopprettelse og migrering lykkes; lagret nøkkel får application tag, innebygd privatnøkkel tømmes, og signaturen verifiseres. | Nøkkelopprettelse kastet feil før migreringsassertions: `NSOSStatusErrorDomain Code=100001`, `failed to generate CDSA key`, `EPERM: Operation not permitted`. |
| `testLegacyEmbeddedPrivateKeyStillSigns` | Innebygd eldre privatnøkkel signerer, og signaturen verifiseres som sann. | Nøkkelopprettelse kastet samme CDSA/EPERM-feil før signeringsassertions. |
| `testScopedSecretDataStaysStableInUnsignedTestHost` | To oppslag gir identiske hemmelige byte med lengde minst 32. | Oppslaget kastet `unhandledError(status: -25291)` før likhets- og lengdeassertions. |

Feilmeldinger og resultatlinjer, ordrett:

```text
/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/_wt-audit-20260924/Sources/CellApple/IdentityVault.swift:1374: error: -[CellBaseTests.AppleIdentityVaultKeyStorageTests testLegacyEmbeddedPrivateKeyMigratesToApplicationTagAndSigns] : failed: caught error: "Creating private key failed with error: Optional(Swift.Unmanaged<__C.CFErrorRef>(_value: Error Domain=NSOSStatusErrorDomain Code=100001 "failed to generate CDSA key" (EPERM: Operation not permitted) UserInfo={numberOfErrorsDeep=0, NSDescription=failed to generate CDSA key}))"
Test Case '-[CellBaseTests.AppleIdentityVaultKeyStorageTests testLegacyEmbeddedPrivateKeyMigratesToApplicationTagAndSigns]' failed (2.795 seconds).
/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/_wt-audit-20260924/Sources/CellApple/IdentityVault.swift:1374: error: -[CellBaseTests.AppleIdentityVaultKeyStorageTests testLegacyEmbeddedPrivateKeyStillSigns] : failed: caught error: "Creating private key failed with error: Optional(Swift.Unmanaged<__C.CFErrorRef>(_value: Error Domain=NSOSStatusErrorDomain Code=100001 "failed to generate CDSA key" (EPERM: Operation not permitted) UserInfo={numberOfErrorsDeep=0, NSDescription=failed to generate CDSA key}))"
Test Case '-[CellBaseTests.AppleIdentityVaultKeyStorageTests testLegacyEmbeddedPrivateKeyStillSigns]' failed (0.066 seconds).
/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/_wt-audit-20260924/Sources/CellApple/IdentityVault.swift:780: error: -[CellBaseTests.AppleIdentityVaultKeyStorageTests testScopedSecretDataStaysStableInUnsignedTestHost] : failed: caught error: "unhandledError(status: -25291)"
Test Case '-[CellBaseTests.AppleIdentityVaultKeyStorageTests testScopedSecretDataStaysStableInUnsignedTestHost]' failed (0.089 seconds).
```

Loggen viser at nøkkeloperasjoner ikke var tilgjengelige i dette kjøremiljøet. Dette gir ikke grunnlag for å erklære de tre testene bestått eller hevde at fullsuiten ville bestå i et annet miljø. `--disable-sandbox` løste manifestbyggingen, men disse runtime-feilene bestod.

De ni hoppede-over testene brukte eksisterende skip-betingelser: sju meldte `Keychain-backed key generation is unavailable in this test environment`, én manglet referanselydfil, og én meldte `MATCHER_DUMP_PATH not set`. Ingen skip-betingelse ble lagt til eller endret.

## Byggetid og kjøretider

Veggtid er målt rundt hver nøyaktige kommando med en monoton klokke. Tidene inkluderer wrapperarbeid; SwiftPMs egen `Build complete!`-tid er oppgitt separat. Klokkeslett er Europe/Oslo (UTC+02:00).

| Kommando | Start | Slutt | Veggtid | Exitkode |
| --- | --- | --- | ---: | ---: |
| Bygg med tester | 20:14:55.981 | 20:18:36.334 | 220.349 s | 0 |
| Fire audit-tester | 20:18:42.586 | 20:18:54.457 | 11.870 s | 0 |
| Full CellBase-suite | 20:18:59.170 | 20:21:13.775 | 134.604 s | 1 |

SwiftPMs egne byggetidslinjer, henholdsvis bygg, audit-kjøring og fullsuite:

```text
Build complete! (155,62 sek)
Build complete! (3,49 sek)
Build complete! (1,66 sek)
```

Første byggkommando tok **220,349 sekunder (3 min 40,349 sek)** totalt. SwiftPM rapporterte **155,62 sekunder** for selve byggfasen. Fullsuitens XCTest-tid var 125,922 sekunder (125,984 sekunder samlet for `CellBaseTests.xctest`).

## Etterkontroll og rålogger

SHA-256 for de tre urørte filene, identisk før og etter kjøringen:

- `b0a45164f1c4068b92450cb49bf00d199d97c40414d25152ffd356a6825b732d` — `Sources/CellBase/Cells/GeneralCell/Cast/Intercepts.swift`
- `396d30287459df55b9856d51c24198d68ed159513cdf9c3740f6923945aa57b7` — `Sources/CellBase/Cells/GeneralCell/GeneralCell.swift`
- `2efc377c2b828d849d7fe024bd640aab732793f2044c4a7532685f1c70273320` — `Tests/CellBaseTests/RegisteredKeypathAuditTests.swift`

Fullstendige stdout/stderr-logger og JSON med kommando, start/slutt, veggtid og exitkode finnes midlertidig her:

- [build-1.log](/private/tmp/audit-bygg-20260924-k3_1ixfp/build-1.log) og [build-1.json](/private/tmp/audit-bygg-20260924-k3_1ixfp/build-1.json)
- [audit-1.log](/private/tmp/audit-bygg-20260924-k3_1ixfp/audit-1.log) og [audit-1.json](/private/tmp/audit-bygg-20260924-k3_1ixfp/audit-1.json)
- [full-1.log](/private/tmp/audit-bygg-20260924-k3_1ixfp/full-1.log) og [full-1.json](/private/tmp/audit-bygg-20260924-k3_1ixfp/full-1.json)
