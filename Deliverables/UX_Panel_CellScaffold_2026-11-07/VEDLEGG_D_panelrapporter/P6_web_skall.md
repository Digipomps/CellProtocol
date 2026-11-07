# P6 – Web-/Porthole-skall: UX, visuell design og tilgjengelighet

Rolle: web-/Porthole-skallekspert. Omfang: håndskrevne web-flater (`Resources/Views/*.leaf`, `Public/js`, `Public/css`, `Public/styles`, `Public/scripts`) og skallet rundt skeleton-flatene. Skeleton-JSON er ikke vurdert her. Alle stier er relative til `<HAVEN_ROOT>/CellScaffold` (HEAD `39c5d8b`, retrieved). Alle funn under er `retrieved` med mindre annet står.

## Brief-revisjon

1. **Lag G mangler i inventaret.** `panel/inventory.md` har 0 rader som nevner `leaf` (retrieved: `grep -c leaf` = 0). Mål F1 («100 % av flatene i inventaret») kan derfor ikke innfris for web-flatene via inventory.py; denne rapporten leverer en egen statusmatrise (§ «Funn» og § «Rester») for alle 27 maler + 4 Swift-rendrede HTML-sider.
2. **HTML-flater rendret fra Swift-strenger er ikke i briefen:** `Sources/App/Controllers/IdentityLinkPageHTML.swift` (`/identity-link`, `VaporIdentityLink.swift:92`), `InviteLandingHTML` (`VaporInviteLanding.swift:328`), `PersonalCopilotCollaborationInviteHTML` (`VaporPersonalCopilot.swift:936`). Identity-link er vurdert under; de to andre er ikke.
3. **`Public/js/haven-localization.js` er ikke «språkbytte».** Filen er en generert 5-linjers bundle (intl-messageformat + skeleton-/katalogvalidatorer, `haven-localization.js:1-2`). Porthole har ingen bruker-synlig språkvelger; locale avledes av `navigator.languages` (`porthole-webo.js:8515-8517`). Oppdragets formulering bør rettes.
4. **Tall i briefen stemmer:** HEAD 39c5d8b; 27 `.leaf`; `porthole-webo.js` 10 967, `porthole-webo.css` 6 679, `skeleton-runtime.js` 10 116, `porthole_login.leaf` 659, `butterpop_studio.leaf` 468, `docs_workbench.leaf` 329 linjer. `Public/css/themes/` har 22 `.css` + en mappe `palazzo/` (fonter/logoer), så «22 temaer» er riktig.
5. **Verktøy-fallgruve:** `ai_usage.leaf` og `ai_usage_admin.leaf` er én linje uten linjeskift (`wc -l` = 0, men 1 663/2 152 byte). Linjebaserte inventar vil telle dem som tomme.
6. **Tidligere gjennomgang 2026-07-14 (`Porthole_Toolbar_Menu_Design_Evaluation`) sier «implementert 2026-07-16».** Retrieved: kjerneleveransene finnes (lang=nb, egen `role="status"`-region, `Verktøy`, `Mer`, `Vis alle N`, reduced-motion for kantmenyer, Playwright-spec 5 tester). Men P1 «konsekvent språk» er bare delvis gjennomført (se funn W-07) og P2 «rå sesjons-ID i detaljer» står fortsatt (`porthole-webo.js:5485-5487`). Briefen bør ikke lese dokumentets status som «lukket».

## Metode

- `grep -n`/`sed -n` på struktur: landemerker, overskrifter, `label for`, `role=`, `aria-*`, `tabindex`, `focus`, `noscript`, `lang`, `innerHTML =`, feilstrenger (`error.message`, `HTTP ${`), lekkasjeord (`Unavailable|denied|undefined`), CSS-funksjoner (`:root`, `@media`, `focus-visible`, `prefers-reduced-motion`, `prefers-color-scheme`, hex-tellinger).
- Rutenåbarhet: `grep -rn 'render("<navn>"' Sources/App` + `leafName:`-varianter i `SimpleProjectManager`.
- Kontrast beregnet med WCAG-relativ luminans (python, verdier under er eksakte for oppgitte hex; alfa-tekst blandet mot oppgitt bakgrunn).
- Ikke kjørt i nettleser; ingen skjermleser-/tastaturprøve. Alt er kodeinspeksjon.
- Leste kjente funn: `Documentation/Porthole_Toolbar_Menu_Design_Evaluation_2026-07-14.md`, `Documentation/Admin_GUI_Production_Readiness_2026-07-14.md`, `.claude/skills/haven-gui-testing/SKILL.md` (lekkasjeliste: `Unavailable`, `denied`, `undefined`, rå JSON, stale konfigurasjonsnavn, fallback-plassholdere).

## Porthole-skall

**Filer:** `Resources/Views/porthole_webo.leaf` (24), `Public/js/porthole-webo.js`, `Public/css/porthole-webo.css`. Rute: `/browserhead/webo` (`VaporBrowserhead.swift:311`).

**Det som er bra (retrieved):** `lang="nb"` (leaf:2); dedikert `<div id="porthole-status-live" role="status" aria-live="polite">` utenfor app-roten (leaf:22) som fylles av `updateStatusLiveRegion()` (js:5283-5300) med «Feil: …», «Laster …», «Porthole arbeider …»; toolbar med `aria-pressed` for Vis/Rediger, `aria-expanded`/`aria-controls` for Bibliotek/Verktøy/Mer (js:5411-5440); `Verktøy`-panel med lineær oversikt, «Vis/Skjul kantmenyer» og «Vis alle N» (js:5534-5586); menygruppene har norske navn (`menuVisuals`, js:202-209); `role="alertdialog" aria-modal` på «forlat redigering» (js:3081); reduced-motion dekker kantmenyer og drop-targets (css:5720, 5792); `focus-visible` 25 steder; `outline: none` kompenseres med `box-shadow` (css:1116-1121, 1200-1204, 4633-4639); kompakt meny ≤ 980 px; Playwright `porthole-toolbar-menu.spec.js` dekker ARIA/tastatur/390/980 px/reduced-motion.

**Funn (detaljer i §Funn, id W-xx):**
- W-01 Produkt-krom skjules og kan bare hentes tilbake via `?showProductChrome=` (js:139-145) eller en `portholeUI`-forespørsel fra Co-Pilot/handling (js:1381-1450). Ingen synlig brukerkontroll. Brukeren er da avhengig av at skeleton-flaten selv har vei tilbake (Book 12 `purpose://skeleton.owner-entity-access`).
- W-02 Feilmelding rendres som `<p class="error">` uten `role` (js:5455); live-regionen fanger den, men bare når state endres. Rå `error.message`/`HTTP 500: Internal Server Error` kan vises (js:1086, 1249, 9431, 10857).
- W-03 `aria-label="Porthole-verktøylinje"` ligger på en `<div>` uten rolle (js:5399) – ignoreres av AT.
- W-04 Synkstatus-badge er `aria-hidden="true"` og bærer forklaring i `title` (js:5620-5622) – «HTTP fallback», «heartbeat», «websocket» er teknikerspråk (js:5627-5639).
- W-05 Tom tilstand sier «Åpne Library eller be Co-Pilot vise Porthole-verktøyene» (js:8496), mens knappene heter «Bibliotek», «Verktøy» og «Butler Chat» (js:5408, 5418, 5433). Empty-state-laget er `pointer-events: none` (css:1785) – ingen handling i selve tomtilstanden.
- W-06 Navnekollisjon Butler/Co-Pilot: toolbar «Butler Chat» (js:5408), konfigurasjonen heter «Co-Pilot Chat» og mappes om (js:4233), feiltekst «Fant ikke Butler Chat» (js:342), tomtilstand «Co-Pilot» (js:8496), degraderingsbanner «Butler svarer naa med lokale regler, ikke en spraakmodell … for aa faa» – ASCII-erstattede æ/ø/å (js:2646).
- W-07 Språkblanding fortsatt: «Loading…» (leaf:19), «Library» (js:5901, 6283, 6306, 8025), «preview-state» (js:5901, 5925), redigeringspaneler «Components/Elements/Inspector» (js:212-214), «Apply», «Apply route», «Save key», «Apply prompts», «Sync and invoke» (js:6481, 6588, 6620, 6633, 6665, 6621).
- W-08 Rå sesjons-ID i toolbar-detaljer (js:5485-5487) – kjent P2 fra 2026-07-14, ikke flyttet til «Avansert».
- W-09 Ingen `<noscript>`; uten JS står «Porthole / Loading…» for alltid (leaf:17-20).
- W-10 CSS uten token-lag: ingen `:root` i `porthole-webo.css`; 606 hex-literaler; lokale tokens bare for motion/publisher/game-preview (css:5675, 5828, 6318). Bruddpunkter 480/640/720/760/860/980/1100 (css:2657-6531). Dark mode bare for game-preview og purpose-tree (css:6329, 6377).
- W-11 Toolbar-knapper ≈ 28 px høye (padding 6/10, 13 px; css:572-580) – over WCAG 2.5.8 AA (24 px), under 44 px-komfort; kantmeny-ikon 9 px tekst i 44 px knapp (css:5640-5643). Inputs 14 px (css:1110) gir iOS-autozoom.

## Innlogging/identitet

**`porthole_login.leaf` (659) + `porthole-login.js` (690), ruter `/` og `/login` (`routes.swift:141-160`), utvider `base.leaf`.**

Bra: tydelig primærvalg («Fortsett med passkey») og sekundære faner; `label for` på alle felt (leaf:531-629); `role="status"` + `role="alert"` (leaf:523-528); `autocomplete="username webauthn"`; eksplisitte feiltekster for avbrutt passkey og ventende forespørsel (js:622-627); `:focus-visible`-utheving (leaf:233-238); `next`-parameter validert mot åpne redirects (js:314-320, `safePostLoginPath` server-side).

Funn:
- L-01 **`base.leaf:2` har `lang="en"`** mens alt innhold er norsk → WCAG 3.1.1 (A). Rutetittel «Sign in» (`routes.swift:160`) vs «Open Porthole» (149) – engelske titler på norsk side.
- L-02 **Ingen `<form>`; alle knapper er `type="button"` og bare `click` lyttes på** (js:21-45; ingen `keydown`/`submit`). Enter i passordfeltet gjør ingenting (H7, forventet nettleseratferd). Uten JS er siden død (ingen `<noscript>`), og status viser «Sjekker session...» (leaf:525) for alltid.
- L-03 **Bunnlenkene «Personvern», «Vilkår», «Hjelp» har `href="#"`** (leaf:651-653) selv om `/privacy/haven` finnes (`routes.swift:230-232`) – døde keypaths (H10, Arendalsuka-guardrail «ingen døde keypaths»).
- L-04 Faner er `role="tab"` men har bare klikk, ingen piltaster (js:349) – APG-mønster halvveis.
- L-05 Registrering med passord har ingen bekreftelse eller «vis passord»; JS leser et `#password-confirm-input` som ikke finnes (js:576, 603), `requireConfirmation` er alltid `false` (js:178, 204) – død kode og svak feilforebygging (H5).
- L-06 Fallback-feiltekst er `error.message` → serverens `reason` eller «HTTP 500: Internal Server Error» (js:628-633, 645) (H9).
- L-07 Kontrast: `--porthole-ink-mute #8c93a3` på hvitt = **3,08:1** ved 10,5 px («Identity Access», «Velkommen»; leaf:11, 131-133, 150-154) – under 4,5:1 (1.4.3 AA). «Identity Access» er dessuten engelsk undertittel.
- L-08 Sjargong: «Sjekker session...», «passkeys/WebAuthn» (js:101, 128), «plattform-passkeys» (leaf:556). Målgruppen er ikke definert noe sted (se formålsvurdering).

**`porthole_identity_unavailable.leaf` + `Public/styles/porthole-identity-unavailable.css` (`VaporBrowserhead.swift:25-100`).** Forbilledlig: `lang` fra Accept-Language, klartekst om hva som skjedde og hva brukeren skal gjøre, referanse-ID, én handling «Prøv igjen», 503 + no-store + CSP, `focus-visible` 3 px, bruddpunkt 360 px. Eneste funn I-01: kicker «Porthole · identity continuity» er hardkodet engelsk også på nb (leaf:16). `--soft #535d70` på `#fffdf8` = 6,52:1 OK.

**`Public/js/identity-link.js` + `IdentityLinkPageHTML.swift` (`/identity-link`).** Norsk, `lang="no"`. Funn I-02: to `<h1>` på samme side (Swift:52, 57) – overskriftshierarki; I-03: feiltekster «Kunne ikke laste: ${error.message}» (js:118, 144, 243) lekker serverspråk.

**`Public/scripts/{signIn,createAccount,base64,utils}.js`:** ikke referert fra noen `.leaf`, `.swift` eller `.html` (retrieved `grep -rn "scripts/signIn"` = 0). `signIn.js:71-76` viser «Unauthorized»/«Something went wrong (NNN)» via `innerHTML`. Rest (se §Rester).

## Admin

**`admin_mvp.leaf` (`/admin/funding`), `admin_catalog.leaf` (`/admin/catalog`), `admin_development.leaf` (`/admin/development`); `/admin` redirigerer til kontrollplan (`VaporAdminMVP.swift:172-205`).**

Bra (bekrefter 2026-07-14-dokumentet): `lang="nb"` på alle tre; felles `<nav aria-label="Adminnavigasjon">` med `aria-current="page"`; `admin-development.leaf` har fullt landemerke-/overskriftshierarki, `role="status"` på lastetekst, fem navngitte tom-tilstander og `<noscript>` (leaf:25-57); `admin-mvp.js` bruker `role="alert"` for feil (js:562, 582, 617, 650) og `role="status"` 7 steder; `admin-theme.css` har `:root`-tokens, `focus-visible`, reduced-motion.

Funn:
- A-01 **`--admin-text-faint` = rgba(204,204,220,.45) → 3,25:1 på `#181b1f`** brukes på informativ tekst i `admin-development.css`: `.empty-lane` (330-336, «Ingen verifiserte kort lastet»), `.privacy-line` (132-136), `.card-meta`, `.purpose-ref`, `.lane-count`, `.source-item small`. Bryter 1.4.3 AA og `lesson.empty-list-must-not-look-like-calm` (tomtilstanden er den svakeste teksten på siden).
- A-02 Tre navn på samme flate: `<h1>CellConfiguration Catalog</h1>` (admin_catalog.leaf:14, engelsk) vs rutetittel «Kontrollplankatalog» (Swift:192) vs nav «Konfigurasjoner» (leaf:17). Tilsvarende `admin_mvp.leaf:20` «Meldingsadgang, brukskvote og finansiering» vs tittel «Lokal brukskvote-administrasjon» vs nav «Brukskvote» (H4).
- A-03 `HTTP ${status}: ${statusText}` + `error.message` som brukertekst (`admin-mvp.js:980, 199-346`; `admin-catalog.js:352, 80-131`; `admin-development.js:427, 454`).
- A-04 `admin_mvp.leaf` og `admin_catalog.leaf` mangler `<noscript>` (bare development har).
- A-05 `porthole_webo.leaf:9` laster `admin-skeleton.css` (mørkt admin-token-sett) globalt i Porthole – blandet tema-grunnlag; ikke verifisert om det lekker visuelt.

## Produktflater i HTML

| Flate | Rute | lang | Formålsdok. | Hovedfunn |
|---|---|---|---|---|
| `butterpop_studio.leaf` + js/css | `/butterpop…` (`VaporButterpopStudio.swift:102`) | `no` | `ButterpopStudio_Product.md` (Formål: PDD-ref, l.20) | P-01 Fanemønster ufullstendig: 4 av 7 `role="tab"` mangler `aria-controls` og panelene `mixes/release/members/quota` mangler `role="tabpanel"`/`aria-labelledby` (leaf:166-173, 176, 205, 341, 369). P-02 Sju `aria-live`-regioner (leaf:47, 68, 104, 119, 124, 209, 251 + arrange-live) → prat-risiko. Ingen `<noscript>`. Bra: `:root`, `focus-visible`, reduced-motion, skjemaer med `label for`, `method="dialog"`. |
| `palazzo_communale.leaf` + js/css | `/palazzo` (`VaporPalazzoCommunale.swift:108`) | `no` | ikke funnet i `Documentation/` (grep «palazzo» = 0 treff på filnavn) | **Forbilde:** skip-lenke (leaf:13), `<form novalidate>` + `role="alert"` (74-84), `role="status"` for tjenestestatus (36), `<noscript>` med alternativ (143), `tabindex="-1"` på svarpanel for fokusflytting (86), norsk klartekst for feil (js:156, 167). Observasjon: `lang="no"` vs husets `nb`. |
| `docs_workbench.leaf` + js/css | `/docs-workbench` (`VaporDocumentationWorkbench.swift:29`) | `en` | ingen (grep «Documentation Workbench» i Documentation = 0) | Utviklerverktøy. P-03 Ingen `focus-visible`/reduced-motion i `docs-workbench.css`; `aria-`/`role` = 0 i js. P-04 Eksempel-plassholdere «Idea, question, unresolved edge case», «Follow up on renderer parity…» (leaf:139, 177) → `lesson.placeholder-example-leaks-into-judgement`. |
| `chat_mvp.leaf` + js | `/chat-mvp` (`VaporChatMVP.swift:96`) | `en` | ingen for malen | P-05 `aria-live="polite"` på hele `<main>` (leaf:15) mens `root.innerHTML` byttes (js:355-412) – mønsteret som ble fjernet fra Porthole i juli. Norsk innhold («Kunne ikke sjekke chat-tilgang», js:508) under `lang="en"` (3.1.1 A). |
| `conference_mvp.leaf` + js | **offentlige** `/events`, `/actors/:slug`, `/publisher-onboarding` m.fl. (`VaporEventPlatform.swift:26-149`, 9 render-kall) | `en` | Conference-docs (dekker skeleton, ikke skallet) | P-06 Engelsk skalltekst for norsk publikum: «Loading skeleton and cell state...» (leaf:30), «Loading conference configuration and state...», «Unable to load conference surface» + rå `error.message`, ingen «prøv igjen» (js:238, 245-250), «Synchronizing preview...»/«Preview ready» (js:256, skjult bare på publisert Arendalsuka). `aria-live` på hele `<main>` (leaf:18). |
| `rag_mvp.leaf` + js/css | `/rag-mvp` | `en` | `RAG_MVP_UI.md` – endepunktliste, ikke formål | Utviklerverktøy; `label for` konsekvent (leaf:30-106); ingen `focus-visible`; feil = `HTTP ${status}: ${detail}` (js:380-381). |
| `lead_vault_harness.leaf` + js | `/lead-vault…` (`VaporLeadVault.swift:42`) | `en` | ingen | Test-harness; `aria-live` på `<main>` (leaf:11); «Running...»/«Idle» (js:85); ingen `:root`/media/focus. |
| `ai_usage.leaf`, `ai_usage_admin.leaf` + `ai-usage.js` | `/ai-usage`, `/admin/ai-usage` (`VaporFirstPartyAI.swift:16-20`) | `nb` | ingen egen | Norsk, `role="status"` (×2), `label` omslutter input. P-07 Lenkerad uten `<nav>` og jargong «Admin: godkjenn topup»; rå `<pre id="ai-output">`. Minifisert enlinjes mal (vedlikehold). |
| `orchestrator.leaf` | `/cells/:cellId/:keypath` GET/POST (`VaporBrowserhead.swift:418, 428`) | mangler | ingen | P-08 Rendres med `resultType` som kontekst, men malen forventer `#(uuid)` (leaf:9); `<body>` er tom, tittel «Cell Page», laster `simpleproject.css` + Tailwind + `orchestrator.js` (legacy websocket-klient). Flate uten formål bak en levende rute. |

## Rester uten formål

| Fil | Nådd fra rute? | Vurdering |
|---|---|---|
| `hello.leaf` | Nei – `routes.swift:234-236` returnerer strengen «Hello, world!» | Ugyldig HTML (`<header>` i stedet for `<head>`, `</html` uåpnet, l.2, 11). Slett. |
| `simpleproject.leaf` + `Public/js/main.js` | Nei (0 treff i `Sources/App`) | «Lorem ipsum», «Click me» (l.17, 39). Slett. |
| `orchestrator2.leaf` | Nei | `#unsafeHTML(skeleton)` (l.17). Slett eller dokumenter. |
| `feedplayerwidgettest.leaf` | Nei (bare `feedplayerwidgettest2` brukes) | «Lorem ipsum». Slett. |
| `feedplayerwidgettest2.leaf`, `feeditemwidgettest.leaf`, `entitymessage/locationmessage/timemessage/simplechatmessage.leaf` | Ja, via `leafName:` i `SimpleProjectManager/*WrapperCell.swift`, `OrchestratorCell.swift`, `ScaffoldOrchestratorCell.swift`, `TestCellWebEmbed.swift` | Legacy widget-fragmenter («Simple Project», «Short description Lorem ipsum», `<a href="/">Logout</a>`). Lever bare om SimpleProjectManager-cellene lever; ingen formålsbeskrivelse funnet. |
| `base.leaf` | Ja, utvides av `porthole_login.leaf` | Har formål, men `lang="en"` (L-01) og Tailwind-bakgrunnsgradient (l.17) er eneste bidrag; vurder å slå sammen med login. |
| `Public/scripts/{signIn,createAccount,base64,utils}.js` | Nei | Erstattet av `porthole-login.js`. Slett. |
| `private` (mal) | **Rute finnes** (`VaporBrowserGatekeeper.swift:33-35` `render("private")`), men `Resources/Views/private.leaf` finnes ikke | Autentisert bruker som treffer `/private` får 500. Fjern ruten eller malen må lages. |
| `Public/css/developer-workbench.css` | Ja, via `@import`/referanse i 8 tema-filer under `Public/css/themes/` og `ConfigurationCatalogCell.swift` | Har formål; ikke rest. |

## Funn

Rubrikk §6: `flate | element/sted | funn | prinsipp/husregel | alvorlighet | anbefaling | revisjon | tverrgående`.

| ID | Flate | Sted | Funn | Prinsipp/husregel | Alvorlighet | Anbefaling | Rev. | Tverrg. |
|---|---|---|---|---|---|---|---|---|
| X-01 | Login, Chat MVP, Conference-skall | `base.leaf:2`, `chat_mvp.leaf:2`, `conference_mvp.leaf:2` | `lang="en"` på sider med norsk innhold (login hele siden; chat/conference feilmeldinger og UI) | WCAG 3.1.1 (A) | **blokker** (A-brudd per rubrikk) | Sett `lang="nb"`; der innhold varierer, sett `lang` per element | retrieved | ja |
| X-02 | Alle web-flater | `porthole-login.js:645`, `porthole-webo.js:10857`, `admin-mvp.js:980`, `admin-catalog.js:352`, `admin-development.js:427`, `conference-mvp.js:796,810`, `lead-vault-harness.js:202`, `rag-mvp.js:381`, `ai-usage.js:25` + `error.message`-visning i 9 filer | Feiltekst til bruker er `HTTP 500: Internal Server Error` eller serverens `reason` | Nielsen H9 (klartekst, årsak, løsning); lekkasjeregel (rå payload) | **alvorlig** | Én felles `userFacingError(error, context)` som mapper status → norsk tekst + handling («Prøv igjen», «Logg inn på nytt»), og legger teknisk detalj i `<details>`/referanse-ID som i `porthole_identity_unavailable` | retrieved | ja |
| X-03 | Chat MVP, Conference-skall, Lead Vault | `chat_mvp.leaf:15`, `conference_mvp.leaf:18`, `lead_vault_harness.leaf:11` | `aria-live="polite"` på hele `<main>` som får `innerHTML` byttet (`chat-mvp.js:355-412`, `conference-mvp.js:235-265`) | WCAG 4.1.3; kjent funn 2026-07-14 (fjernet i Porthole, ikke propagert) | **alvorlig** | Kopier Porthole-mønsteret: egen `sr-only` `role="status"`-region utenfor app-roten | retrieved | ja |
| P-06 | Conference-skall (offentlig) | `conference_mvp.leaf:30`, `conference-mvp.js:238, 245-250, 256` | Engelsk laste-/feil-/statustekst («Loading skeleton and cell state...», «Unable to load conference surface», «Preview ready») for norsk publikum; feil uten gjenopprettingsvei | H1, H2, H9; designguide «task-first, lav tekst-tetthet» | **alvorlig** | Norsk klartekst, «Prøv igjen»-knapp, skjul status-pille på alle publiserte flater (ikke bare Arendalsuka) | retrieved | nei |
| L-02 | Login | `porthole_login.leaf:486-654`, `porthole-login.js:14-52` | Ingen `<form>`/submit; Enter gjør ingenting; ingen `<noscript>`; status «Sjekker session...» uten JS | H7, H1; WCAG 2.1.1 (delvis) | **alvorlig** | Pakk feltene i `<form>` med `type="submit"`; `<noscript>` med forklaring | retrieved | nei |
| L-03 | Login | `porthole_login.leaf:651-653` | «Personvern», «Vilkår», «Hjelp» → `href="#"` | H10; Arendalsuka-guardrail «ingen døde keypaths» | **alvorlig** | Pek til `/privacy/haven` m.fl. eller fjern | retrieved | nei |
| W-01 | Porthole | `porthole-webo.js:139-145, 1381-1450, 5378-5383` | Produkt-krom skjules; kan bare gjenåpnes via URL-param eller Co-Pilot-`portholeUI` – ingen synlig brukerkontroll | Book 12 `purpose://skeleton.owner-entity-access`; H3 brukerkontroll | **alvorlig** (betinget: avhenger av at hver produktflate har egen vei tilbake) | Minimal, alltid-synlig «Porthole»-affordanse (f.eks. tastatursnarvei + liten knapp) eller SkeletonReachabilityAudit som beviser vei tilbake per produktflate | retrieved | ja |
| A-01 | Admin Utviklingsstatus | `admin-development.css:132-136, 330-336, 392-396, 351, 315, 255`; token `admin-theme.css:36` | Informativ tekst (tomtilstand, personvernlinje, meta) i 3,25:1 | WCAG 1.4.3 (AA); `lesson.empty-list-must-not-look-like-calm` | **alvorlig** | Hev `--admin-text-faint` til ≥ 0,6 alfa (≈4,6:1) eller bruk `--admin-text-dim` (5,32:1) for alt som er informasjon | retrieved | ja |
| R-01 | `/private` | `VaporBrowserGatekeeper.swift:33-35` | Rute rendrer `private`-mal som ikke finnes → 500 | H9; ingen døde keypaths | **alvorlig** | Fjern ruten | retrieved | nei |
| P-08 | `orchestrator.leaf` | `VaporBrowserhead.swift:418, 428`; `orchestrator.leaf:9, 19-22` | Levende rute rendrer tom side med feil kontekst | F3 «alle elementer har et formål»; H1 | **moderat** | Fjern rute+mal eller erstatt med JSON-svar | retrieved | nei |
| L-07 | Login | `porthole_login.leaf:11, 131-133, 150-154` | 3,08:1 ved 10,5 px; «Identity Access» engelsk | WCAG 1.4.3; K3 språk | **moderat** | Mørkere mute-farge (≥ `#6b7385`), norsk undertittel | retrieved | nei |
| W-05/W-06 | Porthole | `porthole-webo.js:342, 2646, 4233, 5408, 8496` | Butler vs Co-Pilot vs Library vs Bibliotek i samme skall; ASCII-«naa/spraakmodell/aa» | H2, H4; K3 | **moderat** | Én ordliste (Butler = produktnavn, Co-Pilot = kontraktnavn aldri synlig); rett æøå | retrieved | ja |
| W-07 | Porthole | `porthole_webo.leaf:19`, `porthole-webo.js:212-214, 5901, 5925, 6283, 6306, 6481, 6588, 6620-6666, 8025` | Engelsk/teknisk tekst i visnings- og redigeringsmodus («Loading…», «Library», «preview-state», «Components», «Apply route», «Sync and invoke») | H2; kjent P1 2026-07-14 delvis uløst | **moderat** | Fullfør norske etiketter; byggerverktøy kan ha engelske termer bare bak «Avansert» | retrieved | ja |
| P-01 | Butterpop Studio | `butterpop_studio.leaf:166-173, 176, 205, 341, 369` | Faner uten `aria-controls`, paneler uten `role="tabpanel"` | WCAG 4.1.2; APG Tabs | **moderat** | Gi alle sju faner/paneler id + `aria-controls`/`aria-labelledby`; piltaster | retrieved | nei |
| A-02 | Admin | `admin_catalog.leaf:14`, `VaporAdminMVP.swift:192`, `admin_mvp.leaf:17-20` | Tre ulike navn på samme flate; engelsk `<h1>` | H4 | **moderat** | Ett navn per flate i nav, `<title>` og `<h1>` | retrieved | ja |
| W-02 | Porthole | `porthole-webo.js:5455` | Feil uten `role="alert"`; dekkes bare av live-region ved state-skifte | WCAG 4.1.3 | **moderat** | `role="alert"` på `.error` eller ruting via statusregion med `assertive` | retrieved | nei |
| S-01 | Skeleton-runtime (skall) | `skeleton-runtime.js:2530, 3283` | `title="Navigation target unavailable"`/«Action target unavailable» på deaktiverte knapper | Lekkasjeregel (`Unavailable`); K3 | **moderat** | Norsk tekst som sier hva som mangler («Målet er ikke tilgjengelig i denne flaten ennå») | retrieved | ja |
| X-04 | Alle unntatt Palazzo/Admin-dev | 12 av 14 maler | Ingen `<noscript>`; blanke/evig «Loading»-sider uten JS | H1; robusthet | **moderat** | Felles `<noscript>`-tekst i et base-oppsett | retrieved | ja |
| W-10 | Porthole | `porthole-webo.css` (ingen `:root`; 606 hex; 7 bruddpunkter; dark mode bare 2 blokker) | Mangler token-lag; inkonsistente bruddpunkter | F5 helhetlighet; K2-analog | **moderat** | `:root`-tokens (farge, radius, spacing) + 3 bruddpunkter (480/768/980) delt av alle flater via `admin-theme`-mønsteret | retrieved | ja |
| P-02 | Butterpop Studio | `butterpop_studio.leaf:47, 68, 104, 119, 124, 209, 251` | Sju `aria-live`-regioner | WCAG 4.1.3 (prat) | **lav** | Én statusregion for lister; `aria-live` bare på toast og arrange-live | retrieved | nei |
| W-03 | Porthole | `porthole-webo.js:5399` | `aria-label` på `<div>` uten rolle | ARIA 1.2 (ingen effekt) | **lav** | `role="toolbar"` eller fjern | retrieved | nei |
| W-04 | Porthole | `porthole-webo.js:5620-5639` | Status-badge `aria-hidden` med teknisk `title` | H1, H2 | **lav** | «Live»/«Oppdateres»/«Frakoblet – prøver igjen» uten websocket-språk | retrieved | nei |
| W-08 | Porthole | `porthole-webo.js:5485-5487` | Rå sesjons-ID i detaljer | Kjent P2 2026-07-14 | **lav** | Flytt til «Avansert» | retrieved | nei |
| L-04/L-05 | Login | `porthole-login.js:349, 573-605` | Faner uten piltaster; død bekreftelsesfelt-kode; ingen «vis passord» | APG Tabs; H5 | **lav** | Piltaster; fjern død kode; «vis passord» | retrieved | nei |
| I-01/I-02 | Identity | `porthole_identity_unavailable.leaf:16`; `IdentityLinkPageHTML.swift:52, 57` | Engelsk kicker på nb-side; to `<h1>` | 3.1.2; 1.3.1 | **lav** | Lokaliser kicker; én `<h1>` | retrieved | nei |
| P-04 | Docs Workbench | `docs_workbench.leaf:139, 177` | Eksempel-plassholdere som styrer bruk | `lesson.placeholder-example-leaks-into-judgement` | **lav** | Nøytral hjelpetekst utenfor feltet | retrieved | ja |
| W-11 | Porthole | `porthole-webo.css:572-580, 5640-5643, 1110` | 28 px knapper, 9 px ikontekst, 14 px input | WCAG 2.5.8 (OK), 2.5.5 (ikke), iOS-zoom | **lav** | 36–44 px, ≥ 11 px ikontekst, 16 px input | retrieved | ja |
| X-05 | Palazzo, Butterpop, Identity-link | `palazzo_communale.leaf:2`, `butterpop_studio.leaf:2`, `IdentityLinkPageHTML.swift:14` | `lang="no"` mens resten bruker `nb` | Konsistens | **observasjon** | Standardiser på `nb` | retrieved | ja |
| S-02 | Skeleton-runtime (skall) | `skeleton-runtime.js:8480-8488` | Tom liste gir usynlig `aria-hidden` plassholder; teksten må komme fra flaten | `lesson.empty-list-keeps-its-slot` (oppfylt) vs `empty-list-must-not-look-like-calm` (avhenger av flate) | **observasjon** | Skill-regel: hver flate må levere tomtekst (se regel 4) | retrieved | ja |
| A-05 | Porthole | `porthole_webo.leaf:9` | `admin-skeleton.css` lastes globalt | Tema-hygiene | **observasjon** | Verifiser lekkasje; last per konfigurasjon | retrieved | nei |
| P-07 | AI-bruk | `ai_usage.leaf` (enlinjes) | Lenkerad uten `<nav>`, «topup»-jargong, rå `<pre>` | H2; 1.3.1 | **observasjon** | `<nav aria-label>`; «fyll på kvote» | retrieved | nei |
| — | Palazzo Communale | hele malen | Ingen funn over «observasjon»; forbilde for skallmønster | — | ingen funn | Bruk som referanseimplementasjon | retrieved | — |
| — | Identity unavailable | hele malen | Ingen funn over «lav» | — | ingen funn | Bruk som referanse for feilsider | retrieved | — |

**Telling:** blokker 1 (X-01, tre instanser) · alvorlig 8 (X-02, X-03, P-06, L-02, L-03, W-01, A-01, R-01) · moderat 10 · lav 8 · observasjon 5 · «ingen funn» 2.

**Formålsvurdering (skall-perspektiv, kort):** Dokumentert formål finnes for Porthole-skallet (`Porthole_Toolbar_Menu_Design_Evaluation`, `purpose://gui.quality.functional-accessible`), admin (`Admin_GUI_Production_Readiness`, tre purpose-refs), Butterpop (`ButterpopStudio_Product.md:20`). **Ingen formålsbeskrivelse funnet** for: `porthole_login.leaf` (hvem er brukeren: sluttbruker eller bygger?), `porthole_identity_unavailable` (men teksten selv er formålsklar), `docs_workbench`, `chat_mvp`, `lead_vault_harness`, `rag_mvp` (kun endepunktliste), `ai_usage*`, `palazzo_communale` (ingen `Documentation/*palazzo*`), `orchestrator.leaf`, restene. Skallet i `conference_mvp` er ikke beskrevet separat fra skeleton-formålet.

## Tverrgående regler for skill

1. **Språk er en kontrakt, ikke et tilfeldig attributt.** Hver `.leaf` setter `lang="nb"` (ikke `no`, ikke `en`) når UI-tekst er norsk; `<title>`, rutetittel, `<h1>` og nav-etikett bruker samme navn. Utviklerflater som er engelske skal være engelske hele veien (inkl. plassholdere), ikke blandet. Test: `grep -o '<html lang="[a-z-]*"' Resources/Views/*.leaf` skal gi én verdi per målgruppe.
2. **Feiltekst til bruker er aldri `error.message`, `statusText` eller `HTTP nnn`.** Bruk én delt mapper (status → norsk årsak + neste handling + referanse-ID), og legg teknikk i `<details>`. `porthole_identity_unavailable` er malen. Test: `grep -n 'HTTP \${' Public/js/*.js` skal være tomt utenfor mapperen.
3. **Live-region er en komponent, ikke et attributt på roten.** Aldri `aria-live` på elementet som får `innerHTML` byttet. Én `sr-only` `role="status"` utenfor app-roten (Porthole-mønsteret, `porthole_webo.leaf:22`), `role="alert"` bare på faktiske feil. Maks én `polite`-region per liste-familie.
4. **Tom-tilstand har tekst, handling og full kontrast.** Et tomt skall/list/lane sier hva som mangler og hva brukeren kan gjøre, med minst 4,5:1 og uten `pointer-events: none` over handlingen. Instruksjonen bruker knappenes faktiske etiketter (ikke «Library» når knappen heter «Bibliotek»).
5. **Ingen rute uten mal, ingen mal uten rute, ingen `href="#"`.** Før merge: `grep -rn 'render("' Sources/App` ⟷ `ls Resources/Views`, og `grep -n 'href="#"' Resources/Views`. Avvik er et funn på nivå «alvorlig».
6. **Skjult krom krever bevist vei tilbake.** Enhver flate som undertrykker toolbar/kantmenyer må ha (a) en alltid-synlig affordanse i skallet, eller (b) en SkeletonReachabilityAudit-post som viser at skeletonet selv gir vei til eier/Co-Pilot (Book 12). URL-param og Co-Pilot-kommando teller ikke som brukerkontroll.
7. **Skjema er `<form>`.** Alle innloggings-/innsendingsflater bruker `<form>` + `type="submit"`, `label for`, `autocomplete`, og har `<noscript>` som forklarer at JS trengs. Enter skal alltid sende.
8. **Ett token-lag, tre bruddpunkter.** Nye skall-CSS-filer deklarerer farger/radius/spacing i `:root` (mønster: `admin-theme.css`), bruker `prefers-reduced-motion` og `:focus-visible`, og bruddpunktene 480/768/980 med mindre dokumentert avvik. Hex-literaler i komponentregler er gjeld.
9. **Lekkasjelisten gjelder også `title`, `placeholder` og `aria-label`.** `Unavailable`, `denied`, `undefined`, rå JSON og eksempeltekst som «Idea, question, …» skal ikke finnes i noe attributt sluttbrukeren kan se eller høre.

## Ikke verifisert

- Ingen kjøring i nettleser, skjermleser eller tastatur; alle funn er kodeinspeksjon. Playwright-specs (`porthole-toolbar-menu`, `admin-web`, `palazzo-communale`) er lest etter navn, ikke kjørt.
- W-01: om hver produktflate (Arendalsuka-program/-chat, Co-Pilot Chat, Butterpop) faktisk har egen vei tilbake i skeletonet – det er skeleton-panelets område.
- A-05: om `admin-skeleton.css` lekker visuelt inn i Porthole.
- `InviteLandingHTML` og `PersonalCopilotCollaborationInviteHTML` (Swift-strenger) er ikke vurdert.
- `Public/css/themes/*.css` (22 filer) er ikke lest; filnavn med mellomrom og «·» kan være URL-skjøre, ikke testet.
- Kontrastverdier er beregnet for oppgitte hex/rgba mot oppgitt bakgrunn; faktisk rendret bakgrunn (gradienter, bilder) kan avvike.
- `skeleton-runtime.js` er bare grep-et for skall-strenger; renderer-semantikk (tabs, lister, dialoger i skeleton) er utenfor denne rollen.
- Mobilbredde-oppførsel for `butterpop-studio`, `docs-workbench`, `rag-mvp`, `chat-mvp` er ikke vurdert ut over tellinger av `@media`.
- Om `SimpleProjectManager`-cellene (og dermed `feed*`/`*message.leaf`) fortsatt er aktive i produksjon.
