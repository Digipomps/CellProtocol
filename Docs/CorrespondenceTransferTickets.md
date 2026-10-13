# Attachment transfer tickets (candidate)

An authenticated transfer start may request `requestTransferTicket: true` on
`attachments.prepare` (upload) or `attachments.metadata` (download). The latter
requires the exact `attachments.fetch` grant. After ordinary `authorizeAttachment`
authorization, the response plan includes optional `transferTicket`. The client
sends it only on `attachments.upload` or `attachments.fetch`, respectively.
Old clients omit these fields and retain the original proof-per-operation path.
A new client can use the original path when an old server omits the optional
response field; a supplied invalid ticket never falls back to identity proof.

Tickets are 32 cryptographically random bytes, opaque base64, stored only in the
hosting CorrespondenceCell's memory. They bind requester UUID and signing-key
fingerprint, hosting Cell, sender, message, Agreement, attachment, exact action,
and the authenticated physical session captured for the start command. A remote
bridge without an authenticated session cannot issue a ticket. In-process calls
have no physical channel; their ticket remains an identity-scoped bearer secret.
Restart loses all tickets. Tokens are absent from persisted plans, events,
message envelopes and client download records.

Expiry is 120 seconds of inactivity, extended only after successful bits, with
an absolute 600-second maximum. Both wall time and monotonic uptime enforce the
limits. The shorter physical channel lifetime still applies; connection renewal
does not renew a ticket. The registry permits eight tickets per UUID/key pair
and 1024 per Cell. Expired entries are pruned before admission/use. These are
per-Cell limits, not a global account quota. An interrupted ticket expires; the
caller starts another transfer with ordinary authorization.

Every bit refreshes the authoritative membership snapshot without signing, then
checks the exact active subject key, grant and temporal bounds at the synchronous
storage effect. An authorization mutation first fences admission and invalidates
tickets, before the auditor mutation; completion releases that fence. The Cell
membership lock and authenticated-session effect lock cover the storage operation.
Callbacks/events run after these locks are released. A second check precedes the
returned bytes/success. A ticket cannot have two simultaneous bits in flight.
Final bits remove their ticket. Attachment revoke invalidates its tickets and
fences concurrent issuance; all membership/contract mutations conservatively
invalidate all of the Cell's tickets. Failed issuance after prepare revokes the
newly created storage entry.

The generic Resolver and GeneralCell permission model does not accept tickets
as grants. Only the four exact CorrespondenceCell SET paths inspect this payload.
The authenticated Bridge dispatches to that SET boundary. Calling Resolver.set
locally still adds its normal preflight proof; performance evidence must identify
the path used. Storage quotas, disk reserve, byte bounds and chunk validation,
12/60-second signing policy and #67's backpressure remain unchanged.

Tests and measurements are reported separately; this document describes the
candidate contract, not deployment or production acceptance.
