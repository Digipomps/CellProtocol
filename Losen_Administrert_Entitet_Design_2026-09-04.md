# Losen som administrert entitet – kodeforankret designanalyse

**Dato:** 2026-09-04  
**Status:** Analyse og designanbefaling er fullført. Ingen implementasjon er gjort.  
**Avgrensning:** Statisk lesing av `CellProtocol` og `CellProtocolDocuments/Book/33_Correspondence_First_Class.md`. Ingen tester er kjørt. Ingen nøkler, invitasjoner, grants eller enrollments er opprettet. Staging er ikke berørt.

## Formål og mål

Formålet er å avgjøre hvordan Losen kan være en egen, varig CellProtocol-entitet under et utskiftbart administrativt mandat, uten at administratoren blir den tekniske eieren av entiteten eller at dagens kode tillegges garantier den ikke gir.

Målene var å:

1. plassere Identity-, owner- og EntityAnchor-autoritet korrekt;
2. avklare rollen til `EntityRepresentation`;
3. finne om en administratorbinding allerede finnes, og skissere den hvis den mangler;
4. vurdere gjenbruk av `Agreement`, `Grant` og `Contract`;
5. kontrollere om vaulten gjør Losens private nøkkel utilgjengelig for administratoren;
6. avgrense den reelle append-only-garantien og kartlegge skrivestier utenom journalen;
7. beskrive et sikkert administratorbytte; og
8. kontrollere påstandene i bok 33 §4A mot koden.

Alle analysemål er lukket. Selve implementeringen er uttrykkelig utenfor oppdraget.

## Kort konklusjon

Losen bør ha en stabil, egen `Identity` og være permanent `owner` av sin egen `EntityAnchorCell`. Administratoren skal modelleres som `Contract.subject` med snevre `Grant`-rettigheter og en ny, typet og entity-signert administrasjonsbinding. Administratoren skal aldri settes som `EntityAnchorCell.owner`.

`EntityRepresentation` er en perspektiv-/projeksjonsnode, ikke den autoritative entitetsposten. Autoriteten er i dag fordelt mellom den lagrede owner-identiteten, owner-bevis og signerte kontrakter for tilgang, `EntityAnchorCell.storage` for lokal tilstand, og `EntityAuthorityJournalDocument` bare for mutasjoner som faktisk går gjennom commit-stien.

Den viktigste korreksjonen er at CellProtocol-koden **ikke** gir en generell append-only-garanti. Commit-request er valgfri, `Object.set` erstatter eksisterende verdier, flere aktive skrivestier lagrer snapshot direkte, og den aktive EntityAnchor-lagringen har verken ekstern anti-rollback-forankring eller innkoblet replikaquorum. Den signerte hashkjeden er reell, men beskytter bare commit-deltakende historikk mot intern omskriving innenfor det materialet som faktisk lastes og verifiseres.

## 1. Losen må ha egen Identity og eie sin egen EntityAnchorCell

### Hva koden faktisk modellerer

`Identity` har egen UUID, offentlige signerings-/key-agreement-nøkler, grants, en standard `entityAnchorReference` og en vault-referanse (`CellProtocol/Sources/CellBase/Identity/Identity.swift:18-33`). `EntityAnchorCell` konstrueres med en `owner` og arver owner-semantikken fra `GeneralCell` både i Apple- og Vapor-implementasjonen (`CellProtocol/Sources/CellApple/Cells/EntityAnchorCell.swift:41-55`; `CellProtocol/Sources/CellVapor/Cells/EntityAnchorCell.swift:40-54`). App-oppsettet registrerer EntityAnchor som både `identityUnique` og persistent (`CellProtocol/Sources/CellApple/Cells/Porthole/Utility Views/Skeleton/AppInitializer.swift:221-228`).

I `GeneralCell` er owner en egen lagret egenskap, settes ved initiering og brukes til å opprette avtalemalen (`CellProtocol/Sources/CellBase/Cells/GeneralCell/GeneralCell.swift:301-329`). Owner-deskriptoren serialiseres som del av cellen (`CellProtocol/Sources/CellBase/Cells/GeneralCell/GeneralCell.swift:414-433`, `469-482`). Ved gjenopplasting kan en runtime-identitet bare bindes til lagret owner hvis identitetsreferanse og signeringskontroll matcher (`CellProtocol/Sources/CellBase/Cells/GeneralCell/GeneralCell.swift:339-382`). Resolveren gjør tilsvarende kontroll av owner-UUID, signeringsfingeravtrykk og runtime-bevis for identity-unique-celler (`CellProtocol/Sources/CellBase/Cells/CellResolver/CellResolver.swift:2766-2799`).

Tilgangspolitikken gir owner en særskilt bane: dersom owner-referansen matcher, avgjøres tilgangen av owner-bevis før Contract/Grant vurderes (`CellProtocol/Sources/CellBase/Cells/GeneralCell/CellAuthorization.swift:172-212`). En annen identitet kan få tilgang via en verifisert, signert Contract (`CellProtocol/Sources/CellBase/Cells/GeneralCell/CellAuthorization.swift:228-242`), og direkte UUID-oppløsning av en identity-unique celle tillater nettopp bevist owner eller aktiv Contract-subjekt (`CellProtocol/Sources/CellBase/Cells/CellResolver/CellResolver.swift:2814-2834`).

### Designavgjørelse

Derfor bør:

- Losens `Identity.uuid` og offentlige nøkkelfingeravtrykk være den stabile identitetsroten;
- Losens Identity være `owner` i Losens `EntityAnchorCell`;
- administratorens Identity være en ekstern kontraktspart, aldri owner;
- owner-endring behandles som identitets-/nøkkelrotasjon med eksplisitt migrasjonsprotokoll, ikke som vanlig administratorbytte.

Dette skiller tre ting som ellers lett blandes:

1. **Entitetsidentitet:** Losen.
2. **Teknisk owner/authority:** Losens signeringsidentitet.
3. **Administrativt mandat:** Kjetils eller en senere administrators Contract og administrasjonsbinding.

## 2. EntityRepresentation er en visning, ikke autoritativ entitetspost

Kjernetypen `Entity` er bare et alias for den dynamiske keypath-strukturen `Object`, altså `[String: ValueType]` (`CellProtocol/Sources/CellBase/ValueTypes/Types/Object.swift:6-8`). `EntityRepresentation` er derimot en `PerspectiveNodeImpl` som samler navn, relasjoner, interesser, formål og referanser for bruk i et perspektiv (`CellProtocol/Sources/CellBase/PurposeAndInterest/EntityRepresentation.swift:61-77`). Dens `projectionSource` forklares uttrykkelig som kilden som projiserte noden, slik at kildens bidrag kan erstattes eller fjernes (`EntityRepresentation.swift:68-75`).

At dette er en visning og ikke en full autoritativ post fremgår særlig av serialiseringen: `person`, `fulfilled` og `identities` blir med hensikt **ikke** kodet; detaljene skal bli i kildecellen (`EntityRepresentation.swift:131-153`). `PerspectiveEntityProjection` sier at en kildecelle «owns this slice», og en nyere projeksjon fra samme kilde kan legge til, oppdatere og fjerne noder i perspektivet (`CellProtocol/Sources/CellBase/PurposeAndInterest/PerspectiveEntityProjection.swift:23-36`, `136-193`).

### Hvor autoriteten faktisk ligger

Det finnes ikke én samlet «autoritativ entitetspost» i dagens kode. Autoriteten er lagdelt:

| Spørsmål | Autoritativt materiale i dagens kode |
|---|---|
| Hvem er entitetens tekniske owner? | `GeneralCell.owner`, persistet i cellen og kontrollert med signeringsbevis. |
| Hvem får gjøre hva? | Owner-banen og verifiserte `Contract`-objekter med `Grant` per keypath. |
| Hva er lokal, aktuell entitetstilstand? | `EntityAnchorCell.storage`, persistet som `keypathstorage.json`. |
| Hvilke mutasjoner har signert, hashkjedet historikk? | Bare entries i `EntityAuthorityJournalDocument`. |
| Hva vises i et perspektiv? | `EntityRepresentation`-projeksjoner, derivert fra kildeceller. |

`EntityAnchorCell` eksponerer riktignok `entityRepresentation` som en keypath med les/skriv-grant (`CellProtocol/Sources/CellApple/Cells/EntityAnchorCell.swift:69-81`; Vapor-ekvivalenten `CellProtocol/Sources/CellVapor/Cells/EntityAnchorCell.swift:68-82`). Det gjør ikke verdien autoritativ; det viser bare at den kan lagres i ankerets dynamiske storage.

Konsekvensen er at administrasjonsmandatet ikke bør plasseres i `EntityRepresentation`. Det hører hjemme som en typet styringspost under EntityAnchor, bundet til owner-identiteten og den kontrakten som gir administratoren myndighet.

## 3. Administratorfelt finnes ikke; en typet bindingspost må bygges

Et avgrenset søk i alle Swift-filer under `Sources` og `Tests` fant ingen forekomst av `administrator`, `administered`, `administrationBinding` eller `administratorIdentity` per 2026-09-04. De relevante modellene har heller ikke et slikt felt:

- `Identity` har identitet, nøkler, grants og anchor-referanse, men ingen administrator (`Identity.swift:18-33`).
- `GeneralCell` har `owner`, avtalegrunnlag, contracts og members, men ingen administratorrolle (`GeneralCell.swift:301-320`, `414-433`).
- `Agreement`, `Grant` og `Contract` har heller ingen administratormodell; de er generelle autorisasjonsprimitiver, se §4 nedenfor.

Påstanden «administrator er et felt» beskriver derfor ønsket design, ikke implementert tilstand.

### Foreslått minimal, typet modell

Dette er en skisse, ikke eksisterende kode:

```swift
public struct EntityAdministrationBindingV1: Codable, Equatable, Sendable {
    public static let schema = "haven.entity-administration-binding.v1"

    public var schema: String
    public var bindingID: String
    public var entityIdentity: IdentityPublicKeyDescriptor
    public var administratorIdentity: IdentityPublicKeyDescriptor

    // Existing authorization primitive. Contract.issuer must be the
    // entity owner; Contract.subject must be administratorIdentity.
    public var contract: Contract
    public var contractHash: String

    // Durable semantic scope; non-empty and included in binding signature.
    public var purposeRefs: [String]
    public var validFrom: String
    public var expiresAt: String

    // Append-only lifecycle links, not a mutable boolean status.
    public var predecessorBindingRef: String?
    public var revocationRecordRef: String?

    public var createdAt: String
    public var entityBindingSignature: Data
}

public struct EntityAdministrationRevocationV1: Codable, Equatable, Sendable {
    public static let schema = "haven.entity-administration-revocation.v1"

    public var schema: String
    public var revocationID: String
    public var bindingRef: String
    public var contractRef: String
    public var revokedAt: String
    public var reason: String
    public var successorBindingRef: String?
    public var signer: IdentityPublicKeyDescriptor
    public var signature: Data
}
```

Foreslåtte invariants:

1. `contract.issuer` og `agreement.owner` må matche lagret EntityAnchor-owner, altså Losen.
2. `contract.subject` må matche `administratorIdentity` med både UUID og signeringsfingeravtrykk.
3. `purposeRefs` må være ikke-tom, kanonisk sortert og del av den entity-signerte payloaden.
4. `contractHash` må beregnes av det eksakte Contract-snapshotet.
5. Aktiv status må **utledes** av gyldighetstid, Contract-status og fravær av en gyldig revokasjon; status skal ikke være et fritt overskrivbart felt.
6. Revokasjon skal være en ny, signert post som peker tilbake på binding og Contract. Den gamle bindingen skal ikke overskrives.
7. Bindinger og revokasjoner bør ligge under reserverte keypaths, for eksempel `governance.administration.bindings.<id>` og `governance.administration.revocations.<id>`.
8. Direkte `set` til disse røttene skal avvises. All persistens skal kreve commit, signaturkontroll og konfliktkontroll.
9. Contract-grants skal være minste nødvendige rettigheter: inspeksjon av avtalte projeksjoner, suspendering/resignasjon/wind-down gjennom dedikerte handlinger, og aldri en generell rett til å skrive hele `person`, `relations`, `proofs` eller `identityLinks`.

Bindingsposten er bevis på mandatet; `Contract` er den kjørbare tilgangsautorisasjonen. Begge trengs, og de må hashbindes til hverandre.

## 4. Agreement + Grant + Contract bør gjenbrukes, men to varige bindinger mangler

### Det som allerede kan gjenbrukes

`Agreement` inneholder owner, signatories, conditions, grants, en policybinding, duration og timestamp (`CellProtocol/Sources/CellBase/Agreement/Agreement.swift:6-30`). `Grant` er den konkrete koblingen mellom keypath og permission (`CellProtocol/Sources/CellBase/Agreement/Grant/Grant.swift:6-22`). `Contract` tar et snapshot av avtalen og binder med utsteders signatur til issuer, én subject, domain, issuedAt og expiresAt (`CellProtocol/Sources/CellBase/Agreement/Contract.swift:11-31`, `74-108`). Kommentaren i koden avgrenser formatet til én issuer-signatur, bundet til ett subject; det er ikke et bilateralt signaturformat (`Contract.swift:18-21`).

`GeneralCell.addAgreement` gjør allerede den riktige rollefordelingen for delegasjon: owner signerer en Contract der den innmeldte identiteten er subject, og autorisasjonen installeres (`GeneralCell.swift:1298-1322`). Contracts vurderes senere mot keypath-grants (`CellAuthorization.swift:228-242`). Dette er riktig fundament for administratortilgang.

### Det som mangler nøyaktig

#### A. Varig formålsbinding til administrasjonsmandatet

`Agreement` har ingen `purposeRef`/`purposeRefs` i de kodede feltene (`Agreement.swift:18-30`). `Grant` inneholder bare UUID, navn, permission og keypath (`Grant.swift:12-22`). `Contract.SigningPayload` signerer avtale-snapshot, issuer/subject, domain og tid, men ingen separat, obligatorisk administrasjonsformålsreferanse (`Contract.swift:74-84`).

Det finnes nærliggende, men utilstrekkelige mekanismer:

- `SignedAgreementRecord.purpose` er en valgfri `String` (`CellProtocol/Sources/CellBase/Agreement/SignedAgreementEntity.swift:6-36`).
- `SignedAgreementEntityCommitRequest.metadata` er en utypet `Object` (`CellProtocol/Sources/CellBase/Agreement/SignedAgreementEntityCommit.swift:15-27`). Metadata tas med i immutable content hash (`SignedAgreementEntityCommit.swift:197-229`), men koden krever ikke at den inneholder et administrasjonsformål eller at formen er forståelig og validerbar.
- `PurposeBoundActionIntent` har en eksplisitt `primaryPurposeRef`, men gjelder ett konkret eksternt effect/intent (`CellProtocol/Sources/CellBase/Agreement/PurposeBoundExternalAction.swift:102-175`). Authorizeren sier uttrykkelig at vanlig Cell-autorisasjon leverer authority, mens purpose/policy bare kan innsnevre én ekstern handling (`PurposeBoundExternalAction.swift:613-703`). Dette er ikke en varig rolle-/mandatbinding i Contract.
- `EntityAuthorityCommitRequest` signerer en `purposeRef` for én mutasjonsbatch (`CellProtocol/Sources/CellBase/PersistingCells/EntityAuthorityCommit.swift:80-97`, `131-170`). Det sier hvorfor akkurat den mutasjonen utføres, ikke hvorfor administratorforholdet finnes over tid.

Det som må bygges er derfor en obligatorisk, signert og varig `purposeRefs`-binding i `EntityAdministrationBindingV1`, hashbundet til Contract-snapshotet.

#### B. Signert revokasjonsreferanse og revokasjonspost

Verken `Agreement`, `Grant` eller `Contract` har `revocationReference`, og denne mangler dermed også i `Contract.SigningPayload` (`Agreement.swift:18-30`; `Grant.swift:17-22`; `Contract.swift:63-84`). `GeneralCell.removeMember` fjerner subjectets contracts og membership fra den mutable autorisasjonssnapshoten (`GeneralCell.swift:1844-1867`; `CellProtocol/Sources/CellBase/Cells/GeneralCell/Cast/GeneralAuditor.swift:465-473`), men produserer ikke en varig, signert revokasjon som en senere verifikator kan følge.

Identity-linking viser en nærliggende datatype, men løser ikke administratorproblemet. `IdentityLinkRecord` har valgfri `revocationReference`, og `IdentityLinkRevocation` kan ha et proof (`CellProtocol/Sources/CellBase/Identity/IdentityLinkingModels.swift:247-365`). Dette gjelder «same entity»-identitetslenking, ikke et administrasjonsmandat. Den aktive revoke-stien overskriver dessuten den lagrede identity-link-recorden med status `revoked` og ny tid i stedet for å appendere en separat revokasjonspost (`CellProtocol/Sources/CellApple/Cells/EntityAnchorCell.swift:970-1005`; Vapor `CellProtocol/Sources/CellVapor/Cells/EntityAnchorCell.swift:926-961`). At credential-utstedelsen kan ta en revokasjonsreferanse (`CellProtocol/Sources/CellBase/Identity/IdentityLinkCompletion.swift:303-332`) gjør ikke referansen obligatorisk for Contract eller administratorbinding.

Det som må bygges er en separat, canonical-signert `EntityAdministrationRevocationV1`; bindingsposten må inneholde eller deterministisk kunne avlede en referanse til riktig revokasjonsserie. En usignert statusendring eller bare `removeMember` er ikke nok som historisk bevis.

## 5. Vaulten garanterer ikke at administratoren mangler tilgang til entitetsnøkkelen

Det smale `IdentityVaultProtocol` eksponerer signering, ikke rå privatnøkkel (`CellProtocol/Sources/CellBase/Identity/IdentityVaultProtocol.swift:6-18`). Det kunne ha vært et godt sikkerhetsgrensesnitt. Men den parallelle, offentlige `IdentityKeyRoleProviderProtocol` krever `privateKeyData(for:role:)` (`CellProtocol/Sources/CellBase/Crypto/IdentityKeyRoleProviderProtocol.swift:11-14`), og Apple-`IdentityVault` konformerer til begge (`CellProtocol/Sources/CellApple/IdentityVault.swift:33-49`).

Den avgjørende implementasjonen er `CellProtocol/Sources/CellApple/IdentityVault.swift:422-447`:

- for signeringsrollen hentes en `SecKey` fra keychain, og `SecKeyCopyExternalRepresentation` forsøkes; lykkes det, returneres de rå private nøkkelbytene (`:429-433`);
- ellers returneres legacy `vaultIdentity.privateKey` eller `privateSecureKey.compressedKey` (`:434-437`);
- for key agreement returneres keychain-data eller tilsvarende rå/private felt (`:438-446`).

Apple-implementasjonen har reell lokal beskyttelse: nøkkelreferansen hentes med autentiseringskontekst (`IdentityVault.swift:650-674`), og lagres med `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` og `.userPresence`/`.privateKeyUsage` (`IdentityVault.swift:676-707`). Nyere P-256-generering bruker en permanent keychain-nøkkel og access control (`IdentityVault.swift:1397-1443`). Men opprettelsen angir ikke Secure Enclave-token, og API-et prøver eksplisitt å eksportere private data. Dette er derfor lokal tilgangskontroll, ikke kryptografisk eller arkitektonisk bevis for at administratoren aldri kan hente nøkkelen.

Legacy-modellen beholder og serialiserer dessuten rå private felt (`IdentityVault.swift:1460-1478`, `1590-1615`, `1656-1673`). Den statiske testen for nye identiteter kontrollerer at `privateKey` er tom og at en keychain-tag finnes, men kontrollerer ikke at `privateKeyData(for:role:)` er ute av stand til å eksportere nøkkelen (`CellProtocol/Tests/CellBaseTests/AppleIdentityVaultKeyStorageTests.swift:14-31`). Testen er kun lest; den ble ikke kjørt.

### Hva som må til for reell ikke-ekstraherbarhet

1. Fjern rå privatnøkkel-retur fra produksjonsgrensesnittet. `IdentityKeyRoleProviderProtocol` bør tilby operasjoner som `sign`, `deriveSharedSecret` eller handle-baserte nøkler, aldri `Data` for privat materiale.
2. Generer Losens signeringsnøkkel i et faktisk ikke-ekstraherbart keystore, for eksempel Secure Enclave på støttet Apple-maskinvare eller HSM/threshold-tjeneste på server. For Apple betyr dette blant annet riktig token-attributt og en nøkkeltype/algoritme som støttes av enklaven.
3. Skill «nøkkelen kan ikke eksporteres» fra «administratoren kan få vaulten til å signere». User presence alene hindrer ikke en autorisert administratorprosess i å bruke nøkkelen. Signeringsoperasjoner må også håndheve Losen-spesifikk policy, purpose, capability, rate/approval-regler og audit.
4. Avvikle eller eksplisitt migrere legacy rå private felt. Decode/encode-kompatibilitet må ikke bli en varig eksportkanal.
5. Dokumenter recovery og rotasjon uten å gjøre administratoren til nøkkelholder: threshold recovery, uavhengige custodians eller owner-signert nøkkelrotasjon med ekstern checkpoint er mer konsistent enn eksport av privatnøkkelen.
6. Legg til tester som forventer at private nøkkelbytes ikke kan hentes, også via protokoll-cast, samtidig som tillatte signerings- og key-agreement-operasjoner virker.

Før disse punktene er implementert, er formuleringen «Losen holder sin egen nøkkel, administratoren gjør det aldri» en designintensjon, ikke en kodegaranti.

## 6. Append-only er ikke en generell garanti

Dette er analysens viktigste korreksjon.

### 6.1 Det som faktisk er beskyttet

`EntityAuthorityJournalDocument` validerer fortløpende revision, `previousHash`, payload-binding, entry-hash og receipt-binding (`CellProtocol/Sources/CellBase/PersistingCells/EntityAuthorityCommit.swift:350-430`). Replay utfører entries i rekkefølge (`:433-441`), receipts kan verifiseres mot authority (`:444-446`), og `appending` håndhever blant annet forventet epoch/revision/head og idempotens før en ny signert receipt og entry appendes (`:449-560`). Dette er en reell signert hashkjede for entries som går inn i journalen.

`EntityValidatedContactRecordV1` er et konkret eksempel på en strengere beskyttet postfamilie: direkte mutasjon av reserverte validated-contact-keypaths avvises, og persistence-envelope må ha commit/purpose-krav (`CellProtocol/Sources/CellBase/PersistingCells/EntityValidatedContactRecordV1.swift:6-19`, `26-57`, `82-96`). Dette motbeviset er viktig: koden har byggesteiner for sterkere invariants, men de gjelder ikke automatisk hele entiteten.

### 6.2 Commit er valgfri, også i aktiv kode

`EntityBatchPersistEnvelope.commitRequest` er optional og default er `nil` (`CellProtocol/Sources/CellBase/PersistingCells/EntityBatchPersistEnvelope.swift:42-59`). Dekoderen godtar eksplisitt fravær og setter `nil` (`:93-97`). Den statiske kompatibilitetstesten forventer at legacy-envelope uten commit fortsatt er gyldig (`CellProtocol/Tests/CellBaseTests/EntityAuthorityCommitTests.swift:8-23`).

Begge aktive EntityAnchor-implementasjoner har en eksplisitt `commitRequest == nil`-gren som anvender mutasjonene og skriver snapshot uten journal-entry eller receipt:

- Apple: `CellProtocol/Sources/CellApple/Cells/EntityAnchorCell.swift:785-836`, særlig `806-817`.
- Vapor: `CellProtocol/Sources/CellVapor/Cells/EntityAnchorCell.swift:749-799`, særlig `769-780`.

Den journalførte batchbanen er dessuten owner-only i dagens implementasjon: `requesterProvesOwnership` kreves før append (`Apple EntityAnchorCell.swift:789-800`; `Vapor EntityAnchorCell.swift:753-766`). En Contract-subjekt-administrator kan derfor ikke bare bruke denne banen. Å gjøre administratoren til owner for å komme rundt dette ville ødelegge rollemodellen. Riktig løsning er en capability-aware commit-protokoll der administratorens signerte forespørsel kan autoriseres av Contract, mens authority-receipt fortsatt utstedes av Losens owner-policy/nøkkel.

### 6.3 Mutasjoner kan overskrive keypaths

Den generelle `Object.set` erstatter terminalverdien direkte; ved tom path erstattes hele roten, og ellers settes ny verdi på valgt segment (`CellProtocol/Sources/CellBase/ValueTypes/Types/Object.swift:382-414`, offentlig keypath-API `:511-534`). Journal-replay bruker den samme `set`, slik at en senere journalført mutasjon til samme keypath semantisk vinner (`EntityAuthorityCommit.swift:433-441`).

«Append-only journal» betyr derfor ikke «append-only entitetstilstand». Det betyr høyst at en ny mutation-entry bevares i journalhistorikken. Den materialiserte keypath-verdien er fortsatt siste skrivning.

### 6.4 Aktive skrivestier som går utenom authority-journalen

Følgende stier muterer `storage` og kaller snapshotlagring uten å opprette en `EntityAuthorityJournalEntry`:

| Skrivesti | Apple | Vapor | Journal? |
|---|---|---|---|
| `person` set-intercept | `EntityAnchorCell.swift:204-220` | `EntityAnchorCell.swift:202-218` | Nei |
| `proofs` set-intercept | `:222-243` | `:220-241` | Nei |
| legacy `relations`-logikk | `:260-331` | `:258-319` | Nei |
| generisk FlowElement med `keypath`/`value` | `:332-409`, videre til `set` i `:770-778` | `:320-371`, videre til `set` i `:733-740` | Nei |
| batch uten `commitRequest` | `:806-817` | `:769-780` | Nei |
| signed-agreement-record og receipt | `:552-630` | `:550-593` | Egen immutable-content-sjekk, men ikke authority-journal |
| identity-link approval/completion/revoke og fallback-set | `:891-1005` | `:847-961` | Nei |

`saveKeypathStorage` verifiserer at en legacy-skriving ikke kolliderer med allerede journalførte keypaths ved å replaye journalen og sammenligne snapshot (`Apple EntityAnchorCell.swift:738-748`; Vapor `EntityAnchorCell.swift:701-716`). Det er en nyttig konfliktvakt, men den journalfører ikke legacy-skrivningen, hindrer ikke overskriving av aldri-journalførte keypaths og gjør ikke historikken komplett.

Det finnes også en runtime-asymmetri: Apples generiske `set` avviser både direkte validated-contact- og relation-record-mutasjon (`Apple EntityAnchorCell.swift:770-778`), mens Vapor bare avviser validated-contact (`Vapor EntityAnchorCell.swift:733-740`). Apple validerer begge postfamilier i batch (`Apple EntityAnchorCell.swift:799-800`), Vapor bare validated contact (`Vapor EntityAnchorCell.swift:763`). Dette gjør det ekstra uforsvarlig å formulere en plattformuavhengig generell append-only-garanti.

### 6.5 Aktiv lagring mangler anti-rollback og innkoblet quorum

Commit-receipten forteller sannheten om dagens standard: `durabilityLevel = atomic_file_replace_without_power_loss_proof`, `replicationState = local_authority_only`, `replicaAckCount = 0`, `quorumSatisfied = false` og `distributedCommit = false` (`EntityAuthorityCommit.swift:204-266`). Commit request default-er til `requiredReplicaAcks = 0` (`:131-166`), og journalappend avviser faktisk alle ikke-null quorumkrav som utilgjengelige (`:492-497`). `EntityAuthorityCommitState` annonserer tilsvarende local-only og `distributedQuorumAvailable = false` (`:564-597`).

Apple og Vapor skriver snapshot- og journaldata som hele filer med `.atomic` replace (`CellProtocol/Sources/CellApple/Extensions/GeneralCell+File.swift:78-86`; `CellProtocol/Sources/CellVapor/GeneralCell+File.swift:67-71`). I commit-banen skrives journalfilen og snapshotfilen i to separate operasjoner (`Apple EntityAnchorCell.swift:826-830`; Vapor `EntityAnchorCell.swift:790-793`). Dette er ikke et append-only lagringsmedium og ikke én felles atomisk transaksjon.

Ved oppstart lastes den lokale journalen, strukturen og signatures verifiseres, og den replayes over lokalt snapshot (`Apple EntityAnchorCell.swift:650-676`; Vapor `EntityAnchorCell.swift:613-640`). Verifikasjonen oppdager en intern ødelagt kjede, men koden sammenligner ikke head/revision mot et eksternt, monotont checkpoint. Dersom både snapshot og journal rulles tilbake til et eldre, internt gyldig par, har denne aktive load-stien ingen høyere minimumsrevision å oppdage det mot. Dette er anti-rollback-gapet.

Repoet inneholder separate byggesteiner for replika og quorum:

- replika-persistens skiller transportlevering fra varighet og sier at atomic replace ikke beviser overlevelse ved strømtap (`CellProtocol/Sources/CellBase/PersistingCells/EntityAuthorityReplicaStore.swift:32-73`);
- replika-store leser tilbake eksakte bytes før signert acknowledgement (`EntityAuthorityReplicaStore.swift:113-215`);
- admission, durability-nivå og quorum-certificate er modellert (`CellProtocol/Sources/CellBase/PersistingCells/EntityAuthorityReplication.swift:41-69`, `651-679`, `828-885`).

Men de aktive Apple/Vapor `EntityAnchorCell`-stiene ovenfor oppretter eller krever ikke et slikt quorum-certificate. Eksistensen av typene er derfor ikke det samme som en aktiv quorumgaranti.

### 6.6 Nødvendig korreksjon i arkitektur og språk

Før følgende er gjort, bør dokumentasjon bare love «signert, hashkjedet historikk for commit-deltakende mutasjoner», ikke generell append-only:

1. reserver governance-, agreement-, identity-link- og andre historiske keypaths;
2. avvis alle direkte/legacy writes til dem i både Apple og Vapor;
3. krev `commitRequest` for disse skjemaene og fjern `nil`-kompatibilitet der garantien påstås;
4. journalfør administratorbinding og revokasjon som nye records, aldri statusoverskrivning;
5. koble Contract-subjekt-autorisasjon inn i commit uten å gjøre subject til owner;
6. gjør journal + materialisert snapshot crash-konsistent, eller gjør snapshot fullstendig regenererbart og ikke-autoritativt;
7. pin høyeste kjente `(epoch, revision, headHash)` utenfor den rollbackbare lokale filgruppen;
8. krev verifisert replikaquorum/certificate før noe omtales som distributed commit;
9. harmoniser Apple/Vapor-reglene og legg inn kontrakttester for bypass-forsøk og full rollback.

## 7. Administratorbytte er enkelt bare når administratoren er Contract-subjekt

### Riktig bytte

Når Losen forblir owner, er administratorbytte en mandatendring:

1. signer en revokasjon/resignasjon for gammel `EntityAdministrationBindingV1`;
2. fjern eller deaktiver gammel administrators autorisasjons-Contract;
3. opprett en ny binding og owner-signert Contract med ny administrator som subject;
4. behold samme Losen-Identity, EntityAnchor-UUID, owner-deskriptor, journal authority og historikk;
5. la ny binding peke på forgjenger og gammel revokasjon peke på eventuell etterfølger.

Koden støtter grunnmekanikken for steg 2 og 3: owner kan utstede subject-bundet Contract (`GeneralCell.swift:1298-1322`) og fjerne subjectets authorization (`GeneralCell.swift:1844-1867`; `GeneralAuditor.swift:465-473`). Den mangler den typede, signerte og append-only livssyklusen som gjør byttet historisk etterprøvbart.

### Hva som brekker hvis administratoren gjøres til owner

1. **Administrator blir ubetinget authority, ikke delegat.** Owner-bevis vurderes før Contract og trenger ingen snever Grant (`CellAuthorization.swift:194-212`). Formål, expiry og revokasjonsbane blir ikke det konstitutive tilgangsgrunnlaget.
2. **Identity-unique-oppløsning bindes til feil identitet.** Resolveren krever at requester matcher lagret owner-UUID og signeringsfingeravtrykk (`CellResolver.swift:2766-2799`). EntityAnchor blir i praksis administrators identity-unique celle, ikke Losens.
3. **Owner er persistet grunnmateriale.** Owner serialiseres i `GeneralCell` (`GeneralCell.swift:414-433`, `469-482`). Et «enkelt feltbytte» er derfor endring av cellens authority-root, ikke bare en administrativ referanse.
4. **Eksisterende authority-journal er signert av gammel owner.** Ved innlasting verifiseres alle receipts mot `storedOwnerIdentity` (`Apple EntityAnchorCell.swift:650-676`; Vapor `EntityAnchorCell.swift:613-640`). Erstatter man owner-deskriptoren med ny administrator, vil eldre receipts ikke verifisere mot den nye nøkkelen. Koden har ingen owner-rotasjonskjede som tillater flere historiske authority-nøkler.
5. **Signed-agreement commit forventer dagens owner både som issuer og subject.** Apple-stien kontrollerer eksplisitt Contract mot `storedOwnerIdentity` i begge roller (`Apple EntityAnchorCell.swift:552-562`; Vapor har samme mønster i `:550-560`). En owner-endring endrer dermed også hva denne lagringsstien anser som gyldig authority-materiale.
6. **Revokasjon blir identitetsovertakelse.** Man kan ikke trekke tilbake administrators mandat uten samtidig å rotere selve owner-roten, reetablere resolver-binding, håndtere gamle signatures og definere journalmigrasjon.
7. **Historisk kontinuitet blir tvetydig.** Gamle signatures er fortsatt kryptografisk verifiserbare med gammel offentlig nøkkel, men den aktive modellen mangler et signert owner-succession-bevis som forteller hvorfor ny owner skal arve samme entitet og historikk.

Konklusjonen er kategorisk: ikke bruk `EntityAnchorCell.owner` som administratorfelt. Bygg subject-bundet administrasjon i stedet.

## 8. Bok 33 §4A: påstander som ikke holder mot koden

Kilde: `CellProtocolDocuments/Book/33_Correspondence_First_Class.md:199-268`.

| Bokpåstand | Vurdering mot kode | Nødvendig rettelse |
|---|---|---|
| §4A, linje 201–203: Losen «er bygget» som egen entitet og er knyttet til en administrator. | **Holder ikke som nåtilstandsbeskrivelse.** Egen Identity + owner-anker er en forsvarlig design, men det finnes ingen administratorfelt/type eller Losen-spesifikk binding i koden. | Skriv «skal bygges» og gjør administratorbindingen eksplisitt til manglende implementasjon. |
| Linje 207–215: konstruksjonen er ordinær i lov og «arver» svar om mandat, ansvar og revokasjon. | **Kan ikke utledes av koden og er ikke juridisk revidert her.** Protokolltyper skaper ikke i seg selv rettslig status, ansvar eller representasjonsmyndighet. | Merk som juridisk hypotese som må forankres per jurisdiksjon og organisasjonsform; ikke som kodefaktum. |
| Linje 226: entiteten holder sin egen nøkkel. | **Ikke garantert.** Apple-vaulten eksponerer `privateKeyData(for:role:)` og forsøker rå eksport av signeringsnøkkelen. | Formuler som designkrav inntil ikke-ekstraherbar keystore og operasjonsbasert API er implementert og testet. |
| Linje 226–227: administratoren holder aldri entitetens private nøkkel. | **Ikke garantert.** Keychain/user presence er ikke det samme som at administratorens program/prosess ikke kan eksportere eller bruke nøkkelen. Legacy private bytes finnes også. | Skill ikke-ekstraherbarhet fra bruksmyndighet og dokumenter begge kontrollene. |
| Linje 227–229: administratorbytte er endring i én record, ikke re-founding. | **Bare sant i foreslått subject-modell; ikke implementert.** Det finnes ingen slik record. Hvis administrator er owner, er byttet en authority-root-rotasjon og gammel journal verifiseres ikke under ny owner. | Gjør påstanden betinget av stabil Losen-owner og ny signert binding/revokasjonskjede. |
| Linje 231–236: administrator kan ikke retroaktivt omskrive historikken. | **Holder ikke generelt.** Flere aktive writes går utenom journal, keypaths kan erstattes, identity-link revoke overskriver record, og lokal lagring mangler ekstern anti-rollback. | Avgrens til journalførte commits, eller implementer kravene i §6.6 før sterkere språk brukes. |
| Linje 238–240: administrator er et felt med purpose, expiry og revocation path «som enhver grant». | **Feil i nåværende kode.** Feltet finnes ikke. `Grant` har bare keypath/permission, Agreement/Contract mangler obligatorisk administrasjons-purpose og revocation-ref. | Erstatt med den foreslåtte typede bindingen; ikke si at dette finnes allerede. |
| Linje 244: administratoren «answers for» det entiteten sender. | **Ikke en kodeegenskap.** Contract kan vise delegert tilgang, men rettslig/organisatorisk ansvar følger ikke automatisk. | Skill verifiserbar teknisk delegasjon fra juridisk ansvar. |
| Linje 245: mandatet kan trekkes tilbake når som helst uten å slette entitet/historikk. | **Målbart designmål, men ikke komplett implementert.** Authorization kan fjernes mutabelt; signert revokasjonsrecord og generell historikkbeskyttelse mangler. | Skriv som krav og referer til binding/revokasjon. |
| Linje 246: alt entiteten holder er lesbart for administratoren. | **Ikke strukturell garanti og bør ikke være standard.** Lesetilgang avhenger av Grants per keypath. | Gjør dette til eksplisitt, begrenset policyvalg; vurder dataminimering og need-to-know. |
| Linje 247–248: mottaker kan alltid verifisere både entitet og administrator. | **Ikke etablert av den undersøkte koden.** Det finnes ingen administratorbinding som en correspondence-envelope kan referere til og verifisere. | Gjør dette til protokollkrav: envelope/delegation-ref + innhenting og validering av binding, Contract og revokasjon. |
| Linje 252–256: nøkkelen «svarer» på impersonation, og synlig delegasjon hindrer parkering av ansvar. | **Overdrevet.** Nøkkelkontroll hjelper autentisitet, men løser ikke kompromittert vault, policy-misbruk eller ansvar. Synlig delegasjon er heller ikke implementert som administratorbinding. | Avgrens til autentisitet under antakelse om ukompromittert nøkkel; skill teknisk sporbarhet fra ansvar. |
| Linje 266–268: nøkkel holdes av entiteten, historikk kan ikke omskrives, administratorfelt kan endres. | **Alle tre er foreløpig designpåstander, ikke samlede kodegarantier.** | Erstatt konklusjonen med en implementasjonsport: ikke-ekstraherbar nøkkel + obligatorisk journal/anti-rollback + typet subject-binding. |

Den nærliggende §4.3-påstanden «Nothing new is required» (`Book/33_Correspondence_First_Class.md:176-180`) holder derfor heller ikke fullt ut for en administrert entitet. `Identity`, `Agreement`, `Grant` og `Contract` kan gjenbrukes, men typet administrasjonsbinding, signert revokasjon, Contract-subjekt-integrasjon i commit og reell historikk-/rollback-beskyttelse er nytt arbeid.

## 9. Anbefalt implementasjonsrekkefølge

Dette er en designrekkefølge, ikke utført arbeid:

1. Definer og canonicaliser `EntityAdministrationBindingV1` og `EntityAdministrationRevocationV1` med signeringspayloads og strenge invariants.
2. Reserver governance-keypaths og avvis direkte set i både Apple og Vapor.
3. La Losen-owner utstede Contract til administrator-subjekt med minste nødvendige Grants og eksplisitt expiry.
4. Gjør purposeRefs og revocation-serie obligatorisk og hashbind dem til Contract.
5. Utvid authority commit til å godta Contract-autorisert requester uten å gjøre requester til authority/owner; owner-policy signerer receipt.
6. Flytt alle styrings- og historiske writes til obligatorisk commit og fjern nil-bypass for beskyttede skjema.
7. Gjør snapshot derivert fra journal eller innfør transaksjonell recovery mellom journal og snapshot.
8. Koble inn replica-store og quorum certificate der distributed/anti-rollback-garantier skal gis; pin høyeste head eksternt.
9. Fjern rå privatnøkkel-API, migrer legacy key material og bruk ikke-ekstraherbare operasjonsnøkler.
10. Legg til kontrakttester for owner-vs-subject, administratorbytte, revoke, direkte-write-bypass, rollback og Apple/Vapor-paritet.
11. Rett bok 33 §4A fra nåtidspåstander til betingede designkrav til implementasjonen består disse portene.

## 10. Evidens, usikkerhet og falsifisering

### Hovedpåstander og avgjørelse

| Påstand | Støtte | Mot-/avgrensende evidens | Avgjørelse |
|---|---|---|---|
| Losen bør være egen owner | Owner er persistet authority-root; Contract gir delegatbane. | Krever at Losen faktisk kan operere owner-nøkkelen under policy. | **Støttet design.** |
| EntityRepresentation er autoritativ post | Ingen: typen er projeksjonsnode og utelater sentrale data ved encode. | Den kan ligge som keypath i EntityAnchor. | **Avvist. Den er visning/projeksjon.** |
| Administratorbinding finnes | Bounded fraværssøk fant ingen type/felt. | Generelle Contract/Grant-primitiver finnes. | **Avvist som nåtilstand; ny type kreves.** |
| Agreement/Grant/Contract kan brukes alene | De gir issuer–subject–domain–expiry og keypath rights. | Varig admin-purpose og signert revocation-ref mangler. | **Delvis: gjenbruk fundamentet, utvid med binding.** |
| Vault betyr at admin aldri kan hente nøkkel | Det smale vault-protokollet bruker sign-operasjon. | Apple implementerer offentlig raw-key retrieval. | **Avvist som kodegaranti.** |
| EntityAnchor er generelt append-only | Signert hashkjede finnes. | Optional commit, overwrite, bypass-writes, local-only og rollback-gap. | **Avvist generelt; sant kun for commit-deltakende journalentries.** |
| Adminbytte er en enkel record-endring | Sant i foreslått subject-binding. | Falskt og brytende dersom administrator er owner. | **Betinget støttet.** |

### Hva ville falsifisere eller endre konklusjonene

- En eksisterende, obligatorisk og runtime-validert administratorbinding utenfor de søkte Swift-kildene ville endre fraværsfunnet; ingen slik kilde ble funnet i avgrensningen.
- En produksjonsvariant av vaulten med ikke-ekstraherbar nøkkel kan styrke nøkkelpåstanden for den varianten, men den kan ikke oppheve at dagens offentlige Apple-provider tilbyr raw-key-metoden.
- En vert som tvinger alle writes gjennom commit kan gi sterkere operasjonell praksis, men bypass-stiene i selve EntityAnchor består og er derfor fortsatt en protocol/runtime-risiko.
- Et eksternt, monotont checkpoint eller aktivt quorum som ikke finnes i denne workspacen kan redusere rollback-risiko i en deployment. Det er ikke dokumentert eller koblet inn i de inspiserte aktive stiene.
- Juridisk status og ansvar kan ikke avgjøres av Swift-koden; dette krever separat, offisiell juridisk kildekontroll.

## 11. Q1–Q10 kontrollmål

| Mål | Resultat |
|---|---|
| Q1 Position-change traceability | 100 %. Hver korreksjon av bokteksten er knyttet til konkret kodeevidens. |
| Q2 Mixed-ledger ratio | Ingen ønsket ratio. Ledgeren beholder både støtte (owner/Contract/hashkjede) og motbevis (nøkkeleksport/bypass/rollback); syv bestillingskonklusjoner ble vurdert, ikke antatt. |
| Q3 Audit-status honesty | 100 % for load-bearing kodepåstander: navngitt fil og linje. Juridiske påstander er eksplisitt markert ikke revidert. |
| Q4 Narrative independence | Alle hovedfunn holder både under bokas positive framing og en skeptisk framing; kvalifikasjoner står i samme ledger. |
| Q5 Falsifiability audit | 100 %. Falsifikatorer/oppgraderende evidens er listet i §10. |
| Q6 Natural-experiment identification | Ikke anvendelig: ingen atferdsmessige counterfactuals ble sannsynlighetsvurdert; eksisterende Apple/Vapor-stier er direkte kodeobservasjoner. |
| Q7 Revealed-preference test | Ikke anvendelig: analysen tilskriver ingen aktør motiver. |
| Q8 Terminal adjudication rate | 100 %: alle syv hovedpåstander og alle tekniske påstander i §4A-tabellen er avgjort eller avgrenset til eget juridisk arbeid. |
| Q9 Steelman sourcing | Motvektene kommer fra koden selv: validated-contact-guard, signert journal og separate quorumtyper er sterkeste evidens for eksisterende beskyttelse. |
| Q10 Concession asymmetry | 0 uforankrede innrømmelser/posisjonsendringer. |

## 12. Metode og begrensninger

Dette er en bounded, statisk repository-analyse. Direkte evidens er hentet fra 32 konkrete filer: 31 Swift-kilde-/testfiler i `CellProtocol` og bok 33 i `CellProtocolDocuments`. Lesing av tester er brukt som dokumentasjon på forventet wire-kompatibilitet; ingen test er kjørt. Ingen runtime, staging, nettverk eller eksterne deploy-konfigurasjoner er undersøkt.

Det er ikke gjort juridisk vurdering av påstandene om selskaper, stiftelser, ansvar eller mandat. Rapporten sier bare at disse påstandene ikke kan etableres av koden og derfor ikke bør presenteres som kodegarantier.

Ingen eksisterende kildefil er endret som del av analysen. Rapporten er det eneste nye artefaktet.
