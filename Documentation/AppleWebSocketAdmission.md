# Bounded independent Apple WebSocket receive dispatch

This candidate follows Bridge PR53 N35 and Scanner PR58 (`14181968`). N35
established independent live multiplexed channels in the Vapor adapter. The
Apple adapter still awaited the complete consumer operation before Foundation
registered its next WebSocket receive. A held operation could therefore delay
signing, another channel and selective close on the same socket.

## Receive and authority boundaries

`AppleBridgeTransport` now reserves count and bytes before payload copying or
worker creation. Its ordered preparation lane validates payloads and completes
channel authentication before later messages are prepared. Ordinary operations
retain order per live mux channel; signing, origin-signature responses and
selective close can progress independently. The core gate still prepares and
consumes dispatch and enforces channel generation and caller authority. No
transport field creates a grant or selects a server-side private signer.

The Foundation receive callback waits for bounded admission rather than full
Cell execution. Every admitted worker retains its reservation until its actual
work, including held preparation or rejection auditing, returns. Closing a
transport cannot free still-retained work to admit an unbounded replacement.

| Boundary | Limit |
| --- | --- |
| Foundation maximum complete message | 1 MiB |
| Per adapter admitted work | 64 messages / 4 MiB |
| Shared process Apple + Vapor admitted work | 1,024 messages / 32 MiB |

The existing Vapor budget is an alias for the shared core budget, not a second
pool. Saturation revokes the affected physical session and closes that socket;
it can therefore affect its mux siblings. These counters cover admitted payloads,
not all Foundation/OS buffering or allocator overhead. They are not an RSS cap.

An Apple adapter has one physical lifetime. A second setup and reuse after
retirement fail. Setup admission and close are synchronized; pending setup is
released when its socket closes, without waiting for the five-second connect
timeout. Captured old tasks and non-current physical callbacks are rejected.
Physical disconnect and registration cleanup each have an owned completion
task. This does not claim that every concurrent call to the outer core gate's
close method provides a complete physical-drain barrier.

## Reproduced behavior and tests

The corrected original native regression recorded one test with two failures
after held channel A prevented sibling B and selective close from progressing.
The execution note identifies the unchanged PR58 runtime, but no simultaneous
source-hash manifest was retained for that earlier run. Its raw log alone does
not independently attest the runtime revision. The fixture uses a real
`URLSessionWebSocketTask` for received peer frames. It injects the core challenge
locally to exercise the Apple adapter in the receiving/server gate role; it is
not evidence of a natural full handshake in that particular fixture. Separate
new outbound Apple tests complete the full core handshake, reject an unproved
read, perform protected reads, preserve signing and never invoke the server's
private signer.

The regression then passes with the bounded dispatcher: B and selective close
progress before releasing A; A's queued stale operation never executes and B
continues afterward. Other tests cover quota+1 with held work, shared admission,
stale callbacks, a real socket stalled before HTTP upgrade, duplicate setup and
retired reuse. The first two attempted red runs did not compile; the third had
a noncanonical auth-envelope fixture and failed before the intended barrier.
Only `cp53-apple-native-red-4-20261005.log` among those early runs reaches the
intended hold/progress failure. Not every new or changed test was independently
run red.

The independent evidence check also identified that the initial A-counter assertion
preceded release of the held operation. The final test drains admitted work and
asserts again after release. A separate controlled reversion then restored just
the serial receive dependency by awaiting consumer completion in both callbacks:
the same final fixture failed (one test, two failures). Byte-exact restoration
passes in the final full/TSAN runs. The original runtime, mutated runtime, fixture
and execution manifest are preserved. This controlled reversion is not a run of
an untouched historical checkout.

Local final verification on Apple Swift 6.4 / Xcode 27.0:

- Full package: 26 + 3 + 1,545 = **1,574 XCTest tests**, five skipped, zero failures.
- Earlier affected-suite run: **35 tests**, zero failures. The final extra
  post-hold assertion is also covered by the full package and expanded TSAN run.
- Expanded CI filter: **198 TSAN tests**, zero failures, one local process with
  `TSAN_OPTIONS=halt_on_error=1`. CI retains its three-process policy.
- Bounded builds used two jobs, at least 40 GiB AND 5% free after a 10 GiB reserve.
  Existing caches were retained; automatic garbage collection was report-only.

Exact source/log hashes and test scope are in
`Documentation/Evidence/AppleWebSocketAdmission_2026-10-05.json`. Final tested and submitted source hashes match exactly. The execution manifest
also retains the actual Swift, Xcode and OS version output. The earlier Scanner CI race in a
MockIdentityVault/continuation path remains unexplained despite its successful
rerun. This local pass does not diagnose or erase that earlier result.

## What this supports and what remains

Keep the authenticated Bridge design: separate transport admission and scheduling
from core identity/resolver authority. This removes a reproduced Apple scheduling
dependency without weakening proof or replaying writes. A new transport protocol
or a proof cache is not justified by these measurements.

The tests demonstrate progress under a held consumer, not p50/p95/p99 latency,
fairness under global saturation, independence of pending channel factories,
30-minute subscription continuity or seamless five-minute auth renewal. Physical
NI/UWB, actual iOS execution, staging TLS/proxy acceptance, AP9 review and release
approval remain separate. This document records a local candidate, not deployment.
