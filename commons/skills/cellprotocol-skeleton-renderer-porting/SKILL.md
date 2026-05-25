---
name: cellprotocol-skeleton-renderer-porting
description: Use when implementing, reviewing, or porting a CellProtocol Skeleton renderer or parser in SwiftUI, web, Kotlin Compose, Java UI, Rust UI, Go UI, or another runtime. Covers SkeletonElement JSON parity, renderer semantics, modifiers, legacy decode, golden tests, and UI capability limits. Do not use for authoring one-off CellConfiguration JSON unless renderer behavior is being changed.
---

# CellProtocol Skeleton Renderer Porting

Use this skill when the renderer/parser for CellProtocol skeleton JSON is being
implemented or changed.

For creating a single skeleton configuration, use
`cellconfiguration-skeleton-authoring` instead.

When the renderer is part of a new full-runtime port, use this skill together
with `cellprotocol-cross-language-porting`. This skill owns skeleton JSON and UI
parity; the cross-language skill owns resolver/runtime/protocol parity.

## Core Rules

- The JSON contract is portable; renderer implementation details are not.
- Encode canonical wrapper forms for new output.
- Decode legacy forms only where current data requires compatibility.
- Unsupported elements must fail clearly or degrade explicitly; do not silently
  invent behavior.
- `styleRole` and `styleClasses` are metadata unless a renderer clearly consumes
  them.
- UI controls must bind to real keypaths/actions; no fake affordances.
- Renderer parity includes behavior, not just visual resemblance.

## Read First

- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/12_Skeleton_Spec.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Deliverables/Vegar_SkeletonElement_Rendering_Pack/README_Skeleton_Pack.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Deliverables/Vegar_SkeletonElement_Rendering_Pack/SkeletonElement_Rendering_Handbook.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Deliverables/Vegar_SkeletonElement_Rendering_Pack/Skeleton_Test_Validation_Plan.md`

Current Swift sources:

- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Sources/CellBase/Skeleton/SkeletonDescription.swift`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Sources/CellBase/Skeleton/AttachmentSurface.swift`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Tests/CellBaseTests/SkeletonTests.swift`

## Renderer Surface To Preserve

- `Text`, `TextField`, `TextArea`, `Image`, `Spacer`
- `HStack`, `VStack`, `ZStack`, `ScrollView`, `Section`, `Divider`
- `List`, `Object`, `Reference`, `Grid`
- `Button`, `Toggle`, `Picker`
- `Tabs` where present in current Swift enum
- `FileUpload`
- `AttachmentField` as legacy compatibility

Always verify current enum before adding or claiming an element.

## Required Workflow

1. Determine whether the task is parser, renderer, interaction, or styling.
2. Inspect current Swift skeleton source and tests.
3. Define supported element set and explicit unsupported set.
4. Add golden encode/decode tests for JSON shapes.
5. Add behavior tests for actions, selection, upload payloads, and bindings when
   those are implemented.
6. Validate desktop and mobile layout where a browser/app renderer exists.
7. Document renderer gaps instead of hiding them behind style.

## Porting Notes

Kotlin Compose:

- Use sealed models for element types.
- Keep parser independent from composables.
- Keep actions/keypath binding in a runtime adapter, not inside model parsing.

Web:

- Keep DOM output deterministic enough for tests.
- Report unknown elements visibly in diagnostics, not as blank UI.

SwiftUI:

- Preserve platform gaps honestly, especially keyboard and file behavior.

## Must Not

- Do not add elements like Markdown, Map, Chart, Video, Audio, WebView, Table, or
  Mermaid unless current protocol/schema supports them or Kjetil approves new
  implementation work.
- Do not treat CSS classes as protocol semantics.
- Do not make upload UI imply storage; target Cells validate and store.

## Completion Checklist

- Element set matches source/docs.
- Golden JSON tests pass.
- Unsupported behavior is explicit.
- Renderer-specific gaps are documented.
