# Første kartlegging for periodisk testrevisjon

Dato: 2026-09-10. Status: **avgrenset statisk kartlegging fullført; full kvalitetsrevisjon gjenstår**. Ingen tester er endret eller fjernet. Eksisterende kjøringsbevis er gjenbrukt; ingen ny fullsuite eller feilinnføring er kjørt i denne kartleggingen.

[Arbeidspraksis](../../Testing/HAVEN-test-suite-audit.md) · [Maskinlesbart inventar og oppfølgingspunkter](HAVEN-test-suite-audit.json) · [Tidligere integrasjonsbevis](CellProtocol-security-main-integration.md).

## Vurderingen

Det er rimelig å være bekymret for at tester akkumuleres uten en tilsvarende vurdering av nytten. Det er ikke dokumentert at HAVEN bare rydder tester når de feiler. CellScaffold har allerede et vedlikeholdssystem for testutvalg og en datert gjennomgang av tidligere utestengte suiter. Tre artefaktgeneratorer er eksplisitt kategorisert som slike.

Den [eksisterende gjennomgangen fra 9. september](https://github.com/Digipomps/CellScaffold/blob/e10e93ea92c21d0d13cef600f1b276647617bf30/Deliverables/PDD_butler-verktoyflate_2026-09-09/TESTGJENNOMGANG.md) beskriver derimot uttrykkelig en kontroll av kompilering og kjøringsutfall, uten dom om testkvalitet. Den beskriver 166 undersøkte suiter og 149 tidligere uavklarte suiter flyttet inn i CI-filteret. Dette er historiske tall fra den navngitte gjennomgangen; de erstatter ikke dagens inventar eller en ny vurdering av relevans.

En bestående test kan ha svake forventninger, speile samme feil som produksjonskoden eller beskytte en avviklet funksjon. En aldri-feilende sikkerhetstest kan også være verdifull. En ustabil test kan varsle en reell samtidighetsfeil. Revisjonen må derfor dokumentere beskyttet krav og faktisk feiloppdagelse før den vurderer fjerning. [Google om ustabilitet og produktfeil](https://testing.googleblog.com/2017/04/where-do-our-flaky-tests-come-from.html?hl=it_IT).

## Grunnlag og metode

CellScaffold ble lest fra sporet Git-tre `e10e93ea92c21d0d13cef600f1b276647617bf30`. CellProtocols kontroller ble lest fra `e03923cb2f1d5a339eaf62585ddc9dddf7750cec`. Binding-beviset gjelder testet `64401752`, merget med identisk tre som `ba195299`. Brukerens endringer i hovedarbeidskopiene inngår ikke i disse kildepåstandene.

Alle sporede Swift-filer under CellScaffolds `Tests/` ble lest via `git ls-tree` og `git show`. Inventeringen brukte samme mønster for navngitte `class`/`struct`/`actor` med `Tests`-suffiks som den eksisterende kontrollen, med `AppTests` og `Tests` utelatt. Navn ble avstemt mot `ci/test-filter.txt`, `ci/test-exclusions.txt` og `ci/test-skips.txt`. Kommentarer og bolkskillet `---` ble ikke regnet som seleksjoner. JSON-filen lagrer navn, fil, linje, metodeutvalg og kilde-SHA.

Dette er en kildeinventering. Den teller ikke dynamisk oppdagede XCTest-/Swift Testing-parametriseringer og dekker ikke alle språk, scripts eller GUI-testtyper. Fravær i regex-resultatet kan ikke brukes til å erklære en test død.

## Konkrete funn

| Kontroll | Resultat | Betydning |
| --- | --- | --- |
| Suiter funnet med kontrollens navnemønster | 290 | Et avgrenset kildeinventar, ikke antall testtilfeller. |
| Hele suitenavnet finnes i filteret | 267 | Metode-skips og miljøstyrte skips kan fortsatt gjelde. |
| Bare utvalgte metoder finnes i filteret | 3 | Disse suitene er ikke dokumentert fullt valgt av denne kontrollen. |
| Navn i suiteunntakslisten | 21 | Ett navn overlapper med delvis metodekjøring; 20 er bare unntatt. |
| Eksplisitte metode-skips | 5 | Egne CLI-unntak, ikke samme mengde som runtime-rapporterte skips. |
| Regex-funn uten verken filter eller unntak | 0 | Eksisterende kontroll gjør nyttig arbeid på suitenivå. |

De tre delvis filtrerte familiene er:

| Familie | `test…`-metodedeklarasjoner i kildefilen | Eksplisitte filterselektorer |
| --- | ---: | ---: |
| `CellScaffoldRuntimeIdentityProvisionerTests` | 31 | 8 |
| `CellScaffoldRuntimeIdentityRegistryTests` | 21 | 3 |
| `PortholeConfigurationLoadingTests` | 51 | 1 |

Disse tallene er statiske deklarasjoner og filterstrenger. Testkjørerens mønstermatching og plattformbetingelser må undersøkes før vi fastslår det faktiske utvalget. Porthole-familien står også i unntakslisten.

[Suitekontrollen](https://github.com/Digipomps/CellScaffold/blob/e10e93ea92c21d0d13cef600f1b276647617bf30/ci/test-suite-coverage.sh#L16) fjerner metodedelen fra filteret før den sammenligner suitenavn. Derfor kan en ny metode i en allerede representert suite falle utenfor uten at denne kontrollen avviser endringen. Dette er et bekreftet avgrensningsproblem ved kontrollen, ikke i seg selv et bevist produksjonshull. [Filteret](https://github.com/Digipomps/CellScaffold/blob/e10e93ea92c21d0d13cef600f1b276647617bf30/ci/test-filter.txt#L39) og [kjøreren](https://github.com/Digipomps/CellScaffold/blob/e10e93ea92c21d0d13cef600f1b276647617bf30/ci/run-tests.sh#L60) viser den faktiske kilden til vurderingen.

Unntakslisten inneholder daterte begrunnelser, blant annet produktfeil, testisolasjon, Linux-forutsetninger og tre Butler-dumper. De er ikke alle irrelevante tester. [Kilden](https://github.com/Digipomps/CellScaffold/blob/e10e93ea92c21d0d13cef600f1b276647617bf30/ci/test-exclusions.txt) bør gjennomgås for gjeninntak og klare krav, ikke tømmes for å få en enklere oversikt.

En innledende hypotese om manglende `TESTGJENNOMGANG.md` ble **avkreftet** av full Git-inventering: dokumentet finnes under `Deliverables/PDD_butler-verktoyflate_2026-09-09/`. Oppfølgingspunktet gjelder den uklare kortreferansen og varig gjenfinning av bevis. Dokumentet oppgir rålogger som gitignorerte worktree-filer; tilgjengeligheten til disse historiske råloggene er ikke kontrollert her.

## Hva de grønne portene faktisk beviser

CellScaffold-kjøringen [34466967151](https://github.com/Digipomps/CellScaffold/actions/runs/34466967151) bestod det konfigurerte CI-utvalget med 2067 Swift-tilfeller, 13 runtime-rapporterte utelatelser, null feil og 22 nettlesertester. Tallet omfatter ikke alle tester som ble filtrert bort før kjøring. Det skal derfor ikke brukes som bevis på at hele repoets testinventar ble kjørt eller vurdert semantisk.

Binding hadde 501 tilfeller i hele `BindingTests`: 481 bestått, 20 eksisterende opt-in-utelatelser og null feil. `BindingUITests` og signert distribusjon var utenfor denne porten. Klasse-A-forhåndskontrollen bestod. Dette illustrerer hvorfor testomfang, miljø og kildekvittering må følge tallene.

## Registrert oppfølging

Seks konkrete oppfølgingspunkter er lagret med stabile ID-er, kilder, neste handling og akseptkriterier i JSON-filen. De er dokumentert lokalt, **ikke registrert eller fullført i en native HAVEN-kø**.

| ID-suffiks | Arbeid |
| --- | --- |
| 001 | Avstem fullstendige test-ID-er mot faktisk CI-seleksjon, særlig de tre delvise familiene. |
| 002 | Gjennomgå gjenværende unntak og opt-in-tester med krav, årsak og gjeninntak/vurdering. |
| 003 | Vurder relevans og prøv feiloppdagelse i kritiske kontrakt- og sikkerhetsfamilier. |
| 004 | Etabler sammenlignbare kostnads- og stabilitetsserier med første forsøk og retries adskilt. |
| 005 | Gjør referanser og nødvendig audit-evidens varig gjenfinnbar. |
| 006 | Kontroller skillet mellom verifiserende tester, artefaktgeneratorer og eksperimenter. |

Alle bruker prefikset `haven-test-audit-20260910-`. Ingen tester er nå vurdert som trygge å fjerne. Det er ikke utført en komplett redundansanalyse eller mutation testing i denne første kartleggingen.

## Oppfølging og dokumentasjon

Automatiseringen **Revider HAVEN-testsuitene** er opprettet og lest tilbake som aktiv, ID `revider-haven-testsuitene`. Den følger denne oppgaven første mandag hver måned kl. 09:00 lokal tid; miljøets tidssone er Europe/Oslo. Første kommende dato etter denne kartleggingen er 5. oktober 2026. Januar/april/juli/oktober bruker full gjennomgang; de andre månedene tar endringer og åpne funn. Frekvensen er assistentens foreløpige valg etter et ubesvart valgfritt spørsmål, ikke en eksplisitt intervallbestilling fra Kjetil.

Utføringen er en Codex-heartbeat, ikke en HAVENAgentD-scheduler. Den skriver datert Markdown og JSON og følger uferdig arbeid videre. Lokal kjøring krever tilgjengelig maskin, app og repo. [Offisiell dokumentasjon](https://learn.chatgpt.com/docs/automations?surface=app).

Ingen kode, tester, skip-lister, merge-porter eller opprinnelige sikkerhetsoppgaver ble endret i denne revisjonen. De nye filene er lokal dokumentasjon og er ikke pushet eller merget til main.
