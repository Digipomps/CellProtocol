# Scanner NearbyInteraction binding (N12)

NI uses one platform session per authenticated physical adapter. Apple documents
[one NISession per nearby object](https://developer.apple.com/documentation/nearbyinteraction/nisession).
`ScannerNearbyInteraction` is an association/lifecycle helper, not an authentication
gate. `ScannerConsumerContext` retains the exact MCPeerID/MCSession through the
adapter, the proved public-identity descriptor, channel session/generation and
accepted shared endpoint setupID. The adapter's local invitation-instance UUID is
not the shared setupID. Neither payload UUIDs nor `connectedRemoteUUID` select a
measurement recipient.

All NI state, creation, secure token decoding, platform calls and callbacks use
the Scanner state queue. `ScannerNISession` is the small injectable driver
protocol; `AppleScannerNISession` is the production iOS implementation. macOS tests
inject deterministic drivers into the real Scanner/gate/wire path. No dependency,
WS profile, mux format, signing source, ready exception or Cell authority changes.

## Token contract and lifetime

`DiscoveryToken` is a negative-cid response FlowElement sent through the existing
bounded, encrypted peer-v3 gate to exactly one captured context. Its content has
exactly `niVersion` (integer 1), `userUuid` (channel signer's UUID), `targetSession`
(receiver's session UUID), `setupID` (accepted shared endpoint), `niGeneration`
(canonical uppercase UUID), and `token` (secure archive, 1...16384 bytes). JSON
carries token bytes as base64. Legacy unbound token payloads are rejected.
The complete physical context and full principal descriptor come from the gate,
not from these wire labels. Ordinary frame/work/send budgets remain in force.

There is at most one local NI instance and one remote token/generation per channel.
An exact repeated token is idempotent. A replacement token or NI generation is
rejected, never silently installed. Restart after terminal NI failure requires a
new authenticated channel/invitation; the closed entry remains a bounded tombstone
until channel retirement. Unsupported platforms create no NI session.

Startup and incoming token handling use the same helper, so either arrival order
works. Each local token is sent once to its own context. Reconnect creates a new
platform session, local NI generation, token and channel context. An old envelope
fails the new setupID check; a captured old context fails liveness. No token or
measurement is persisted or logged.

## Callbacks and retirement

The native adapter first requires callback NISession object identity and matches
the NINearbyObject discovery token. The helper then requires the exact driver and
entry, live physical adapter, session/generation and principal. Queued main-actor
publication rechecks entry/lifetime again and reports the captured remoteUUID.
A publication that already won its final admission cannot be recalled.

Close, physical retirement/disconnect, revoke cleanup and stop invalidate and drop
the platform session/token. Direct session revocation prevents effects immediately;
the existing gate close callback schedules physical/NI cleanup. A callback during
that interval also detects the revoked session and invalidates its NI driver.
Late update/remove/suspend/resume/invalidation callbacks cannot restart a replacement.
Suspension suppresses measurements; resume and timeout may run only the same token
on the same live session. End/invalidation is terminal, without automatic recreation.

The association proves which authenticated channel supplied a token. It is not
hardware attestation that a principal is a particular person or that a hostile
accepted peer cannot forward a token obtained outside this channel.

## Verification boundaries

`ScannerNearbyInteractionTests` tests concurrent B/C associations, wrong principal/
setup/target/version, immutable tokens, queued and late callbacks, reconnect,
close/revoke/disconnect/stop, suspension and terminal invalidation with fake drivers.
It exercises the real peer-v3 gate and send path; radio and native token creation
are not simulated claims of hardware verification. Existing token quota tests now
select an explicit authenticated context and still prove encrypted targeting and
send-budget enforcement. The same NI tests are included in macOS TSAN CI.

The iOS-only malformed-archive test needs no UWB hardware. Successful native token
archive/decode and physical measurements require the operator's two supported
phones. iOS compilation, simulator tests and physical testing must be reported
separately from macOS results. See the N12 handoff and operator script in the
PDD_bro-paa-i-prod_2026-09-26 delivery for exact execution evidence and procedure.
