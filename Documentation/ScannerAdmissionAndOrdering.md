# Scanner ordering and invitation ownership

Scanner opens peer v3 records in physical callback order. It then admits normal
application dispatch to a second ordered chain, awaiting consumer completion.
An origin-sign command or response to a locally registered sign command may
run independently so an operation can receive the proof it is waiting for.
A signature-shaped payload alone never selects that lane. Both lanes retain all
normal gate/session/permit checks. WebSocket framing and dispatch are unchanged.
This orders received records; it cannot repair reordering by an application
producer before physical submission. EntityScanner's detached asynchronous
consumer work remains the separate N13 contract.

Each pending, accepted or outgoing invitation owns a fixed MCPeerID, MCSession,
service instance generation, endpoint, local instance ID and monotonic deadline.
Discovery indexes are only advertisements, never the owner of invitation state.
Taking a pending handler, installing accepted state and invoking the result use
one state-queue transition. The handler is resolved exactly once. Crossed
invitations choose one setup without renewing pending deadlines. Discovery loss
cannot retarget the binding; the same physical peer cannot change its name in a
pending setup. Gate creation transfers the binding and retires invitation state.
One service timer expires all invitations, including accepted/outgoing setups
that never create a gate. Stop retires the service generation and MCSession.

Timeout calls cancelConnectPeer for unfinished attempts. This is not an assertion
that an already connected Multipeer peer has been physically evicted (N15).
A late MC callback has no invitation authority; channel authentication still
requires the exact fresh endpoint/setup, proof and Finished. MC callbacks carry
no application setup ID; fresh proof, rather than callback arrival, is decisive.

## Pre-authentication admission

All Scanner instances share `ScannerAdmission.shared` in production. Tests can
inject an isolated ledger and monotonic clock. Reservations precede metadata and
handler retention, queued main-actor work, and publication. Costs are retained
UTF-8/context payload bytes plus 256 bytes per entry, not a measurement of Swift
heap or Multipeer OS allocation. Count limits also bound object overhead.

| Resource | Global count / bytes | Per MCPeerID count / bytes | Lifetime |
|---|---|---|---|
| Discovery | 128 / 128 KiB | 1 / 4096 | 60 s, refreshed only by admitted discovery |
| Invitations (pending + accepted + outgoing) | 32 / 64 KiB | 1 / 4096 | min(local invitation timeout, 30 s) |
| Context/setup work | 16 / 64 KiB | 2 / 8192 | 10 s |
| Queued UI notification batches | 64 / 64 KiB | 8 / 8192 | 5 s |

One fixed ten-second rate window permits 256 reservations globally and 24 per
MCPeerID, across all four resources. Capacity-rejected attempts consume rate;
oversized inputs are rejected before source bookkeeping. The source table has
at most 256 entries and expires idle entries after 60 seconds on its next use.
Active reservations keep their bucket alive. Discovery permits at most 32
metadata fields and 512 UTF-8 bytes for its correlation UUID. Invitation context
is checked before decoding; its 4096-byte bound includes the fixed 256-byte cost.
Invalid contexts cannot fall back into a bridge invitation.

A single main-actor drain references a bounded queue of entries. The timer can
remove expired entries (and reject their pending context handlers) even while
the main actor is busy; the scheduled task does not capture all payloads. Stop
clears the queue and prevents old-generation publication. Executing setup work
retains its reservation until it returns, including after expiry/cancellation;
expiry never frees quota for still-running noncooperative work. Each physical
setup gets at most one setup wrapper; each Data callback no longer creates one.
Expiry resolution/status UI is best effort under the same event limits, while
invitation handlers are always resolved. Downstream asynchronous EntityScanner
work is still N13, not a claimed bound supplied by a synchronous UI callback.

A source is the best physical handle MC exposes here: MCPeerID equality, with an
opaque local token passed to the channel gate. Discovery UUIDs and display names
never create source buckets. This does NOT establish a stable adversary/device
identity: a Sybil can mint different peers and exhaust global capacity/rate.
No honest-admission guarantee is possible during full global saturation. Bounds
limit retained application state and work; they do not bound allocations made by
Multipeer before calling this delegate or establish N14/N15/N18 OS guarantees.
After expiry or release, a fresh legitimate invitation can be handled again.
