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
