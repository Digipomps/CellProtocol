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
