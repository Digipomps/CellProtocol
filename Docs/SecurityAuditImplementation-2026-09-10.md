# Security audit implementation ledger

Status: IN_PROGRESS. Owner/integrator: current Codex security audit task.

The user authorized implementation, testing and publication on 2026-09-10, after
the read-only audit and passive FIFO intake. This is new authority; the original
intake remains immutable evidence of its original read-only scope.

## Source and ownership

- Repository: CellProtocol; branch `codex/security-audit-20260910`.
- Clean base: `cde2e0aa759704d46f15e5312262e34db4c9ad8c` from `origin/main`.
- Worktree: `/private/tmp/cellprotocol-security-audit-20260910`.
- Audit source: `4096760fe2b47d93d65d143320acfb51b4d50ff7` on
  `pdd/tillitspakke-agentflaate`; this includes unmerged features. Findings must
  be revalidated against main. Do not merge the audit branch's unrelated work.
- Passive intake: `HavenAgentD/Imports/HAVEN.CellProtocol.securityAudit/2026-09-09`.
  The import.json SHA-256 is
  `899757c6023e1b5a0a94b70ae1275acab7bad5e89f4b617421612521beab0e07`.
- The existing task “Implementer asynkron MCP-jobbflyt” owns the separate
  HavenAgentD AgentJobs implementation and native import/readback. Its task ID
  is `01a0611b-306f-7f81-9716-78d36cff03e3`. Do not edit its files or live Jobs/State.

## FIFO and acceptance

Work IDs are `cp-sec-20260909-001` through `cp-sec-20260909-024` in the original
intake. Execution is sequential. A blocked head must be reported explicitly,
not skipped by an optimizer. Native registration is not yet verified here.

001–008 have passed their local acceptance checks, including serialized bridge
tests. They remain subject to the final consumer/CI integration gate. 009 is the
next FIFO item. 009–024 have not passed implementation acceptance.

Positive operations, rejected operations, persisted data compatibility and
relevant consumer behavior must pass before publication to main. Evidence
must name the actual commit and command. No test result is a universal promise
that no deployment can fail.

## Verification log

- Clean-base bridge baseline is building with a private SwiftPM cache:
  `Scripts/haven-swiftpm.sh --cache-root /private/tmp/cp-security-swiftpm
  --cache-key cp-security-20260910 --max-age-seconds 0 --max-cache-kib 0 --
  test --disable-automatic-resolution --jobs 4 --filter
  'AppleBridgeTransportTests|VaporBridgeTransportTests|BridgeBaseTests'`.
- Log: `/private/tmp/cp-security-baseline.log`. `BridgeBaseTests` is not the
  actual suite name; run `BridgeTests` separately before claiming that coverage.
- Build/test results and remaining risks will be appended as work completes.

### 001–002: bridge identity boundary and local signing scope

- Clean-base Apple/Vapor transport tests: 19 passed, zero failures.
- Corrected clean-base `BridgeTests` baseline: 48 passed, zero failures;
  `/private/tmp/cp-security-bridge-baseline.log`.
- Red test evidence: `/private/tmp/cp-security-f1-red.log` showed the copied
  public owner reading `protected-value` without a peer proof. After the
  requester-boundary fix, `/private/tmp/cp-security-f1-f2-red.log` showed both
  unsolicited signing and signing another local identity still succeeding.
- The initial positive proof-count assertion assumed one authorization check;
  GeneralCell performs multiple checks. The test now requires at least one peer
  proof and checks the protected-read result, without prescribing internal count.
- Complete targeted matrix: 15 tests passed, zero failures;
  `/private/tmp/cp-security-f1-f2-verified.log`.
- Broad bridge matrix: 105 tests passed, zero failures in 107.654 seconds;
  `/private/tmp/cp-security-bridge-regression.log`. Filter:
  `BridgeTests|BridgeIdentity|AppleBridgeTransportTests|VaporBridgeTransportTests|LightweightBridgeTransportTests|BridgeMultiplexingTests|CellResolverProtocolLightweightBridgeTransportTests`.
- Host compatibility requirements are recorded in `BridgeIdentitySecurity.md`.
  Protected discovery and nested proof scopes require explicit host pins. This
  host-level verification remains part of the integration gate; passing unit
  tests does not establish every application deployment's compatibility.

Local commit for 001–002: `effbb2e` (not pushed or merged).

### 003–004: active-feed authorization (in progress)

- Added `ActiveFeedAuthorizationTests`. On the preceding implementation both
  member removal overloads leaked `after` values and a publisher obtained before
  revocation could be subscribed afterward. Red log:
  `/private/tmp/cp-security-feeds-red.log` (2 tests, 6 failed assertions).
- Uncommitted `FeedAuthorizationRegistry.swift` now gives each subscription a
  revocation signal, serial asynchronous reauthorization and a 256-element
  bounded buffer. Both removeMember paths revalidate live subscriptions before
  returning, preserving readers whose authority still holds.
- The two revocation regressions pass: `/private/tmp/cp-security-feeds-green.log`.
- Still required: contract expiry and condition-change tests, burst ordering,
  overflow/cancellation/completion checks, then GeneralCell/Integration/bridge
  regressions. Review normal upstream completion: merging an endless revocation
  signal must not hide completion. No feed change has been committed yet.
- Implementation uses Combine/OpenCombine buffer `.byRequest`: the checked
  pinned OpenCombine source requests unlimited upstream for this setting,
  allowing explicit overflow failure instead of silently losing producer demand.

The first broad feed run (`/private/tmp/cp-security-feeds-regression.log`) ran
91 tests and found 3 failed assertions: the new overflow test and existing
waitable-detach / cross-thread overflow integration invariants. Do not weaken
those tests. The asynchronous authorization hop had released the existing
forwarding reservation before downstream completion. The uncommitted fix now
captures a `FlowDeliveryFlight` ticket synchronously before buffering and releases
it only after downstream delivery returns or the element is discarded. The
forwarding loop waits for those tickets; invalidated generations cannot deliver.
The buffer's terminal error can itself wait for demand, so overflow additionally
signals failure asynchronously outside Buffer's internal lock.

Condition change, template grant removal and real contract expiry are now tested.
Normal completion closes the auxiliary revocation publisher so Merge cannot hide
upstream completion. Late contract expiry is rechecked after suspending proof and
condition evaluation, before a new GeneralCell authorization decision is emitted.

The v2 run stopped on a compile error (Subscriber's combineIdentifier); fixed
explicitly in the forwarding subscriber. Current verification command is in
`/private/tmp/cp-security-feeds-regression-v3.log`, running the same 91-test filter.
All feed source changes remain uncommitted until this verification passes.

The corrected v3 run passed all 91 tests in 6.933 seconds. Additional acceptance
coverage is now running in `/private/tmp/cp-security-feeds-final.log` (session
78597): instance-local controlled contract clock, expired-grant reopen denial,
valid renewal, and two serialized bridge clients where revoking one preserves
the other. GeneralCell's clock is internal and is neither persisted nor exposed
through Meddle. The earlier real-time sleep was replaced by this controlled clock.

The current BridgeBase protocol does not acknowledge remote feed termination.
The bridge test checks server-side feed termination and absence of new events
for the revoked client; already-authorized/in-flight transport messages cannot
be retracted. Do not claim a remote teardown acknowledgement or replay guarantee.
Broader transport/lifecycle fault verification remains in work item 024.

Next FIFO items after feed acceptance: 005 empty GeneralCell get/set keypaths
(also inspect Agreement.set's equivalent array access), 006 safe FileCrypto
integer decoding, 007 bounded decompression, 008 authenticated envelope header
with explicit legacy compatibility, then 009 EntityAnchor side-file encryption.
Do not skip the remaining 010–024 items or the final consumer/CI integration gate.

The 95-test feed acceptance run has NOT passed yet. The controlled clock and
renewal tests pass, as do all 91 GeneralCell/feed/integration checks, but the new
two-client bridge test currently gets `denied` at initial client.flow. Direct
local authorization with the same newly issued member contract passes. Neither
peer transport records a signing challenge/denial, so investigate the exact
pre-sign authorization boundary. An initial fixture UUID collision was removed
by assigning explicit unique UUIDs through EphemeralIdentityVault.addIdentity;
the denial remains. Do not call the feed slice complete or bypass its test.

Latest targeted diagnostic: `/private/tmp/cp-security-bridge-feed-events.log`
(exec session 24970), using existing InMemoryCellSecurityEventSink reason codes.
Earlier targeted logs: `cp-security-bridge-feed-diagnostic.log`,
`cp-security-bridge-feed-local-proof.log`; the assertions record safe response
types/reasons only. Sources are still uncommitted after `effbb2e`.

Read-only coordination freshness: the other task's worktree is
`/private/tmp/haven-agentd-app-server-bridge-20260909`, branch
`codex/app-server-mcp-bridge-20260909`, base `cccc97c`. It now contains staged/new
AgentJobsCell, CodexAppServerBridge, registration store, MCP process E2E tests,
real app-server integration tests and a copy of the 81-file passive import.
Native execution/import success has not been returned; do not infer completion
from these source files. Preserve its exclusive ownership.

Root cause of the member bridge denial: the default Agreement includes an
`identity.displayName` GrantCondition. Identity's constructor/decoder installs
that intrinsic public read grant, but the new publicIdentitySnapshot-based
requester boundary had removed it. The boundary now installs ONLY that known
local `displayName: r---` grant; it still discards caller-supplied grants, private
properties and vault authority. This preserves the existing wire decoder's
public-metadata behavior without trusting arbitrary remote policy. Verification
is running in `/private/tmp/cp-security-feeds-and-identity-verified.log` (exec
session 19668).

That run completed successfully: 99 tests, zero failures, 1.742 seconds. This
includes 5 active-feed tests, 4 serialized bridge boundary tests, 4 signing-scope
tests, 3 queue/lifecycle tests, 48 GeneralCell interface tests and 35 Integration
tests. See `ActiveFeedAuthorization.md` for the precise guarantees and limits.

Local commit for feed/metadata compatibility: `95d85e3` (not pushed or merged).

### 005: empty keypaths

GeneralCell get/set now reject an empty component list instead of indexing it.
Agreement.set safely ignores the equivalent empty path without changing state.
The regression exercises empty and dot-only strings and a subsequent valid read.
64 GeneralCell/IdentityAgreement/serialized bridge tests pass with zero failures:
`/private/tmp/cp-security-empty-keypaths.log`. Existing state and wire formats are
unchanged. This fix has not been deployed.

No changes have been made in the original dirty CellProtocol, CellProtocolDocuments
or HavenAgentD source working copies. Do not use those for builds or overwrite
their existing WIP. The other task continues to own AgentJobs and native import.
