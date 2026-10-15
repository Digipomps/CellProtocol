# Explicit Object values on the bridge wire

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
