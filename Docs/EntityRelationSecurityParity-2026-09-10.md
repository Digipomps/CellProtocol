# EntityRelation integration and security boundary

The integration takes only feature commit `2bbc062329456fe70977c48d3e6743b9dcc7dee9`
and parity fix `50b1490c701c8db43dbda4658a2b3ad3b5741453` onto the security
release. Unrelated correspondence, radar, identity-link and skeleton changes
from the feature branch are not included.

Both Apple and Vapor EntityAnchor now admit `relations.records.<id>` and
relation chronicle events through the same owner-authorized batch path. Direct
writes, ancestor replacement, selector aliases, partial record deletion,
unknown JSON fields and mismatched bindings are rejected. Deletion is a null
mutation at exactly one validated relation ID. Other relation families retain
their existing access paths. Whole `relations` or `chronicle` replacement is
intentionally rejected because it could erase a protected family.

Interaction capture defaults to metadata. `off` never admits an event; full
content requires an already stored `person.relations.interactionPolicy` string
of `full`. An event, or a simultaneous mutation in its own batch, cannot grant
that permission. Malformed stored policies disable capture. Setting this policy
is an owner-controlled Entity operation, not proof of a third party's consent.
A `blocked` standing is not cleared by an invite-joined event.

## Versioned event storage correction

The unmerged feature's v1 event encoded its short logical ID in `id`, but used
`chronicle[id=relation-event-<relation>-<event>]` as its storage address. The
actual Object list writer retained the short ID, so a later lookup missed the
stored entry and repeated writes could append duplicates. Real Apple/Vapor
collision tests exposed this during integration.

New events explicitly use `haven.relation-interaction-event.v2`:

- `id` is the full chronicle selector ID;
- `eventID` is the logical event ID exposed as Swift `event.id`;
- `relationID` and the remaining metadata keep their meanings;
- the record schema and batch operation remain v1.

The shared golden JSON is `Tests/CellBaseTests/Fixtures/EntityRelationEventV2.json`.
The decoder still reads and re-encodes legacy v1 values without silently
claiming they were migrated. New persistence rejects v1 events. Feature-branch
consumers must generate v2 with the updated codec; existing v1 chronicle rows
need an explicit owner-reviewed migration before they can participate in v2
addressed updates. No existing user files are migrated by this integration.

The historical hyphen-separated address can collide across relation/event ID
pairs. Both hosts check current and within-batch event content before writing;
an identical event is allowed, while a conflicting binding/content is rejected.
The matrix proves this using real storage and restart, not only a pure validator.

## Limits

Relation data is owner-private. Rejecting raw addresses in channel references
is not a general personal-data scrubber: names, notes and declared fields remain
private data and must not be published merely because the record validates.
Standing/evidence references do not themselves verify a credential or grant
access. The reach planner proposes actions and does not send messages.

`applying` is a local ordered fold, not a deduplicating CRDT. Repeated events
must be deduplicated by the caller's operation history. Existing signed Entity
commit requests retain their journal semantics; legacy owner-authorized
unsigned batches remain local snapshots without a receipt. This change does
not promise cross-replica convergence or automatic historical-data migration.

Verification includes a red regression (three new tests, 13 failed assertions
before hardening), pure positive/negative admission, v2 golden/legacy read,
actual Apple/Vapor writes, duplicate/collision denial, policy enforcement,
encrypted restart and full package regression. Exact final counts and CI are
recorded in the integration receipt.
