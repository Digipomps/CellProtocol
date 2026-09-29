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
authentication message. Ordinary application dispatch has its own ordered tail,
so the first held response prevents later feed values from entering the gate.
Only a `sign` command or a response matched to a locally registered signing RPC
may pass this tail. The latter lookup follows the gate and, for mux, the exact
logical channel to its BridgeBase auditor. A signature-shaped payload is not a
scheduling credential. The unchanged gate, principal, operation-permit and
response validation still execute for every control message. The control lane
uses the same receive budgets; a saturated connection is closed, not exempted.

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
