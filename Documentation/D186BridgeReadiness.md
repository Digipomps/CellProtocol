# D186 bridge readiness handoff

Source change: BridgeBase retains readiness with a CurrentValueSubject and
filters false states when awaiting readiness. Transport replacement resets the
same retained state. This replaces an unsynchronised Bool plus a transient
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
