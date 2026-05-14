# Skeleton Drag And Drop Contract

Status: V1 implementation contract, 2026-05-13.

## Purpose

Drag and drop is a general skeleton modifier capability. It is not a chat-only
feature and it is not a replacement for `FileUpload`. Porthole web can use it
for direct manipulation; Porthole on mobile and Binding can expose equivalent
fallback actions until native drag/drop is implemented.

## Modifier Fields

Drag sources use optional `SkeletonModifiers` fields:

- `draggableRole`: semantic role, for example `person`, `component`, `chat`,
  `cell` or `file`.
- `dragPayloadKeypath`: keypath to pre-sanitized state owned by the source cell.
- `dragPreviewRole`: renderer hint for the drag preview.
- `accessibilityDragLabel`: platform accessibility label.

Drop targets use optional `SkeletonModifiers` fields:

- `dropTargetRole`: semantic target role, for example `chat-invite-slot`.
- `acceptedDragRoles`: roles this target accepts.
- `dropActionKeypath`: action called when a valid drop happens.
- `dropIntents`: candidate operation, for example `add`, `attach`, `copy`,
  `move`, `link` or `absorb`.
- `dropValidationStateKeypath`: cell-owned validation state.
- `dropDeniedReasonKeypath`: cell-owned user-facing denial text.
- `accessibilityDropLabel`: platform accessibility label.

## Payload Shape

Renderers call `dropActionKeypath` with this stable payload:

```json
{
  "dragRole": "person",
  "dragPayload": {},
  "dropTargetRole": "chat-invite-slot",
  "dropIntent": "add",
  "modifierActive": false
}
```

The renderer must never send internal skeleton paths, DOM paths, or inferred
keypaths to the receiving cell.

## Security Rules

- `dragPayloadKeypath` must point to a source-cell-owned public-safe payload.
- The renderer must not construct new keypaths from drag data.
- The receiving cell validates grants, moderation, block state and payload
  shape.
- Drop creates a candidate or draft only. User-visible side effects require a
  separate explicit action.
- Drag previews must not show private endpoint, device, token, proof or owner
  identifiers.

## Porthole V1

Porthole web reflects modifier metadata with HTML5 drag/drop:

- `data-draggable-role`
- `data-drop-target-role`
- `application/x-cellprotocol-drag` transfer payload
- CSS states for `drop-hover`, `drop-valid`, `drop-invalid`, `drop-denied` and
  `drop-pending`

Porthole mobile and Binding should keep fallback buttons near draggable content.
Native drag/drop should use the same payload shape when implemented.

## First Product Use

`Co-Pilot Chat` supports `person -> chat-invite-slot`:

1. A public profile row exposes `publicSafeDragPayload`.
2. Dropping it on the invite helper calls `chatHub.drop.receive`.
3. The chat cell validates the profile, grants and block state.
4. A valid drop fills `inviteDraft`.
5. The invitation is sent only when the user clicks `Send invitasjon`.
