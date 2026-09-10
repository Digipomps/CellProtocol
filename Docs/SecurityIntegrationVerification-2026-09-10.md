# CellProtocol security and asynchronous MCP integration

Verified 2026-09-10. State: source CI and local consumer gates verified; final
consumer CI tracked on the linked PRs. No main merge, deployment, live queue
import or daemon activation. Binding has an explicit unresolved acceptance gate.
This document supersedes the intermediate states in the implementation journal.

`SecurityAuditWorkEvidence-2026-09-10.json` is the ordered machine-readable
assessment for all 24 original work IDs at its publication revision `94d785f`.
It is documentation, not a new wire contract, native import format or mutation
of scheduler state. The consumer table below records later verification.

## Source and published changes

The clean CellProtocol base is `cde2e0aa759704d46f15e5312262e34db4c9ad8c`.
The original audit used `4096760fe2b47d93d65d143320acfb51b4d50ff7` plus existing
working changes; every main fix was rechecked against the clean base. Original
dirty worktrees in all repositories remain untouched.

[CellProtocol PR 35](https://github.com/Digipomps/CellProtocol/pull/35) contains
the source security series on `codex/security-audit-20260910`. The accepted
source/manifest revision is `f1036dcf422f7834cd896d7231407d269b422b3f`.
Runtime files and resolved dependency versions are identical to the earlier
`b605c5e` implementation. Later commits add an encrypted-backup test, CI runner
selection and explicit CellVapor transport-product requirements: these prevent
SwiftPM from pruning security floors in downstream consumers. A real resolver
probe accepts vulnerable NIOSSL 2.36.1 before that fix and rejects it afterward.
All published CellProtocol consumers below pin the final `f1036dc` chain; local uncommitted
overrides are not release dependencies.

| FIFO ID suffix | Implemented disposition | Evidence |
| --- | --- | --- |
| 001–002 | Received public identities cannot gain local vault authority. Signing proofs require a locally pending operation and bounded session/identity/Cell scope. | Forged and genuine serialized bridge tests; proof leases/reset/cancellation; `BridgeIdentitySecurity.md`. |
| 003–004 | Active feeds recheck authorization, revocation, expiry and changed conditions; ordered delivery and bounded buffering preserve forwarding lifecycle. | Revoke/renewal/overflow/cancellation and two actual serialized clients; `ActiveFeedAuthorization.md`. |
| 005 | Empty GeneralCell get/set paths reject safely; Agreement empty setter does not trap. | Empty, dot-only and subsequent valid operation regressions. |
| 006–008 | Checked lengths, bounded decompression and authenticated v2 envelope metadata. | Boundary, tamper, truncation and legacy v1 read tests; `FileCryptoSecurity.md`. |
| 009 | EntityAnchor snapshot and journal obey encryption policy on Apple and Vapor. Missing keys fail closed; wrong-key reopen does not overwrite files. | Migration, restart, cross-file/Cell substitution and synthetic independent backup restore; `EntityAnchorStorageSecurity.md`. |
| 010 | Text containing `isMember` no longer proves membership; unsupported evidence remains unresolved. | Negative condition tests. No new membership-attestation protocol is invented. |
| 011–012 | Grant permission bits are checked; malformed/null/unknown conditions fail decoding. | Agreement/Identity regression matrix, preserving absent/empty conditions compatibility. |
| 013–014 | Bridge setters return actual typed errors. Resolver logs omit complete values and raw URLs. | Success/failure transport responses and secret-value log exclusion tests. |
| 015 | Feature-only Apple/Vapor relation parity fixed separately; feature absent from main. | Commit `50b1490`, 19 tests pass. Integration remains with the unmerged feature owner. |
| 016–019 | Trusted Swift boundary documented; ephemeral producer requires its actual local owner and cannot fabricate signing. Commons permission metadata remains advisory; replay claims are bounded. | 58 targeted boundary/integration tests; `RuntimeTrustBoundary.md`. |
| 020 | macOS and native Linux regression gates added and passing. | Exact CI runs below. Final consumer gate remains separately tracked. |
| 021 | All 34 locked dependencies checked by immutable commit; four known vulnerable dependencies upgraded. | `DependencySecurity-2026-09-10.md` and machine-readable `DependencySecurityEvidence-2026-09-10.json`. |
| 022 | Source/local exposure matrix completed; actual remote deployment inventory remains unverified. | `DeploymentStorageFaultReview-2026-09-10.md`. Must not be closed as production verified. |
| 023 | Synthetic encrypted backup/restore passes; actual host permissions and historical backup copies remain unverified. | Same storage review and regression. Must not be closed as production verified. |
| 024 | Bounded concurrency and transport/storage fault matrix passes, with explicit delivery/retry limits. | 57 targeted tests and full macOS suite; same fault review. No exactly-once remote-write claim. |

## Exact platform gates

All three source gates passed at
`f1036dcf422f7834cd896d7231407d269b422b3f`:

| Gate | Result | Durable CI evidence |
| --- | --- | --- |
| macOS/Xcode 26 full package | 1058 tests, zero failures; actual downstream vulnerable-pin rejection passes | [34428821757](https://github.com/Digipomps/CellProtocol/actions/runs/34428821757) |
| Native Linux/OpenCombine | 51 tests, zero failures; separate file-bounds executable and negative/positive public authority API compilation checks pass | [34428821695](https://github.com/Digipomps/CellProtocol/actions/runs/34428821695) |
| Native Linux, actual Vapor vault source | 25 tests, zero failures | [34428821686](https://github.com/Digipomps/CellProtocol/actions/runs/34428821686) |

All three gates also passed at documentation revision `94d785f`:
[macOS 34430616691](https://github.com/Digipomps/CellProtocol/actions/runs/34430616691),
[Linux 34430616727](https://github.com/Digipomps/CellProtocol/actions/runs/34430616727),
and [Vapor 34430616810](https://github.com/Digipomps/CellProtocol/actions/runs/34430616810).

The full local macOS dependency rerun also passed 1058 tests. OpenCombine 0.14
lacks Merge; the portable two-inner bounded flatMap fan-in is covered by the
native Linux gate. Earlier emulated amd64 Docker runs on arm64 hung at varying
tests; their cause remains unknown, and they are not counted as passing checks.
The first macOS CI runner lacked FoundationModels; existing CellApple source
requires Xcode 26, now explicitly selected. The new dependency graph requires
Swift 6.1 or newer. These platform requirements are adoption constraints.

## Consumer acceptance

| Consumer | Published change | Verification |
| --- | --- | --- |
| DiMyMicropayments | [PR 11](https://github.com/DiMy-io/DiMyMicropayments/pull/11), `99da4ba38a1a6a4d2e5f7dfe3a66a2329a476a41` | 36/36 tests pass with the exact published graph. |
| DiMyMint | [PR 11](https://github.com/DiMy-io/DiMyMint/pull/11), `41c5005c9b12021f18d491af85f0516b9aa04a19` | Source gate: 32 tests, one skipped because no disposable PostgreSQL database was configured. [CI 34429533655](https://github.com/DiMy-io/DiMyMint/actions/runs/34429533655) passes on this exact head. |
| Sprout | [PR 1](https://github.com/Digipomps/Sprout/pull/1), `9d9f89a1bcdbc29b622487428a0f8d112bc5008e` | 107 tests pass separately with Crypto 4.5.2 and 3.15.1; native macOS/Linux CI and release-bundle verification pass. |
| HavenAgentD | [PR 11](https://github.com/Digipomps/HavenAgentD/pull/11), `602656e7889ac98beb0ef98085e2162178e1916b` | 179 tests/37 suites, product build and daemon smoke pass; [final CI 34431850574](https://github.com/Digipomps/HavenAgentD/actions/runs/34431850574) passes after the documentation handoff. The real Codex app-server job passed in 30.303 seconds at the preceding pin with identical runtime sources/versions. |
| CellScaffold | [PR 237](https://github.com/Digipomps/CellScaffold/pull/237), `7f6dc4b823f2cca803489404481495cba995d2ae` | 24 local shards pass: 2067 cases, 10 existing skips, zero failures at `cc09dc5d`; 30 relevant tests pass at the final pins, with all dependency versions unchanged. 59 historical-controller tests pass. Native CI at `e29e5c13` passed 23/24 groups and reproduced a main replay-flag test defect, now corrected with 18 local callback tests passing. [Final native Linux/browser CI](https://github.com/Digipomps/CellScaffold/actions/runs/34432685661) remains required on this exact head. |
| Binding | Local candidate only; clean base `3c712731` | Final-pin macOS app/test build passes. Runtime verification: 376 Swift Testing tests pass; 94 XCTest cases include 20 existing skips and one failed protected-storage case. See the boundary below. |

CellScaffold needed its inbound bridge to enter local ready state before
requesting the peer's proof. The real AdminEntry WebSocket test fails without
that integration and passes after the fix. The multiplex custom factory and
Sprout host now follow the same initialization. Two direct EntityAnchor test
fixtures install and restore a synthetic persistence key, matching the host's
key-before-construction contract.

Early CellScaffold selections passed 71 and 22 tests using sibling local package
overrides. They establish integration behavior but are not the canonical graph
gate. The 24-shard run uses a separate parent directory with no sibling
CellProtocol/DiMy packages, all 55 remote pins, the exact pinned documentation
checkout and the unchanged `ci/run-tests.sh` selection. The final pin update
changes only the three first-party revisions; all third-party versions remain
identical. The subsequent 30-test selection covers actual AdminEntry networking,
encrypted AgreementWorkbench persistence, public policy and skeleton provenance.

The native Linux run at `e29e5c13` reproduced the same callback test assertion
already failing on unmodified main `5e64c296`: both concurrent requests reported
`isReplay`. Admission and mutation have independent atomic winners, and the API
combines both replay flags. Each call can therefore replay a different stage.
The corrected test retains identical signed responses and exactly one mutation,
and adds a subsequent identical replay plus direct counts of one admission,
one ticket transition and one mutation. All 18 callback runtime tests pass
locally. No runtime behavior or skip list changed for this correction. The full
explanation and both failure runs are linked in CellScaffold's
`docs/CallbackAdmissionReplayVerification-2026-09-10.md`.

The public-configuration crash reproduced on clean main: recursive skeleton
validation constructed the entire catalogue under nested stack frames. The
iterative traversal preserves depth-first error order and caches publication
lookups only within one validation call. A 64-level positive/negative regression
passes. The historical one-shot deployment controller keeps its original
contract; its tests use a checksummed pre-audit input fixture instead of current
package pins. No deployment guard or source behavior was weakened.

An exploratory single-process full CellScaffold run failed and crashed; a clean
baseline reproduces the unrelated failures and crash. The repository already
uses shards and explicitly documents exclusions. No exclusions were added or
weakened for this change. Two manifest-writer failures also reproduce unchanged
on main; they are not hidden inside the 71-test claim. The DiMyMint database skip
and opt-in remote/provider tests are not evidence of live service readiness.

Binding's one failing case is the identity-link completion persistence test,
which reports three assertions after Foundation rejects
`.atomic + .completeFileProtection` with Cocoa 513 / POSIX EPERM. A standalone
Foundation probe reproduces that rejection while `.atomic` succeeds. The exact
host cause is unproven; the protection requirement and test remain intact.
A later unsandboxed synthetic matrix confirms class A writes fail with and
without atomic writing; class B writes succeed but reopening fails; class C
writes and reads succeed. CoreGraphics reports a completed on-console login.
This is consistent with unavailable protection keys, but the specific session
or keybag cause is unproven. It is not evidence that the application should
weaken protection. [Apple documents the class-dependent availability boundary](https://support.apple.com/guide/security/data-protection-classes-secb010e978a/web).
No Binding source implementation was changed or pushed. Its final-pin build
passes, and its unit run uses the preceding pin's identical runtime sources and
dependency versions, with isolated user storage and remote parity disabled.
The candidate patch is `Binding-security-adoption-candidate-20260910.patch`,
SHA-256 `dc0829cf400e69355b1bec6a6c815796719d0c03b39ea5cd8f57596cab117bbc`.
Protected-storage acceptance in the intended app/environment is required before
publishing or integrating that consumer. FileCrypto writer rollout must account
for this remaining reader-upgrade gate.

## Asynchronous MCP and queue boundaries

HavenAgentD owns the durable job store, persistent Codex app-server child,
MCP submit/import/state/list/complete surfaces and read-only AgentJobs Cell.
MCP returns `queued` with a resource URI promptly; execution and completion
continue in the daemon. Tests cover atomic duplicate registration, restart
rescan, uncertain running-turn blocking, ordered completion and approval gates.

The exact 24 jobs `cp-sec-20260909-001` through `-024` import idempotently and
read back through MCP and the native AgentJobs Cell in a disposable daemon root:
24 first accepted, 24 reused on the second import, FIFO sequence 1–24, all passive.
Original import SHA-256 is
`899757c6023e1b5a0a94b70ae1275acab7bad5e89f4b617421612521beab0e07`;
80/80 source hashes remain valid. That original read-only intake is immutable.
The user's later implementation/test/push authorization is separate provenance.

HavenAgentD commit `602656e` also retains the byte-identical 24-item assessment
from CellProtocol `94d785f` under
`Evidence/HAVEN.CellProtocol.securityAudit/2026-09-10/`.
Its 9,949 bytes have SHA-256
`8c0962f99c7b64e2d0e4746606aee503ed933a88ee6daa043c73e6b2480b5784`.
The import runbook records this provenance. This separate evidence snapshot
does not change the original import, its 80 checksums or native FIFO status.

The actual installed daemon currently lacks enabled AgentJobs, its route, the
MCP binary and Jobs root. Production import and activation have not occurred.
`HavenAgentD/Docs/SecurityAuditPassiveImport.md` supplies concrete prerequisites,
shadow verification and import/readback commands. Disk files alone are not
native live Cell registration. No scheduler statuses have been silently changed
to claim completion or skip an unresolved FIFO head.

Results are available as resource/status and safe relative artifact metadata.
Automatic insertion into an arbitrary Claude conversation and actual binary
message attachments are not implemented by this server-side slice.

## Integration order and remaining limits

Integrate the CellProtocol security PR and Sprout compatibility PR before their
consumers. Then DiMyMicropayments, DiMyMint and CellScaffold follow their exact
dependency chain; HavenAgentD follows CellProtocol and Sprout. Pin tests must
remain green on the revisions actually selected by each integration.

Upgrade readers before enabling FileCrypto v2 writers: old readers cannot read
new envelopes. Legacy v1 reads are retained by default. EntityAnchor hosts must
load the correct master key before constructing encrypted persisted Cells.
Existing plaintext backups are not retroactively encrypted. Custom transports
bypassing BridgeBase still own their equivalent proof boundary.

The relation fix is a separate local feature commit, not a hidden main feature
addition. Patch: `EntityRelation-Vapor-security-50b1490.patch`, SHA-256
`a2a76ca889d1f64ce6e2493b156943ac13355589e9773fd6f20b1541da947b40`.
Its source feature branch has no published remote target, so it was not pushed
as an unrelated main feature history.

Protected messages already in flight cannot be recalled; remote teardown has
no acknowledgement and remote writes have no general durable deduplication
contract. Trusted same-process Swift code is not sandboxed by Cell permissions.
The zero-match OSV scan is point-in-time evidence, not a promise of no unknown
vulnerabilities. Production exposure, real backup coverage and daemon activation
remain explicit operational follow-ups, not inferred from passing source tests.
