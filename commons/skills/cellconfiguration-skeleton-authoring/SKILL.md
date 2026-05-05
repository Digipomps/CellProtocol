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
