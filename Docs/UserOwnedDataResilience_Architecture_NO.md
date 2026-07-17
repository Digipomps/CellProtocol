# Brukereid dataresiliens i et desentralisert HAVEN

Status: arkitekturvedtak og implementert CellProtocol-kjerne (`v0`)  
Dato: 2026-07-17  
Omfang: CellProtocol-kontrakter, kryptografi, erasure coding, EntityAnchor-integrasjon og kontrakttester

## Konklusjon

HAVEN bør behandle oversikten over brukerdata som et lite, privat og
distribuert **kontrollplan**, ikke som en kopi av alle data. Kontrollplanet er
et eier-signert, lineært og hashkjedet inventar over alle representasjoner som
HAVEN har autorisert eller observert gjennom protokollen. Store datamengder
lagres separat som krypterte fullkopier eller som erasure-kodede fragmenter.

Dette er ikke en global, usikker multi-master-database. Én Entity authority per
partisjon bestemmer kanonisk rekkefølge. Flere uavhengige noder replikerer den
signerte journalen og inventaret. Konflikt, rollback, manglende kvittering eller
utløpt grant skal gi `degraded` eller `unrecoverable`, aldri optimistisk
«healthy».

Standard backup-profil er **4+2 systematisk Reed–Solomon**:

- data krypteres og signeres før oppdeling;
- seks metadata-bundne ciphertext-fragmenter plasseres i seks deklarerte
  feildomener;
- hvilke som helst fire gyldige fragmenter rekonstruerer ciphertext;
- to fragmenttap kan tåles;
- plassbehovet for selve shard-dataene er omtrent 1,5 ganger ciphertext, pluss
  små manifester og kvitteringer;
- reparasjon av manglende fragmenter trenger ikke dekrypteringsnøkkelen.

4+2 er et forsvarlig utgangspunkt, ikke en universell konstant. Store eller
svært kritiske datasett bør kunne velge en annen `k+m`-profil etter målt risiko,
reparasjonsfrekvens og kostnad.

## Formål og mål

### Formål F1 — brukeren skal beholde faktisk kontroll

| Mål | Verifiserbart kriterium |
|---|---|
| G1.1 Komplett autorisert oversikt | Hver protokollautorisert representasjon har dataset-, versjons-, representasjons-, innholds-, custodian- og feildomenebinding. |
| G1.2 Ingen skjult autorisasjon | Lagring teller bare med eier-signert grant. En rute eller transportleveranse er ikke lagringsrett. |
| G1.3 Kontrollerbar sletting | Alle kjente autoriserte kopier kan adresseres for sletting; manglende bekreftelse forblir synlig. |

### Formål F2 — tap av scaffold skal ikke bety tap av forståelse eller data

| Mål | Verifiserbart kriterium |
|---|---|
| G2.1 Inventaret overlever hjemmet | Minst tre ferske inventarreplikaer i tre deklarert uavhengige feildomener. |
| G2.2 Bootstrap overlever | Minst to kvitterte kopier av gjeldende Recovery Root i to feildomener. |
| G2.3 Datasett kan gjenopprettes | Minst én fersk fullkopi eller minst `k` gyldige fragmenter, og minst én tilgjengelig recovery-nøkkel. |
| G2.4 Tap oppdages før katastrofen | Periodisk read-back/full restore oppdaterer signerte kvitteringer; gammel kontroll gjør status degradert. |

### Formål F3 — backupen skal være brukerens

| Mål | Verifiserbart kriterium |
|---|---|
| G3.1 Custodian ser ikke klartekst | ChaChaPoly-kryptert konvolutt er input til erasure coding. |
| G3.2 Flere bruker-kontrollerte veier inn | Innholdsnøkkelen pakkes separat til minst to recovery-nøkler. Dette er alternative nøkler, ikke 2-av-n terskelkryptografi. |
| G3.3 Ruter røpes ikke i Recovery Root | Lokatorer er eier-signerte, krypterte konvolutter uten serialiserte mottaker-UUID-er. Klartekstlokator avvises. |
| G3.4 Manipulasjon feiler lukket | Signatur, associated-data-kontekst, manifesthash, fragmenthash og rekonstruert payload-hash må alle stemme. |

## Påstander, motargumenter og vedtak

### P1 — «En content hash/CID er nok til å finne data igjen»

Motargument: En innholdsidentifikator identifiserer bytes, men sier ikke hvor de
er lagret. IPFS-dokumentasjonen sier eksplisitt at CID ikke angir lokasjon, og
livsløpsdokumentasjonen viser at pinning fortsatt kan feile dersom ingen
providers er tilgjengelige. Vedtak: inventaret må binde innhold til en
eier-kryptert lokator, custodian-identitet, grant, varig kvittering og
feildomene. [IPFS CID](https://docs.ipfs.tech/concepts/content-addressing/),
[IPFS data lifecycle](https://docs.ipfs.tech/concepts/lifecycle/)

### P2 — «Distribuer inventaret som en fri multi-master CRDT»

Motargument: Samtidige tilføyelser kan slås sammen, men destruktive operasjoner,
eierskifte, grant-utløp og rollback krever én autoritativ orden. En CRDT kan
senere brukes til ikke-autoritative observasjoner, men skal ikke avgjøre hvem
som har lagringsrett eller hvilken sletting som er kanonisk. Vedtak: behold
eksisterende EntityAuthority som single-writer, signert hashkjede; repliker
journalen og bruk CAS på revisjon/hodehash.

### P3 — «En transport-ACK betyr at backupen finnes»

Motargument: Den beviser bare levering til et transportlag. Den sier ikke at
bytes kan leses tilbake etter restart eller strømbrudd. Vedtak: nivået
`transport_delivery_only` er eksplisitt forbudt som storage receipt. Kvittering
må angi durability-nivå og en kontrolltype. `full_restore` er sterkest. NIST
fremhever både recovery catalog, geografisk/kopimessig fordeling, isolasjon og
restoration assurance. [NIST SP 800-209](https://csrc.nist.gov/pubs/sp/800/209/final)

### P4 — «RAID-5-lignende paritet er backup»

Motargument: Paritet beskytter mot enkelte fragmenttap, men ikke mot
ransomware, logisk sletting, korrupte nøkler eller at alle shards ligger i
samme feildomene. Vedtak: immutable versjoner + kryptering + erasure coding +
uavhengige feildomener + separat Recovery Root + testet gjenoppretting. Reed–
Solomon-egenskapen er at hvilke som helst `k` mottatte elementer kan rekonstruere
de `k` kildeelementene. [RFC 5510](https://datatracker.ietf.org/doc/rfc5510/)

### P5 — «Det holder å sikkerhetskopiere ciphertext»

Motargument: Uten nøkkel er korrekt ciphertext permanent utilgjengelig. Vedtak:
hver backup pakker en tilfeldig innholdsnøkkel til flere recovery-identiteter.
Nøklene må selv ligge i uavhengige, bruker-kontrollerte vaults eller
gjenopprettingsmedier. NIST beskriver uavhengig, sikker backup av nødvendig
nøkkelmateriale og påpeker at kryptert informasjon ikke kan gjenopprettes når
dekrypteringsnøkkelen er borte.
[NIST SP 800-57 Part 1 Rev. 5](https://nvlpubs.nist.gov/nistpubs/specialpublications/nist.sp.800-57pt1r5.pdf)

## Trusselmodell

Dette designet skal håndtere:

- permanent eller midlertidig tap av hjem/scaffold;
- disk-, prosess-, nettverks- og leverandørfeil;
- to samtidige fragmenttap med standardprofilen;
- korrupte eller manipulerte fragmenter og manifester;
- stale/rollback av inventar;
- en custodian som påstår lagring uten godkjent eier-grant;
- lekkasje av fragmenter eller Recovery Root uten recovery-nøkkel;
- utløpte grants og kontroller som ikke er fornyet;
- manglende bootstrap-kopier, som skal gjøre helsen synlig dårlig.

Designet kan ikke alene håndtere:

- hemmelige kopier tatt etter at en mottaker lovlig har fått klartekst;
- en custodian som lyver med gyldig nøkkel uten at eieren noen gang gjør
  read-back/full restore;
- kompromiss av alle eierens recovery-nøkler;
- korrelerte feildomener som feilaktig er deklarert som uavhengige;
- kompromiss av eierens signeringsautoritet;
- juridisk eller fysisk sletting hos en ikke-samarbeidende tredjepart.

«Alle representasjoner» betyr derfor alle representasjoner som er opprettet,
autorisert eller rapportert gjennom protokollen. Ingen desentralisert protokoll
kan oppdage en skjult kopi hos en ondsinnet part etter klartekstutlevering.

## Kontrollplan og datamodell

### 1. Storage Grant

`UserDataStorageGrant` er signert av eieren og binder nøyaktig:

- inventar, dataset, versjon og representasjon;
- representasjonstype;
- innholdshash og byteantall;
- custodianens offentlige signeringsidentitet;
- feildomene;
- commitment til kryptert lokator;
- capability `userData.representation.store`;
- gyldighetsvindu.

### 2. Storage Receipt

`UserDataStorageReceipt` er signert av den custodianen granten navngir. Den
binder samme bytes og grant-hash, tidspunkt, durability-nivå og verifikasjon.
Transportleveranse avvises. En kvittering er fortsatt en custodian-påstand;
periodisk eier-initiert full restore er sterkere evidens.

### 3. Representasjonsinventar

`UserDataInventorySnapshot` er privat, eier-signert og kan serialiseres som
`ValueType`. Revisjon `n` peker med hash på revisjon `n-1`. Postene er sortert
kanonisk og duplikater avvises. Snapshotet verifiserer historisk evidens ved
snapshot-tid; helseberegningen validerer grant/receipt på nytt mot nåtid. Dette
gjør at et gammelt snapshot ikke mister sin signaturverdi fordi en grant senere
utløper.

Inventaret lagres under `dataInventory` i Apple- og Vapor-variantene av
`EntityAnchorCell`, og endringer går gjennom eksisterende owner-authorized
EntityAuthority-journal. Dermed arver det journalens CAS, hashkjede, replay og
replikakvitteringer.

### 4. Recovery Root

`UserDataRecoveryRoot` er det lille bootstrap-objektet som løser rekursjonen
«hvor ligger kartet som forteller hvor kartet ligger?» Den binder:

- gjeldende inventarrevisjon og snapshot-hash;
- policy-hash;
- hashkjede til forrige root;
- krypterte lokatorer og kvitteringshash for inventarreplikaene;
- eieridentitet og signatur.

Lokatorene er faktiske ChaChaPoly-konvolutter bundet med associated data til
inventar og representasjon. Klartekst, feil binding og feil signatur avvises.
Helse kan bare bli `healthy` når gjeldende root og minst to ferske,
custodian-kvitterte root-kopier i to feildomener legges ved vurderingen. Root-
kopiene ligger utenfor snapshotet for å unngå en kryptografisk sirkel der
snapshotet må inneholde hash av rooten som selv inneholder snapshot-hashen.

### 5. Recovery health

`UserDataRecoveryEvaluator` returnerer `healthy`, `degraded`, `unrecoverable`
eller `unknown` med maskinlesbare årsaker. Standard `healthy` krever:

- tre ferske inventarreplikaer i tre feildomener;
- gyldig Recovery Root;
- to ferske root-kopier i to feildomener;
- for hvert datasett enten komplett 4+2-sett i seks feildomener og minst to
  recovery-key-commitments, eller en strengere konfigurert policy.

Fire av seks fragmenter er fortsatt gjenopprettbart, men degradert og skal
utløse reparasjon. Tre av seks uten fullkopi er `unrecoverable`.

## Dataplan: kryptert 4+2

`UserOwnedBackupCodec` gjør følgende i denne rekkefølgen:

1. genererer tilfeldig ChaChaPoly-innholdsnøkkel;
2. pakker nøkkelen separat med X25519/HKDF-SHA256 til hver recovery-identitet;
3. signerer autentisert header + ciphertext med eierens Ed25519-nøkkel;
4. serialiserer konvolutten kanonisk;
5. deler ciphertext-konvolutten i fire systematiske datashards;
6. lager to Reed–Solomon-paritetsshards over GF(256);
7. hasher hvert fragment sammen med all kritisk metadata;
8. signerer manifestet som binder alle fragmenthashene.

Dette følger samme sikkerhetsrekkefølge som Tahoe-LAFS-arkitekturen: krypter
først, erasure-kod deretter, verifiser/repair ciphertext uten å dele
dekrypteringsnøkkelen.
[Tahoe-LAFS architecture](https://tahoe-lafs.readthedocs.io/en/tahoe-lafs-1.12.1/architecture.html)

## Gjenopprettingsprosedyre ved tapt hjem

1. Last den nyeste av minst to lokalt/eksternt oppbevarte Recovery Root-kopier.
2. Verifiser eier-signatur, root-kjede og policy-hash.
3. Åpne en inventory-lokator med en tilgjengelig bruker-kontrollert
   recovery-identitet.
4. Hent inventory-snapshot og verifiser snapshot-hash, signatur og kjede.
5. Evaluer ferske grants/receipts. Ikke tell transport-ACK eller utløpt evidens.
6. Velg siste ønskede datasetversjon og minst fire gyldige fragmenter fra
   uavhengige feildomener.
7. Rekonstruer den krypterte konvolutten og kontroller payload-hash.
8. Åpne innholdsnøkkelen med en recovery-identitet, verifiser eier-signaturen og
   dekrypter.
9. Skriv gjenopprettet tilstand til en ny Entity authority, opprett ny
   inventarrevisjon/root og reparer redundansen tilbake til policy.
10. Marker gamle eller utilgjengelige plasseringer eksplisitt; ikke skjul dem
    ved å slette historikken.

## Implementert i denne endringen

- `UserDataErasureCoding`: deterministisk systematisk Reed–Solomon 4+2,
  rekonstruksjon, integritetskontroll og repair uten nøkkel.
- `UserOwnedBackupCodec`: encrypt-before-erasure, flere recovery-nøkler,
  owner-signert manifest og gjenoppretting.
- `UserDataOwnerSealedLocatorCodec`: kryptert og signert rutemetadata med
  offentlig validerbar konvoluttbinding.
- `UserDataStorageGrant` og `UserDataStorageReceipt`.
- `UserDataInventorySnapshot`, policy, recovery-evaluator og Recovery Root.
- privat `dataInventory`-flate i Apple/Vapor `EntityAnchorCell`.
- kontrakttester for alle 15 fire-av-seks-kombinasjoner, korrupsjon,
  utilstrekkelige/dupliserte shards, repair, feil recovery-identitet,
  signaturmanipulasjon, klartekstlokator, grant-utløp, historisk snapshot,
  anti-rollback, EntityAuthority replay, tapt hjem, manglende root, degradert og
  ugjenopprettelig tilstand.
- en deterministisk JSON-golden fixture for andre runtimer.

## Det som fortsatt mangler før produksjonspåstand

Denne endringen er et komplett protokollfundament, men ikke en ferdig distribuert
lagringstjeneste. Følgende skal ikke beskrives som implementert ennå:

1. **Custodian-adapter og faktisk durability.** Eksisterende filstore kan
   attestere atomic replace uten power-loss-bevis. Produksjon trenger konkret
   `fsync` av fil og parent directory, restarttest og read-back før det sterkeste
   receipt-nivået brukes.
2. **Replikasjons- og repairscheduler.** Ingen bakgrunnsjobb plasserer seks
   fragments, fornyer receipts, gjør restore drills eller reparerer degradering
   automatisk ennå.
3. **Transportadaptere på tvers av scaffolds.** CellProtocol-kontraktene finnes,
   men CellScaffold, Binding og eksterne custodianer må implementere den samme
   grant/receipt-protokollen. Transport skal ikke eie semantikken.
4. **Recovery UX og virkelig uavhengige vaults.** To key-commitments beviser to
   nøkler, ikke at nøklene ligger i uavhengige feildomener. Produksjon må kreve
   og teste minst to bruker-kontrollerte vault-/medieveier. Terskelkryptografi
   (for eksempel 2-av-3) er et separat designvalg; dagens modell er «én av flere».
5. **Signert slettingskvittering og retention.** Modellen har slettet-status og
   receipt-hash, men full deletion request/receipt-kontrakt og tombstone-retention
   er ikke implementert.
6. **Inventarering av eksisterende data.** Gamle Cells, filer, cacher og
   eksterne tjenester må migreres gjennom en eksplisitt scanner/import. Systemet
   kan ikke retrospektivt vite om skjulte kopier.
7. **Uavhengig kryptografisk gjennomgang og fuzzing.** GF(256)-koden er testet
   deterministisk, men bør fuzzes, kryssverifiseres mot en etablert
   implementasjon og revideres før kritiske produksjonsdata.
8. **Kryssruntime-paritet.** Kotlin/andre runtimer må bevise samme JSON,
   hashing, GF-polynom, generator og fragmenter mot golden-fixturen.

## Videre implementeringsplan

### Fase A — lokal produksjonsklar lagring

- implementer custodian-store med atomic temp write, file `fsync`, rename,
  parent-directory `fsync`, exact read-back og restarttest;
- generer storage receipt bare etter verifisert durability;
- bygg immutable backup-sett og behold minst én tidligere god versjon;
- bygg property/fuzz-tester for tilfeldige payloadstørrelser og alle tapsmønstre.

Akseptanse: prosesskill/strømbruddsimulering mister ikke kvitterte bytes, og
full restore lykkes etter restart.

### Fase B — controller og kontinuerlig kontroll

- inventory scanner for alle CellProtocol-persistensflater;
- idempotent placement-controller for 4+2 og tre inventarreplikaer;
- planlagte hash-challenges, periodiske full restores og receipt-fornyelse;
- automatisk repair til ny feildomene ved degradering;
- observability uten plaintext-lokatorer eller sensitive datasettnavn i logger.

Akseptanse: tilfeldig tap av to shards og hele hjemmescaffoldet repareres uten
tap; tap av tre shards varsles som ugjenopprettelig før historikk overskrives.

### Fase C — kryss-scaffold og ekstern custodian

- map grant, fragment, receipt, inventory replay-range og root placement over
  eksisterende bridgeprotokoll;
- bruk replay/CAS for metadata; aldri la WebSocket/QUIC/IPC avgjøre commit;
- konfigurer eksplisitte, målte feildomener og avvis korrelerte plasseringer.

Dette krever koordinerte endringer i andre HAVEN-repositorier og bør gjøres i
egne branches/PR-er etter eksplisitt avklaring av hvilke scaffolds og
lagringsleverandører som er i første pilot.

### Fase D — nøkkel- og slettingslivsløp

- recovery-policy med uavhengighetsbevis, rotasjon og tapstest;
- vurder 2-av-3 terskel for høyrisiko-brukere uten å sentralisere kontroll;
- signed deletion request/receipt, tombstones og kontrollert garbage collection;
- dokumenter hva «slettet» kan og ikke kan garantere hos tredjepart.

## Beslutningsporter før pilot

Piloten skal ikke kalles robust backup før alle disse er sanne:

- minst tre kvitterte inventory-replikaer i tre reelt uavhengige feildomener;
- minst to kvitterte Recovery Root-kopier i to feildomener;
- seks fragmenter fordelt slik at en felles feil ikke tar mer enn to;
- minst to faktisk uavhengige bruker-kontrollerte recovery-key-veier;
- automatisert full restore fra fire fragments er kjørt etter restart;
- receipt-renewal og repair er aktivt overvåket;
- en dokumentert recovery drill er utført av en person som ikke bygget
  backupjobben;
- gamle autoriserte kopier har kjent retention/slettestatus.

NIST anbefaler et oppdatert recovery-katalog over hver kopi, minst like sterk
kryptering for backup, isolasjon av recovery copies og kontroll av at alle
kritiske komponenter faktisk kan gjenopprettes. Disse punktene er derfor
akseptansekriterier, ikke bare fremtidige forbedringer.
[NIST SP 800-209 PDF](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-209.pdf)
