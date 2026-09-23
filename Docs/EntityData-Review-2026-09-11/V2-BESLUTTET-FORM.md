# EntityData v2 — løpende målmodell

Oppdatert 23.09.2026. Målskjemaet er én fil som utvikler seg. Beslutningene fra
[22.09 og avklaringen 23.09](BESLUTNING-UUID-OG-GRUPPER-2026-09-22.md#løst-23092026-følg-entityrepresentation-mønsteret)
er lagt etter [16.09-gjennomgangen](GJENNOMGANG_KJETIL_2026-09-16.md).
Åpne detaljer er fortsatt åpne.
Dette er dokumentasjon og målstruktur; ingen Swift-implementasjon eller migrering er utført.

| Fil | Rolle |
|---|---|
| [EntityData.v2.schema.json](EntityData.v2.schema.json) | Det ene gjeldende målskjemaet. |
| [EntityData.v2.example.json](EntityData.v2.example.json) | Fiktivt eksempel i målformen. |
| [EntityRepresentation.v2.schema.json](EntityRepresentation.v2.schema.json) | Grafutsnitt med identiske delte definisjoner fra målskjemaet. |
| [current-review.json](current-review.json) | Peker til gjeldende filer, beslutningskilder og byggekommando. |
| [EntityData.review.schema.json](EntityData.review.schema.json) | Urørt runtime-grunnlag; beskriver den undersøkte lagringsformen i koden. |

Filnavn og eksisterende `$id` er beholdt. Datoen i `$id` er opprinnelse;
`x-haven.decisionsAsOf` og `current-review.json` angir innarbeidet beslutningsdato.
Ingen ny datamodellversjon eller wire-eksponeringskontrakt er vedtatt her.

## Beslutningene 22.09 i målskjemaet

- `groups.<group-uuid>` har påkrevd `name` og `members`. Gruppen er en uvektet,
  flat medlemsliste; relasjoner bærer den vektede perspektivgrafen. Gruppesobjektet
  tillater bare disse to feltene. Medlemmer er entitets-UUID-er til
  `relations.entities`, uten vekter eller innebygde kopier. Bakveien bygges ved
  dekoding, i minnet. Som de andre røttene er `groups` valgfri i en delvis EntityData.
- `relations` beholder alle ti reserverte nøkler fra 16.09-steget, inkludert
  `validatedContacts` og det utsatte `bokprosjekt`-undertreet. Eierdefinerte
  navngitte lister avvises med `additionalProperties: false`.
- `relations.entities`, `relations.identities`, `relations.records` og `groups`
  krever UUID-nøkler gjennom `propertyNames.pattern`. 23.09-steget håndhever nå
  også kravet for `records`, med `maxLength: 36`. Det fiktive eksempelets
  `relation-demo` blir fast UUID `40000000-0000-4000-8000-000000000001`.
  Kontaktpostens nøkkel, begge `relationID`-felt, kontaktstien og den fiktive
  celleadressen omskrives sammen. Validatorfixturen bruker i tillegg
  `40000000-0000-4000-8000-000000000002` for `rellea` og kontrollerer omskriving
  av både `supports.keypaths` og `proofs.index.byKeypath`. Ukjente forekomster,
  kollisjoner og uoppløselige lokale stier stopper transformasjonen.
- `relations.identities.*.entityRefs` og `relations.entities.*.relationRefs`
  er fjernet og eksplisitt forbudt, også når postene ellers er åpne objekter.
  `relations.entities.*.identityRefs` og `relations.records.*.subject.entityRef`
  beholdes. Beskrivelsene sier at motsatt retning bygges ved dekoding, i minnet.
- Eksempelet har to entiteter og to grupper: Venner inneholder begge, og
  Samarbeidspartnere inneholder den ene. Den eksisterende relasjonsposten peker
  på denne entiteten; entiteten peker på én identitet. Alle nye referanser
  kontrolleres mot eksempelets kart.

JSON Schema kontrollerer UUID-syntaks, ikke om en UUID finnes i et annet kart.
Den nye validatoren har derfor en separat referansekontroll for det fiktive
eksempelet og en negativ test der en relasjons-UUID feilaktig brukes som medlem.
Dette er ingen implementasjon av generell referanseoppløsning eller identitetslikhet.

## Bevismønsteret 23.09 i målskjemaet

`proofs.credentials` er det ene persisterte, flate lageret for bevispostene,
nøklet på bevis-uuid med samme `propertyNames.pattern` som de øvrige UUID-kartene.
Posten har de seks feltene etterspurt fra `VCClaim`: `uuid`, `type`, `issuer`,
`issuanceDate`, `credentialSubject` og `proof`, samt det nye, påkrevde `supports`.
Målposten krever alle sju og tillater ingen andre toppfelter. `issuer` er streng
eller objekt, `type` er en strengliste, `issuanceDate` er RFC3339, og
`credentialSubject` og `proof` er objekter. Deres interne felter er ikke utvidet her.
Dette er ikke en komplett Swift-/VC-wire-kontrakt.

`supports` er en **påstand om hva beviset understøtter**, ikke at det er gyldig.
Objektet krever `entityRef` (entitets-uuid) og `keypaths` (minst én unik, ikke-tom
nøkkelstistreng i eierens EntityData), og tillater bare disse to feltene.
Oppslag fastslår ikke sannhet, gyldighet, utstedertillit eller samtykke.
**`supports` er ikke implementert i Swift VCClaim ennå.**

Eksempelets bevispost er nøklet på `50000000-0000-4000-8000-000000000001` og bærer:

```json
"supports": {
  "entityRef": "10000000-0000-4000-8000-000000000001",
  "keypaths": [
    "relations.identities.20000000-0000-4000-8000-000000000001.domain"
  ]
}
```

Entitetspostens `identityRefs` peker på denne identiteten. Identitetspostens
`proofRefs` peker på bevisets uuid i `proofs.credentials`. Beviset er fiktivt;
`proof: {}` viser bare objektformen og er ingen gyldig kryptografisk signatur.

`proofs.index.byKeypath` beholdes som dokumentert **avledet oppslagsform**:

```json
{
  "relations.identities.20000000-0000-4000-8000-000000000001.domain": [
    "50000000-0000-4000-8000-000000000001"
  ]
}
```

Ved dekoding skal hvert bevis legges i oppslaget under sine `supports.keypaths`;
bevisposten bærer også entitetskonteksten i `supports.entityRef`. Mønsteret er
`entityRepresentationNameReferences`: oppslagsordet ligger på objektet selv
(`name` der, `supports.keypaths` her). Indeksen er ikke persistert sannhet eller
en andre kilde og skal utelates ved lagring. Den finnes derfor ikke i det lagrede
eksempelet. `index`, `byKeypath` og listene under er merket `derived: true`,
`persisted: false`, `storageDomain: memory`, `mutability: read-only` og
`runtimeImplemented: false` i `x-haven`. Dette er dokumentasjonsmetadata;
JSON Schema håndhever ikke lagringsatferd. Dekodingsmønsteret for bevis er
**ikke implementert i Swift ennå**.

Alle fire `proofRefs`/`evidenceRefs`-beskrivelser sier nå at referansene er
bevis-uuid-er inn i `proofs.credentials`: identitet, tilknytning, ferdighet og
foreløpig attributt. Listeformene er uendret, også den historisk åpne formen
på listeelementene. Referanseoppløsning, likhet mellom kartnøkkel og postens
`uuid`, samt nøkkelstiers eksistens og escaping krever separate kontroller.
Validatoren kontrollerer bare det fiktive eksempelets referanser og enkle stier;
den implementerer ingen generell nøkkelstioppløser eller Swift-dekoder.

## Bevarte sperrer og uavklarte punkter

**`relations.bokprosjekt` er helt urørt.** `members[].relation.groupRefs` og
`group` er derfor fortsatt et synlig migreringsunntak. Repoeksemplet inneholder
ikke bokprosjektmedlemmer. Runtime bruker `recipientID` og gruppe-ID/label samt
`memberRecipientIDs` i et eget gruppeuttrekk; det mangler en autoritativ kobling
fra hver mottaker til entitets-UUID og fra eksisterende grupper til gruppe-UUID
og navn i den nye roten. Å finne på slike koblinger eller persistere enda en
bakvei ville ikke gjennomføre beslutningen om én kilde til medlemskap.
Se [leveranserapporten](../../../CellProtocolDocuments/Deliverables/ENTITYDATA_UUID_GRUPPER_2026-09-22.md)
for konkrete kildebaner og hva som må foreligge før dette kan gjøres.

Utover UUID-kravet i `relations.records`, bevislageret,
indeksmetadata/-beskrivelser og de fire referansebeskrivelsene
er 22.09-skjemaets datakontrakt uendret. De øvrige spesialiserte undertrærne i
`proofs` er bevart; denne leveransen utfører ingen migrering av dem. Det samme
gjelder åpne detaljer om endpoints, scaffold-tilstedeværelse, identitetslikhet
og wire-eksponering.
[16.09-notatet](OPPDATERT-ETTER-GJENNOMGANG-2026-09-16.md) beskriver det historiske
mellomsteget; det er ikke en konkurrerende gjeldende målform.

## Reproduksjon og kontroll

Fra denne mappen, med [requirements-target.txt](requirements-target.txt) installert:

```sh
python -B apply_decisions_2026_09_23.py
python -B validate_decisions_2026_09_23.py
```

23.09-skriptet tar resultatet fra 22.09-skriptet videre. Hele kjeden
16.09 → 22.09 → 23.09 bygges i minnet. Skjema, eksempel og manifest skrives først etter at
forutsetningene og skjemavalideringen har passert. Manglende mål eller uventet
inngangsform gir feil, også med `python -O`. En ny kjøring bygger fra runtime-
grunnlaget og gir identiske byte; den anvender ikke samme steg to ganger på
allerede transformerte data. Å kjøre **bare** 16.09- eller 22.09-skriptet skriver
et historisk mellomsteg; bruk alltid 23.09-kommandoen for gjeldende målform.
Det historiske `build_v2_schema.py` brukes ikke.

Python-biblioteket var utilgjengelig i arbeidsmiljøet. Den eksplisitte lokale
Ajv-banen ble brukt til både bygging og kontroll:

```sh
export ENTITYDATA_AJV_MODULE=/usr/local/lib/node_modules/@nestjs/cli/node_modules/ajv
export ENTITYDATA_AJV_FORMATS_MODULE=/usr/local/lib/node_modules/@nestjs/cli/node_modules/ajv-formats
python3 -B -O apply_decisions_2026_09_23.py
python3 -B -O validate_decisions_2026_09_23.py
```

`target_validation.py` bruker Ajv bare når miljøvariablene er satt. Begge
validatorbaner kontrollerer formater. Resultatet oppgir faktisk brukt motor.
Se [TARGET-VALIDATION-2026-09-23.json](TARGET-VALIDATION-2026-09-23.json) og
[leveranserapporten](../../../CellProtocolDocuments/Deliverables/ENTITYDATA_BEVIS_2026-09-23.md).
22.09-validatoren kan også kjøres mot gjeldende 23.09-mål. Den kontrollerer
fortsatt grupper og enveisrelasjoner, men forventer nå 23.09-bevisformen og
håndhevede relasjonsnøkler. Resultatet angir `targetDecisionsAsOf`.
22.09-rapportens opprinnelige målinger beskriver det historiske mellomsteget.

**Visualiseringssjekkene er ikke kjørt.** Den historiske suiten leser en mappe
utenfor repoet med utdaterte 16.09/17.09-artefakter; ingen oppdaterte
23.09-artefakter er levert. Ingen visualiseringsfiler er oppdatert. Den nye
validatoren rapporterer dette som `ikke kjørt`, aldri som bestått. Før en ny
visualiseringskontroll trengs oppdaterte artefakter og en suite som måler
gjeldende målform. Swift/runtime, dekoding og ekte
migrering er heller ikke testet i denne dokumentasjonsoppgaven.
