---
name: cellconfiguration-skeleton-authoring
description: Generate, review, or edit CellConfiguration JSON and skeleton structures for HAVEN/CellProtocol. Use when a task involves authoring or changing CellConfiguration, adding or editing skeleton elements, checking whether a requested UI is possible in the current skeleton format, or converting product intent into valid CellConfiguration. Be strict about current implementation limits: use only supported fields and skeleton element types, warn explicitly when a request exceeds today's format or renderer behavior, and do not invent new capabilities or implement new skeleton features without first asking Kjetil for approval.
---

# CellConfiguration Skeleton Authoring

Use this skill when the user wants help with:

- generating a new `CellConfiguration`
- editing an existing `CellConfiguration`
- translating product/UI intent into skeleton JSON
- checking whether a skeleton/UI request is possible today
- identifying what is configuration-only versus what would require implementation
- helping users find, combine, and display data from cells through
  `cellReferences`, `keypath`s, and supported skeleton composition

## Core Rules

- Treat the current codebase as the source of truth, not intuition.
- Use only supported top-level `CellConfiguration` fields and supported
  `SkeletonElement` cases.
- `Tabs` is supported today as `SkeletonElement.Tabs(SkeletonTabs)`.
- `FileUpload` is supported today as `SkeletonElement.FileUpload(SkeletonFileUpload)`.
  Prefer it for new upload surfaces. Legacy `AttachmentField` still decodes and
  renders for backwards compatibility.
- If a request depends on behavior that is not implemented today, say so
  clearly.
- Do not silently add new skeleton capabilities.
- Do not propose implementation of a new capability without first asking
  `Kjetil`.

If a request is partially unsupported, respond in two parts:

1. what can be done with today's format
2. what cannot be done without implementation work

## Read First

Before generating or editing anything substantial, inspect these sources:

- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Sources/CellBase/CellConfiguration/CellConfiguration.swift`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Sources/CellBase/Skeleton/SkeletonDescription.swift`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Tests/CellBaseTests/SkeletonTests.swift`

Then read the reference file:

- [references/schema-and-limits.md](references/schema-and-limits.md)

Read examples only when useful:

- [references/examples.md](references/examples.md)

## Required Workflow

1. Identify the requested user outcome.
2. Map it to current `CellConfiguration` and skeleton capabilities.
3. Separate the request into:
   - supported with today's format
   - unclear and needs source check
   - unsupported without implementation
4. Identify the runtime data plan:
   - which cells must be referenced
   - which labels those references should use
   - which `keypath`s the skeleton will read from or write to
   - whether the request needs `List`, `Reference`, `Object`, `Grid`, or simple
     direct bindings
5. If unsupported parts exist, say that explicitly before producing final JSON.
6. When producing JSON, keep it minimal and valid for the current schema.
7. If editing an existing configuration, preserve supported existing structure
   unless the user asked for a redesign.

## Output Pattern

When the request is simple and supported, provide:

- a short capability check
- a short data-plan summary
- the final `CellConfiguration` JSON or a focused patch

When the request is partially unsupported, provide:

- `Supported now:` concise list
- `Not supported in current skeleton:` concise list
- `Needs Kjetil approval before implementation:` concise list
- then only the supported JSON if it still adds value

## Guardrails

- Prefer canonical wrapper keys like `Text`, `VStack`, `List`, `Button`.
- `Tabs` may be used when the request fits the current `SkeletonTabs` model:
  `activeTabStateKeypath`, optional `selectionActionKeypath`, `idKeypath`,
  `labelKeypath`, and `panels`.
- Do not invent elements like `Markdown`, `DatePicker`, `WebView`, `Chart`,
  `Video`, `Audio`, `Map`, `Table`, or `Mermaid` unless you have
  confirmed they are actually present in `SkeletonDescription.swift`.
- Do not assume `styleRole` or `styleClasses` imply full theme/styling support.
  They are metadata unless the renderer clearly consumes them.
- Do not promise keyboard behavior beyond what the current renderer documents.
- Do not treat transport input such as QR payloads or deep links as authority;
  keep configuration authoring separate from runtime protocol authority.

## Canonical Questions To Answer Internally

Before you finish, make sure you can answer:

- Which exact skeleton element types are used?
- Which keypaths or endpoints must exist at runtime for this to work?
- Which `cellReferences` are needed, and why?
- Is any requested behavior actually renderer behavior rather than schema?
- Is the user asking for a new component rather than a new configuration?
- Would this require implementation approval from Kjetil?

## What To Escalate

Escalate instead of guessing when the request requires:

- a new skeleton element type
- new renderer semantics
- richer styling than current modifiers support
- upload/media/embed capabilities not present in the current enum
- behavior that depends on unsupported key handling or event semantics

Use plain language:

- `This part is not supported by today's skeleton format.`
- `This would require implementation work. I should ask Kjetil before adding it.`

## UX-panelets forfatterregler (lagt til 2026-11-07)

Et UX/GUI/design-panel gikk gjennom alle flatene i CellScaffold 7. november 2026
(`<HAVEN_ROOT>/CellProtocol/Deliverables/UX_Panel_CellScaffold_2026-11-07/RAPPORT.md`).
Reglene under gjelder hver gang du skriver eller endrer et skeleton; hele settet står i
`<HAVEN_ROOT>/CellProtocol/commons/skills/haven-ux-surface-review/references/rules.md`.

- **Formålet reiser med filen.** `description` + `discovery.purpose` (purpose://-ref eller
  `candidate.*`) + `purposeDescription` som svarer på hvem, hva, utfall, målbart mål og
  avgrensning. Skrevet for brukeren, ikke for rendereren. (A1–A3)
- **Hvert element har en setning i formålet, hvert løfte har et element.** Stryk eller utvid før commit. (A4)
- **Tabs har forfattede etiketter** (`tabsKeypath` + `labelKeypath` eller tittel per panel); uten
  det gir web `defaultTabTitle(id)` («Overview») og Apple kapitalisert id. (G3)
- **Rad-knapper erklærer kontrakten:** `labelKeypath` + `payloadKeypath`, norsk fallback-verb i
  `label`, aldri «Action». (B1, D4)
- **Valg trenger både tilstand og handling, og de må være ulike.** `selectionActionKeypath` for
  handlingen (web dispatcher aldri uten), eget `.state.`-felt i `selectionStateKeypath`; samme verdi i
  begge gir dobbel dispatch på Apple. (D2)
- **Ingen ubundet input.** `targetKeypath`, eller `submitActionKeypath` + `submitOnEnter`; en
  send-knapp ved feltet bærer samme tekst, aldri `payload: true`. (D1)
- **Tre tilstander per List** (rader / ingen / kunne ikke lese) – fra cellen eller via `visibility`;
  aldri statisk ro-tekst. (C1)
- **Farlig verb = to trinn + konsekvens + kvittering**, egen HStack, ikke `primary-action`. (D3)
- **Fargepar, aldri enkeltfarge;** kontrast ≥ 4,5:1 skal kunne regnes fra JSON. Velg én
  stylingstrategi (tema-CSS via `styleClasses` / `styleVariables` / fast palett ≤ 12) og si det i
  `description`. Én typografiskala 12·14·16·20·24·32. (F1–F4)
- **Tilgjengelig navn på alt:** `alt`/`altKeypath` på `Image`, `label` på `Picker`/`Toggle`,
  `accessibilityLabel` på tekstfelt og ikon-knapper. (G1–G2)
- **Ett språk per flate** (samme som `purposeDescription`); internspråk bare bak «Avansert». (E1, E3)
- **Owner-entity-access er et element:** synlig vei til egen entitet/Co-Pilot, eller `shellProvided`
  markert og bevist i reachability-auditen. Flater uten Porthole-skall må alltid ha elementet selv. (H1)
- **Gjentakelser er rader** (List/Grid med `flowElementSkeleton`), ikke statisk utrulling. (B4)
- **Én kilde per flate.** Playwright-kopier eksporteres fra katalogen eller testes for erklært avvik. (I1)
