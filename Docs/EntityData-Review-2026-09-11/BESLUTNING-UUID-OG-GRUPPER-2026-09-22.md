# Beslutning 22.09.2026: uuid-nøkling, grupper som egen rot, én source of truth

Besluttet av Kjetil 22.09.2026, videreført 23.09 med bevismønster og undergrupper
og 25.09 med skills som formål.
**Besluttet, ikke implementert i Swift.** Det løpende målskjemaet følger nå beslutningene;
`EntityData.review.schema.json` viser fortsatt hva koden lagrer i dag.

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
perspektivgrafen. Grupper er ikke vektet. Hver gruppe har en flat medlemsliste over entiteter.
Grupper kan inngå i et hierarki via `partOf`, som besluttet nedenfor.

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

## Undergrupper og avviklet bokprosjekt-form — besluttet 23.09.2026

Eieren har besluttet **`partOf` på barnet**. `groups.<gruppe-uuid>` har fortsatt
påkrevd `name` og `members`, samt valgfri `partOf` med foreldregruppens uuid.
En rotgruppe har ingen `partOf`. Barnelisten persisteres ikke: den bygges ved
dekoding, som alle andre bakveier i modellen.

`members` inneholder bare entitets-uuid-er til `relations.entities`. En gruppe-uuid
skal avvises i `members`; undergrupper og entitetsmedlemskap blandes ikke i ett felt.
JSON Schema kontrollerer UUID-syntaks, men kan ikke slå opp referansetypen i et
annet dynamisk kart eller fange sykler i `partOf`. Dekoderen må avvise gruppe-uuid-er
i `members`, ugyldige foreldre og sykler, også selvreferanser. En separat Python-
kontroll i dokumentasjonsverktøyet tester disse kravene; Swift er ikke implementert.
UUID-prefiksene i eksempelet er bare faste eksempelverdier, ingen typekoding.

**`relations.bokprosjekt` er tatt ut av målskjemaet og avvises nå.** Undertreet
hadde egne `members` og `groups`, blant annet `members[].relation.groupRefs`.
Det erstattes av `groups`-roten: prosjektet er en rotgruppe, kapittelgrupper
peker til prosjektet, og arbeidsgrupper peker til kapittelgruppen med `partOf`.
`EntityData.review.schema.json` er urørt; koden lagrer fortsatt den gamle formen.
Dette er ikke en migrering av eksisterende bokprosjektdata.

Det nye steget `apply_decisions_2026_09_23_groups.py` følger etter 23.09-steget.
Eksempelet bruker oppdiktede gruppenavn og faste uuid-er, med én prosjektrot,
én kapittelgruppe og to arbeidsgrupper under samme kapittel. De eksisterende
fiktive entitetene er medlemmer i hver sin arbeidsgruppe.

## Avklart 25.09.2026: konteksten bor i PerspectiveCell

Kjetil: aktiv kontekst holdes i `PerspectiveCell`. Der legges spor etter alt brukeren foretar
seg i forhold til formål, interesser, endring av entiteter og relevante CellConfigurations.
**Skills er bare formål.**

`person.skills[]` utgår helt, også som avledet visning i målskjemaet. En skill er et
formål brukeren hevder å kunne oppfylle, med samme nodeform som ethvert annet formål.
Grafen er det ene stedet skills bor. Det innføres ingen egen `SearchPurpose` eller
`Skill`-type. Et utvalg kan annonseres etter kontekst; det gir ikke en andre lagret liste.
Sporets form, grovhet og levetid er fortsatt åpne; denne jobben implementerer ikke sporene.

**Friksjonen er villet:** `Purpose.goal` er påkrevd. En skill må derfor si hva oppfyllelse
er. En skill uten et målbart resultat kan ikke uttrykkes i denne formen. JSON Schema
krever målkonfigurasjonen, men kan ikke bevise at den faktisk måler resultatet.
Eksempelet sier at den fiktive eieren kan levere en nettside med nøyaktig tre sider,
alle tilgjengelige, og null brutte interne lenker. Ingen målecelle er implementert.

`apply_decisions_2026_09_25_skills.py` følger etter undergruppesteget fra 23.09.
Det fjerner hele `$defs.PersonProfile.skills`, inkludert `label`, `level`, `taxonomyRef`
og `evidenceRefs`. Fordi `PersonProfile` ellers er åpent, avvises nøkkelen eksplisitt
med `not: {required: [skills]}`. Den er ikke beholdt i `properties` som en visningsliste.
Den delte definisjonen oppdateres også i grafskjemaet. Besluttet, ikke implementert i Swift.

### Åpen sperre 25.09: bevis til en bestemt skill-node

`evidenceRefs` forsvinner sammen med skill-listen. Beviset må kunne knyttes til
formålsnoden fra det eksisterende lageret `proofs.credentials`. Undersøkelsen viser:

- `supports.keypaths` krever minst én unik, ikke-tom streng. Skjemaet verifiserer
  ikke at strengen løses til en node; `supports.entityRef` identifiserer entiteten,
  ikke formålsnoden.
- `EntityRepresentation.purposes` er en liste av `WeightOfPurpose`, med innebygd
  `value` eller `reference`. `Purpose.nodeIdentifier` finnes, men en kanonisk,
  stabil nøkkelsti som velger noden via denne identiteten er ikke kontraktfestet.
  Roten `purposes` har dessuten fortsatt uavklart lagringsorganisering.
- Dagens `resolve_fixture_keypath` i `apply_decisions_2026_09_23.py` og
  `fixture_errors` i `validate_decisions_2026_09_23.py` løser bare objektstier.
  Den nye kontrollen viser at både en forsøkt indekssti og en forsøkt selektorsti
  godtas som skjemastrenger, men ikke kan løses av dagens verktøy. En sti bare til
  hele `entityRepresentation.purposes` løses til listen, ikke til den bestemte noden.
- Selv en fremtidig indekssti vil være ustabil ved omordning. En kontrakt må også
  avklare hvordan bevis følger noden når kanten serialiseres som `reference` i
  stedet for `value`. Et nytt bevisfelt eller en ny selektorsyntaks er ikke vedtatt her.

**Sperren er derfor åpen:** dagens form kan lagre en påstått nøkkelsti, men vi kan
ikke hevde en stabil, verifisert beviskobling til én skill-node. `proofs.credentials`
og `supports.keypaths` beholdes byte-/strukturmessig uendret; ingen erstatning for
`evidenceRefs` oppfinnes, og eksempelet har ikke en påstått løst skill-beviskobling.
Den tidligere fiktive identitetsbeviskoblingen er bevart og kontrolleres fortsatt.
Dette er en sperre for nodeadresseringen i målkontrakten, i tillegg til at `supports`
og bevisoppslaget ennå ikke er implementert i Swift.

## Hva som gjenstår

- implementere målformen og dekodingskontrollene i Swift; skjema og eksempel er oppdatert
- implementere `supports` og dekodingsbygget `proofs.index.byKeypath`; målkontrakten er beskrevet
- avklare stabil bevissti til en formålsnode gjennom grafens lister og referanser
- eksponeringskontrakten for uuid: hva krysser wire
- migrere eksisterende `bokprosjekt`-data til `groups` med autoritative entitetskoblinger
- runtime-tester mot funksjon og formål før implementasjonen publiseres

## Meldt

Vegar er orientert 22.09.2026 (`losen-vegar-groups-uuid-20260922-1`), med beskjed om at dette
er besluttet og ikke implementert, og hva han trygt kan bygge på i mellomtiden.
