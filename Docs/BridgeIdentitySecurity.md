# Authenticated bridge channels and identity-origin proofs

Last verified against code: 2026-09-27, 5232688fdfda08d36e00227df15acfdfd0e8eeef.

## Admission precedes every Cell operation

`BridgeChannelTransport` implements `org.haven.bridge-channel.v1` around a physical
transport. `BridgeBase` and `BridgeMultiplexServerSession` fail closed without a
verified `BridgeChannelSession`. A wire `ready` cannot authenticate either side.
The state machine is unauthenticated → challengeIssued → verifying → authenticated
→ closed/revoked. A host's Cell factory runs only after proof verification and the
host's optional awaited revocation-policy check. The gate rechecks its generation
and deadlines after that await and after factory creation.

This is a wire compatibility change. Existing raw BridgeBase hosts, including
separately authorized native-porthole/Admin/entity-data routes, must compose their
existing admission with this gate before consuming network commands. There is no
ready-only fallback. This CP change does not register or deploy any application
route and does not replace those routes' separate contract/evidence requirements.

Dedicated and multiplex connections prove one immutable public principal per
physical connection. `openChannel` and later commands must present the same UUID,
algorithm, curve and public key. Missing/mismatched command identities are denied.
Responses may omit identity because they are correlated with pending commands;
a present identity must match. Client-side inbound traffic is limited to responses,
scoped origin-proof requests and multiplex control replies. No Cell grant is
created by successful transport admission.

## Handshake and canonical transcript

The client locally selects a canonical WSS URL and the transport domain (`bridge`
for CellResolver), then starts `BridgeChannelClientOperation`. Its hello contains
only profile, a random 32-byte client nonce and `PublicIdentity` (UUID, signing
algorithm, curve, public signing key). It does **not** encode `Identity`, properties,
grants, vault references, display names, private keys or key-agreement keys.
Normal outgoing command identities also use public snapshots, excluding private
properties and vault references. The separate local proof lease keeps its local
vault reference only in process; serializing a public descriptor does not broaden it.

The server issues a fresh 32-byte CSPRNG nonce, session ID, generation, issued time
and absolute channel expiry. The signed `IdentitySigningChallenge` keeps its
existing type/version/purpose and uses `action = openBridgeChannel`, the exact
transport domain, `audience = canonical origin + route`, and
`resource = org.haven.bridge-channel.v1:<SHA-256(canonical transcript)>`.

The transcript is a canonical JSON object: sorted keys, unescaped slashes, base64
Data, and integer milliseconds. Its fields are profile, endpoint (origin, route,
domain), minimal public identity, both nonces, session ID, generation, direction
(`client-to-server`), issued time, and absolute channel expiry. Route includes the
publisher and bridge ID. The existing challenge's own sorted-key encoding is used
for its exact signed bytes. Auth envelopes reject unknown/duplicate fields and
noncanonical encodings by decoding and re-encoding byte-for-byte. The wire carries
four BridgeCommands with cid=0, no identity or multiplex metadata, and a string
payload containing the canonical JSON: `channelAuthHello`, `channelAuthChallenge`,
`channelAuthProof`, `channelAuthAccepted`.

The client reconstructs and compares the complete transcript before asking its
own explicitly configured local vault to sign. This single-use connect permit
cannot be created by a `.sign` command. It cannot sign arbitrary bytes or another
origin/domain/route/principal. Cancellation and timeout are rechecked after the
vault await. The server verifies with `IdentityPublicKeySignatureVerifier` only;
it never selects a client signer or local user vault. The proof identifies existing
connection-owned pending state; it does not supply replacement challenge bytes.
Consumption precedes verification, so at most one concurrent proof can win.

The server has a local monotonic 10-second pre-auth deadline. The challenge has a
30-second signing lifetime and the channel expires after at most five minutes.
Both monotonic and absolute checks are repeated at activation and dispatch. A
restarted process, another connection or another generation has no matching pending
state, so an old proof cannot resume a channel.

## Host composition API

Share one `BridgeChannelLimits` across public routes. A configured public URL,
trusted network source, and local route selection precede the factory; neither
Host nor arbitrary Forwarded headers establish the signed audience.

```swift
let admission = try BridgeChannelTransport(
    underlying: physicalTransport,
    endpoint: .init(url: configuredPublicURL, domain: "bridge"),
    limits: sharedLimits,
    source: trustedSocketOrProxySource,
    recheckPolicy: { publicIdentity in
        try await currentTransportRevocationPolicy.check(publicIdentity)
    }
) { admittedTransport, session in
    // First place a Cell/Resolver lookup or BridgeBase may be constructed.
    let bridge = try await BridgeBase(.init(
        owner: localServiceIdentity,
        transport: admittedTransport,
        connection: .inbound(publisherUuid: locallyAllowedPublisher),
        inboundPublisherLookupIdentity: localServiceIdentity
    ))
    try await bridge.setTransport(admittedTransport,
        connection: .inbound(publisherUuid: locallyAllowedPublisher))
    return bridge
}
```

Retain the admission object for the connection. For multiplex, the factory returns
`BridgeMultiplexServerSession(physicalTransport: admittedTransport, bridgeOwner: …)`;
its logical transports inherit the same verified session. Closing one logical
channel cancels its work and releases its quota without revoking sibling channels.
The factory receives the minimal proven principal, not wire-supplied metadata.
The service identity is
only an explicit local publisher lookup identity, never a replacement requester.

The reusable `BridgeChannelSession.reserveOpen`, `recheckBeforeActivation`, and
`activate` sequence generalizes CellScaffold's `PersonEntityReadRouteCoordinator`
reservation/recheck/activation pattern. That application must retain its person
link evidence and scope checks, and compose them in its admission/recheck step.
Its HTTP-upgrade proof alone must not be turned into a ready-only exception.

For Vapor ingress, use `VaporBridgeTransport(webSocket:closeUnderlyingChannel:)`
and supply `{ try? await ownedNIOChannel.close().get() }`. Reuse the existing
PersonEntityRead upgrader's frame/reassembly/error-close pattern to obtain that
channel. A WebSocket close frame alone depends on peer cooperation. The generic
Vapor route helper does not prove those production ingress bounds. Install the
gate synchronously in the upgrade callback before accepting peer messages.

CellResolver wraps both dedicated and multiplex outgoing transports automatically.
A direct client can construct the client initializer of `BridgeChannelTransport`,
attach BridgeBase, then call `setup`. `ws` is allowed only for an explicitly enabled
loopback development endpoint. User-info, query credentials, fragments, noncanonical
paths and ambiguous explicit default ports are rejected. TLS certificate/hostname
validation remains the physical adapter's responsibility; production adapters must
not redirect or substitute an insecure transport.

## Lifecycle, quotas and retained state

Before authentication the server retains one bounded public hello/challenge per
connection, generation, deadline and quota reservation. After authentication it
retains only the minimal immutable public principal, endpoint, session/transcript
digest, expiry and bounded operation/feed/channel accounting. Pending signature
bytes are discarded after verification. There is no persisted client key, bearer
token, server-side client signer or positive Cell authorization cache.

Shared limits cover total connections, pending handshakes, pending handshakes per
trusted source, and connections/operations/feeds/logical channels per proven
(domain, UUID, fingerprint). Pending sends have per-connection and global byte
bounds. Fixed 60-second rate windows survive socket closure: defaults are 512
attempts globally, 60 per trusted source and 12 verified handshakes per proven key.
Rate buckets are bounded (4096); unknown sources cannot evict unexpired buckets.
Unproved UUIDs never consume a victim's key-specific bucket. These are configurable
starting values, not measured production capacity.
Pre-auth wire envelopes are limited to 16 KiB; ordinary bridge payload
limits still apply. The host must also bound WebSocket frames, accumulated fragments
and ingress task/CPU scheduling **before** JSON decoding. Transport-side limits do
not establish those host-level bounds by themselves.

The GeneralCell signing replay store is bounded (default 4096), rejects new entries
at capacity, and retains still-valid consumed entries. Pending BridgeBase requests
are bounded (default 256). Feed send work is bounded and captures its generation;
revoked/expired generations cannot enqueue new deliveries. Local host policy can
call `session.revoke()` or `sharedLimits.revoke(identity:domain:)`. Closing, expiry,
transport loss and replacement invalidate the session and local proof leases and
cancel feeds and fail pending callbacks. Suspended old replies retain their old
transport; a late close callback cannot invalidate a replacement generation.
Concurrent feed admissions are bounded, and closure is rechecked after awaiting
the Cell's stream. The physical transport is released on close.

`sharedLimits.revoke` invalidates currently admitted leases; it is not a durable
revoked-key database. The host must supply authoritative current key/link policy in
`recheckPolicy` to deny subsequent reconnection when required. No global revocation
propagation or host-policy freshness guarantee is inferred from local invalidation.

`BridgeBase.renewAuthenticatedChannel(requester:)` explicitly starts a new dedicated
physical connection and fresh proof. `using:` may supply a fresh configured physical
adapter; it must not reuse an adapter still owned by another connection. It ends
the old streams and pending work;
subscriptions and writes are not automatically replayed. Expired resolver cache
entries and multiplex pool sessions are replaced on a new client resolution.
A failed send is surfaced; an already-issued write may have an unknown outcome.
The caller must reconcile it, not retry blindly. Application heartbeat/drain,
revocation-source freshness and measured ≤30-second recovery are integration checks
for CellScaffold/HavenAgentD/staging, not claims established by these unit tests.

## Cell-origin proof authority remains narrow (V1)

Transport admission does not replace Cell authorization. A Cell may still request
an origin proof through `BridgeIdentityVault` while a locally initiated operation
holds its existing proof lease. The accepted profile remains
`checkIdentityOrigin` / `GeneralCell`, with exact principal/domain/Cell UUID. No
`VerifiedRequesterContext` or broader `.sign` authority is introduced. Closing or
replacing the transport invalidates an in-flight signature before delivery.

Every incoming Apple, Lightweight and Vapor identity descriptor receives a
`BridgeIdentityVault`, including exact matches to keys held locally and absence
of a delegate. It cannot borrow local signing authority. The authenticated Vapor
path does not add pre-auth descriptors to the global visiting identity registry.

## Security boundary and evidence

V2 deliberately trusts the TLS terminator and server process after admission.
Commands are **not** individually signed end-to-end. A compromised trusted proxy
or runtime can alter subsequent operations. Keeping the user's private key local
does not establish protection against either compromise.

`BridgeChannelAuthenticationTests` covers canonical public envelopes, real local
signing with a server signer trap, immutable principals, replay/concurrent consume,
time, scope, cancellation, quota release and bounded replay state.
`BridgeChannelTransportTests` covers pre-auth dispatch/factory denial, paired wire
handshakes, V1 Cell proof, multiplex principal binding, revocation during an awaited
policy check and local/bridge Cell authorization parity. Existing origin-proof and
transport-provenance tests remain regression requirements.

`BridgeChannelWebSocketTests` additionally exercises real Vapor/WebSocketKit TCP
loopback framing, rejects a first unauthenticated command, and completes a protected
read with an instrumented server signer that must never run. This explicitly local
WS test is not production TLS/proxy evidence. Vapor outgoing setup waits for actual
socket installation, not just the upstream HTTP upgrade future. Its waiter is
bounded/cancelled; cleanup of a peer stalled before upstream WebSocket upgrade also
requires adapter/host-level connection timeouts and remains a load-test obligation.

Actual proxy hardening, real client WSS paths, staging recovery and release readiness are separate AP5–AP9
integration evidence. See the PDD handoff for exact test/CI results and open findings.
