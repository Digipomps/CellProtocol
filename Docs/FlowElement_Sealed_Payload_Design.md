# Forseglet payload i FlowElement — revidert designforslag

Utkast 2026-08-20, revisjon 2. Basert på CellProtocol `main` @ 135d3c0.

**Denne revisjonen erstatter `FlowEnvelope_Sealed_Payload_Design.md`.** Kjetil
utfordret FlowEnvelope-forslaget på at det bloater typer, og utfordringen holdt.
Under står hvorfor, og hva jeg mener vi bør gjøre i stedet.

---

## Argumentet jeg tok feil på

I forrige runde skrev jeg, som støtteargument for FlowEnvelope:

> I dag har vi to uavhengige integritetsmekanismer som aldri møtes.
> Å gjøre Flow til bæreren løser begge problemene i én bevegelse.

Det er sirkulært. «Vi har en ubrukt modul, derfor bør vi bruke den» er
sunk cost, ikke design. Hvis `Sources/CellBase/Flow/` ikke trengs, er det riktige
svaret å fjerne den — ikke å lete etter en jobb til den. Og observasjonen om to
mekanismer argumenterer minst like godt for å slette den ene som for å ta den i
bruk. Jeg brukte den bare i én retning.

Verre: konstruksjonen jeg endte opp med — saltet klartekst-hash inne i
chifferteksten, separat `ciphertextHash`, resonnement om bekreftelsesorakler og
salt-skop — eksisterte **utelukkende** for å holde `payloadHash` og
`provenance` i live under kryptering. Det er to felter ingen produksjonskode
bruker. Når et design bruker halve omfanget sitt på å bevare noe ingen etterspør,
har designet begynt å generere sine egne krav.

---

## Hva formålet faktisk er

Formålet er: **verten skal ikke kunne lese payload.** Ikke noe mer.

Hva krever det?

- chiffertekst
- headeren som trengs for å dekryptere: suiteID, algoritmer, per-mottaker
  innpakkede nøkler, ephemeral pubkeys, senderKeyID, AAD-kontekst, generasjon
- avsenderautentisering, så en vert ikke kan bytte ut innhold

`EncryptedContentEnvelope` er nøyaktig dette, og ikke mer. Den har allerede
`senderSignature`, og `ContentCryptoEnvelopeUtility.open` verifiserer den når
suiten krever det (`:219–233`) og rapporterer `senderVerified`. AEAD-en
(ChaCha20-Poly1305) gir integritet og autentisitet på chifferteksten, og
`associatedDataContext` binder konteksten.

Integritet og avsenderautentisering er altså allerede dekket av forseglingen selv.

---

## Hva FlowEnvelope ville lagt til, felt for felt

| Felt | Dekket allerede? | Av hva |
|---|---|---|
| `signature` / `signatureKeyId` | **Ja** | `EncryptedContentEnvelope.senderSignature`, verifisert i `open()` |
| `streamId` / `sequence` | **Ja** | `BridgeCommand.streamID`/`sequence` + `BridgeFlowContinuityTracker` — implementert, testet, i drift |
| `payloadHash` | Redundant | AEAD gir integritet; hashen er bare meningsfull for proveniens |
| `previousEnvelopeHash` | Nei | Men ingen produksjonskode kjeder flow, og broen lover eksplisitt ingen replay |
| `provenance` | Nei | Ingen produksjonskode relayer med opprinnelsesbevis i dag |
| `revisionLink` | Nei | Ubrukt |

To av seks er duplikater av mekanismer som allerede virker. Fire tjener formål vi
ikke har.

Duplikatet på `streamId`/`sequence` er det mest talende. Broen har allerede
kontinuitetssporing på wire, med watermark, gap-deteksjon og LRU-grenser. Å
adoptere FlowEnvelope ville lagt en *andre* sekvensmekanisme oppå den — altså
akkurat den dupliseringen jeg advarte mot, bare i motsatt retning av det jeg
foreslo.

---

## Forslaget: én enum-case

`FlowElement.content` er allerede `FlowElementValueType` med `.data(Data)`.
Chifferteksten passer inn uten wire-brudd. Det som mangler er hintet, og
`contentType` er nøyaktig det feltet som sier hva `content` representerer.

```swift
public enum FlowElementContentType: String {
    ...
    case sealed          // ny: content er en JSON-kodet EncryptedContentEnvelope
}
```

og én gren i `FlowElement.init(from:)`, ved siden av den eksisterende `.base64`:

```swift
case .sealed:
    let decoded = try values.decode(String.self, forKey: .content)
    guard let decodedData = Data(base64Encoded: decoded) else { throw ... }
    content = .data(decodedData)
```

Det er hele wire-endringen.

**Blast radius, målt:** `FlowElementContentType` nevnes i 4 filer totalt.
Én uttømmende switch (`FlowElement.init(from:)`, som kompilatoren tvinger oss til
å oppdatere) og én tuple-switch med `default` i
`AppleIntelligenceCell.persistedOutboxContent` — der bør `.sealed` legges til
eksplisitt, ellers avvises forseglet innhold stille fra outboxen.

Ingen ny `ValueType`-case. Ingen protokollversjonsbump. Ingen endring i
`Emit.flow`. Ingen endring i de 19 kallstedene. Ingen salt, ingen `ciphertextHash`,
ingen resonnement om bekreftelsesorakler — hele det problemet forsvinner, fordi
vi ikke lenger prøver å bevare en klartekst-hash gjennom kryptering.

I tillegg trengs:

```swift
ContentCryptoPurpose.flowElement
ContentCryptoSuite.flowElementV1   // x25519HKDFSHA256 + x25519SharedSecret
                                   // + chachaPoly, requiresSenderSignature: true
```

med `associatedDataContext = "flow:\(topic):\(origin)"`, så en forseglet payload
ikke kan flyttes til et annet emne eller en annen opprinnelse.

---

## Hvorfor det enkle valget også er det mest utvidbare

Dette er argumentet jeg synes veier tyngst, og som jeg ikke så i forrige runde.

Når payloaden er ugjennomtrengelig for alle andre enn mottakerne, blir den et
**privat utvidelsespunkt.** Alt vi senere vil binde kryptografisk til innholdet
kan legges *inne* i den forseglede blobben — usynlig for wire, for verten, og for
enhver annen implementasjon.

Trenger vi proveniens gjennom videreformidling senere, forsegler vi
`{origin, payload}` i stedet for `payload`. Ingen wire-endring. Ingen ny type.
Ingen versjonsbump. Ingen koordinering med motparter.

En ytre envelope-type gjør det motsatte: den fryser et **offentlig** skjema for
felter vi ennå ikke vet formen på. `provenance`, `revisionLink` og
`previousEnvelopeHash` er designet mot krav ingen har formulert. Å publisere dem
på wire nå betyr at vi må leve med dem — eller versjonere oss ut av dem — når
kravene faktisk dukker opp og ser annerledes ut enn vi gjettet.

Kryptering kjøper oss altså utsettelse. Det er billigere å utvide en hemmelig
struktur enn en offentlig.

---

## Hva vi faktisk gir opp

Jeg vil være presis her, ikke selge inn.

1. **Mellomledd kan ikke verifisere kontinuitet kryptografisk.** Med
   `ciphertextHash`-kjeding kunne verten oppdaget hull og manipulering uten å
   lese. Uten den har vi bare `BridgeFlowContinuityTracker`, som oppdager
   *hull* men ikke *manipulering*. En ondsinnet vert kan droppe eller omordne
   elementer uten at det er kryptografisk påvisbart — den kan ikke endre
   innholdet, men den kan endre hva du ser.

   Er det akseptabelt? I dag ja: broen lover eksplisitt ingen replay-garanti, og
   verten er allerede i posisjon til å droppe frames. Kryptering endrer ikke
   trusselbildet der. Men hvis vi senere trenger «verten kan ikke skjule at noe
   mangler», er det en egen, bevisst utvidelse — og den kan legges inne i den
   forseglede blobben som en sekvens mottakeren verifiserer selv.

2. **Proveniens gjennom relay finnes ikke.** `senderSignature` beviser hvem som
   forseglet, ikke hvem som opprinnelig sa det før re-forsegling. Utsatt, ikke
   utelukket — se avsnittet over.

---

## Hva vi gjør med `Sources/CellBase/Flow/`

Konsekvensen av dette valget er at FlowEnvelope-modulen ikke får en jobb. Da bør
den ikke bli liggende. Å la ferdig, testet, ubrukt kryptokode ligge i repoet er
en felle: neste person antar at den er i bruk, eller gjenoppfinner den.

To ærlige alternativer:

- **Fjern den**, og hent den tilbake fra git hvis proveniens blir et reelt krav.
- **Behold den, men flytt og merk den** som et lag for persistert revisjon/audit —
  altså noe som brukes når flow *lagres*, ikke når den *sendes* — og skriv
  eksplisitt i modulen at den ikke er en transportmekanisme.

Jeg heller mot det første. Hvis vi ikke kan peke på hvem som skal bruke den,
er det ikke kode, det er inventar.

Uansett: la den ikke stå udokumentert. Det er dette som gjorde forrige runde
forvirrende.

---

## Én reell kostnad ved rullout

En v1-motpart som mottar `contentType: "sealed"` vil feile i
`FlowElementContentType.init(from:)`. `FlowElement.init(from:)` dekoder
`properties` med `try?`, så feltet blir `nil`, og elementet degraderer til
`content = .string("Decoding error")` via `case .none`-grenen.

Det krasjer ikke, men det er en stille degradering. Sender vi forseglet payload
til en gammel klient, ser brukeren «Decoding error» uten forklaring.

Det bør håndteres ved at avsenderen vet om mottakeren støtter `.sealed` før den
forsegler — samme kapabilitetsforhandling som `ChatCell` allerede gjør med
`supportedSuites`. Ikke ved å håpe at alle oppgraderer.

---

## Foreslått rekkefølge

1. `ContentCryptoPurpose.flowElement` + `ContentCryptoSuite.flowElementV1`, med
   tester. Ingen bruk ennå.
2. `FlowElementContentType.sealed` + dekodegren + oppdater
   `AppleIntelligenceCell.persistedOutboxContent`. Fortsatt ingen produsent.
3. **Avklar nøkkeldistribusjon per strøm.** Dette blokkerer fortsatt alt under.
   `seal` trenger et `recipients`-sett, og flow har ingen «hvem abonnerer her».
   Dette er uendret fra forrige runde, og det er fortsatt den vanskeligste biten.
4. Kapabilitetsforhandling, så vi aldri forsegler mot en motpart som ikke kan åpne.
5. Første produsent og konsument, bak et flagg.
6. Beslutning om `Sources/CellBase/Flow/`: fjern eller merk.

---

## Hva som fortsatt lekker

Uendret fra forrige revisjon, og verdt å skrive ned som et bevisst valg framfor
en implisitt konsekvens: `topic` og `origin` på `FlowElement` er ruting-metadata i
klartekst, og `BridgeCommand` bærer `streamID`, `sequence` og identitet. En vert
som ikke kan lese innholdet ser fortsatt hvem som snakker med hvem, hvor ofte, og
om hvilket emne. Ruting krever noe lesbart. Men det bør stå hva vi aksepterer å
lekke.
