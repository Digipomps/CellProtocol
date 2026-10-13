# WP-R1 portable format fixtures

These fixtures pin the approved `SKJELETT_ELEMENTER.md` iteration 6 contract,
including the mount binding in §2.2 (the other R1 fields retain iteration 5).
They are shared inputs for the CellBase tests and the later web/native work.

- `tree.json`: all required Tree fields, a wrapped VStack row, and all 23 new modifiers.
- `component.json`: source keypath, stable instance ID, explicit pinned variant, and modifiers.
- `modifiers.json`: the same complete modifier payload without an element wrapper.
- `negative-modifiers.json`: named invalid payloads and the field that must appear in the rejection.
- `component-mount-two-instances.json`: the shared web/native T-F3 oracle.
- `negative-component-mounts.json`: 35 named rejected descriptors, including every
  required field missing/null/wrong-type/blank, malformed skeleton wrappers, and
  `instanceID` incorrectly placed in the descriptor.

## Shared mount scenario

Render `skeleton` with `initialRoot` as the host root at `hostCellEndpoint`.
Resolve each surface's `sourceKeypath` item-first then root, just like other
keypaths. The resolved value is a `SkeletonComponentMount`, without an extra
wrapper. Its `item` replaces the current item for the mounted definition;
the host root stays unchanged. Omitted/null item supplies no item data.

`expected.initial` names the text shown by each stable instance ID. `title`
comes from each mount's item and `subtitle` falls back to the host root.
Execute each `expected.actions[].trigger` through the renderer's real action
path and compare the emitted envelope with `dispatch`: sourceCellEndpoint,
keypath, unchanged payload and separate mount metadata. The user payload's
own instanceID deliberately differs from mount.instanceID to detect merging.
The source cell decides access; this fixture does not grant any authority.

Apply `sourceUpdates` in order by replacing only the value at sourceKeypath
in the host root. Compare the resulting view with `expected.afterUpdates`.
Assert unchangedInstanceIDs, no remountedInstanceIDs, unchangedMounts and the
unchangedDefinition flag against actual renderer state. A's title changes;
B's descriptor and both mounting identities stay unchanged.

Both initial definitions and the update encode to byte-identical skeleton JSON
with sorted keys. Only item changes; keypaths are never rewritten. Swift tests
verify serialization and oracle consistency. T-F3 in each renderer must still
prove actual binding, source dispatch, update isolation and retained identity.

Swift tests: `swift test --filter SkeletonTests` and
`swift test --filter SkeletonReachabilityAuditTests` from the package root.
Valid fixtures must round-trip without field loss or unexpected `Unsupported`.
Invalid modifier fixtures must throw when decoded directly; the existing element
decoder may instead return a named `Unsupported` failure. That is rejection,
never success. No legacy `padding` behavior is changed.

The fixtures describe format, not running cell endpoints or a rendered product.
Component resolution is an explicit host-supplied audit input carrying the exact
component ID, revision, definition and data-scope availability. No lookup or
subscription is performed by the format/audit. `instanceID` belongs to the mount,
not to the source; hosts must preserve it across layout changes.

V3-A dimensions describe available content space. Declared child space is clamped
to its known parent; undeclared dimensions inherit. A host/known container must
call `narrowed(availableWidth:availableHeight:)` for its children. Without that
call a 236-unit column still inherits its parent's width: no implicit measurement
exists. Thresholds are inclusive; the first matching variant wins, all declared
capabilities are required, and missing dimensions cannot match size thresholds.
