# Panel-brief: UX/GUI/design-gjennomgang av alle flater i CellScaffold (2026-11-07)

Denne briefen binder panelet til REGLER, ikke til FAKTA. Hvert faktum under har en revisjonsstatus
(`retrieved` = lest i kilde av briefskriver i denne økten; `recalled` = fra hukommelse, teller ikke).
Finn du feil i briefen, er det et funn som rangerer over alle fagfunn. Åpne svaret ditt med `## Brief-revisjon`.

## 0. Oppdraget (fra Kjetil, ordrett oversatt til mål)
«Sett opp et UX/GUI- og designekspertpanel og gå gjennom alle flatene du får tak i i CellScaffold. Vurder ut fra
anerkjent gode UX-prinsipper, helhetlighet og hvilke formål det er beskrevet at flaten skal løse. Minst én rådgiver
evaluerer om formålsbeskrivelsen er komplett nok og om den er besvart i flaten. Alle elementer må ha et formål.
Dokumenter godt og få det som virker inn i skills – også i Codex.»

### Formål og mål for panelrunden
| Formål | Mål (målbart) |
|---|---|
| F1 Alle tilgjengelige flater er vurdert | 100 % av flatene i inventaret (§2) har en rad i funn-/statusmatrisen, også «ingen funn» |
| F2 Formålsbeskrivelsen er vurdert for komplett­het og besvarelse | Hver flate har en formålsvurdering: (a) beskrivelse finnes? (b) komplett nok (hvem/hva/utfall/målbart/avgrensning)? (c) besvart i flaten? |
| F3 Hvert element har et formål | For hver flate: andel elementer som kan knyttes til et uttalt formål; elementer uten formål er navngitt |
| F4 Vurdering mot anerkjente prinsipper og husets egne | Hvert funn peker på prinsipp (Nielsen H1–H10, Norman, WCAG 2.2, Fitts/Hick, Gestalt) ELLER husregel (§4) |
| F5 Helhetlighet på tvers | Tverrgående funn om navn, navigasjon, språk, farger, typografi, mønstre |
| F6 Læring inn i skills | Funn som gjelder flere flater er formulert som regel som kan stå i en SKILL.md |

## 1. Repoer og stier (alle `retrieved`)
- CellScaffold: `<HAVEN_ROOT>/CellScaffold` (HEAD 39c5d8b, grunn klon 2026-11-07)
- CellProtocol: `<HAVEN_ROOT>/CellProtocol`
- CellProtocolDocuments (Book): `<HAVEN_ROOT>/CellProtocolDocuments/Book`
- Inventar over alle JSON-flater: `<panel-arbeidsmappe>/inventory.json` og `inventory.md`
  (skript: `inventory.py` samme mappe – gjenbruk/utvid heller enn å lese 10 000-elementers JSON rått)
- Kjente purpose://-referanser (Book 23 + KB-JSON): `.../panel/kb_refs.txt`; brukte refs i CellScaffold: `.../panel/used_refs.txt`

## 2. Flate-inventar (retrieved via inventory.py; 53 JSON-flater + Swift-fabrikker + web-maler)
Lag A – JSON CellConfiguration med `discovery.purpose`/`purposeDescription` (14):
`Documentation/ConfigurationCatalog/CellConfiguration.*.json` (12: 9 conference, mermaid.playground, obsidian-mermaid.staging, vault.obsidian) og
`Documentation/ProjectControl/Formaalsdekning_*.json`, `Korrespondansegodkjenning_*.json`.
Lag B – publiserte offentlige skeletons UTEN discovery-blokk (7): `Public/skeletons/butterpop/{apen-visning,innlogget}.json`,
`Public/skeletons/kunstnerportefolje/{forside,skallside,verk,verkside,butterpop-metoden}.json`. Formål beskrevet i
`Documentation/Butterpop_Public_Method_20261030.md`, `Documentation/ButterpopStudio_Product.md`, `Documentation/Butterpop_Folgere_20261104.md`.
Lag C – ressurs-skeletons i app (8): `Sources/App/Resources/ConferenceDemoDashboard/{arrangor,partner,utstiller}-{A,B}.skeleton.json`
(A/B = designvarianter; arrangor-B har 9 896 elementer), `journey.cellconfiguration.json` (har discovery), `Sources/App/Resources/GameWorkshop/spillverksted.skeleton.v1.json`.
Formål for disse: se `Documentation/Conference_Demo_*.md`, `Documentation/Conference_GUI_Porthole_Design_Guide.md`, GameWorkshop-docs (`grep -ril spillverksted Documentation`).
Lag D – testfikstur-flater som er reelle produktflater (6): `Tests/AppTests/Fixtures/PortholeRemote/gjest-sicilia-liste.cellconfiguration.json` (Palazzo Gjest),
`Tests/AppTests/Fixtures/AgentTrustPackage/skeleton/tillitspakke-{for,etter}.json`, `Tests/AppTests/Fixtures/ButlerBuiltIn-b4a2779a.json` (Co-Pilot Chat, nyeste av fire snapshot),
`playwright/fixtures/kallimachos-advisor-skeleton.json`, `playwright/fixtures/butler-chat-skeleton.json`.
Lag E – Playwright-scenarier (14) i `playwright/skeleton-scenarios/`. De seks conference-scenariene er KOPIER av katalogflatene men har DRIFTET
(ingen av de seks er byte-like katalogens skeleton – retrieved via json-sammenlikning). Unike scenarier: `correspondence-approval`, `palazzo-communale-web.parity`,
`personal-invite-chat`, `restaurant-guest-shell.famiglia`, `trust-packet`.
Lag F – Swift-fabrikker som bygger CellConfiguration i kode: 61 filer under `Sources/App/Cells/**` med `purposeDescription:`; størst er
`Sources/App/Cells/ConfigurationCatalog/ConfigurationCatalogCell.swift` (~7 300 linjer, >40 flater), `Sources/App/Cells/PersonalCopilot/PersonalCopilotConfigurationFactory.swift`,
`Sources/App/Cells/ConferenceMVP/Skeleton/*.swift`, `Sources/App/Cells/Transcript/TranscriptConfigurationFactory.swift`.
Lag G – web-maler og Porthole-skall: `Resources/Views/*.leaf` (27), `Public/js/porthole-webo.js` (10 967 linjer), `Public/js/skeleton-runtime.js` (10 116),
`Public/css/porthole-webo.css`, `Public/css/themes/*.css` (22 temaer, ett per flate-navn), `Public/js/porthole-login.js`, admin-*.js/css, `butterpop-studio.*`, `docs-workbench.*`, `palazzo-communale.*`.
Lag H – runtime-flateliste: `Deployment/porthole/surfaces.example.json` (krever `purposeRef` per flate) og `Documentation/Porthole_Runtime_Surfaces.md`.

## 3. Hvor formålsbeskrivelsen bor (retrieved)
- JSON: `discovery.purpose` (purpose://-ref), `discovery.purposeDescription` (fritekst), ev. `discovery.purposeRefs[]`, `interests[]`, `menuSlots[]`, toppnivå `description`.
- Swift: samme felter i `CellConfiguration(... discovery: ...)`-kall.
- Formålsbasen: Book 23 (`23_Purpose_Knowledge_Base.md`, `haven_purpose_knowledge_base_v0.json`). Mål-shape `haven.goal-definition.v1` (metric, baseline, target, timeframe).
- `purpose://candidate.*` er lovlige oppgavelokale kandidater. 30 ikke-kandidat-refs brukt i CellScaffold finnes IKKE i Book 23/KB
  (bl.a. `purpose://chat`, `purpose://toolbar-test`, `purpose://...`, `purpose://capability.delivery`, alle `purpose://palazzo.*`, `purpose://project-work.*`,
  `purpose://haven.surface.*`). Dette er et faktum med revisjonsstatus `retrieved`, men tolkningen (feil vs. KB-etterslep) er ÅPEN – ikke avgjør den uten kilde.

## 4. Husets egne regler panelet skal måle mot (retrieved; les kilden før du siterer)
- `Documentation/Conference_GUI_Porthole_Design_Guide.md`: task-first, lav tekst-tetthet, synlig eierskap, ingen auto-mutasjon fra copilot, Layer-0-primitiver,
  `styleRole` = progressiv forbedring, Tabs over side-rails, ikke vis kapabilitets-UI verten ikke støtter.
- `Documentation/ArendalsukaParticipantProgram_UX_Guardrails.md`: aldri full liste ved første last, detaljer over folden, ingen auto-select, ingen døde keypaths.
- Book 12 `12_Skeleton_Spec.md`: `purpose://skeleton.owner-entity-access` – hver produksjonsflate må ha synlig vei tilbake til egen entitet/Co-Pilot.
- Book 20 `20_Skeleton_Motion_And_Component_Surfaces.md`: motion er forklaring, ikke pynt; sideeffekter bare etter eksplisitt handling.
- Book 35 §2.3 + `haven_purpose_packages_v0.json` → `pkg.std.gui-surface`: bilde før kode, paritet, laster ≤ 5 s, «flaten skjuler ikke sine egne veier inn» (SkeletonReachabilityAudit).
- Lessons (`haven_lessons_register_v0.json`): `lesson.text-ux-is-not-design`, `lesson.findability-is-not-usability`, `lesson.empty-list-must-not-look-like-calm`,
  `lesson.unresolvable-condition-is-invisible`, `lesson.empty-list-keeps-its-slot`, `lesson.placeholder-example-leaks-into-judgement`, `lesson.sketch-assumed-a-renderer-it-did-not-have`.
- Skeleton-format og grenser: `.claude/skills/cellconfiguration-skeleton-authoring/references/schema-and-limits.md` (CellScaffold). Ikke foreslå elementer som ikke finnes.
- Tidligere UX-gjennomganger (ikke gjenta uten å si at det er kjent): `Documentation/CoPilotChat_CentralGUI_UXReview_2026-06-13.md`, `CoPilotChat_ComponentUXReview_2026-05-20.md`,
  `Conference_Skeleton_Design_Audit.md`, `Porthole_Toolbar_Menu_Design_Evaluation_2026-07-14.md`, `AgreementWorkbenchRedesign_2026-07-15.md`, `Chat_Workbench_GUI_UX_Handoff_2026-06-11.md`.

## 5. Kjente konflikter (deklarert, ikke løst)
- K1: Katalog-JSON vs Playwright-scenario har driftet for alle seks conference-flater; hvilken som er «sann» er ukjent.
- K2: Conference-skeletons bruker hardkodede hex-farger (`#D5E4ED` 1 487 forekomster, `#172033` 405 …) mens designguiden sier `styleRole` er progressiv forbedring og temaer ligger i `Public/css/themes/`. Om hex-bruk er bevisst (Porthole uten tema) eller gjeld, er ukjent.
- K3: Språk: formålsbeskrivelser veksler mellom norsk og engelsk i samme katalog.

## 6. Vurderingsrubrikk (bruk denne, ikke egen)
Alvorlighet: `blokker` (formålet kan ikke nås / brukeren sitter fast / WCAG A-brudd), `alvorlig` (formålet nås med betydelig friksjon eller feil), `moderat`, `lav`, `observasjon`.
Hvert funn: `flate | element/sted (sti + JSON-sti eller linje) | funn | prinsipp/husregel | alvorlighet | anbefaling (innenfor dagens skeleton-format) | revisjonsstatus (retrieved/recalled) | tverrgående? (ja/nei)`.
Formålsvurdering per flate (Formålsrådgiver): `beskrivelse finnes (ja/nei) | komplett (hvem, hva, utfall, målbart mål, avgrensning – 0–5) | besvart i flaten (ja/delvis/nei + hvorfor) | elementer uten formål (liste) | formål uten element (liste)`.
Ikke finn opp purpose://-refs, elementtyper, kapabiliteter eller kilder. `recalled` teller ikke som støtte. Skriv på norsk (bokmål). Sitér korte utdrag, aldri hele filer.

## 7. Leveranseformat
Skriv hele rapporten din til filen oppgitt i oppdraget ditt (markdown). Returner til orkestrator KUN: (1) brief-revisjon i 3–8 linjer, (2) antall funn per alvorlighet,
(3) de 5 viktigste funnene i én linje hver, (4) 3–8 tverrgående regler du mener bør inn i en skill, (5) hva du IKKE rakk/ikke kunne verifisere.
