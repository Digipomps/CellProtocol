# Cross-runtime wire fixtures

`BridgeCommandSetString.v1.json` is an exact semantic JSON round-trip fixture.
Supported runtimes must decode it as a `set` bridge command with command ID 7
and a typed string `KeyValue`, then encode the same JSON object. Object member
ordering and insignificant whitespace are not contractual.

`CellConfigurationMinimal.json` is a decode-compatibility fixture. It
deliberately omits `uuid`; each runtime must generate a valid non-empty UUID and
decode the same configuration, reference, key/value, and Skeleton semantics.
It is not an exact re-encoding fixture: current runtimes normalize legacy
generic values and generated fields differently, and this fixture does not
adjudicate whether those differences are compatible. Do not describe it as
canonical round-trip JSON until those encoding semantics are standardized.

`UserDataErasureSetDescriptor.v0.json` is the deterministic 4+2 Reed-Solomon
descriptor for UTF-8 payload `HAVEN user data erasure fixture v0`. Other
runtimes must produce the same payload hash, set ID, shard sizing, and six
metadata-bound fragment hashes. Object member ordering and whitespace are not
contractual.

`DeviceIngressChallenge.v3.b64`, `DeviceIngressRequest.v3.b64`,
`DeviceIngressSignedContract.v3.b64`, and `DeviceIngressResponse.v3.b64` are
one byte-pinned, cryptographically bound DeviceIngress registration exchange.
The requester's locally derived response expectation, not server-provided
admission metadata, is the response-verification authority. The v1 and v2
envelope fixtures remain pinned negative vectors and must fail closed.
