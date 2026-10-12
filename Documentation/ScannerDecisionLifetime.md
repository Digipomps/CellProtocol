# Scanner decisions, retirement and retention

This follow-up to Bridge PR #53 addresses review findings N32 and N36–N39.
It keeps the authenticated transport and resolver authority checks. The local
UI selectors described here are not credentials, grants or remote identities.

## Consent selects one retained instance

Contact and detail notifications contain a locally generated `decisionID`.
`acceptContact` and `probeDetail` approval require that ID as well as the remote
session/request selectors. The pending record remains bound to the original
physical channel, authentication generation and proved signing identity. Its
payload is a deep immutable snapshot; consumption is one-shot before suspension.
Expiry or reconnect can reuse an external request ID without reusing consent.
A stale action neither consumes the fresh record nor sends/persists its result.

Contact action payloads contain selectors, not a copy of the signed request.
Detail notifications also expose `selectedReferences`; the retained decision
freezes those references. Approval intersects them with the still-active policy
and overlap, so an intervening expansion cannot disclose additional references.
A revoked policy still denies the action. The wire request/response format and
owner access checks are unchanged.

Invitation accept/reject payloads contain `invitationID`, selecting the existing
local invitation object. The service checks it and its generation under the
state lock before taking the one-shot handler. New setup, physical peer or
service instances cannot inherit an old accept or reject action. UI clients must
forward the published action payload; manually reconstructing legacy selectors
is deliberately rejected.

These checks are local and introduce no network round trip. This is a code-level
property, not a measured latency distribution.

## One lifetime owner

Before releasing its service reference, the cell stops it and synchronously
drains its terminal lifecycle publication. Repeated stop remains idempotent.
Delegate callbacks recheck service identity at the consumer; queued callbacks
from a replaced service cannot publish state for its replacement.

Outgoing aggregate operations own their `.probing` state through the pending
record's local decision ID. Expiry, failure and channel retirement remove that
owned state together. Late cleanup cannot reset a new operation. Automatic
probe scheduling also owns a local token and checks it after suspension.

## Fixed retention bounds

Bounds below apply to each consumer. Existing process-wide physical/discovery/
consumer admission and pending-request budgets remain in force.

| Retained state | Fixed limit | Retirement |
| --- | --- | --- |
| Radar entities | 128; 256 KiB total accounted data; 8 KiB per entity | Peer retirement and service maintenance, even without radar GET |
| Radar metadata | 128 device names and 8 KiB; status string 256 bytes | Replacement or clear |
| Probe request/nonce history | 512 records, 128 peers, 128 KiB | Original local approval deadline; explicit scanner stop |
| Probe result snapshots | 128, 160 KiB; payload 1 KiB and remote ID 128 bytes | 60 seconds, peer retirement or stop |
| Probe rate timestamps | At most 512 and the lower policy limit | Sliding 60-second window |

The byte counters bound retained data with fixed per-entry overhead; they are
not a measurement of allocator overhead or process RSS. Oversized updates do
not replace already accepted radar entries. Capacity rejects new disclosure
requests rather than evicting replay guards. Peer loss/reconnect removes
presentation results but preserves approval-scoped replay/rate history. The
service's existing maintenance tick owns pruning; reads are not required.

This deliberately favors bounded memory and conservative disclosure under a
flood. A saturated approval history can deny new probes until its approval
window ends or the owner explicitly stops the scanner. It does not grant a
new quota merely because a peer reconnects.

## Acceptance scope

Regression tests exercise the actual published UI payloads, TTL/ID reuse,
same UUID with a different signing key, new physical peers, service replacement,
real cell stop, first probe after reconnect and late cleanup. Retention tests
exercise count/byte limits over many discovery and rate windows without radar
polling, and prove that result retirement does not remove replay history.

N35's established-channel independence remains specific to the Vapor mux
adapter. This patch does not implement native Apple WebSocket channel dispatch,
automatic subscription continuity across the five-minute authentication expiry,
or a physical Nearby Interaction/UWB test. Those remain separate verification
and integration work; local Scanner tests do not certify a deployed Bridge.


## Local verification, 2026-10-05

Apple Swift 6.4 / Xcode 27.0, two bounded build jobs: the full package passed
1,567 XCTest tests across three targets, with five skips and zero failures.
The three actual published-action regressions fail with 34 assertions when
only the local pending/invitation instance checks are removed, then pass after
byte-exact restoration. This is a controlled behavior reversion, not an untouched
historical checkout. Source and raw-log hashes are recorded in
`Documentation/Evidence/ScannerDecisionLifetime_2026-10-05.json`.

The stock external preflight reports two false/policy-drift blocks: its disk
rule still assumes 10% instead of the user's explicit 40 GiB AND 5% floor, and
its CI-filter detector misses the unfiltered full-suite command when it also
finds a separate TSAN filter. The actual bounded capacity gate passed with its
10 GiB reserve. The macOS workflow already runs the full package before TSAN;
no CI filter or global preflight rule was weakened for this patch.
