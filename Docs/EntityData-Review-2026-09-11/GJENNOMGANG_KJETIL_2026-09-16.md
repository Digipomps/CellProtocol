# EntityData — Kjetils gjennomgang 2026-09-15/16

Kilde: gjennomgangsflaten publisert 15.09, der Kjetil gikk gjennom alle 253 elementene i
`EntityData.review.schema.json` element for element. Dette dokumentet er utskriften av
hans egne svar, ordrett, gruppert etter hva de får som konsekvens. Losens tolkninger er
utelatt her; det som står under «Kjetil» er hans tekst.

Tall: 253 elementer. 203 godkjent uten merknad. 45 med kommentar. 5 ikke berørt
(e001 roten, e002 `person`, e022/e023 `nicknames`, e195 `proofs.credentials.<credentialID>`).

## Beslutninger som endrer strukturen

Disse krever endring i skjemaet før det kan fryses til dokumentasjon.

### `person.contact.email`

Vi dropper ett fet for epost - det blir for lite fleksibelt. Vi ska bruke endpoints som beskriver endepunkter hvor brukeren kan nåes. Det kan være telefon, epost, some nick, url,  cellreference etc.

### `person.contact.phone`

la oss bruke label på phones - primary

### `relations.people[].contact.email`

Her skal vi ha samme struktur som en person entityData altså endpoints

### `relations.people[].contact.mobile`

Her skal vi ha samme struktur som en person entityData altså endpoints

### `relations.people[].contact.endpointStatus`

Her skal vi ha samme struktur som en person entityData altså endpoints

### `person.contact.endpoints[].endpointCell`

Kanskje vi skulle kalle cellReference i stedet for

### `person.preferences.communication.preferredChannel`

Vi forenkler og går for den andre: person.contact.preferredChannel.

### `person.preferences.privacy.defaultVisibility`

Default private

### `person.conference`

domeneskiver som denne heller ligge som egen rot

### `relations`

Gå for object - da holder vi noen reserved keys. men brukeren kan legge til egne navngitte relasjoner med arrays

### `relations.people`

Vi bruker den nyere  relations.records/entityRepresentation

### `relations.people[].ownerUUID`

dette er obsolete - vi bruker uuid i Identity (som minimum må inneholde uuid og offentlig nøkkel) vi peker vel en entityRepresentation til entity som igjen har en liste på hvilke Identities vi har oppfattet at den entiteten bruker. (Vi må med andre ord bli flinke til  - på en sikker og utvetydig måte - finne ut om to identities representerer samme Entity )

### `relations.people[].purposeRefs`

Vi skal bruke graf

### `/signedAgreementEntity/records`

Tenker vi går for dictionary fra signedAgreementEntity.commit. Si ifra om du har invendinger.

### `/chronicle`

Ryddes

### `scaffoldPresence.staging`

Denne blir  en underlig løsning - veldig  spesifikk for vårt utviklingsmiljø. Vi må ha en mer generell måte å uttrykke det samme på. Kanskje bare scaffoldPresence.

### `/EntityRelationInterests`

Her bruker vi i tilfelle Interest/Purpose

### `/EntityRelationChannel`

Bruk helle endepunt i EntityRepresentation

### `/EntityRelationStanding`

Status eller tillit måles i om relasjonens uttalte formål er oppfylt (Weighted)

### `/EntityRelationEvidence`

Her bruker vi proofs med keypaths som i egne bevis

## Til vurdering — Kjetil ber om at dette tenkes grundig gjennom

Ikke avgjort. Flere av dem er mønstre som vil gjenta seg andre steder i treet.

### `person.work`

Burde vi ha en referanse til work organisasjoner i et work array? Dette kan være et godt mønster

### `person.work.organizationRef`

Se kommentaren på person work

### `person.skills`

Burde skills være annonserte formål som brukeren hevder hen kan løse?

### `relations.people[].relationship`

vi kan ha et array som lister opp relasjonene personen er medlem av - så vi får en toveis binding. Vurder dette grundig.

### `relations.people[+]`

Dette var en skrivesyntaks som var nyttig - vurder nytte og konsekvens.

### `signedAgreementEntity.records[].purpose`

Vurder om vi skal ha et fritekst beskrivelse og muligheten for å knytte til formål.

### `chronicle`

Chronicle kan bli veldig stor og burde kanskje peke til en egen celle. Denne kan også ligge et i et annet scaffold - kanskje peke til en lokal celle som håndterer administrasjonen?

### `person.demographics`

Dette er data som ikke er tilgjengelige for andre enn brukeren selv i utgangspunktet. Men verd å tenke etter om sensitive merkelapper ikke skal lagres i entityRepresentation (altså data en bruker har lager i egen entity om en annen etity)

### `person.displayName`

DisplayName burde kanskje heller være knyttet til PerspectiveCell. Det er gjerne noe en bruker forskjellig i forskjellige sammenhenger. Hm la denne stå så kan folk sette her at om de har et dobbeltnavn så bruker de bare det ene eller slik som Ninni som egentlig heter Ingrid Elisabeth men absolutt alle kjenner henne som Ninni. La det stå men vi må huske at displayName i mange sammenhenger er brukt i et mindre Scope

## Presiseringer — bekrefter eller skjerper forståelsen

Ingen strukturendring, men de fastsetter hva noe betyr og hører hjemme i dokumentasjonen.

### `purposes`

Dette er hva som blir administrert av PerpectiveCell

### `/EntityRepresentation`

Kontakt er en node i min graf. Det er det samme som jeg i mitt eget hode vet om mine relasjoner.

### `/Interest`

Interesse er egentlig bare en node med en label. Lebelen er for gjenkjennelighet mens noden er definert av sine relasjoner til andre noder. Constraint er nyttig funksjonalitet der det er relevant.

### `/Purpose`

Purpose er også en node label og definert av sine relasjoner - men i tillegg her den et målbart mål.  som er påkrevet. Purpose er egentlig den utførende delen av en Interesse

### `/CellConfiguration`

CellConfiguration er veldig godt dokumentert i kode.  Forklar nøye - kan også brukes til å utføre get/set

### `person.conference.purposeSnapshot`

Fornyes når brukeren melder seg på en konferanse og når brukeren deltar

### `person.conference.consentRecords`

Dette er ikke autorativt samtykke på linje med Agreement

### `person.profile.interestTags`

tagger er kun pynt - de kan avledes om brukeren vil. I denne settingen er det forenklede interesser som vil være med når man annonserer sine interesser som for eksempel med nearby scanner hvor man kan legge enkle data i userInfo. Da kan en interesse personen vil skal være med uavhengig av kontekst lagres her.

### `person.profile.visibility`

Kan gi litt mer styring til f.eks interestsTags. Men det vil være en veldig forenkling i forhold til interesser og formål uttrykt som PerspectiveNodes

### `person.demographics.ageBand`

Denne blir litt omtrentlig, men kan være grei å bruke om brukeren ikke har fått issuet en Verifiable Credential om birthdate - som igjen kan brukes som en undertøttet påstand om ageBand

### `person.contact.emails[].status`

Enig - bevis hører hjemme i proofs

### `proofs.index.byKeypath`

Dette må beskrives nøye i dokumentasjon

### `/identityLinks`

Dokumenter tydelig

### `/EntityRelationInteractionSummary`

Kan være nyttig - vi tar den med og vurderer når vi tar dette i bruk

### `/EntityRelationSubject`

Kan være nyttig - vi tar den med og vurderer når vi tar dette i bruk

### `/EntityRelationInteractionEvent`

Samhandling er mer generelt som i en interaction

## Ikke berørt i gjennomgangen

- `e001` roten i datatreet
- `e002` `person`
- `e022` / `e023` `person.nicknames` og `nicknames[]`
- `e195` `proofs.credentials.<credentialID>`

Disse ble verken godkjent eller kommentert — antakelig hoppet over, ikke avvist.
