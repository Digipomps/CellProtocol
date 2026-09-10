# Active feed authorization

`GeneralCell.flow(requester:)` still requires authorization before returning a
publisher. Each subscription also checks current authority before delivering
each element. Holding an old publisher does not preserve a revoked contract.

Both `removeMember` overloads revalidate affected live subscriptions before
returning. Subscriptions that lost access terminate with denied access. An owner,
another member, or a reader with independently valid access remains connected.
Contract expiry, changed conditions and a changed agreement template are checked
when the next element is processed. An idle stream need not emit an immediate
expiry notification; it cannot use its earlier admission to deliver another
private element. Opening a new stream after expiry requires fresh authorization.

Authorization is asynchronous and serialized for each subscriber. A bounded
queue holds at most 256 pending elements plus the active check. Overflow fails
explicitly and cancels the subscriber's pending work. Valid bursts preserve
order; ordinary upstream completion drains the authorized queue and completes.

For forwarded events, a process-local delivery ticket extends the existing
forwarding reservation through authorization and downstream delivery. Waitable
detach therefore still waits for an in-flight downstream callback to return.
Generation invalidation suppresses queued stale deliveries. Tickets are not
persisted and do not change FlowElement or bridge wire formats.

The raw `getFeedPublisher()` API remains a trusted in-process runtime surface.
It is not a replacement for `flow(requester:)` at an untrusted boundary.

For bridges, revocation cancels the server subscription and prevents forwarding
new events. Messages already authorized and passed to the transport cannot be
retracted. The current bridge protocol does not acknowledge remote feed teardown;
these changes do not claim a remote completion acknowledgement or replay.

Acceptance evidence includes local and two-client serialized bridge revocation,
a controlled per-Cell clock for expiry and renewal, condition/template changes,
ordered bursts, stalled-check overflow, cancellation, normal completion and the
existing waitable-detach and cross-thread overflow integration regressions.
