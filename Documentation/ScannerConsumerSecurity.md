# EntityScanner consumer lifetime and contact proofs

EntityScanner's delegate is async and runs on MainActor. Scanner awaits it
inside the existing gate's authenticated work reservation. The receive byte
reservation and ordered application dispatch also remain held until it returns.
There is no detached contact handler, separate authentication state machine, or
ready exception. An immutable local context captures the exact Scanner service,
physical adapter, session/generation, local identity and proven remote descriptor.
It cannot be constructed from payload UUIDs. Responses use that captured adapter,
never a new channel found by discovery UUID after an await.

All EntityScanner mutable state, action intercepts and delegate callbacks run
on MainActor. Discovery/status events use Scanner's existing bounded notification
queue. A physical frame source schedules setup once, including after completion;
ingress overflow reuses the one existing rejection task before allocating more
work. The process-wide gate limits still bound admitted asynchronous work. A
closed consumer which ignores cancellation keeps its lease until it returns.

The consumer checks lifetime after verification, resolver/perspective access,
local vault operations, sends and storage resolution. Final synchronous state
effects linearize with session close/revoke under the existing session lock and
Scanner binding queue. Cell-owned events use the existing runtime-bound synchronous
emitter; they do not start another untracked publication task. Synchronous
subscribers run outside the session lock and can revoke without deadlocking;
each notification has its own admission check. An already admitted notification
cannot be recalled, and reentrant revocation prevents the next notification. Downstream Cells
remain responsible for their own authorization and effect lifetimes.

## Pending records and replay

One MainActor table combines incoming contacts, outgoing contacts and incoming
detail requests. Each record binds its request ID to its kind, exact channel,
principal and generation. Payloads are copied to their wire representation before
retention, so a mutable Identity reference cannot change a stored proof.

| Bound, per EntityScanner instance | Value |
|---|---:|
| Total retained entries, including consumed records | 128 |
| Entries per remote peer across kinds | 16 |
| Total canonical payload bytes | 1 MiB |
| Canonical payload bytes per remote peer | 128 KiB |
| One canonical payload | 64 KiB |
| Request ID | 128 UTF-8 bytes; contact IDs are canonical UUIDs |
| Pending lifetime | 60 monotonic seconds, never refreshed by replay |

The cell is scoped to one app/identity. These are limits across all its peers;
they are not a process heap measurement. The transport's shared admission/work
limits apply independently across Scanner instances. Full global saturation can
deny honest work; a peer reaching only its own limit leaves other peer capacity.

Invalid requests are discarded before retention or contact state transition.
A one-shot consume marks the record before any later await; concurrent duplicate
verification cannot claim it again. Consumed records remain charged as bounded
replay tombstones until their original deadline. One timer prunes idle records;
every lookup/insertion also checks deadline and channel validity. Retirement
removes that generation, while service stop clears the cell's table. Cancellation
does not release the separate gate work reservation prematurely.

## Contact validation and wire representation

`entity-contact-v1` retains its field names. Hashes and signatures now use
`FlowCanonicalEncoder` over the JSON-round-tripped Object, rather than over
Swift-only ValueType tags. The generic JSON codec encodes Identity as an object,
Data as base64, and may decode an integer-valued float as integer. Normalizing
before signing makes the exact proof stable on the real wire and after reload.
Signature base64 is canonical; verification uses only the embedded public key.
Old signatures over non-round-trippable Swift tags are not accepted via fallback.
The general ValueType codec, WS profile and mux framing are unchanged.

Before consuming an outgoing request or changing contact state, acceptance must
have the exact type/version, request ID, encounter ID, canonical hash of the
entire signed request, local requester session, remote responder session and
local target UUID. The responder identity UUID and full descriptor must equal
the channel's proven principal; same UUID with another key is rejected. No
identity delegation is currently implemented or implicitly inferred. The
acceptance's own hash and signature must also verify. Signed createdAt must be
finite, newer than 60 wall-clock seconds and no more than 5 seconds in the future;
the pending record's independent monotonic deadline is checked after verification.

Incoming requests have equivalent type/version, time, target/session, self-hash,
signer UUID/descriptor and signature checks. Local acceptance uses the retained
verified request, not the UI's supplied proof contents. Signatures are made only
by the current local owner's non-proxy vault after identity lookup and lifecycle
revalidation. Channel admission still grants no Cell capability.

## Actual encounter commit

Scanner resolves the local EntityAnchor through the normal resolver. Its internal
encounter commit checks owner proof and existing `proofs`/`relations` write
authorization, takes EntityAnchor's commit gate, checks the authority journal,
and creates one encrypted snapshot containing both proofs, relation and trace.
The final channel check, atomic file replacement and in-memory installation are
one synchronous effect. A close that wins first prevents the write, including
when verification, resolution or storage preparation was suspended. A commit
that already won cannot be undone by later revocation. Publication rechecks the
same channel separately. This is not a distributed or power-loss/fsync guarantee.

Encounter IDs are UUIDs and cannot overwrite an existing encounter. The remote
identity's storage key is limited to 128 ASCII letters/digits, dash or underscore,
preventing keypath injection. Other identity formats can authenticate a channel
but cannot use this contact storage path. An arbitrary Meddle storage backend is
not used as a fallback because it cannot provide this final guarded commit.

`EntityScannerConsumerSecurityTests` uses real handshakes, the actual consumer,
normal resolver/owner authorization and encrypted EntityAnchor files. It covers
individually signed bad bindings, unrelated/same-UUID signers, another channel,
simultaneous accepts, two-sided contact exchange, retained work at verification/
resolver/storage barriers, revoke/reconnect, TTL and count/byte floods. Controlled
barriers do not replace verification or persistence. Native MC transport and
Thread Sanitizer runs are reported separately in the N13/N20 handoff.
