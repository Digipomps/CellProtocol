# Remote contact local-holder R2: review test follow-up

Status: SOURCE_ONLY_TEST_SUCCESSOR_PENDING_REVIEW; NOT_COMPILED/NOT_RUN.
Parent fa2757c3f132b553d293610e8bc2f102264074b7 (R1 source review PASS only).
R1 review: PalazzoScaffold/Deliverables/Palazzo_Pilot_2026-11-01/acceptance-18-20261113/remote-local-holder-api-r1-review/REVIEW.json, SHA256 bd7b99242f6b5fe9bb4cb915f49aaf8d455c6aafbcc65f73f134f99def2e3d1f.

Only test source and this new evidence directory change. All product source,
public API, packages and all seventeen R1 methods/helpers retain exact bytes.
Removing the marked additive R2 block restores the entire parent test file.
Frozen R1, R15, local chat and R25 are untouched. This is not a new TestFlight
requirement, execution permission, or evidence that Swift35/CP-O1 has run.

## Three added methods

1. `testEachClockExpiryInsideVaultAwaitPreventsPrivateSigning`: a controlled,
thread-safe wall/monotonic clock is injected through the existing internal lease
initializer. Hold the actual vault signing await, advance only one clock past
its deadline, assert the other clock stayed unchanged, release and require
`expired` with zero private calls/no dispatch. Repeat with the other clock.
A fresh operation with an independent current clock succeeds. No retire call,
real-time expiry sleep or changed production clock supplies the denial.
2. `testFailedPrivateCallCannotRetryConsumedContextWhileLeaseRemainsActive`:
inject failure inside the source signer closure and require one private-call
attempt plus consumed context. Clear the failure, prove the original lease is
current, retry that exact context and require signingDenied with unchanged
count. Prove the lease is still current; a fresh context on that same lease
signs and verifies successfully. Retirement cannot mask the consumed-context
check. The injected failure is before the actual in-memory crypto call, inside
the fenced private-signer closure; it is not an induced cryptographic failure.
3. `testActualBridgeIdentityVaultCannotMintLocalHolder`: attach an actual
BridgeIdentityVault to the original public descriptor and full-looking home.
Require unsupportedSigner, zero local source calls and no dispatch. The original
local requester then succeeds on the same lease. This proxy has no live Bridge;
the test is direct type/authority refusal, not a network forwarding test.

Positive source-entry barriers use bounded XCTest expectations and are released
before task results are joined. No sleeps establish negative effects. All20
methods remain NOT_COMPILED/NOT_RUN; source counts are not Swift discovery.
The20-method test source is not a successful execution result.

## Unchanged integration boundaries

The R1 ContactLocalSigningVault/ContactSigningContext API stays byte-identical
(SHA25625037f40c61d22aef543208b019f6ed17f66cff7e117b7513a0c067e81f32e0c).
CS owns the separately requested Browser implementation. Resolver/connect/origin,
actual physical-send admission, Bridge-owned current-RPC provenance, durable
storage, owner export and OriginConversationCell/member/Flow remain open.
Local holder proof or queued callback admission must not be reported as remote
contact delivery, native person reading, staging or TestFlight acceptance.

No Swift/SwiftPM/resolve/discovery/build/runtime/native/queue/Deploy command ran.
Original data, entity links, analyses and the hard cleanup gate remain preserved.
