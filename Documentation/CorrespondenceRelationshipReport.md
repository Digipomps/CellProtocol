| Krav | Test | Utfall | Bevis (kommando, exit-kode, antall tester) |
|---|---|---|---|
| 1. Eiersignert innslipp, cellebinding og smal avtale | `CorrespondenceRelationshipTests.testAdmissionRejectionsAgainstRelationshipCell`, `testUnsignedSubjectEncryptionKeySubstitutionIsRejected`; bolk-1-avvisningene | Kjørt grønt lokalt; 12 avvisningstilfeller mot relasjonscellen | `bash HAVEN-Deploy/_handoff/GRUNNMUR/wp-cellprotocol-grunnmur.sh codex/korr-relasjonscelle-20261007`, bygg/test exit 0; 1 614 tilfeller, 5 skipped, 0 feil; inkluderer 57 korrespondanse-/innslippstester |
| 2. Fornyelse og varig tilbakekall, også over await og omstart | `ExternalAgreementAdmissionTests.testRenewalWithLaterExpiryReplacesPreviousSubjectContract`, `testRevocationRejectsReplayAndSurvivesSnapshot`, `testRemovalWhileSubjectProofIsSuspendedCannotInstallMember`, `testAuditorFinalInstallRejectsRevokedContractWithStaleCallerSnapshot` | Kjørt grønt; begge kontrollmutasjonene gir forventet rødt | Samme fullportkommando, bygg/test exit 0; mutasjonene: test-exit 1, prøveskript-exit 0, én regresjon per mutasjon; `evidence/bolk2-mutation-{actor,restore}.txt` |
| 3. Eier og invitert sender/leser tekst og vedlegg | `CorrespondenceRelationshipTests.testLocalPurposeThreeVaultsTextAttachmentsFlowRenewalAndRevocation` | Kjørt grønt; 1 100 037 byte hver vei, identiske mottakerbyte | Samme fullportkommando, bygg/test exit 0; `evidence/bolk2-formaalsproeve.txt` |
| 4. Flow uten spørring, historikk med state, ikke-medlemmer og tilbakekall | Samme formålsprøve; eksisterende `CorrespondenceCellTests` | Kjørt grønt; fire nye poster kommer over Flow og åpnes direkte fra hendelsene; kvittering og vedleggshendelser mottas; eksisterende abonnement avsluttes ved tilbakekall | Samme fullportkommando, bygg/test exit 0; `evidence/bolk2-formaalsproeve.txt` |
| 5. Hele konvolutten og vedleggsbyte utløper uten innbokslesing | `CorrespondenceRelationshipTests.testEnvelopeExpiresWithoutInboxRead`; eksisterende vedleggstester | Kjørt grønt; kontrollen finner chunk før utløp, og ingen konvolutt/chunk etterpå | Samme fullportkommando, bygg/test exit 0; de 57 korrespondanse-/innslippstestene inkluderer 14 vedleggstester og to samtidighets-/timerregresjoner |
| 6. Vert/agent uten eiernøkkel kan ikke signere eller gi tilgang | `CorrespondenceRelationshipTests.testHostAndAgentCannotSignOrApplyRevocationWithoutOwnerKey`; bolk-1-avvisningene | Kjørt grønt; vertens nøkkellager mangler begge parters nøkler | Samme fullportkommando, bygg/test exit 0; `evidence/bolk2-formaalsproeve.txt` |
| Hele CellProtocol på Mac | Påkrevd grunnmurskript | Kjørt grønt på ba7a275; første ports ni røde tilfeller er rettet | `bash HAVEN-Deploy/_handoff/GRUNNMUR/wp-cellprotocol-grunnmur.sh codex/korr-relasjonscelle-20261007`; køjobb c90, bygg/test exit 0, 1 614 tilfeller: 1 609 passed, 5 skipped, 0 failed |

Lokalt portnotat ved PR-opprettelse. Dette er et historisk snapshot før første push: lokal port er grønn, GitHub CI er ennå ikke kjørt. Live PR/CI-status står i PR-en; endelig oppdragsrapport vedlikeholdes i HAVEN-oppgavemappens handoff/BOLK-2-RAPPORT.md.

## Gren, commit og PR

- Gren: `codex/korr-relasjonscelle-20261007`, fra `origin/main` `68069b6` (nett-fetch kontrollert).
- Bolk 1 tatt inn som `acf53c0`; vedleggsgrenen som `8a6f803`; ny implementasjon `02f5ac1`; skjerpet Flow-/historikkprøve `899a737`; utløps-/samtidighetsretting `7bb45e7`; kompatibilitetsretting `ba7a27584880055d566ff8374c1daebe5aa473ba` (grønn fullportkandidat).
- Eget arbeidstre: `_worktrees/cp-korr-relasjonscelle-20261007`.
- PR: ikke opprettet ennå. CI: ikke kjørt på kandidaten ennå. Ingen push før grønn fullport.
- Hovedarbeidstreet, a35 og eksisterende andre arbeidstrær er ikke endret. Ingen merge, tag, pinnendring eller deploy.

## MÅ 1 og BØR fra kontrollen

**MÅ 1 er rettet og funksjonsprøvd.** `GeneralAuditor` har en varig cutoff per subjekt (`revokedBefore`), serialisert sammen med kontrakter og medlemmer i `GeneralCell`. Tilbakekall og medlemsfjerning setter denne også når det ikke er et ferdig innslipp. Ekstern framlegging sjekker før nøkkelbevis og etter vilkår. Selve installasjonen sjekker i autorisasjonsactorens samme transaksjon. `authorizationContracts(for:)` sjekker også før og etter sikkerhets-await. Dermed kan en gammel kontrakt ikke gjenåpne tilgangen, og en framlegging som venter på nøkkelbeviset taper mot fjerningen. Omstart fra lagret JSON beholder sperren. Eiersignert tilbakekall binder celle, domene, subjekt, Contract-UUID, Agreement-UUID, tidspunkt og nonce; replay avvises atomisk.

Kontrollmutasjonene er **kjørt**, etter implementasjonen: fjerning av installasjonssperren gir rød actor-regresjon; fjerning av dekodingen av cutoff gir rød omstartsregresjon. Kilde ble gjenopprettet etter hver. En tredje mutasjon fjerner sekvensbindingen i utløpstimeren og gir forventet rød ID-gjenbruksregresjon; også den er gjenopprettet. Dette er ikke en påstand om at de nye testene ble kjørt på uendret main før implementasjon. Første kompileringsforsøk var rødt på en returtypefeil. Første formålsforsøk fant feil klientmeldings-ID i prøveoppsettet og at kontrakten beholdt utstederens vault-referanse; begge er rettet. En prøvevault manglet videresending av vault-referanse og ventet derfor uten at nøkkelbeviset startet; bare jobbens egen XCTest-prosess ble stoppet, og fixture ble rettet.

BØR:

1. GeneralCell registrerer `contractRejected` med egne grunnkoder for snapshot/debug, runtime, binding/bevis, avtalesnapshot, mal, vilkår/utløp/tilbakekall og installasjon. Relasjonscellens ekstra eksakthets-/krypteringsnøkkelkontroller returnerer avvisning før baseveien og har ikke egne sikkerhetshendelser. Dette loggapet er ikke fremstilt som løst fullt ut.
2. Avtalen og identitetsfeltene fryses; vilkårene får et offentlig snapshot av framleggeren. Det levende identity-objektet brukes til nøkkelbeviset. Kommentaren er presisert.
3. Cellebundne kontrakter signerer `signaturePurpose = haven.contract.admission.v2`; tilbakekall har et separat signert formål. Legacy-kontrakter med nil binding/purpose beholder signerte byte. Bolk-1-provens bundne kontrakter uten purpose må signeres på nytt for ekstern framlegging.
4. Eieren oppretter relasjonscellen én gang. GeneralCell genererer UUID, og vanlig dekoding gjenoppretter det. Vert/klient må beholde det ved restaurering; en ny relasjon/klone skal få nytt UUID og nye kontrakter. En test viser at bundet kontrakt ikke autoriserer et gjenopprettet snapshot med annet celle-UUID. `uuid` er fortsatt offentlig muterbar; det er ikke innført en ny global UUID-tjeneste eller uforanderlig eiendom.
5. Transporten svarer `accepted`, ikke `signed`. Swift-API-ens `.signed` beholdes for kompatibilitet og betyr at en allerede signert avtale er installert; verten signerer ikke.
6. Endret/fjernet binding legges fram for cellen; positiv eierskriving og filter ved gjenoppretting i en annen celle er prøvd. De nye historikk- og Flow-avvisningene kontrollerer feiltype. Bolk-1-filens øvrige eldre tomme catch-blokker er ikke alle omskrevet; ingen eksisterende test er fjernet eller svekket.

Ekstra funn: Subject-fingeravtrykket for signering er signert, men den top-level X25519-deskriptoren er det ikke. Relasjonscellen sammenligner derfor installert subject-nøkkel med nøkkelen i den signerte avtalen. Avtalens/utstederens eiernøkkel for kryptering må stemme med cellens betrodde eier. Testen bytter bare den usignerte top-level nøkkelen, viser at kontraktsignaturen fortsatt er gyldig, og viser at innslippet avvises.

## Første fullport og kompatibilitetsretting

Kjørt: første fullport på `7bb45e7` hadde bygg-exit 0 og test-exit 1, med ni røde eksisterende tester. Én bro-test mistet positiv lokal tilgang når klokken var fast etter medlemsfjerning. Åtte DeviceIngress-tester avviste kanoniske dokumenter fordi `Identity` fyller inn tomme properties ved dekoding, mens et rått publicIdentitySnapshot utelater dem. Dette var regresjoner i denne jobben, ikke klassifisert som rødt på main.

Rettet i `ba7a275`: offentlige Contract-deskriptorer normaliseres før dokumentet returneres; ny lokal eiersignatur utstedes etter cutoff og kontrollerer at actor-installasjonen faktisk lyktes. Hver fjerning flytter cutoff fram, også ved samme klokkeverdi, og inkluderer installerte kontrakttider. Ekstern framlegging avviser issuedAt senere enn vertens klokke, også innen legacy-verifiseringens 300-sekunders avvik. Dette unngår at en gyldig framtidsdatert ekstern kontrakt går foran en fjerning mens innslippet venter. Den gamle signaturverifiseringens klokkeavvik beholdes.

Fire nye tester dekker kanonisk wire-rundtur, fersk lokal reautorisasjon ved fast klokke, gjentatt fjerning mot ventende reautorisasjon og ekstern framtidsdatering innen legacy-avviket. Alle fire er kjørt grønne i den nye fullporten. Fullporten inkluderer også alle DeviceIngressContractTests og BridgeChannelTransportTests. Den ekstra b99-prøven ble avbestilt etter dette, fordi den ville gjentatt de samme grønne kontrollene. Ingen eksisterende test er endret som følge av disse feilene.

## Samtidig utløp

Kjørt på 7bb45e7: 53 fokuserte tester også med Thread Sanitizer, exit 0, uten rapportert datakappløp. Postlageret beskytter sekvens, endringer og JSON-snapshots med lås; en utløpstimer kan bare fjerne den sekvensen den ble opprettet for. 128 parallelle sendinger mens snapshots tas over utløp gir 128 ulike sekvenser og poster. En gammel timer kan ikke slette en senere melding med gjenbrukt ID. Kontrollmutasjonen for timeren gir test-exit 1 og prøveskript-exit 0. Dette er ikke en garanti for alle mulige samtidige runtime-operasjoner. CI gjentar også relasjonsprøvene med Thread Sanitizer.

## Sluttport på Mac

Kjørt på `ba7a27584880055d566ff8374c1daebe5aa473ba`: bygg exit 0 (98 s), test exit 0 (85 s). XCTest: 1 614 tilfeller, 1 609 passed, 5 skipped, 0 failed. Fordeling: CommonsLibrarian 26, CellNearby 3, CellBase 1 585. Ingen linjer med testfeil. De fem hoppede tilfellene er ikke fremstilt som gjennomførte tester. Swift Testing rapporterte 0 tilfeller. Maskin: macOS 27.0, Xcode 27.0, Apple Swift 6.4. Det oppgitte Tahoe-miljøet er dermed ikke prøvd her. Den midlertidige fullport-worktree ble fjernet av skriptet.

Bevis: `evidence/bolk2-fullport.txt`; rålogger: `HAVEN-Deploy/_handoff/GRUNNMUR/logg-ba7a275848/`.

## Lokal formålsprøve med én kommando

Fra HAVEN-roten:

```sh
bash HAVEN-Deploy/_handoff/KORR-UT/wp-korr-relation-focused.sh green-final
```

Dette er den korte gjentakbare prøven. Den siste kandidatens E/H/I-prøve ble kjørt som del av hele fullporten; beviset oppgir den faktiske kommandoen. Skriptet kjører bundet SwiftPM på kandidatens isolerte arbeidstre og inkluderer `CorrespondenceRelationshipTests.testLocalPurposeThreeVaultsTextAttachmentsFlowRenewalAndRevocation`. Tre uavhengige EphemeralIdentityVault-instanser er E, H og I. H huser cellen med offentlige beskrivelser; E signerer innslipp, fornyelse og tilbakekall; I beviser egen nøkkel. Prøven bruker **Resolver-rutet** `agreement.accept`, vanlig SET for tekst og chunk-overføring, og vanlig Flow for levering. Flow-konvoluttene åpnes direkte fra hendelsene. Ingen innbokslesing eller `readMessage` brukes for å få eller åpne disse; `readMessage` prøves også separat. Etter Flow-leveringen hentes `get state` og fire historikkposter kontrolleres. Begge parter åpner konvolutter og henter 1 100 037-byte vedlegg med bytekontroll. Den eksisterende abonnentens strøm avsluttes ved tilbakekall; senere Flow/state og gammel kontrakt avvises, også på gjenopprettet relasjonscelle.

Dette er **tre nøkkelkontekster i én lokal testprosess**, ikke tre OS-prosesser eller tre maskiner. Brukerens oppdrag krevde adskilte sammenhenger/nøkkellagre, som dette prøver. Nettbroen og staging er ikke vist gjennom denne prøven.

## Omfangskontroll av rapporten

Rapporten gjelder bolk-2-kravene til CellProtocol, ikke fullførte A3/C2/D3 i hele produktløpet. Tre lokale nøkkellagre beviser ikke at en fysisk stagingvert er uten nøkler, og nøkkelkravet beviser ikke fersk Touch ID eller eierens ja. Tilbakekall er varig i det nye snapshotet; det er ingen beskyttelse mot at en ondsinnet vert ruller tilbake til et gammelt snapshot.

Flow-grensen «ikke mer enn ytterdelen av konvolutten allerede viser» er tolket som en grense for åpne meldingsopplysninger. `message.stored` sender den krypterte konvolutten med eksisterende kryptohode, innpakkede nøkler og signatur, i tillegg til ytterdelen, slik at klienten faktisk kan åpne posten uten et nytt kall (A7 i formålsspesifikasjonen). Hendelsen er derfor større enn bare ytterdelen; det er ikke hevdet byte-/feltekvivalens. Emne, innhold og vedleggsmanifest forblir kryptert.

## HavenAgentD: kontrakten for bolk 3

Bare lest/implementert i CellProtocol; HavenAgentD er ikke endret.

- Eier oppretter/lagrer relasjonens adresse og stabile celle-UUID. Identitetsbeskrivelser i avtalen bruker UUID som visningsfallback, offentlige signerings- og X25519-nøkler og ingen person-/maskinmetadata.
- Signer `CorrespondenceAgreementTemplates.withAttachments(owner:)`, state `signed`, signatories `[ownerPublic, subjectPublic]`, med positiv duration høyst ett år. Malen har fire tekstoperasjoner, `feed`/`state` for lesing og ti vedleggshandlinger. Den gir ingen invitasjons- eller administrasjonsrett.
- `Contract.signed(agreement:issuer:subject:domain:issuedAt:targetCellUUID:)` kjøres hos E; domain er `correspondence`, target er relasjonens celle-UUID. Contract inkluderer `signaturePurpose`. JSON-Contract sendes med SET `agreement.accept` fra subjektets nøkkelbevisende klient. Svaret har `status: accepted|rejected`.
- Forny med samme operasjon og senere expiresAt; det erstatter den tidligere subjekt-/cellekontrakten. Hent/lagre den nye signerte avtalen hos klienten; serveren lager ikke en klientprofil.
- `ContractRevocation.signed(contract:owner:at:)` kjøres hos E. Send JSON med `cellUUID`, `subjectUUID`, `contractUUID`, `agreementUUID`, `domain`, `issuedAt`, `nonce`, `signature` til SET `agreement.revoke`; svaret er `revoked|rejected`. Signeringspayload inkluderer `haven.contract.revocation.v1`. Subjektet kan bare slippes inn igjen med en ny eiersignatur utstedt etter cutoff.
- Vanlige operasjoner er `inbox`, `readMessage`, `sendMessage`, `ackMessage` og de ti `attachments.*` i malen. Eieren bruker samme nyttelaster/klientprotokoll, og beviser nøkkel for hver vanlig handling.
- Vedlegg fra inviterte binder `agreementID` til Agreement-UUID. Vedlegg fra eieren bruker cellens UUID som `agreementID`. Mottakernøkler kommer fra nåværende medlemmer og eieren. `clientMessageID` ved forsegling må være vedleggets messageID. Kryptert vedleggsmanifest og AAD beholder melding-/avtalebindingen.
- Abonner med Flow på `haven.correspondence`. `message.stored` inkluderer `envelope` som en `CorrespondenceStoredEnvelope`: `outer` og `innerCiphertext`. Åpne denne direkte i klienten. Ytterfeltene er meldings-ID, sekvens, avsender-UUID, offentlig konvoluttformål, utløp og ciphertext-størrelse. Klartekst/emne/filnavn/nøkkel sendes ikke i hendelsen.
- `message.receipt` bærer messageID/receiptState; `message.read` og `message.expired` bærer meldingsmetadata. `attachments.*`-hendelser bærer messageID/senderIdentityUUID. Dette må ikke tolkes som at vedlegget er hentet, kjørt eller overdratt.
- GET `state`/`state(requester:)` gir innboksens historikkformat `haven.correspondence.inbox.v0`, med membershipFingerprint og ytre konvolutter. Etter gjenkobling: hent historikk, og les manglende konvolutter med `readMessage`. En klient får medlemsnøkler fra den eiersignerte avtalen, ikke fra usignert nettinput.
- Behold eksisterende Bridge-nøkkelbevis og lokal lease for `checkIdentityOrigin`; nye klientkommandoer må bruke den. Om den konkrete fjernklienten og bro-ruta gir dette for de nye kommandoene, **vet ikke**: det er ikke kjørt over nett i bolk 2.

API og garantier er også skrevet i CellProtocols `Documentation/CorrespondenceRelationship.md` på kandidatgrenen.

## Ikke vist

- GitHub CI er foreløpig ikke kjørt; PR er ikke opprettet ennå.
- Ingen uavhengig gjennomgang av hele bolk-2-diffen er utført i denne jobben. Bolk-1-kontrollen er grunnlaget for rettingen. Uavhengig bolk-2-gjennomgang gjenstår før merge.
- Ingen staging, to-maskiners håndtrykk, fjernlease, produksjonsklient, installasjon, Intel-/Tahoe-prøve, notarisering eller GUI-prøve.
- Ingen fersk Touch ID/passord-policy eller lås mellom agentens lesing/sending og eierens signering er etablert. En prosess som allerede har eierens private signeringskapabilitet, kan signere; «agent uten nøkkelen» er det som er prøvd.
- Stor reell fil, fysisk full disk, strømbrudd og overdragelse med ekte mottaker er ikke prøvd her. Eksisterende vedleggstester følger med.
- Utløp er prøvd i en kjørende lokal runtime, ikke på en stoppet vert eller mot backup. Hostens vanlige persistensintegrasjon må lagre snapshots; bolk 2 har ikke endret CellScaffold.
- Reduksjon av tilbakekallshistorikken, klokketilbakerulling og UUID-endring av en allerede levende relasjon er ikke etablert som støttede operasjoner. Tilbakekall er ikke prøvd mot tilbakerulling til et eldre snapshot eller en vert som endrer runtime/lagret tilstand.

Læringene `L-2026-10-07-a-contract-signature-binds-subject-signing`, `L-2026-10-07-correspondencecell-automatic-expiry-must-compare` og `L-2026-10-08-identity-decoding-changes-omitted-properties-to` er fanget, anvendt i kandidatens dokumentasjon og markert synket (dokumenter distribueres med git). `haven_learn.py check --strict` er exit 1 på andre, eksisterende åpne/udistribuerte læringer; disse læringene er ikke blant dem. Dokumentet ligger i et arbeidstre frem til publisering, og skal følge PR-en.

LOKAL PORT: GRØNN — historisk notat før PR-opprettelse; CI-status følger PR-en.
