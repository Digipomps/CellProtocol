# Beslutning 22.09.2026: uuid-nøkling, grupper som egen rot, én source of truth

Besluttet av Kjetil 22.09.2026. **Ikke implementert.** Skjemaet og koden følger den ennå ikke.
Denne filen finnes for at beslutningen ikke skal bli liggende uutført, slik gjennomgangen
16.09 ble.

## De fire beslutningene

**0. Uuid er nok.** Ingen salting er nødvendig for kollisjonssikkerhet (Kjetil 23.09).
Doc-kommentaren i `Sources/CellBase/PurposeAndInterest/PerspectiveNode.swift:69` krever i dag
«a salted, local identifier» for alt som representerer en person. Den er foreldet og må rettes,
ellers foreskriver koden noe vi har besluttet å ikke gjøre. Poenget kommentaren verner om —
at en persistert graf ikke skal være en klartekstliste over alle du kjenner — ivaretas av at en
uuid ikke bærer noe navn.

**1. Data nøkles på uuid, gjennomgående.** Der et faktum faktisk bor, er posten nøklet på en
uuid. Uuid-en opprettes når tingen opprettes, og er global i kraft av seg selv — kollisjons-
sannsynligheten er forsvinnende. Alle andre steder refererer til den. Uuid-ene trenger ikke
eksponeres; hva som krysser wire er en egen kontrakt som skal skrives.

**2. Relasjoner og grupper er to begreper, og begge trengs.** Relasjoner er vektet og bærer
perspektivgrafen. Grupper er ikke vektet. En gruppe er en flat medlemsliste.

**3. `groups` er en egen rot**, ikke eierdefinerte navngitte lister under `relations`.

**4. `groups.members` peker på entitet**, ikke på relasjon. Medlemskap handler om hvem, ikke
om hva eieren vet om dem.

Formen:

```
entities : { "<entity-uuid>"   : { … selve entitetsdataene … } }
relations: { "<relation-uuid>" : { "subject": "<entity-uuid>", … vektet graf … } }
groups   : { "<group-uuid>"    : { "name": "Venner", "members": ["<entity-uuid>", …] } }
```

## Gjensidighet persisteres ikke

Én retning lagres. Bakveier — «hvilke grupper er X med i», og tilsvarende for relasjoner —
bygges ved dekoding, i minnet. Koden har allerede mønsteret: `Weight.resolvedReference` og
`Weight.context` er `weak`, nettopp så avledede bakkanter ikke holder grafen i live.

## Én source of truth — tre kjente brudd i dagens v2

| Samme faktum lagret to steder | Tiltak |
|---|---|
| `relations.entities.*.identityRefs` ↔ `relations.identities.*.entityRefs` | persister én retning, utled den andre |
| `relations.entities.*.relationRefs` ↔ `relations.records.*.subject.entityRef` | persister én retning, utled den andre |
| `proofs.index.byKeypath` | **Besluttet 22.09: bygges ved dekoding.** Skal ikke persisteres som sannhet. Se sperren under |

## Sperre for `proofs.index.byKeypath`

Beslutningen er tatt, men den er **ikke implementerbar slik datamodellen står nå**, og det er
målt, ikke antatt:

- `proofs.credentials` er et åpent kart uten beskrevne felter i målskjemaet — ingen kontrakt.
- `VCClaim` (`Sources/CellBase/VerifiableCredentials/VCClaim.swift:62-69`) har `uuid`, `type`,
  `issuer`, `issuanceDate`, `credentialSubject` og `proof`. Ingen av dem sier hvilken av
  eierens nøkkelstier beviset understøtter.
- `ClaimSchema.subjectPath` (`TrustedIssuerCell.swift:20`) er en sti **inne i** beviset sitt
  eget `credentialSubject`, brukt til utstedervurdering. Den peker ikke ut i eierens EntityData.

Koblingen «dette beviset understøtter dette feltet hos meg» finnes altså i dag **kun** i
indeksen. Fjernes indeksen uten videre, forsvinner informasjonen — den kan ikke bygges ved
dekoding, fordi det ikke er noe å bygge den fra.

### Løst 23.09.2026: følg entityRepresentation-mønsteret

Kjetil: uuid er nok som kollisjonssikker id, og bevis skal følge samme mønster som
entityRepresentations — ett sted der alle postene ligger, og ett sted som har nøkler som
inneholder referanser.

Det mønsteret er målt i koden, og det består av tre deler:

| Del | Hvor | Persistert? |
|---|---|---|
| Lageret | `InterestsAndPurposesContainer.entityRepresentation` (`Perspective.swift:20-24`) — CodingKeys er kun `interests`, `purposes`, `entityRepresentation`, `states` | **ja**, flat liste |
| Raskt oppslag | `Perspective.entityRepresentationReferencesDict` (`Perspective.swift:133`) | nei, bygges ved dekoding |
| Oppslagsord → referanser | `Perspective.entityRepresentationNameReferences` (`Perspective.swift:132`) | nei, bygges ved dekoding |

Dekodingen fyller dem: hver dekodet post legges i `Facilitator` (`Perspective.swift:50-58`).

Overført på bevis:

- **persistert:** `proofs.credentials`, nøklet på bevis-uuid — lageret
- **bygges ved dekoding:** `byKeypath`, nøkkelsti → liste av bevis-uuid-er

De to utsagnene «bygges ved dekoding» og «samme mønster som entityRepresentations» er altså
ikke i strid. Men mønsteret krever én ting, og det er nettopp den som mangler:

**`entityRepresentationNameReferences` lar seg bygge fordi oppslagsordet — `name` — ligger på
objektet selv.** For bevis er oppslagsordet eierens nøkkelsti, og den ligger ikke på beviset.
Skal bevis følge samme mønster, må bevisposten bære det den understøtter — entitets-uuid
og/eller nøkkelsti — slik en entityRepresentation bærer navnet sitt.

Dette er konsekvensen Losen trekker av mønsteret Kjetil anviste, ikke en egen beslutning.
Rettes den ikke, er indeksen fortsatt den eneste kilden og kan ikke bygges fra noe.

## Looptrygghet

Grafen skal aldri enkode en kopi av en node den allerede har skrevet; andre forekomst skrives
som referanse. Mekanismen finnes: `Weight.encode` slår opp i `Facilitator.referenceablesDict`
og skriver `reference` hvis noden er sett før.

Svakheten i dag er nøkkelen den dedupliserer på. `PerspectiveNodeImpl.reference`
(`Sources/CellBase/PurposeAndInterest/PerspectiveNode.swift:72`) faller tilbake på `name` når
`nodeIdentifier` er nil. To følger, begge alvorlige:

- like navn kolliderer til én node — feil data, stille
- noder uten stabil identitet dedupliseres ikke — en sykel re-enkodes til disken er full

Uuid-nøkling fjerner begge: `nodeIdentifier` er alltid satt, så `reference` aldri degenererer
til navn. Nytt register per dokument; roten registreres først.

## Eksisterende gruppe-implementasjon som skal avvikles

`relations.bokprosjekt.members[].relation.groupRefs` — «Stable group refs derived from Excel
column Gruppe». Gruppemedlemskap finnes altså allerede, som refs inne i ett prosjekts undertre.
Den skal erstattes av `groups`-roten, ikke leve ved siden av.

## Hva som gjenstår

- skrive formen inn i skjemaet og eksempelet
- `proofs.index.byKeypath`: besluttet bygget ved dekoding, men sperret på prerequisittet over
- eksponeringskontrakten for uuid: hva krysser wire
- migrere `bokprosjekt`-gruppene til `groups`
- tester mot funksjon og formål før noe går mot `main`

## Meldt

Vegar er orientert 22.09.2026 (`losen-vegar-groups-uuid-20260922-1`), med beskjed om at dette
er besluttet og ikke implementert, og hva han trygt kan bygge på i mellomtiden.
