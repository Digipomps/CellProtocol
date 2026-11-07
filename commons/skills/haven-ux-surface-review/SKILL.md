---
name: haven-ux-surface-review
description: >-
  Run a UX/GUI/design expert-panel review of HAVEN surfaces (CellConfiguration/skeleton JSON,
  Swift configuration factories, Public/skeletons, Leaf web templates and the Porthole shell)
  in CellScaffold or companion repos. Use when Digipomps asks to "vurder flaten", "gå gjennom
  alle flatene", "UX-panel", "designgjennomgang", "er formålet besvart i flaten", or before a
  G1-GUI/G3 gate on anything visual. Evaluates each surface against recognised UX principles
  (Nielsen, Norman, WCAG 2.2, Hick/Fitts, Gestalt), HAVEN house rules, and — mandatory — a
  purpose-completeness adviser who checks that the purpose description is complete and answered
  by the surface and that every element serves a stated purpose. Produces a dated deliverable
  with a per-surface matrix, severity-ranked findings, brief audit, two-adjudicator rulings and
  cross-cutting rules. Does not change product code; findings go to Digipomps for decision.
---

# HAVEN UX Surface Review (UX/GUI/design-panel)

Use this skill when the user wants to:

- review one, several or all HAVEN surfaces for usability, visual design, accessibility and coherence
- check whether a surface's purpose description (`discovery.purpose`/`purposeDescription`) is complete and whether the surface actually answers it
- verify that every element on a surface has a stated purpose ("alle elementer må ha et formål")
- prepare or evaluate a G1-GUI / G3 gate (Book 35) with more than one pair of eyes
- turn review findings into durable rules in skills and lint checks

Do NOT use it for implementing fixes (use `haven-purpose-driven-dev`), for pure claim
adjudication without GUI (use `haven-panel-task-decomposition`), or for authoring skeletons
(use `cellconfiguration-skeleton-authoring`).

## Core Rules

1. **The panel is a method, not a vote.** Fixed roles with controlled context; disagreement is signal. The human (Digipomps) decides; the panel makes gaps, risk and alternatives visible.
2. **A purpose adviser is mandatory.** At least one panelist does nothing but purpose completeness and answeredness, with the five questions in `references/rules.md` §A, and lists elements without purpose and purposes without element.
3. **Bind the panel to rules, never to facts.** The brief carries audit status per fact (`retrieved`/`recalled`/`unavailable`/`contradicted`). Every panelist opens with `## Brief-revisjon`. A brief error found mid-run triggers a correction round that names which findings fall, stand or flip (Book 30, D2 2026-08-02).
4. **Two adjudicators.** Adjudicator A consolidates; adjudicator B receives the hardest verdicts as explicit challenges and must rule on each. A panel convened to critique drifts towards convicting its object — B is the counterweight.
5. **Code or render, not memory.** Every finding carries a file path plus JSON path or line. `recalled` gives no support. Prefer rendering the surface with the web runtime offline (see `references/checks.md`) over reading JSON when a verdict depends on renderer defaults (background colour, tab titles, button payload).
6. **Within today's format.** Recommendations use only elements and fields that exist in `SkeletonDescription.swift` or are verified in `Public/js/skeleton-runtime.js`; say which renderer verified them. Never invent purpose refs, element types or capabilities.
7. **Known findings stay known.** Read earlier reviews listed in the brief and mark repeats as "kjent siden <dato>". Do not re-litigate decisions Digipomps has already made.
8. **Severity by rubric.** `blokker` (purpose cannot be reached / user stuck / WCAG A), `alvorlig`, `moderat`, `lav`, `observasjon`. Say when a severity depends on an unverified assumption.
9. **Side-effect free.** Analysis artifacts only. Product changes, Book edits and skill promotions are separate explicit actions approved by Digipomps.
10. **Norwegian bokmål** for deliverables; one language per surface is itself a rule the panel enforces.

## Read First

> **Path convention:** `<HAVEN_ROOT>` is the parent directory containing all
> HAVEN repos (current and future). From inside any HAVEN repo, find it with:
> ```bash
> export HAVEN_ROOT=$(dirname $(git rev-parse --show-toplevel))
> ```

- `references/rules.md` — the consolidated rule set (panel 2026-11-07), grouped A–J, each with the finding it came from. This is what the panel measures against, in addition to Nielsen/Norman/WCAG.
- `references/panel-roles.md` — role definitions, brief template, output format, adjudication protocol.
- `references/checks.md` — inventory script, lint greps, offline render harness, contrast check.
- House rules in CellScaffold: `<HAVEN_ROOT>/CellScaffold/Documentation/Conference_GUI_Porthole_Design_Guide.md`, `ArendalsukaParticipantProgram_UX_Guardrails.md`, `.claude/skills/cellconfiguration-skeleton-authoring/references/schema-and-limits.md`, `.claude/skills/haven-gui-testing/SKILL.md` (leak list).
- Book: `<HAVEN_ROOT>/CellProtocolDocuments/Book/12_Skeleton_Spec.md` (`purpose://skeleton.owner-entity-access`), `20_Skeleton_Motion_And_Component_Surfaces.md`, `23_Purpose_Knowledge_Base.md` + `haven_purpose_knowledge_base_v0.json`, `35_Purpose_Driven_Development_Workflow.md` + `haven_purpose_packages_v0.json` (`pkg.std.gui-surface`), `haven_lessons_register_v0.json`, `30_Panel_Task_Decomposition_Workflow.md`.
- Latest deliverable of this kind: `<HAVEN_ROOT>/CellProtocol/Deliverables/UX_Panel_CellScaffold_2026-11-07/RAPPORT.md` — do not repeat its findings as new.

## Workflow

1. **Inventory.** Run `scripts/surface_inventory.py <repo> <outdir>` to list every JSON surface with purpose fields, element counts, buttons, hex colours, font sizes, unlabelled inputs. Add Swift factories (`grep -rn 'purposeDescription:' Sources`), `Resources/Views/*.leaf` and runtime surface lists (`Deployment/porthole/surfaces*.json`) by hand. Deduplicate copies (catalog vs Playwright scenario) but record drift.
2. **Locate the purpose** for each surface: `discovery` block, Swift factory, `Documentation/*.md`, FORMAALSSPEC in a PDD folder. If none exists, that is finding F-A1, not a reason to skip the surface.
3. **Write the brief** from `references/panel-roles.md` §Brief: task purposes with measurable goals, inventory, where purposes live, house rules, declared conflicts, rubric, output format. Audit every fact.
4. **Fan out** the roles in parallel (minimum: purpose adviser, UX heuristics, visual design + accessibility, web shell, coherence/IA + skeptic). Each writes a full report to a file and returns only the brief audit, counts, top-5, cross-cutting rules and what was not verified.
5. **Correction round.** Collect brief audits. For each brief error: name affected findings and whether they fall, stand or flip. Re-run a role only when a finding's premise fell.
6. **Adjudicate.** A consolidates into the per-surface matrix and ranked findings. B gets the hardest verdicts (typically: a `blokker` resting on a renderer assumption, a cross-cutting conviction resting on an unread shell, a "dead keypath" claim) and must render or read code to rule. Record both rulings.
7. **Deliver.** Dated folder `Deliverables/UX_Panel_<repo>_<date>/` with `RAPPORT.md` (Formål/mål table with final status, method, brief corrections, per-surface matrix, findings by severity, adjudication, cross-cutting rules, Q1–Q10 metrics block from Book 30, open items, what was not verified) plus appendices (inventory, brief, scripts, raw panel reports).
8. **Capture learning.** Rules that hold across surfaces go into `references/rules.md` here and into the skill the next author reads (`cellconfiguration-skeleton-authoring`, `haven-gui-testing`). Distribute with `codex-collaboration` (repo skill → `.claude/skills`, `~/.claude/skills`, `~/.codex/skills`, Desktop ZIP). Product fixes are proposed, never applied, by this skill.

## Output

- `RAPPORT.md` that stands alone: a reader who sees only it knows which surfaces were reviewed, what was found, how severe, what Digipomps must decide, and what was not verified.
- Every finding: surface | element (path + JSON path/line) | finding | principle or house rule | severity | recommendation within today's format | audit status | cross-cutting?
- Purpose matrix per surface: description exists | completeness 0–5 (hvem, hva, utfall, målbart mål, avgrensning) | answered ja/delvis/nei | elements without purpose | purposes without element | owner-entity-access.
- Adjudication section with B's explicit rulings on the challenged verdicts.
- Rules proposed for skills, each traceable to a finding.

## Boundaries

- Never mark a gate approved; only Digipomps does.
- Never promote `purpose://candidate.*` to Book 23 from this skill.
- Never edit product skeletons, Swift or CSS as part of the review. Proposals only.
- Public-facing claims about HAVEN derived from the review go through `haven-claim-review`.
