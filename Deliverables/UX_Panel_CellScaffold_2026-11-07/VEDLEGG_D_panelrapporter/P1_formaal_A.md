# P1 — Formålsrådgiver A: Er formålsbeskrivelsen komplett, og er den besvart i flaten?

Dato: 2026-11-07. Omfang: brief §2 lag A (14), B (7), C (8), D (5) og de fem unike scenariene i lag E (5) = 39 flater.
Kilder lest i denne økten (`retrieved`): alle 39 JSON-filer via skript, `ConferenceDemoDashboardConfiguration.swift`,
`docs/Kunstnerportefolje_pub_flate_NO.md`, `ButterpopStudio_Product.md` §Brukerhistorie, `Butterpop_Public_Method_20261030.md`,
`Butterpop_Folgere_20261104.md`, `Documentation/Spillverksted/README.md` + `Runde3.md`, `PDD_spillverksted_2026-10-09/FORMAALSSPEC.md` §1 og §3,
`PDD_tillitspakke-agentflaate_2026-09-08/FORMAALSSPEC.md` §1, Book 12 (`owner-entity-access`), `haven_lessons_register_v0.json` (5 lessons),
`Conference_GUI_Porthole_Design_Guide.md` §Design Principles + §Acceptance Criteria, `ArendalsukaParticipantProgram_UX_Guardrails.md`,
`schema-and-limits.md`, `Kallimachos_Capable_Model_Advisor_Runbook_2026-09-02.md` (overskrifter) og `kallimachos-advisor-demo.spec.js` (første 40 linjer),
fikstur-README-ene (PortholeRemote, AgentTrustPackage/PROVENANCE, ButlerBuiltIn-b4a2779a.md), de fem `*.preview.json`.
Ikke lest: de tidligere UX-gjennomgangene i brief §4 (se «Ikke verifisert»).

## Brief-revisjon

Alle punkter under er `retrieved` i denne økten.

1. **§2 lag C: «A/B = designvarianter» stemmer ikke.** `Sources/App/Cells/ConferenceDemoDashboard/ConferenceDemoDashboardConfiguration.swift:33-61`
   gir seks ulike formål: Arrangør A «saksbord under og etter konferansen», Arrangør B «kjøreplan før konferansen»; Utstiller A «Standvakt»,
   Utstiller B «Oppfølgingsplan»; Partner A «Avtaleregnskap», Partner B «Løfteinnboks». Jeg har derfor vurdert seks flater, ikke tre par.
2. **§2 lag C: formålet for de seks dashbordene står ikke i `Conference_Demo_*.md`.** `grep` etter `arrangor-A|Standvakt|Oppfølgingsplan|Løfteinnboks|Avtaleregnskap`
   i `Documentation/` gir 0 treff; det eneste stedet er Swift-filen over. `Conference_Demo_Story*.md` beskriver katalogflatene (Control Tower, Participant Portal, Sponsor Follow-up).
3. **§2 lag B: `grep -ril kunstnerportef Documentation` gir 0 treff.** Formålsdokumentet er `docs/Kunstnerportefolje_pub_flate_NO.md` (PDD «kunstnerside-som-flate», G1/G1-GUI/G2 godkjent 26.10.2026).
   `Butterpop_Public_Method_20261030.md` dekker bare `butterpop-metoden.json`; `apen-visning`/`innlogget` beskrives i `ButterpopStudio_Product.md` §Brukerhistorie pkt. 6 og i malenes egen `description`.
4. **§2 lag D: «ButlerBuiltIn-b4a2779a.json … nyeste av fire snapshot» er ikke dekket av kilden.** `ButlerBuiltIn-b4a2779a.md` kaller den «the former production version» (commit b4a2779a);
   `pretree.md`/`prewb.md` er fanget 2026-09-19 fra senere greinkommits. Hvilken som er nyest er ikke avgjort; jeg har vurdert b4a2779a som bestilt.
5. **Inventartallene er for lave for stakker i array-form.** `inventory.py` teller bare element-nøkler med dict-verdi; `{"VStack": [ ... ]}` telles ikke. Control Tower: 641 (brief) vs 706 (mitt skript), participant portal 193 vs 225. arrangor-B 9 896 stemmer.
6. **§2 inventory-kolonnen «unlabelled inputs» er feil for Butterpop innlogget (4).** Alle fire har `accessibilityLabel` (f.eks. «Navn på lista»); de mangler *synlig* label, ikke tilgjengelig navn.
7. **§4 `schema-and-limits.md` er bak runtime.** `AudioQueue` og `Visualization` finnes i `Public/js/skeleton-runtime.js:32-34` og brukes i Butterpop, utstiller-A (`kind: chart`), spillverksted og Butler, men står ikke i skjema-listen. Jeg har ikke behandlet dem som oppfunnet.
8. §3 bekreftet: `purpose://project-work.purpose-first`, `purpose://admin.approvals.correspondence`, `purpose://palazzo.family-belonging`, `purpose://palazzo.guest.reachable` finnes ikke i `kb_refs.txt`. Tolkningen holdes åpen som briefen krever.

## Metode

1. Skript `panel/purpose_map.py` (kjørt med `python3 -I`, ligger i panel-mappen, ikke i repoet). Per flate: `name/description/discovery`, elementtelling per type,
   outline toppnivå → nivå 3 (Tabs-paneler, Section-innhold, VStack-barn) med type + `text/label/header/keypath`, duplikate tekster og knappetekster,
   knapper uten `keypath/url/payload`, Text uten `text` og `keypath`, Spacer/Divider-telling, alle List-keypaths, tekster som ligner tom-/feiltilstand,
   visibility-regler (root-scope utenfor List/Grid/Reference), og kandidater til owner-entity-access (Button/Reference med Co-Pilot/entitet/HAVEN/porthole/tilbake i label eller keypath).
   For arrangor-B bare toppnivå + mønstertelling. Rådata: `panel/out/map_{A1,A2,B,C,D,E}.txt`.
2. Kompletthet 0–5: ett poeng per kriterium (hvem, hva, utfall, målbart mål, avgrensning) der det står i `description`/`purposeDescription` eller i det navngitte formålsdokumentet. Kilden er angitt per rad.
3. Besvart: ja = hvert løfte i beskrivelsen har minst ett element; delvis = løfte uten element eller element som motsier beskrivelsen; nei = flaten gjør noe annet.
4. Owner-entity-access (Book 12): «ja» krever et synlig Button/Reference i skeletonet bundet mot egen entitet/Co-Pilot. Shell-garanti utenfor skeletonet er ikke verifisert og teller som «nei (shell ukjent)».
5. Tom-/feiltilstand (lesson `empty-list-must-not-look-like-calm`): sjekket om det finnes element som skiller «ingen» fra «kunne ikke lese».
6. Verifikasjonsgrense: statisk lesing av JSON. Ingen flate er rendret eller kjørt; hva cellene leverer av tom-rader, labelKeypath-verdier eller shell-chrome er ikke sett.

## Formålsmatrise

Kolonner: sti | beskrivelse finnes (hvor) | kompletthet 0–5 (mangler) | besvart | elementer uten uttalt formål (antall + eksempler) | formål uten element | owner-entity-access.
«Mangler»: H=hvem, V=hva, U=utfall, M=målbart mål, A=avgrensning.

### Lag A — katalog-JSON med discovery

| # | Sti | Beskr. | 0–5 (mangler) | Besvart | Elementer uten formål | Formål uten element | Owner-access |
|---|---|---|---|---|---|---|---|
| 1 | `Documentation/ConfigurationCatalog/CellConfiguration.conference.control-tower.json` | ja (JSON) | 2 (U, M, A) — «Organizer-siden … viser hvordan onboarding, programvalg, møter, innsikter og sponsor-signaler samles» | delvis — 11 faner dekker innholdet, men beskrivelsen er demo-utstilling («viser hvordan»), ikke arrangørens oppgave | 7 Button `label:"Action"` i liste-rader (`conferenceAdminShell.dispatchAction`), seksjonen «Demo Flow» (2 knapper «Åpne participant cockpit»/«Åpne demo launcher»), 42 Divider | ingen eksplisitt | nei (shell ukjent) |
| 2 | `…conference.nearby-radar.json` | ja | 3 (U, M) — A: «web and staging remain quiet when capability is absent» | delvis — ingen visibility-gating; overskrifter «Nearby encounters»/«Resolved people» og tre tomme lister vises også uten kapabilitet (bare `nearby.fallback`-tekst) | — | «remain quiet» har ingen gating-mekanisme i skeletonet | nei |
| 3 | `…conference.ownership-diagram.json` | ja | 1 (H, U, M, A) | delvis — dokument + Mermaid rendres; 16 rå state-Text (`document_count`, `entry_doc_id`, `render_count`, `mermaid_block_count`, `heading_count`, `source_path` …) er debug | 16 Text i «Document State» | — | nei |
| 4 | `…conference.participant-chat.json` | ja | 3 (U, M) — A: «uten å late som chat er organizer-owned state» | delvis — «meeting ask» har ingen knapp/felt (12 knapper, ingen om møte; kan ligge i `toolCards`-data, ikke verifisert) | hardkodet demo-Text «Midlertidig trygg demo-handling: foreslå Samir …» + knapp «Foreslå Samir» | «meeting ask» | delvis: «Tilbake til portal» → `addConfiguration` (portal, ikke egen entitet) |
| 5 | `…conference.participant-portal.dashboard.json` | ja | 2 (U, M, A) | ja — faner today/agenda/people/chats/meetings/profile svarer 1:1 på «neste steg, agenda, anbefalte personer, chat, møter, proof/session-verktøy» | 8 Button «Action» (`dispatchAction`) i rader | — | uavklart: «Åpne AI-assistent» → `addConfiguration` (hva som åpnes er ikke verifisert) |
| 6 | `…conference.public-profile.editor.json` | ja | 3 (U svakt, M) — A: «participant-owned slice» | ja — felt-for-felt Picker/TextField/AttachmentField | — (all UI-tekst engelsk; K3) | — | nei |
| 7 | `…conference.public-profile.json` | ja | 3 (U, M) — A: «shows only the fields the participant has selected» | delvis — `imageReference`/`imagePreviewReference` vises som Text (streng), ikke Image; «Demo Flow»-seksjon med «Åpne control tower» på en viewer-flate | «Demo Flow» (2 Text + 2 Button) | bilde | nei («Tilbake til portalen» = portal) |
| 8 | `…conference.public-surface.json` | ja | 3 (U, M) — A: «public-safe» | delvis — 7 CTA-varianter for 2 mål («Gå til registrering» ×2, «Gå til participant portal» ×2, «Fortsett til participant portal», «Start registrering», «Se min agenda først»); «Åpne participant chat» og «Se min agenda først» for anonym besøkende | 3 overtallige CTA + «Åpne participant chat»; Image `name:"Oslo harbor and opera skyline"` uten alt-felt | — | n/a (offentlig) |
| 9 | `…conference.sponsor-follow-up.json` | ja | 2 (H ok, V ok fra `description`; U, M, A) — `purposeDescription` beskriver preview-wrapperen, ikke sponsorens oppgave | delvis — pipeline/consent/unlock/follow-up finnes; 139 Text mot 11 knapper med 4 ulike tekster («Action» ×6, «Refresh inbox» ×2, «Prepare export» ×2) | 6 «Action», 19 Divider, «Unlocked contacts» ×2 | «retention» (ingen handling) | nei |
| 10 | `…mermaid.playground.json` | ja | 2 (H, U, M) — A delvis (webview/native) | ja for render | 26 Text i «Runtime State»/«Last Render» (`cacheEntries`, `maxCacheEntries`, `cacheHits`, `correlationId`, `contentHash`, `engineVersion`, `pngBytesCount` …) | — | nei |
| 11 | `…obsidian-mermaid.staging.json` | ja | 1 (H, U, M, A) — «viser hvordan flere cellereferanser kan brukes» (teknisk demo) | delvis — Vault-knapper uten resultatvisning (se 12); «Contract Notes» med hardkodede id-er og runtime-forbehold som UI-tekst | 26 debug-Text + 5 «Contract Notes»-Text | notatvisning | nei |
| 12 | `…vault.obsidian.json` | ja | 2 (H, U, M) | **nei/delvis** — «Opprett/list notater» har 6 knapper men ingen List/Text som viser notater eller resultat («List notes» uten utdata) | 5 «Contract Notes»-Text (hardkodede id-er, «Hvis cell:///Vault ikke er registrert …») | «list notater», «koblinger» (ingen visning) | nei |
| 13 | `Documentation/ProjectControl/Formaalsdekning_CellConfiguration_2026-08-30.json` | ja | 4 (M) — U: «bestrid en utledet status uten å overskrive den», A: «kan ikke skrives manuelt» | ja — rot-statement/coverageLabel/basis + barn-liste med én knapp | — | — | nei |
| 14 | `Documentation/ProjectControl/Korrespondansegodkjenning_CellConfiguration_2026-08-26.json` | ja | 4 (M) — H «Eieren», U «informert beslutning», A «fra hvilken som helst enhet» | ja — `pendingRequests` med avgjør-knapper | venstre admin-side-rail: «HAVEN»/«Admin»/«Kontrollplan» + 6 + 2 nav-knapper, brødsmule «Godkjenning / Korrespondanse» (3 Text + Spacer), 2 Spacer | — | **ja** («Copilot» → `addConfiguration`) |

### Lag B — publiserte skeletons uten discovery

| # | Sti | Beskr. | 0–5 | Besvart | Elementer uten formål | Formål uten element | Owner-access |
|---|---|---|---|---|---|---|---|
| 15 | `Public/skeletons/butterpop/apen-visning.json` | JSON: teknisk («Data-bundet mal …»); formål i `ButterpopStudio_Product.md` pkt. 6 | 3 fra dok (U, M) — A: «ingen utdragsknapp på lytterflaten» | ja — «Spill sang»/«Spill alle»/«Spill album» via `playQueueKeypath`; tom-tekster «Ingen publiserte sanger ennå.», «Ingen referanser delt ennå.» | 2 Text `""` med `styleClasses:["reference-spacer"]`; «Direct from the studio» (engelsk tagline) | — | n/a (anonym); ingen synlig vei inn til HAVEN/innlogging i skeletonet (grep `porthole|HAVEN` = 0) |
| 16 | `Public/skeletons/butterpop/innlogget.json` | som 15 | 3 fra dok (U, M) | ja — «Kjøp sang», spillelister, referanser, dialog, toast; 6 tom-tekster | 2 Text `""` (reference-spacer); 4 inputs uten synlig label (har `accessibilityLabel`) | «kunne ikke lese»-tilstand (bare «ingen») | **nei** — innlogget flate uten vei til egen entitet/Co-Pilot/Porthole |
| 17 | `Public/skeletons/kunstnerportefolje/butterpop-metoden.json` | JSON: teknisk; `Butterpop_Public_Method` (teknisk) + `Butterpop_Folgere` («Hold deg oppdatert»: e-post, push bare når konfigurert, samtykketekst) | 4 fra dok (M) | ja — TextField + «Følg med e-post», «Varsle meg i nettleseren» gated på `portfolio.follow.pushAvailable`, `follow.status`, `consentText` | Text «Henriks eksempellåter kommer senere.» (plassholder-løfte, vises når `!hasTracks`) | — | delvis: Text «Rediger denne siden ↗» med `linkURLKeypath: portfolio.editorPath` (eier-vei, men Text-lenke, ikke Button) |
| 18 | `Public/skeletons/kunstnerportefolje/forside.json` | JSON: «Eieren kan endre den i Porthole»; `docs/Kunstnerportefolje_pub_flate_NO.md` | 5 — M: pikselavvik 0,00–0,01 % målt; A: bare `portfolio`-referanse, maks 256 KB, ingen skrivehandlinger | ja | — | — | n/a (offentlig); eier redigerer i Porthole (dok) |
| 19 | `Public/skeletons/kunstnerportefolje/skallside.json` | dok (samme) | 5 — A: «navnet, utstillingene og hvem som krediterte … og ingenting annet», noindex | ja — `shell.placeholders` Grid + `shell.exhibitions` | — | — | n/a |
| 20 | `Public/skeletons/kunstnerportefolje/verk.json` | dok | 5 | ja — `works.emptyMessage` bundet (tom-tilstand fra data) | Text «Verk publisert fra HAVEN.» (statisk markedsføring) | — | n/a |
| 21 | `Public/skeletons/kunstnerportefolje/verkside.json` | dok | 5 | ja | — | — | n/a |

### Lag C — ressurs-skeletons i app

| # | Sti | Beskr. | 0–5 | Besvart | Elementer uten formål | Formål uten element | Owner-access |
|---|---|---|---|---|---|---|---|
| 22 | `Sources/App/Resources/ConferenceDemoDashboard/arrangor-A.skeleton.json` | **kun i Swift** (`…Configuration.swift:36`): «saksbord under og etter konferansen: fra innsikt til kildeinnspillet i opprinnelig kontekst, ansvarlig, frist og oppfølging. Syntetiske demodata.» | 3 (U, M) | ja — kø, filtre, `ko.tomUtgave`/`ko.tomtUtvalg` (tom-tilstand som data) | Text «Mockup for rådgiverpanelet, 4. november 2026 …», «Tema: auto», Picker «Demotilstand», «Simulert» ×12, 13 Spacer | — | nei («Tilbake» ×8 er intern kjede) |
| 23 | `…arrangor-B.skeleton.json` | Swift:41 «kjøreplan før konferansen: program, rom og sesjoner med åpne saker» | 3 (U, M) | ja — men 9 896 elementer: 6 407 Text, 1 148 Button, 8 419 visibility-regler; «Simulert» ×251, «Registrert møtt»/«Intensjon (låst før start)»/«Kapasitet» ×16 → tidslinje-rutenettet er statisk utrullet | ~250 «Simulert»-badges, 14 Spacer, samme meta-tekster som 22 | — | nei |
| 24 | `…partner-A.skeleton.json` | Swift:56 «avtaleregnskap: avtalt mot levert, med bevis per post. Standard partnerramme (beslutning 4.11).» | 3 (U, M) | ja — og eneste med full feiltilstand: «Kunne ikke hente» + «Prøv igjen»/«Vis diagnose»/«Hent på nytt» + «Listen under er sist kjente tilstand kl. 09.20» | 23 Text `""` som bare bærer `styleClasses` (CSS-ikon); «Avtaleposter: innholdet er hypotese …» ×4; «Mockup laget av partnerrådgiveren 4.11.2026 …» | — | nei (Button `""` → `konf.partner.nav.tilbake`) |
| 25 | `…partner-B.skeleton.json` | Swift:61 «løfteinnboks under konferansen, med Avtaleregnskapet som standard før og etter» | 3 (U, M) | ja — inneholder også A-listene (13 toppnivå-lister); «Tilbake til standard: Avtaleregnskap» | 29 Text `""` (CSS-ikon), «Foreldet» ×12 | — | nei |
| 26 | `…utstiller-A.skeleton.json` | Swift:46 «Delt sanntidskø for standteamet under konferansen, bygget for telefon.» | 3 (U, M) — H og A tydelige | ja — kø, detalj, notatark med `noter.feil`-liste; `Visualization kind:"chart"` med accessibilityLabel | «Demodata» ×2, «Tema: auto», «Simulert» ×12 | — | nei («← Tilbake» lukker henvendelse) |
| 27 | `…utstiller-B.skeleton.json` | Swift:51 «Plan før, lett notering under og oppfølgingstavle etter» | 3 (U, M) | ja | samme som 26 («Simulert» ×16) | — | nei |
| 28 | `…journey.cellconfiguration.json` | ja (JSON) «Spillbar konferansereise … seks dashbordene i rekkefølge. Syntetiske demodata.» | 3 (U, M) | ja | 7 TextArea-blokker med identisk label og placeholder («Ditt svar»/«Ditt svar» ×2), hver gated av root-scopet `canEdit_*`; Text «DEMOKONFERANSEN 2026 / SAL FJORD» hardkodet | — | nei |
| 29 | `Sources/App/Resources/GameWorkshop/spillverksted.skeleton.v1.json` | **ikke i JSON**; `FORMAALSSPEC.md` §1 (formålstre R, A–H med mål og tester) | 5 — M: «Sverre har laget og publisert minst ett spill» + T-tester | delvis — A (levelPills, «Be pappa se» = A3), B (ask/revise/discard/applyProposal, forhåndsvisning = B2), C (searchTools/selectPurpose/selectTool), D (gamePreview), E1/E2 («Spillene dine», «Angre hit», `versions`) finnes; **F publisering** (erklært fase 3) og **E3 «oppgaver Sverre kan krysse av»** har ingen element (ingen oppgave-liste blant 22 lister) | 14 Spacer; Text «🎮», «🧰» (emoji som ikon); 3 Text `" "` med `styleClasses gw-dot/gw-level-pill` | F1–F3, E3 | **nei** (ingen vei til Co-Pilot/egen entitet; Runde3 nevner at Porthole gir `product-view` bare for konfigurasjoner med `chatHub`-referanse — ikke verifisert) |

### Lag D — testfiksturer som er produktflater

| # | Sti | Beskr. | 0–5 | Besvart | Elementer uten formål | Formål uten element | Owner-access |
|---|---|---|---|---|---|---|---|
| 30 | `Tests/AppTests/Fixtures/PortholeRemote/gjest-sicilia-liste.cellconfiguration.json` | ja (JSON): «Viser huset, din egen entitet og hvem som har innsyn — på samme skjerm.» `discovery.purpose` er fritekst, README-ref er testformål | 4 (M) | ja — 7 seksjoner svarer 1:1 | — | «kunne ikke lese» for `entity.match.pending/expired/shared` (tomme lister = stille) | **ja** (seksjon «Din egen entitet», «Se forespørsler» → `entity.consent.prompt`) |
| 31 | `Tests/AppTests/Fixtures/AgentTrustPackage/skeleton/tillitspakke-for.json` | JSON: bare `purpose://candidate.…root`, tom `description`; FORMAALSSPEC §1 full | JSON 1 / spec 5 | ja — status/summary/digest/approval, flåte-liste, rekkevidde, whitelist, 2 Toggle, «Regenerer»/«Godkjenn pakke», `providerToolsLabel` | — | «rekkevidde-graf» er liste, ikke graf (spec sier «grafen») | nei |
| 32 | `…tillitspakke-etter.json` | som 31 | JSON 1 / spec 5 | ja — `violationsLabel` + liste + kvitteringer, «Stopp flåten», «Snevre inn og godkjenn på nytt» | — | — | nei |
| 33 | `Tests/AppTests/Fixtures/ButlerBuiltIn-b4a2779a.json` | ja (JSON, 60+ ord) | 3 (U, M) — A: «alle sideeffekter krever klikk og scope-godkjenning» | ja (1 040 elementer, 192 knapper) | «−» ×19, «×» ×12 (ikon-knapper uten tekstnavn), «Status» ×9, «Avbryt» ×5, «Feil / work item» ×2, «Mangler som fortsatt må fylles:» ×2 | — | ja (er Co-Pilot) |
| 34 | `playwright/fixtures/kallimachos-advisor-skeleton.json` | **ikke i JSON**; runbook §1 + spec: «answer first, everything else one click away», «KI-figur», «Intern prototype» | 4 (M delvis via spec-asserts) | ja — og eksemplarisk negativ tilstand: «Ingenting ble sendt til modellen. Dette er ikke en modellfeil.», «Dette har jeg ikke i katalogen ennå …» | ~60 label/verdi-rader (Kjøring, Kapabilitetsindeks, Validator, Behandling, Målt kostnad) + «Driftsledger»/«Rådata» = operatør-telemetri på sluttbrukerflate; 9 system-Image uten alt (ikoner ved tekst) | — | nei |

### Lag E — unike Playwright-scenarier

| # | Sti | Beskr. | 0–5 | Besvart | Elementer uten formål | Formål uten element | Owner-access |
|---|---|---|---|---|---|---|---|
| 35 | `playwright/skeleton-scenarios/correspondence-approval.skeleton.json` | nei i fil; preview: «Korrespondanse-godkjenning» → arver #14 | 4 (fra #14) | ja — teller + liste + 2 knapper/rad + «Avgjørelser bokføres …» | — | — | **nei** — scenarioet mangler katalogens «Copilot»-knapp (drift, K1-type) |
| 36 | `…palazzo-communale-web.parity.skeleton.json` | **nei** — «Palazzo Communale Concierge»; ingen formålsbeskrivelse funnet i `Documentation/` | 0 (UI antyder: gjest, spørre før besøk, svar med kilder, «TRYGGHET FØRST») | kan ikke vurderes mot beskrivelse; UI er internt konsistent (3 snarveier «Spør om dette», TextArea, svar-List med `topic: palazzo.concierge.answer`) | «Palazzo Communale» ×2 | — | **ja** («Åpne i HAVEN» → `url:/porthole?configurationName=Co-Pilot%20Chat`) |
| 37 | `…personal-invite-chat.skeleton.json` | preview: «Co-Pilot Chat» → arver #33 | 3 | ja (227 elementer; eldre snapshot 2026-05-21 av #33) | «Kontakt-endepunkt» ×2, «Rydd utkast» ×2, «Skjul» ×2 | — | ja («Til samtale» i «Mer»-fanen) |
| 38 | `…restaurant-guest-shell.famiglia.skeleton.json` | **nei** — «Palazzo Guest Portal»; ingen formålsbeskrivelse funnet | 0 (UI: «Dette er ditt eget rom hos oss … du velger», consent-seksjon) | kan ikke vurderes; UI: 7 seksjoner, 5 TextArea + 3 TextField + Picker + 6 preset-knapper før noe utfall vises | — | — | delvis («Dette er ditt» viser `access.ownerScope`/`keypathMatrix`, men ingen vei til egen entitet/Co-Pilot) |
| 39 | `…trust-packet.skeleton.json` | **nei** — «Trust Packet»; ikke lest formålsdok (se Ikke verifisert) | 0 | kan ikke vurderes; UI: Draft/Boundaries/Receipt/Signature/Purpose Candidates/Perspective Match/Actions, 2 samtykke-Toggle før «Send» | engelske seksjonsoverskrifter m/norsk brødtekst; «Export receipt», «Revoke lokalt» | — | nei |

Oppsummering: beskrivelse finnes i selve JSON-en på 16/39; 7 (lag B) har bare teknisk `description`; 7 (6 dashbord + spillverksted) har formål utenfor filen; 3 (36, 38, 39) har ingen beskrivelse jeg fant.
Målbart mål finnes bare for kunstnerportefølje (pikselparitet) og spillverksted/tillitspakke (via FORMAALSSPEC) — 0/14 i lag A.
Owner-entity-access «ja» i skeletonet: 14, 30, 33, 36, 37 (+ delvis 17, 38). Resten: nei eller shell ukjent.

## Funn

Format: flate | element/sted | funn | prinsipp/husregel | alvorlighet | anbefaling (dagens format) | revisjonsstatus | tverrgående.

### Alvorlig (7)

| ID | Flate | Sted | Funn | Prinsipp/husregel | Anbefaling | Status | Tverr. |
|---|---|---|---|---|---|---|---|
| F-01 | Alle 12 katalog-flater (#1–12) | `discovery.purpose` | `purpose` er fritekst («Conference control tower»), ingen `purposeRefs`, ingen goal; 0/14 i lag A har målbart mål; `interests` i #10 smugler `purposeRef=personal.diagram.mermaid.render` | Book 23 (`haven.goal-definition.v1`), F2 | Sett `discovery.purpose` til purpose://-ref (kandidat om nødvendig) og én goal (metric/baseline/target/timeframe) i `purposeDescription` til feltet finnes | retrieved | ja |
| F-02 | #36, #38, #39 (+ #22–27, #29, #34 har formål utenfor filen) | hele filen | Ingen formålsbeskrivelse finnes i filen; for 36/38/39 fant jeg heller ingen i `Documentation/`. En reviewer kan ikke vurdere «besvart» | F2, «Alle elementer må ha et formål» forutsetter et formål å måle mot | Krev `description` + `discovery` i hver skeleton-fil som rendres (også scenarier/fixtures som er produktflater), eller en sidefil med samme navn | retrieved | ja |
| F-03 | #1 Control Tower, #5 Participant Portal, #9 Sponsor | List-rader: Button `label:"Action"` ×7/×8/×6 → `…dispatchAction` | Knappeteksten forklarer ikke handlingen; raden må leses for å gjette | Nielsen H6 (gjenkjenning), designguide-akseptanse «Every action is explainable by its label and surrounding section» | Bruk `labelKeypath` (brukes alt i arrangor-A: `"label":"", "labelKeypath":"label"`) eller cellens handlingsnavn i label | retrieved | ja |
| F-04 | #12 Vault, #11 Staging | «Vault Actions» 6 knapper | Formålet «Opprett/list notater og koblinger» har ingen visning av notater eller resultat; «List notes» uten utdata. Eneste «respons» er en forklarende Text om at knappene «ikke får …» hvis cellen mangler | Formål uten element; H1 synlighet av systemstatus | Legg til `List keypath` mot vault-state og en status-Text; fjern «Contract Notes» med hardkodede id-er fra brukerflaten | retrieved | nei |
| F-05 | #1–9, #13, #30, #31–32, #38, #39 | alle List (f.eks. #1: 42 lister, #30: `entity.match.pending/expired/shared`, #13: `coverage.children`) | Ingen element skiller «ingen rader» fra «kunne ikke lese». En tom liste ser rolig ut. Unntak som gjør det riktig: #24/#25 («Kunne ikke hente» + «Prøv igjen»/«Vis diagnose» + «sist kjente tilstand kl. 09.20»), #34 («Ingenting ble sendt til modellen. Dette er ikke en modellfeil.»), #22 (`ko.tomUtgave`), #29 (`emptyText`, `emptyCards`), #20 (`works.emptyMessage`) | lesson `empty-list-must-not-look-like-calm`, `empty-list-keeps-its-slot` | Én status-Text per kilde bundet til cellestate (`read/unreadable/not-configured` + grunn), eller en rad i listen som cellen leverer; partner-mønsteret er malen | retrieved | ja |
| F-06 | #16 Butterpop innlogget, #29 Spillverksted, #22–28, #31–32, #34, #38, #39, #1–3, #9–13 | hele skeletonet | Ingen synlig Button/Reference mot egen entitet/Co-Pilot. #16 er en *innlogget* flate; #29 er et barns arbeidsbenk. Shell-garanti er ikke erklært noe sted jeg har lest | Book 12 `purpose://skeleton.owner-entity-access` / `goal.skeleton.owner-entity-access` | Én Button («Min HAVEN»/«Co-Pilot») med `url:/porthole?configurationName=Co-Pilot%20Chat` slik #36 gjør, eller `addConfiguration` slik #14 gjør; ellers skriv shell-garantien inn i SkeletonReachabilityAudit | retrieved | ja |
| F-07 | #23 arrangor-B | hele filen | 9 896 elementer (6 407 Text, 1 148 Button, 8 419 visibility-regler); «Simulert» ×251 og tre etiketter ×16 viser at et 16-sesjons rutenett er rullet ut statisk i stedet for List/Grid-rader. Formålet (kjøreplan) er dekket, men ~95 % av elementene er gjentakelser | pkg.std.gui-surface «laster ≤ 5 s» (ikke målt), lesson `text-ux-is-not-design`, vedlikehold | Flytt sesjons-/tidslinjeceller til `List`/`Grid` med `flowElementSkeleton` og la cellen levere radene; mål lastetid før/etter | retrieved | nei |

### Moderat (13)

| ID | Flate | Sted | Funn | Prinsipp/husregel | Anbefaling | Status | Tverr. |
|---|---|---|---|---|---|---|---|
| F-08 | #22–27 | fil vs Swift | Formålet står bare i `ConferenceDemoDashboardConfiguration.swift:33-61`; JSON-en har ikke `name/description/discovery`. Den som åpner skeletonet ser ikke hvilket av seks formål den tjener | F2, Book 23 | Skriv `description`/`discovery` i hver `*.skeleton.json` eller generer dem fra Swift i samme bygg | retrieved | ja |
| F-09 | #9 Sponsor | `purposeDescription` | Beskriver preview-wrapperen («so Porthole, web preview, and Binding review can stay on the same skeleton»), ikke sponsorens oppgave; «retention» i `description` har ingen handling | F2 hvem/hva/utfall | Skriv sponsorens formål («sponsoren plukker opp handoff-leads, kvalifiserer, låser opp med samtykke, følger opp») og la wrapper-teksten stå i `description` | retrieved | nei |
| F-10 | #3, #10, #11 | «Document State»/«Runtime State»/«Last Render» | 16/26/26 rå state-Text (cache, hash, correlationId, engineVersion, pngBytesCount, entry_doc_id) uten uttalt formål i beskrivelsen = debugpanel i produktflate | H8 minimalisme, designguide «low text density», lesson `text-ux-is-not-design` | Behold `status`, `lastError`, `warnings/errors`; flytt resten til egen seksjon gated på en `visibility`-regel mot cellestate (f.eks. `debug.enabled`) | retrieved | ja |
| F-11 | #7 Public Profile | «Demo Flow»-seksjon; `profile.imageReference` | Viewer-flate har «Åpne control tower» (arrangørinngang) og viser bildereferansen som Text-streng, ikke Image | H2 match til virkeligheten, designguide «Image Field» | Fjern Demo Flow fra viewer-kortet (eller gate på demo-state); bruk `Image` med `urlKeypath` | retrieved | nei |
| F-12 | #8 Public Surface | 9 knapper | 7 CTA-tekster for 2 destinasjoner; «Åpne participant chat»/«Se min agenda først» for anonym besøkende | H4 konsistens, Hick | Én tekst per destinasjon; chat/agenda bare etter registrering (gate eller fjern) | retrieved | nei |
| F-13 | #4 Participant Chat | knapper | «meeting ask» i formålet har ingen knapp/felt; demo-tekst «Midlertidig trygg demo-handling: foreslå Samir» er hardkodet i produktflaten | Formål uten element; H2 | Legg til «Be om møte»-knapp mot ConferenceChatLaunch hvis handlingen finnes, ellers stryk løftet; flytt demo-tekst til demo-state | retrieved | nei |
| F-14 | #2 Nearby Radar | tre seksjoner | Formål lover «remain quiet when capability is absent»; skeletonet har ingen `visibility`-regel; overskrifter og tomme lister vises alltid | designguide «Nearby is invisible when unsupported», «Do not show capability-specific UI where the host cannot support it» | `visibility.when` på seksjonene mot `discovery.nearby.capabilityAvailable` (eller tilsvarende felt cellen faktisk har — verifiser i Explore først) | retrieved | nei |
| F-15 | #35 vs #14 | hele filen | Scenario-kopien av Korrespondanse-godkjenning (29 el.) mangler katalogens Copilot-knapp og admin-ramme (72 el.); samme navn, to flater | K1 drift, Book 35 paritet | Avgjør hvilken som er sann; la scenariet lese katalogfilen | retrieved | ja |
| F-16 | #24, #25 (+ #15/16, #29) | 23/29 Text `"text":""` med bare `styleClasses` | Tomme Text brukt som CSS-ikon/indikator («k = gap/levert/venter»). Uten tema er tilstanden usynlig; skjermleser får ingenting | K2, lesson `text-ux-is-not-design`, WCAG 1.1.1 | Bruk Text med kort ord («Levert», «Venter») + styleClasses, eller `Image name` med `accessibilityLabel` | retrieved | ja |
| F-17 | #29 Spillverksted | faner | E3 «oppgaver Sverre kan krysse av» har ingen liste; F publisering/godkjenning har ingen element (erklært fase 3 i FORMAALSSPEC) | Formål uten element (spec §1 E3, F1–F3) | Legg til oppgaveliste (WorkItem) i «Prosjekt»-fanen; marker F som «kommer» i STATUS, ikke i flaten | retrieved | nei |
| F-18 | #33 Co-Pilot Chat (og #37) | 31 ikon-knapper «−»/«×» | Knapper uten tekstlig navn; «Status» ×9 som overskrift | WCAG 2.4.6/4.1.2, H6 | `label` «Minimer»/«Lukk» (kan være kjent fra 2026-06-13-review; ikke sjekket) | retrieved | ja |
| F-19 | #38 Restaurant Guest Shell | seksjon 3–4 | 5 TextArea + 3 TextField + Picker + 6 preset-knapper før gjesten ser noe utfall; ingen beskrivelse å måle byrden mot | H8, F2 | Skriv formål + utfall; reduser til det «Planen for kvelden» faktisk bruker | retrieved | nei |
| F-20 | #30 Palazzo Gjest | `discovery.purpose` | Fritekst «Gjestens egen oversikt»; README-refen (`candidate.palazzo-porthole-fjernt-scaffold.reference-rewrite`) er testens formål, ikke flatens | F2, Book 23 | Sett `purposeRefs` (f.eks. de `palazzo.guest.*`-refene som brukes i #13 — men de finnes ikke i KB; avklar først) | retrieved | nei |

### Lav (7)

| ID | Flate | Sted | Funn | Prinsipp/husregel | Anbefaling | Status | Tverr. |
|---|---|---|---|---|---|---|---|
| F-21 | #14 Korrespondanse | venstre kolonne | Admin-side-rail (8 nav-knapper) + brødsmule inne i skeletonet; tjener ikke flatens formål | designguide «Prefer Tabs over desktop-only side rails» | La shell/Tabs bære navigasjon | retrieved | nei |
| F-22 | #22–27 | fotnoter/hode | «Mockup for rådgiverpanelet, 4. november 2026 …», «Mockup laget av partnerrådgiveren 4.11.2026 …», «Tema: auto», «Demodata», Picker «Demotilstand» | H8; «hvert element et formål» | Gate på demo-state eller flytt til `description` | retrieved | ja |
| F-23 | #28 Journey | 7 TextArea-blokker | Label og placeholder identiske («Ditt svar»/«Ditt svar»), 7 root-scopede `canEdit_*`-regler | H8; lesson `unresolvable-condition-is-invisible` (gjelder Binding-renderer; web ikke verifisert) | Én TextArea med `placeholderKeypath`/label fra state, eller gating inne i en List-rad | retrieved | nei |
| F-24 | #39, #6, #1–#12 | overskrifter | Engelske seksjonsnavn («Draft», «Boundaries», «Receipt», «Signature», «Actions», «Profile Basics») med norsk brødtekst; #6 helt engelsk | K3, H4 | Ett språk per flate, samme som formålsbeskrivelsen | retrieved | ja |
| F-25 | #17 Butterpop Metoden | Text «Henriks eksempellåter kommer senere.» | Plassholder-løfte i publisert flate (vises når `!hasTracks`) | lesson `placeholder-example-leaks-into-judgement`, H2 | Erstatt med nøytral tom-tekst eller skjul seksjonen | retrieved | nei |
| F-26 | #16 Butterpop innlogget | 4 TextField/TextArea | Kun `accessibilityLabel`, ingen synlig label («Navn på lista», «Artist» …) | WCAG 3.3.2 | Synlig Text-label over feltet | retrieved | nei |
| F-27 | #34 Kallimachos | paneler Kjøring/Kapabilitetsindeks/Validator + «Driftsledger»/«Rådata» | Operatør-telemetri på sluttbrukerflate; formålet dekker «one click away», men hvem-spørsmålet (bruker vs operatør) er ikke avgrenset | F2 avgrensning, H8 | Skriv avgrensningen; gate operatørpaneler | retrieved | nei |

### Observasjon (4)

| ID | Flate | Funn | Status |
|---|---|---|---|
| F-28 | #13, #14, #30 | Purpose-refs utenfor KB (`project-work.purpose-first`, `admin.approvals.correspondence`, `palazzo.*`). Tolkning åpen (feil vs KB-etterslep); ikke avgjort her | retrieved |
| F-29 | #18–21 Kunstnerportefølje | God praksis: eneste flatesett med målbart mål (pikselparitet), eksplisitt avgrensning («og ingenting annet», bare `portfolio`), tom-tekst fra data. Kan være mal for formålsbeskrivelse | retrieved |
| F-30 | inventory.py | Teller ikke stakker i array-form; elementtall i brief er for lave (se Brief-revisjon 5) | retrieved |
| F-31 | #24/#25, #34 | God praksis for F-05: eksplisitt «kunne ikke hente»-tilstand med handling, og «ikke en modellfeil»-forklaring | retrieved |

Antall: blokker 0 · alvorlig 7 · moderat 13 · lav 7 · observasjon 4 = 31.

## Tverrgående regler for skill

1. **Formålet reiser med filen.** Hver skeleton/CellConfiguration som rendres i produksjon (også fixtures og scenarier som er produktflater) har `description` + `discovery.purpose` (purpose://-ref, kandidat om nødvendig) + `purposeDescription`. Formål som bare finnes i Swift eller i en .md er ikke lesbart for den som åpner JSON-en. (F-01, F-02, F-08)
2. **Fem spørsmål i hver formålsbeskrivelse:** hvem (rolle), hva (handling/innhold), utfall (hva brukeren har etterpå), målbart mål (goal med metric/target), avgrensning (hva flaten ikke gjør). Kunstnerportefølje-dokumentet er malen. (F-01, F-09, F-27)
3. **Ingen generisk knappetekst.** «Action», «Åpne», «−», «×» uten tekstnavn er forbudt; bruk `labelKeypath` eller spesifikk label. Test: hver knapp må kunne forklares av label + seksjonsoverskrift alene. (F-03, F-18)
4. **Tre tilstander per List:** rader / «ingen» (erklært fravær) / «kunne ikke lese» (ukjent fravær med grunn). Modelleres som data fra cellen eller en status-Text per kilde; partner-A-mønsteret («Kunne ikke hente» + «Prøv igjen» + «sist kjente tilstand kl. …») er referansen. (F-05)
5. **Debug og demo gates.** Cache-tall, hash, correlationId, engineVersion, «Tema: auto», «Demotilstand», mockup-fotnoter og hardkodede id-er står ikke i brukerflaten uten `visibility`-gating mot en eksplisitt state. (F-10, F-13, F-22)
6. **Owner-entity-access er et element, ikke en antagelse.** Hver produksjonsflate som ikke selv er Co-Pilot har én synlig Button/Reference til egen entitet/Co-Pilot (`url:/porthole?configurationName=Co-Pilot%20Chat` eller `addConfiguration`), eller shell-garantien står skrevet i reachability-auditen. (F-06)
7. **Tom Text er ikke et element.** `"text":""`, `" "` eller emoji som ikon/CSS-krok bryter «hvert element et formål»; bruk tekst med mening eller `Image` med `accessibilityLabel`. (F-16, F-17 Spacer/emoji)
8. **Gjentakelser er rader.** Et mønster som gjentas >3 ganger med ulike data hører i `List`/`Grid` med `flowElementSkeleton`, ikke utrullet statisk. (F-07)
9. **Ett språk per flate**, og samme språk i formålsbeskrivelse og UI. (F-24)

## Ikke verifisert

- Ingen flate er rendret eller kjørt. Hva cellene leverer (tom-rader, `labelKeypath`-verdier, `nearby.fallback`, `toolCards` med «meeting ask»), og hva Porthole-shellen legger rundt (Co-Pilot-knapp, bibliotek), er ikke sett. F-05, F-06, F-13 og F-14 kan derfor være dekket utenfor skeletonet.
- Hva `addConfiguration` åpner for «Åpne AI-assistent» (#5) og «Copilot» (#14) — payload ikke lest.
- Om root-scopede `visibility`-regler (Butterpop 26/50, Kallimachos 156, Journey 7, Korrespondanse 1) faktisk løses i web-runtime; lesson `unresolvable-condition-is-invisible` gjelder Binding-rendereren.
- Formålsdokumenter for #36 Palazzo Communale Concierge, #38 Palazzo Guest Portal og #39 Trust Packet: ikke funnet i `Documentation/` med grep; kan ligge i CellProtocolDocuments/Deliverables eller PalazzoScaffold. `CoPilot_HAVEN_Onboarding_Privacy_Architecture_2026-07-13.md` nevner trust-packet-skjemaet, men er ikke lest.
- De tidligere UX-gjennomgangene i brief §4 er ikke lest; F-18 (Co-Pilot ikon-knapper) kan være kjent.
- Public Profile Editor (#6): bare de første 4 av 6 seksjoner lest i detalj; de 11 knappene er ikke enkeltvis vurdert.
- arrangor-B: kun toppnivå + mønstertelling; nivå 2–3 ikke lest.
- Lastetid (≤ 5 s) for arrangor-B og Butler er ikke målt.
- `Conference_Demo_Story.md` Act 1–4 er ikke lest linje for linje; bare §Purpose, §Principles og §Canonical Surfaces.
- Hvilket av de fire Butler-snapshotene som er nyest (brief-revisjon 4).
