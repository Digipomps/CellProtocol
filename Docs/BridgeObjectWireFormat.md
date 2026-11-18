# Explicit Object values on the bridge wire

> **Status on main (R5 merge, 2026-11-18): opt-in.** The format below is selected
> with `CellBase.objectWireFormat = .explicitEntries`. The default,
> `.legacyInference`, keeps main's encoding and lenient decoding byte for byte,
> so existing peers and Codable round-trips (ChatCell, EntityScanner, FileCrypto,
> TrustedIssuer, Skeleton map specs, admission challenges) are unchanged. Turning
> it on for a shared wire still needs the coordinated peer decision described
> under "Decoder contexts and compatibility".

D252E candidate change, not a deployment statement. Alternative 1 was explicitly
authorized in the D252C order. Verification is tied to the current candidate and gate
evidence under `HAVEN-Deploy/_handoff/ARBEIDSBENK/`.

`WireObject` emits Objects requiring explicit representation as a single
`&objectEntries` member. It maps application property names to records with
`type` and `value`. Types use the existing wire marker vocabulary; `null` and
`&identity` identify those additional ValueType cases. Lists within these
records contain typed records too, preserving number versus integer, integral
float, and data variants recursively. An embedded Cell must first be advertised
as a description; `.cell` as an explicit Object property throws on encoding.

Example: a list containing an Object property named data with integer value 1:

```json
{"cmd":"response","cid":7,"&list":[{"&objectEntries":{"data":{"type":"integer","value":1}}}]}
```

Plain objects whose JSON inference already preserves each variant retain their
old encoding (for example age as integer and name as String). Marker-named
non-null properties, reserved envelope names and variants lost by inference
require explicit encoding. Nested Objects make the same decision recursively.

The old ambiguous `&list:[{"data":1}]` remains rejected under the unchanged
D248 negative contract. Empty and all-null Objects without the new reserved envelope key retain the old dictionary
encoding, including D248 nested null byte roundtrips.

## Decoder contexts and compatibility

BridgeCommand selects typed decoders from its declared payload keys. A legacy
generic Object container interprets child wire markers explicitly. Neither path
infers a type merely from the last codingPath component. Explicit entries treat
every application property name as data, including data, bool, integer, float,
&keyValue, and &objectEntries itself.

Legacy top-level typed primitives, list/Object dictionaries, valid structured
payloads, null payloads and unknown command/metadata compatibility remain
accepted. Accepted legacy Objects may re-encode to the explicit form; byte
identity is preserved where specifically required and tested, including all-null
dictionaries. Older peers are not asserted to understand the new representation.
Peer rollout/capability negotiation is outside this local candidate and requires
a coordinated compatibility decision before use.

Known malformed present fields in KeyValue, FlowElement, AnyCell,
CellConfiguration, Agreement and VCClaim propagate errors. Absent/null optional
fields preserve their existing defaults. Agreement accepts unknown String states
through its existing legacy fallback, but rejects a non-String present state.
Resolver and identity proof remain authoritative for actual Cell operations.

Focused verification includes FileCryptoCell.advertise/Explore, variant/byte
roundtrips, legacy negatives and authorized set/get with real proof and observed
Cell write count. Complete gate results, control-removal evidence and remaining
work are reported separately in `D252E-ASTRA-FUNN-RETTET-29.md`.

When FlowElement has no declared contentType, valid producer string, integer,
Boolean, list and Object content is decoded without inventing a type declaration.
Nested malformed values still throw. A declared contentType keeps its strict
typed decoder; absent/null content retains the legacy default. Bare JSON cannot
distinguish base64 text from Data; Data needs the existing base64 contentType.

## D256 legacy Object correction (source change; execution pending)

W30b exposed a missing context handoff: the legacy `WireObject` dictionary
decoded each child as generic `ValueType`. Since D252 removed coding-path-based
dispatch, a primitive child named `&keyValue` became an integer instead of being
validated as KeyValue. The unchanged D239 rejection witness failed after a
successful build. The earlier D252 focused selection omitted D239SchemaDecodeTests.

The candidate now explicitly selects the child marker decoder in the legacy
dictionary branch, as generic wire Object decoding already did. Only
`&objectEntries` entries treat property names as literal data and select types
from the entry's `type`. Thus legacy `&object:{"&keyValue":0}` must throw,
while an explicitly encoded application property named `&keyValue` with integer
value 0 remains legal. Valid typed legacy children, null and unknown properties
retain their compatibility contract.

The same branch is reached through KeyValue.object, nested Object/list entries
and untyped FlowElement content. FlowElement's six declared Object content types
now also decode through WireObject. Its Object encoder uses WireObject too, so
valid marker-named application properties get explicit representation. Ordinary
unambiguous Objects retain plain JSON. Producer and consumer changes are coupled:
strict legacy validation without explicit producer encoding would reject valid
FlowElement values such as an application property named data containing 1.

New D256 tests cover those contexts, nonselected typed fields, exact variants,
positive producers, and both AgentD transport entrypoints. The focused driver
includes eight independent removals and the original D239 witness. These are
source changes and planned checks, not executed green results: consult
`HAVEN-Deploy/_handoff/ARBEIDSBENK/D256-D239-REGRESJON-RETTET.md` for the actual
candidate, execution status and remaining W30c gate. W30b's red evidence is in
`D255-W30B-STOPPED-EVIDENCE/result.json` in that handoff directory.
