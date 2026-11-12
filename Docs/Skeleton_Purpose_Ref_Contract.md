# Skeleton Purpose Reference Contract

Status: V1 implementation contract, 2026-11-09. Last verified against code 2026-11-09
(`Sources/CellBase/Skeleton/SkeletonDescription.swift`, `SkeletonModifiersFields.purposeRef`).

## Purpose

A skeleton element can name the purpose it serves. `purposeRef` is metadata for
tests and audits, not for rendering: it lets a test judge whether an element
belongs on its surface (its purpose must be a descendant of the surface's
`CellConfiguration.purposeRefs`) and derive what the element must observably do.
It comes from PDD `formaal-som-gui-test` (CellProtocolDocuments, 2026-11-08).

## Modifier Field

- `purposeRef`: optional `String` on `SkeletonModifiers`. A `purpose://…`
  reference into Book 23 (`haven_purpose_knowledge_base_v0.json`) or a
  `purpose://candidate.…` node named in a FORMAALSSPEC.

```json
{
  "Button": {
    "keypath": "gameHelper.ask",
    "label": "Lag spill",
    "modifiers": { "purposeRef": "purpose://candidate.game-workshop.project.create" }
  }
}
```

## Rules

- Decoding rejects a blank value and a value that does not start with
  `purpose://` (`SkeletonFormatError`, field `purposeRef`).
- An absent field is not encoded, so existing skeleton JSON is unchanged.
- Renderers (Porthole web, Binding) ignore the field. A renderer built against
  an older CellBase drops it on decode; coverage must therefore be measured by a
  test that links a CellBase with this field.
- A purpose never grants, widens or inherits a right. `purposeRef` is read by
  tests; cells enforce grants exactly as before (Purpose-Bound External Action
  Contract, `lesson.purpose-never-grants-rights`).

## Consumers

- `SkeletonReachabilityAudit` is unchanged in this version. The coverage test
  that walks interactive elements and compares their purposes with the surface's
  purposes lives with the pilot (CellScaffold, Spillverksted).
