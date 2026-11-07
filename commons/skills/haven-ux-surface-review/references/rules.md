# Regler for HAVEN-flater (fra UX/GUI/design-panelet 2026-11-07)

Hver regel kom fra ett eller flere funn i `Deliverables/UX_Panel_CellScaffold_2026-11-07/RAPPORT.md`
(funn-ID i parentes). Reglene gjelder innenfor dagens skeleton-format; feltene som nevnes finnes i
`SkeletonDescription.swift` eller er verifisert i `Public/js/skeleton-runtime.js` (merket «web»).
Reglene er panelets anbefaling. Digipomps avgjør hvilke som blir husregler.

## A. Formål (Formålsrådgiverens regler)

- **A1 Formålet reiser med filen.** Hver CellConfiguration/skeleton som rendres i produksjon – også fixtures og Playwright-scenarier som er produktflater – har `description`, `discovery.purpose` (purpose://-ref, `candidate.*` om nødvendig) og `purposeDescription`. Formål som bare finnes i Swift eller i en .md er ikke lesbart for den som åpner JSON-en. (P1 F-01/F-02/F-08)
- **A2 Fem spørsmål i hver formålsbeskrivelse:** hvem (rolle), hva (handling/innhold), utfall (hva brukeren har etterpå), målbart mål (goal med metric/terskel eller hendelse), avgrensning (hva flaten ikke gjør). Score 0–5; under 3 er ikke klart for G1. Kunstnerportefølje-dokumentet (`docs/Kunstnerportefolje_pub_flate_NO.md`) er malen. (P1 F-01, P2 F-1)
- **A3 Formålssetningen skrives for brukeren, ikke rendereren.** «rendered from a canonical skeleton so Binding and web can share …» er en kodekommentar, ikke et formål. Test: kan setningen stå som første linje på flaten? (P2 F-2)
- **A4 Hvert synlig element peker til en setning i formålet; hvert løfte har et element.** Før commit: list seksjonstitler/knapper og stryk de uten setning – eller utvid setningen. Alt i `visibleActions` har knapp/radhandling. (P1 F-04, P2 F-4/F-5)
- **A5 Vei inn er del av formålet.** `menuSlots` settes, eller beskrivelsen sier hvor flaten åpnes fra. (P2 F-9)
- **A6 Formålsfelter brukes etter kontrakt.** `purpose`/`purposeRefs[]` for `purpose://`-refs (`purpose://`-prefiks + KB eller `candidate.*`), fritekst i `purposeDescription`, `interests[]` kun for interesser – ingen `purposeRef=…`-strenger der. Ukjente ikke-kandidat-refs samles i én liste til Book 23-vedlikeholder. (P2 F-12, P7 F-14)

## B. Elementer

- **B1 Ingen generisk knappetekst.** «Action», «−», «×», «Show / hide» uten tekstnavn er forbudt. Rad-knapper bruker `labelKeypath` + `payloadKeypath` (web) med norsk fallback-verb i `label`. Test: label + seksjonsoverskrift forklarer handlingen alene. (P1 F-03, P3 U02, P4 F14.1)
- **B2 Tom Text er ikke et element.** `"text":""`, `" "` eller emoji som CSS-krok/ikon bryter «hvert element et formål» og kollapser uten tema. Bruk tekst med mening, eller `Image` med `accessibilityLabel`, og behold alltid tallfallback ved stolper. (P1 F-16, P3 U32)
- **B3 Tekst stylet som knapp er falsk affordans.** `Text` med knappe-/segment-klasser uten handling fjernes eller blir `Button`. `Text`+`linkURL` kun for navigasjon, uten knappe-klasser. `Toggle` for av/på. (P3 U28, P7 F-16, P3 U24)
- **B4 Gjentakelser er rader – og radmaler telles én gang.** Et mønster som gjentas > 3 ganger med ulike data hører i `List`/`Grid` med `flowElementSkeleton`. Mål før du dømmer størrelse: arrangor-B så ut som 9 896 statiske elementer, men er 48 statiske + 420 radmaler (1,96 MB, 126 ms malt med tomt state) – moderat, ikke alvorlig. (P1 F-07, P3 U29, ADJ_B D)
- **B5 Debug og demo bak gates.** Cache-tall, hash, correlationId, engineVersion, «Tema: auto», «Demotilstand», mockup-fotnoter, demo-personer og presentørnotater står ikke i brukerflaten uten `visibility`-gating mot en state cellen eier. (P1 F-10/F-22, P3 U09/U10, P2 F-6/F-8)

## C. Lister og tilstander

- **C1 Tre tilstander per List:** rader / «ingen» (erklært fravær) / «kunne ikke lese» (ukjent fravær med grunn). Cellen leverer én rad med `kind` (`empty`/`unreadable`/`not-configured`) eller flaten har en søsken-`Text` med `visibility` mot tomhet. Statisk ro-tekst («Ingenting er delt ennå») uten binding er en feil. Forbilder: partner-A («Kunne ikke hente» + «Prøv igjen» + «sist kjente tilstand kl. …»), Spillverksted `emptyCards`. (P1 F-05, P3 U20, P4 F12.2, lesson.empty-list-must-not-look-like-calm)
- **C2 Betingelser bor i rader, ikke på rot.** `visibility.when` med `scope:"root"` mot celletilstand bare etter SkeletonReachabilityAudit i begge tilstander på web og Binding (lesson.unresolvable-condition-is-invisible). Standard er `scope:"item"` i rader. (P3 U26)
- **C3 Kopi lover ikke mer enn formatet.** Ingen tekst om Cmd/Ctrl/Shift+Enter, «spillet kjører», «fallback vises» uten at elementet finnes i samme skeleton. Hjelpetekst som forklarer en mulig død ende («hvis cellen ikke er registrert …») erstattes av bundet status-`Text`. (P4 F1.1/F2.3, lesson.sketch-assumed-a-renderer-it-did-not-have)

## D. Handlinger og input

- **D1 Ingen ubundet input.** Et `TextField`/`TextArea` må ha `targetKeypath`, eller `submitActionKeypath` + `submitOnEnter` (gyldig på web og Apple – Palazzo Gjest-mønsteret). En send-knapp ved siden av feltet må bære samme tekst (`payloadKeypath`/`sourceKeypath`), aldri `payload: true` (palazzo-parity: Enter virket, knappen sendte `true` og cellen avviste). Døm aldri «død input» uten å ha rendret eller lest runtime. (P4 F12.1/F17.1, ADJ_B C3)
- **D2 Valg trenger både tilstand og handling, og de må være ulike.** `List`/`Picker` som skal utløse noe har `selectionActionKeypath`; web dispatcher aldri uten (Broadcast-listen i Control Tower er død på web). `selectionStateKeypath` kan peke på en action-keypath bare når cellen har get-intercept som returnerer `{selected}` og server-projeksjonen leser den – men da sender Apple (`CellPickerView`/`CellListView`) til begge og handlingen fyrer to ganger. Regel: eget `.state.`-felt for tilstand, action-keypath for handling, aldri samme verdi. (P3 U03, ADJ_B C4/E1/E2)
- **D3 Farlig verb = to trinn + konsekvens + kvittering.** Godkjenn/avvis/slett/publiser/send-til-alle/betal/stopp/trekk tilbake: egen HStack, egen `styleClasses` (ikke `primary-action`), konsekvenssetning rett over, armed-mønster (to knapper + `visibility` på `isArmed` fra cellen, som Butterpop «Trykk igjen for å slette») eller samtykke-`Toggle` koblet via `visibility`, og bundet resultattekst etterpå. `payload {"confirm":true}` satt av knappen teller ikke. (P3 U06, P4 R4, P2 F-7)
- **D4 Rad-handling bærer sin kontekst.** `Button` i `flowElementSkeleton` som endrer noe har `payloadKeypath` (web); aldri `"$id"`-maler eller implisitt item-kontekst. Skillen oppgir Binding-paritet. (P4 F4.1/F13.3)
- **D5 Ett sted per handling.** Samme handling to steder med ulik dekning («Approve selected» i to faner) læres som «hvilken teller». (P3 U08)

## E. Språk og tekst

- **E1 Ett produktspråk per produkt, og det er brukerens.** Overskrifter, faner, knapper, plassholdere og `purposeDescription` på samme språk (bokmål baseline); engelsk bare i egennavn og `localization`-katalog. Aldri to språk i én setning. (P3 U18, P7 F-04, P2 F-13, P4 F1.5)
- **E2 Verbliste for knapper** (samme handling → samme verb, verb + objekt): Legg til · Opprett · Lagre · Send · Åpne · Vis/Skjul · Oppdater · Fjern (reversibelt) / Slett (varig) · Avvis · Godkjenn · Trekk tilbake (kun samtykke/deling) · Tilbake til <navn>. «Start»/«Send» aldri uten objekt. (P7 F-05/F-18)
- **E3 Internspråk bare bak «Avansert».** `purpose://`, `interest://`, UUID, keypath, cell, skeleton, RAG, proof, capability, endepunkt, hash, «Binding», «runtime», «AttachmentField», «preview», «mock» står ikke i `text`, `label`, `placeholder`, `title` eller `aria-label` i standardvisning. Lint-regex. (P4 R5, P3 U23, P6 S-01)
- **E4 Plassholder er eksempel, ikke etikett, og aldri et eksempel fra casen.** Synlig `Text`-etikett over feltet; nøytrale eksempler (lesson.placeholder-example-leaks-into-judgement). (P3 U31/U34, P1 F-25, P6 P-04)
- **E5 Ett navn per anker.** Co-Pilot Chat / Butler / Copilot er samme ting – ett navn i UI, aliaser bare i kode. Samme regel for `<title>`, `<h1>` og nav-etikett. (P7 F-06, P6 A-02)

## F. Farge, typografi og tema

- **F1 Fargepar, aldri enkeltfarge.** Setter du `foregroundColor`, sett `background` på elementet eller nærmeste forelder (og omvendt). Web-standard for felt/knapp er lys-på-mørk; Apple bruker systemfarge. Ingen `#D5E4ED`-copy-tone utenfor flate med mørk bakgrunn. (P5 #1/#7 – se adjudikator B)
- **F2 Kontrast skal kunne regnes fra JSON-en alene** (≥ 4,5:1 normal, ≥ 3:1 stor/UI) mot nærmeste `background`; kontrastsjekk før commit. (P5 #5/#8/#9)
- **F3 Én stylingstrategi per flate, oppgitt i `description`:** (a) `styleClasses` + `Public/css/themes/<eksakt konfigurasjonsnavn>.css` (foretrukket; gir tokens og mørk modus), (b) `styleVariables` (`accent/ink/paper/line/muted/surface`), eller (c) fast hex-palett ≤ 12 farger fra én fabrikk-`section(...)`. Temafil må finnes for navnet – `syncConfigurationTheme` feiler stille. Tema bør nøkles på stabil id, ikke visningsnavn. (P5 #12, P7 F-03, konflikt K2)
- **F4 Én typografisk skala:** 12 (metadata/eyebrow) · 14 (minste brødtekst) · 16 · 20 · 24 · 32; ingen halvpunkt. Semantisk `fontStyle` i skeleton, numerisk i tema. Tallet er px på web og pt på Apple – paritetsbilder på begge. (P5 #11, P7 F-08)
- **F5 Mørk modus er et valg.** Hex-flater er låst til én modus – si hvilken (`color-scheme` i temaet) og test den; tokenflater har `prefers-color-scheme`-blokk med samme kontrastkrav. (P5 #13)

## G. Tilgjengelighet

- **G1 Hvert `Image` har `alt`** (eller `alt:""` for dekor) eller `altKeypath`; systemikoner ved tekst har meningsbærende `accessibilityLabel` (Kallimachos-ikonene får i dag SF-navnet som aria-label). Kjent renderer-avvik: web **statisk** `Image` leser ikke `alt` (`skeleton-runtime.js` ≈ l. 2860), mens data-bundet sti (l. 2894) gjør det – rett rendereren. Butterpop og Kunstnerportefølje gjør dette riktig (`altKeypath`) og er forbilder. (P5 #4/#6, ADJ_B D)
- **G2 Hvert felt og hver Picker har tilgjengelig navn i JSON:** `Picker.label`, `Toggle.label`, `modifiers.accessibilityLabel` på `TextField/TextArea`. Web gir `aria-label` bare for `admin-form-field` i dag – forfattere kan ikke stole på placeholder. (P5 #2/#3/#10, P3 U30)
- **G3 Tabs har alltid forfattede etiketter.** Uten `tabsKeypath`/tittel gir web `defaultTabTitle(id)` («Overview», «Story») og Apple kapitalisert id – engelsk, renderer-avhengig, ikke oversettbart. Bruk `tabsKeypath` + `labelKeypath` mot en `navigation.tabs`-liste (portalens mønster). (P3 U01)
- **G4 Treffstørrelse.** `Button` med `padding < 6` eller `fontSize < 13` får `minHeight: 24`/`minWidth: 24`; skall-knapper 36–44 px; input ≥ 16 px på mobil. (P5 R7, P6 W-11)
- **G5 Farge er aldri eneste bærer.** Nivåpiller/stolper har tekst eller tall ved siden av. (P4 F11.3, P3 U32)

## H. Navigasjon og struktur

- **H1 Owner-entity-access er et element eller en dokumentert skall-garanti** (Book 12 `purpose://skeleton.owner-entity-access`). Tre tilfeller: (1) Porthole-rendret ikke-produktflate: verktøylinjen gir alltid «Butler Chat» – garantien finnes, men skal stå som `shellProvided` i discovery og i SkeletonReachabilityAudit; (2) produktflate med skjult krom (`isProductSurfaceConfigurationName`) eller flate uten Porthole-skall (`Public/skeletons/**`, `conference_mvp.leaf`-skallet): skeletonet må selv ha én synlig `Button`/`Reference`/`Text`+`linkURL` til egen entitet/Co-Pilot, fast plass øverst til høyre; (3) fixtures uten vert dømmes ikke. URL-parameter (`showProductChrome`) eller Co-Pilot-kommando teller ikke som brukerkontroll. (P1 F-06, P2 F-3, P7 F-02, P6 W-01, ADJ_B C2/E3/E5)
- **H2 Maks én skjerm per panel.** Veiledende ≤ 8 knapper og ≤ 40 elementer per Section/Tab-panel; over det nestede `Tabs`. Primærhandlingen står i første HStack. (P3 U04/U05, P4 F18.3)
- **H3 Detaljer over folden, ingen full liste først, ingen auto-select** (Arendalsuka-guardrails). Terskel for «lang liste» (> 20 rader) skrives inn i designguiden så den ikke motsier guardrails. (P3 U14, P7 F-17)
- **H4 Ingen faste bredder i rader.** `width` på VStack/Picker i HStack er forbudt uten mobil-render; bruk `maxWidthInfinity`. (P3 U22)
- **H5 Skjult krom krever bevist vei tilbake.** Enhver flate som undertrykker toolbar/kantmenyer har en alltid-synlig affordanse i skallet eller en reachability-post som viser at skeletonet selv gir veien. (P6 W-01)

## I. Kilder, paritet og referansebilder

- **I1 Én kilde per flate, deklarert i flaten.** Swift-fabrikk → katalog-JSON er sannheten (paritetstest). Playwright-scenarier eksporteres fra katalogen eller har en test som bare tillater erklært avvik (`drift.json`). Designforslag i et scenario merkes som forslag med dato for landing i fabrikken. (P3 K1, P7 F-01, P1 F-15)
- **I2 Referansebilde i repo.** `pkg.std.gui-surface` er oppfylt bare når det godkjente bildet ligger ved siden av flaten med relativ sti (f.eks. `Documentation/ConfigurationCatalog/images/<navn>-v<n>.png`). Eksterne mockup-mapper og `/Users/...`-lenker teller ikke. (P7 F-12/F-13)
- **I3 schema-and-limits.md speiler runtime.** Referansen lister feltene publiserte flater bruker (`payloadKeypath`, `labelKeypath`, `urlKeypath`, `linkURL`/`linkURLKeypath`, `altKeypath`, `playQueueKeypath`, `backgroundKeypath`, `tabsKeypath`, `Audio`, `AudioQueue`, `Tabs`, `Visualization`) med paritetsstatus per renderer; ellers avviser skillen gyldige mønstre og godtar døde. (P4 R9, P1 brief-revisjon 6)
- **I5 Rendre i alle canvas-klasser.** Porthole gir ulik bakgrunn etter konfigurasjonsnavn (`view-mode` hvit, `product-view`/`conference-view` mørk). Testkorpuset (`skeleton-element-catalog.spec.js`) rendrer bare i mørk `product-view` og låser dermed inne antakelsen som ga C1. Kontrast- og G1-GUI-bilder tas i den klassen flaten faktisk får. (ADJ_B C1/E4)
- **I4 Husreglene avstemmes mot fabrikken.** Designguiden får «sist avstemt mot fabrikk: <dato>»; begreper som ikke finnes i kode («Do it/Dismiss») fjernes eller merkes forslag. (P7 F-07)

## J. Web-skall og Leaf-maler

- **J1 Språk er kontrakt.** `lang="nb"` (ikke `no`/`en`) når UI er norsk; `<title>`, rutetittel, `<h1>` og nav-etikett bruker samme navn. Test: `grep -o '<html lang="[a-z-]*"' Resources/Views/*.leaf`. (P6 X-01/X-05)
- **J2 Feiltekst er aldri `error.message`, `statusText` eller `HTTP nnn`.** Én delt mapper (årsak + neste handling + referanse-ID), teknikk i `<details>`. Mal: `porthole_identity_unavailable.leaf`. Test: `grep -n 'HTTP \${' Public/js/*.js` tomt utenfor mapperen. (P6 X-02)
- **J3 Live-region er en komponent, ikke et rot-attributt.** Aldri `aria-live` på elementet som får `innerHTML` byttet; én `sr-only role="status"` utenfor app-roten (Porthole-mønsteret), `role="alert"` bare på feil. (P6 X-03/W-02/P-02)
- **J4 Skjema er `<form>`** + `type="submit"` + `label for` + `autocomplete` + `<noscript>`; Enter sender alltid. Ingen `href="#"`. (P6 L-02/L-03)
- **J5 Ingen rute uten mal, ingen mal uten rute.** Før merge: `grep -rn 'render("' Sources/App` ⟷ `ls Resources/Views`. Døde maler slettes; generiske verter får navn etter formål. (P6 R-01/P-08, P2 F-16/F-17/F-18)
- **J6 Ett token-lag, tre bruddpunkter.** Skall-CSS deklarerer farger/radius/spacing i `:root` (mønster `admin-theme.css`), har `:focus-visible` og `prefers-reduced-motion`, bruddpunkter 480/768/980. Hex-literaler i komponentregler er gjeld. (P6 W-10)
- **J7 Lekkasjelisten gjelder også `title`, `placeholder` og `aria-label`** («Unavailable», «denied», «undefined», rå JSON, eksempeltekst). Utvid `haven-gui-testing`. (P6 S-01/P-04)
- **J8 Tom-tilstand i skallet har tekst, handling og ≥ 4,5:1**, og bruker knappenes faktiske etiketter («Bibliotek», ikke «Library»). (P6 A-01/W-07)
