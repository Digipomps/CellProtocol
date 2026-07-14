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
