# Peer physical lifetime and flow control

N14/N15/N18 extend the unreleased peer v3 implementation. The `HPC3` header,
Kapp derivation, nonce, AEAD and handshake are unchanged. Application plaintext
inside each record now has the mandatory binary framing below; earlier v3
application plaintext is rejected. There is no negotiation or fallback.
The WebSocket profile and mux wire formats are unchanged.

## Physical ownership and unused MC entrances

Scanner allocates one `.required` MCSession per invitation/physical peer, never
reusing it for a replacement generation. Invitation and adapter capture that
exact object. `disconnect()` therefore retires only that peer. `cancelConnectPeer`
is not used to evict established peers. Stop retires every owned session.

Physical admission is process-wide through ScannerAdmission: 32 slots, 8192
accounted metadata bytes; per physical MCPeerID 2 slots/512 bytes. Slots are
reserved before MCSession allocation and remain charged during retirement until
`connectedPeers` is empty. Gate close awaits this retirement before releasing
transport and outstanding send reservations. Expiry of a logical lease alone
does not release the physical slot. These are object/connection counts, not an
assertion that every OS allocation has been freed at that instant.

All resource transfers are cancelled at `didStartReceivingResource`; all input
streams are closed at `didReceive stream`, even for obsolete callbacks. The
exact owning session is disconnected once, without spawning per-callback error
work or logging attacker-controlled resource names/errors. The finished-resource
callback neither opens nor moves the temporary file. Stale callbacks cannot
select a new connection by discovery UUID. These MC side channels are unsupported.

## Record plaintext and receipt contract

Integers are unsigned big endian. Each plaintext is:

```
kind:u8 || random:32 || receiptCount:u8 || receipts:(counter:u64 || digest:32)* || payload
```

Kind 1 is application data with a nonempty BridgeCommand payload. Kind 2 is
an internal receipt, with at least one receipt and no trailing payload. Unknown
kinds, malformed sizes, more than 64 receipts, duplicates, nonexistent/future
counters and mismatched digests are terminal. The random 32 bytes are generated
locally by Crypto for EVERY record, independently of Kapp. A receipt's digest
is SHA-256 of the **entire sealed wire record**, including header, ciphertext
and tag. The generation and direction are therefore bound both by AEAD and by
the digest; the acknowledged counter belongs only to this gate's send map.
The peer cannot pre-acknowledge a guessed counter using Kapp alone. Receipt
validation is all-or-nothing before any quota is released.

Every record, including receipts, uses the next counter under the existing
directional Kapp. No new key, plaintext auth message, Cell authority or ready
exception exists. Public sendData cannot inject a receipt: it accepts only an
application BridgeCommand, which is wrapped as kind 1. Only the gate's physical
receipt submission path creates kind 2.

Data records retain exact wire-byte reservations after MCSession.send returns.
Release requires a valid receipt, or physical retirement completing. There are
at most 32 outstanding data records and 2 MiB of data wire bytes per connection,
in addition to existing shared send quotas. Overflow closes that peer; producers
do not accumulate an unbounded waiting queue. Lack of a data receipt for 10
monotonic seconds retires the peer, checked by one timer per gate.

Receipt records have a separate count limit of 64 and still consume existing
shared byte quota. At most 64 receipt entries can be pending for piggybacking.
Receiving data generates a receipt after bounded adapter admission, before Cell
dispatch. Receiving a receipt never generates another receipt. Its confirmation
is piggybacked on the next data/receipt record; otherwise its bounded reservation
lasts until normal channel expiry or physical close. A full data window therefore
does not consume the receipt count allowance. Extremely small/custom shared byte
limits can still fail closed instead of permitting control progress.

The existing 1 MiB record plaintext maximum includes this framing (34 bytes
plus 40 per piggybacked receipt), so application capacity depends on pending
receipts. The outer AEAD overhead remains 65 bytes. No sender payload/ciphertext
copy is stored in the flow ledger: only digest, counter, byte count, kind and
deadline. A receipt proves protocol receipt/admission, not Cell completion,
persisted state, honest remote processing or release of every kernel buffer.

## Ingress and memory boundary

Scanner admits at most 64 complete callbacks and 4 MiB of their wire Data per
adapter before asynchronous work, with maximum frame 1 MiB + 65. With the
32-slot physical cap this bounds retained callback Data to 128 MiB, excluding
decoder/plaintext/object overhead, executing Cell work and framework allocations.
The per-record cap also bounds the flow decoder; the pending/outstanding receipt
tables are bounded independently of attacker counters. Existing gate/work quotas
and Scanner admission still apply.

MC materializes/reassembles a Data message before invoking the delegate. Its
public API exposes no configurable reassembly byte ceiling or preallocation
hook. Consequently these limits **do not establish a hard bound on MC's memory
while a hostile peer sends an oversized message before the first callback**.
The callback rejects that message and physically disconnects its isolated
session. Native RSS observations are measurements of the tested workload, not
a vendor-guaranteed worst-case OS bound. Supporting arbitrary hostile reassembly
with a strict preallocation bound would require a transport exposing that control.

Apple WebSocket text/data sends now await their actual completion callback and
propagate failure to the gate, which holds the original send lease until return.
There is no new WS receipt format. URLSession completion and remote application
consumption remain different events.

Sources: [MCSession](https://developer.apple.com/documentation/multipeerconnectivity/mcsession),
[resource transfer](https://developer.apple.com/documentation/multipeerconnectivity/mcsession/sendresource(at:withname:topeer:withcompletionhandler:)).
