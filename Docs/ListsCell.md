# ListsCell — `cell:///Lists`

Last verified against code: 2026-10-08 (`Sources/CellBase/Cells/Lists/`, branch `pdd/lister-celle`).

Holds one person's named lists — shopping list, reminders, ideas, anything — with items that can be
checked off and reordered. Checked items always sit at the bottom, in the order they were checked,
as in Apple Notes. The cell delivers the same checklist skeleton in two ways: as the surface
«Mine lister» (`ListsSkeletonFactory.mineListerConfiguration()`) and as one
`SkeletonComponentMount` per list, so a host can drop a list in with a single `ComponentSurface`.

Purpose tree, approved images and contract:
`CellProtocolDocuments/Deliverables/PDD_lister-celle-og-komponent_2026-10-02/`.

## Files

| File | Holds |
|---|---|
| `Sources/CellBase/Cells/Lists/ListsModel.swift` | `ListsStore`, `ListsListRecord`, `ListsItemRecord`, the ordering invariant and every mutation |
| `Sources/CellBase/Cells/Lists/ListsPayloads.swift` | The `lists.state` shape the skeleton reads (row payloads, 0/1-row lists, mounts) |
| `Sources/CellBase/Cells/Lists/ListsConfiguration.swift` | `ListsSkeletonFactory`: one checklist skeleton, two keypath prefixes; «Mine lister»; mounts |
| `Sources/CellBase/Cells/Lists/ListsCell.swift` | The cell: keys, grants, persistence, payload parsing |
| `Sources/CellBase/Skeleton/SkeletonComponentActionContext.swift` | TaskLocal mount context a host sets around a mounted action |
| `Tests/CellBaseTests/Lists*Tests.swift`, `Fixtures/ListsMineListerApproved.json` | 27 tests; the fixture is the JSON the approved images were rendered from |

## Keys

Owner grant: `rw--` on area `lists`. Any other requester is denied before the handler runs.
Through a Porthole reference labelled `my`, every key below is reached as `my.lists.…`.

| Method | Keypath | Payload | Effect / returns |
|---|---|---|---|
| get | `lists.state` | — | `ListsStatePayload`: `status`, `cell`, `schemaVersion` (`haven.lists.state.v1`), `stateVersion`, `updatedAtEpochMs`, `activeListId`, `lists[]` (rows with `mount`), `activeAsRows` (0/1 `ListView`), `emptyHint`, `notice`, `mountsById`, `counts` |
| get | `lists.state.<path>` | — | Nested lookup through the root intercept `lists`, e.g. `lists.state.lists`, `lists.state.mountsById.<id>` |
| set | `lists.list.create` | string or `{title, kind?}` | New list, becomes active. `kind`: `shopping`, `reminders`, `ideas`, `custom` |
| set | `lists.list.select` | string, `{listId}` or a List selection payload `{selected}` | Sets `activeListId` |
| set | `lists.list.rename` | string (→ target list) or `{listId, title}` | Renames |
| set | `lists.list.remove` | string or `{listId}` | Removes list and items; active falls back to the first list |
| set | `lists.list.clearDone` | `{listId}`, string or `true` (→ target list) | Deletes checked items |
| set | `lists.item.add` | string (→ target list) or `{listId?, title}` | New item, last among open items |
| set | `lists.item.update` | `{listId, itemId, title}` | Renames an item |
| set | `lists.item.toggle` | `{listId, itemId}` | Checks/unchecks; checked → bottom with `doneAtEpochMs`, unchecked → last among open |
| set | `lists.item.move` | `{listId, itemId, direction: up/down}` or the web drop payload `{dragPayload, dropTargetPayload}` | Moves within the open zone; dragged item lands before the target; a step at the edge is a no-op |
| set | `lists.item.remove` | `{listId, itemId}` | Deletes an item |

Every set returns `{status: "ok", stateVersion, …}` or `{status: "error", code, message}` with codes
`invalid_payload`, `invalid_title`, `no_target_list`, `list_not_found`, `item_not_found`,
`item_done_cannot_move`.

**Target list for text without a list id** (`item.add`, `list.rename`, `clearDone` with `true`):
explicit `listId` → `SkeletonComponentActionContext.mount?.instanceID` when a host dispatches a mounted
action → `activeListId` → `no_target_list`.

## Ordering invariant

After every mutation, `items == open items (manual order) + checked items (doneAtEpochMs ascending)`.
`ListsStoreTests.testInvariantHoldsForRandomOperationSequences` drives 200 random sequences of 30
operations through it. Two items checked in the same millisecond keep their checking order.

## Persistence

`persistancy == .persistant`. After each successful mutation the cell calls
`CellResolver.persistCellSnapshot(self)`; when that returns `false` the state carries a `notice` row
(«Kunne ikke lagre siste endring …») that the surface shows above the list. Encode/decode round-trips
the whole store byte for byte (`ListsCellTests.testEncodeDecodeRoundTripKeepsStateByteForByte`).

## Skeleton

`ListsSkeletonFactory.checklistSkeleton(keypathPrefix:)` builds the checklist once; the surface uses
`my.lists.` and the mount `lists.`. The surface JSON is byte-identical to
`Tests/CellBaseTests/Fixtures/ListsMineListerApproved.json`, which the approved images were rendered
from. Choices that live in the skeleton, and why:

- Check-off is two `Button`s with item-scoped visibility (not `Toggle`): a `Toggle` sends a bare
  bool to a fixed keypath and cannot say which item it belongs to; a `Button` resolves its payload from
  the row (`payloadKeypath`).
- Unchecked is the text glyph «○» because the web icon map has no `circle`; checked is
  `checkmark.circle.fill`, which both renderers have.
- The arrows «flytt opp/ned» carry `layoutVariants: [{requiresCapability: [drag], hidden: true}]`: hosts
  that declare `drag` (Porthole web) hide them and use drag-and-drop; hosts without (Binding today) show
  them. Both paths call `lists.item.move`.
- Optional sections (`emptyHint`, `notice`, `activeAsRows`, `emptyRows`, `doneRows`) are lists with 0 or 1
  rows, never root-scoped conditions (lesson.unresolvable-condition-is-invisible).
- Checked items are dimmed through `foregroundColorKeypath: titleColor` (`#8E8E93`, only set when done);
  open items inherit the surface colour.

## Mounting a list elsewhere

```json
{"List": {"keypath": "my.lists.state.lists", "flowElementSkeleton": {"VStack": {"elements": [
  {"ComponentSurface": {"sourceKeypath": "mount", "instanceIDKeypath": "id", "variant": "inline"}}]}}}}
```

with `CellReference(endpoint: "cell:///Lists", label: "my")`. On the web the mount's actions reach
`cell:///Lists` with `mount.instanceID == listId`; the integration package makes CellScaffold's
`ScaffoldKit.ComponentActionContext` a typealias of `SkeletonComponentActionContext` so the cell sees it.
In the native renderer a mounted definition renders, but its actions need the host adapter Binding
does not have yet — the plain surface «Mine lister» works there today.

## Known limits

- Owner only; sharing a list with another entity is a later purpose.
- No due dates, priorities or recurrence (that is CellScaffold's `TodoCell`).
- Web shows row buttons as filled buttons because `.canvas.product-view .skeleton-button` overrides
  `controlStyle: plain` (`porthole-webo.css`); the native renderer shows plain icons.
