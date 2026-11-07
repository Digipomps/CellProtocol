# ADJUDIKATOR B – de hardeste dommene prøvd mot kode og rendering

Grunnlag: CellScaffold HEAD 39c5d8b (`<HAVEN_ROOT>/CellScaffold`), CellProtocol (`<HAVEN_ROOT>/CellProtocol`). Rendering er gjort offline med `Public/js/skeleton-runtime.js` + `Public/css/porthole-webo.css` i Chromium (skript: `<panel-arbeidsmappe>/render_check.js` og `render_time.js`; skjermbilder og måledata i `<panel-arbeidsmappe>/out/render/`). Alle påstander under er `retrieved`; ingen `recalled`.

## Brief-revisjon

1. Rubrikken (§6) definerer `blokker` som «formålet kan ikke nås / brukeren sitter fast / **WCAG A-brudd**». Det gjør at ethvert manglende tilgjengelig navn (4.1.2, nivå A) og `lang="en"` (3.1.1, nivå A) automatisk blir blokker, mens 1,3:1 kontrast (1.4.3, nivå AA) formelt ikke er det. Panelet har brukt regelen ulikt (P3 U30 «alvorlig», P5 #2 «blokker» for samme Picker). Briefen bør skille «blokker-stuck» fra «blokker-WCAG-A», ellers blir tellingene usammenlignbare.
2. Briefen sier ikke hvilken **vert** en flate dømmes i. Samme skeleton gir ulik dom i Porthole-skallet (verktøylinje med «Butler Chat»), i `conference_mvp.leaf`-skallet (ingen Butler-lenke), som `/pub`-side (ingen skall) og i Binding. C2 viser at halvparten av «mangler eierentitet»-funnene avhenger av verten.
3. Briefen krever «bevis fra rendering» bare implisitt. Minst fire harde dommer (P4 F12.1, F7.1/F9.1, P3 U03, P1 F-07) faller eller endrer karakter ved første rendering/kodelesing av runtime. Et krav om «kjør runtime på elementet før blokker/alvorlig» bør inn i §6.
4. Inventar-nummereringen (`inventory.md` #1–53) brukes ikke konsekvent (P1 refererer «#36» som palazzo-paritet, inventaret har #36 = Palazzo Gjest). Tabellen i D bruker rapportens egne ID-er, ikke flatenummer.
5. `selectionStateKeypath` har **to semantikker** i huset: Apple skriver til den (CellPickerView/CellListView `submit(payload:to:)`), web leser den bare. Brief §4 («husets regler») nevner ikke dette; flere funn (P3 U03) er bygget på web-semantikken alene.

## C1 – `#D5E4ED` på hvit canvas (P5 #1, blokker)

**Påstand:** Mermaid Renderer Playground, Staging Demo (Obsidian + Mermaid) og Vault Workspace (Obsidian-style) setter `foregroundColor:#D5E4ED` på all Text uten bakgrunn og uten temafil → 1,3:1 på hvitt.

**Motargument:** Bakgrunnen var antatt fra CSS; Porthole kan gi mørk `.canvas`/`.skeleton-section` eller `product-view`.

**Bevis:**
- JSON: 36/43/9 `Text` med `foregroundColor:#D5E4ED`, null `background` i noen av de tre filene (python-opptelling over `Documentation/ConfigurationCatalog/CellConfiguration.{mermaid.playground,obsidian-mermaid.staging,vault.obsidian}.json`).
- Vert-klasse: `Public/js/porthole-webo.js:5369–5388` gir `.conference-view` bare for `/^Conference(?:\s|$)/` eller «Arendalsuka Participant Program», `.product-view` bare når `isProductSurfaceConfigurationName()` (l. 3227–3270: Idea Task Workspace, Co-Pilot Chat, Invite Chat, Questionnaire Campaign, `Arendalsuka *`, eller chatHub-referanse + faner samtale/aktivt/mer). Ingen av de tre navnene treffer → canvas-klassen blir `canvas view-mode`.
- CSS: `.canvas { background:#ffffff }` (`porthole-webo.css:817–825`), `.skeleton-section { background:#ffffff }` (l. 3161–3170), `body { background:#e8edf5 }` (l. 49–54). Mørke bakgrunner finnes kun for `.canvas.conference-view.view-mode` (l. 4856) og `.canvas.product-view.view-mode` (l. 4865). `@media (prefers-color-scheme: dark)` dekker bare `.skeleton-game-preview` og `.skeleton-purpose-tree` (l. 6329, 6377).
- Temafil: `syncConfigurationTheme()` (l. 5313–5337) laster `/css/themes/<navn>.css`; `Public/css/themes/` har ingen fil for de tre navnene (22 filer listet).
- **Rendering** (`render_check.js`, skall `canvas view-mode`, tomt state): `getComputedStyle` gir `color: rgb(213,228,237)` på alle synlige `.skeleton-text`, nærmeste ikke-transparente bakgrunn `rgb(255,255,255)` fra `.canvas` eller `.skeleton-section`; beregnet kontrast **1,30:1** for 10/17/9 synlige tekster (resten er keypath-bundne og tomme uten state). Skjermbilder: `out/render/CellConfiguration.mermaid.playground__canvas_view-mode.png` (overskrift og instruks er praktisk talt usynlige), tilsvarende for staging og vault.
- Kontrollrendering i `product-view`/`conference-view` gir mørk seksjonsbakgrunn (`rgba(15,30,39,0.97)`) → ≈13:1. Fargen er altså riktig for conference-canvasen og feil for den verten disse tre faktisk får.

**Kjennelse: STÅR** for Porthole-web (målt, ikke antatt). Presisering: WCAG 1.4.3 er AA, så blokker-grunnlaget er «formålet kan ikke nås» (instruksen «Rediger kilde, bruk Cmd/Ctrl+Enter …» er uleselig), ikke «WCAG A». Apple/Binding er ikke målt (systembakgrunn, trolig samme problem i lys modus).

## C2 – ~30 flater mangler `purpose://skeleton.owner-entity-access` (P1 F-06, P2 F-3, P7 F-02, alvorlig)

**Påstand:** Ingen synlig vei til egen entitet/Co-Pilot i skeletonet.

**Motargument:** Porthole-skallet gir veien globalt.

**Bevis (a) – hvem rendres hvor:**
- *Porthole-skall* (`/porthole?configurationName=…`): alle katalogflater (#1–12), ProjectControl (#13–14), Konferansedemo-skeletonene (#22–28, temafiler «Konferansedemo …»), Spillverksted (`GameWorkshopConfiguration.swift:13–20`, navn «Spillverksted»), Kallimachos, Co-Pilot Chat, Idea Task Workspace, Invite Chat, Questionnaire Campaign.
- *Frittstående `/pub`-sider*: `Public/skeletons/kunstnerportefolje/*.json` og `butterpop/*.json` rendres av `Public/js/pub-skeleton.js` / `butterpop-skeleton.js` i `PublicationSkeletonPage.swift` / `ButterpopSkeletonPage.swift` – ingen Porthole-verktøylinje. Alle `url`/`linkURL` i disse skeletonene: `/butterpop`, `/butterpop#releases`, `/login?next=…`, `/images/butterpop-wordmark.jpg`; kunstnerportefølje-filene har ingen lenker i det hele tatt.
- *Conference-skall* (`Resources/Views/conference_mvp.leaf` + `Public/js/conference-mvp.js:388–433`): de seks conference-konfigurasjonene rendres også her; eneste utganger er «Open this in Porthole» / «Open library in Porthole» (l. 351–373), ingen Butler/Co-Pilot-lenke.
- *Binding/PortholeRemote-fixtures* (#30–31, #36) og *playwright-scenarier* (#41–53): testkorpus, ingen vert å dømme.

**Bevis (b) – gir skallet veien for alle?** Nei, men for de fleste:
- Verktøylinjen har alltid `<button data-action="open-copilot-chat">Butler Chat</button>` (`porthole-webo.js:5402–5408`), «Bibliotek», «Tilbake»/navigasjonsstakk, og handleren laster Co-Pilot Chat (l. 336–345, `findCoPilotChatConfiguration` l. 3296–3309). Den **skjules kun** når `suppressProductChrome = mode==="view" && isProductSurfaceConfiguration && !productChromeRevealed` (l. 5381–5384). `productChromeRevealed` settes bare av URL-param `showProductChrome` (l. 139–145) eller `portholeUI`-forespørsler fra Co-Pilot (l. 1381–1450) – ingen synlig kontroll (P6 W-01 er korrekt).
- Konsekvens: Conference-flater er **ikke** produktflater (P2 F-3 siterer selv l. 3228 – men trekker motsatt slutning): verktøylinjen med «Butler Chat» er synlig. Det samme gjelder Mermaid/Vault/Staging, Konferansedemo, Spillverksted, Kallimachos, ProjectControl.
- Produktflater med skjult krom: Co-Pilot Chat (er selv eierflaten), Arendalsuka-flater (`arendalsukaBottomNavigationBar()` i `ArendalsukaEventAtlasConfigurationFactory.swift:1060` har «Butler»-element i selve skeletonet), **Idea Task Workspace** (`ConfigurationCatalogCell.swift:7663 ff.`: ingen `url:`/Co-Pilot/Butler i fabrikkfunksjonen) – her er veien reelt borte på web. Invite Chat/Questionnaire Campaign: ikke verifisert.
- Skall-garantien er **udokumentert**: `purpose://skeleton.owner-entity-access` brukes i én fabrikk (`PersonalEntityActivityDashboardConfigurationFactory.swift:9`), og ingen test/validering sier «skallet dekker dette».

**Kjennelse: OMKLASSIFISER – del i tre.**
1. *Skall-dekket, udokumentert garanti* (moderat, tverrgående): alle Porthole-rendrede ikke-produktflater (conference #1–9, #10–12, #13–14, #22–28, Spillverksted, Kallimachos). Anbefaling: skriv garantien inn i `SkeletonReachabilityAudit`/en test som sjekker «enten in-skeleton-affordance eller vert med Butler-knapp».
2. *Reelt manglende* (alvorlig, står): `/pub`-sidene (P7 F-02 – særlig `butterpop/innlogget.json`, som er innlogget), conference-flater i `conference_mvp.leaf`-skallet, og Idea Task Workspace (produktflate med skjult krom uten egen vei → kandidat til blokker: brukeren kan ikke komme tilbake uten å kjenne URL-param).
3. *Ikke dømbar* : fixtures/scenarier (#30–31, #36, #41–53) – ingen vert; test-korpus ≠ levert korpus.

## C3 – Palazzo Gjest / palazzo-communale-paritet: «det gjesten skriver går ingen steder» (P4 F12.1, F17.1, blokker)

**Påstand:** `TextArea` uten `targetKeypath`; send-knappen sender `payload=true`.

**Motargument:** Runtime kan sende via `submitActionKeypath`/`submitOnEnter`.

**Bevis:**
- `Tests/AppTests/Fixtures/PortholeRemote/gjest-sicilia-liste.cellconfiguration.json`, seksjon «Din egen entitet»: `TextArea{ placeholder:"Hva er anledningen i kveld?", submitActionKeypath:"entity.entity.record", submitOnEnter:true }` – P4 har oversett `submitActionKeypath`. Det finnes ingen send-knapp i denne flaten; påstanden om `payload=true` gjelder bare paritetsfila.
- Web: `skeleton-runtime.js:2041–2110` (`renderTextArea`) → `wireFieldInput` (l. 2228–2278) sender `dispatchAction(state, submitKeypath, field.value)` på Cmd/Ctrl+Enter alltid og på ren Enter når `submitOnEnter`. **Rendret**: etter `fill("Bursdag, fire personer")` + Enter ble `onAction("entity.entity.record", "Bursdag, fire personer", trigger "textarea-submit")` kalt (`render_report.json` → `c3.palazzoGjest`).
- Apple: `SkeletonView.swift:3955–3996` – `submitOnEnter` + `submitActionKeypath ?? targetKeypath` → `submitCurrentValue` sender `.string(value)`. `SkeletonReachabilityAudit.swift:406` regner `submitActionKeypath` som gyldig handling.
- Paritetsfila `playwright/skeleton-scenarios/palazzo-communale-web.parity.skeleton.json`: `TextArea{ submitActionKeypath:"palazzo.concierge.ask", submitOnEnter:true }` og `Button{ keypath:"palazzo.concierge.ask", label:"Send spørsmål →", payload:true }`. **Rendret**: knappen gir `onAction("palazzo.concierge.ask", true)`; Enter gir `onAction("palazzo.concierge.ask", "Hvilke retter uten melk?")`. Porthole-vertens `resolveRendererActionPayload` (`porthole-webo.js:9438–9481`) erstatter bare tomme payloads med feltverdi – `true` er ikke tom, så knappen bærer aldri teksten. Palazzo-cellen (`PalazzoCommunaleServiceCell.swift:524–545`) krever streng eller `{query}` → `invalidQuery` for `true`. (Scenariet er dessuten et Playwright-korpus; produksjonssiden `Public/js/palazzo-communale.js:165–171` sender `{query}` korrekt.)

**Kjennelse:** F12.1 **FALLER** (teksten sendes på Enter i begge runtimer; gjenstår: ingen synlig send-affordance og intet tilgjengelig navn på feltet → moderat, WCAG 3.3.2/H6). F17.1 **OMKLASSIFISER til alvorlig**: den synlige knappen gjør ikke det etiketten lover (sender `true`), mens Enter fungerer – ikke blokker, siden formålet kan nås; mobil uten fysisk Enter er verst stilt.

## C4 – 12 Picker med `selectionStateKeypath` = action-keypath (P3 U03, alvorlig)

**Påstand:** Runtime leser `selectionStateKeypath` fra state, finner ingenting → valget vises aldri; Broadcast-listen mangler `selectionActionKeypath`.

**Bevis:**
- JSON: alle 12 Picker har **både** `selectionStateKeypath` og `selectionActionKeypath` satt til samme action (f.eks. `conferenceAdminShell.accessRequests.selectSegment`), `selectionPayloadMode:item_id`, `selectionValueKeypath:id`. Broadcast-List (`panels[3]…content[11]`) har bare `selectionStateKeypath:conferenceBroadcastStudio.selectRecipient`.
- Cellene eksponerer **get-intercept på action-keypathen** som returnerer `{selected: id}`: `ConferenceAccessRequestCell.swift:218–224`, `ConferenceAudienceDiscoveryCell.swift:101–105`. Keypathen er altså lese+skrive i husets design.
- Server-projeksjonen leser den for web: `PortholeBootstrapProjection.swift:117–122` legger `picker.selectionStateKeypath` i readable keypaths (for `List` gjøres det **ikke**, l. 103–108).
- Web runtime: `syncPickerSelectionFromState`/`resolvePickerSelectedIndex` (`skeleton-runtime.js:9465–9535`) godtar `{selected: verdi}`; `submitPickerSelectionChange` (l. 9536–9555) sender til `selectionActionKeypath`. **Rendret** («Access target»-Picker med state slik projeksjonen leverer): uten `{selected}` viser den første option; med `accessRequests.selectSegment:{selected:"seg-b"}` viser den «Segment B»; brukervalg sender `conferenceAdminShell.accessRequests.selectSegment` med `{selected:"seg-c"}`; state-refresh nullstiller ikke lokalt valg (`render_report.json` → `c4`, `out/render/control-tower-picker.png`).
- Apple: `CellPickerView.swift:166–186` sender payload til `selectionStateKeypath` **og** til `selectionActionKeypath`; `hydrateInitialSelection` (l. 236–270) leser `renderData.resolve(selectionStateKeypath)` eller `get` mot cellen. Valget vises og sendes.
- Broadcast-List: web `submitListSelectionChange` (l. 9011–9020) returnerer uten `selectionActionKeypath` → **ingen dispatch på web**; Apple `CellListView.swift:482–496` sender til `selectionStateKeypath` → fungerer. Projeksjonen leser ikke list-`selectionStateKeypath` → valgt rad vises heller ikke på web.

**Kjennelse:** U03 **FALLER** for de 12 Pickerne (valg vises og sendes på begge plattformer). Det som står igjen: (i) Broadcast-listen «Send test til valgt» er **død på web** (omklassifiser til alvorlig, web-spesifikk); (ii) nytt funn panelet overså: på Apple sendes hvert Picker-/List-valg **to ganger** når begge keypaths er like (se E1).

## D Gjennomgang av blokker/alvorlig

| id | rapport | dom | begrunnelse |
|---|---|---|---|
| F-01 | P1 | for hardt – moderat | Manglende målbart mål er et beskrivelses-/prosessgap; ingen bruker får friksjon av det. |
| F-02 | P1 | udokumentert | Nummerering avviker fra inventaret (#36 har faktisk `description`+`discovery.purpose`); for Playwright-fixtures er fravær av formål forventet. |
| F-03 | P1 | udokumentert – trenger rendering med raddata | Web erstatter «Action» med radens `label` som standard (`resolveButtonSpec`, runtime l. 2366–2395); 7 knapper sitter i `flowElementSkeleton` med `keypathKeypath`. Apple-sti ikke verifisert. |
| F-04 | P1 | står | Vault-knapper uten utdata-element bekreftet i JSON (ingen `vault.*`-Text). |
| F-05 | P1 | står | Mønsteret er reelt; runtime har ingen innebygd «kunne ikke lese»-tilstand for lister. |
| F-06 | P1 | omklassifiser – se C2 | Skall-dekket (moderat) for Porthole-flater; alvorlig for /pub, conference_mvp-skall og Idea Task Workspace. |
| F-07 | P1 | for hardt – moderat | Målt: 1,96 MB JSON, 48 statiske elementer + 9 848 i 420 radmaler (ikke «statisk utrullet»); create 20 ms, malt 126 ms med tomt state. Lastetid med data ikke målt. |
| F-1 | P2 | for hardt – moderat | Som P1 F-01. |
| F-2 | P2 | for hardt – moderat | Teknisk purposeDescription er et dokumentasjonsfunn. |
| F-3 | P2 | faller/omklassifiser – se C2 | Egen referanse (l. 3228) viser at conference-flater ikke er produktflater → verktøylinjen med «Butler Chat» er synlig. |
| F-4 | P2 | står (kode-lest av P2, ikke verifisert her) | Plausibelt; ikke renderavhengig. |
| F-5 | P2 | for hardt – moderat | Tetthet/duplisering, ikke feil utfall. |
| F-7 | P2 | står | Policybrudd (nøkkelfelt i planleggingsflate) uavhengig av rendering. |
| U01 | P3 | står | `defaultTabTitle` (runtime l. 8397–8402) bekrefter engelske, avledede fanenavn. |
| U03 | P3 | faller – se C4 | Picker-valg vises og sendes; bare Broadcast-listen er død på web (alvorlig, web). |
| U04 | P3 | står | 129 elementer i én seksjon; strukturelt bekreftet. |
| U06 | P3 | står | Ingen bekreftelsesmekanisme i formatet; destruktive og trygge deler klasse. |
| U10 | P3 | står | Hardkodet demoperson som primærhandling. |
| U12 | P3 | står | Faste payloads uten inndata. |
| U15 | P3 | står | Katalog-public-surface uten `selectionActionKeypath`; scenariet har det (drift bekreftet av P7 F-01). |
| U29 | P3 | for hardt – moderat | Se F-07-måling. |
| U30 | P3 | for mildt per rubrikk – blokker (WCAG A) | Samme Picker som P5 #2; `renderPicker` setter `aria-label` bare når `label` finnes (runtime l. 3116–3129). |
| F12.1 | P4 | faller – se C3 | `submitActionKeypath`+`submitOnEnter` sender teksten; rest: moderat (navn/affordance). |
| F17.1 | P4 | omklassifiser – alvorlig | Knapp sender `true`; Enter fungerer. |
| F14.1 | P4 | omklassifiser – alvorlig (ikke blokker) | 30 «−»/«×»-knapper får `aria-label` = tegnet (runtime l. 2549) → navn uten mening; de 2 «tomme» har `labelKeypath` og får navn fra rad. |
| F7.1/F9.1 | P4 | faller | Butterpop/Kunstnerportefølje-bilder har `altKeypath` (coverAlt/title) eller `alt`/`accessibilityLabel`; data-bundet sti bruker dem (runtime l. 2881–2894). |
| F16.1 | P4 | står – alvorlig | Kallimachos-ikoner uten mening (som P5 #6). |
| F2.2/F3.1 | P4 | står | Som P1 F-04. |
| F14.4 | P4 | står | Blind «Stem første»-payload bekreftet i fixture. |
| F12.2 | P4 | for hardt – moderat | Caption-tekst; listene under viser delte elementer når de finnes. |
| F19.1 | P4 | udokumentert | Flaten er en test-fixture; bekreft at fabrikken produserer samme placeholder før dom. |
| #1 | P5 | står – se C1 | Målt 1,30:1 i `canvas view-mode`. |
| #2 | P5 | står (per rubrikk) | Navnløs `<select>`; anbefaler at briefen skiller WCAG-A-blokker fra stuck-blokker. |
| #3 | P5 | står (per rubrikk) | `aria-label` settes bare for `styleRole:admin-form-field` (runtime l. 2062–2074). |
| #4 | P5 | står | Statisk bilde-sti ignorerer `alt` (runtime l. 2860); data-bundet sti respekterer det (l. 2894) – reell paritetssplitt. |
| #5 | P5 | står (beregnet fra JSON, ikke rendret) | Farger er i fila, ikke tema-avhengige. |
| #6 | P5 | står | Ikon får `aria-label` = SF-navn (runtime l. 2848). |
| X-01 | P6 | står (per rubrikk) | `lang="en"` bekreftet i base/chat_mvp/conference_mvp.leaf. |
| X-02 | P6 | står | Rå feiltekster; ikke renderavhengig. |
| X-03 | P6 | står | `aria-live="polite"` på `<main>` bekreftet i tre leaf-filer. |
| P-06 | P6 | står | Engelsk statustekst i conference-mvp.js bekreftet (l. 238–256 av P6). |
| L-02 | P6 | står (ikke kjørt) | Kodelest av P6. |
| L-03 | P6 | står | `href="#"` ×3 bekreftet (`porthole_login.leaf:651–653`). |
| W-01 | P6 | står – skjerp til konkret flate | Gjelder bare produktflater; Idea Task Workspace har verken skall-krom eller egen vei (blokker-kandidat), Arendalsuka har bunn-nav. |
| A-01 | P6 | står (ikke målt her) | Tall fra CSS-tokens, plausibelt. |
| R-01 | P6 | står | `protected.get("private")` rendrer «private»; ingen `private.leaf` i `Resources/Views`. |
| F-01 | P7 | står | Katalog vs scenario-drift bekreftet (public-surface: Sections vs Tabs). |
| F-02 | P7 | står – reelt manglende | Se C2 (a): ingen lenke ut av `/pub`-skeletonene. |
| F-03 | P7 | for hardt – moderat | Arkitektur-/regelfunn uten målt brukerkonsekvens. |

Opptelling: 49 rader; **står** 30 (hvorav 3 «per rubrikk», 1 skjerpet), **for hardt/omklassifisert** 13 (F-01, F-07, P2 F-1/F-2/F-5, U29, F17.1, F14.1, F12.2, P7 F-03 + C2-splitt F-06/F-3, U03-rest), **faller** 4 (U03, F12.1, F7.1/F9.1, P2 F-3 i sin opprinnelige form), **udokumentert** 3 (F-02, F-03, F19.1), **for mildt** 1 (U30).

## E Der panelet var for mildt (eller overså det åpenbare)

1. **Dobbelt dispatch på Apple.** `CellPickerView.swift:180–186` og `CellListView.swift:494–500` sender payload til `selectionStateKeypath` *og* `selectionActionKeypath` når begge finnes. I control-tower er de identiske for 12 Picker → hvert valg utløser `set` på f.eks. `simulation.setEventType` to ganger. Ingen rapport nevner det. (Web sender én gang – ny paritetssplitt.)
2. **Broadcast «Send test til valgt» er død på web.** P3 noterte manglende `selectionActionKeypath`, men pakket det inn i en falsk premiss (U03). Faktum: web-runtime dispatcher aldri uten `selectionActionKeypath`, og serverprojeksjonen leser ikke list-`selectionStateKeypath` – mottakeren kan verken velges eller vises på web, mens Apple fungerer. Det er «formålet kan ikke nås» på én plattform og burde vært eget alvorlig funn.
3. **Idea Task Workspace er en blokker-kandidat, ikke en betinget observasjon.** Produktflate med skjult krom (`isProductSurfaceConfigurationName`), ingen Co-Pilot/Butler/URL i fabrikken (`ConfigurationCatalogCell.swift:7663 ff.`), og eneste vei tilbake er URL-param `showProductChrome` eller at Co-Pilot sender `portholeUI`. P6 W-01 og P1 F-06 pekte rundt det uten å navngi flaten.
4. **Statisk `Image` ignorerer `alt` på web – og paritetstesten låser feilen inne.** P5 #4 fant renderer-feilen; ingen bemerket at `playwright/skeleton-element-catalog.spec.js` rendrer korpuset i `product-view` (mørk) og asserter `.skeleton-fallback` = `rgb(213,232,238)`: testinfrastrukturen antar conference-/produkt-canvas, akkurat den antakelsen som gir C1.
5. **`/pub`-sidene har null utganger.** P7 F-02 kalte det «ingen synlig vei til egen entitet»; i praksis har `kunstnerportefolje/*.json` ingen `url`/`linkURL` i det hele tatt (ikke engang «Logg inn»), og `innlogget.json` lenker bare til `/butterpop`. For en innlogget flate er det nærmere blokker enn alvorlig etter Book 12.

## Hva jeg ikke fikk rendret/kjørt

- Ingen Swift-server: Porthole-skallet selv (verktøylinje, «Butler Chat»-knapp, chrome-suppresjon) er lest i `porthole-webo.js`, ikke klikket. Server-projeksjonen av `selectionStateKeypath` er lest (`PortholeBootstrapProjection.swift`), ikke kjørt; C4-renderingen matet state manuelt i samme form.
- Apple/Binding er ikke rendret (CellPickerView/CellListView/SkeletonView lest). C1 på Apple (systembakgrunn) er ikke målt.
- C1-rendering med tomt state viser 10/17/9 av 37/44/9 Text; de keypath-bundne tekstene er tomme uten cellestate, men har samme `foregroundColor` og ville fått samme 1,30:1.
- arrangor-B lastetid er målt bare med tomt state (lister tomme → 61 DOM-noder); kostnaden med 16 sesjoner × radmaler er ikke målt.
- P1 F-03 («Action»-etiketter): Apple-sidens oppløsning av radknapp-etiketter er ikke verifisert; web erstatter med radens `label`, men raddataenes feltnavn i `ConferenceAdminShellCell` er ikke sjekket.
- Palazzo-cellens svar på `payload=true` er lest (`invalidQuery`), ikke kjørt; paritetsscenariet er dessuten uten cellekobling (Playwright-korpus).
- P2 F-4, P6 L-02, P6 A-01, P5 #5: ikke uavhengig verifisert (kodelest av rådgiverne; ikke renderavhengige).
