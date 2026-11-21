---
name: cellconfiguration-skeleton-authoring
description: Generate, review, test, or edit CellConfiguration JSON and skeleton structures for HAVEN/CellProtocol. Use when a task involves authoring or changing a CellConfiguration, adding or editing skeleton elements, building a dashboard or surface from cell data, checking whether a requested UI is possible in the current skeleton format, or converting product intent into a valid CellConfiguration. Be strict about current implementation limits: use only supported fields and element types, prove every surface shows its own ways in, run skeleton-check before handing over a file, warn explicitly when a request exceeds today's format or renderer behavior, and do not invent new capabilities or implement new skeleton features without first asking Digipomps.
---

# CellConfiguration Skeleton Authoring

A HAVEN surface is a `CellConfiguration`: a JSON document that names the cells
it uses (`cellReferences`) and describes what the person sees (`skeleton`). The
same file renders in the browser (Porthole) and in the app (Binding, SwiftUI).
No compilation is needed to make a new surface.

Use this skill when the user wants help with:

- generating a new `CellConfiguration`, such as a personal dashboard
- editing an existing `CellConfiguration`, even a single element
- translating product or UI intent into skeleton JSON
- checking whether a requested UI is possible today
- finding, combining and showing data from cells through `cellReferences`,
  `keypath`s and supported composition

`<HAVEN_ROOT>` below means the folder that holds your clones of the HAVEN
repositories. Paths without it are relative to the CellProtocol repository.

## Core Rules

- The code is the source of truth, not intuition or this text.
- Use only supported top-level `CellConfiguration` fields and supported
  `SkeletonElement` cases (see `references/schema-and-limits.md`).
- If a request depends on behaviour that is not implemented, say so clearly.
- Do not invent elements or fields, and do not add new skeleton capabilities.
  A new element or new renderer semantics is implementation work: ask
  Digipomps first.
- Run `skeleton-check` on every file before you hand it over (see
  «Check the file»).

If a request is partly unsupported, answer in two parts:

1. what can be done with today's format
2. what cannot be done without implementation work

## Read First

Before generating or editing anything substantial, read:

- `Sources/CellBase/CellConfiguration/CellConfiguration.swift`
- `Sources/CellBase/Skeleton/SkeletonDescription.swift`
- `Sources/CellBase/Skeleton/SkeletonReachabilityAudit.swift`
- `Tests/CellBaseTests/SkeletonTests.swift`
- [references/schema-and-limits.md](references/schema-and-limits.md)

Read [references/examples.md](references/examples.md) when an example helps.

## Required Workflow

1. Write down the outcome the person wants, and **the actions they must be
   able to take** on the surface. That list is the acceptance contract.
2. Map it to today's `CellConfiguration` and skeleton capabilities.
3. Separate the request into: supported today; unclear, needs a source check;
   unsupported without implementation.
4. Make the data plan:
   - which cells to reference, and the `label` of each reference
   - which `keypath`s the skeleton reads from or writes to
   - whether the data needs `List`, `Reference`, `Object`, `Grid` or direct
     bindings
5. Say what is unsupported before producing the final JSON.
6. Keep the JSON minimal and valid for the current schema. When editing,
   keep the existing structure unless a redesign was asked for.
7. Run `skeleton-check`, with `--require` for every action from step 1.
8. Preview the file where the person can see it (see «Preview»), on a wide
   and a narrow screen.

## Check the file

CellProtocol ships an executable that runs the same check as Cell
Configuration Studio:

```bash
swift run skeleton-check minflate.json
swift run skeleton-check --require todo.toggleTodo minflate.json
swift run skeleton-check --json minflate.json
```

It decodes the file with the production decoder and reports:

- files that are not JSON or not a `CellConfiguration`
- elements the format does not have (they render as nothing in the app)
- `List`/`Grid` row templates (`flowElementSkeleton`) that are not a `VStack`
  (the web renderer rejects the whole surface; the app drops the rows)
- parts of the surface that can never be seen, with the actions lost
- required actions that cannot be reached

Exit code 0 means no findings. A schema-valid file with findings is not done.

## Visibility And Scope — read before using any condition

`SkeletonModifiers.visibility` is the most dangerous part of the format,
because its failure mode is silence.

- The renderer evaluates a condition against **the value it has at that
  position**.
- **At root there is no value.** A root-scoped condition against cell state,
  such as `todo.completedItems.0`, resolves to nothing.
- `evaluate` returns `false` when the keypath does not resolve, when the value
  differs, when the condition is malformed, and when it states no predicate.
  Four situations, one answer, no signal.
- `false` means hidden. A top-level section gated on cell state is not
  reported as broken: it never appears, while the surface looks finished.
- **Inside a row it works.** `List`/`Grid` rows and `Reference` flow elements
  pass the row value down, so conditions there can be answered.

Consequences:

- Do not gate a top-level section on cell state. Put content that should come
  and go in a `List` whose keypath yields zero or one row: an empty list
  renders nothing. Or let the cell bind content that is empty when it does not
  apply.
- `exists: false` is the only root-scoped form that is true when nothing
  resolves.
- Making root-scoped conditions resolve against cell state would be a renderer
  change. Ask Digipomps; never fold it into a surface task.

## Reachability

A schema check cannot tell whether anyone will see the result.
`SkeletonReachabilityAudit` (CellBase) can, and `skeleton-check` runs it:

- `audit(_:)` returns every element that can never be seen, and each
  finding's `lostActionKeypaths` names what the person loses with it.
- `reachableActionKeypaths(_:)` returns what the person can actually reach.
  Check the action list from step 1 against it, by name.

## Layout that works on a phone

- `flowElementSkeleton` must be a `VStack`, even for a single `Text`.
- Three texts side by side break mid-word on a narrow screen. Put a title and
  its detail in a `VStack`, then `Spacer`, then the button.
- `HStack` wraps only with `wrap: true`. For width-dependent layouts use
  `layoutVariants` (`maxAvailableWidth` → vertical axis), which both the web
  and the app read.
- Colours, corner radius, borders, font size and weight, and padding are
  `modifiers` fields that both renderers read. `styleRole` and `styleClasses`
  are hints: the surface must work without them.
- One primary action per step. Plain language in labels; keypaths belong in
  documentation, not on the surface.

## Preview

- **On staging (anyone with an account):** upload the file in Cell
  Configuration Studio or Cell Configuration Architect («Last opp privat
  CellConfiguration-utkast»). The draft is private; nothing is published.
  Preview does not run `setKeysAndValues` or subscriptions, but buttons and
  fields reach the real cells, which check access as usual.
- **With a local CellScaffold (maintainers):** the Porthole runtime iteration
  loop (`npm run skeleton:iterate -- --mode preview …` in
  `<HAVEN_ROOT>/CellScaffold`) previews, reviews and commits runtime overrides
  without a rebuild. See `Documentation/Skeleton_Runtime_Iteration_Workflow.md`
  there.

Never answer «it works» for a visual surface on the strength of the check
alone. Say which layer you verified: file check, web preview, or the app.

## Output Pattern

When the request is supported:

- a short capability check
- the data plan
- the actions the person must be able to take, and where each lives
- the final `CellConfiguration` JSON or a focused patch
- the `skeleton-check` result

When the request is partly unsupported:

- `Supported now:` concise list
- `Not supported in current skeleton:` concise list
- `Needs approval from Digipomps before implementation:` concise list
- then only the supported JSON, if it still adds value

## Guardrails

- Prefer canonical wrapper keys like `Text`, `VStack`, `List`, `Button`.
- Do not invent elements like `Markdown`, `DatePicker`, `WebView`, `Chart`,
  `Video`, `Map` or `Table`. Charts go through `Visualization`, and only with
  the kinds the renderers support.
- Do not promise keyboard behaviour beyond what the renderer documents.
- A button grants no rights. Every action is checked by the cell against the
  person's Agreement; «denied» is access, not JSON.
- Do not treat transport input such as QR payloads or deep links as
  authority.

## What To Escalate

Escalate instead of guessing when the request needs:

- a new skeleton element type
- new renderer semantics, including root-scoped conditions on cell state
- styling beyond the current modifiers
- media or embed capabilities not in the element enum
- key handling or event semantics the renderers do not have

Use plain language:

- `This part is not supported by today's skeleton format.`
- `This would require implementation work. I should ask Digipomps before adding it.`
- `I have not seen the rendered surface, so I have not verified that it renders.`
