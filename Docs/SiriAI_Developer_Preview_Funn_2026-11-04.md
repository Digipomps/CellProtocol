# Siri AI Developer Preview — funn (2026-11-04)

Kildegrunnlag: Apples utviklerdokumentasjon lest via dokumentasjons-API-et
(`developer.apple.com/tutorials/data/documentation/...json`) 4. november 2026,
Apples nyhetspost «Siri AI is now open to all developers» (3. november 2026),
WWDC26-guiden for Apple Intelligence og transkripsjoner av WWDC26-sesjonene
240, 242, 319, 339, 343, 345 og 298. Innlogget Safari/Xcode på Mac var ikke
tilgjengelig fra denne skysesjonen, så alt under er fra offentlig tilgjengelige
Apple-sider. Hver påstand er merket **[Apple]** (lest direkte hos Apple) eller
**[avledet]** (min tolkning).

## 1. Hva Apple faktisk slapp 3. november 2026

- **[Apple]** «Siri AI Developer Preview» åpnes for alle utviklere i betaene av
  iOS 27.3, iPadOS 27.3, macOS 27.3 og visionOS 27.3 (nyhetsposten nevner også
  watchOS 27.3 i kravlisten, men API-dokumentasjonen lister bare de fire
  første). Krever Apple Intelligence-enhet og støttet språk.
- **[Apple]** Ingen ny entitlement og ikke noe eget utviklerprogram. Alt går
  via App Intents-rammeverket.
- **[Apple]** Preview-funksjonaliteten virker bare i utviklerbygg og for
  interne TestFlight-testere. Den virker **ikke** for eksterne TestFlight-testere
  eller App Store-versjoner. App Store-innsending åpner «til våren», levering til
  kunder «om noen måneder».
- **[Apple]** Språk nå: engelsk, fransk, japansk, koreansk, portugisisk, spansk.
  «Kommer snart»: tradisjonell kinesisk, **norsk**, tyrkisk, vietnamesisk.
- **[Apple]** Region: Siri AI er «for øyeblikket ikke tilgjengelig i EU» på
  iOS, iPadOS og watchOS. Apple sier de «jobber med EU om en vei videre».
  **[avledet]** Apple skriver «EU», ikke EØS. Hvorvidt Norge rammes er ikke
  avklart i dokumentasjonen og må testes på enhet.
- **[Apple]** Ikke tilgjengelig for brukere under 13 år.
- **[Apple]** Server-side Apple Intelligence (Siri AI, Image Playground, AFM 3
  Cloud i Shortcuts) har **daglige kvoter** per bruker som varierer med
  funksjon, kompleksitet og belastning. «Utvidet tilgang mot betaling kommer».
- **[Apple]** Vilkår og bruksregler for preview publiseres senere.

## 2. Mentalt kart: hvordan Siri AI «ser» en app

Siri AI er en modellbasert orkestrator over App Intents. Appen eksponerer tre
ting, og Siri finner ut resten:

| Apple-begrep | Hva det er | HAVEN-parallell (se rapporten) |
|---|---|---|
| **Tool intent** (`@AppIntent(.tool)`, protokollen `ToolIntent`) | En `AppIntent` Siri kan konfigurere og kalle for å svare på en forespørsel. Krever `title`, `description` og tittel/beskrivelse per `@Parameter`. | En `set`-nøkkel med Explore-kontrakt i en celle |
| **App entity** (`@AppEntity`, `@Property`, `@DeferredProperty`, `@ComputedProperty`) | Appens innholdstyper, med beskrivelser per egenskap, autentiseringspolicy og synlighet. | Celle-tilstand / `ValueType`-objekter med kjent form |
| **Generable entity** (`@AppEntity(.generable)` + `TransientAppEntity`, protokollen `GenerableEntity`) | Entitet modellen kan **fylle direkte fra ytringen** uten å spørre appen (f.eks. et flysøk). Egenskaper må selv være generable (verdityper, `AppEnum`, andre generable, arrays). | `@Generable PurposeWrapper`, guided generation av payloads |
| **App skill** (`Skills.skillsbundle/Skills/<navn>/SKILL.md`) | Markdown-fil med frontmatter `name` + `description` (≤1024 tegn) og fritekst-kropp (≤10 000 tegn) som veileder Siri gjennom fler-stegs oppgaver. | Purpose-tre med mål og helperCells; HAVEN-skills i `commons/skills` |
| **Spotlight semantisk indeks** (`IndexedEntity`, `CSSearchableIndex.indexAppEntities`, `IndexedEntityQuery`) | Siri finner innhold ved mening, også uten skjema. | Vault-notater, lister, chat, purposes |
| **Onscreen context** (`appEntityIdentifier`, `appEntityUIElements`, `NSUserActivity.appEntityIdentifier`) | «Denne», «den tredje» løses mot det som er på skjermen. | Skeleton-renderer-rader i Binding |
| **Donations** (`IntentDonationManager`) | Atferdssignaler som hjelper disambiguering. | Replaybar relasjonslæring (RelationalLearningEngine) |
| **Transferable / IntentValueRepresentation** | Entiteter som kan flyttes mellom apper (f.eks. til Meldinger). | Correspondence-vedlegg, FlowElement-innhold |

### 2.1 Når Siri kan kalle appens tools **[Apple]**

- Appen er i forgrunnen, har en aktiv Live Activity, eller samtalen i Siri-appen
  allerede har nevnt appen → brukeren trenger ikke si appnavnet.
- Appen er i bakgrunnen → brukeren må nevne appen («... i HAVEN»).
- En relevant entitet fra appen dukker opp i et søkeresultat.
- Siri kan hente innhold fra én app, flytte det til en annen og utføre en
  handling der («send favorittjoggeskoene mine til partneren min i Meldinger»).
- Svar vises i **card snippets** appen selv leverer (`ShowsSnippetView`).

### 2.2 Regler for tool intents **[Apple]**

- Ikke legg `.tool` på intents som allerede følger et skjema i et primært
  domene Siri støtter (f.eks. `sendMessage`); det er en byggefeil.
- `@AppIntent(.tool, schema: .journal.createEntry)` brukes for skjemaer som bare
  støttes i Shortcuts (books, browser, files, journaling, presentation, reader,
  spreadsheet, whiteboard, word-processor).
- Dårlige kandidater: widget-konfigurasjonsintents, rene snarvei-trinn, og
  intents med bivirkninger brukeren må starte eksplisitt (bestilling og
  betaling).
- Skriv beskrivelser «for en som ikke kjenner appen»: strengformat, tallområde,
  enheter.

### 2.3 Sikkerhet og personvern i entiteter **[Apple]**

- `IntentAuthenticationPolicy` på entitet eller per egenskap:
  `.alwaysAllowed`, `.requiresAuthentication`,
  `.requiresLocalDeviceAuthentication`. Gjelder bare Siris svar; returnerer
  intenten sensitiv informasjon, settes policyen på intent-nivå.
- `visibility: .internal` skjuler en egenskap helt for Siri/Shortcuts (bare appen
  og dens extensions ser den). Kombineres ikke med `indexingKey`.
- Entiteter er **private som standard**. Delte/offentlige entiteter bør
  implementere `OwnershipProvidingEntity` (`.shared`, `.public`, `.unknown`) så
  Siri ber om bekreftelse før bivirkninger (WWDC26 343).
- Relatert sesjon: «Secure your app: Mitigate risks to agentic features».

### 2.4 App skills **[Apple]**

- Én `.skillsbundle` per app-target. Én katalog per skill, bare `SKILL.md`.
  Navn: 1–64 tegn, små bokstaver/siffer/bindestrek, må matche katalognavnet.
- Siri leser bare `description` for å avgjøre om skillen passer; kroppen leses
  først etterpå.
- Skills gir **ingen deterministisk kontroll**; Siri utfører ikke tool-intents
  sekvensielt etter lista. Skills er veiledning: rekkefølge, hvilken tool som
  foretrekkes, hva som skal unngås, domenekunnskap, hvordan intervjue brukeren
  for parametre.
- Referer til tools uformelt («kall vær-verktøyet først»), ikke med typenavn.
  Ikke gjenta det kode allerede beskriver.
- Formatet er «et subsett av Agent Skills-spesifikasjonen» (samme form som
  Claude-skills: frontmatter + Markdown-kropp).

### 2.5 Verktøy for verifisering **[Apple]**

- **Siri Integration Advisor** i Xcode: tilbakemelding og forslag til
  App Intents-implementasjonen.
- **Siri Evaluations**-rammeverket (`import SiriEvaluations`, 27.3 beta):
  `SiriScenario { UserTurn("…") { Calls { intent.expect(param: .equals(…)) }
  Calls(.disallowed) { … } SiriResponse(.contains(…)) } }`, kjørt via
  `SiriService.run(scenario:)` i en `Evaluation` med `SiriExpectationEvaluator`.
  Forventninger: `Calls`, `Finds`, `Loads`, `OnScreen`, `SiriResponse`.
  Scenarier er `Codable` (kan lagres som JSON). Krever UI-testtarget, samme
  signeringsteam, Developer Mode + «Enable UI Automation» på enheten. Siris svar
  varierer mellom kjøringer; Apple anbefaler å kjøre settet flere ganger.
- **AppIntentsTesting** (fra WWDC26): kjører intents out-of-process slik Siri
  gjør, uten UI-automatisering.
- **Evaluations**-rammeverket (WWDC26 298): `Evaluation`, `ModelSample`,
  `Evaluator`, `ModelJudgeEvaluator` (kan bruke `PrivateCloudComputeLanguageModel`
  som dommer), `ScoreDimension`, `@Test(.evaluates(…))`. Rapport i Xcodes
  report navigator.
- Manuell trapp: AppIntentsTesting → Shortcuts-appen → Spotlight → Siri.

## 3. Foundation Models (grunnlaget Siri AI og vår egen celle-AI deler)

- **[Apple]** `FoundationModels` (26.0+, watchOS 27.0+) gir tilgang til «any
  large language model»: `SystemLanguageModel` (på enhet),
  `PrivateCloudComputeLanguageModel` (PCC, 27.0+), og tredjeparts modeller via
  protokollen `LanguageModel` + `LanguageModelExecutor` (27.0+). Apples guide
  nevner Claude og Gemini som eksempler på skymodeller via samme API.
- **[Apple]** `@Generable`/`@Guide` guided generation, `Tool`-protokollen for
  tool calling, `DynamicInstructions`/`Profile`/`DynamicProfile` (profilkroppen
  re-evalueres før hvert modellkall; kan bytte modell, verktøy, temperatur og
  resonneringsnivå), `SessionProperty`, `historyTransform`,
  `ToolCallingMode` (`.allowed`/`.disallowed`/`.required`),
  `transcriptErrorHandlingPolicy`, multimodale prompts med bilder.
- **[Apple]** PCC-modellen: samme API, én linje byttes. Kontekst 32 768 tokens
  (på-enhet: 4 096 på 26.0, 8 192 på nyere enheter i 27.0). Resonnering
  `.light/.moderate/.deep`. Ingen token-kostnad for utvikler, men daglig kvote
  per bruker (iCloud+-oppgradering gir mer). `quotaUsage` kan leses.
  Krever «managed entitlement» (`com.apple.developer.private-cloud-compute`) og
  er gratis for apper i Small Business Program med < 2 mill. førstegangs
  nedlastinger.
- **[Apple]** `LanguageModel`-leverandør: `capabilities` (`.toolCalling`,
  `.guidedGeneration`, `.reasoning`), `Executor.Configuration` (Hashable; deles
  mellom sesjoner), `respond(to:model:streamingInto:)` som strømmer
  `.appendText`, `.updateUsage`, `.updateMetadata`, custom segments. Apple
  anbefaler token-provider/innlogging i stedet for rå API-nøkler, Keychain og
  App Attest. Rammeverket skal åpnes som open source (WWDC26 382).
- **[Apple]** Instruments har egen Foundation Models-instrument; `fm` CLI og
  Python SDK finnes for skripting (WWDC26 334).

## 4. Hva Apple **ikke** gir (viktig for forventningsstyring)

- **[avledet]** Ingen «Siri-chat-API»: appen kan ikke sende fritekst til Siri AI
  og få svar tilbake programmatisk. Appen eksponerer tools/entiteter/skills,
  Siri bestemmer. Vår egen modellbruk går via Foundation Models, ikke via Siri.
- **[Apple]** Siri kaller bare det appen eksplisitt eksponerer.
- **[avledet]** Siri AI finnes ikke på Linux/Vapor. `CellVapor`-noder og
  Porthole-web får ikke Siri, bare Apple-vertene (Binding). Kontraktene må
  derfor ligge i `CellBase`, adapteren i `CellApple`/Binding.
- **[Apple]** Ingen garanti for deterministisk oppførsel (skills er veiledning,
  svar varierer mellom kjøringer).
- **[Apple]** Preview-API kan endres.

## 5. Relevante Apple-sider

- https://developer.apple.com/news/?id=gdk2umrf
- https://developer.apple.com/documentation/appintents/siri-ai-developer-preview
- https://developer.apple.com/documentation/appintents/bringing-custom-actions-and-content-to-siri
- https://developer.apple.com/documentation/appintents/orchestrating-complex-actions-with-app-skills
- https://developer.apple.com/documentation/appintents/toolintent
- https://developer.apple.com/documentation/appintents/generableentity
- https://developer.apple.com/documentation/appintents/apple-intelligence-and-siri-ai
- https://developer.apple.com/documentation/appintents/providing-contextual-cues-to-apple-intelligence-and-siri
- https://developer.apple.com/documentation/appintents/verifying-your-app-intents-implementation
- https://developer.apple.com/documentation/sirievaluations
- https://developer.apple.com/documentation/foundationmodels
- https://developer.apple.com/documentation/foundationmodels/languagemodel
- https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel
- https://developer.apple.com/wwdc26/guides/apple-intelligence/
- WWDC26-videoer: 240, 242, 243, 298, 319, 339, 343, 344, 345, 382
