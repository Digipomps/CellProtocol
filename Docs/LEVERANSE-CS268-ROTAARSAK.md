STATUS: FUNNET - CP 33ad8d741678b90b30696dde49a93fb40acce977 (#47) registrerer en aktiv genesis-selvlenke under testens persistBatch før HTTP-avvisningen.

# CS #268 — rotårsaken til PersonEntityLinkCompletion-feilene

Analysert 27. september 2026. **Rotårsaken er CP #47**, som endrer registerinnholdet før completion-forespørselen. De observerte lenkene er eierens genesis-selvlenker. Den forespurte nye identiteten får ingen same-entity-lenke i de to avviste kjøringene. Ingen fiks er implementert.

## F1 — isolering av pin og commit

CS er uendret `ea00be47cdfc40deb9977f1df4322baa22efa99d` i `/Users/kjetil/Build/Digipomps/HAVEN/_worktrees/rel-2026.9/cs268-rotaarsak`. CP ble lest fra Git-objektene i origin/main/taggenes historikk og fra SwiftPMs remote revision-checkout. Lokale CP-arbeidsfiler ble ikke brukt. Remote main og tag `2026.9.2` pekte begge på `a6fa51a8db059c64d5171cbc8d454eea412ada9d`; [fjernbevis](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/CellProtocol-remote.txt). CS #268 stod på `bc3fa95ad27f132956031abdaaa1165980c7f601`; [fjernbevis](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/CellScaffold-remote.txt).

**Metodebegrensning:** å endre bare CP-linjen i CS sitt manifest gir en uløselig SwiftPM-graf, fordi gammel DMP også krever `5609a9ad`. Den bokstavelige enkeltpin-varianten kjørte **ingen tester**:

```text
error: cellprotocol is required using two different revision-based requirements
(a6fa51a8db059c64d5171cbc8d454eea412ada9d and 5609a9ad23e76999e1cf1609e1de5a010ae2e3c9), which is not supported
```

[Reprodusert resolveravslag](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-new-literal-suite.log). Dette er ikke ført som en testfeil.

For radene merket * ble DMP/Mint eksportert fra de angitte Git-revisjonene til egne lokale snapshots. Bare manifestkravene ble samordnet: DMP peker på den valgte **remote CP-revisjonen**, Mint på dette DMP-snapshotet. CS bruker de eksisterende lokale DMP/Mint-overstyringene og `CELLPROTOCOL_PUBLISHED_API=1`; CPs development-API er dermed ikke slått på. Alle 15 DMP- og 17 Mint-kildefiler er kontrollert byte for byte. Kontrollraden med gammel CP viser at selve tilpasningen er grønn. [Reproduksjonsskript og alle varianter](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/run_matrix.py), [DMP-integritet](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/DiMyMicropayments-normalized-source-integrity.json), [Mint-integritet](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/DiMyMint-normalized-source-integrity.json).

Hver suitekjøring bygger den valgte grafen gjennom `scripts/run_swift_bounded.sh test --disable-sandbox --filter PersonEntityLinkCompletionTests`. Deretter kjøres de to navngitte testene i hver sin Swift test-prosess med `--skip-build --force-resolved-versions --filter <Suite/metode>`. Bolken bruker samme bygde binær og de opprinnelige CI-filtrene/skippene. To Swift-jobber og uendret kapasitetsvakt brukes hver gang. Full kommando står øverst i hver matrise-logg; den første baseline-loggen ble startet direkte med samme bounded runner.

| Kontroll | CP | DMP | Mint | Isolert :107 | Isolert :208 | Hele suiten | CI-bolk 26 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Opprinnelig graf | 5609a9ad | a65e202a | 1d75a2d8 | [1/1 PASS](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/baseline-missing.log) | [1/1 PASS](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/baseline-uv.log) | [7/7 PASS](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/baseline-suite.log) | [35/35 PASS](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/baseline-bolk26.log) |
| Manifestkontroll * | 5609a9ad | a65e202a | 1d75a2d8 | [1/1 PASS](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/control-missing.log) | [1/1 PASS](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/control-uv.log) | [7/7 PASS](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/control-suite.log) | ikke kjørt |
| Direkte forelder til #47 * | a40ceeb8 | a65e202a | 1d75a2d8 | [1/1 PASS](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-pre47-missing.log) | [1/1 PASS](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-pre47-uv.log) | [7/7 PASS](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-pre47-suite.log) | ikke kjørt |
| **Første røde: #47** * | 33ad8d74 | a65e202a | 1d75a2d8 | [1/1 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-47-missing.log) | [1/1 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-47-uv.log) | [2/7 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-47-suite.log) | ikke kjørt |
| #50 * | 7577d74a | a65e202a | 1d75a2d8 | [1/1 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-50-missing.log) | [1/1 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-50-uv.log) | [2/7 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-50-suite.log) | ikke kjørt |
| #48 * | ef4a99ab | a65e202a | 1d75a2d8 | [1/1 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-48-missing.log) | [1/1 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-48-uv.log) | [2/7 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-48-suite.log) | ikke kjørt |
| #46 * | 1ede9bac | a65e202a | 1d75a2d8 | [1/1 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-46-missing.log) | [1/1 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-46-uv.log) | [2/7 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-46-suite.log) | ikke kjørt |
| #51 * | 3fbdb953 | a65e202a | 1d75a2d8 | [1/1 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-51-missing.log) | [1/1 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-51-uv.log) | [2/7 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-51-suite.log) | ikke kjørt |
| Bare ny CP-kilde * | a6fa51a8 | a65e202a | 1d75a2d8 | [1/1 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-new-missing.log) | [1/1 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-new-uv.log) | [2/7 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-new-suite.log) | [2/35 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-new-bolk26.log) |
| Bare ny DMP-kilde * | 5609a9ad | 4c3b17f1 | 1d75a2d8 | [1/1 PASS](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/dmp-new-missing.log) | [1/1 PASS](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/dmp-new-uv.log) | [7/7 PASS](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/dmp-new-suite.log) | ikke kjørt |
| Bare ny Mint-kilde * | 5609a9ad | a65e202a | cc65355c | [1/1 PASS](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/mint-new-missing.log) | [1/1 PASS](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/mint-new-uv.log) | [7/7 PASS](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/mint-new-suite.log) | ikke kjørt |
| Alle nye; remote revision-pinner | a6fa51a8 | 4c3b17f1 | cc65355c | [1/1 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/all-new-missing.log) | [1/1 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/all-new-uv.log) | [2/7 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/all-new-suite.log) | [2/35 FEIL](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/all-new-bolk26.log) |

Alle røde testceller har **bare** de forventede feilene på `PersonEntityLinkCompletionTests.swift:107` og/eller `:208`; øvrige assert-er, inkludert HTTP 503, passerer. «Ikke kjørt» i bolk-kolonnen er bevisst: bolken er kjørt på gammel graf, CP alene oppgradert og hele ny graf. Alle revisjonsradene har begge isolerte tester og hele suiten.

**Commit-grensen:** direkte forelder `a40ceeb8af05e1c06b111500b50427bf08bdf4e6` er grønn; `33ad8d741678b90b30696dde49a93fb40acce977` er rød. Deretter er også #50, #48, #46, #51 og #52 røde på samme assert-er. Historikken inneholder altså #47 og #50 i tillegg til endringene nevnt i oppdraget. [Full first-parent-historikk](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-first-parent.txt), [diff for den utløsende commiten](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp47.diff), [maskinlesbare resultater](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/results.tsv).

DMP- og Mint-oppgraderingene har ingen `Sources`-diff, og begge separate kildekontroller er grønne med gammel CP. [DMP-diff](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/DiMyMicropayments-diff-stat.txt), [Mint-diff](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/DiMyMint-diff-stat.txt). CS #268 endrer ingen Swift-kilde eller disse testene; [komplett PR-diff](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cs268.diff). Samme feil gjenskapes på CS main med nye pinner, så en CS-kodeendring i #268 trengs ikke for feilen. FileUtils-c har samme commit `26f365ca39955ee693e138ef028560df3bdf218c` gjennom hele matrisen. Feilen finnes før exact-manifestendringen #52. Ingen uvedkommende eksterne pakkeversjoner ble endret; [alle lockfil-sammenligninger](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/lockfile-comparison.json).

## F2 — ikke avhengig av en tidligere test

Begge negative tester feiler i en fersk prosess alene med ny CP. Den samme feilen oppstår i bolk 26: **35 tester, 2 feil**. Med gammel CP er bolken **35/35 grønn**. Det finnes derfor ingen nødvendig «forurensende test» i bolken som forklarer disse to feilene.

Den eksakte bolken, utledet fra CS main `ci/run-tests.sh` og `ci/test-filter.txt`, er:

```text
ArendalsukaPublisherBootstrapTests
PersonEntityLinkEvidenceStoreTests
EncryptedEntityAuthorityReplicaPersistenceTests
EntityReplicaProcessTests
EntityPersonBridgeProcessTests
EntityDataGatewayCellTests
PersonEntityLinkCompletionTests
```

[Filteret som faktisk ble brukt](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/bolk26-filter.txt). CI-filene er uendret mellom main og #268. Det er ikke kjørt en ny Linux-CI-jobb; bolken er gjenskapt lokalt på macOS/Swift 6.4, med separate prosesser slik CI-scriptet gjør.

**Singletonen nullstilles faktisk ikke generelt mellom testene.** [IsolatedCellTestCase.swift:15](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cs-ea00be47/Sources/ScaffoldTestKit/IsolatedCellTestCase.swift:15) resetter resolver og globals; [CellResolver.swift:2564](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-a6fa51a8/Sources/CellBase/Cells/CellResolver/CellResolver.swift:2564) tømmer ikke IdentityLinkRegistry. Testklassens tearDown resetter runtime-policy/evidence-store, ikke registeret. Dette er en separat isolasjonsbegrensning, men forklarer ikke feilene: de oppstår også uten en forutgående test, og registeret er indeksert per eier.

Den konkrete årsakskjeden er:

1. Begge tester kaller `makeHTTPFixture`. Denne lager bruker/eier og lagrer `entityRepresentation` med `IdentityEntityPersistenceSupport.persistBatch`, **før** POST-kallet: [PersonEntityLinkCompletionTests.swift:252](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cs-ea00be47/Tests/AppTests/PersonEntityLinkCompletionTests.swift:252). HTTP-kallene og assert-ene står ved :82/:107 og :193/:208.
2. #47 legger inn `performGenesis(... .firstPersist ...)` etter bevist eierskap: [CP@33ad8d74 EntityAnchorCell.swift:814](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-33ad8d74/Sources/CellVapor/Cells/EntityAnchorCell.swift:814); samme kode er ved :862 i release-revisjonen.
3. Genesis lager `linkID = "genesis-" + anchorID`, `linkedIdentity = initiator`, `issuerIdentityUUID = initiator.uuid`, `status = .active`: [EntityGenesis.swift:123](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-a6fa51a8/Sources/CellBase/Identity/EntityGenesis.swift:123).
4. Genesis-record og signert seal lagres, og registeret gjenopprettes: [CP@33ad8d74 EntityAnchorCell.swift:1121](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-33ad8d74/Sources/CellVapor/Cells/EntityAnchorCell.swift:1121). Restore validerer genesis-sealet før recorden tas inn: [release EntityAnchorCell.swift:735](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cp-a6fa51a8/Sources/CellVapor/Cells/EntityAnchorCell.swift:735).
5. `activeLinks` returnerer alle aktive records, også denne allerede opprettede selvlenken. Den avviste nye identiteten er en annen identitet.

**Måling av innhold og tidspunkt:** etter den uendrede matrisen ble kun leselogging lagt midlertidig i CS-ruten, uten å endre beslutninger, lagring, tester eller assert-er. Første målepunkt er før kontroll av eksisterende personbinding; andre er rett før 503 i henholdsvis binding-catch og completion-catch. Loggene under er fra hver negative test alene, med alle nye remote-pinner. Record-arrayet er kanonisk JSON med SHA-256-digest. [Nøyaktig instrumenteringsdiff](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/diagnostic-route.diff).

[missing — full logg](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/diagnostic-new-missing.log:67)

```text
CS268_MEMBERSHIP phase=before-person-binding-check requestedIdentityHasSameEntityLink=false
CS268_SNAPSHOT phase=before-person-binding-check count=1 digest=325749e55945292dcd4f48003aa79d302b01d00a77f7613ee8008862d3db06ee records=[genesis=true,self=true,issuerIsOwner=true,matchesRequestedIdentity=false,matchesApproval=false,domains=["private"]]
CS268_MEMBERSHIP phase=rejected-person-binding requestedIdentityHasSameEntityLink=false
CS268_SNAPSHOT phase=rejected-person-binding count=1 digest=325749e55945292dcd4f48003aa79d302b01d00a77f7613ee8008862d3db06ee records=[genesis=true,self=true,issuerIsOwner=true,matchesRequestedIdentity=false,matchesApproval=false,domains=["private"]]
```
[uv — full logg](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/diagnostic-new-uv.log:67)

```text
CS268_MEMBERSHIP phase=before-person-binding-check requestedIdentityHasSameEntityLink=false
CS268_SNAPSHOT phase=before-person-binding-check count=1 digest=73ac6afe313ef461e943b292e4603b2e946903e5cb7ca77a8b8789e5fdcfefd6 records=[genesis=true,self=true,issuerIsOwner=true,matchesRequestedIdentity=false,matchesApproval=false,domains=["private"]]
CS268_MEMBERSHIP phase=rejected-completion requestedIdentityHasSameEntityLink=false
CS268_SNAPSHOT phase=rejected-completion count=1 digest=73ac6afe313ef461e943b292e4603b2e946903e5cb7ca77a8b8789e5fdcfefd6 records=[genesis=true,self=true,issuerIsOwner=true,matchesRequestedIdentity=false,matchesApproval=false,domains=["private"]]
```

I begge kjøringer er det én aktiv, selvutstedt genesis-lenke, med **identisk digest før og ved avvisning**. Den matcher verken forespurt identitet eller approval-ID. Direkte `sameEntityLink`-oppslag for den nye identiteten returnerer nil. Testenes øvrige kontroller for manglende recovery evidence og manglende DB-binding passerer. Bevisene støtter derfor ikke hypotesen om at disse to avvisningene har registrert den nye enheten. Dette er avgrenset til de kjørte scenariene, ikke en generell sikkerhetssertifisering.

## F3 — IdentityLinkRegistry er i CP

Fil: `CellProtocol/Sources/CellBase/Identity/IdentityLinkRegistry.swift` ved `a6fa51a8`: actor :44, singleton :45, `linksByOwner` :47, `register` :51, `restore` :56, `clear` :72, `activeLinks` :76 og `sameEntityLink` :83. [Uforanderlig kildeuttrekk](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/IdentityLinkRegistry-a6fa51a8.swift:44).

Den komplette diffen fra `5609a9ad` til `a6fa51a8` er:

```diff
diff --git a/Sources/CellBase/Identity/IdentityLinkRegistry.swift b/Sources/CellBase/Identity/IdentityLinkRegistry.swift
index 98440b1..2a2a2d7 100644
--- a/Sources/CellBase/Identity/IdentityLinkRegistry.swift
+++ b/Sources/CellBase/Identity/IdentityLinkRegistry.swift
@@ -93,7 +93,11 @@ public actor IdentityLinkRegistry {
             guard record.linkedIdentity.uuid == requesterUUID,
                   record.linkedIdentity.publicKey == signingKey,
                   IdentityLinkScope.grantsSameEntity(record.approvedScopes),
-                  record.approvedDomains.contains(domain) else {
+                  record.approvedDomains.contains(domain),
+                  // purpose://candidate.entitetsdata.authorization-resolves-entity:
+                  // pairwise and blinded bindings prove membership to *others*;
+                  // only a link bound to the local anchor opens the entity itself.
+                  record.entityBinding.mode == .localEntityAnchor else {
                 continue
             }
             return record
```

`register`, `restore`, singleton-lagringen og `activeLinks` er uendret. Diffen over begrenser `sameEntityLink` til lokale entity-anchor-bindinger. Den utløsende skriveendringen ligger i **EntityAnchorCell/genesis**, ikke i implementasjonen av `activeLinks`.

## F4 — minste forsvarlige forslag, uten implementering

**Med kravet om å beholde de eksisterende testene uendret foreslås en CP-kontraktsfiks:** skill verifisert genesis-eierskap fra listen over fullførte innmeldingslenker. `activeLinks(ownerUUID:)` kan da beholde CS-forbrukernes tidligere betydning: aktive enrollment-lenker. Genesis-sealet og dets eierbevis må bestå, og resolverens genesis-/same-entity-autorisasjon må fortsatt bruke den verifiserte genesis-informasjonen. Klassifiseringen bør komme fra validert genesis-state, ikke et generelt filter som skjuler alle selvlenker eller alle records med et navneprefiks.

Dette hører hjemme i `IdentityLinkRegistry` og restore-integrasjonen i begge CP-runtime-variantene (`Sources/CellVapor/Cells/EntityAnchorCell.swift` og `Sources/CellApple/Cells/EntityAnchorCell.swift`). Det må være et eksplisitt valg av API-kontrakt: dagens navn/implementasjon sier «alle aktive lenker», mens de uendrede CS-testene forutsetter «ingen enrollment-lenker». Å gjøre testen grønn alene er ikke tilstrekkelig begrunnelse for å endre betydningen. En ren CS-endring som tømmer registeret ved HTTP-avvisning ville fjerne legitimt genesis-eierskap og er ikke en riktig fiks.

Forslaget må verifiseres med uendrede CS-tester, bolk 26 og CP-regresjoner for genesis, restart/restore, faktisk innmelding, feil bevis og revokering. **Denne fiksen og disse nye regresjonene er ikke kjørt eller implementert.** Analysejobben har ikke endret noen sikkerhetskontroll eller testforventning.

En CP-fiks krever **2026.9.3** og en senere koordinert forbrukeroppdatering. `2026.9.2`-taggene skal stå immutable. Ingen endring av #268, push, PR, commit eller merge er gjort i denne jobben.

## Reproduksjon, avgrensning og opprydding

[Miljø](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/environment.txt), [alle testresultater](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/results.json), [loggutdrag med fil:linje](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/test-excerpts.txt), [kapasitetsvakt før hver Swift-kjøring](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/capacity-summary.txt). Originaltesten er byte-identisk med både `ea00be47` og `bc3fa95a`; [SHA-256 og sammenligning](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/test-integrity.json).

Full CS-suite, nye CP-pakketester, ny Linux-CI, staging/prod og browserløp: **ikke kjørt**. Den tidligere Jobb E-rapportens Linux-feil er bakgrunnsbevis; alle resultatene i matrisen over er fra denne jobben.

Sluttkontroll og sletting av eget `.build`: se [oppryddingsbevis](/Users/kjetil/Build/Digipomps/HAVEN/HAVEN-Deploy/_handoff/cs268-rotaarsak-evidence/cleanup.txt). Midlertidig rutelogging og Package.swift/Package.resolved er tilbakeført til egen worktrees HEAD; ingen andre arbeidstrær ryddes. Arbeidskøen følger opp samme eksisterende feil i HD-0132; ingen fikset/grønn release påstås.

Pålagt HAVEN-Deploy-oppstart fant eksisterende HIGH-varsel: leveranseinventaret var 216,1 timer gammelt, med 0 ubesluttede i det foreldede inventaret. `hd validate` hadde 11 eksisterende fingerprint-formatfeil. Ingen aktive claims. Dette er ikke en fersk tilstandsmåling av staging/prod.

Sluttkontroll: CP main/tagger og CS main/#268 er fjernverifisert uendret fra oppstart. HD-0132-bevis er registrert som `ev_c24c910c3a608672`; lesson `L-2026-09-27-cs268-genesis-registry` (`ev_bde14914fdc5d9d5`). Sluttvalidering har fortsatt de samme 11 eksisterende formatfeilene. Hendelsesloggen er oppdatert i `/Users/kjetil/Build/Digipomps/HAVEN/Losen/logg/Losen_Hendelseslogg.md`.
