# D186 bridge readiness handoff

Source change: BridgeBase retains readiness with a CurrentValueSubject and
filters false states when awaiting readiness. Transport replacement resets a fresh
retained state for the replacement transport. This replaces an unsynchronised Bool plus a transient
PassthroughSubject whose ready event could be lost between checking and subscribing.

Invariant: receiving ready for the current transport must unblock both current
and later readiness waiters; readiness is not an authorization grant. Identity
proof scope discovery and all signing/authorization checks remain unchanged.
Wire commands and payloads are unchanged.

Linux evidence before the fix: CellScaffold Actions 37741285022, complete log
lines 132453–132469: ready arrives at 1791445346.8709476, no description is sent,
set is sent at 1791445351.872239, and signing is rejected for missing local scope.
Lines 132639–132652 confirm server authorization denial and the failed existing
non-owner restart regression. The readiness fix is not yet verified on Linux.

The CellScaffold regression suite retains its positive and negative credential,
revocation, expiry, restart and proof-scope assertions. An additional stress test
races 2,048 ready callbacks with readiness waiters and verifies late waiters.

Further Linux evidence: CellScaffold 37747913744 passed five additional admin
suites after the readiness-state patch, but the full gate still failed one admin
test. Its second channel never received the ready frame; flow diagnostics record
bridge_description_deferred:timeout. This is distinct from the received-ready
handoff above, so the retained-state patch alone is insufficient.

VaporBridgeTransport now selects WebSocketKit's synchronous upgrade callback and
registers synchronous text/binary callbacks immediately. Processing is dispatched
inside each installed callback. In locked WebSocketKit 2.16.2 the async callback
registration overload enqueues registration on the event loop, leaving its initial
no-op handler active while buffered frames may be replayed. The analogous
Scaffold authenticated transport and Linux test transports are corrected too.
A deterministic NIO pipeline regression delivers the first frame inside the
upgrade callback, before queued registration tasks can run; Linux verification
of this additional correction is pending.
