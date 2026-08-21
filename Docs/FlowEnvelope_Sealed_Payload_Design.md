> **UTGÅTT 2026-08-20.** Erstattet av `FlowElement_Sealed_Payload_Design.md`.
> Forslaget her bygget delvis på et sirkulært argument («FlowEnvelope er ubrukt,
> derfor bør vi bruke den»), og halve konstruksjonen fantes bare for å bevare
> `payloadHash` og `provenance` — to felter ingen produksjonskode bruker.
> Beholdt for sporbarhet i beslutningen.

# FlowEnvelope som bærer av kryptert payload — designforslag

Utkast 2026-08-20. Basert på CellProtocol `main` @ 135d3c0.
Besluttet av Kjetil: envelopen skal nå helt fram til Cellen, og `payloadHash`
skal være saltet klartekst-hash med en separat chiffertekst-hash.

Dette dokumentet er et forslag, ikke implementert kode.

---

## Hvorfor Flow er riktig bærer

`FlowEnvelope` har allerede alt en kryptert strøm trenger av rammeverk:
`streamId` + `sequence` for kontinuitet, `previousEnvelopeHash` for hash-kjede,
`signature` for avsenderautentisering, `provenance` for opprinnelse gjennom
videreformidling, `revisionLink` for revisjoner, og `metadata` for det som må
være lesbart underveis. Alternativet — å presse `EncryptedContentEnvelope` inn i
`FlowElement.properties` — ville bygget en andre, svakere ramme ved siden av en
ferdig en.

Det avgjørende argumentet er likevel et annet: i dag har vi **to uavhengige
integritetsmekanismer som aldri møtes.** `Sources/CellBase/Flow/` er komplett og
testet, men brukes ingen steder utenfor sin egen mappe. Broen sender
`FlowElement` rått som `BridgeCommand.payload`. Å gjøre Flow til bæreren løser
begge problemene i én bevegelse.

---

## Det som brekker hvis vi bare bytter ut payloaden

### 1. `payloadHash` verifiseres mot klartekst i dag

`FlowEnvelopeVerifier.verify` (linje 14–20) regner ut
`FlowHasher.payloadHash(for: envelope.payload)` og sammenligner med
`envelope.payloadHash`. `FlowCanonicalEncoder.canonicalData(for: envelope)`
inkluderer dessuten hele `payload` som JSON-objekt i signaturmaterialet.

Med kryptert payload må begge deler defineres på nytt. Det er ikke en
felt-endring, det er en semantikk-endring.

### 2. Proveniens binder til klartekst-hashen

`verifyProvenance` krever `provenance.originPayloadHash == envelope.payloadHash`.
Hele poenget med `FlowProvenance` er at opprinnelsen skal overleve
videreformidling: en Celle som relayer skal kunne bevise hvem som opprinnelig sa
noe. Hvis `payloadHash` blir en chiffertekst-hash, brytes den bindingen så snart
noen re-forsegler til et nytt mottakersett — og re-forsegling er nettopp det en
relay gjør.

Dette er grunnen til at valget «bare chiffertekst-hash» ville vært feil, og
hvorfor den saltede klartekst-hashen er riktig valg.

---

## Foreslått konstruksjon

### Wire-format

```
FlowEnvelope
  envelopeVersion      2                    ← bumpes
  streamId, sequence, domain, producerCell, producerIdentity   (uendret, klartekst)
  sealedPayload        EncryptedContentEnvelope                 ← erstatter payload
  payloadHash          sha256(salt ‖ canonical(FlowElement))    ← saltet klartekst
  ciphertextHash       sha256(sealedPayload.combinedCiphertext) ← ny, i klartekst
  previousEnvelopeHash (uendret, men kjedes på ciphertextHash)
  signature, signatureKeyId, provenance, revisionLink, metadata (uendret)
```

Klartekstblobben som forsegles er **ikke** `FlowElement` alene, men:

```
{ "salt": <32 tilfeldige bytes>, "payload": <FlowElement> }
```

### Hvorfor saltet ligger inne i chifferteksten

Saltet må være hemmelig for alle andre enn mottakerne. Hvis det lå i klartekst i
envelopen ville `payloadHash` blitt et bekreftelsesorakel: et mellomledd som
gjetter på en laventropi-payload — «status: ok», et beløp, en boolsk verdi —
kunne verifisert gjetningen ved å regne ut hashen. Det er en reell lekkasje for
flow-trafikk, der mange elementer har svært lav entropi.

Ved å legge saltet inne i den forseglede blobben får vi tre ting samtidig:

1. **Ingen orakel.** Bare den som kan dekryptere kan verifisere klartekst-hashen.
2. **Proveniens overlever re-forsegling.** En relay er per definisjon mottaker —
   den kan dekryptere. Den beholder saltet, forsegler `{salt, payload}` på nytt
   til det nye publikumet, og `payloadHash` er uendret. Dermed holder
   `provenance.originPayloadHash == envelope.payloadHash` fortsatt, med
   `originSignature` fra den opprinnelige avsenderen.
3. **Mellomledd kan verifisere kontinuitet.** `ciphertextHash` ligger i klartekst
   og kjeder strømmen, så en vert kan oppdage hull og manipulering uten å kunne
   lese noe.

### Signaturmaterialet

`FlowCanonicalEncoder.canonicalData(for: envelope, includingSignature: false)`
må bytte `"payload"` mot `"ciphertextHash"` og `"payloadHash"`. Avsenderen
signerer altså over chifferteksten og den saltede klartekst-hashen — ikke over
klarteksten. Det gir binding til begge lag uten å kreve klartekst for å verifisere
signaturen.

### Nøkkelepoker, ikke re-wrap av historikk

`ContentCryptoEnvelopeUtility.seal` lager **én** innholdsnøkkel per forsegling og
pakker den inn per mottaker. Alle mottakere ser dermed samme chiffertekst, og
hash-kjeden forgrener seg ikke. Det er viktig.

Men når en ny abonnent kommer til midt i en strøm må vi *ikke* re-forsegle
historikken — det ville endret `recipientKeys`, endret envelope-bytene, og brutt
kjeden for alle andre. I stedet:

- Endring i mottakersettet bumper `envelopeGeneration` og starter en ny epoke.
- Historiske envelopes forblir forseglet til det gamle settet.
- En ny abonnent leser framover, ikke bakover.

Dette er samme modell som `ChatCell` allerede bruker, og det har en konsekvens
verdt å notere: **`FlowCacheCell`-replay blir uleselig for en abonnent som kom
til etter at elementene ble forseglet.** Det er riktig oppførsel for ekte E2E,
men det er en atferdsendring som må dokumenteres, ikke oppdages.

### Ny suite

```swift
ContentCryptoPurpose.flowElement
ContentCryptoSuite.flowElementV1   // x25519HKDFSHA256 + x25519SharedSecret + chachaPoly
```

`associatedDataContext` bindes til `"flow:\(domain):\(streamId):\(sequence)"`, så
en forseglet payload ikke kan flyttes til en annen strøm eller sekvensposisjon.

---

## Min gjenstående innvending, og hva jeg mener vi bør gjøre med den

Beslutningen om å la envelopen nå helt fram til Cellen er riktig for proveniens —
den kan ikke være varig hvis den kastes på brogrensen. Men den flytter et ansvar
ut i 19+ kallsteder, og det er der risikoen ligger:

**Hvis `FlowEnvelope.payload` fortsatt er et offentlig lesbart felt, blir
verifisering opt-in.** Én Celle som leser `envelope.payload` uten å kalle
`FlowEnvelopeVerifier.verify` først er et stille hull. Ingen test feiler. Ingen
logg sier fra. Det ser ut som fungerende kode.

Med kryptert payload finnes det en bedre løsning enn disiplin: **gjør det
strukturelt umulig.**

```swift
public struct FlowEnvelope {
    public private(set) var sealedPayload: EncryptedContentEnvelope
    // ingen offentlig `payload`

    /// Eneste vei til klarteksten. Verifiserer signatur, payloadHash og
    /// proveniens før den dekrypterer, og kaster hvis noe av det svikter.
    public func openPayload(
        as recipient: Identity,
        sender: Identity?,
        provider: IdentityKeyRoleProviderProtocol,
        requireProvenanceSignature: Bool = false
    ) async throws -> FlowElement
}
```

Da kan ingen få tak i et `FlowElement` uten å ha gått gjennom verifisering.
Kompilatoren håndhever det, ikke en kodegjennomgang. Dette er den ene endringen
jeg vil argumentere hardest for — den koster nesten ingenting nå og er nesten
umulig å innføre senere, når 19 kallsteder allerede leser `.payload` direkte.

En sekundær konsekvens av samme valg: `Emit.flow(requester:)` går fra
`AnyPublisher<FlowElement, Error>` til `AnyPublisher<FlowEnvelope, Error>`, og
`ValueType` får en `.flowEnvelope`-case. Det er et brudd på wire-formatet og må
gates på `protocolVersion`. Broen må kunne snakke begge deler i en overgangsfase:
v1-motparter får `.flowElement` som før, v2-motparter får `.flowEnvelope`.

---

## Det som fortsatt ikke er løst

**Nøkkeldistribusjon per strøm er den vanskelige biten, ikke kryptoen.**
`ChatCell` vet hvem mottakerne er fordi den har et deltakerregister. Flow har
ingen tilsvarende «hvem abonnerer på denne strømmen». Uten en slik mekanisme har
`seal` ingen `recipients` å pakke inn nøkkelen til, og hele designet over står på
løs grunn.

Det bør avklares før implementasjon starter. Mulige retninger, i økende kostnad:

1. Abonnement er en eksplisitt handling som binder abonnentens
   key-agreement-nøkkel til strømmen, og produsenten forsegler til det settet.
2. Strømmen har en egen `ContentCryptoPolicy` med et deklarert mottakersett,
   knyttet til en `Agreement`.
3. Gruppenøkkel med rotasjon per epoke, der `envelopeGeneration` er epoketelleren.

**Metadata i klartekst lekker fortsatt mønster.** `streamId`, `domain`,
`producerCell`, `producerIdentity`, `sequence`, og `FlowElement.topic`/`origin`
hvis de løftes ut. En vert som ikke kan lese innholdet ser fortsatt hvem som
snakker med hvem, hvor ofte og om hvilket emne. Det er et bevisst valg — ruting
krever noe lesbart — men det bør stå skrevet hva vi aksepterer å lekke, ikke
være en implisitt konsekvens.

---

## Foreslått rekkefølge

1. `ContentCryptoPurpose.flowElement` + `ContentCryptoSuite.flowElementV1`,
   med tester. Ingen bruk ennå. Lav risiko, ingen wire-endring.
2. Avklar nøkkeldistribusjon per strøm. **Ingenting under her gir mening før
   dette er bestemt.**
3. `FlowEnvelope` v2: `sealedPayload`, `ciphertextHash`, saltet `payloadHash`,
   `openPayload(as:)`, og `payload` gjort utilgjengelig. Oppdater
   `FlowCanonicalEncoder`, `FlowEnvelopeSigner`, `FlowEnvelopeVerifier`.
4. `ValueType.flowEnvelope` + versjonsgatet ruting i `BridgeBase`. v1-motparter
   må fortsatt virke.
5. `Emit.flow` bytter elementtype. Dette er den brede endringen — ta den sist,
   når alt under er grønt.
6. Dokumenter `FlowCacheCell`-konsekvensen: replay er uleselig for abonnenter som
   kom til etter forseglingen.
