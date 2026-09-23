# EntityData v2 — løpende målmodell

Oppdatert 23.09.2026. Målskjemaet er én fil som utvikler seg. Beslutningene fra
[22.09 og avklaringen 23.09](BESLUTNING-UUID-OG-GRUPPER-2026-09-22.md#løst-23092026-følg-entityrepresentation-mønsteret)
er lagt etter [16.09-gjennomgangen](GJENNOMGANG_KJETIL_2026-09-16.md).
Undergruppesteget fra 23.09 følger deretter; det innfører `partOf` og tar ut
`relations.bokprosjekt` fra målskjemaet. Åpne detaljer er fortsatt åpne.
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

- `groups.<group-uuid>` har påkrevd `name` og `members`, samt valgfri `partOf`
  med foreldregruppens uuid. En rotgruppe har ingen forelder. Barnet peker oppover;
  barnelisten persisteres ikke, men bygges ved dekoding som alle andre bakveier.
  Gruppeobjektet tillater bare disse tre feltene. `members` er en flat, uvektet
  liste med bare entitets-uuid-er til `relations.entities`. Gruppe-uuid-er i
  `members` skal avvises. Som de andre røttene er `groups` valgfri.
- `relations` beholder ni reserverte nøkler, inkludert `validatedContacts`.
  `relations.bokprosjekt` er tatt ut og erstattet av `groups`-roten.
  Den gamle formen og eierdefinerte navngitte lister avvises med
  `additionalProperties: false`.
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
- Eksempelet beholder de to entitetene og gruppene Venner og Samarbeidspartnere. I tillegg
  har det tre nivåer med fiktive navn: prosjektet «Bokverkstedet ved Månesjøen»,
  kapittelet «Broer mellom ideer», og to arbeidsgrupper under samme kapittel.
  Prosjekt-uuid ender på `0003`, kapittelet på `0004`, arbeidsgruppene på `0005`
  og `0006`. Entitetene er medlemmer i hver sin arbeidsgruppe. Alle referanser
  kontrolleres mot eksempelets kart; UUID-prefiksene er ingen typekontrakt.

JSON Schema kontrollerer UUID-syntaks, ikke om en UUID finnes i et annet kart.
Dokumentasjonsvalidatoren kjører derfor en separat kontroll som avviser gruppe-
og relasjons-uuid-er i `members`, ukjente entiteter og ugyldige gruppeforeldre.
JSON Schema kan heller ikke fange sykler i `partOf`; dekoderen må avvise sykler,
inkludert selvreferanser. Negative prøver viser at skjemaet alene slipper gjennom
disse semantiske feilene, mens referansekontrollen avviser dem. Dette er Python-
kontroller av komplette lokale kart, ingen implementert Swift-dekoder.
Se [Draft 2020-12, strukturell validering](https://json-schema.org/draft/2020-12/json-schema-validation#section-3)
for skillet mellom skjemakontroll og dokumentets øvrige semantikk.

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

**`relations.bokprosjekt` er fjernet fra målskjemaet.** Runtime-grunnlaget
`EntityData.review.schema.json` og dagens kode beholder den gamle formen.
Migrering av ekte data gjenstår: det trengs autoritative koblinger fra mottakere
til entitets-uuid-er og fra gamle grupper til gruppe-uuid-er i `groups`.
Det nye fiktive treet er ikke en migrering av brukernes bokprosjekter.

Utover `groups`, fjerningen av `relations.bokprosjekt` og tilhørende beskrivelser/
metadata er bevisstegets datakontrakt uendret, inkludert alle delte `$defs`.
De øvrige spesialiserte undertrærne i `proofs` er bevart.
Åpne detaljer om endpoints, scaffold-tilstedeværelse, identitetslikhet
og wire-eksponering er fortsatt uavklart.
[16.09-notatet](OPPDATERT-ETTER-GJENNOMGANG-2026-09-16.md) beskriver det historiske
mellomsteget; det er ikke en konkurrerende gjeldende målform.

## Reproduksjon og kontroll

Fra denne mappen, med [requirements-target.txt](requirements-target.txt) installert:

```sh
python -B -O apply_decisions_2026_09_23_groups.py
python -B -O validate_decisions_2026_09_23_groups.py
```

Hele kjeden 16.09 → 22.09 → 23.09 → undergrupper bygges i minnet før noe
skrives. Manglende mål, uventet inngangsform og gjentatt anvendelse gir feil,
også med `python -O`. Ny bygging fra runtime-grunnlaget gir identiske byte.
Ikke kjør et tidligere byggesteg alene mot gjeldende filer; det skriver en
historisk mellomform. `build_v2_schema.py` brukes ikke.

I dette miljøet brukes den eksisterende lokale Ajv-banen eksplisitt:

```sh
export ENTITYDATA_AJV_MODULE=/usr/local/lib/node_modules/@nestjs/cli/node_modules/ajv
export ENTITYDATA_AJV_FORMATS_MODULE=/usr/local/lib/node_modules/@nestjs/cli/node_modules/ajv-formats
python3 -B -O apply_decisions_2026_09_23_groups.py
python3 -B -O validate_decisions_2026_09_23_groups.py
```

Begge validatorbaner kontrollerer formater. Se faktisk motor, positive/negative
kontroller og filsummer i [TARGET-VALIDATION-2026-09-23-GROUPS.json](TARGET-VALIDATION-2026-09-23-GROUPS.json)
og [jobbrapporten](../../../CellProtocolDocuments/Deliverables/GRUPPER_PARTOF_2026-09-23.md).
Den nye suiten kjører også de uendrede 22.09-/23.09-suitene på deres historiske
målform i en midlertidig kopi. Gjeldende mål og historiske resultatfiler overskrives ikke.

**Visualiseringssjekkene: ikke kjørt.** Den historiske suiten leser utdaterte
16.09/17.09-artefakter utenfor repoet. Oppdaterte undergruppeartefakter og en
oppdatert suite mangler. Swift/runtime, ekte dekoding og migrering er også
**ikke kjørt**: denne oppgaven endrer dokumentasjon og målskjema.
