# Host-pinned resolver proof scopes

`CellResolver.cellAtEndpoint(endpoint:requester:identityProofScopes:)` opens an
explicit `ws://` or `wss://` endpoint with exact local identity-origin proof
scopes. This is an additive host API; the ordinary overload is unchanged.

```swift
let bridge = try await resolver.cellAtEndpoint(
    endpoint: trustedEndpoint,
    requester: localIdentity,
    identityProofScopes: [
        .init(domain: trustedDomain, resource: knownCreationName),
        .init(domain: trustedDomain, resource: knownCellUUID)
    ]
)
```

The host must know and authorize those exact domain/resource pairs independently
of incoming configurations, descriptions and signing challenges. The argument is
not Codable, persisted, installed as global resolver policy, or read from a
CellReference. Known child Cells need their own exact pairs. A name is not an
alias for a later UUID challenge. This API does not solve discovery of unknown
identity-unique Cell UUIDs.

Pins are passed unchanged to `BridgeBase.Config.identityProofScopes`. An empty
array explicitly denies every identity-origin scope. The existing overload uses
nil and retains its existing discovery behavior. Cache and pending-task keys
include the pin **set**, in addition to endpoint and proven principal. Different
sets, including nil versus empty, cannot reuse the same bridge; order and
duplicate entries do not create different policies. Pins apply only to the
returned bridge and do not influence later ordinary reference loading.

The local requester proof, live holder/channel handshake, ready requirement,
signing containment, exact challenge validation, operation leases, expiry and
revocation checks are unchanged. This does not grant a server-side capability or
enable a legacy peer to bypass channel authentication. `cell://` endpoints are
rejected by the new overload; their route APIs remain unchanged.

`ResolverPinnedProofScopeTests` uses real loopback WebSockets and an authenticated
server with a fresh client identity. Its fixture pins a known creation name and
Cell UUID, checks description and GET, rejects another domain/resource, an empty
set and a name-only pin, and verifies that an ordinary lookup cannot inherit a
previously pinned bridge. The fixture's known UUID is intentional; it does not
prove automatic bootstrap of arbitrary server-generated UUIDs.

This candidate is local WP8b work. Its full-suite and Palazzo integration
results are recorded separately in the WP8b handoff; these tests are not a claim
that the Palazzo app flow works.

## HTTP upgrade credentials (WP8c)

`VaporBridgeTransport(upgradeHeaders:)` accepts host-selected HTTP headers for
WebSocket upgrade, e.g. an Authorization bearer header. The default is empty.
These headers do not become part of `BridgeChannelAuthentication.Endpoint`,
identity proof scopes, or Cell authority. Query-bearing canonical endpoints
remain rejected. The local host must bind credentials to its intended destination.

The resolver's type-based transport registration can use a host adapter whose
`new()` supplies that policy. Forward `setDelegate` directly to the physical
Vapor transport: wrapping its gate delegate hides type-dependent lifecycle and
origin-signing dispatch checks. Channel renewal calls the registered type's
`new()`; a bare `VaporBridgeTransport.new()` intentionally has no credentials.
This addition does not establish a name-to-UUID bootstrap authorization contract.
