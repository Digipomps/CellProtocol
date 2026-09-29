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

## Beslutning 23.09.2026: skills er både graf og annonsering

Kjetil, på spørsmålet om skills skal være annonserte formål heller enn egne poster: **begge
deler.** Brukeren har en formålsgraf som beskriver alle skills brukeren har digitalt. Et
subsett kan annonseres, og hva som annonseres varierer med konteksten — som må være rikt nok
beskrevet i perspektivet.

Det betyr én lagring og mange visninger: grafen er stedet skills bor, annonseringen er et utvalg
av den. Det er samme mønster som resten av modellen — lager pluss avledet visning — og det
lukker dobbeltheten: `person.skills[]` kan ikke være en andre sannhet ved siden av grafen.

### Hva som allerede finnes

Dette er målt i koden, ikke antatt:

| Mekanisme | Hvor | Hva den gjør |
|---|---|---|
| `advertise(for identity:)` | `Cells/GeneralCell/GeneralCell.swift:1523`, kalt fra `CellResolver.swift:3016` | annonsering er allerede per spørrer — cellen svarer ulikt ut fra hvem som spør |
| Annonserte formål | `Cells/Commons/EntityAtlasInspectorCell.swift:298,326` | «celler som annonserer dekning for et formål», og «annonserte formål for en celle-id» |
| `InterestCondition` | `PurposeAndInterest/Constraint.swift:83` | `always`, `purposeSolvedWithin`, `metadataFreshness` — betingelser for **når** en node gjelder |
| Kontekstbundet synlighet | `conference.publicProfiles`, `visibilityPolicies`, `defaultPublicProfileId` | felt-nivå synlighet, men bundet til konferansedomenet |

Annonsering av formål finnes altså allerede, og den er allerede kontekstavhengig i én forstand:
hvem som spør.

### Hva som mangler

`InterestCondition` uttrykker **når**, ikke **for hvem eller i hvilken sammenheng**.
`conference.visibilityPolicies` uttrykker sammenheng, men bare for konferanse.
Det finnes ingen generell måte å si «dette utsnittet av formålsgrafen min annonseres i
kontekst C».

`person.skills[]` (`label`, `level`, `taxonomyRef`, `evidenceRefs`) står fortsatt som egne
poster. **Avgjort 25.09: de utgår.** Skills er formålsnoder i grafen.

### Friksjon som må løses

`Purpose.goal` er påkrevd. En skill uttrykt som formål må derfor si hva oppfyllelse er.
«Jeg kan lage nettsider» blir «jeg kan levere en nettside som gjør X». Det er trolig en styrke —
det tvinger en målbar leveranse fram i stedet for en løs etikett — men det er en reell endring
i hva en skill er, og den bør være villet.

### Avklart 25.09.2026: konteksten bor i PerspectiveCell

Kjetil: aktiv kontekst holdes i `PerspectiveCell`. Der legges spor etter alt brukeren foretar
seg i forhold til formål, interesser, endring av entiteter og relevante CellConfigurations.
**Skills er bare formål.**

Det avslutter to ting. Konteksten er ikke en ny type og ikke avsenderidentiteten — den er levende
tilstand utledet av aktivitet. Og `person.skills[]` utgår: en skill er en formålsnode i grafen,
ikke en egen post.

Målt i koden:

| Det som finnes | Hvor |
|---|---|
| `perspective.state` | `Sources/CellApple/PurposeAndInterest/Cells/PerspectiveCell.swift` |
| `perspective.query.activePurposes` | samme fil, linje 164 |
| `perspective.query.interestsFromActivePurposes` | linje 173 |
| `perspective.query.match` | linje 182 |
| `addPurpose`, `addMatchers` | samme celle, endepunkt `cell:///Perspective` |
| Læring og forfall av vekter | `PurposeAndInterest/RelationalLearningModels.swift` — `decayProfileId`, `decayParams`, `decayPolicyUpdated` |

Aktiv kontekst som spørring finnes altså allerede, og maskineriet som flytter vekter over tid
er under arbeid i glemmetermen.

**Det som mangler er sporene selv.** `Perspective.getActivePurposes` (`Perspective.swift:958`)
filtrerer på vekt og sorterer på vekt — ikke mer. Ingenting skriver «brukeren gjorde X i
forhold til formål P, interesse I, entitet E, konfigurasjon C» inn i perspektivet. Konsumentene
finnes, matematikken er under bygging, inngangen finnes ikke.

Det er også inngangen relasjonene skal vokse ut av. Uten spor har «relasjoner vokser seg frem av
interaksjoner» ingen kilde.

### Åpent

Sporets form: hva registreres, hvor grovt, og hvor lenge. Ikke avgjort.

## Hva som gjenstår

- skrive formen inn i skjemaet og eksempelet
- `proofs.index.byKeypath`: besluttet bygget ved dekoding, men sperret på prerequisittet over
- eksponeringskontrakten for uuid: hva krysser wire
- migrere `bokprosjekt`-gruppene til `groups`
- tester mot funksjon og formål før noe går mot `main`

## Meldt

Vegar er orientert 22.09.2026 (`losen-vegar-groups-uuid-20260922-1`), med beskjed om at dette
er besluttet og ikke implementert, og hva han trygt kan bygge på i mellomtiden.
