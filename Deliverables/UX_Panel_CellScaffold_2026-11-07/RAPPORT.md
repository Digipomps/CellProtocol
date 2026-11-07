# UX/GUI/design-panel: gjennomgang av alle flater i CellScaffold

Dato: 2026-11-07 · Repo: `Digipomps/CellScaffold` @ `39c5d8b` (grunn klon) · Bestilt av: Digipomps (Kjetil) ·
Metode: `haven-panel-task-decomposition` (brief-revisjon, to adjudikatorer) tilpasset GUI, nå nedfelt som skill
`commons/skills/haven-ux-surface-review`. Panelet var sju AI-rådgivere med faste roller pluss to adjudikatorer.
Ingen produktkode er endret. Alle funn er forslag til Digipomps.

Kort versjon: 53 JSON-flater, 152 Swift-definerte flater og 27 web-maler er vurdert. Formålsbeskrivelser finnes for
de fleste, men ingen av dem har et målbart mål, og i 20 flater finnes formålet bare utenfor filen eller ikke i det hele tatt.
Flatene besvarer formålet sitt i hovedsak, men med fire gjennomgående svakheter: tomme lister som ser rolige ut, farlige handlinger
uten vern, elementer uten uttalt formål (demo-, debug- og paritetsrester) og manglende synlig vei tilbake til egen entitet. Fem funn ble meldt som blokker; etter adjudikator Bs rendring og kodelesing står tre, ett falt og ett er
nedjustert, mens B løftet to nye (Idea Task Workspace uten vei tilbake, Broadcast-mottakerliste død på web) (se §6). Regelsettet som kom ut av runden står i §8 og i skillen.

## 1. Formål og mål for panelrunden – sluttstatus

| Formål | Mål | Status | Begrunnelse |
|---|---|---|---|
| F1 Alle tilgjengelige flater er vurdert | 100 % av inventaret har en rad | **satisfied** | 53 JSON-flater (vedlegg A), 152 Swift-flater (vedlegg D/P2 §Formålsmatrise Swift), 27 Leaf-maler (P2 §Lag G, P6), Porthole-skall, runtime-flateliste. Rendret: bare de flatene adjudikator B valgte (§6). |
| F2 Formålsbeskrivelsen er vurdert for kompletthet og besvarelse | Per flate: finnes / komplett 0–5 / besvart | **satisfied** | Matrise for 39 JSON-flater (P1), 152 Swift-flater (P2), 27 maler (P2). |
| F3 Hvert element har et formål | Elementer uten formål navngitt per flate | **delvis** | Element-nivå for 39 JSON-flater og 12 Swift-flater; de øvrige 140 Swift-flatene bare på flatenivå. Eier: neste runde, med `surface_inventory.py` + fabrikk-dump. |
| F4 Vurdert mot anerkjente prinsipper og husregler | Hvert funn peker på prinsipp/husregel | **satisfied** | Alle 205 funn i vedlegg D har prinsipp-kolonne. |
| F5 Helhetlighet på tvers | Tverrgående funn | **satisfied** | P7 (18 funn) + tverrgående-flagg i P1–P6. |
| F6 Læring inn i skills, også Codex | Regler i SKILL.md; distribusjon | **satisfied i CellProtocol / blocked i CellScaffold** | Regler A–J i `haven-ux-surface-review/references/rules.md`, addenda i `cellconfiguration-skeleton-authoring`. CellScaffold/`~/.codex`/Desktop-ZIP krever Mac → Codex-handoff `commons/prompts/codex_ux_panel_skill_distribution_handoff_2026-11-07.md`. |

## 2. Metode

1. Inventar med skript (vedlegg C) over alle JSON-filer med `skeleton`; Swift-fabrikker via `purposeDescription`-grep; Leaf-maler via rute-grep.
2. Brief (vedlegg B) med formål, inventar, hvor formålet bor, husregler, deklarerte konflikter K1–K3, rubrikk.
3. Sju roller parallelt, hver med fil-rapport (vedlegg D): Formålsrådgiver A (JSON) og B (Swift + web), UX-heuristikk 1 (konferanse) og 2 (øvrige), Visuell design + tilgjengelighet, Web-/Porthole-skall, Helhet/IA + skeptiker.
4. Korreksjonsrunde på brief-feil (§3). Adjudikator A (orkestrator) konsoliderte; adjudikator B fikk de fire hardeste dommene som utfordringer og rendret/leste kode (§6).
5. Regler trukket ut, dedupliset til A–J (§8), lagt i skill.

Begrensning som gjelder hele rapporten: panelet leste kode og JSON; bare adjudikator B rendret, og bare utvalgte flater. Ingen flate er kjørt i Binding. Alvorlighet som hviler på en antakelse er merket.

## 3. Korreksjonsrunde: feil i briefen og hva de gjorde med funnene

Hver panelist åpnet med brief-revisjon (Book 30, D2). Fjorten feil ble funnet. Ingen av dem veltet et fagfunn, men flere endret ramme eller tall:

| # | Feil i briefen | Rettelse (retrieved) | Virkning på funn |
|---|---|---|---|
| 1 | «A/B = designvarianter» for demo-dashbordene | Seks ulike formål (`ConferenceDemoDashboardConfiguration.swift:33-61`): Arrangør saksbord/kjøreplan, Utstiller standvakt/oppfølgingsplan, Partner avtaleregnskap/løfteinnboks | Vurdert som seks flater. Står. |
| 2 | «Seks conference-scenarier, ingen byte-like» | 13 scenariofiler, 8 conference-par; sponsor identisk, control-tower og editor skiller seg bare i Picker-UUID; reell drift i 5/8 | K1 snevret. A-10 står (public-surface er den store driften). |
| 3 | K2 tilskrev `#172033` conference | `#172033` er Co-Pilot/Butler-farge (403 i b4a2779a, 0 i conference); `#D5E4ED` 1 487 var dobbelttelt (787 i katalog) | K2 omformulert: katalogflatene har ingen temafil, hex er eneste styling der (A-20). |
| 4 | «61 filer / ~7 300 linjer» | 152 treff i 52 filer + 7 fabrikker via konstant; `ConfigurationCatalogCell.swift` er 12 667 linjer | Tall rettet. |
| 5 | «30 ukjente purpose-refs»; antok Swift `discovery.purpose` er en ref | 26 distinkte; Swift `purpose` er fritekst-tittel i 150/152, refs ligger i `interests` som `purposeRef=…`; `kb_refs.txt` manglet refs (147 i hele Book) | Omrammet fra «ukjente refs» til «formålsfelter brukt mot kontrakt» (A-1b). Tolkning av ukjente refs fortsatt åpen. |
| 6 | `haven.goal-definition.v1` «i Book 23» | Står i Book 30 l. 82 | Sitat rettet. |
| 7 | «skeleton-format = schema-and-limits.md» | Publiserte flater bruker `payloadKeypath`, `labelKeypath`, `altKeypath`, `linkURL(Keypath)`, `playQueueKeypath`, `backgroundKeypath`, `Audio`, `AudioQueue`, `Tabs`, `Visualization` – verifisert i web-runtime, ikke i doc | Nytt funn I3; addendum lagt i skillen. |
| 8 | Formålskilder: Kunstnerportefølje, demo-dashbord, Butterpop | Kunstnerportefølje: `docs/Kunstnerportefolje_pub_flate_NO.md`; dashbord: Swift-filen, ikke `Conference_Demo_*.md`; `Butterpop_Public_Method` dekker bare metoden-siden | Funnet likevel; A-2 står. |
| 9 | «b4a2779a = nyeste Butler-snapshot» | .md kaller den «former production version»; pretree/prewb er fra senere commits | Alle Co-Pilot-funn merket «snapshot – verifiser mot dagens fabrikk». |
| 10 | Lag D som produktflater | Tillitspakke-fiksturer er syntetiske regresjonsdata; Palazzo Gjest har aldri lastet på staging (422, natt-QA 2026-09-03) | Alvorlighet på disse er JSON-nivå; B-3 sendt til adjudikator B. |
| 11 | Lag G manglet i inventarfilen; `haven-localization.js` kalt «språkbytte» | P6 laget egen matrise; filen er intl-bundle, Porthole har ingen språkvelger | Ingen funn påvirket; F-15 (P7) presisert. |
| 12 | «22 temaer, ett per flatenavn» | 8 er `@import`-stubber, A/B-par er byte-like, `Palazzo Gjestebrief.css` har ingen flate → 13 distinkte | A-20 presisert. |
| 13 | Elementtall | `inventory.py` telte ikke stakker i array-form (Control Tower 641 → 706) | Skript rettet (vedlegg C), vedlegg A regenerert. |
| 14 | Designguidens «Do it/Dismiss» | Finnes ikke i kode (0 treff) | Nytt funn I4 (guide ikke avstemt mot fabrikk). |

## 4. Flateinventar (sammendrag)

| Lag | Antall | Formål i filen | Kilde til formål ellers |
|---|---|---|---|
| A Katalog-JSON (`Documentation/ConfigurationCatalog`, `ProjectControl`) | 14 | 14/14 (`purpose` fritekst, `purposeDescription`) | – |
| B Publiserte skeletons (`Public/skeletons`) | 7 | 0/7 | `ButterpopStudio_Product.md`, `Butterpop_Public_Method_20261030.md`, `docs/Kunstnerportefolje_pub_flate_NO.md` |
| C Ressurs-skeletons (demo-dashbord ×6, journey, spillverksted) | 8 | 1/8 (journey) | `ConferenceDemoDashboardConfiguration.swift`, GameWorkshop FORMAALSSPEC |
| D Fiksturer som er produktflater | 6 | 5/6 | README/PROVENANCE |
| E Playwright-scenarier (13; 8 conference-kopier, 5 unike) | 13 | 1/13 | arver via `preview.json configurationName`; 3 (palazzo-communale, restaurant-guest-shell, trust-packet) har ingen formålsbeskrivelse funnet |
| F Swift-fabrikker | 152 flater i 52 filer | 152 `purposeDescription` (kompletthet: 49×1, 70×2, 30×3, 3×4, 0×5) | – |
| G Leaf-maler + skall | 27 maler, Porthole-skall, login, admin | formål dokumentert for skall/admin/Butterpop; ikke for login, docs_workbench, chat_mvp, rag_mvp, ai_usage, palazzo_communale, orchestrator | – |
| H Runtime-flateliste (`surfaces.json`) | format | `purposeRef` + `reason` (reason valgfri i kode) | – |

Full tabell: vedlegg A (JSON), vedlegg D/P2 (Swift og maler).

## 5. Funn

### 5.1 Blokker (fem meldt; tre står etter B, pluss to B løftet)

| ID | Flate | Funn | Prinsipp | Kilde | Status etter B |
|---|---|---|---|---|---|
| B-1 | Mermaid Renderer Playground, Staging Demo (Obsidian+Mermaid), Vault Workspace | All `Text` har `foregroundColor:#D5E4ED` uten `background`, ingen temafil, navnet gir ikke mørk `product-view`/`conference-view` → 1,3:1 på hvit canvas (antatt) | WCAG 1.4.3 | P5 #1 | **står** – rendret: rgb(213,228,237) på rgb(255,255,255) i `canvas view-mode` = 1,30:1 (vedlegg E). Grunn: formålet kan ikke nås (1.4.3 er AA, ikke A). |
| B-2 | Konferansedemo utstiller-A (3), utstiller-B (7), arrangør-A (1); arrangør/partner A/B | `Picker` med `label:""` uten `accessibilityLabel`; `TextArea` svarutkast uten placeholder/label → kontroller uten tilgjengelig navn | WCAG 4.1.2 / 3.3.2 (A) | P5 #2/#3, P3 U30 | **står** – `renderPicker` setter `aria-label` bare når `label` finnes (runtime l. 3116–3129); P3 hadde satt U30 for lavt. |
| B-3 | Palazzo Gjest (`gjest-sicilia-liste`), palazzo-communale-parity | `TextArea` uten `targetKeypath`; send-knapp sender `payload=true` → det gjesten skriver når ikke cellen | H1; guardrail «ingen døde keypaths» | P4 F12.1/F17.1 | **Palazzo Gjest faller** (rest: moderat – feltet mangler navn/affordans for Enter): `TextArea` har `submitActionKeypath` + `submitOnEnter`; rendret Enter sender teksten (Apple gjør det samme). **Palazzo-parity → alvorlig**: Enter virker, men knappen «Send spørsmål →» sender `true`, som Palazzo-cellen avviser (`invalidQuery`). |
| B-4 | Co-Pilot Chat (b4a2779a) | 35 ikon-knapper («−» ×19, «×» ×12, «⤢», «✕») + 2 tomme labels uten `accessibilityLabel` | WCAG 4.1.2 (A) | P4 F14.1, P1 F-18 | **→ alvorlig**: de 30 «−»/«×»-knappene får `aria-label` = tegnet (navn uten mening, ikke navnløse); de 2 «tomme» har `labelKeypath`. Snapshot – verifiser mot dagens fabrikk. |
| B-5 | `base.leaf` (login), `chat_mvp.leaf`, `conference_mvp.leaf` | `lang="en"` på sider med norsk innhold; offentlige conference-ruter rammes | WCAG 3.1.1 (A) | P6 X-01 | **står** – bekreftet i alle tre filer. |
| B-6 (ny, fra B) | Idea Task Workspace (`ConfigurationCatalogCell.swift:7663 ff.`) | Produktflate med skjult Porthole-krom og ingen Co-Pilot/Butler/URL i fabrikken; eneste vei tilbake er URL-param `showProductChrome` eller at Co-Pilot sender `portholeUI` | Book 12 owner-entity-access; H3 | ADJ_B E3 | **blokker-kandidat** – skall lest, ikke klikket; bekreft i Porthole før dom. |
| B-7 (ny, fra B) | Control Tower Broadcast-mottakerliste | `List` med bare `selectionStateKeypath`, ingen `selectionActionKeypath`; web-runtime dispatcher aldri (l. 9011–9020) og server-projeksjonen leser ikke list-state → mottaker kan verken velges eller vises på web; Apple virker | «formålet kan ikke nås» på én plattform | ADJ_B C4/E2 | **alvorlig, web-spesifikk** (B: burde vært eget funn). |

### 5.2 Alvorlig (21 konsoliderte; Bs justering står i siste kolonne)

| ID | Flate(r) | Funn | Prinsipp / husregel | Kilde |
|---|---|---|---|---|
| A-1 | Alle 152 Swift-flater og 14 katalogflater | Ingen formålsbeskrivelse har målbart mål; 49 Swift-flater sier bare «hva». `discovery.purpose` er fritekst i 150/152 Swift og 12/14 JSON; refs ligger i `interests` som `purposeRef=…` | Book 30 goal-shape, Book 23; F2 | P2 F-1, P1 F-01, P7 F-14 · **B: → moderat** (prosess-/beskrivelsesgap, ingen brukerfriksjon). Panelet beholder det øverst fordi det er oppdragets F2 og rammer alle flater. |
| A-2 | Public/skeletons ×7, demo-dashbord ×6, spillverksted, scenarier palazzo-communale / restaurant-guest-shell / trust-packet | Formålet står ikke i filen; for de tre scenariene ikke funnet noe sted | A1 «formålet reiser med filen» | P1 F-02/F-08 |
| A-3 | Conference participant/public/control-tower/sponsor-skall, Palazzo Guest/Staff, Conference Partnering MVP | `purposeDescription` er paritets-/wrapper-begrunnelse («so Binding and web can share…»), ikke brukerformål; Sponsor-flaten blir dermed 100 % «elementer uten formål» | H2; task-first | P2 F-2, P1 F-09 · **B: → moderat** (dokumentasjonsfunn) |
| A-4 | ~30 flater: Butterpop innlogget, Kunstnerportefølje ×4, spillverksted, demo-dashbord ×6, journey, tillitspakke, trust-packet, Kallimachos, 9 katalogflater, alle fire conference-skall | Ingen synlig vei til egen entitet/Co-Pilot i skeletonet; Porthole-skallet gir Butler-nav bare for `productContext=arendalsuka`, skjuler produkt-krom og kan bare gjenåpnes via URL-param/Co-Pilot-kommando | Book 12 `purpose://skeleton.owner-entity-access`; H3 | P1 F-06, P2 F-3, P7 F-02, P6 W-01 · **B: delt i tre** – (1) Porthole-rendrede ikke-produktflater (alle conference-katalogflater m.fl.): verktøylinjen har alltid «Butler Chat» (porthole-webo.js:5402–5408) → skall-dekket men udokumentert garanti, **moderat**; (2) reelt manglende, **alvorlig**: `/pub`-sidene (kunstnerportefolje-skeletonene har null `url`/`linkURL`, butterpop/innlogget lenker bare `/butterpop` – for en innlogget flate nær blokker), conference-flater i `conference_mvp.leaf`-skallet (bare «Open in Porthole»), Idea Task Workspace (B-6); (3) fixtures/scenarier uten vert: ikke dømbar. P2 F-3 i opprinnelig form **faller** (l. 3228 viser at conference-flater ikke er produktflater). |
| A-5 | Control Tower, Participant Portal, Sponsor, Nearby Radar | 21 rad-knapper `label:"Action"` uten `labelKeypath`/`payloadKeypath`; virker bare via runtime-default | H6; designguide «every action explainable by its label» | P1 F-03, P3 U02 · **B: udokumentert** – web erstatter «Action» med radens `label` (`resolveButtonSpec`, l. 2366–2395); trenger rendering med raddata og Apple-sti før dom. Står som regel (kontrakten er usynlig i skeletonet), ikke som brukerfeil. |
| A-6 | Control Tower (11 paneler), Sponsor (4) | `Tabs` uten etiketter → web «Overview/Story/Live/Follow Up», Apple kapitalisert id: engelsk, renderer-avhengig | H2, H4, K3 | P3 U01 |
| A-7 | Control Tower (12 Picker + Broadcast-liste), Profile Editor (3 Picker) | `selectionStateKeypath` peker på action-keypath, ikke `.state.` → valg vises aldri; Broadcast mangler `selectionActionKeypath` | H1; «ingen døde keypaths» | P3 U03 · **B: faller for de 12 Pickerne** – alle har også `selectionActionKeypath`; cellen har get-intercept på action-keypathen som returnerer `{selected}` (`ConferenceAccessRequestCell.swift:218–224`), projeksjonen leser den (`PortholeBootstrapProjection.swift:117–122`); rendret: valg vises og sendes. Resten (Broadcast-listen) er B-7. **Ny fra B (E1):** Apple `CellPickerView.swift:180–186`/`CellListView.swift:494–500` sender til både state- og action-keypath → identiske verdier gir dobbel dispatch på Apple (web én gang) – alvorlig paritetssplitt. |
| A-8 | Control Tower, Sponsor, Editor, Chat, Butterpop, Korrespondanse, Kallimachos, Co-Pilot, Tillitspakke | Destruktive/konsekvensfulle handlinger (Publish, Discard draft, Send til alle, Expire grant, Run retention sweep, Kjøp sang, Godkjenn/Avvis, Slett historikk, Stopp flåten, Trekk tilgang) i samme HStack og stil som trygge, uten bekreftelse/angre/konsekvenstekst; `payload {"confirm":true}` satt av knappen | H5, H3; Book 20 | P3 U06, P4 F8.1/F5.1/F14.6/F16.2/F13.2 |
| A-9 | Gjennomgående: katalog (Control Tower 42 lister), Formålsdekning, Palazzo Gjest, tillitspakke, trust-packet, Korrespondanse, Sponsor | Tom liste skiller ikke «ingen» fra «kunne ikke lese»; statisk ro-tekst («Ingenting er delt ennå»). Forbilder: partner-A («Kunne ikke hente» + «Prøv igjen» + «sist kjente tilstand»), Spillverksted `emptyCards`, Kallimachos | lesson.empty-list-must-not-look-like-calm; H1 | P1 F-05, P3 U20, P4 F12.2 |
| A-10 | Conference Public Surface | Katalog/Swift: fem inerte lister uten valg/detalj/handoff; scenariet har Tabs, 36 keypaths og 10 knapper som cellen støtter; `Conference_Surfaces_Functional_Reference.md` beskriver scenariet som levert | Book 35 «flaten skjuler ikke sine egne veier inn»; K1 | P3 U15, P7 F-01 |
| A-11 | Participant Chat, Participant Portal, Co-Pilot Chat | Primærhandling er hardkodet demo-person («Start demo-chat med Sara», «Foreslå Samir»); «Post spørsmål»/«Stem nyttig nå»/«Stem første» med canned payload – formålet oppfylles bare med forhåndsskrevet innhold | H2, H7; lesson.placeholder-example-leaks-into-judgement | P3 U10/U12, P4 F14.4, P1 F-13 |
| A-12 | Control Tower Published Content (129 el., 19 knapper, 24 felt), Simulation Studio (119 el.) | Alt i én rulle; «Publish content» etter ~120 elementer | Hick; task-first; «detaljer over folden» | P3 U04/U05 |
| A-13 | Konferansedemo arrangør-B | 9 896 elementer, 109 identiske List-skjeletter, 8 419 visibility-regler, «Simulert» ×251 – 16-sesjons rutenett utrullet statisk; lastetid mot ≤ 5 s ikke målt | pkg.std.gui-surface; vedlikehold | P1 F-07, P3 U29 · **B: → moderat** – målt 1,96 MB, 48 statiske + 9 848 elementer i 420 radmaler (ikke statisk utrullet), create 20 ms / malt 126 ms med tomt state; lastetid med data ikke målt. |
| A-14 | Butterpop ×2, Kunstnerportefølje ×4, Kallimachos (9 ikoner), Public Surface hero | `Image` uten `alt`/`altKeypath`; web-runtime leser `accessibilityLabel || name || "skeleton-image"`, ikke `alt` (protokoll og Apple bruker `alt`) → paritetsbrudd i rendereren | WCAG 1.1.1 | P4 F7.1/F9.1/F16.1, P5 #4/#6/#15 · **B: Butterpop/Kunstnerportefølje faller** – bildene har `altKeypath`/`alt`/`accessibilityLabel` og data-bundet sti bruker dem (l. 2881–2894). **Står:** Kallimachos-ikoner (aria-label = SF-navn, l. 2848), Public Surface hero, og renderer-splitten statisk/data-bundet (l. 2860 vs 2894). B: `skeleton-element-catalog.spec.js` rendrer i mørk `product-view` og låser dermed canvas-antakelsen inne (E4). |
| A-15 | Palazzo Communale (web-paritet) | Sikkerhetstekst om krysskontaminering `#F3D8CA` på `#B44E2E` 3,81:1; «TRYGGHET FØRST» 2,64:1; «CONCIERGE» 4,43:1 – farger fra JSON | WCAG 1.4.3 | P5 #5 |
| A-16 | Vault Workspace, Staging Demo | «List notes» og fem andre Vault-knapper uten noen bundet utdata; statisk kopi forklarer at «knappene ikke får svar» | Formål uten element; H1 | P1 F-04, P4 F2.2 |
| A-17 | Transcript Store; Sponsor «Unlock & Retention»; Trust Packet | `visibleActions` (read/release/setPolicy) uten element; ti statuslister uten setning i formålet; bruker må skrive rå `purpose://` i felt | A4; H2 | P2 F-4/F-5, P4 F19.1 · **B:** F-4 står (kodelest), F-5 → moderat (tetthet), F19.1 udokumentert (fixture – bekreft at fabrikken gir samme placeholder). |
| A-18 | Todo Planner Copilot, Obsidian AI Workspace, Cell Configuration Architect | Identisk «Paste API key and press Enter»-blokk i tre planleggingsflater, i strid med Personal Assistant Profile-regelen om separat valg + tillitspakke | H4, H10; synlig eierskap | P2 F-7 |
| A-19 | Alle web-flater (9 JS-filer); chat_mvp/conference_mvp/lead_vault | `HTTP ${status}: ${statusText}`/`error.message` vist rått; `aria-live="polite"` på `<main>` som får `innerHTML` byttet; conference-skall engelsk laste-/feiltekst uten «prøv igjen» | H9; WCAG 4.1.3; lekkasjeregel | P6 X-02/X-03/P-06 |
| A-20 | Login; `/private`; admin-development | Ingen `<form>`/submit (Enter gjør ingenting), ingen `<noscript>`, «Personvern/Vilkår/Hjelp» → `href="#"`; `/private` rendrer mal som ikke finnes → 500; tomtilstand/personvernlinje 3,25:1 | H7, H9, H10; WCAG 1.4.3 | P6 L-02/L-03/R-01/A-01 |
| A-21 | Alle flater (stilstrategi) | Tre stilmekanismer (inline hex / `styleRole`+porthole-webo.css / tema-CSS per visningsnavn) uten prioritetsregel; ingen temafil for noen av de 12 katalogflatene (hex er eneste styling der); `styleVariables` brukes av 0 flater; 125 distinkte hex; 20 fontSize-verdier; auditens hex-normalisering motsier guidens «styleRole = progressiv forbedring» | H4; WCAG 1.4.3 i begge moduser; K2 | P7 F-03, P5 #11–#13, P3 U35 · **B: → moderat** (arkitektur-/regelfunn uten målt brukerkonsekvens; C1 er den målte konsekvensen og står for seg). |

### 5.3 Moderat, lav og observasjon

94 moderate, 41 lave og 21 observasjoner står i vedlegg D med sti og anbefaling. De viktigste klyngene:

- **Språk:** engelsk/norsk blandet i samme skjerm og samme setning; rolle-avhengig språk (arrangør/sponsor/editor engelsk, deltaker norsk); 7 verbformer for «legg til», Avvis+Avslå i samme flate, «Start/Send/Fjern» overbelastet; Co-Pilot Chat/Butler/Copilot som fire navn på samme anker (P3 U18, P7 F-04/F-05/F-06, P2 F-13).
- **Debug og demo i produktflater:** «Document State»/«Runtime State» med cache/hash/correlationId; «Demo Flow»-seksjoner; «Tema: auto»-tekst stylet som knapp; mockup-fotnoter; demo-seed i katalog (P1 F-10/F-22, P3 U09/U25/U28, P2 F-6/F-8).
- **Tilgjengelighet:** 399 av 403 tekstfelt har navn bare via placeholder; konferansedemo-knapper 4,42:1 (lys) / 3,64:1 (mørk); Porthole-badge 2,49:1; Butterpop Studio-faner uten `aria-controls`; sju `aria-live`-regioner (P5 #8–#10, P6 P-01/P-02).
- **Struktur:** faste bredder (17 × `width=180`, Picker 300/320) i rader → mobil-overflow; detalj under lang liste; samme handling to steder; `visibility` med rot-scope i journey (P3 U22/U14/U08/U26).
- **Kilder og paritet:** 5/8 conference-scenarier driftet; Korrespondanse scenario 21 vs katalog 72 elementer; fem ordrette formålskopier i Swift; ingen godkjente referansebilder i repo (bilde før kode oppfylt for ≤ 3 av ~30 produktflater) (P3 K1, P1 F-15, P2 F-20, P7 F-12).
- **Web-rester:** `hello.leaf`, `orchestrator2.leaf`, `simpleproject.leaf`, `feedplayerwidgettest.leaf` uten rute; `orchestrator.leaf` levende men tom; `ai_usage*.leaf` og `conference_mvp.leaf` uten formålsspor; `surfaces.json` har `reason` valgfri i kode (P2 F-16–F-19, P6 P-08).

### 5.4 Forbilder funnet underveis (bruk dem som maler)

Kunstnerportefølje (eneste flatesett med målbart mål, eksplisitt avgrensning, `altKeypath`, tom-tekst fra data) · partner-A/B feiltilstand («Kunne ikke hente» + «Prøv igjen» + «sist kjente tilstand kl. 09.20») · Butterpop innlogget (`accessibilityLabel` på alle felt, armed-mønster «Trykk igjen for å slette») · Formålsdekning (alle løfter har element, alle elementer har formål) · `porthole_identity_unavailable.leaf` og `palazzo_communale.leaf` (feilside og skall uten funn) · Korrespondansegodkjenning katalog (100 % `styleRole` med CSS-dekning) · Participant Portal (`tabsKeypath` → norske faner).

## 6. Adjudikering

### 6.1 Adjudikator A (orkestrator)

Konsoliderte 205 funn fra sju rapporter (7 blokker, 42 alvorlige, 94 moderate, 41 lave, 21 observasjoner før adjudikering) til 5 blokker, 21 alvorlige og tre klynger under. Dedupliserte funn som flere roller fant uavhengig (tom liste: tre roller; owner-entity-access: fire roller; språk: fem roller) – uavhengig gjenfunn er brukt som styrke, ikke som «flere funn». Valgte fire dommer til B etter regelen i `panel-roles.md` §Adjudikering: én blokker på renderer-antakelse (C1), én tverrgående dom på ulest skall (C2), én «død keypath» (C3), én som rollen selv ba om render-bekreftelse for (C4).

### 6.2 Adjudikator B – kjennelser

Fulle kjennelser med bevis: vedlegg E (`ADJ_B.md`, skjermbilder, `render_report.json`, `render_check.js`). B rendret skeletons offline med web-runtime (mønster fra `skeleton-element-catalog.spec.js`) i tre canvas-klasser og leste runtime, server-projeksjon og Apple-visninger.

| Utfordring | Panelets dom | Bs kjennelse | Bevis |
|---|---|---|---|
| C1 `#D5E4ED` på hvit canvas (B-1) | blokker, antatt bakgrunn | **Står.** Porthole gir disse tre navnene `canvas view-mode` (porthole-webo.js:5369–5388, 3227–3270); målt 1,30:1. Presisering: blokker-grunn er «formålet kan ikke nås», ikke WCAG A. Apple ikke målt. | `render/*__canvas_view-mode.png` (adjudikator A har sett bildet: tekst og seksjonsoverskrifter er praktisk talt usynlige), `render_report.json` |
| C2 owner-entity-access ~30 flater (A-4) | alvorlig, skall ulest | **Omklassifisert – delt i tre** (skall-dekket/moderat · reelt manglende/alvorlig · ikke dømbar). Panelet (P2) siterte l. 3228 men trakk motsatt slutning. | porthole-webo.js lest, ikke klikket |
| C3 Palazzo TextArea uten `targetKeypath` (B-3) | blokker | **Palazzo Gjest faller** (`submitActionKeypath`+`submitOnEnter`, rendret Enter → `onAction("entity.entity.record", …)`; Apple `SkeletonView.swift:3955–3996` likt). **Parity → alvorlig** (knappen sender `true`; cellen krever streng). | `render/palazzo-gjest.png`, `palazzo-parity.png` |
| C4 Picker `selectionStateKeypath` = action (A-7) | alvorlig | **Faller for 12 Picker** (get-intercept + projeksjon + rendret valg). **Broadcast-listen død på web** → eget alvorlig funn (B-7). | `render/control-tower-picker.png`, `PortholeBootstrapProjection.swift:117–122` |

Gjennomgang av alle 49 blokker/alvorlig-funn (vedlegg E §D): 30 står (3 «per rubrikk», 1 skjerpet), 13 omklassifisert ned, 4 faller (U03, F12.1, F7.1/F9.1, P2 F-3 i opprinnelig form), 3 udokumentert (P1 F-02 nummerering, F-03 «Action», F19.1 fixture), 1 for mildt (U30 → blokker).

Der panelet var for mildt (vedlegg E §E): (1) Apple dobbel dispatch når state- og action-keypath er like; (2) Broadcast-listen død på web; (3) Idea Task Workspace som konkret blokker-kandidat; (4) testinfrastrukturen (`skeleton-element-catalog.spec.js`) låser inne den mørke canvas-antakelsen som gir C1; (5) `/pub`-skeletonene har null utganger – for innlogget Butterpop nær blokker etter Book 12.

Adjudikator A tar Bs kjennelser til følge i sin helhet. Retning på korreksjonene: 13 ned, 3 opp (U30, B-6, B-7) – panelet dømte i hovedsak for hardt der det ikke hadde rendret, og for mildt der det ikke hadde lest Apple-siden. Begge deler er argumentet for regelen «render eller les kode før dom» i skillen.

## 7. Panelets kvalitetsmål (Book 30 Q1–Q10, diagnostikk – ikke mål)

| # | Mål | Verdi | Bevis |
|---|---|---|---|
| Q1 Sporbare posisjonsendringer | 100 % | 17/17 | Alle 13 nedjusteringer, 4 fall og 3 skjerpinger i §6.2 peker på fil:linje eller skjermbilde (vedlegg E §D). |
| Q2 Blandet ledger | retning, ikke tall | 30 står / 13 ned / 4 faller / 3 opp | Objektet er husets egne flater; feilmodus var hardhet. Bs rolle korrigerte den, og fant samtidig tre punkter panelet var for mildt på. |
| Q3 Revisjonsærlighet | 100 % retrieved på bærende funn | 205/205 merket `retrieved`; 9 bærer eksplisitt «antatt bakgrunn»/«ikke rendret» | Antakelsene står i funn-kolonnen; C1-antakelsen ble målt. |
| Q4 Narrativ uavhengighet | hovedfunn holder under begge rammer | 4/5 | Tom liste, farlige verb, formålsfelter og språk holder uansett om flaten kalles «demo» eller «produkt»; owner-entity-access avhenger av rammen (skall vs frittstående) og er derfor delt. |
| Q5 Falsifiserbarhet | 0 uflaggede | 0 | Ingen funn er formulert slik at både bekreftelse og avkreftelse støtter det. |
| Q6 Naturlige eksperimenter | hver motfaktisk sjekket | 4/4 | C1–C4 ble rendret/lest i stedet for sannsynlighetsvurdert; to av fire snudde. |
| Q7 Avslørt preferanse | – | ikke relevant | Ingen aktørpåstander om motiv i materialet. |
| Q8 Terminal adjudikering | 100 % | 49/49 blokker/alvorlig; 156/156 moderat/lav/obs | Alle har status står/omklassifisert/falt/udokumentert-med-eier (§5, vedlegg D/E). Udokumenterte (3) har eier D7. |
| Q9 Steelman-kilde | motsatt kilde | 4/4 | Bs motargumenter kom fra runtime, projeksjon og Apple-kode – ikke fra panelets egne rapporter. |
| Q10 Innrømmelser uten anker | 0 | 0 | Hver nedjustering har måling eller linje. |

## 8. Regler som går inn i skills

Regelsettet A–J (52 regler) står i `commons/skills/haven-ux-surface-review/references/rules.md` med funn-ID per regel.
Forfatterreglene er i tillegg lagt som dedikert seksjon i `commons/skills/cellconfiguration-skeleton-authoring/SKILL.md`,
og listen over runtime-felt publiserte flater bruker (med paritetsstatus) i dens `references/schema-and-limits.md`.
Codex får rollemal (`commons/prompts/codex_ux_surface_review_prompt.md`) og distribusjons-handoff
(`commons/prompts/codex_ux_panel_skill_distribution_handoff_2026-11-07.md`) som kopierer skillen til
`CellScaffold/.claude/skills`, `~/.claude/skills`, `~/.codex/skills` og bygger Desktop-ZIP via `sync_claude_desktop_skills.py`,
og som legger lekkasje-utvidelsen inn i `haven-gui-testing` og en krysspeker i `haven-panel-task-decomposition`.

De ti reglene med størst nedslagsfelt:

1. Formålet reiser med filen, svarer på fem spørsmål og er skrevet for brukeren (A1–A3).
2. Hvert element har en setning i formålet; hvert løfte har et element (A4).
3. Tre tilstander per liste – aldri statisk ro-tekst (C1).
4. Farlig verb = to trinn + konsekvens + kvittering, i egen HStack (D3).
5. Tabs, rad-knapper og Picker/felt har forfattede navn; `selectionStateKeypath` peker på state (G3, B1, G2, D2).
6. Fargepar, aldri enkeltfarge; én stilstrategi per flate oppgitt i `description`; én typografiskala (F1–F4).
7. Ett språk per flate; internspråk bare bak «Avansert»; én verbliste (E1–E3).
8. Owner-entity-access er et element eller en dokumentert skall-garanti – fast plass øverst til høyre (H1).
9. Én kilde per flate; scenarier avledet med test; referansebilde i repo (I1–I2).
10. `schema-and-limits.md` speiler runtime med paritetsstatus (I3).

## 9. Åpne punkter og beslutninger til Digipomps

| # | Beslutning | Anbefaling fra panelet | Eier |
|---|---|---|---|
| D1 | Skal reglene A–J bli husregler (Book 12/35) eller forbli panelanbefaling? | Husregel for A1, A4, C1, D1–D3, G1–G3, H1, I1; resten anbefaling til neste runde | Digipomps |
| D2 | K1: skal public-surface få Tabs/valg/handoff i `makePublicSkeleton()` (scenariets design), eller skal Functional Reference rettes? | Ta inn i fabrikken – cellen støtter alt allerede | Digipomps |
| D3 | K2: temafil per katalogflate (flytt hex til `styleClasses`), eller erklær katalog-conference som fast-palett-flater? | Temafil; hex bare som Binding-fallback | Digipomps |
| D4 | Owner-entity-access: element i hvert skeleton, eller skall-garanti + `shellProvided`-markør + reachability-test? | Begge: markør for skall-rendrede, element for `Public/skeletons` | Digipomps |
| D5 | De 26 ukjente purpose-refs: KB-etterslep (legg inn) eller feil (omdøp til `candidate.*`)? | Én liste til Book 23-vedlikeholder; ikke avgjort av panelet | Digipomps / Losen |
| D6 | Rekkefølge på produktfikser | B-1, B-2, B-5 og parity-knappen først (små endringer), så B-6/B-7, så A-9 (tom liste) og A-8 (farlige verb) som mønster-endring i fabrikken, så A-4(2) | Digipomps → PDD |
| D7 | Rendret bekreftelse i Binding for B-2, A-14 (renderer-avvik) og de tre «udokumentert»-funnene | Egen GUI-testrunde med `haven-gui-testing` | Codex/Xcode |
| D8 | Apple dobbel dispatch når `selectionStateKeypath` = `selectionActionKeypath` (B E1) og Broadcast-liste død på web (B-7) | Renderer-fiks i CellProtocol (`CellPickerView`/`CellListView`) + eget state-felt i cellen; paritetstest som kjører begge | Digipomps → PDD |

Ingen av punktene er avgjort av panelet. Ingen produktkode er endret.

## 10. Ikke verifisert

- Ingen flate er kjørt i Binding/Apple; alle Apple-påstander er lest i `SkeletonView.swift`/`SkeletonDescription.swift`, ikke kjørt.
- Web-rendring bare for flatene adjudikator B valgte (§6.2); øvrige kontrast- og layout-funn er regnet fra JSON/CSS med oppgitte antakelser.
- `ConfigurationCatalogSkeletonParityTests` er ikke kjørt; «katalog = Swift-sannhet» forutsetter grønn test på 39c5d8b.
- Lastetid for arrangør-B (2 MB) og Co-Pilot mot «≤ 5 s» er ikke målt.
- Co-Pilot-funn gjelder snapshot `ButlerBuiltIn-b4a2779a.json` («former production version»), ikke dagens fabrikk.
- Element→formål-kartlegging for 140 av 152 Swift-flater er bare på flatenivå.
- Formålsdokumenter for palazzo-communale, restaurant-guest-shell og trust-packet kan ligge i PalazzoScaffold eller CellProtocolDocuments/Deliverables (ikke lett der).
- Git-historikk (grunn klon): tidspunkter for drift og «nyeste snapshot» er ikke fastslått.
- Palazzo `STYLEGUIDE_4`, `Conference_Claude_Desktop_Design_Extracts_2026-05-05.md` og `Porthole_Menu_og_Skeleton_Paritet.md` er ikke lest.

## Vedlegg

- A `VEDLEGG_A_inventar.md` – alle 53 JSON-flater med tall
- B `VEDLEGG_B_brief.md` – briefen slik panelet fikk den (feilene står i §3 over)
- C `VEDLEGG_C_inventory.py` – inventarskript (rettet)
- D `VEDLEGG_D_panelrapporter/P1..P7` – de sju rådgivernes fulle rapporter med alle 205 funn, formålsmatriser og «ikke verifisert»
- E `VEDLEGG_E_adjudikator_B/` – adjudikator Bs fulle rapport (`ADJ_B.md`), rendringsskript (`render_check.js`), `render/` med skjermbilder (view-mode for de tre C1-flatene, product-view-eksempel, Palazzo Gjest, Palazzo-parity, Control Tower Picker), `render_report.json` (beregnede farger) og `render_time.json` (arrangør-B)
