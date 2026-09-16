# Implementasjon og kontroll – 11. september 2026

Denne oppfølgingen er lokal kildekode og dokumentasjon. Den er ikke pushet, utrullet eller installert på iPhone. Eksemplene er syntetiske. Ingen kontaktposter, identitetsnøkler eller Entity-data er migrert eller slettet.

**Datamodellen:** `EntityRelationRecord` kan bevare den eksisterende `EntityRepresentation` som kanonisk kunnskapsgraf. `EntityRelationPerspective` tilpasser eldre poster ved lesing. `EntityRepresentationDataCodec` setter opp de eksisterende typede `Facilitator`-registrene, bevarer `person` kun ved eksplisitt eierlagring og binder interne referanser svakt etter dekoding. Ingen ny matcher eller alternativ Purpose-type er lagt til.

`Purpose`, `Interest` og `EntityRepresentation` registrerer roten før barn serialiseres. `Weight<T>` bruker allerede samme register via `encoder.userInfo` og skriver en referanse ved gjentakelse. `nodeIdentifier` overlever nå Purpose-/Interest-serialisering. Den eldre Perspective-containeren bevarer nå også entitetslisten, og kan lese eldre dokumenter uten listen.

En ugyldig graf (for eksempel NaN-vekt) avbryter serialisering via `EntityRelationCodec.persistenceValue`. Binding bruker denne kastende kodeken for mutasjoner, slik at en feil ikke blir til en `null`-sletting.

**Binding:** `Cells/RelationEntityStore.swift` bevarer en eksisterende kanonisk graf ved resynkronisering. `Cells/RelationsCell.swift` leser representasjonen fra eierens Entity og bruker den faktiske kodeken ved projeksjon. `includeGraph` er et uttrykkelig valg, standard er fortsatt direkte interesser. Valget bevares ved oppfriskning og i cellens Codable-tilstand, og nullstilles når projeksjonen slås av. Alle eksisterende autorisasjons- og signeringsbaner beholdes. Eldre importfelter og visningsmodeller finnes fortsatt; det er ikke gjennomført en global migrering av alle redigeringsflater.

**Verifikasjon:**

| Kontroll | Resultat | Grense |
|---|---|---|
| Valgte CellBase XCTest-suiter | 57 tester, 0 feil | Inkluderer 11 nye EntityRelationPerspective-tester; ikke hele pakken |
| Sirkler i faktisk objektgraf | Bestått | 30 Purpose-noder, delte kanter og tilbakekoblinger; én full kropp per ID og under 25 000 byte |
| Selvsløyfer på rot | Bestått | EntityRepresentation, Purpose og Interest bruker referanser |
| Les/skriv og levetid | Bestått | Vekter, ID-er, funksjonskonfigurasjoner og private personfelter bevares ved eierlagring; svake tilbakekoblinger slipper grafen |
| Dokumentert eksempel i Swift | Bestått | Samme JSON dekodes og matches i eksisterende WeightedGraphRuntime; ferskhetsbetingelsen håndheves |
| Eksisterende projeksjon/adgangsregler | Bestått i de valgte testene | Ingen full sikkerhetsrevisjon eller ny distribuert garanti |
| Binding build-for-testing, macOS arm64 | `TEST BUILD SUCCEEDED` | Testene er kompilert, men Binding-testverten/UI-testene er ikke kjørt |
| JSON Schema | 3 gyldige skjemaer, 68 lokale referanser, 40 positive/negative tilfeller | JSON Schema beviser ikke rettigheter, signaturer eller at eksterne referanser finnes |
| Koblingsfixturens kilde | `swiftc -parse` bestått | Endringen i den isolerte EntityContinuity-klonen er ikke fullbygget eller kjørt i UI |
| Testbyggisolering på Mac | Bestått | Bekreftet bundle-ID, nytt navn, ingen URLTypes, avregistrering og verifisert ad hoc-signatur |

Testkommandoen for CellProtocol var:

```sh
bash scripts/haven-swiftpm.sh --cache-root /private/tmp/haven-swiftpm-bounded --max-age-seconds 0 --max-cache-kib 0 --wait-seconds 2 -- test -j 2 --disable-automatic-resolution --filter 'EntityRelationPerspectiveTests|PerspectiveEntityProjectionTests|EntityRelationRecordV1Tests|PurposeAndInterestMatchingTests|WeightedGraph|PurposeComposition|InterestCondition'
```

Ingen cache-rydding var aktivert. SwiftPM måtte kjøres utenfor den ytre sandboxen fordi kompilatorens egen sandbox først feilet med `sandbox_apply: Operation not permitted`. Den første byggingen ble også avbrutt av en kildeendring under kompilering. Den etterfølgende testkjøringen fant en feil i testens bruk av ValueType-likhet; kontrollen ble rettet til å sammenligne den faktiske serialiserte JSON-en. De endelige resultatene ovenfor er fra vellykkede kjøringer etter rettelsene.

Lokale rålogger ligger i `/private/tmp/entitydata-perspective-tests.log` og `/private/tmp/entitydata-binding-build.log`. SHA-256 og kort resultat finnes i `TESTRESULTATER.json`. Binding ble kun bygget med `build-for-testing` og `CODE_SIGNING_ALLOWED=NO`; ingen ny HAVEN-testvert ble startet.

**Appforvekslingen på Mac og iPhone:**

Fire vanlige/test-HAVEN-prosesser var startet fra forskjellige byggesteder på Mac. Tre ekstra prosesser er avsluttet normalt etter UI-inspeksjon. Den gjenværende prosessen er fra `Binding-EntityContinuity`; den separate HAVEN Agent er beholdt.

Den avsluttede UI-fixturen hadde bundle-ID `org.digipomps.haven.person-link-ui-test`, nesten samme navn som de andre appene, og registrerte det vanlige `haven://`-skjemaet. Fixturens kode brukte en bevisst tom identitetsleverandør når testmodus var aktiv. Dette gir en konkret forklaring som passer skjermbildet, men skjermbildet alene identifiserer ikke hvilken prosess som viste feilen.

Det midlertidige testbygget er nå merket **HAVEN UI-test**, dets URL-håndterere er fjernet og den gamle LaunchServices-registreringen er trukket tilbake. Metadata og signatur er kontrollert. Det gjenbrukbare verktøyet er `Binding/Scripts/isolate_identity_link_fixture.py`; det avviser normale HAVEN-bygg, bygg utenfor midlertidige mapper og kjørende testbygg.

I den isolerte kildeklonen `Binding/Implementation/EntityContinuity-20260911/Binding` er testmodus også knyttet til fixture-bundle-ID, en synlig testbanner er lagt til, reell kobling stoppes med en forklarende testbyggmelding, og den misvisende feilen «denne telefonen» er endret til «denne enheten». Dette er kildeendringer som må følge koblingskandidatens videre bygging.

På tilgjengelig iPhone er to separate bundle-ID-er bekreftet: `org.digipomps.haven` og `org.digipomps.havenplayground`, begge med synlig navn HAVEN. Begge er beholdt; å fjerne eller erstatte dem kan berøre ulike data-/nøkkellagre. De installerte iPhone-appene er ikke omdøpt.

**Koblingsfeilen er ikke erklært løst ende til ende.** Den gjenværende Mac-prosessen kjører fra et byggested der selve app-bundlen ikke lenger finnes på disk, samtidig som en separat `/Applications/HAVEN.app` med samme bundle-ID finnes. Derfor er riktig varig lenkemål ikke ferdig verifisert. Det må ferdigstilles én identifiserbar, installert kandidat, og en ekte kobling må deretter prøves med brukerens vanlige godkjenning. Ingen koblingsbillett er bedt om, ingen identiteter er slått sammen, og ingen godkjenning er utført her.
