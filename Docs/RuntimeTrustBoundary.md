# Runtime trust boundary

Network and user-session adapters use requester-bearing Emit/Meddle methods and
the resolver's Identity/Agreement/Grant enforcement. GeneralCell.flow(requester:)
also revalidates active subscriptions. Raw getFeedPublisher() and mutable Swift
policy properties are retained for trusted host composition compatibility. They
are not an isolation boundary against code already running in the same process.
Do not hand those references to untrusted plugins or external session adapters.

FlowElementPusherCell is an ephemeral local producer. Requester-bearing access
and mutation require the exact owner object supplied at construction. A decoded
or copied identity is not that local capability. Its legacy no-requester feed
methods remain trusted host APIs. The helper rejects Agreement signing requests;
it must never report a Contract as signed without signing one. Use GeneralCell
when a feed needs remote identity proofs, membership and revocation.

Commons PermissionEvaluator evaluates metadata using supplied role/consent
strings. Its allowed result is advisory and supplies no verified data-access
authority. Commons resolution does not replace the authorization check when
fetching an Entity value. A service role string is not a runtime capability.

Replay and determinism require a stated path and evidence. Ordinary live feeds
are not a durable event log, and asynchronous network delivery does not imply
global ordering or replay. Entity authority journals and explicit replay
contracts must be assessed using their own invariants and persistence tests.

Security release host gates must exercise protected discovery, nested scopes,
direct EntityAnchor construction with durable keys, and external feed adapters.
The implementation does not claim retroactive erasure of received data, backups
or historic log records.
