# Swarm identity admission og entity-link

Dato: 2026-07-02

Dette dokumentet beskriver den enkleste brukerreisen for aa gi en bruker nok
bevis til aa komme inn i Swarm, uten aa gjoere Swarm til en global konto eller
kopiere private data inn i scaffoldet.

Loesningen har to lag:

1. `admission`: bevis paa at en domain-scoped Identity kan slippe inn i Swarm
   for et konkret formaal.
2. `entity-link`: frivillig kobling mellom denne Swarm-identiteten og resten av
   brukerens entity, slik at Swarm-presens blir en utvidelse av entiteten.

Begge lag maa vaere eksplisitte, signerte, scope-bundne og revokerbare.

## Kort anbefaling

Den laveste friksjonen for brukeren er en "Swarm ber om tilgang"-flyt:

1. Swarm viser eller sender en claim request.
2. Brukerens lokale identitetsflate, for eksempel Binding/HavenAgentD, velger
   riktig domain-scoped Identity.
3. Brukeren godkjenner med lokal tilstedevaerelse, for eksempel Keychain,
   passkey, Secure Enclave, lokal agent token eller annen fersk device-presens.
4. En trusted issuer utsteder eller bekrefter et kortlivet role/capability
   credential for denne identiteten.
5. Klienten sender Swarm-kallet med signert request, credential, nonce,
   timestamp, body-hash og proof-keypath.
6. Hvis brukeren ogsaa vil knytte Swarm til sin entity, startes en separat
   `EntityScaffoldEnrollment`-flyt.

Brukeren skal ikke maatte se eller kopiere token, headers, private keys eller
raatt credential-JSON. Det boer se ut som:

```text
Swarm vil bekrefte:
- at denne identiteten kan delta i Swarm
- hvilke handlinger Swarm faar lov til aa gjoere
- hvor lenge beviset er gyldig

[Godkjenn] [Avbryt]
```

## Prinsipper

- Entity er ikke autoritet. En Entity er konseptuell og skal ikke sendes som en
  global bruker-ID.
- Identity er autoritetshaandtaket. Den er domain-scoped, kryptografisk og
  minimal.
- En lenke er ikke en rettighet. Same-entity eller enrollment sier bare at to
  identiteter kan behandles som samme entity for et avtalt scope.
- Rettigheter gis av credentials, agreements, contracts og conditions.
- QR, deep link, URL eller cell reference er transport, ikke autoritet.
- Private keys, raw credentials og persondata skal ikke kopieres inn i Swarm.
- Swarm skal be om nok bevis til aa loese sitt formaal, ikke mer.

## Lag 1: admission inn i Swarm

Admission svarer paa ett spoersmaal:

```text
Kan denne konkrete Identity bruke denne Swarm-ressursen akkurat naa?
```

Minimumsbeviset er:

- requester Identity med UUID, domain og public signing key
- signert credential eller proved claim for riktig role/capability
- request-signatur fra samme Identity
- canonical request-binding til method, path, query, body-hash, identity UUID,
  proof-keypath, timestamp og nonce
- replay-cache paa `identityUUID + nonce`
- trusted issuer policy eller eksplisitt testmodus for self-issued credential
- expiry og klokkevindu

Dagens Swarm admin-route i CellScaffold har allerede denne formen gjennom
`SimulationAdminAccessMiddleware`.

Eksisterende signerte request-headers:

```text
X-Simulation-Admin-Identity
X-Simulation-Admin-Credential
X-Simulation-Admin-Signature
X-Simulation-Admin-Timestamp
X-Simulation-Admin-Nonce
X-Simulation-Admin-Proof-Keypath
X-Simulation-Admin-Body-SHA256
```

Eksisterende admin proof-keypaths:

```text
identity.proofs.scaffold.roles.admin.observer
identity.proofs.scaffold.roles.admin.operator
identity.proofs.scaffold.roles.admin.nodeAgent
identity.proofs.scaffold.roles.admin.security
```

Dette er riktig for operator/admin-tilgang, inkludert `GET /swarm/cells`.
Det er ikke riktig som generell participant-admission.

## Participant-admission

For vanlige Swarm-deltagere boer vi ikke gjenbruke admin-rollene. Vi boer bruke
samme mekanikk, men med egne Swarm proof-keypaths og capabilities.

Foreslaatt minimum:

```text
identity.proofs.swarm.entry.participant
identity.proofs.swarm.entry.operator
identity.proofs.swarm.entry.nodeAgent
identity.proofs.swarm.entry.security
```

Eksempel paa capabilities:

```text
swarm.presence.enter
swarm.presence.read-own
swarm.presence.update-own
swarm.matching.request
swarm.matching.receive-suggestions
swarm.cell-catalog.read
swarm.run.join
swarm.run.leave
```

Eksempel paa role/capability credential:

```json
{
  "type": ["VerifiableCredential", "SwarmAdmissionCredential"],
  "issuer": "did:key:trusted-swarm-issuer",
  "credentialSubject": {
    "id": "did:key:user-swarm-identity",
    "identityUUID": "user-swarm-identity-uuid",
    "role": "swarm.participant",
    "roleKeypath": "identity.proofs.swarm.entry.participant",
    "capabilities": [
      "swarm.presence.enter",
      "swarm.presence.update-own",
      "swarm.matching.request"
    ],
    "audience": "https://swarm.haven.digipomps.org",
    "privacyLevel": "minimal-presence"
  },
  "validFrom": "2026-07-02T00:00:00Z",
  "validUntil": "2026-07-03T00:00:00Z"
}
```

Dette credentialet sier ikke hvem personen er i verden. Det sier bare at den
signerende Swarm-identiteten har disse Swarm-rettighetene innenfor et kort scope.

## Lag 2: entity-link inn i resten av entiteten

Entity-link svarer paa et annet spoersmaal:

```text
Er denne Swarm-identiteten en frivillig utvidelse av min entity for et gitt
scope?
```

Dette boer gjoeres med `EntityScaffoldEnrollment`, ikke ved aa legge global ID
eller persondata i Swarm.

Eksisterende CellScaffold-kontrakt:

```text
cell:///EntityScaffoldEnrollment
read:  state, contracts, linkedScaffolds, pendingEnrollments
write: enrollment.begin, enrollment.approve, enrollment.complete,
       enrollment.revoke, enrollment.validate
```

Flyten:

1. Swarm-tilstedevaerelsen lager eller gjenbruker en egen Swarm Identity.
2. Den lager en `EntityScaffoldEnrollmentRequest` med public key, domain,
   scaffold kind, audience, origin, expiry, nonce og oenskede capabilities.
3. Brukerens owner scaffold verifiserer request-signaturen og viser en
   godkjenningsflate.
4. Brukeren godkjenner med fersk lokal presens.
5. Owner identity signerer `EntityScaffoldEnrollmentApproval` med en subset av
   capabilities.
6. Enrollment-cellen utsteder en activation challenge.
7. Swarm-identiteten signerer challenge.
8. Cellen lagrer en aktiv `EntityScaffoldLinkRecord`.

Link-recorden kan lagre:

- link ID
- Swarm identity UUID
- Swarm public key
- identity domain
- scaffold kind
- capabilities
- audience
- status
- linkedAt
- approvedByIdentityUUID
- revokedAt

Den skal ikke lagre:

- private keys
- raw Keychain items
- passord
- telefonnummer, e-post, foedselsdato eller annen PII
- full historikk om brukerens aktivitet i Swarm
- global entity identifier som kan brukes til sporing utenfor scope

## Brukerreisen

### Fase A: foerste gang brukeren kommer til Swarm

1. Brukeren trykker "Koble til Swarm".
2. Swarm lager en admission request:
   - audience: `https://swarm.haven.digipomps.org`
   - purpose: `swarm.presence.enter`
   - requested capabilities: minimal liste
   - expiry: kort, for eksempel 15 minutter for requesten
3. Binding/HavenAgentD eller annen identity wallet viser forespoerselen.
4. Brukeren godkjenner.
5. Identity wallet signerer eller henter credential.
6. Klienten proever Swarm-kallet.
7. Swarm returnerer enten:
   - `connected`
   - `signContract(...)`
   - `denied(reason)`

### Fase B: brukeren vil at Swarm skal bli del av entiteten

1. UI viser "Gjoer Swarm til en del av min entity".
2. Owner scaffold starter `EntityScaffoldEnrollment`.
3. Brukeren godkjenner capabilities.
4. Swarm fullfoerer activation challenge.
5. Owner scaffold viser Swarm som aktiv lenket presence.

Dette er bevisst en egen handling. Admission kan vaere midlertidig uten entity
link. Entity-link skal kreve tydeligere samtykke.

## Hva Swarm trenger aa vite

For admission:

- Identity UUID eller DID
- public signing key
- identity domain
- role/capability credential
- credential issuer
- expiry
- nonce/timestamp/body-hash/signature

For entity-link:

- Swarm identity UUID
- Swarm public key
- enrollment request hash
- approved capability subset
- link status
- revocation status

Swarm trenger normalt ikke:

- juridisk navn
- e-post
- telefonnummer
- presis lokasjon
- foedselsdato
- personnummer
- betalingsdata
- full kontaktliste
- full entity graph
- private interests som ikke er nodvendige for valgt matchingformaal

Hvis matching trenger interesser eller formaal, skal dette gis som egne
purpose-scoped disclosures. Et eksempel er:

```text
disclose:
- "Jeg vil finne tekniske samtalepartnere om CellProtocol"
- "Jeg vil motta forslag til 3 relevante sesjoner"

do not disclose:
- legal identity
- exact location
- private notes
- unrelated interests
```

## Hvordan HavenAgentD passer inn

`HavenAgentD` har allerede en purpose-aware
`identity.sign-statement`-kommando. Den er nyttig for brukeropplevelsen fordi
private keys blir i lokal daemon/Keychain, mens Swarm bare faar en verifiserbar
signert statement eller request.

Bruk den for:

- audience-bundne statements
- payload-hash i stedet for raw payload naar mulig
- expiry
- nonce
- lokal nonce ledger
- klar purposeRef, for eksempel `personal.entity.send-verifiable-statement`

Den skal ikke brukes som en generell "sign arbitrary bytes"-bakdoer. Swarm
requesten maa fortsatt vaere formalisert og canonicalisert.

## Implementasjonsretning

### Steg 1: behold dagens admin-admission

Dagens `SimulationAdminAccessMiddleware` er god nok for operator/admin-flater.
For Kjetil som operator kan vi bruke:

```text
identity.proofs.scaffold.roles.admin.operator
```

eller, for ren lesing:

```text
identity.proofs.scaffold.roles.admin.observer
```

Dette holder `/swarm/cells` og andre admin-routes beskyttet uten aa introdusere
ny policy.

### Steg 2: trekk ut generisk SwarmAdmissionAccess

Neste produksjonsrette steg er aa lage en Swarm-spesifikk variant som ikke heter
`SimulationAdmin...`.

Den boer gjenbruke:

- canonical request payload
- body SHA-256
- timestamp window
- nonce replay store
- identity signature verification
- VCClaim verification
- trusted issuer DID policy

Den boer endre:

- header prefix fra `X-Simulation-Admin-*` til `X-Swarm-Admission-*`
- role enum fra admin-only til swarm roles
- route requirements fra HTTP method alene til konkrete endpoint/capability
- error copy fra "admin" til "admission"

### Steg 3: koble entity-link til Swarm presence

Swarm boer ha en liten presence/enrollment surface:

```text
cell:///SwarmPresence
read:  swarm.presence.state, swarm.presence.link
write: swarm.presence.requestAdmission,
       swarm.presence.beginEntityLink,
       swarm.presence.completeEntityLink,
       swarm.presence.revokeEntityLink
```

Denne cellen skal ikke eie identity policy. Den skal koordinere brukerflyten og
delegere autorisasjon til admission/enrollment/credential-lagene.

### Steg 4: lag en "proof wallet" UX

For brukeren boer dette vaere ett panel:

```text
Swarm
Status: ikke koblet / admission OK / entity-link aktiv

Bevis:
- Swarm participant credential: gyldig til ...
- Entity-link: aktiv / ikke aktiv
- Capabilities: ...

Handlinger:
- Koble til Swarm
- Knytt Swarm til min entity
- Forny bevis
- Trekk tilbake Swarm-lenke
```

## Testkrav

Admission tests:

- manglende headers gir 401
- feil body-hash gir 401
- feil signatur gir 401
- replayed nonce gir 401
- utloept timestamp gir 401
- credential fra ukjent issuer gir 403
- credential subject som ikke matcher Identity gir 403
- observer kan lese read-route
- observer kan ikke skrive operator-route
- operator kan skrive operator-route
- participant kan bare bruke participant-routes

Entity-link tests:

- enrollment request maa vaere signert av Swarm identity
- approval maa vaere signert av owner identity
- approval capabilities maa vaere subset av request capabilities
- approval `jti` kan bare brukes en gang
- activation challenge maa signeres av Swarm identity
- revocation stopper videre bruk av link
- linkedScaffolds returnerer ikke private keys eller raw credentials

Privacy tests:

- admission credential inneholder ikke e-post, telefon, juridisk navn,
  foedselsdato, personnummer eller presis lokasjon
- Swarm presence disclosure er purpose-scoped
- logs lagrer hashes/metadata, ikke raw payload naar payload ikke trengs
- entity-link kan bevises uten aa eksponere full entity graph

## Aapne hull

- Dagens Swarm-route bruker `SimulationAdminAccessMiddleware`; det er riktig for
  admin-katalogen, men ikke en ferdig participant-admission.
- Det finnes `EntityScaffoldEnrollment`, men Swarm har ikke en komplett
  brukerflate som binder enrollment direkte til Swarm presence.
- Trusted issuer provisioning for Swarm participant credentials maa defineres.
- Vi trenger en liten credential renewal-flow slik at brukeren ikke maa
  godkjenne for ofte, men heller ikke sitter med langlivede brede rettigheter.
- Vi boer skille "developer/operator Kjetil" fra "participant Kjetil" med ulike
  identities eller ulike credentials paa samme domain-scoped identity.

## Beslutning

Den enkleste trygge loesningen er ikke ett magisk login. Det er to enkle,
synlige handlinger:

1. Gi Swarm et kortlivet, purpose-scoped admission-bevis.
2. Knytt Swarm-identiteten til min entity gjennom `EntityScaffoldEnrollment`
   naar jeg faktisk vil at Swarm skal bli en del av entiteten.

For brukeren kan dette oppleves som to knapper. Under panseret holder vi fast paa
CellProtocol-reglene: domain-scoped identity, eksplisitt evidence, resolver/
middleware-enforcement, minimal disclosure, replay-beskyttelse og revokerbarhet.
