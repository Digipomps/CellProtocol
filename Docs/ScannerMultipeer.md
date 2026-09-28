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

Each ScannerPeerTransport retains its accepted MCPeerID, MCSession instance,
local setup ID and role. Send, callback capture and retirement use that binding,
not discovery routes. Colliding discovery cannot replace a pending/active route;
discovery loss alone does not disconnect the channel. MC receive callbacks
capture the transport synchronously before starting asynchronous work. A late
failure, disconnect or close can only retire that transport instance.

Ordinary peer BridgeCommands require `&peerGeneration`, stamped by the gate from
its local session generation and checked against the remote hello generation
before dispatch/cid lookup. Old-generation frames are discarded without closing
the replacement gate. Auth frames and WebSocket frames omit the field. Both peer
ends must run this protocol version; untagged ordinary peer frames fail closed.
The final encoded bytes, including the generation, count toward send limits.

This is a reconnect fence, **not cryptographic integrity**. N07 remains open:
a relay terminating two MC connections can still forward authentic proofs and
modify ordinary messages. The future per-message protection layer belongs at
ScannerPeerTransport.sendData/receiveData, the bound physical byte boundary;
it must account for its wire overhead in the existing gate's budgets.

NI discovery tokens use shareDiscoveryTokenData, one gated send per eligible
peer. Pending/factory/ack-incomplete, expired and revoked channels are skipped;
normal send admission and retained-work/byte limits are rechecked. The macOS
suite exercises this same helper using opaque synthetic archived bytes, including
an active B plus pending/revoked C and an exceeded byte quota. Creating/decoding
NIDiscoveryToken and running NISession/UWB still require iOS verification.
