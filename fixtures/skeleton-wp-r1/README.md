# WP-R1 portable format fixtures

These fixtures pin the approved `SKJELETT_ELEMENTER.md` iteration 5 contract.
They are shared inputs for the CellBase tests and the later web/native work.

- `tree.json`: all required Tree fields, a wrapped VStack row, and all 23 new modifiers.
- `component.json`: source keypath, stable instance ID, explicit pinned variant, and modifiers.
- `modifiers.json`: the same complete modifier payload without an element wrapper.
- `negative-modifiers.json`: named invalid payloads and the field that must appear in the rejection.

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
