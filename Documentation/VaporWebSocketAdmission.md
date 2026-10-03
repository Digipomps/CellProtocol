# Vapor WebSocket receive admission and ordering

PDD_bro-paa-i-prod_2026-09-26 / N30. Applies to incoming and outgoing
`VaporBridgeTransport` sockets, before the existing `BridgeChannelTransport`.
There is still one authentication gate and one session per physical socket.

The synchronous WebSocketKit `onText`/`onBinary` callbacks reserve count and
wire-payload bytes before copying a frame, decoding JSON or creating receive
Tasks. The async callback overload must not be used: WebSocketKit 2.16.1 creates
an independent Task for each frame before invoking that callback.

| Limit | Value | Ownership |
| --- | ---: | --- |
| One complete callback payload | 1 MiB | Existing inbound validator maximum |
| Queued plus executing payloads | 64 / 4 MiB | Per transport instance |
| Queued plus executing payloads | 1024 / 32 MiB | Shared process-wide ledger |

All conditions must pass atomically with respect to that connection's enqueue;
the shared ledger also locks its global acquisition. Failed acquisition creates
no payload copy or receive worker and never releases another frame's reservation.
Each accepted frame has one preparation Task and at most one dispatch Task.
The count and bytes remain charged through validation, queue waits, gate work,
identity lookup, consumer completion and awaited rejection auditing. A blocked
security-event sink retains the accepted frame's reservation. Closing does not release executing or
held queued work early. Existing gate/work/operation/send quotas also still apply.

Preparation follows callback arrival order, including completion of each
authentication message. Ordinary dispatch for an established mux channel has a
separate tail bound to the locally captured channel instance. A waiting consumer
on A therefore does not prevent B from progressing. Values on the same channel
still enter the consumer in order. The fallback tail handles non-mux traffic and
channel setup; pending channel factories are outside this change's independence
guarantee.

A close for an established logical channel bypasses that channel's consumer
tail, but still passes the normal gate and identity checks. It retires only the
captured channel instance. Queued work retains that instance rather than looking
up a reusable wire ID when it eventually runs. Retirement suppresses cancellation
and late-send failures from that old consumer so they cannot close siblings.
Count/byte/work/channel reservations remain retained until their actual work
returns. Captured destinations and scheduling tails are bounded by the same
receive admission; completed per-channel tails are removed.

A `sign` command or a response matched to a locally registered signing RPC can
also progress independently. The lookup follows the gate and exact logical
channel to its BridgeBase auditor. A signature-shaped payload is not a scheduling
credential. Every prepared dispatch still runs the gate's normal principal,
generation, expiry, operation-permit and response validation. All lanes use the
same receive budgets; saturation closes the connection rather than bypassing
limits.

Overflow or malformed input stops further admission and closes the existing
session synchronously. At most one adapter cleanup Task is scheduled; the
existing session-close callback is also idempotent. Already executing work is
revoked by the gate and retains receive accounting until it returns. Pending
ordinary dispatch checks retirement before entering the gate. Physical close
uses the host-owned NIO channel callback (or the outgoing adapter's owned event
loop group), without waiting for a peer close acknowledgement. Concurrent close
callers await the same physical-close Task before gate transport accounting can
be released. All callers also await one shared resolver-unregistration Task;
otherwise a second close could release a slot while the first cleanup still
retains work. The gate notification runs afterward, outside that Task, so
reentrant close cannot await itself. Public ingress
hosts must continue supplying `closeUnderlyingChannel`. A retired adapter is
single-use; reconnect uses a fresh transport instance.

This bounds application-owned receive payloads and work at the callback
boundary, not kernel buffers or WebSocketKit allocations/reassembly before the
callback. Hosts must configure their frame/fragment/aggregate limits as well.
Decoded objects and Task overhead are bounded in number, but wire-byte charging
is not an exact RSS measurement. Global saturation can reject another connection;
the isolation guarantee is that rejecting one connection does not close existing
siblings or consume reservations for its rejected frames.

## Regression evidence

`VaporWebSocketAdmissionTests` drives WebSocketKit's actual aggregator and
callback handlers on live NIO sockets. It injects complete frames in one event
loop turn so the synchronous count/byte assertions do not depend on Swift Task
scheduling. It covers pre-proof and authenticated bursts, 64 plus one, 1 MiB
plus one, 4 MiB plus one, global count/byte plus one, retained accounting through
held consumers, mixed text/binary feed order, malformed input, non-signing
responses and a fresh sibling after rejection. Default public adapters are also
checked against the same process-wide ledger.

`BridgeChannelWebSocketTests` separately uses actual HTTP upgrade and socket
framing to prove a protected read with origin signing for both ordinary and
mux WebSockets, with no server signing vault. The full macOS regression and its
existing three-pass TSAN job include both suites. No production host deployment,
TLS proxy verification, or universal DoS guarantee follows from these tests.

## N35 regression candidate

Three added regressions cover two logical channels on one physical socket:

- `VaporWebSocketAdmissionTests.testMuxHeldOperationAllowsSiblingAndSelectiveCloseOnSameSocket`:
  holds A without cooperative cancellation, requires B and selective A-close to
  progress, reuses A's wire ID before old work completes, retains work accounting,
  rejects the old late send and prevents queued old work reaching replacement A.
- `VaporWebSocketAdmissionTests.testMuxFlowOrderIsLocalToItsChannelOnSameSocket`:
  holds A's first Flow delivery, requires ordered B delivery, then verifies A's
  own order and eventual receive-accounting release.
- `BridgeChannelWebSocketTests.testHeldCellDoesNotBlockAnotherProtectedReadOnSameWebSocket`:
  performs real HTTP upgrade and authentication, holds an actual GeneralCell GET,
  and requires another protected GET with origin signing on the same socket.

Verified in [macOS CI run 37049974688](https://github.com/Digipomps/CellProtocol/actions/runs/37049974688),
completed 2026-10-02 and inspected 2026-10-03. Tested head:
`7ef06e7541d57561f04d1a3ca8d2ced44cbd0eb1`; runtime change: `091c85b`.

- The three tests compiled and all failed with the three original runtime files
  from `3824cf84` restored. Failures were sibling-progress/close timeouts, not
  compiler errors. XCTest reports six failures, two from thrown timeout errors.
- With the candidate restored, all three tests passed.
- Full macOS suite: 1539 tests, five skipped, zero failures.
- One focused Thread Sanitizer pass: 55 tests, zero failures.

One macOS-26 job took 18m40s, using Xcode 26.6 and Swift 6.3.3. Dependency pins
stayed unchanged; the downloaded source hashes match the runtime candidate.
Artifact `bridge-mux-n35-7ef06e7541d57561f04d1a3ca8d2ced44cbd0eb1`
contains all four raw logs and `result.json` with commands and source hashes.
`Scripts/run-bridge-mux-n35-ci.py` is the bounded reproducer; its nine
orchestration tests passed locally and in CI without simulating runtime results
as Swift evidence. The temporary dispatch-only workflow was restored after the
run; normal PR/main regression policy is preserved.

Host Swift compilation remained blocked by the task's 40 GiB and 10 percent
capacity gate; only syntax/static and Python checks ran locally. The full-suite
skips include optional fixture/worker tests and native Multipeer coverage.
This evidence addresses established-channel N35 behavior, not other PR53
findings, iOS Nearby Interaction, a production TLS route or deployment.
