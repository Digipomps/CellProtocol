# Selskapsentiteter, gruppenøkler og flersignatur

Dato: 2026-10-08
Status: **G1 besluttet 2026-10-08 (se «Beslutninger»). G2-plan venter på godkjenning.** Ingen kode er endret.
Formål: `purpose://candidate.entitetsdata.organization-acts-through-mandated-persons`

Dette dokumentet beskriver hvordan HAVEN skiller mellom entiteter som er
enkeltpersoner og entiteter som representerer selskaper, hvordan en
selskapsnøkkel lagres, hvordan to eller flere med fullmakt aktivt må godkjenne
før selskapet signerer, og hvordan en person beviser overfor andre at hen
handler på vegne av selskapet.

## Kort anbefaling

1. **Personen er first-class, selskapet er en styrt entitet.** En
   personentitet forsegles til den som startet den (dagens `EntityGenesis`).
   En selskapsentitet forsegles i stedet til en signert **styringspolicy**
   (hvem er eiere og roller, hvem har signaturrett, prokura og grenser), og
   ingen person blir noen gang `same_entity` med selskapet.
2. **Individene låser opp *bruken*, ikke *nøkkelen*.** Selskapets private
   nøkkel skal aldri dekrypteres hos en enkeltperson. Hver godkjenner signerer
   et konkret forslag med sin egen nøkkel (som i dag ligger i Secure Enclave).
   Når godkjenningene oppfyller policyen, signerer selskapsnøkkelen nøyaktig
   det forslaget og ingenting annet.
3. **Selskapsnøkkelen holdes av en selskapshvelv-celle** (custodian) som ikke
   kan eksportere nøkkelen og bare signerer mot et gyldig godkjenningsbevis.
   Fase 2 deler nøkkelen med FROST (RFC 9591, Ed25519), slik at hvelvet alene
   heller ikke kan signere.
4. **Fullmakt bevises med to credentials**, samme mønster som
   `ConferenceOrganizerAccessVerifier` allerede bruker: et
   *selskapsbevis* (selskapet finnes og har denne styringen, utstedt av en
   tillitsankret utsteder, på sikt Brønnøysund/EU Business Wallet) og et
   *fullmaktsbevis* (selskapet gir denne identiteten denne rollen med disse
   grensene). Personen presenterer begge i en VP bundet til egen nøkkel.

Kjetils forslag om at personer med fullmakt «låser opp» selskapsnøkkelen er
riktig i intensjon, men bør gjennomføres som godkjenning av bruk. Grunnen er
konkret og følger i neste avsnitt.

## Hva finnes i dag

| Byggestein | Fil | Relevans |
|---|---|---|
| `Identity` med én signeringsnøkkel og én nøkkelavtale-nøkkel | `Sources/CellBase/Identity/Identity.swift` | Godkjennere signerer med denne. Ingen forestilling om entitetstype. |
| Apple-nøkler: P-256 i Secure Enclave, `userPresence` + `privateKeyUsage` | `Sources/CellApple/IdentityVault.swift:683` | Ikke-eksporterbare. Kan bare gjøre vanlig ECDSA, ikke terskelprotokoller. |
| Vapor-nøkler: Ed25519 i programvare | `Sources/CellVapor/VaporIdentityVault.swift:1161` | Server-/scaffold-side. |
| Verifikator støtter bare `EdDSA/Curve25519` og `ECDSA/P-256` | `Sources/CellBase/Identity/IdentityPublicKeySignatureVerifier.swift` | En FROST-Ed25519-signatur verifiseres uendret. FROST-P-256 gjør ikke det (Schnorr, ikke ECDSA). |
| `EntityGenesisSeal`: entiteten forsegles til initiatoren, kan ikke oppheves | `Sources/CellBase/Identity/EntityGenesis.swift` | Riktig for personer. Feil for selskaper (ingen enkeltperson skal eie selskapsentiteten alene). |
| `IdentityLinkRegistry.sameEntityLink` og scope `same_entity` | `Sources/CellBase/Identity/IdentityLinkRegistry.swift` | En lenket identitet handler *som* entiteten. Må aldri brukes mellom person og selskap. |
| `CanonicalPayloadSignable` + `CanonicalPayloadEncoder` | `Sources/CellBase/Crypto/CryptoAgilityModels.swift` | Gjenbrukes for forslag og godkjenninger. |
| `SecretCredentialContract`: HPKE-wrapping til 2–8 mottakere | `Sources/CellBase/Crypto/SecretCredentialContract.swift:96` | Hver mottaker kan pakke ut *hele* hemmeligheten alene. Altså 1-av-n, ikke 2-av-n. |
| `ConferenceOrganizerAccessVerifier`: same-entity-VC + rolle-VC | `Sources/CellBase/Identity/ConferenceOrganizerAccessModels.swift` | Mønsteret for fullmaktsbevis finnes allerede. |
| `EntityAuthorityJournal` med hashkjede, epoch og signerte kvitteringer | `Sources/CellBase/PersistingCells/EntityAuthorityCommit.swift` | Revisjonslogg for selskapets handlinger. «Quorum» der gjelder replikaer, ikke signerere. |
| `TrustedIssuerCell`, `VCClaim`, `VCPresentation.holderBinding` | `Sources/CellBase/VerifiableCredentials/` | Tillitsankre og presentasjon. |
| `PurposeBoundExternalAction` med `requiresHumanApproval` | `Sources/CellBase/Agreement/PurposeBoundExternalAction.swift` | Naturlig sted å si «denne handlingen krever selskapsgodkjenning». |
| Prinsipper i Swarm-designet: «Entity er ikke autoritet», «en lenke er ikke en rettighet» | `Docs/Swarm_Identity_Admission_and_Entity_Link_NO.md` | Dette designet følger dem. |

Det finnes ingen modell for organisasjon, rolle, signaturrett eller flersignatur
i koden i dag. Alt under er nytt, men bygger på typene over.

## Hvorfor ikke låse opp selve nøkkelen

Den direkte versjonen av forslaget er: selskapets private nøkkel krypteres til
hver person med fullmakt (slik `SealedDatabaseSecret` gjør i dag), og den som
har fullmakt dekrypterer og signerer. Det har fire problemer:

1. **Det håndhever ikke «to eller flere».** Den første som pakker ut har hele
   nøkkelen og kan signere alene, nå og senere. Kravet om felles godkjenning
   blir en regel i klientkoden, ikke en egenskap ved kryptografien.
2. **Tilbakekalling krever rotasjon.** Når et styremedlem går av, må man anta
   at hen har en kopi. Hver rollebytte blir en nøkkelrotasjon hos alle
   motparter.
3. **Nøkkelen forlater Secure Enclave.** En importert nøkkel kan ikke legges i
   Secure Enclave, så selskapsnøkkelen ville levd i programvare på mange
   personlige enheter.
4. **Revisjonssporet sier hvem som *kunne* signere, ikke hvem som *gjorde* det.**

Å låse opp *bruken* gir det samme brukeropplevelsen (to personer trykker
«Godkjenn» med Face ID) uten disse svakhetene.

## Alternativer for nøkkellagring

| Modell | Håndhever 2-av-n | Nøkkel i Secure Enclave hos personer | Uttrykker norsk signaturrett («leder og ett styremedlem i fellesskap», prokura, beløpsgrenser) | Bytte av styre | Kompleksitet |
|---|---|---|---|---|---|
| A. Delt nøkkel kryptert til hver fullmektig | Nei | Nei | Bare i klientkode | Rotasjon | Lav |
| B. Ren terskelsignatur (FROST) blant personene | Ja, kryptografisk | Nei, andelene er programvare | Bare én fast terskel per nøkkel | Ny deling (reshare) | Høy |
| C. Policy-quorum + selskapshvelv som holder nøkkelen | Ja, i hvelvet | Ja | Fullt ut, policy er data | Ny policyversjon, ingen rotasjon | Middels |
| D. Ingen selskapsnøkkel; motparten verifiserer alle signaturene | Ja, hos verifikator | Ja | Fullt ut | Ny policy | Lav hos oss, høy hos hver motpart |
| **C + B (anbefalt mål)** | Ja, både i hvelvet og kryptografisk | Ja for godkjenning | Fullt ut | Ny policy; reshare sjelden | Høy, men i fase 2 |

**Anbefaling:** Bygg C nå. Behold D som det interne formatet (godkjenningsbeviset
er alltid med, så en HAVEN-motpart kan sjekke selv). Legg B til i fase 2 som
et ekstra lag: hvelvet holder én FROST-andel, og minst én annen andel må
bidra, slik at et kompromittert hvelv ikke kan signere alene.

Begrunnelsen for C før B: norsk signaturrett er sjelden en enkel terskel.
«Styrets leder alene, eller to styremedlemmer i fellesskap, eller daglig leder
for daglig drift under 100 000 kr» er tre regler med ulike personer og grenser.
Det er policy, og policy kan endres uten nøkkelseremoni. FROST alene kan bare
si «t av n». I tillegg kan Secure Enclave ikke holde FROST-andeler, og det
finnes ikke et modent Swift-bibliotek for FROST i dag (referanseimplementasjoner
er i Rust og vil kreve FFI; dette er antatt, ikke verifisert i denne runden).

FROST(Ed25519) er det riktige valget når B kommer, fordi den produserer en
vanlig Ed25519-signatur som `IdentityPublicKeySignatureVerifier` allerede
godtar. Ingen motpart trenger å vite at signaturen er laget i fellesskap.

## Modellen

### Entitetstyper

```swift
public enum EntityKind: String, Codable, Sendable {
    case person        // first-class, forseglet til initiator (dagens genesis)
    case organization  // styrt, forseglet til en styringspolicy
}
```

Invariantene:

- En personentitet kan aldri slettes eller overtas av en organisasjon.
- En organisasjonsentitet har ingen `same_entity`-lenker til personer.
  `IdentityLinkRegistry.sameEntityLink` må feile lukket når ankeret er en
  organisasjon. Personer får i stedet `acts_for`-relasjoner med et snevert
  scope (se fullmakter under).
- Organisasjonen kan selv ha enhets-identiteter (hvelvet, en server), og
  disse kan være `same_entity` med organisasjonen. De er maskiner, ikke
  personer.

### Organisasjonsgenesis

```swift
public struct OrganizationGenesisSeal: CanonicalPayloadSignable {
    var version: Int
    var anchorID: String
    var legalIdentifier: LegalIdentifier?   // orgnr / EUID, valgfri ved oppstart
    var initialPolicyHash: Data             // hash av GovernancePolicy v1
    var custodianKey: IdentityPublicKeyDescriptor
    var founders: [IdentityPublicKeyDescriptor]
    var approvals: [OrganizationApproval]   // alle grunnleggerne signerer
}
```

Forskjellen fra `EntityGenesisSeal` er at seglet er signert av *alle*
grunnleggerne og peker på en policy, ikke på én initiator. Et enkeltpersonforetak
blir en organisasjon med én grunnlegger og policyen «eieren alene», slik at
modellen er lik for alle selskapsformer.

### Styringspolicy

Policyen er et versjonert, signert dokument som speiler selskapets juridiske
struktur. Den er data, ikke kode.

```swift
public struct GovernancePolicy: Codable, CanonicalPayloadSignable {
    var policyID: String
    var version: Int                    // monotont økende, som epoch i EntityAuthority
    var previousPolicyHash: Data?       // hashkjede
    var members: [OrganizationMember]   // identitet + roller
    var rules: [SigningRule]
    var amendmentRule: String           // hvilken regel som kreves for å endre policyen
    var evidence: [PolicyEvidenceRef]   // f.eks. Brreg-attest, styrevedtak
    var validFrom: String
}

public struct OrganizationMember: Codable {
    var identity: IdentityPublicKeyDescriptor  // personens domene-identitet, ikke hele entiteten
    var roles: [OrganizationRole]              // .chair, .boardMember, .ceo, .procurist, .owner(share) ...
    var validFrom: String
    var validUntil: String?
}

public struct SigningRule: Codable {
    var ruleID: String                   // "signatur", "prokura", "daglig-drift"
    var anyOf: [ApprovalClause]          // én av klausulene må være oppfylt
    var actionClasses: [String]          // "contract.sign", "credential.issue", "payment" ...
    var limits: ActionLimits?            // beløp, valuta, varighet
    var excludedActions: [String]        // prokura: ikke salg/pantsettelse av fast eiendom
}

public struct ApprovalClause: Codable {
    var requirements: [RoleCount]        // alle må oppfylles: [{role: .chair, min: 1}, {role: .boardMember, min: 1}]
    var distinctPersons: Bool            // samme person teller ikke to ganger selv med to roller
}
```

Eksempel (et typisk AS):

```text
regel "signatur":  styrets leder alene  ELLER  to styremedlemmer i fellesskap
regel "prokura":   daglig leder og én prokurist i fellesskap, ikke fast eiendom
regel "drift":     daglig leder alene, beløp under 100 000 NOK, bare payment/contract.sign
amendment:         "signatur"
```

`distinctPersons` er viktig: en person som er både styreleder og styremedlem
skal ikke oppfylle «to styremedlemmer» alene.

### Forslag, godkjenning og godkjenningsbevis

```swift
public struct OrganizationActionProposal: CanonicalPayloadSignable {
    var proposalID: String
    var organizationAnchorID: String
    var policyHash: Data                 // låst til policyversjonen som gjaldt ved forslaget
    var actionClass: String
    var payloadHash: Data                // hash av det som faktisk skal signeres
    var payloadSummary: String           // det godkjenneren ser, menneskelesbart
    var amount: MonetaryAmount?
    var audience: String
    var createdAt: String
    var expiresAt: String
    var nonce: Data
    var proposer: IdentityPublicKeyDescriptor
}

public struct OrganizationApproval: CanonicalPayloadSignable {
    var proposalHash: Data
    var approver: IdentityPublicKeyDescriptor
    var role: OrganizationRole
    var decision: Decision               // .approve / .reject
    var approvedAt: String
    var freshAuthEvidence: IdentityLinkFreshAuthEvidence?  // gjenbruker passkey-/Face ID-beviset
    var signature: Data                  // med personens egen nøkkel (Secure Enclave)
}

public struct ApprovalBundle: Codable {   // «quorum-sertifikatet»
    var proposal: OrganizationActionProposal
    var approvals: [OrganizationApproval]
    var satisfiedRuleID: String
    var satisfiedClauseIndex: Int
}
```

Flyten:

1. Noen (en person eller en agent) lager et forslag. Forslaget inneholder
   hashen av nøyaktig det som skal signeres, ikke en åpen tillatelse.
2. Hvelvet finner hvilke regler som kan oppfylles og varsler de aktuelle
   personene (Binding / HavenAgentD).
3. Hver godkjenner ser `payloadSummary`, beløp og mottaker, og godkjenner med
   Face ID. Signaturen gjøres av personens egen nøkkel i Secure Enclave via
   eksisterende `Identity.sign(data:)`.
4. Godkjenninger samles asynkront til `expiresAt`. En avvisning fra en person
   med veto i regelen stopper forslaget.
5. Når en klausul er oppfylt, verifiserer hvelvet hele bundelen (se sjekkliste)
   og signerer `payloadHash` med selskapsnøkkelen.
6. Resultatet føres i selskapets `EntityAuthorityJournal`: forslag, alle
   godkjenninger, regelen som ble brukt og signaturen. Hashkjeden gjør loggen
   manipulasjonssikker.

Sjekkliste i hvelvet, alle må holde (feiler lukket):

- forslaget er ikke utløpt, nonce er ikke brukt (gjenbruk
  `CellSecuritySigningChallengeReplayStore`)
- `policyHash` er gjeldende policy, eller en policy som fortsatt er gyldig
  etter en eksplisitt overgangsregel
- hver godkjenning er signert av en nøkkel som står i policyen, med rollen den
  påberoper seg, innenfor `validFrom/validUntil`
- klausulen er oppfylt med distinkte personer
- `actionClass` og beløp er innenfor regelens grenser og ikke ekskludert
- godkjenningene peker på nøyaktig samme `proposalHash`
- fersk tilstedeværelse er bevist når regelen krever det

### Selskapshvelvet (custodian)

Hvelvet er en del av protokollen, ikke en driftsbeslutning per scaffold.
`OrganizationVaultCell` ligger i CellBase og oppfører seg likt i alle
scaffolds. Det eneste som varierer per plattform er hvor nøkkelen bor, og det
skjules bak en smal protokoll:

```swift
public protocol OrganizationKeyCustodian: Sendable {
    func publicKey(organizationAnchorID: String) async throws -> IdentityPublicKeyDescriptor
    func generateKey(organizationAnchorID: String) async throws -> IdentityPublicKeyDescriptor
    func sign(_ payloadHash: Data, organizationAnchorID: String) async throws -> Data
    var keyIsExportable: Bool { get }   // må være false i produksjon
}
```

- CellApple: P-256 i Secure Enclave (ikke-eksporterbar, som `IdentityVault` i dag).
- CellVapor: Ed25519 bak en KMS/HSM-adapter; programvarenøkkel bare i test,
  og da med `keyIsExportable == true` slik at policy kan nekte det.
- Hvelvet eksponerer bare signering av et verifisert `ApprovalBundle`, aldri
  nøkkelen. Samme prinsipp som `SecretUnwrappingProvider`.
- Hvelvet har ingen egen rett til å godkjenne. Det er en notarius, ikke en
  styreperson. `custodian.sign` kalles bare fra
  `OrganizationVaultCell` etter at `GovernancePolicyEvaluator` har godtatt bundelen.

**Gjenoppretting** gjøres ved ny nøkkel og ny policy (besluttet). Det finnes
ingen backup av selskapsnøkkelen og ingen Shamir-deling. Mister man hvelvet,
lager gjenværende medlemmer en ny `GovernancePolicy`-versjon med ny
`custodianKey`, godkjent etter `amendmentRule`, og den gamle nøkkelen merkes
tilbakekalt. Utstedte fullmaktsbevis signert med den gamle nøkkelen må
utstedes på nytt; verifikatorer følger policykjeden for å se at nøkkelbyttet
er legitimt.

### Fase 2: FROST-deling

Når C fungerer, kan selskapsnøkkelen genereres med FROST(Ed25519) som
2-av-3 eller (t+1)-av-(n+1), der hvelvet holder én andel og andelene for øvrig
ligger i programvarenøkkelbutikk hos utpekte personer eller deres egne
scaffolds. Godkjenningsflyten over er uendret; i tillegg bidrar én
andelsinnehaver med en signaturandel. Fordelen er at et kompromittert hvelv
ikke kan signere. Kostnaden er DKG-seremoni, reshare ved bytte av
andelsinnehavere, og to rundtrips per signatur. Dette bør avgjøres når C er i
bruk og vi vet hvor ofte styret byttes.

## Bevis overfor andre: fullmakts-VC

Når en person handler på vegne av selskapet, presenterer hen en VP med to
credentials, bundet til sin egen nøkkel via `VCPresentation.holderBinding` og
en challenge fra verifikatoren:

1. **Selskapsbevis** (`OrganizationIdentityCredential`), utstedt av en
   tillitsankret utsteder om selskapet: orgnr/EUID, navn, selskapets DID og
   nøkkel, gjerne hash av gjeldende styringspolicy. Kilden er i første omgang
   en HAVEN-utsteder som har sjekket Brønnøysundregistrene, på sikt et
   offentlig attest fra EU Business Wallet.
2. **Fullmaktsbevis** (`OrganizationMandateCredential`), utstedt av selskapet
   selv (signert med selskapsnøkkelen, altså etter quorum) til personens
   identitet:

```json
{
  "type": ["VerifiableCredential", "OrganizationMandateCredential"],
  "issuer": "did:web:eksempel.no",
  "credentialSubject": {
    "id": "<personens domene-identitet>",
    "actsFor": { "organization": "did:web:eksempel.no", "legalIdentifier": "NO:123456789" },
    "role": "procurist",
    "ruleID": "prokura",
    "actionClasses": ["contract.sign"],
    "limits": { "maxAmount": { "value": 500000, "currency": "NOK" } },
    "excludedActions": ["real_estate.transfer", "real_estate.mortgage"],
    "requiresCoApproval": true,
    "policyHash": "…",
    "validUntil": "2027-01-01T00:00:00Z"
  },
  "credentialStatus": { "type": "StatusList", "…": "…" }
}
```

Verifikatoren sjekker:

- VP-en er signert av nøkkelen i `credentialSubject.id` og svarer på min challenge
- fullmaktsbeviset er signert av nøkkelen i selskapsbeviset
- selskapsbeviset er signert av en utsteder `TrustedIssuerCell` stoler på
- handlingen er innenfor `actionClasses`, `limits` og ikke i `excludedActions`
- statuslisten sier at fullmakten ikke er tilbakekalt

Dette er nøyaktig formen `ConferenceOrganizerAccessVerifier` har i dag
(same-entity-VC + rolle-VC, med issuer- og bindingskontroll), generalisert fra
konferanse til selskap.

`requiresCoApproval: true` betyr at fullmakten alene ikke er nok: handlingen må
i tillegg bære en selskapssignatur som er laget via et godkjenningsbevis. Da
kan verifikatoren be om `ApprovalBundle` eller bare hashen av den.

### To måter å handle på

| | Personen signerer selv med fullmakts-VC | Selskapet signerer etter quorum |
|---|---|---|
| Hvem signerer | personens nøkkel | selskapsnøkkelen |
| Bevis | VP: selskapsbevis + fullmaktsbevis | selskapssignatur + (valgfritt) godkjenningsbevis |
| Passer for | daglig drift, enkeltfullmakter, innlogging som «X for selskap Y» | avtaler, utstedelse av credentials, endring av policy, alt som krever «i fellesskap» |
| Tilbakekalling | statusliste | policyversjon |

Begge trengs. Den første er det brukeren mener med «leverer en VC som beviser
påstanden». Den andre er det som gjør «to må godkjenne» ekte.

## Kilde til signaturrett

Signaturrett og prokura står i Foretaksregisteret. Rollene (styreleder,
styremedlem, daglig leder) er åpne i Enhetsregisterets API. Signatur- og
prokuratekst ser ut til å bli levert gjennom andre kanaler (f.eks. Infotorg, som
oppgir Brønnøysundregistrene som kilde), og teksten er ofte fritekst som
«Styrets leder og ett styremedlem i fellesskap». Dette må verifiseres før vi
bygger en import.

Forslag: Brreg-data blir *bevis* for en policy, ikke policyen selv. Selskapet
skriver policyen (med en mal per selskapsform), og en HAVEN-utsteder attesterer
at den er i samsvar med registeret. Avvik vises som advarsel. Dermed kan
selskapet ha strengere interne regler enn registeret, men aldri løsere.

EU Business Wallet-forslaget (Rådets forhandlingsposisjon 9. juni 2026,
mål om enighet innen utgangen av 2026) bruker begrepene *authorised
representative* og *mandate*, bruker EUID som identifikator, og krever at
roller og fullmakter er «verifiable, auditable, revocable and traceable».
Rådet presiserer at ordningen ikke endrer fullmakter gitt etter nasjonal rett.
Modellen over er laget for å kunne mappe til dette: `OrganizationMandateCredential`
tilsvarer et mandat, selskapsbeviset tilsvarer EBW-eierens identifikasjonsdata.

## Sikkerhetsgrenser

- **Det dette løser:** ingen enkeltperson kan signere for selskapet utenfor sin
  regel; rollebytte krever ikke nøkkelrotasjon; hver selskapssignatur kan
  spores til navngitte godkjennere.
- **Det dette ikke løser i fase 1:** et kompromittert hvelv kan signere alene.
  Det er derfor FROST er planlagt i fase 2, og derfor hvelvet skal ha
  ikke-eksporterbar nøkkel.
- **Tvang:** to personer kan presses til å godkjenne. Det er utenfor scope, på
  samme måte som i `Owner_Mediated_Cross_Scaffold_Association_Threat_Model.md`.
- **Hva godkjenneren ser:** sikkerheten står og faller på at `payloadSummary`
  er en ærlig gjengivelse av `payloadHash`. Hvelvet skal generere sammendraget
  fra payloaden, ikke ta det fra forslagsstilleren.
- **Policyendring er den farligste handlingen.** Den krever `amendmentRule`,
  bør kreve fersk tilstedeværelse, og bør ha en ventetid før den trer i kraft
  slik at andre medlemmer kan reagere.

## Beslutninger (Kjetil, 2026-10-08)

1. **Nøkkelmodell:** policy-quorum med selskapshvelv nå, FROST(Ed25519) i fase 2.
2. **Hvelvet er protokoll:** det ligger i CellProtocol og kan brukes av alle
   scaffolds. Bare nøkkellageret er plattformspesifikt (`OrganizationKeyCustodian`).
3. **Gjenoppretting:** ny nøkkel og ny policy. Ingen backup av selskapsnøkkelen.
4. **Signaturrett:** selskapet skriver policyen, Brreg attesterer den.
5. **Enkeltpersonforetak:** egen organisasjonsentitet med regelen «eieren alene».

## G2: implementeringsplan for CellProtocol

Prinsipp: få nye typer, gjenbruk det som finnes (`IdentityPublicKeyDescriptor`,
`IdentityLinkFreshAuthEvidence`, `CanonicalPayloadSignable`,
`CellSecuritySigningChallengeReplayStore`, `EntityAuthorityJournal`, `VCClaim`).
Hver PR er selvstendig, testet og uten endret wire-format for eksisterende typer.

**PR 1 – Modell og regelmotor (ren CellBase, ingen celler).**
Ny mappe `Sources/CellBase/Organization/`:
`EntityKind`, `GovernancePolicy` (med `OrganizationMember`, `SigningRule`,
`ApprovalClause`), `OrganizationActionProposal`, `OrganizationApproval`,
`ApprovalBundle` og `GovernancePolicyEvaluator` (ren funksjon: policy + bundle +
tid → godtatt regel eller presis feilkode). Tester: alene, i fellesskap,
prokura med unntak, beløpsgrense, samme person med to roller, utløpt forslag,
feil policyhash, godkjenning over annen proposalHash, rolle utenfor gyldighet,
avvisning med veto.

**PR 2 – Organisasjonsgenesis og grensen mot personer.**
`OrganizationGenesisSeal` (signert av alle grunnleggerne) og policykjeden
(`previousPolicyHash`, monoton versjon, endring bare via `amendmentRule`).
`IdentityLinkRegistry.sameEntityLink` og EntityAnchor feiler lukket for
person-identiteter mot et organisasjonsanker. Mal for enkeltpersonforetak
(«eieren alene») og AS (styreleder alene eller to styremedlemmer). Tester for
M1 og M4.

**PR 3 – Hvelvet.**
`OrganizationKeyCustodian`-protokollen, `OrganizationVaultCell`
(forslag inn, godkjenninger inn, signatur ut, nonce via replay-store,
journalføring i `EntityAuthorityJournal`), CellApple-custodian (Secure Enclave)
og CellVapor-custodian (KMS-adapter + test-backend). Tester for M2, M3, M6, også
under Linux/OpenCombine-gaten.

**PR 4 – Fullmakts-VC og verifikator.**
`OrganizationMandateCredential`-subject, utstedelse som en
`credential.issue`-handling gjennom hvelvet, og `OrganizationMandateVerifier`
generalisert fra `ConferenceOrganizerAccessVerifier` (selskapsbevis + fullmakt
+ holder-binding + grenser + status). Tester for M5.

**PR 5 – Brreg-attest.**
`OrganizationIdentityCredential` og en `TrustedIssuerCell`-profil som sammenligner
policy mot registerets roller. Forutsetter at kilden for signatur/prokura er
avklart (åpent spørsmål under).

**Utenfor CellProtocol:** godkjenningsflate i Binding (forslag, sammendrag,
Face ID) og eventuell scaffold-konfigurasjon. **Fase 2:** FROST(Ed25519) som en
ny `OrganizationKeyCustodian` der hvelvet bare holder én andel.

**Åpne spørsmål som ikke blokkerer PR 1–4:**
- Hvor signatur- og prokuratekst hentes fra (åpent API eller avtalekanal).
- Om policyendring skal ha en fast ventetid før den trer i kraft, og hvor lang.

## Mål for godkjenning (G1)

- M1: En person kan aldri bli `same_entity` med et selskap.
- M2: Ingen person får selskapets private nøkkel under normal drift.
- M3: «Styreleder og ett styremedlem i fellesskap» kan uttrykkes og håndheves.
- M4: Bytte av styremedlem krever ny policyversjon, ikke ny selskapsnøkkel.
- M5: En tredjepart kan verifisere at en person handler for selskapet med én VP.
- M6: Hver selskapssignatur kan spores til hvilke personer som godkjente.

## Kilder

- RFC 9591, FROST: https://www.rfc-editor.org/rfc/rfc9591.html
- Rådet, European Business Wallets, forhandlingsposisjon 9. juni 2026:
  https://www.consilium.europa.eu/en/press/press-releases/2026/06/09/european-business-wallets-council-adopts-negotiating-position/
- Oppsummering av forslagets artikler (EUID, mandat, segl):
  https://docs.igrant.io/regulations/reg-eu-business-wallets/
- Enhetsregisteret på data.norge.no:
  https://data.norge.no/en/datasets/68d08f28-a16d-4fab-a953-ed4ab08ce2e2/central-coordinating-register-for-legal-entities
- Prokura/signatur som tjeneste (kilde Brønnøysundregistrene):
  https://web.infotorg.no/developers/api/prokura-signatur
