# EntityData v2 — den besluttede formen

Skrevet 2026-09-17. Dette er beslutningene fra Kjetils gjennomgang 16.09 ført inn i skjema og
eksempel, ikke bare beskrevet i prosa.

## Filene

| Fil | Hva den er |
|---|---|
| `EntityData.v2.schema.json` | Den **besluttede** formen. JSON Schema Draft 2020-12, avledet av v1-gjennomgangsskjemaet med beslutningene anvendt. |
| `EntityData.v2.example.json` | Fiktivt eksempel i den besluttede formen. Validerer mot skjemaet over. |
| `EntityData.review.schema.json` | v1. Beskriver **dagens** lagring — det koden faktisk skriver. Beholdt, ikke erstattet. |
| `EntityData.example.json` | v1-eksempel. Samme: dagens form. |

**v2 er besluttet, ikke implementert.** CellProtocol lagrer fortsatt v1. Bygg mot v2 som mål;
les v1 for å vite hva som ligger i lagringen i dag.

Verifisert 2026-09-17: skjemaet er gyldig Draft 2020-12 (`Draft202012Validator.check_schema`),
og eksempelet validerer mot det med null feil.

## Hva som endret seg


**Kontakt.** `person.contact.email`, `.phone`, `.emails[]` og `.phones[]` er borte. `endpoints[]` er den eneste kontaktformen, med `kind` (phone/email/some/url/cellReference), `label` for å skille flere av samme slag, `value` og `status`.

**Delt type.** `$defs.ContactEndpoint` defineres én gang og brukes både av `person.contact.endpoints` og `EntityRepresentation.endpoints`. Det eieren vet om andres kontaktveier har samme form som eierens egne.

**Foretrukket kanal.** `person.contact.preferredChannel` beholdt; dubletten under `person.preferences.communication` fjernet.

**Standard synlighet.** `person.preferences.privacy.defaultVisibility` har nå `default: "private"`.

**Konferanse.** `person.conference` flyttet ut til egen rot `conference`. Domeneskiver hører ikke under person.

**relations.** Er nå et object med reserverte nøkler (`records`, `identities`, `entities`, `contactEndpoints`, `issuers`, `chatInvites`, `workspaceInvites`, `workspaceMemberships`) pluss egne navngitte lister ved siden av — f.eks. `relations.venner`, som inneholder relationID-er, ikke kopier.

**relations.people[].** Fjernet. `relations.records` med `entityRepresentation` er formen.

**Relasjonsposten.** `interests`, `purposeRefs`, `channels`, `standing` og `evidence` er fjernet fra `EntityRelationRecord` — både som properties og fra `required`. `entityRepresentation` er nå påkrevet. `schema`-consten er hevet til `haven.entity-relation-record.v2`, siden formen er en annen.

**Fjernede typer.** `EntityRelationInterests`, `EntityRelationChannel`, `EntityRelationStanding` og `EntityRelationEvidence` er slettet fra `$defs`. De erstattes av henholdsvis Interest/Purpose-noder, `ContactEndpoint`, vektet formålsoppfyllelse og `proofs` med keypaths.

**Purpose.goal.** Nå **påkrevet**, og ikke lenger nullbar. Det er dette som skiller Purpose fra Interest: Purpose er den utførende delen av en Interest. Merk at dagens Swift-type har goal som valgfri — kravet er besluttet, ikke implementert.

**signedAgreementEntity.** `records` forblir en **liste**. Dictionary-formen ble vurdert og forkastet: et JSON-objekt har ingen rekkefølge, og posten er en revisjonskjede der rekkefølgen må bevares.

**chronicle.** Kun `array`. Legacy-initialiseringen med tomt objekt er ikke lenger en tillatt form.

**scaffoldPresence.** `staging` fjernet. Erstattet av `presences` nøklet på scaffold, uten miljønavn.

## Åpne punkter

Disse står i skjemaet under `x-haven.openQuestions` og er bevisst **ikke** bakt inn i formen:


- organization som egen rot for organisasjonsentiteter — Kjetil ba 16.09 om at det vurderes, ikke avgjort.
- endpointCell omdøpes til cellReference — vurdert, ikke avgjort.
- Skal skills være annonserte formål brukeren hevder å kunne løse, i stedet for egne poster?
- Skal person.work bli et array med referanser til arbeidsorganisasjoner?
- Toveis binding: array som lister hvilke relasjoner personen er medlem av. Krever grundig vurdering — avgjør om relasjonsgrafen har én eier av sannheten eller to som kan gå fra hverandre.
- Skal sensitive merkelapper kunne lagres i entityRepresentation, altså i det én bruker lagrer om en annen?
- Bør chronicle peke til en egen celle, eventuelt i et annet scaffold, siden den kan vokse seg stor?
- Hvordan avgjøres det sikkert og utvetydig at to identiteter representerer samme entitet?

## Hvordan den ble laget

`build_v2_schema.py` leser v1-skjemaet og anvender beslutningene programmatisk. Hver endring
asserter at målet finnes, så en beslutning som ikke treffer noe stopper skriptet i stedet for å
gå stille forbi. 28 endringer ble anvendt.

Valideringen fant fire feil i første utkast som ellers ville gått upåaktet hen: properties var
slettet men sto fortsatt i `required`; `schema`-consten var fortsatt pinnet til v1;
`interactions.byChannel` var påkrevet etter at kanaler var fjernet; og en kryssreferanse inn i
`properties` brøt når `$defs` ble brukt frittstående. Alle fire er rettet.

