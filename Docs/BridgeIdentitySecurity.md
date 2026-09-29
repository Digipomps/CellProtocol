# Authenticated bridge channels and identity-origin proofs

Updated: 2026-09-29 for PR #53 through N26 and peer v3. Build, test and CI evidence is in the PDD `CP53-SAMLET.md` handoff, including its remaining iOS/NI limits.

## Admission precedes every Cell operation

For WS, `BridgeChannelTransport` implements `org.haven.bridge-channel.v1` around a physical
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

Local `EphemeralIdentityVault` binds its vault reference during explicit identity
creation/insertion. Looking up an already published identity does not rewrite its
shared metadata while bridge/resolver callers read it. The actor protects its
maps; it does not make arbitrary external mutation of the returned Identity safe.
UUID-only lookalikes still fail public-key matching before local signing.

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
Both monotonic and absolute checks are repeated at activation and dispatch.
The client accepts issuance at exactly +5 seconds, rejects issuance at −30 seconds,
and rechecks the challenge after the awaited local signer. Server activation also
rechecks the original challenge's wall-clock expiry after awaited policy. A
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
channel retires its transport without revoking sibling channels. Its quota is
released only when the channel record and already-started work have finished.
This also holds if close arrives while the host channel factory is suspended;
the canceled opening sends no stale acknowledgement or rejection.
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

## Diagnostic privacy

Bridge diagnostics use bounded, allowlisted metadata (recognized command type,
numeric cid, byte length and fixed failure codes). Unknown command names map to
`none`; peer-supplied labels, UUIDs, descriptions, payloads and arbitrary Error or
publisher-completion descriptions are not logged. Apple/Vapor transport failures
and WebSocket ping failures follow the same rule. Diagnostic logging remains
opt-in, but enabling its handler does not permit plaintext payload dumps.

`BridgeDiagnosticPrivacyTests` exercises every Base payload-mismatch/unknown-cid
site and malformed-description decoding with synthetic secret markers. Adapter
tests inject an NSError whose domain and description both contain a marker.
This is a diagnostics guarantee, not a promise to sanitize application responses,
security-event stores, external delegate implementations or all other log domains.

## Lifecycle, quotas and retained state

Before authentication the server retains one bounded public hello/challenge per
connection, generation, deadline and quota reservation. A verified proof awaiting
host policy still occupies pre-auth capacity until full activation. After authentication it
retains only the minimal immutable public principal, endpoint, session/transcript
digest, expiry and bounded operation/feed/channel accounting. Pending signature
bytes are discarded after verification. There is no persisted client key, bearer
token, server-side client signer or positive Cell authorization cache.

Shared limits cover total connections, pending handshakes, pending handshakes per
trusted source, and connections/operations/feeds/logical channels per proven
canonical signing key. This accounting ID hashes a domain-separated tuple of
algorithm, curve and normalized public-key bytes: P256 compressed and X9.63
encodings normalize to compressed P256; Ed25519 uses its raw 32-byte encoding.
The channel accepts only those two signing-key types. UUID, authorization domain,
route and transport profile are excluded from this process-local accounting ID;
rotating them does not reset a key's quota or rate window, including across WS
and peer sessions sharing one limits owner. It is never sent, logged or used as
an authorization/revocation principal. Those checks still bind the original
(domain, UUID, fingerprint) and exact public identity. Pending sends have
per-connection and global byte bounds. Fixed 60-second rate windows survive socket closure: defaults are 512
attempts globally, 60 per trusted source and 12 verified handshakes per proven key.
Rate buckets are bounded (4096); unknown sources cannot evict unexpired buckets.
Unproved UUIDs never consume a victim's key-specific bucket. These are configurable
starting values, not measured production capacity.

Regression rule: a verified identity principal is not a canonical key. Quota tests
must vary UUID, domain, transport profile and every supported encoding while
holding the signing key fixed. Fill the limit, reject limit+1 repeatedly, retain
closed owners with live leases, and prove an independent key still works.
`BridgeCanonicalKeyQuotaTests` executes these checks with actual signed WS and
peer challenges at the shared session boundary. It does not simulate MC delivery
or replace transport-level acceptance tests.
Send-suspension fixtures must match decoded response type/cid/payload, not bytes
from independent ordinary JSONEncoder calls: JSON object-key order is not fixed.
`BridgeChannelLifetimeQuotaTests.testPendingSendBarrierMatchesResponseFieldsIndependentOfJSONKeyOrder`
pins two equivalent orders and rejects mismatched fields. This does not relax
exact-byte checks for canonical signing transcripts or authenticated records.

Closed socket records remain in the bounded accounting table while any operation,
feed, logical channel, pending admission/factory, send bytes or physical close is
still outstanding. Admission counts these retained records. Cancellation is
requested for tracked transport work; a cancellation request does not release its
reservation. Non-cooperative awaited code keeps its reservation until it returns.
Global defaults additionally cap Cell operations at 256, feeds at 128, logical
channels at 256 and tracked work at 512 (64 per connection). Completed work removes
its closed record; there is no ever-growing retired-ID set. Client and server
stream-order backing arrays are also compacted when channels are repeatedly
removed/reopened; retaining one sibling cannot keep an unbounded history of
retired stream IDs. Feed delivery tasks
reserve operation capacity before they are enqueued. Feed and logical-channel
leases release exactly once, including after replacement or natural completion.
An exhausted global budget denies new work; these limits do not promise service
under unlimited Sybil load. Tests demonstrate independent service while capacity
remains and recovery after the retained work completes.
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
the Cell's stream. The physical transport reservation remains until its close actually returns.

`sharedLimits.revoke` invalidates currently admitted leases; it is not a durable
revoked-key database. The host must supply authoritative current key/link policy in
`recheckPolicy` to deny subsequent reconnection when required. No global revocation
propagation or host-policy freshness guarantee is inferred from local invalidation.

`BridgeBase.renewAuthenticatedChannel(requester:)` explicitly starts a new dedicated
physical connection and fresh proof. `using:` may supply a fresh configured physical
adapter; it must not reuse an adapter still owned by another connection. It ends
the old streams and pending work;
subscriptions and writes are not automatically replayed. Logical server sends
compare the original transport object with the active channel record, so reuse of
a wire channel ID cannot admit an old response. Sign denials capture the original
transport before awaiting auditing, just like successful replies. Bytes already
accepted by an underlying socket cannot be recalled; neither close nor revocation
rolls back a Cell mutation that already occurred. Expired resolver cache
entries and multiplex pool sessions are replaced on a new client resolution.
The security-bound pool shares live unauthenticated/verifying setup as well as
active sessions. Closed, revoked and expired sessions cannot be reused; replacement
retires the previous pool entry. A shared setup failure reaches all waiters, and a
later resolution starts a fresh session.
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
socket installation, not just the upstream HTTP upgrade future. Each outgoing
Vapor connection owns one NIO event-loop thread, allowing timeout/close to terminate
TCP even before WebSocket upgrade. A second real-socket test stalls the HTTP
upgrade and verifies close completes within five seconds. Outgoing Vapor frame and
reassembly size are bounded at 1 MiB with at most 128 accumulated fragments. This
has a per-connection thread cost; capacity tuning and server ingress load evidence
remain host integration obligations.

Actual proxy hardening, real client WSS paths, staging recovery and release readiness are separate AP5–AP9
integration evidence. See the PDD handoff for exact test/CI results and open findings.

## AP9a regression evidence and explicit limits

The R1/R2/R4 suites include same-channel-ID/cid reuse during suspended get/set/sign
rejection, actual dedicated renewal with an old sign rejection, retained quotas
across non-cooperative policy/factory/Cell/feed/send/close, multiple independent
signing keys, and parallel **CellResolver** resolutions sharing a suspended real
client auth wrapper. Command admission enumerates all 29 `Command` cases in both
directions, plus independent response entry and well-formed authentication order
failures. Lookup instrumentation counts actual `cellAtEndpoint` calls separately
from unregister/cleanup. Scope tests regenerate canonical signing bytes for each
changed publisher/bridge ID/host/environment/domain. Clock tests separate wall and
monotonic motion, and check exact skew boundaries.

`BridgeChannelProcessTests` starts a separate macOS XCTest server process and uses
real loopback WebSockets. It receives only the public client descriptor, has an
instrumented signer trap, performs a protected owner read using the client's
scoped signer, and inspects wire/persisted/log artifacts for a synthetic private
marker. The public SecureKey discriminator `privateKey:false` is valid; actual
private-key values are rejected by the artifact check. This test is macOS-only;
its worker test runs only as a child of the parent test.

The action-parity test executes a Cell action requiring `--x-` and calls actual
`GeneralCell.attach` through a protected Cell action. It checks wrong permissions,
keypath, domain, expired/revoked contracts and purpose. It does **not** certify the
legacy `BridgeBase.attach` → `connectEmitter` wire API: the existing receiver has no
`connectEmitter` handler. That separate generic attach capability remains
unsupported; no new reverse-bridge authority was added to make this test pass.

ScannerService now uses the explicit mutual peer profile below (R3); Binding's
custom transport remains separate consumer work (N05). WS-adapter tests alone
do not certify either consumer. Host ingress fragment/CPU limits,
drain, production TLS/proxy and real consumer deployment remain AP5–AP9b evidence.


## Multipeer peer profile (R3, N22 v3)

`org.haven.bridge-peer-channel.v3` is separate from the WS profile. The accepted
invitation supplies E (both endpoint names, setup UUID and domain). The physical
adapter and pending/accepted invitation retain their exact peer/session/endpoint
instance; acceptance is atomic and independent of the discovery index. Discovery names and MCSession possession grant no
identity or Cell authority. MCSession encryption remains required.

The identity-free M1 and M2 hello fields bind fresh X25519 keys, nonces, roles,
generations and times. Authentication identities, endpoint and signatures are
inside fixed-size encrypted M2/M3 blocks, with separate identity MACs. The
initiator verifies and accepts the responder before its local vault signs M3.
Scanner explicitly chooses first contact with any proven identity. An active
initiator can learn the responder in M2; an accepted active responder can learn
the initiator in M3. This is not discovery anonymity or a trusted person binding.

Both Finished messages must be locally validated at their specified stages.
Initiator activates after submitting M5; responder activates after receiving M5.
Separate application keys derive from the complete T5 transcript; HPC3 record
counters start at zero after the handshake. All app frames use authenticated
ChaCha20-Poly1305, exact direction/generation/counter checks and terminal failure.
Both signatures bind both hello/DH values, while only I's signature contains both
identities. Finished and application keys bind the whole exchange. Peer v1/v2,
HPC2, ready, plaintext fallback and cross-profile messages are rejected.

The authoritative [v3 wire and security contract](../Documentation/BridgePeerChannelV3.md)
defines the five messages, exact encodings, key schedule, disclosure policies,
padding and limits, with linked consumer, NI and physical-resource contracts. Local vault signing
and Cell authorization remain separate; no remote signer or dependency is added.

WS `reserveOpen` consumes its pending challenge before public verification.
Peer v3 registers its principal only after validating encrypted Auth, identity MAC
and signature; both profiles retain the same session authority and quota owner. Its deadline, absolute expiry, principal binding,
revocation, activation and retained resource accounting are shared. The transport
uses the existing tracked-work, send-byte, cancellation and close machinery.
Scanner services share one default limits owner; a host may inject its existing
limits owner. Local setup work also uses the transport's retained work budget.
There is no peer `ready` exception. New peer setup requires a fresh accepted
invitation and proof; WS renewal does not fabricate a peer URL.

A peer session has two proved principals: the remote requester and the locally
initiated signer. Incoming Cell requests match the remote principal; outgoing
requests match the local principal. Only `sign` callbacks and responses use their
corresponding local-request identity. The existing narrow GeneralCell proof permit
still applies to signing callbacks. No incoming descriptor receives a local vault.
`session.endpoint` is optional for peer sessions; WS users retain the typed WS
endpoint and peer users have `peerEndpoint`.

Scanner installs only the gate before proof. Base creation, resolver access and
registration, description and lobby attachment follow proof. Auth frames are
processed before the ordinary Command enum; the pre-auth bound is 16 KiB.
Disconnect cancels setup and closes that physical generation. Old transports
cannot send through a replacement, and registration teardown finishes before a
replacement reuses the remote cell UUID. Consumer status reports `authenticating`,
then `connected` after setup, or `bridgeFailed:<reason>` on failure.

`ScannerPeerAuthenticationTests`, `ScannerServiceInvitationTests` and
`EntityScannerCellContractTests` cover controlled delivery, actual LobbyCell
attachment/feed, owner-approval denial after valid proof, replay, role/peer/setup binding, reconnect, revocation,
quota exhaustion, retained work and proxy provenance. The opt-in
`ScannerMultipeerProcessTests` runs real discovery, encrypted MCSession and Scanner
setup in two separate processes, with each process as inviter in turn. Its fixture
explicitly configures owner-published read grants for the Lobby; authentication
does not grant those rights. See [Scanner Multipeer verification](ScannerMultipeer.md).

N06: a resource lease starts without ownership. Only successful acquisition arms
release, including throwing initialization/deinitialization. Same-session tests
hold an existing lease while repeatedly rejecting feed/channel acquisition at
per-key and global limits, exercise actual mux open/reject/open, and check close
plus late/double completion. Rejected acquisition cannot release another owner.
