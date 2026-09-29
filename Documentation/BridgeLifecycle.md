# Bridge response, factory and signing lifetimes

The WS authentication profile, its signing transcript, and mux v2 wire fields are
unchanged. These shared lifecycle rules apply to WS and peer v3, including mux.
There is one authentication gate/session; none of the rules allow a `ready` frame
or a remote vault to bypass it.

## Response publication (N23, N34)

BridgeBase and its bounded auditor share one recursive lifecycle lock. After
initial lookup, response consumption rechecks the captured session and the live
command registration under that lock. Removal (except an ongoing feed), proof
permit completion, description/scope mutation and synchronous publisher delivery
form the same decision as Base retirement and transport replacement. The lock is
never held across an async operation. Get completion belongs to cid, not keypath;
an old timeout or response cannot consume another get on the same path. A Future
also preserves a response delivered before the caller starts awaiting it.

Set and description calls also register a cid-owned Future before sending, with
an explicit captured session. Send admission must still belong to that session.
A malformed reply fails only that waiter; close fails all of that Base's waiters.
Timeout/send-error cleanup removes only its cid and proof permit. Concurrent
same-keypath sets and descriptions therefore cannot overwrite or complete one
another. The old keypath-only `sendSetValueResponse` helper was removed; protocol
responses must use `consumeResponse` with the registered cid and session checks.

## Outgoing feed ordering (N27)

One worker drains each Base feed in publisher delivery order. Admission happens
synchronously under the lifecycle lock, before a task can reorder values. At
most 32 queued/in-flight values per Base retain the existing per-key/global
operation budgets and pending-send byte budgets, including through completion.
The transport separately charges its wire copy; no quota is bypassed. There is
no persistent replay or remote processing acknowledgement implied by send return.

Upstream completion is a terminal marker behind all admitted values, including
for a synchronous finite publisher. Successful drain releases the feed lease and
marks the sender inactive. The existing wire protocol has no feed-finished frame;
this change does not claim remote subscriber completion. An upstream failure
may signal revoked authorization, so it immediately fails queued values and
closes the captured transport. Encoding, admission or send failure also explicitly
fails the remaining queue and closes that transport;
a logical mux close preserves siblings. Stop/retirement discards queued values,
while an already admitted physical send keeps its operation, bytes and feed lease
until return. Late work cannot reactivate a replacement generation.

These guarantees order one publisher's values before WS/mux/peer submission.
Scanner's receive-side dispatch ordering remains a separate guarantee.

## Mux send ownership (N24)

The server reserves a logical channel ID atomically with its object identity
check, retains the old record/channel quota, and keeps the reservation through
queued physical `sendData`. A close removes that record from dispatch, but an
open with the same ID is rejected until every admitted send returns. Pending
opens and their control responses also reserve their ID across factory and
rejection-audit awaits. Retained IDs count toward channel capacity. Sibling IDs
remain usable within existing quotas.

This is local fencing, without a new wire generation. Physical transport
`sendData` must not return success before handing over its bytes; an exception
must mean that no later handover can occur. A non-cooperative send keeps its
reservation until it actually returns. Bytes already handed over before close
cannot be recalled. This is not N18's OS queue/receipt resource guarantee.

## Factory results (N25)

A WS/peer server factory owns its provisional delegate until it returns. Its
`setDelegate` calls do not publish that result. The gate adopts the returned
result under its terminality lock; close takes that same ownership exactly once.
An exception before adoption retires the result, including a revoked/expired
session after a factory await. Base activation and peer-ready publication cannot
race gate close. A stopped gate cannot acquire a new delegate or expiry timer.

Mux similarly wraps every returned delegate in a record before any throwing
post-factory check. Record retirement is idempotent. Work and channel reservations
remain retained until non-cooperative work and asynchronous cleanup finish.
A factory which throws before returning an object still owns cleanup of its own
unreturned resources.

## Private-key admission (N26)

WS connect operations validate their original ten-second monotonic deadline,
wall-clock challenge, cancellation and local active state again after the vault
existence lookup, immediately before signing, and after signing. Peer v3 retains
its equivalent checks and local disclosure-policy rechecks for both roles.

Origin proofs freeze a monotonic window from the challenge's remaining validity
before any lookup. They revalidate challenge time, captured session, cancellation
and the exact local operation permit after containment, vault lookup and replay
lookup, immediately before signing and after return. Non-feed local permits also
have their own five-second monotonic deadline. A different active operation in
the same scope cannot revive a captured permit. Feed permits can stay active,
but cannot extend an individual signing challenge.

Regression evidence lives in `BridgeResponseLifetimeTests`,
`BridgeFeedAndRPCOrderingTests`, `BridgeMuxSendLifetimeTests`, `BridgeFactoryLifetimeTests`,
`BridgeSigningLifetimeTests` and `BridgePeerV3Tests`. The barriers deliberately
ignore task cancellation and hold work at the relevant lifetime boundary.
