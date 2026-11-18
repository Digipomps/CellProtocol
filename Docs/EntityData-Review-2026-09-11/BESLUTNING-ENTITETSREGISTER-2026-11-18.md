# Beslutning 18.11.2026: ett entitetsregister

Kjetil besluttet dette 17. og 18.11.2026, da han gikk gjennom forslag 1 i
[SAMMENDRAG-KONFERANSEDELING-2026-09-24.md](SAMMENDRAG-KONFERANSEDELING-2026-09-24.md)
(som ligger på grenen `arendalsuka-navigationbar-icon-support`).
**Beslutningen er ført inn i målskjemaet. Den er ikke implementert i Swift.**
`EntityData.review.schema.json` viser fortsatt det koden lagrer i dag.

## Hvorfor

Beslutningene 22.09 og 23.09 sa at hver entitet bor ett sted, nøklet på uuid, og at alt annet
refererer dit. Målskjemaet etter 25.09 hadde snudd dette på hodet.
`relations.entities.<uuid>` inneholdt bare `identityRefs` og `contactEndpointRefs`, og den
fullstendige `entityRepresentation` lå inne i hver relasjonspost,
`relations.records.<rel>.entityRepresentation`, som et påkrevd felt. Representasjonen var dermed
eid av relasjonen, og to relasjoner til samme entitet ga to kopier.

## Beslutningen

1. **Ett register ved roten: `entities.<entity-uuid>`.** Hver post har `kind` og hele
   `entityRepresentation`. Et oppslag på uuid trenger ikke vite om uuid-en gjelder et
   individ, en organisasjon, en gruppe eller en konferanse. Alle ligger i samme register.
2. **Hva relasjonen heter, bestemmer eieren.** Entiteten finnes uten at man vet noe om
   relasjonen. `relations.records.<rel>.subject.entityRef` er påkrevd og er en uuid i `entities`.
   Relasjonsposten bærer ikke lenger `entityRepresentation`.
3. **Grupper er entiteter.** Hver gruppe står i `entities` med `kind = group`. Navnet ligger i
   `entityRepresentation.name`. `groups.<uuid>` beholder bare `members` og `partOf`.
   `groups.<uuid>.name` er tatt ut, fordi navnet ellers ville ligget to steder.
4. **Konferanser nøkles per entitet: `conference.<entity-uuid>`.** Uuid-en er en post i
   `entities` med `kind = event`. Den gamle unøklede skiven er nå formen på hver enkelt skive.
5. **Perspective er avledet.** Det som finnes i Perspective, har sin kilde til sannhet i
   EntityData. `entityRepresentationReferencesDict` bygges fra registeret og er ikke et eget lager.

`kind` kan i dag ha verdiene `person`, `organization`, `group` og `event`. Listen er et forslag
og kan utvides ved en ny beslutning.

## Lagring og tilgjengelighet

Eierens EntityData er den logiske kilden til sannhet. Det betyr ikke at én enhet er det.
Kjetil bruker iPhone, iPad, Mac og sky, og det mest tilgjengelige stedet er ikke nødvendigvis
telefonen eller den lokale Mac-en. Registeret må derfor kunne ha replikaer på flere enheter og i
sky, og et oppslag går til den replikaen som er tilgjengelig.

Valg av replika, synk og konflikthåndtering er en egen lagringskontrakt som ikke er skrevet.
For store registre er en B-tre-indeks eller database en lagringsimplementasjon. Da trenger ikke
alt ligge i minnet. Dette står bevisst ikke i skjemaet.

## Hva som er gjort

- Nytt byggesteg: [apply_decisions_2026_11_18_entity_register.py](apply_decisions_2026_11_18_entity_register.py),
  som kjøres etter skills-steget fra 25.09.
- Kontroll: [validate_decisions_2026_11_18_entity_register.py](validate_decisions_2026_11_18_entity_register.py)
  med resultatet i [TARGET-VALIDATION-2026-11-18-ENTITY-REGISTER.json](TARGET-VALIDATION-2026-11-18-ENTITY-REGISTER.json).
  Det gir 31 nye kontroller, og alle eldre regresjonssuiter (22.09, 23.09, undergrupper og skills) går grønt.
- Skjemaet avviser den gamle formen: `relations.entities`, `entityRepresentation` i relasjonsposten,
  `name` i `groups`, en relasjon uten `entityRef`, og en entitet uten `kind` eller representasjon.
- Referansekontrollen avviser en ukjent entitet, en gruppe som medlem, en `groups`-nøkkel som ikke er
  `kind = group`, en konferanse som ikke er `kind = event`, et bevis med ukjent `supports.entityRef`,
  en ukjent identitet og en `partOf`-sykel.
- Eksempelet er fiktivt. Det har to personer, et forlag (organisasjon) som er medlem av en gruppe
  sammen med en person, seks grupper og én konferanse med en tom deltakerskive.

## Ikke besluttet

Følgende står som `deferredDecisions` i skjemaet:

- forslag 2, `conference.<uuid>.cells[]`, som må avklares mot `scaffoldPresence.mounts`/`bindings`
- forslag 3, `conference.<uuid>.matchConsent`
- forslag 4, grant-betingelsen «gyldig medlemskapsbevis med `supports.entityRef = X`»
- relasjonsspesifikke kanter og vekter, nå som representasjonen ligger i registeret
- lagringskontrakten for replikaer

Eierens egen rot `entityRepresentation` er ikke endret.

## Hva som gjenstår

- implementere registeret, referansekontrollene og den avledede Perspective-visningen i Swift
- migrere eksisterende `relations.entities` og `relations.records.*.entityRepresentation`
- endre EntityAnchorCell, som i dag skriver `relations.entities.<uuid>.identities.<id>`
- skrive lagringskontrakten for replikaer på tvers av enheter og sky

Gjenoppbygg og kontroller med:

```bash
python -B apply_decisions_2026_11_18_entity_register.py
python -B validate_decisions_2026_11_18_entity_register.py
```
