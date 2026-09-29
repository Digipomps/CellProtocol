# Scanner Multipeer verification

ScannerService keeps its existing discovery, invitations, MCSession, Lobby and
EntityScanner/ConnectRadar composition. The peer gate is installed on the existing
ScannerPeerTransport. A contact invitation must carry the explicit peer-profile
endpoint and receive the existing user acceptance. Crossed invitations select the
lexicographically lower session peer ID as initiator; the winning incoming
invitation still requires acceptance. Legacy nil-context invitations cannot set
up a bridge. Advertisement exchange remains a separate existing path.

Both peers need identities backed by their own local signing vaults. Inbound
identities are public proxy identities even if their keys match a local owner.
Configure Lobby grants/admission on the host as usual: peer authentication grants
no read, write, subscription or owner permissions. Failed attachment is observable
through `ConnectServiceDelegate.scannerStatusChanged` and `scanner.status`.
The host should inject a common `channelLimits` when sharing budgets with other
bridge routes, and call its `revoke(identity:domain:)` for authoritative key
revocation (`domain: "nearby"`). The standard channel lifetime is five minutes;
renewing a peer connection requires a new invitation/proof.

## Automated checks

```sh
swift test --filter 'ScannerPeerAuthenticationTests|ScannerServiceInvitationTests|EntityScannerCellContractTests'
CP53_MULTIPEER_TEST=1 swift test --filter ScannerMultipeerProcessTests/testTwoProcessesUseRealMultipeerInBothInvitationDirections
```

The second command is macOS-only and opt-in. It starts **two separate XCTest
processes** with no mock delivery, waits for real discovery and MCSession, performs
the mutual proofs, retrieves Lobby description, attaches using GeneralCell and
asserts delivered feed content. It repeats with the opposite inviter. Only
synthetic public descriptors and coordination files are exchanged through the
artifact directory; each worker creates and retains its own private test key.

The test prints `CP53 Multipeer artifacts: <directory>`. Each directory contains
`a.log`, `b.log`, public descriptors and completion markers. Success requires both
workers to exit zero and both content checks to pass. The worker and parent tests
skip in ordinary CI, which does not attest to radio or local-network operation.

Verified locally 2026-09-27 with two processes on one Mac, both invitation
directions (9.496 seconds, one parent test, zero failures). This does not certify
separate physical devices, UWB/NearbyInteraction, iOS, production pairing policy,
network transitions or production deployment. Repeat the opt-in test from this
checkout for exact-head evidence; the CP53 handoff records the final run.

If discovery is blocked, inspect both logs and enable local-network access for
the process host. App-hosted runs must declare `NSLocalNetworkUsageDescription`
and the `_haven-radar._tcp` Bonjour service as required by
[Apple's Multipeer documentation](https://developer.apple.com/documentation/multipeerconnectivity)
and [local-network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).
Do not treat a failed run as an authenticated connection.

## Physical binding and reconnect fence (N08/N09)

Each installed ScannerPeerTransport retains its MCPeerID, MCSession instance,
local setup ID and role. Send, callback capture and retirement use this object
binding. Discovery cannot replace an installed adapter. Pending/accepted
invitation ownership before adapter creation remains N11 work; it must not be
inferred from the installed-adapter guarantee.

The active [peer v3 contract](../Documentation/BridgePeerChannelV3.md) protects
identity fields against a pure inner-handshake relay and encrypts all subsequent
application records. Scanner explicitly accepts first contact with any proven
identity; this is not an expected-person policy. Active DH participants have the
asymmetric disclosure limits documented in that contract.

Ordinary peer commands retain the inner `&peerGeneration` check in addition to
HPC3 AEAD. An old callback captured on a retired adapter cannot affect its
replacement. Old ciphertext delivered to the **current** adapter, including one
whose generation/counter has been rewritten, is a terminal error for that gate.
Auth frames and WS frames omit the inner generation field. Both peer ends must
run v3; v1/v2/HPC2 and plaintext application frames are rejected. Actual encoded
wire bytes, padding and cryptographic overhead count toward send limits.

The former N07 application-integrity gap is closed. Consumer ordering (N10),
physical retirement (N15), general delivery backpressure (N18), contact/NI
binding and other review findings remain separate work and verification gates.

NI discovery tokens use shareDiscoveryTokenData, one gated send per eligible
peer. Pending/factory/ack-incomplete, expired and revoked channels are skipped;
normal send admission and retained-work/byte limits are rechecked. The macOS
suite exercises this same helper using opaque synthetic archived bytes, including
an active B plus pending/revoked C and an exceeded byte quota. Creating/decoding
NIDiscoveryToken and running NISession/UWB still require iOS verification.
