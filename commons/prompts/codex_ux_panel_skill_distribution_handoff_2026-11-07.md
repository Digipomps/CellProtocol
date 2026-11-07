# Handoff til Codex: distribuer UX-panelets skill og læring (2026-11-07)

Skrevet av Claude (cloud-sesjon, bare skrivetilgang til CellProtocol-branch `claude/jolly-clarke-56hwv7`).
Codex kjører på Mac-en med hele HAVEN-roten og tar distribusjonen. Les hele filen før du gjør noe.
Kjør fra HAVEN-roten:

```bash
/Users/kjetil/.local/bin/codex exec -C /Users/kjetil/Build/Digipomps/HAVEN \
  "Les CellProtocol/commons/prompts/codex_ux_panel_skill_distribution_handoff_2026-11-07.md og utfør slicene som er merket GODKJENT. Rør ikke slicer merket BLOKKERT."
```

## Objektiv

Få UX/GUI/design-panelets regler inn der neste tråd leser dem – Claude Code, Claude Desktop/Cowork
og Codex – uten at Kjetil må forklare dem igjen (haven-learning-capture F0).

## Nåværende tilstand (retrieved 2026-11-07)

- Ny skill i CellProtocol: `commons/skills/haven-ux-surface-review/` (SKILL.md, `references/rules.md`,
  `references/panel-roles.md`, `references/checks.md`, `scripts/surface_inventory.py`).
- Oppdatert i CellProtocol: `commons/skills/cellconfiguration-skeleton-authoring/SKILL.md` (ny seksjon
  «UX-panelets forfatterregler») og `references/schema-and-limits.md` (ny seksjon «Felt og elementer …»).
- Ny Codex-prompt: `commons/prompts/codex_ux_surface_review_prompt.md`.
- Leveranse: `CellProtocol/Deliverables/UX_Panel_CellScaffold_2026-11-07/` (RAPPORT.md + vedlegg).
- CellScaffold `.claude/skills/` er kilden for sync-skriptet; den har en NYERE
  `cellconfiguration-skeleton-authoring` enn commons-kopien. Ikke overskriv den – legg bare til seksjonene.
- `CellScaffold/scripts/haven_learn.py` fantes ikke på `origin/main` 39c5d8b. Finnes den lokalt, bruk den (slice 4).

## Slicer

### Slice 1 – GODKJENT: kopier skillen inn i CellScaffold
```bash
rsync -a --delete CellProtocol/commons/skills/haven-ux-surface-review/ CellScaffold/.claude/skills/haven-ux-surface-review/
```
Kontroller at `SKILL.md` følger `write-a-skill` (frontmatter, `<HAVEN_ROOT>`, Digipomps som godkjenner – den gjør det allerede).

### Slice 2 – GODKJENT: legg de samme to seksjonene til CellScaffolds skeleton-authoring-skill
Append (ikke erstatt) seksjonen «## UX-panelets forfatterregler (lagt til 2026-11-07)» fra
`CellProtocol/commons/skills/cellconfiguration-skeleton-authoring/SKILL.md` til
`CellScaffold/.claude/skills/cellconfiguration-skeleton-authoring/SKILL.md`, og seksjonen
«## Felt og elementer brukt i publiserte flater …» til dens `references/schema-and-limits.md`.
Verifiser først tabellens påstander mot `Public/js/skeleton-runtime.js` og `SkeletonDescription.swift`
(grep feltnavnene); rett rader som er feil og skriv «Last verified against code: <dato>».

### Slice 3 – GODKJENT: utvid haven-gui-testing og haven-panel-task-decomposition
- `CellScaffold/.claude/skills/haven-gui-testing/SKILL.md` → under «Leak Check»: lekkasjelisten gjelder også
  `title`, `placeholder` og `aria-label` (`skeleton-runtime.js` har «Navigation target unavailable»/«Action target
  unavailable» som `title`); legg til sjekk «tom liste har tekst med handling og ≥ 4,5:1».
- `CellScaffold/.claude/skills/haven-panel-task-decomposition/SKILL.md` → under «Related»/«Canonical Sources»: én linje
  «For GUI/UX-gjennomgang av flater, bruk `haven-ux-surface-review` (samme brief-revisjon og to-adjudikator-protokoll,
  pluss obligatorisk formålsrådgiver).»

### Slice 4 – GODKJENT: læringsfangst (hvis `CellScaffold/scripts/haven_learn.py` finnes)
```bash
python3 CellScaffold/scripts/haven_learn.py route --query "ux panel skeleton review"
python3 CellScaffold/scripts/haven_learn.py capture --kind workflow --target skill:haven-ux-surface-review --applied \
  --what "UX/GUI-panel med obligatorisk formålsrådgiver, brief-revisjon og adjudikator B som rendrer offline før dom" \
  --source CellProtocol/Deliverables/UX_Panel_CellScaffold_2026-11-07/RAPPORT.md
python3 CellScaffold/scripts/haven_learn.py capture --kind gap --target skill:cellconfiguration-skeleton-authoring --applied \
  --what "schema-and-limits manglet payloadKeypath/labelKeypath/altKeypath/linkURL/Tabs/Audio/Visualization som publiserte flater bruker" \
  --source CellProtocol/Deliverables/UX_Panel_CellScaffold_2026-11-07/RAPPORT.md
```
Finnes ikke skriptet: skriv de to linjene i `CellScaffold/memory/context-ledger.md` under dagens dato og si det i svaret.

### Slice 5 – GODKJENT: sync til alle konsumenter
```bash
cd CellScaffold
python3 scripts/sync_claude_desktop_skills.py --skill haven-ux-surface-review --skill cellconfiguration-skeleton-authoring \
  --skill haven-gui-testing --skill haven-panel-task-decomposition --include-user --include-codex --build-artifacts --dry-run
```
Les driften. Hvis `~/.claude/skills` eller `~/.codex/skills` har nyere lokale endringer i disse fire, stopp og rapporter.
Ellers kjør samme kommando uten `--dry-run`, og deretter `--check --include-user --include-codex`.
Rapporter de eksakte ZIP-stiene under `Documentation/ClaudeSkills/desktop-zips/` (Kjetil laster dem opp til claude.ai selv – de oppdaterer seg ikke).

### Slice 6 – GODKJENT: oppdater Documentation/ClaudeSkills/README.md og Claude_Skills_and_Codex_Collaboration.md
Legg `haven-ux-surface-review.zip` i bundle-lista og skillen i «Current skills».

### Slice 7 – BLOKKERT (krever Kjetils ja): produktendringer
Ingen av funnene i RAPPORT.md skal rettes i skeletons, Swift, CSS eller Leaf uten eksplisitt godkjenning fra Kjetil
per funn-ID. Dette gjelder også de tre blokker-funnene. Unntak: ingen.

### Slice 8 – BLOKKERT: Book 23
Ukjente purpose://-refs (RAPPORT.md §«Formålsarkitektur») skal ikke legges til eller omdøpes i Book 23 fra denne handoffen.

## Verifisering som forventes i svaret

- `ls CellScaffold/.claude/skills/haven-ux-surface-review/` viser de fem filene.
- `python3 scripts/sync_claude_desktop_skills.py --check --include-user --include-codex` exit 0.
- `git -C CellScaffold status --short` viser bare de berørte filene; ingen commit uten Kjetils ja (haven-git-workflow).
- Liste over ZIP-stier.

## Åpne spørsmål til Kjetil

1. Skal `haven-ux-surface-review` også ligge i `~/.codex/skills` eller holder repo-`.agents/skills`-lenken?
2. Skal reglene A–J i `rules.md` bli husregler (flyttes til Book 12/35) eller forbli panelanbefaling?
