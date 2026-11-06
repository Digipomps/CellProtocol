# Testplan: invitasjon og chat på tvers av HAVEN-flater

Dato: 2026-11-04 (Europe/Oslo). Forfatter: claude-code (sky). Status: **G1-kandidat**, venter på Kjetils godkjenning før implementering av testdrivere.

Kilder: CellProtocol `953e87f`, CellScaffold `b3563b3`, Binding `f7386a4`, HavenAgentD `42d57ad`, SwiftWebScaffold `89f6681`, PyCellProtocol (interop-matrise). Alle påstander under er lest i kildekode eller dokumentasjon i disse revisjonene; det som ikke er kjørt er merket `(uverifisert)`.

Vedlegg: `Docs/Testing/Invite_Chat_Permutasjonsmatrise_2026-11-04.md` (generert av `Docs/Testing/invite_chat_permutations.py`).

---

## 1. Hensikt

Vi skal bevise at en person kan invitere en annen part inn i en samtale, at parten kommer inn, og at meldinger går begge veier, på alle flater HAVEN faktisk har i dag. Testen skal være så nær ekte bruk som mulig: Kjetil som ekte bruker, pluss AI-personaer som opptrer som andre mennesker, kjørt i sverm.

### Formålstre (kort)

- **F0 Invitasjon og chat virker mellom reelle parter**
  - M1 En invitasjon utstedt på flate X kan aksepteres av en part på flate Y, og begge ser samme tråd.
  - M2 Meldinger sendt av den ene parten blir synlig for den andre uten manuell oppfrisking utover produktets egen mekanisme (25 s revisjons-heartbeat, Porthole-websocket, bridge-flow).
  - M3 Uinviterte, tilbakekalte og utløpte parter kommer ikke inn, og mister tilgang når invitasjonen trekkes.
  - M4 Gruppe (3+) virker der produktet lover det.
  - M5 Alle resultater har evidens (skjermbilde/trace/respons/revisjon) og registreres i VIRKER-ledgeren.
- **F1 Testoppsettet er gjenbrukbart**
  - M6 AI-personaer kan startes som prosesser med egen identitet, uten å røre produksjonsdata.
  - M7 Matrisen kan kjøres på nytt på en revisjon med én kommando per lag.

---

## 2. Hva som finnes (kart)

### 2.1 To lag med chat

| Lag | Hva | Hvor | Identitet |
|---|---|---|---|
| **Protokoll** | `CellBase.ChatCell`: `sendMessage`, `audience.inviteIdentities`, `generateInvitationArtifacts`, `acceptInvitationArtifact`, `audience.admissionConditions` (`invitationAccepted` / `member`) som `LookupCondition` på Agreement. E2E-kryptering og rekey ved medlemsendring. | CellProtocol `Sources/CellBase/Cells/Chat/ChatCell.swift`, `ChatInvitationProofUtility.swift`. Tester: `ChatCellTests` (48), `ChatAgreementAdmissionTests` (7). | Ed25519-identitet i vault; bridge-kanal `org.haven.bridge-channel.v1` |
| **Produkt** | `cell:///PersonalChatHub` (Butler Chat / Co-Pilot Chat) med REST `/personal-copilot-v1/chat/api/*`; konferansechat; Chat MVP; Arendalsuka. | CellScaffold `Sources/App/Controllers/VaporPersonalCopilot.swift`, `VaporConferenceMVP.swift`, `VaporChatMVP.swift`. Binding `Binding/ChatWorkbenchParityCells.swift`, `BindingNativeChatTransport.swift`. | FidoUser-sesjon (web) eller nativt bevis `X-Haven-Chat-Proof` etter person-link-seremoni |

Ingen av lagene har i dag en test som sender chat over en ekte bridge/WebSocket med to separate prosesser, bortsett fra interop-matrisen (2.4).

### 2.2 Flater

| Kode | Flate | Inngang | Hvem kan bruke | Tester som finnes |
|---|---|---|---|---|
| S1 | Butler Chat / Co-Pilot Chat (`PersonalChatHub`) | Web: `/porthole?configurationName=Samtaler&configurationEndpoint=cell:///PersonalChatHub`. Native: `BindingPersonalChatHubCell` + `BindingNativeChatTransport` mot samme REST. | Innlogget FidoUser; nativt bevis krever fullført person-link | `InviteChatEndToEndTests` (17), `ChatConversationJoinLinkTests`, `NativeChatAuthenticationTests`, Playwright `invite-chat-group-binding.spec.js` (kun localhost), Binding `Inv10ChatEndToEndTests` (in-process fake server) |
| S3 | Konferanse deltakerchat (`ConferenceChatLaunch`) | `/conference-participant` (krever innlogging), `conferencePersona`-nøkkel for demo-personaer | Deltaker, organisator; Binding har lokal adapter `(uverifisert)` | `ConferenceMessageExchangeAcceptanceTests`, `ConferenceProofChatLaunchCellTests`, `scripts/staging-conference-message-acceptance.js`, Playwright `conference-demo.smoke.spec.js` |
| S4 | Chat MVP (delt `cell:///Chat`) | `/chat-mvp`, passkey (WebAuthn) + `ensurePaidChatEntry` | Betalende bruker | `ChatMVPRoutesTests`, `ChatCellAuthorBindingTests` (UPRØVD i VIRKER) |
| S5 | Arendalsuka deltakerchat | `/arendalsuka` (full Porthole når innlogget), `chat.generateConnectKey`, `chat.sendRequest` | Innlogget deltaker | `ArendalsukaPrivateAgendaItemInviteTests`, `arendalsuka-participant-smoke.js` |
| S6 | Protokoll-ChatCell over bridgehead | `InteropPeer` (Swift, CellScaffold `Sources/InteropPeer`), Python `cellprotocol_scaffold.interop_peer`, Go `cmd/interop-peer`. Op-er: `init`, `serve`, `invitation`, `agree`, `call`, `remote`. | Hver peer er sin egen identitet og node | PyCellProtocol `interop/matrix/run_matrix.py` (3 flyter × vert/gjest-par; Python og Go i CI, Swift-peer skal legges til) |
| S7 | SwiftWebScaffold `ChatCell` | `POST /api/cell/set` med `CellRouteAuthentication` | Ingen identitets-UI, ingen bevis-utstedelse | Kun rutebevis-tester; `Public/index.html` poster uten bevis og får trolig 401 `(uverifisert)` |
| S8 | Assistant Correspondence | `/haven/api/assistant-correspondence/v1/*`, onboarding `/haven/assistant-correspondence/onboard/:inviteID` | HavenAgentD som gjest, eier godkjenner i Binding | `AssistantCorrespondenceInvitationsTests`, HavenAgentD `CorrespondenceMCPTests` |
| S9 | AgentConversationInbox | Binding `AgentConversationClient` ↔ HavenAgentD `AgentConversationFlowSubscriber`, topic `haven.agent.conversation` | Eierens telefon og eierens agent | `AgentConversationFlowSubscriberTests`, `DeviceActionRelayTests` |

Utelatt som chat mellom parter: Developer Workbench-hjelperen (kun bruker → AI, Butler-knappen åpner S1), Butler-widgetflaten (fjernet fra skjelett 2026-10-13), Kallimachos (bruker → kilde-grunnet AI).

### 2.3 Invitasjonsveier

| Kode | Vei | Utsteder | Mottaker | Fører inn i |
|---|---|---|---|---|
| V1 | In-app invitasjon: `POST chat/api/invite` → `accept` / `decline`. Levetid 7 d (1 s–7 d). Ventende mottaker ser ingen historikk. | Innlogget bruker | Innlogget bruker (valgfritt levert til mottakers `ContactEndpoint`) | S1 |
| V2 | Join-lenke: `POST chat/api/conversation/join-link` → `GET/POST /chat/join/:token`. Utfall: joined / alreadyParticipant / inactive 410 / blocked 403 / notFound. | Innlogget bruker | Hvem som helst med lenke; anonym sendes til `/login?next=` | S1 |
| V3 | Ekstern samarbeidslenke: `collaboration/prepare-external` → `/personal-copilot-v1/collaborate/:token` (`claim`, `decline`, `respond`, `fork`, `withdraw`). Krever konto, sesjonskvittering, CSRF, bevis på gjestens hjemmenøkkel, eiers `identity-binding/approve`, signert Agreement, chat-aksept. | Innlogget bruker | Utenforstående (ny konto) | S1 |
| V4 | Offentlig landing: `HavenInviteTicket` publisert til `/i/api/publish` → `/i/<token>` → `HavenInviteContactRequest` via `/i/:token/reply`. Gir ingen rettighet i seg selv, bare «lag egen entitet» og «send kontaktforespørsel tilbake». Ingen e-post sendes av tjeneren. | Binding `InvitationCell` eller interop-peer `invitation` | Person uten HAVEN | S1 (etterfulgt av V1) og S6 |
| V5 | `ChatInvitationArtifact` → `ChatInvitationAcceptance` → Agreement med `invitationAccepted`/`member` over autentisert bridge | ChatCell-eier | Identitet med egen vault | S6, S3 (`proofChat.generateArtifacts`, lokal aksept bare i samme runtime), S7 |
| V6 | Konferanse `discovery.startChat` / `discovery.startGroupChat`; Control Tower `sessionThread.postMessage` | Deltaker / moderator | Deltaker | S3 |
| V7 | Arendalsuka `chat.generateConnectKey` / `chat.sendRequest` → gjensidig kontakt | Deltaker | Deltaker | S5 |
| V8 | Ingen invitasjon: betalt inngang | – | Betalende bruker | S4 |
| V9 | Assistant-correspondence invite-fil (`inviteID`/`inviteSecret`), `scripts/create-assistant-correspondence-pilot.py`, agent kjører `haven-correspondence-mcp setup --invite`, status `pending_approval`, eier godkjenner i Binding | Eier | HavenAgentD | S8 |
| V10 | Ingen invitasjon: AgentConversationInbox-sløyfen | – | Egen agent | S9 |

Forutsetninger som ikke er chat-invitasjoner, men som åpner aktører:

- **Person-link-seremoni** (QR/nearby, `/link`, `IdentityLinkFlow`): nødvendig før Binding kan snakke nativt med S1. QR er transport, ikke rettighet.
- **Workbench-tilgangstoken** (`/workbench/access/:token`): gir Workbench, ikke chat.
- **Scanner/nearby-invitasjon** (`EntityScannerCell.invite`): peer-sesjon, ikke koblet til chat.

### 2.4 Verktøy for simulerte brukere

| Verktøy | Hva den kan | Hva den ikke kan |
|---|---|---|
| **Interop-peer** (Swift/Python/Go) | Egen identitet og node per prosess; utsteder invitasjon på egen `/i/`-landing; aksepterer; ber om Agreement; sender og leser chat over bridge. Styrt med JSON-linjer på stdin. Kjører på Linux (Python/Go) og macOS (alle tre). | Ingenting på produktlaget (S1, S3). |
| **HTTP-konto** (Playwright `request`-kontekst) | `/auth/register` lokalt, så full `chat/api/*` som ekte bruker: invite, accept, send, join-link, collaborate. | Nativt bevis; staging-registrering er ikke verifisert (se 7). |
| **UserSimulationScaffold** (swarm) | `VirtualUser` med atferd lurker/reader/agentConversationUser/requester/reconnectingMobile/slowSubscriber over bridgehead eller nativePorthole; identiteter `simulation.<runId>.user.<n>`; koordinator/arbeider over `SIMULATION_*`. | Har ingen chat-atferd. Ny atferd `chatParticipant` er en PDD-kandidat, ikke del av denne planen. |
| **HavenAgentD** | Korrespondanse-postkasse (S8) og prompt-sløyfe (S9). | Kan ikke delta som likeverdig part i en ChatCell/PersonalChatHub-tråd, og kan ikke utstede invitasjoner. |
| **Persona-seed** | `Documentation/TestData/Entity/EntityAnchorChatInviteCandidates.example.json` har `agentKind: ai-persona` med `simulated-endpoint`. Kan brukes som kontaktlister for V1-levering. | – |
| **Konferanse-personaer** | `playwright/conference-demo.personas.json`: organizer, admin-observer, participant, participant-foreign, sponsor, demo-gov, demo-design, demo-ops, demo-group-anchor via `conferencePersona`. | Gjelder bare S3. |

---

## 3. Dimensjoner og permutasjoner

Fem dimensjoner: **flate** (8) × **invitasjonsvei** (10) × **vert** (6 aktører) × **gjest** (6 aktører) × **kardinalitet** (1:1, gruppe). Teoretisk 5 760 kombinasjoner. Etter reglene i generatoren (hvilke veier fører inn i hvilken flate, hvilke aktører kan stå på hver side, hvor gruppe finnes, og at V3/V4 krever en kald utenforstående) gjenstår **139 meningsfulle kombinasjoner**: 38 `klar`, 92 `delvis`, 9 `gap`.

Aktører:

| Kode | Aktør | Hvordan opprettes |
|---|---|---|
| K | Kjetil, web | Egen konto i Porthole |
| KN | Kjetil, native Binding | Telefon/Mac med fullført person-link mot samme scaffold |
| P | AI-persona med web-konto | `/auth/register` + LLM-styrt driver over `chat/api` |
| I | AI-persona som interop-peer | Prosess per persona, LLM-styrt driver over stdin |
| S | Swarm VirtualUser | `docker-compose.swarm.yml`, kun lesende på bridge-flow |
| D | HavenAgentD | Eksisterende daemon på Mac, egen identitet |

Flate × vei (fra vedlegget):

| Flate | V1 | V2 | V3 | V4 | V5 | V6 | V7 | V8 | V9 | V10 |
|---|---|---|---|---|---|---|---|---|---|---|
| S1 Butler | klar | klar | klar | delvis | – | – | – | – | – | – |
| S3 Konferanse | – | – | – | – | delvis | klar | – | – | – | – |
| S4 Chat MVP | – | – | – | – | – | – | – | delvis | – | – |
| S5 Arendalsuka | – | – | – | – | – | – | delvis | – | – | – |
| S6 Protokoll | – | – | – | klar | klar | – | – | – | – | – |
| S7 SwiftWeb | – | – | – | – | gap | – | – | – | – | – |
| S8 Korrespondanse | – | – | – | – | – | – | – | – | klar | – |
| S9 AgentInbox | – | – | – | – | – | – | – | – | – | klar |

Det er ingen vei fra en interop-peer (I) inn i Butler Chat (S1), og ingen vei for en web-konto (P/K) inn i protokoll-chatten (S6) uten en signerende klient. Binding (KN) er den eneste aktøren som kan stå i begge lag (nativt bevis mot S1, og absorbering av `cell://staging…/Chat` mot S6 ifølge `ScaffoldChat.md`, uverifisert).

### 3.1 Kjernesett (prioritert, 28 tilfeller)

Hvert tilfelle kjøres først lokalt, så på staging. «Ekte bruker» betyr Kjetil. IDene brukes i evidensmapper.

| ID | Flate / vei | Vert → gjest | Kard. | Hva som bevises | Lag |
|---|---|---|---|---|---|
| IC-01 | S6 / V5 | I(swift) → I(py) | 1:1 | Invitasjonsartefakt, aksept, Agreement `invitationAccepted`, send/les over bridge | protokoll |
| IC-02 | S6 / V5 | alle 9 vert/gjest-par Swift/Py/Go | 1:1 | Samme bytes og samme verdikt på tre språk | protokoll |
| IC-03 | S6 / V5 | I → I | gruppe | Tre peers i samme ChatCell, rekey ved medlemsendring | protokoll |
| IC-04 | S6 / V5 negativ | I → fremmed | 1:1 | Uten bevis, tilbakekalt, utvidet grant, droppet betingelse avvises | protokoll |
| IC-05 | S6 / V4 | I → I | 1:1 | Ticket på `/i/`, svar med kortkode, utsteder ser svaret | protokoll |
| IC-10 | S1 / V1 | P → P | 1:1 | Invitasjon, aksept, meldinger begge veier, revisjon øker ved melding, ikke ved skriving | produkt web |
| IC-11 | S1 / V1 | P → P, P | gruppe | Tre web-personaer i én tråd (utvider `invite-chat-group-binding.spec.js`) | produkt web |
| IC-12 | S1 / V1 | K → P | 1:1 | Ekte bruker i Porthole inviterer persona via den rendrede knappen; persona svarer; Kjetil ser svaret innen heartbeat | blandet |
| IC-13 | S1 / V1 | P → K | 1:1 | Persona inviterer Kjetil; Kjetil aksepterer i Porthole | blandet |
| IC-14 | S1 / V2 | K → P | 1:1 | Join-lenke; persona uten sesjon får `/login?next=`, med sesjon joined; revokert gir 410 | blandet |
| IC-15 | S1 / V3 | K → P(ny) | 1:1 | Ekstern lenke, ny konto, claim, eiers godkjenning, Agreement, chat-aksept, samme samtale | blandet |
| IC-16 | S1 / V4 → V1 | KN → P(ny) | 1:1 | Binding utsteder ticket, persona åpner `/i/`, svarer, Kjetil aksepterer kontaktforespørsel, V1-invitasjon følger | blandet native |
| IC-17 | S1 / V1 | KN → P | 1:1 | Nativt bevis (`native/challenge` + `X-Haven-Chat-Proof`) fra Binding, persona på web | native ↔ web |
| IC-18 | S1 / V1 | P → KN | 1:1 | Persona inviterer; Binding ser invitasjonen og aksepterer med ekte ticket | web ↔ native |
| IC-19 | S1 / V1 | KN → KN | 1:1 | To Binding-enheter (telefon + iPad) via samme scaffold; aldri målt tidligere | native |
| IC-20 | S1 / V1 negativ | P → P | 1:1 | Decline, utløp (`expiresInSeconds=1`), revoke, blokkert, uinvitert ser ikke historikk | produkt web |
| IC-21 | S1 / V1 | P → P (Butler-flate) | 1:1 | Poll-forutsetning: med < 2 deltakere gir Butler `needsInvite`; med 2 går det | produkt web |
| IC-30 | S3 / V6 | P(participant) → P(participant-foreign) | 1:1 | `discovery.startChat`, melding, restart beholder tråd (`testConnectionMessageTwoParticipantRestartV1`) | produkt web |
| IC-31 | S3 / V6 | P → P, P | gruppe | `startGroupChat` | produkt web |
| IC-32 | S3 / V6 | K → P | 1:1 | Kjetil som deltaker i Porthole, persona svarer | blandet |
| IC-33 | S3 / V6 | moderator → alle | gruppe | Control Tower `sessionThread.postMessage` vises i deltakerskallet | produkt web |
| IC-34 | S3 / V5 | P → P | 1:1 | `proofChat.generateArtifacts` → aksept på egen identitet, ikke bare «lokalt i samme runtime» | produkt web |
| IC-35 | S3 / V6 | KN → P | 1:1 | Binding sin konferanse-adapter mot web-persona | native ↔ web |
| IC-40 | S5 / V7 | P → P | 1:1 | Connect key, `chat.sendRequest`, gjensidig kontakt, melding | produkt web |
| IC-41 | S4 / V8 | P → P | gruppe | Passkey (Playwright virtuell autentisator), betalt inngang, delt ChatCell, forfatter bundet til requester | produkt web |
| IC-50 | S8 / V9 | KN → D | 1:1 | Invite-fil, `setup`, `pending_approval`, godkjenning i Binding, `activate`, `send_message`/`read_message` begge veier | agent |
| IC-51 | S9 / V10 | KN ↔ D | 1:1 | Prompt fra Binding, svar fra agent, replay av `messages` | agent |
| IC-52 | S6 / V5 | I → S | 1:1 | Swarm-lurker abonnerer på chat-topic og ser flow-hendelser (lesende) | protokoll |

Gap som ikke testes, men registreres som PDD-kandidater: agent som likeverdig chatpart (S6/S1 med D), SwiftWebScaffold-chat (S7), swarm `chatParticipant`-atferd, chat-invitasjon via QR.

---

## 4. AI-personaer i sverm

### 4.1 Tre personaklasser

1. **Protokoll-persona (I)**: én interop-peer-prosess per persona. Driveren sender `init`, `serve`, `invitation`, og i chatfasen veksler mellom `remote get messages` og `remote set sendMessage`. Linux-sky kan kjøre Python- og Go-peers nå; Swift-peer krever CellScaffold-bygg (`scripts/run_swift_bounded.sh`), altså Mac eller Linux-CI.
2. **Web-persona (P)**: én Playwright `request`-kontekst per persona med egen konto. Driveren bruker `chat/api/identity`, `invite`, `accept`, `send`, `state`, `revision`. Lokalt registreres kontoer med `/auth/register`; på staging må Kjetil opprette eller godkjenne testkontoer (se 7).
3. **Native persona (KN)**: ikke en AI, men Kjetils egne enheter. Kan automatiseres delvis med Binding sine XCUITests (`ButlerConversationUITests`) og `run_nearby_scanner_device_pair_test.sh`-mønsteret for to enheter.

### 4.2 Persona-driver

En liten orkestrator (`persona-swarm.py`, foreslått plassert i CellScaffold `scripts/`, ikke skrevet ennå) som:

- leser et scenario (hvem inviterer hvem, på hvilken flate, hvor mange runder),
- starter N personaer av klasse I og/eller P med navn, rolle og en kort karakterbeskrivelse,
- lar en LLM (Claude via API, eller lokal Qwen/Gemma gjennom samme `llama-server` som HavenAgentD bruker) velge neste handling blant et lukket sett: `invite`, `accept`, `decline`, `send <tekst>`, `wait`, `leave`,
- logger hver handling med tidsstempel, HTTP-status/peer-svar, og observert revisjon,
- avslutter med en JSON-rapport per persona og en samlet `TESTRESULT.md`.

LLM-en styrer bare *hva som sies og når*; alle protokoll- og HTTP-kall er deterministiske. Dermed kan samme scenario kjøres uten LLM (skriptet modus) for regresjon, og med LLM for «tett opptil ekte» utprøving. Tekstene som sendes skal inneholde en kjørings-ID og et sekvensnummer, slik at mottakersiden kan verifisere rekkefølge og tap.

Kjetil deltar i blandede tilfeller (IC-12..19, IC-32, IC-35) ved å være en av partene i Porthole eller Binding mens personaene kjører.

### 4.3 Sikkerhetsrammer

- Kun lokalt og staging. Produksjon (`haven.digipomps.org`) er utenfor planen.
- Personaer bruker tydelig prefiks (`persona-<runId>-<navn>`) og slettes/blokkeres etter kjøring.
- Ingen ekte e-post eller SMS sendes; V4 testes ved å åpne lenken direkte.
- API-nøkler til LLM ligger i miljøvariabler på maskinen som kjører driveren, aldri i repo.

---

## 5. Faser og rollefordeling

| Fase | Innhold | Hvem | Hvor |
|---|---|---|---|
| 0 Forberedelse | Lokal CellScaffold (`haven-local-dev-environment-setup`), bygg InteropPeer, installer Python-peer og Go-peer, evidensmappe `Documentation/Operations/invite-chat-<dato>/`, tre testkontoer | Codex (Mac), Claude (Linux-del) | Mac + sky |
| 1 Protokoll | IC-01..05, IC-52: `run_matrix.py` med Swift-, Python- og Go-peer → `TESTRESULT.md` | Claude kan kjøre Py+Go i sky nå; Swift-peer på Mac via Codex | sky + Mac |
| 2 Produkt web | IC-10, 11, 20, 21, 30, 31, 33, 34, 40, 41 som Playwright-specs mot `127.0.0.1:9312` | Claude skriver specs, Codex kjører lokalt | Mac |
| 3 Blandet | IC-12..15, IC-32 med Kjetil i Porthole og personaer i sverm, lokalt først, så staging | Kjetil + Claude-driver | Mac/staging |
| 4 Native | IC-16..19, IC-35: person-link, nativt bevis, to enheter; kjør `inv08-build-test.sh` på iOS 27-simulator for første gang | Codex (Xcode) + Kjetil (enheter) | Mac |
| 5 Agent | IC-50, IC-51 | Kjetil + Codex | Mac |
| 6 Rapport | VIRKER-ledger, `SISTE_OPPDATERING.md`, lærdommer via `haven-learning-capture` | Claude | repo |

Fasene 1 og 2 kan starte uavhengig. Fase 3 krever grønn fase 2. Fase 4 krever fungerende lokal scaffold med `RP_ORIGIN` og tunnel for telefon.

---

## 6. Negative tester (alle flater)

- Uinvitert tredjepart får ikke lese tråden (403 / tom liste / `rejected` Agreement).
- Tilbakekalt invitasjon: tilgang opphører straks (`ChatAgreementAdmissionTests` lover dette på protokollnivå; må bevises på S1 og S3).
- Utløpt invitasjon (1 s) kan ikke aksepteres.
- `never`-svar på `/i/` blokkerer senere tickets fra samme utsteder.
- Gjest kan ikke utvide Agreement (`extraGrants`) eller droppe betingelser (`dropConditions`).
- Forfalsket aksept (feil nøkkel) avvises; fixtures i `fixtures/interop/v1` gir forventede verdikter.
- Levering til ikke-registrert `ContactEndpoint` gir samme ubekreftede kvittering som til registrert (ingen lekkasje av om mottaker finnes).
- Lekkasjesjekk i GUI etter hver handling: ingen `Unavailable`, `denied`, `undefined`, rå JSON (`haven-gui-testing`).

---

## 7. Kjente blokkere og risiko

| # | Risiko | Kilde | Konsekvens for planen |
|---|---|---|---|
| R1 | Ferske brukere på staging fikk `ownerAuthorityUnavailable` for `PersonalChatHub` (61 av 69 feil i staging-rapporten 2026-08-09). Årsak ikke bevist. | `Staging_Surface_Test_Report_2026-08-09.md` | Fase 3 på staging kan stoppe på første persona. Kjør IC-10 på staging som første sjekk; hvis rødt, bli lokalt og registrer funn. |
| R2 | Nativt bevis mellom to brukere er aldri målt; `NativeChatAuthentication.md` sier at nativt hub «fortsatt skriver til lokal cache». | Binding `ChatWorkbenchBindingParity.md` inv10–inv14 | IC-17..19 kan avdekke at chat er lokal på native. Det er et reelt funn, ikke en testfeil. |
| R3 | Binding inv08-testene er aldri kjørt på simulator (krasj på iOS 18.6 pga. FoundationModels-typer; fix krever iOS ≥ 27). | `RESULT-inv08.md` | Fase 4 starter med å kjøre `Scripts/inv08-build-test.sh`. |
| R4 | Agent-svar-henting i scaffold er slått av (503). HavenAgentD kan ikke være chatpart. | `VaporAgentConversationReplies.swift` | D begrenses til S8/S9. |
| R5 | Swarm har ingen chat-atferd. | `SimulationModels.swift` | S brukes bare lesende (IC-52). |
| R6 | SwiftWebScaffold `index.html` poster uten bevis etter at bevis ble påkrevd. | SwiftWebScaffold `89f6681` | S7 utelates; registreres som gap. |
| R7 | Playwright fra Codex mot staging krever `danger-full-access`. | VIRKER-ledger | Staging-kjøringer gjøres av Claude-driver eller Kjetil, ikke Codex-sandkasse. |
| R8 | Chat MVP krever passkey og betalt inngang. | `VaporChatMVP.swift` | IC-41 trenger WebAuthn virtuell autentisator og test-top-up; lav prioritet. |
| R9 | `ChatCellAuthorBindingTests` står som UPRØVD. | VIRKER-ledger | Kjøres i fase 2 og flyttes til VIRKER/VIRKER IKKE. |

---

## 8. Evidens og rapportering

Per tilfelle (etter `haven-functional-service-verification`):

- base-URL, git-revisjon per repo, persona-IDer, flate/konfigurasjon,
- nøyaktig kommando eller driver-scenario,
- artefakter: skjermbilder, Playwright-trace, HTTP-responser, `TESTRESULT.md` fra matrisen, peer-logger,
- pass/fail med den konkrete dynamiske verdien som ble sjekket (meldingstekst med sekvensnummer, revisjonsnummer, `joined`/`410`),
- blokkert nedstrøms dekning.

Samlet: én VIRKER-oppføring per IC-tilfelle (VIRKER / VIRKER IKKE / VIRKER MED FORBEHOLD / UPRØVD, aldri uten evidens), én oppføring øverst i `Documentation/ProjectControl/SISTE_OPPDATERING.md` i CellScaffold per arbeidsøkt, og nye Playwright-/Swift-tester lagt til `ci/test-filter.txt` i samme commit.

---

## 9. Spørsmål til Kjetil (G1)

1. Skal personaene styres av Claude via API, eller av lokal modell på M5 (samme `llama-server` som HavenAgentD)? Begge er mulig; lokal modell holder alt på maskinen.
2. Staging: har du kontoer vi kan bruke, eller skal personaer registreres der? R1 tilsier at vi sjekker én fersk konto først.
3. Fase 4 krever Xcode 27 og iOS 27-simulator på M5, pluss telefon og iPad for IC-19. Er det tilgjengelig i perioden?
4. Skal gapene (agent som chatpart, swarm `chatParticipant`, SwiftWebScaffold-chat) få egne formålstrær nå, eller vente til kjernesettet er grønt?
5. Kjernesettet er 28 av 139 kombinasjoner. Er det riktig nivå, eller vil du ha hele «klar»-settet (38) i første runde?

---

## 10. Fase 1 status (2026-11-06, claude-code i sky, Linux)

Kjørt i skymiljøet med Python-peer (PyCellProtocol `711aae8`, venv med `[scaffold]`) og Go-peer (GoCellProtocol `9ea5cc9`, `go build ./cmd/interop-peer`). Swift-peer er ikke kjørt: den krever CellScaffold-bygg på Mac eller Linux-CI (Codex). Evidens: `Docs/Testing/evidence/invite-chat-2026-11-06/`.

| ID | Resultat | Evidens |
|---|---|---|
| IC-01 | VIRKER (python/go). Invitasjonsartefakt, aksept på egen node, Agreement `invitationAccepted`, send og les over autentisert bridge. | `TESTRESULT-fase1-py-go.md`, `run_matrix-py-go.log` (116 steg, alle ok) |
| IC-02 | VIRKER MED FORBEHOLD: 4 av 9 vert/gjest-par (python→python, python→go, go→python, go→go). Swift-parene (5) er UPRØVD. | samme |
| IC-03 | VIRKER (python/go). Vert + to gjester, alle 8 kombinasjoner, 17 steg hver: artefakt matchet på `invitedIdentity.uuid`, gjest kan ikke bruke den andres artefakt, lik ordnet tråd hos alle tre, forfatter riktig attribuert, tilbakekalt gjest stenges ute straks mens den andre fortsetter. Rekey-sjekk på `crypto.*` er ikke eksponert i peer-protokollen og er derfor UPRØVD. | `TESTRESULT-fase1-gruppe-py-go.md`, `interop_group_chat-py-go.log` (136 steg, alle ok) |
| IC-04 | VIRKER (python/go). Uten bevis, bevis alene, utvidet grant, droppet betingelse, fremmed, eier-nøkler fra gjest, endring av betingelser fra gjest, tilbakekalt gjest: alle avvist. | `run_matrix-py-go.log` |
| IC-05 | VIRKER (python/go). Ticket publisert på `/i/`, lenke verifisert, svar via kortkode, utsteder ser `joined`, svar hentes én gang, tilbakekalt lenke avviser svar. | `run_matrix-py-go.log` |
| IC-52 | UPRØVD. Swarm-scaffoldet krever CellScaffold-bygg. | – |

Driver for IC-03: `Docs/Testing/interop_group_chat.py` (bruker `Peer`, `Steps`, `agreed`, `refused` fra PyCellProtocol `interop/matrix/run_matrix.py`). Bør flyttes til PyCellProtocol `interop/matrix/` og inn i `interop-matrix.yml` når Kjetil godkjenner.

Kommandoer som ble kjørt:

```bash
python3 -m venv pyenv && pyenv/bin/pip install -e 'PyCellProtocol[scaffold]'
go build -o interop-peer-go ./cmd/interop-peer        # i GoCellProtocol
pyenv/bin/python PyCellProtocol/interop/matrix/run_matrix.py \
  --peer python="pyenv/bin/python -m cellprotocol_scaffold.interop_peer" \
  --peer go=./interop-peer-go --verbose --out TESTRESULT-fase1-py-go.md
pyenv/bin/python CellProtocol/Docs/Testing/interop_group_chat.py \
  --matrix-dir PyCellProtocol/interop/matrix \
  --peer python="pyenv/bin/python -m cellprotocol_scaffold.interop_peer" \
  --peer go=./interop-peer-go --verbose --out TESTRESULT-fase1-gruppe-py-go.md
```

Neste i fase 1 (Codex på Mac): bygg `InteropPeer` med `scripts/run_swift_bounded.sh build --product InteropPeer` i CellScaffold og kjør begge kommandoene med `--peer swift=<sti>` i tillegg, slik at de 5 Swift-parene og 19 Swift-gruppekombinasjonene dekkes.
