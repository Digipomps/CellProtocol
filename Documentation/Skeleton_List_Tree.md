# List trees in Porthole and CellApple

WP1a round 2 implementation status: **written, not verified**. Round 1 passed
Losen's reported test gates (1326 baseline / 1337 changed, zero failures), but
its images did not meet the approved chip layout. Those results do not verify
round 2. Landing requires new gates and Kjetil's approval of the rendered images.

`SkeletonList.childrenKeypath` is supported by the Porthole renderer and by this
native CellApple implementation. It names a list inside each row; a missing or
non-list value means that the row has no children. Children reuse the same row
skeleton and are rendered in pre-order with increasing indentation. Native
branches have a `▸` / `▾` button labelled `Utvid` / `Slå sammen`. Disclosure only
changes renderer state; it does not select, activate, write to, or reload a Cell.

`expandedStateKeypath` seeds local expansion from the current render snapshot:

| Configuration/value | Initial expansion |
| --- | --- |
| No keypath (or an empty keypath) | All branches open |
| List of identities | Only those identities open |
| `"*"` (also `"*"` inside the list, as in Porthole) | All branches open |
| Empty list, null, another type, or an unresolved keypath | All branches closed |

A row identity uses the non-null `selectionValueKeypath` property, then `id`,
then `uuid`, then its source path (`#0`, `#0.1`, etc.). Porthole looks up the
identity property directly, even if its name contains a dot. `childrenKeypath`
first tries a direct list property, then a nested path. Supply stable unique
string identities when rows can move or be refreshed; path identities describe
positions and duplicate identities share expansion state.

Local changes survive a reload with the same seed. A changed seed replaces local
expansion; null and an unresolved keypath share one seed signature. Closing a
branch while all are open first records the currently expanded branch identities,
so reopening it restores the previously expanded descendants. Selection indices
are remapped by row identity during disclosure without sending a selection action.

Non-wrapped flat top-level lists retain their existing rendering and selection behavior.
No skeleton elements, fields or modifiers are introduced by this implementation.

## A wrapped list inside a row (S2)

The parent is a List with `childrenKeypath: "children"`. Its one child owns
`tags: [{"label": "arancini"}, ...]`. The shared row VStack contains a Text bound
to `label`, and an inner List bound to `tags` with `modifiers.wrap: true`.

`CellListView.rowContent` passes the row as `userInfoValue` and as the item in
`SkeletonRenderDataContext`. Relative nested Lists consume that row's value;
missing, null or non-list data produces an empty list without a Cell lookup or
root-data fallback. An explicit `cell://` list keypath retains its normal source.
The nested list lays out at its content height, using the existing `FlowLayout`
for wrapping instead of an additional vertical ScrollView. Optional Text fields
must declare `visibility: {"when": {"scope": "item", "keypath": "label", "exists": true}}`.
The round-1 special case for absent tree-row text has been removed: a required
missing field still uses the ordinary unavailable-content message.

## Native wrap sizing (round 2)

`List.modifiers.wrap: true` means that each item owns its width, including the
row template's padding, any explicit `rowInsets`, and any selection/disclosure/
activation controls. It does not mean equal-width columns. Native wrapped rows
now omit the ordinary trailing Spacer and default to zero row insets; explicit
insets are still honored. They use their ideal horizontal size. Non-wrapped rows
retain the full-width frame, Spacer, and default 6/8/6/8 insets. Selection,
activation and tree indentation remain on their existing paths. `rowDecoration:
"none"` suppresses selection decoration; it does not itself remove row insets.

`itemSpacing` sets both the horizontal and vertical gaps in a wrapped List
(default 8). Previously only horizontal spacing was passed to `FlowLayout`;
vertical spacing always used its default 8. The layout implementation itself is
unchanged. Explicit fixed/minimum widths in the row template still contribute
to item width, and a single item wider than the container retains the existing
overflow behavior of FlowLayout. No new schema fields were added.

The round-1 source explains the apparent columns: FlowLayout measures each
whole row with `.unspecified`, not just its visible chip. The row added 8 + 8
horizontal insets, a Spacer with minimum 8, and an HStack gap of 8: at least
32 extra horizontal points per ordinary chip. Vertically it added 6 + 6 insets
plus FlowLayout's 8-point line gap. The shared row template also had a default
10-point VStack gap and a rendered empty Text for the child without `label`.
These are source findings, not measured round-2 image results.

The Palazzo S2 fixture now explicitly uses zero `rowInsets`, `rowDecoration:
"none"`, and `itemSpacing: 4` on both lists; both row VStacks have `spacing: 0`.
The outer label has item-scoped `visibility` on `label`; the tags List has the
same rule on `tags`, so the parent does not reserve an empty tag slot. The chip
itself keeps its caption font, padding 4, background and radius 10. Tree depth
indentation and the native disclosure gutter remain; the fixture does not claim
to reproduce the approved card's background or arrow placement.

Source inventory: CellProtocol checkout and `origin/main` (`81601a6`), this
worktree, and CellScaffold checkout plus locally cached `origin/main`
(`adf48d4615d1ed143d5bdc190fcf63e266214c8f`) were searched. The native List change
also affects Arendalsuka's `selectedSpeaker.interestRows`
(`ArendalsukaEventAtlasConfigurationFactory.participantInterestChipList`) and
Butler Workbench's `scopeChips` / `branchChips`
(`PersonalCopilotConfigurationFactory+Workbench`, also represented in
`playwright/fixtures/butler-chat-skeleton.json`). Their own chip padding remains;
the implicit outer padding/Spacer disappears. Butler's explicit spacing 6 now
applies between lines too. Kallimachos and conference participant chat, portal,
and public-profile editor wrap hits are HStacks, so this List-only change does
not change them. Web/Porthole code was not changed. This is an inventory of the
read sources, not a complete inventory of externally stored configurations.

## Tests and artifact handoff

The macOS-only `SkeletonNativeTreeListTests` lives in `Tests/CellBaseTests`.
`Fixtures/SkeletonListTreePorthole.json` copies the scope tree from CellScaffold's
`playwright/skeleton-list-tree.spec.js` at
`adf48d4615d1ed143d5bdc190fcf63e266214c8f`. It records the visible label order and
depths for the reference's expansion sequence. This is a pinned oracle, not a
claim that Playwright and native tests have both been run on this change.

`Fixtures/SkeletonListArticleReaction.json` is the round-2 Palazzo skeleton,
derived from the S2 spike with the explicit spacing/visibility rules above.
It keeps the WP1a reaction data, including the child without a `label`. It is
intentionally no longer byte-identical to the original Porthole spike.

`testWrappedListItemsTakeTheirOwnWidth` hosts the real renderer and compares
three different chip widths against independent SwiftUI Text + padding
measurements. It checks default zero row insets and explicit extra insets,
both top-level and row-local Lists, and requires the chips to fit on one line
with the specified gap. `testTreeRowMissingRequiredTextKeepsUnavailableMessage`
removes the fixture's visibility rule and requires the normal missing-field
message. These tests are written, not executed in this round.

From the CellProtocol worktree, Losen can run the focused suite with:

```sh
swift test --filter SkeletonNativeTreeListTests
```

The image method returns immediately unless `NATIVE_TREE_IMAGE_DIR` is set.
With an existing or creatable output directory, run:

```sh
NATIVE_TREE_IMAGE_DIR=/private/tmp/native-tree-images swift test --filter SkeletonNativeTreeListTests.testRenderArticleReactionRowImages
```

It hosts the real renderer in an offscreen `NSWindow` using `NSHostingView` and
`cacheDisplay(in:to:)`, opens the row through its accessibility press action,
and writes `native-brikker-lukket.png` (390 pt), `native-brikker-aapen.png`
(390 pt), `native-brikker-smal.png` (320 pt), and the explicitly named light-theme
review copy `native-brikker-aapen-lyst.png` (390 pt). The host already enforced
`.environment(\.colorScheme, .light)` and Aqua in round 1; this is retained.
Each bitmap must contain multiple colors and all seven chip labels must be
present when open. The image test also requires at least five chips on the
first 390-point line, 4-point gaps between lines, and no more than 16 points
between the registered label and the first chip line. It does not use ImageRenderer.
Actual correspondence with the approved image still requires image review;
geometry and nonuniform bitmap checks alone cannot prove it.

## Inspection lesson for future renderer work

On the WP1a baseline (`81601a6`), `SkeletonList.getElements(in:)` already resolves
an existing list from the row context. That alone does not establish S2 support:
a missing key can still fall through to the host/Cell, a nested ScrollView can
consume the wrong height, and `SkeletonText.asyncContent` returns an unavailable
message when an object lacks the requested field. Keep fixtures with absent
optional fields (the S2 parent lacks `tags`, the child lacks `label`), include a
conflicting root-level collection, and inspect the actual hosted images. These
are source-inspection findings; round 2 still needs the test and image gates
described above. Use item-scoped visibility for optional text, not blanket
suppression of missing-field errors. When investigating chip spacing, trace the
whole row wrapper's measured size and all padding/Spacers before changing the
flow algorithm. Keep fixtures that assert geometry, not only visible labels.

## Known deviation: a wrap list alone at the root (native)

Measured 2026-09-29. A `List` with `wrap: true` that is the root element, and so
goes through CellListView's `ScrollView` path, wraps every chip onto its own line
when the host is only just wide enough for them. Inside a row or a `VStack`, the
chips pack as the contract says. A diagnostic run on `origin/main` (81601a6) and
on this branch placed the root case the same way, so the deviation predates the
native tree list. The cause is not found. `testWrappedListItemsTakeTheirOwnWidth`
therefore tests only the nested case.
