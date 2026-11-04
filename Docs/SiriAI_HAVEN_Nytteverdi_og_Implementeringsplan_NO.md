# Siri AI × HAVEN: nytteverdi og implementeringsplan

Dato: 2026-11-04. Status: se STATUS under.

## STATUS

- G1: godkjent 2026-11-04 (Kjetil: «G1 godkjent, start fase 1»)
- G2 (fase 1): godkjent 2026-11-04 ved samme ord; fase 2–4 venter på WP0.1-måling og egen G2
- Fase 1 (WP1.1–WP1.4): implementert 2026-11-04 på branch `claude/youthful-hawking-sm0c4i`,
  dokumentert i `Docs/Assistant_Exposure_Contract.md`. Verifisering: `swift test` kunne ikke
  kjøres i skysesjonen (ingen Swift-toolchain, download.swift.org og Docker Hub er stengt i
  sesjonens nettverk). Testene er lagt i Linux-CI-gaten; CI-resultatet og lokal
  `swift test --filter Assistant` på Mac er bevisene som skal inn i TESTRESULT.md.
- Fase 0 (måling på enhet): ikke startet; Codex-handoff i
  `commons/prompts/codex_siri_ai_fase0_prompt.md` er fortsatt merket blocked til Kjetil frigir den.
- G3: ikke bedt om. Faktagrunnlaget om Apple ligger i
`Docs/SiriAI_Developer_Preview_Funn_2026-11-04.md`. Alt om HAVEN under er lest fra
dette repoet i denne sesjonen (stier oppgitt) med mindre det er merket *recalled*.

## 0. Kjetils intensjon (verbatim)

> Apple har sluppet Siri AI developer. Finn ut det du kan om det. [...] Bygg deg
> opp forståelse for Siri AI. Dokumenter viktige funn. Kombiner det med all
> tilgjengelig kunnskap om HAVEN, CellProtocol og prosjektene vi har utviklet og
> vurder hvordan vi best kan bruke det til å lage en bedre brukeropplevelse basert
> på hvordan vi kobler inn ai assistenter i celler for å hjelpe til med tolkning og
> generering. Lag en rapport om nytteverdien, vær litt kreativ så lenge det er
> innenfor HAVENs konsepter. Lag en plan for implementering.

### Brief-audit

| Antakelse i oppgaven | Status | Kilde |
|---|---|---|
| Apple har sluppet «Siri AI» for utviklere | retrieved | Apple news `gdk2umrf`, 2026-11-03 |
| Dokumentasjon kan lastes via Xcode/innlogget Safari | unavailable i skysesjon; løst med Apples offentlige dokumentasjons-API | funn-dokumentet §0 |
| HAVEN har allerede en AI-assistent-celle | retrieved | `Sources/CellApple/Intelligence/AppleIntelligenceCell.swift` (1464 linjer, bruker `LanguageModelSession`, `GraphMatchTool`, `GetConfigurationsTool`, `@Generable PurposeWrapper`) |
| Celler har maskinlesbare kontrakter | retrieved | `Sources/CellBase/Cells/GeneralCell/ExploreContract.swift`, `ExploreContractCatalog.swift` |
| Det finnes en typed prompt/profil-modell | retrieved | `commons/docs/architecture/assistant-profiles-prompts-context.md` (`AtlasAssistantProfile`, `AtlasModelProviderProfile`, `AtlasPromptResolver` i lagrekkefølge entity → assistant → purpose → cell → session) |
| Purpose-treet kan bære hjelpeceller og mål | retrieved | `Sources/CellBase/PurposeAndInterest/Purpose.swift` (`goal`, `helperCells`, `composition`) |
| Bivirkninger mot omverdenen er formålsbundet | retrieved | `Sources/CellBase/Agreement/PurposeBoundExternalAction.swift` (`proposeOnly`, `reviewRequired`, destinasjonsklasser) |
| Siri virker i Norge nå | contradicted/uavklart | Apple: «ikke tilgjengelig i EU» på iOS/iPadOS/watchOS; norsk språk «kommer snart». Må måles på enhet. |
| Binding/CellScaffold/Palazzo-kode | unavailable i denne sesjonen (ikke i containeren); omtales via `Docs/Cross_Repo_P0_Orchestration_Status.md` og README | — |

## 1. Hovedkonklusjon

Siri AI gir HAVEN **én ny inngang** (stemme/tekst i Siri, på tvers av apper, med
skjermkontekst) og **ett nytt sett kvalitetsverktøy** (Siri Evaluations,
Evaluations, AppIntentsTesting). Den gir **ikke** en ny modell-API: generering og
tolkning inne i celler skjer fortsatt via Foundation Models, som vi allerede
bruker i `AppleIntelligenceCell`.

Det avgjørende funnet er at Apples tre primitiver passer én-til-én på ting HAVEN
allerede har som maskinlesbare kontrakter:

| Apple trenger | HAVEN har allerede | Gap |
|---|---|---|
| Tool intent med `title`, `description`, parametre med beskrivelser | Explore-kontrakt per nøkkel: `key`, `method`, `input`-skjema med `properties`/`requiredKeys`/`description`, `returns`, `permissions`, `flowEffects`, `summary` | En generator fra kontrakt → `AppIntent` |
| App entity med beskrevne egenskaper, autentiseringspolicy, synlighet | `ValueType`-objekter med Explore-skjema; Commons `PermissionClass` (`public/private/consent/aggregated`); `IntentAuthenticationPolicy` mangler motpart | Entitetsmapping + policy-avledning |
| App skill (`SKILL.md`: name, description, Markdown-veiledning) | `Purpose` med `description`, `goal`, `helperCells`, `composition` (`allOf/anyOf/sequence/atLeast`); `commons/skills/*/SKILL.md` i samme format | En generator fra purpose-tre → skills-bundle |
| Semantisk indeks | Vault (`vault.note.*` med tags), Lists (`lists.state`), Chat, Perspective | `IndexedEntity`-adapter i CellApple |
| Onscreen context | Skeleton-renderer i Binding med `List`-rader, `selectionValueKeypath`, `payloadKeypath` | Én renderer-endring: `appEntityIdentifier` per rad |
| Evaluering | `CellContractHarness`, `Docs/AI_Agent_CellConfiguration_Test_Prompts.md`, PDD §5 avledede tester | Siri-scenarier og Evaluations som §5-testtyper |

Det betyr at HAVEN ikke trenger å «skrive App Intents for hver celle». HAVEN kan
**avlede** Siri-integrasjonen fra kontrakter og formål som allerede finnes, og
holde avledningen deterministisk og auditérbar. Det er innenfor HAVENs
prinsipper: eksplisitte kapabiliteter, ingen globale identifikatorer, forklarbar
oppførsel.

## 2. Nytteverdi, ordnet etter kost/nytte

### 2.1 Høy nytte, lav kost

**A. Onscreen awareness for alle skeleton-flater (én endring i Binding).**
Når Bindings renderer tegner en `List`-rad som er bundet til en keypath med en
stabil id (`selectionValueKeypath`/`payloadKeypath`), kan raden merkes med
`.appEntityIdentifier(EntityIdentifier(for: CellEntity.self, identifier: "<endpoint>#<keypath>#<id>"))`.
Da kan en bruker si «legg *denne* i handlelista», «send *den tredje* til Vegar»
eller «hva betyr *dette*» i enhver celle-flate, uten at cellen vet om Siri.
Krever bare at `CellEntity` finnes (B).

**B. Celle-entiteter som App Entities (CellApple-adapter).**
En generisk `CellEntity: AppEntity` med `id = "<endpoint>#<keypath>#<id>"`,
`displayRepresentation` fra skeleton-tittelfelt, og egenskaper avledet fra
Explore-skjemaet. Autentiseringspolicy avledes fra kontraktens `permissions`
og Commons `PermissionClass`: `private`/`consent` → `.requiresAuthentication`;
alt med `owner`-grant og personlig innhold → `.requiresLocalDeviceAuthentication`;
`visibility: .internal` for nøkler cellen ikke har annonsert.
Entiteter er private som standard hos Apple, som er i tråd med HAVEN.

**C. Tool intents avledet fra Explore-kontrakter.**
En `CellKeyToolIntent` per annonsert `set`-nøkkel som har (1) et beskrevet
input-skjema, (2) ingen `flowEffects` av typen ekstern publisering, (3) en
opt-in-markør i kontrakten (`siri: true` eller tilsvarende) satt av cellens
forfatter. Siri kaller `perform()` → adapteren kaller
`cell.set(keypath:value:requester: siriRequester)`. **Requester er aldri eieren
direkte.** Det må finnes en egen Siri-identitet med en Agreement/Contract som gir
nøyaktig de grantene cellen har opt-in-et (se §4).

Kandidater i dagens repo: `lists.item.add`, `lists.item.toggle`,
`lists.list.create` (`Docs/ListsCell.md`), `vault.note.create`, `vault.note.list`
(`Docs/Vault_and_Graph_Contracts.md`), `chat.message` (ChatCell),
`taxonomy.resolve.term` (lesing), `atlas.query.cellsForPurpose` (lesing).

**D. Siri Evaluations som PDD-testtype.**
Hvert leaf-formål som berører Siri får en `SiriScenario` i §5. Scenariene er
`Codable`, så de kan ligge som JSON under `Deliverables/PDD_*/siri/` ved siden av
skeleton-JSON og bilder. Dette er den første gangen vi kan måle «sa brukeren X,
skjedde Y» mot et eksternt orkestreringslag.

### 2.2 Høy nytte, middels kost

**E. Purpose-avledede app skills («formålsskills»).**
Et `Purpose` med `description`, `goal` og `composition(.sequence)` er allerede
den informasjonen Apple ber om i `SKILL.md`: hvilke tools som hører sammen,
rekkefølge, hva som skal unngås, domenekunnskap. En generator
`PurposeSkillBundleBuilder` tar et formålsutsnitt (f.eks.
`purpose.net-positive-contribution` → `SDGPilotPurposeCatalog`-formål) og skriver
`Skills.skillsbundle/Skills/<purpose-slug>/SKILL.md` med:

- `name`: slug av `nodeIdentifier`
- `description`: `Purpose.description` komprimert til én linje (≤1024)
- kropp: målets `outcome`/`successSignals`, hjelpecellenes oppgaver, uformelle
  tool-referanser («bruk legg-til-i-liste-verktøyet»), og et «ikke gjør»-avsnitt
  fra `forbidden_relations_to_mandatory` i taxonomi-guidance.

Fordi `commons/skills/*/SKILL.md` allerede er i samme format (frontmatter +
Markdown), kan samme builder også eksportere HAVEN-skills til Claude/Codex.
**Én sannhet (formålstreet), tre konsumenter (Siri, Claude, Codex).**

**F. Semantisk indeks for Vault, Lists og Perspective (opt-in).**
`IndexedEntity` for notater, lister og formål. Indekseringen skjer bare for
innhold cellen merker som indekserbart, og aldri for `consent`-klassifisert
innhold. Spotlight-indeksen er lokal på enheten, som ikke bryter «ingen
kryss-domene-sporing». Lar brukeren si «finn notatet om Arendalsuka-programmet»
og få et HAVEN-kort (snippet) tilbake.

**G. Snippet-visning via skeleton.**
`ShowsSnippetView` lar Siri vise vårt eget SwiftUI-kort. Bindings renderer kan
tegne et lite skeleton (`VStack` + `Text` + `Button`) som kortet. Da ser
Siri-svaret ut som HAVEN, og knappene i kortet treffer ekte keypaths. Begrensning:
må verifiseres med bilde (G1-GUI) før det loves.

### 2.3 Strategisk nytte, høyere kost

**H. HAVEN som `LanguageModel`-leverandør («HavenLanguageModel»).**
Foundation Models åpner `LanguageModel`-protokollen for tredjeparts modeller.
En `HavenLanguageModel` kan rute per `AtlasModelProviderProfile` og
`privacyMode` (jf. CP-03 i `Docs/Sprint1_Cell_Productivity_Backlog.md`):
på-enhet → PCC → Claude via Anthropics kommende Swift-pakke → egen Vapor-node.
Alle cellene bruker da samme `LanguageModelSession`-API uansett modell, og
`AtlasPromptResolver` sine lag (entity/assistant/purpose/cell/session) blir
`DynamicInstructions` som re-evalueres før hvert kall. Dette er den naturlige
videreføringen av `AppleIntelligenceCell` og gjør den leverandør-nøytral uten
å endre celle-kontraktene.

**I. Celle-verktøy for modellen («CellKeyTool»).**
Speilbildet av C: en generisk Foundation Models-`Tool` som eksponerer en
annonsert celle-nøkkel for modellen inne i vår egen sesjon, med
`DynamicGenerationSchema` bygget fra Explore-input-skjemaet. Da kan assistenten
i `AppleIntelligenceCell` kalle `lists.item.add` eller `vault.note.create` uten
håndskrevne tool-klasser per celle. C og I deler kontrakt-til-skjema-koden.

**J. «Tolkningsceller» og «genereringsceller» som mønster.**
Dagens `AppleIntelligenceCell` gjør alt. Planen foreslår å dele i to små,
komponerbare celleroller som begge bruker H + I:

- *Tolkning*: tar inn en `FlowElement` (chat-melding, korrespondanse, scannet
  entitet, Siri-ytring) og returnerer et strukturert `@Generable`-objekt:
  formål-kandidat, interesse-signaler, foreslått handling (`PurposeBoundActionIntent`
  i `proposeOnly`). Deterministisk kontrakt rundt ikke-deterministisk kjerne.
- *Generering*: tar et formål + datadplan og produserer en `CellConfiguration`
  (skeleton) eller et svarutkast. Guided generation med skjema avledet fra
  `SkeletonElement`-enumen (bare støttede elementer, jf.
  `commons/prompts/ai_agent_cell_cellconfiguration_instruction.md`).

Siri er da bare én av flere «ytringskilder» inn i tolkningscellen, og Siris
snippet er én av flere flater ut fra genereringscellen.

## 3. Kreative scenarier (innenfor HAVENs konsepter)

1. **«Siri, hva kan jeg bidra med i dag?»** → tool `ai.discover` (finnes) kjører
   `GraphMatchTool` over Perspective og svarer med tre formål som kort; «velg det
   andre» via onscreen context; «lag en liste for det» → `lists.list.create` med
   formålets `helperCells` som ferdige punkter.
2. **Konferanse-swarm uten PII.** Deltaker sier «finn noen her som jobber med
   klimamobilitet» → `PersonalMatchmaking`-tool med `pseudonym entityRef`,
   capability-sjekk (`matchPurpose`, `discloseContext`) før svar. Siri får aldri
   e-post/telefon (`visibility: .internal`), bare det Agreement tillater.
3. **Korrespondanse-tolkning.** En innkommende korrespondanse vises i Binding;
   brukeren sier «hva ber de om?» → tolkningscellen svarer strukturert og
   foreslår et `PurposeBoundActionIntent` i `proposeOnly`; «svar ja» blir
   `reviewRequired` til eieren bekrefter i kortet.
4. **Formålsskill for Arendalsuka-program.** Purpose-treet for
   programflaten (#73) blir en skill: «finn sesjon → sjekk tid → legg i min
   liste → inviter». Siri orkestrerer fire tools Siri selv velger rekkefølge
   på; HAVEN leverer bare veiledningen.
5. **Lokal-først fallback.** Utenfor EU-spørsmålet eller uten Apple
   Intelligence-enhet gjør *samme* tolknings- og genereringsceller jobben inne i
   HAVEN via `HavenLanguageModel` (på-enhet/PCC/Claude/Vapor). Brukeropplevelsen
   er den samme minus Siri-inngangen.

## 4. Grenser og tillitsgrense (må inn i §2 i FORMAALSSPEC)

- **Siri er en requester, ikke eieren.** Tool intents kjører i Bindings prosess
  og er dermed «trusted composition code» (`Docs/RuntimeTrustBoundary.md`). Det er
  nettopp derfor adapteren **må** bruke requester-bærende `set/get` med en egen
  Siri-identitet og Contract, aldri rå feed- eller policy-egenskaper. Grants
  følger cellens opt-in-liste, ikke eierens grants.
- **Ingen bivirkninger uten formålsbinding.** Enhver tool med `flowEffects` som
  når utenfor eierens lager går via `PurposeBoundActionIntent` i `proposeOnly`;
  Siris «confirm» er ikke HAVENs confirm. Apples egen regel sier det samme:
  intents med bivirkninger brukeren må starte eksplisitt skal ikke være tools.
- **Ikke indeksér `consent`-innhold.** `PermissionClass.consent` og alt med
  `visibility: .internal` holdes utenfor Spotlight.
- **Ingen formål gir rettigheter.** En skill som sier «bruk verktøy X» gir ikke
  tilgang til X; Agreement gjør det (Purpose-Bound External Action Contract).
- **Ikke lov ting Siri ikke gjør.** Skills er ikke deterministiske; vi kan ikke
  garantere rekkefølge. Alt som *må* skje i rekkefølge ligger i
  `PurposeComposition(.sequence)` evaluert i cellen, ikke i skillen.
- **Region/språk.** Siri AI er ikke tilgjengelig i EU på iOS/iPadOS/watchOS, og
  norsk er «kommer snart». Første målepunkt (§6, WP0) er om en norsk enhet i
  27.3-beta får Siri AI i det hele tatt. macOS er ikke nevnt i EU-unntaket.
- **Ikke på Linux.** `CellVapor`/Porthole-web får ingen Siri-inngang. Alt i
  `CellBase` må fungere uten Apple-rammeverk; kun `CellApple` og Binding
  importerer `AppIntents`/`SiriEvaluations`.
- **Preview.** Kan ikke leveres til App Store før våren; API kan endres. Planen
  bygger derfor på det stabile laget (Foundation Models 26/27, Explore-kontrakter)
  og holder Siri-laget tynt og avledet.

## 5. Formålstre (forslag til §1, kandidat-noder)

```
purpose://candidate.siri.assistant-inngang
  «En bruker kan nå HAVEN-celler gjennom Siri AI uten at cellen kjenner Siri»
  ├── purpose://candidate.siri.celle-entitet          (B)
  │     outcome: celle-innhold finnes som AppEntity med riktig policy
  │     successSignals: Spotlight finner et Lists-element; policy-test grønn
  │     verifier: AppIntentsTesting + manuell Spotlight på enhet
  ├── purpose://candidate.siri.kontrakt-til-tool       (C)
  │     outcome: en annonsert, opt-in set-nøkkel kan kalles av Siri
  │     successSignals: SiriScenario «legg melk i handlelista i HAVEN» → Calls(lists.item.add)
  │     verifier: SiriEvaluations, intentsAllPass == 1 over 3 kjøringer
  ├── purpose://candidate.siri.skjerm-kontekst         (A)
  │     outcome: «denne» i en skeleton-liste løses til raden
  │     successSignals: OnScreen-forventning grønn
  │     verifier: SiriEvaluations med XCUIAutomation-navigasjon
  ├── purpose://candidate.siri.formaalsskill           (E)
  │     outcome: et formålsutsnitt blir en gyldig Skills.skillsbundle
  │     successSignals: Xcode validerer bundle; description ≤1024; kropp ≤10 000
  │     verifier: swift test (builder) + xcodebuild
  ├── purpose://candidate.siri.tillitsgrense           (§4)
  │     outcome: Siri-requester kan bare det Contract gir
  │     successSignals: assertSetDenied for ikke-opt-in nøkkel; proposeOnly for eksterne effekter
  │     verifier: CellContractHarness
  └── purpose://candidate.siri.evaluering-i-pdd        (D)
        outcome: SiriScenario er en §5-testtype
        verifier: purpose_dev.py validate aksepterer `siri`-testtype

purpose://candidate.assistent.leverandoer-noeytral     (H, I, J)
  «Celler tolker og genererer via én modell-API uansett leverandør»
  ├── purpose://candidate.assistent.haven-languagemodel (H)
  ├── purpose://candidate.assistent.celle-verktoey      (I)
  ├── purpose://candidate.assistent.tolkningscelle      (J)
  └── purpose://candidate.assistent.genereringscelle    (J)
```

Formålene i det andre treet er uavhengige av Siri og gir verdi også om Siri AI
aldri når Norge. Rekkefølgen i §6 er valgt slik at feil i Siri-sporet ikke
stopper assistent-sporet (prinsippet «uavhengige formål, uavhengige feil»).

## 6. Implementeringsplan (forslag til PLAN.md)

Utførere: **Claude** (skysesjon, CellBase/CellApple, dokumenter, generatorer),
**Codex** (lokalt på Mac via `/Users/kjetil/.local/bin/codex exec`, Xcode-bygg,
Binding, enhetstester), **Xcode** (27.3-beta, Siri Integration Advisor, Siri
Evaluations på enhet), **Kjetil** (gater, enhet, godkjenning av bilder).

### Fase 0 — Mål før vi bygger (1–2 dager)

| WP | Innhold | Utfører | Bevis |
|---|---|---|---|
| WP0.1 | Installer Xcode 27.3-beta + iOS/macOS 27.3-beta på én enhet/Mac. Mål: får en norsk Apple-ID/enhet Siri AI Developer Preview? Mål med engelsk og norsk språkinnstilling. | Kjetil + Xcode | `Deliverables/PDD_siri-ai_<dato>/maal/ENHET-MAALING.md` |
| WP0.2 | Kjør Apples eksempel (CosmoTunes/UnicornChat) med `@AppIntent(.tool)` for å bekrefte at tool-sporet virker på enheten. | Codex/Xcode | samme mappe, skjermbilde |
| WP0.3 | Mål dagens `AppleIntelligenceCell` på 27.3: `ai.sendPrompt` og `ai.discover` med `SystemLanguageModel` og `PrivateCloudComputeLanguageModel` (krever entitlement-søknad; start søknaden nå). | Codex | TESTRESULT `#fm-baseline` |

Uten WP0.1 er rekkevidden til hele Siri-sporet ukjent; da bygges bare fase 1 og 3.

### Fase 1 — Kontrakt-til-tool-grunnmur i CellBase (leverandør-nøytral)

| WP | Innhold | Utfører | Test |
|---|---|---|---|
| WP1.1 | `ExploreContract`: additivt felt `assistant` (`{ exposeAsTool: Bool, exposeAsEntity: Bool, entityTitleKey, entityIDKey, authentication: alwaysAllowed/requiresAuthentication/requiresLocalDevice, indexable: Bool }`). Default alt av. | Claude | `ExploreContractValidator`-tester; eksisterende kontrakt-JSON uendret |
| WP1.2 | `AssistantToolDescriptor` + `AssistantEntityDescriptor` i CellBase: ren projeksjon fra Explore-kontrakt (ingen Apple-typer). Deterministisk, sortert. | Claude | golden-fixture i `Tests/CellBaseTests/Fixtures/AssistantDescriptors*.json` |
| WP1.3 | `ListsCell` og `VaultCell` opt-in-er `lists.item.add`, `lists.item.toggle`, `lists.list.create`, `vault.note.create`, `vault.note.list` som tools; `lists.state.lists[]` og notater som entiteter. | Claude | `CellContractHarness.assertAdvertisedKey` + ny `assertAssistantDescriptor` |
| WP1.4 | Siri-requester-modell: `AssistantRequesterContract` (Agreement-mal som gir nøyaktig opt-in-grantene) + test på at ikke-opt-in nøkkel nektes. | Claude | `assertSetDenied` |

### Fase 2 — Apple-adapter i CellApple + Binding (krever WP0.1 grønn)

| WP | Innhold | Utfører | Test |
|---|---|---|---|
| WP2.1 | `CellApple/Assistant/CellEntity.swift`: generisk `AppEntity` fra `AssistantEntityDescriptor`, `EntityQuery` som går via `cell.get`, policy-mapping. | Codex | AppIntentsTesting |
| WP2.2 | `CellKeyToolIntent`: én `@AppIntent(.tool)` per deskriptor (generert Swift via `Scripts/` eller makro-fri kodegenerator; App Intents krever statiske typer, så generering skjer ved bygg). | Codex | AppIntentsTesting + Shortcuts-appen |
| WP2.3 | Binding skeleton-renderer: `appEntityIdentifier` på `List`-rader med stabil id; `NSUserActivity` for enkelt-entitet-flater. | Codex | SiriEvaluations `OnScreen` |
| WP2.4 | Snippet: `ShowsSnippetView` som tegner et mini-skeleton. **G1-GUI med bilde før bygging.** | Codex + Kjetil | bilde i `images/`, parity |
| WP2.5 | `IndexedEntity` for Lists/Vault (ikke `consent`). | Codex | manuell Spotlight + `Finds` |

### Fase 3 — Leverandør-nøytral assistent (uavhengig av Siri)

| WP | Innhold | Utfører | Test |
|---|---|---|---|
| WP3.1 | `CellKeyTool: Tool` (Foundation Models) fra `AssistantToolDescriptor` med `DynamicGenerationSchema`. Erstatter håndskrevet `GetConfigurationsTool`-mønster. | Claude | enhetstest med `SystemLanguageModel` (skip hvis utilgjengelig) |
| WP3.2 | `AtlasPromptResolver` → `DynamicInstructions`-lag; `AtlasAssistantProfile` → `Profile` med modell/temperatur/reasoning. | Claude | determinisme-test: samme input → samme `assembledText` |
| WP3.3 | `HavenLanguageModel: LanguageModel` med ruting (på-enhet / PCC / tredjepart) etter `AtlasModelProviderProfile.privacyMode`; fail-closed uten nøkkel-alias (CP-03). | Claude + Codex | ruting-tester; ingen rå nøkler i `ValueType` |
| WP3.4 | Tolkningscelle (`cell:///Interpret`): `FlowElement` → `@Generable Interpretation { purposeRefs, interestSignals, proposedAction: PurposeBoundActionIntent(proposeOnly) }`. | Claude | kontrakt-tester + Evaluations-sett (20–30 samples) |
| WP3.5 | Genereringscelle (`cell:///Generate`): formål + dataplan → `CellConfiguration` med skjema bare over støttede `SkeletonElement`-typer; kjør `Docs/AI_Agent_CellConfiguration_Test_Prompts.md` som Evaluations. | Claude | `ModelJudgeEvaluator` + `SkeletonReachabilityAudit` |

### Fase 4 — Formålsskills (krever fase 1 + WP0.2)

| WP | Innhold | Utfører | Test |
|---|---|---|---|
| WP4.1 | `PurposeSkillBundleBuilder` i CellBase: formålsutsnitt → `SKILL.md`-tekst (name/description/kropp), lengdegrenser, uformelle tool-navn fra `summary`. | Claude | golden-fixture; grenseverdier |
| WP4.2 | Byggsteg i Binding som skriver `Skills.skillsbundle` fra `SDGPilotPurposeCatalog` (eller valgt utsnitt). | Codex | xcodebuild validerer bundle |
| WP4.3 | Samme builder eksporterer til `commons/skills/<slug>/SKILL.md` (Claude/Codex). | Claude | diff mot eksisterende skills |
| WP4.4 | 3 `SiriScenario` per skill, kjørt 3 ganger; rapporter `intentsAllPass`-snitt, ikke «grønn». | Xcode + Kjetil | TESTRESULT `#siri-skill` |

### Fase 5 — Aksept og læring

- ACCEPT.md bygges fra evidensfiler (tall fylles av kode), kontrolleres av en
  uavhengig tråd før Kjetil ser den.
- Nye lessons: minst «Siri-confirm er ikke HAVEN-confirm», «skills er veiledning,
  ikke rekkefølge», «EU/Norge-rekkevidde måles, ikke antas».
- Kandidat-formål promoteres til Book 23 bare med Kjetils ord.

### Avhengigheter og rekkefølge

```
WP0.1 ──┬── WP0.2 ── Fase 2 ── Fase 4 (Siri-delen)
        └── WP0.3 ── Fase 3 (uavhengig av Siri)
Fase 1 ── Fase 2, Fase 3, Fase 4 (felles grunnmur, Apple-fri)
```

Fase 1 og 3 kan starte nå i skysesjon (Claude). Fase 2 og 4 trenger Mac med
27.3-beta og går til Codex/Xcode. Hvis WP0.1 viser at Siri AI ikke er
tilgjengelig i Norge, leveres fase 1 og 3 likevel i full bredde; fase 2 og 4
settes til `blocked` med målingen som grunn.

## 7. Codex-handoff

Prompt for første lokale slice ligger i
`commons/prompts/codex_siri_ai_fase0_prompt.md`. Den dekker WP0.1–WP0.3 og er
merket **blocked** inntil Kjetil sier G1 for dette dokumentet. Kommando Kjetil
kan lime inn på Mac-en når slicen er godkjent:

```bash
/Users/kjetil/.local/bin/codex exec -C /Users/kjetil/Build/Digipomps/HAVEN \
  "Les CellProtocol/commons/prompts/codex_siri_ai_fase0_prompt.md og utfør slicene som er merket godkjent."
```

## 8. Åpne spørsmål som endrer treet

1. Får en norsk Apple-ID Siri AI Developer Preview på iOS 27.3-beta, og på
   macOS? (WP0.1) Hvis bare macOS: prioriter Binding på Mac først.
2. Skal Siri-requesteren være én identitet per enhet eller én per entitet
   (person/organisasjon)? Forslag: per entitet, domene-scoped, i tråd med
   identitetsmodellen.
3. Skal PCC-entitlement søkes for Binding nå? Den er gratis for Small Business
   Program < 2 mill. nedlastinger og gir 32k kontekst + resonnering, som
   genereringscellen trenger for skeleton-JSON.
4. Hvilket formålsutsnitt blir første skill: Lists («Mine lister»), Arendalsuka-
   program eller SDG-pilot «local child participation»? Forslag: Lists, fordi
   cellen, kontraktene og de godkjente bildene finnes.

## 9. Hva som bevisst ikke er gjort

- Ingen kode, kontrakt eller skeleton er endret. Dette er P0–P2 som forslag.
- Ingen gate er satt. `Deliverables/PDD_siri-ai_*`-mappen opprettes med
  `purpose_dev.py new` på Mac-en (verktøyet ligger i CellProtocolDocuments, som
  ikke er i denne sesjonen).
- Ingen målinger på enhet; alle påstander om rekkevidde i Norge er ukjente.
- Innlogget Apple-dokumentasjon (Xcode/Safari) er ikke lest; bare offentlige
  sider.
