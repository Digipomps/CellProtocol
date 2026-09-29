# Scanner Multipeer verification

The authoritative peer wire description is [Peer channel v3](../Documentation/BridgePeerChannelV3.md).
It specifies the five handshake messages, encrypted identity disclosure, HPC3
records and the mandatory receipt framing. Both endpoints must implement the
current v3 contract. Peer v1/v2, HPC2, plaintext application messages and ready
are rejected without fallback. WS retains its separate v1/TLS profile.

## Admission, identity and consumers

A contact invitation carries the endpoint (initiator, responder, setupID, domain)
and requires explicit user acceptance. Crossed invitations choose the
lexicographically lower session peer ID as initiator; the incoming winner still
requires acceptance. Nil-context legacy invitations cannot create a bridge.
Advertisement exchange remains a separate path.

Pending, accepted and outgoing invitations own their immutable physical peer,
MCSession, endpoint, role and local invitation instance independently of discovery.
Acceptance is atomic; unfinished setups expire. Discovery loss or another peer
advertising the same UUID cannot retarget this ownership. Process-wide count,
byte, rate and TTL limits apply before storing discovery/invitations or scheduling
work. The [admission and ordering contract](../Documentation/ScannerAdmissionAndOrdering.md)
defines these limits and their physical-source/Sybil boundary.

Each endpoint signs only through its own local vault. Scanner explicitly permits
first contact with any proven identity and responder disclosure to an unauthenticated
initiator. A pure inner-handshake relay cannot read stable identity fields; an
active initiator learns the responder, and an accepted active responder learns the
initiator. This does not establish a person, proximity or discovery anonymity.
Incoming identities use public proxy vaults even when they copy a local owner key.

Base creation, resolver lookup, registration, description and Lobby attachment
follow proof and Finished validation. Configure Lobby grants/admission separately:
channel authentication grants no Cell rights. The standard channel lifetime is
five minutes; renewal requires a new invitation and proof. A host sharing budgets
with other bridge routes should inject the same `channelLimits`. Its
`revoke(identity:domain:)` terminates currently registered remote principals
(`domain: "nearby"`); it is not a persistent key blacklist or local-owner revocation.
Local owner revocation closes the associated gates; future admission needs host policy.

Ordered application delivery extends beyond record opening through the awaited
consumer. Origin-signing RPC has a separate scheduling lane so it can answer an
operation waiting on proof. [EntityScanner consumer security](../Documentation/ScannerConsumerSecurity.md)
binds work leases and bounded pending contact/detail records to the exact principal,
physical context and generation. Contact acceptance validates every request/proof
binding and consumes pending state once before encounter persistence.

## Retirement and resource boundaries

One encrypted MCSession belongs to each physical peer/invitation. Close disconnects
that exact session and retains transport/send reservations until its local
`connectedPeers` is empty. A healthy sibling has a separate session. Stream inputs
are closed and resource Progress objects cancelled at the first callback; these
side channels are unsupported. [Physical flow control](../Documentation/PeerPhysicalFlowControl.md)
defines retained wire-byte windows, bounded encrypted receipts and the ten-second
missing-progress timeout. Successful MC enqueue alone releases no data send quota.
MC reassembly happens before the Data callback: these app limits do not prove a
hard preallocation/total-OS-memory ceiling or instantaneous remote disconnect.

Old callbacks captured on a retired adapter cannot affect its replacement.
Old ciphertext delivered to the **current** adapter, including rewritten generation
or counter headers, is a terminal error for that gate. Inner `peerGeneration`
remains mandatory for ordinary peer commands; auth and WS frames omit it.
[Shared bridge lifetimes](../Documentation/BridgeLifecycle.md) cover response
publication, mux ID reuse, late factories and signing deadlines for WS and peer.

[NearbyInteraction binding](../Documentation/ScannerNearbyInteraction.md) uses one
NI session per authenticated physical context. Tokens travel through the same
encrypted gate to one captured peer and bind the full principal, shared setupID,
channel and NI generations. Replaced tokens are rejected; close/revoke/stop retire
NI, and late callbacks cannot affect a new generation. macOS fake-driver tests
exercise association and lifecycle. Native token archive/decode, iOS compilation
and physical UWB measurements require separate evidence.

## Repeatable checks

Run the workspace build-capacity guard before Swift commands; use the repository's
locked dependencies. Deterministic suites include:

```sh
swift test --disable-automatic-resolution --filter 'Scanner|EntityScannerConsumerSecurityTests|BridgePeer|BridgeResponseLifetimeTests|BridgeMuxSendLifetimeTests|BridgeFactoryLifetimeTests|BridgeSigningLifetimeTests'
swift test --disable-automatic-resolution --sanitize thread --filter 'EphemeralIdentityVaultConcurrencyTests|PublisherAsyncLifetimeTests|BridgeDescriptionConcurrencyTests|EntityScannerConsumerSecurityTests|ScannerNearbyInteractionTests|ScannerPeerAuthenticationTests|ScannerServiceInvitationTests|ScannerAdmissionTests|BridgePeerV3Tests|BridgePeerRecordLayerTests|BridgePeerFlowControlTests|BridgeMultiplexingTests|BridgeMuxSendLifetimeTests|BridgeResponseLifetimeTests|BridgeFactoryLifetimeTests|BridgeSigningLifetimeTests'
CP53_MULTIPEER_TEST=1 swift test --disable-automatic-resolution --filter ScannerMultipeerProcessTests/testTwoProcessesUseRealMultipeerInBothInvitationDirections
```

The macOS opt-in parent runs real MC in both invitation directions, Lobby
description/attach/feed, and a separate three-process physical isolation workload:
resource/stream rejection, handshake expiry, authenticated revoke and missing
receipts while a healthy sibling continues. A further three-process relay places M
on two separate encrypted outer MC sessions. It uses a test MC adapter around the
production v3 gate/session/record implementation, verifies both principals and
ordered application data, and inspects the actual inner wire at M for the five
strict schemas and fixed-size encrypted identity blocks. It is separate from the
production Scanner-adapter scenarios. Parent/worker logs and `.passed`
markers are printed under temporary artifact directories. Each endpoint keeps
its synthetic private signing key in its own process. Ordinary CI skips the
existing opt-in parent/worker; it provides no native MC or NI claim.

Read the exact-head results in the CP53 handoff. Deterministic tests, TSAN, native
processes on one Mac, iOS builds, physical phones and production are distinct
verification boundaries. No absolute security or production approval follows from
a green package suite. `ConnectServiceDelegate.scannerStatusChanged` and
`scanner.status` report attachment failures.

If native discovery fails, inspect both worker logs and the process host's
local-network access. App hosts need `NSLocalNetworkUsageDescription` and the
`_haven-radar._tcp` Bonjour service; see [Apple Multipeer documentation](https://developer.apple.com/documentation/multipeerconnectivity)
and [local-network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

Consumer discovery lifetime, outgoing probe reply binding, terminal status and
per-peer aggregate connection snapshots are specified in
[consumer security](../Documentation/ScannerConsumerSecurity.md#discovery-retention-and-outgoing-probes-n28n29)
and [Scanner admission](../Documentation/ScannerAdmissionAndOrdering.md#terminal-status-and-connected-snapshots-n32n33).
Their application-owned bounds do not establish a hard MC reassembly/RSS limit.
