# Deployment, storage and fault verification

Scope: FIFO items 022–024, using local metadata, repository sources and isolated
synthetic tests. No production attack, private Entity read, key export, migration
of user files or deletion was performed.

## Exposure matrix

| Surface | Observed state | Authority and evidence | Remaining uncertainty |
| --- | --- | --- | --- |
| CellProtocol Apple/Vapor bridges | Library sources at security commit b605c5e | BridgeBase strips received requester authority and obtains proofs from the peer; forged-owner and genuine-owner serialized tests pass. Transport hydration alone is no longer authorization in BridgeBase. | A custom delegate that bypasses BridgeBase must implement its own equivalent boundary. |
| CellScaffold AdminEntry | Actual temporary loopback server tested on 127.0.0.1 | HMAC-authenticated WebSocket; real owner key loaded only in the isolated host. Protected operation passes after local server ready transition, with the security CellProtocol graph. | This does not establish the configuration of deployed remote hosts. |
| CellScaffold multiplex and Sprout hosts | Source-reviewed inbound host setup | The custom multiplex factory and Sprout host now make the same local ready transition as the default multiplex factory. Existing route/transport gates pass. | The dedicated AdminEntry test is a real network test; it is not an end-to-end test of every Sprout application. |
| Existing local AdminScaffold listeners | Four loopback-only listeners, PIDs 75594/78671/84620/88716, ports 65033/49510/50390/50853 | Metadata identifies an older /tmp/cellscaffold-ci-build-admin-loopback-20260826 build, running for about 14 days. They are unrelated to this run and were not stopped or probed. | Binary revision, keys, route policy and stored data were not inspected. These are not verified upgraded services. |
| Remote/production installations | No authoritative live inventory obtained | No inference from repository source or historical configuration to actual exposure. | External interfaces, deployed revisions, key roles and backup copies remain unverified. |

Item 022 has a concrete local/source exposure matrix. Production exposure remains
open; missing live deployment evidence must not be marked done or interpreted as
absence of exposure.

CellScaffold's existing atomic-v3 controller is a one-shot historical deployment
contract tied to an `f76de5a` image tuple. Its declared dependency inputs match
the later pre-audit main snapshot `5e64c296`, while the Package.resolved stored
at `f76de5a` has different pins. Build-time overrides or actual image provenance
must be checked before using that controller. This audit did not inspect or run
the live image. Its dependency test now compares the frozen pre-audit inputs,
with their exact checksum, instead of silently forcing that historical contract
to follow each current package update. The controller and release guards are
unchanged. This is not deployment acceptance for the security candidate.

## Storage and backup

Both Apple and Vapor EntityAnchor snapshot and journal files are encrypted by
the shared codec unless a trusted host explicitly selects plaintext policy.
Directory/filename policy is applied before the existing atomic file writer.
The side-file writer does not itself impose a new POSIX mode: effective access
still depends on host directory permissions and umask. Encryption does not hide
file names or sizes. Hosts must keep the master key separately protected and
available for restore. No real host master key or backup content was inspected.

The shared Apple/Vapor regression now copies both encrypted files to an
independent backup directory, moves the original directory aside, restores the
backup and reopens the Cell. The synthetic value is recovered and both restored
files match the backup ciphertext. A wrong-key reopen blocks writes without
overwriting either file. Legacy plaintext migration and cross-Cell/cross-file
substitution rejection remain covered. Old backups are not retroactively
encrypted, and complete machine/disk-loss recovery was not simulated.

## Fault and concurrency evidence

`/private/tmp/cp-security-faults-backup.log`: 57 tests passed, zero failures,
covering the new backup restore, journal receipt verification and interrupted
snapshot recovery, active-feed revocation/expiry/renewal, cancellation during
authorization, bounded overflow and ordered completion, proof lease timeout and
transport reset, multiplex continuity gaps, channel bounds, reconnect after
wake/keepalive failure and actual serialized bridge responses.

The full 1058-test macOS run additionally includes signing response correlation,
timeout cleanup, forged-signature rejection, challenge replay denial, immediate
failed-send propagation and cancellation during route churn. These checks do
not establish exactly-once remote writes after a lost response: the protocol
has no general durable operation deduplication contract. Already authorized
network data cannot be recalled after revocation, and there is no remote
teardown acknowledgement. Application retries must account for that ambiguity.

The intermittent emulated Linux hangs remain recorded separately from passing
results; their cause is unproven. Native Linux CI subsequently passed at
`7d3598a`: 51 OpenCombine/security tests plus file-bounds/public-API compilation
checks, and 25 actual Vapor vault tests. See `SecurityIntegrationVerification-2026-09-10.md`
for exact runs. The emulated timeouts are not counted as passing tests.
