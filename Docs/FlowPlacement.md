# Flow placement

Last verified against code: 2026-11-20 (`Sources/CellBase/Flow/FlowPlacement.swift`,
`EntityAnchorCell` in CellApple and CellVapor).

Purpose: when an entity gains access to a cell that emits Flow, the entity decides
which of its own runtimes consumes that Flow. No runtime holds a configured
address for the publisher. PDD: `CellProtocolDocuments/Deliverables/PDD_flow-plassering_2026-11-07`.

Placement never grants access. The publishing cell still authorizes every element
against the requester's contract (see `ActiveFeedAuthorization.md`). A placement is
only a choice of where to ask.

## Model (CellBase)

- `FlowSource`: a cell the entity has access to, with a fully qualified endpoint
  (`cell://<host>/<path>`), optional topics, the purposes it is wanted for, and the
  grant it came from. `FlowSource.sources(fromLinkCompletion:host:purposes:)` reads the
  `cells[]` an identity-link completion returns (PalazzoScaffold's
  `PalazzoIdentityLink.complete`). Only cells with a signed contract are taken.
  `cell:///<uuid>` is qualified with the host the client talked to; an endpoint that
  names another host is refused.
- `FlowVenue`: a runtime of the entity (`agent`, `app` or `homeScaffold`) that
  reports itself. A report expires, at most 24 hours after it was made.
- `FlowPlacementPurpose`: `present`, `notify`, `store`, `agentJob`. Unknown values fail
  to decode.
- `FlowSubscription`: a flow the person set up, so one more of their runtimes follows
  a source for given purposes, beside the default placement. One per (source, venue);
  adding again replaces its purposes. It grants no access.
- `FlowPlacementPolicy.decide`: one default decision per (source, purpose), then one
  more per subscribed venue. A cell has one output and as many inputs as it wants
  (Kjetil 2026-11-20), so many venues may follow one source; a venue never gets the
  same (source, purpose) twice. Defaults:
  - `present` goes to an online app that shows that source's surface.
  - `notify`, `store` and `agentJob` go to an online agent, otherwise to the home
    scaffold. The home scaffold is the person's own, never the publisher's.
  - Ties go to the most recent report, then the lowest venue id.
  - An expired source, or no fitting venue, gives a decision without a venue and with
    a reason.
  - A subscribed venue that is offline, or a source that has expired, adds nothing.
    Removing a source removes its subscriptions.

## EntityAnchor keypaths

Both anchors (CellApple and CellVapor) implement these through `FlowPlacementLedger`:

| Keypath | Method | Value |
|---|---|---|
| `flowPlacement.state` | get | `{status, sources, venues, subscriptions, decisions}` |
| `flowPlacement.sources.add` | set | a `FlowSource`, a list of them, or `{linkCompletion, host, purposes, topics?}` |
| `flowPlacement.sources.remove` | set | `{sourceID}` |
| `flowPlacement.venues.report` | set | a `FlowVenue`; `reportedAt` is set by the anchor |
| `flowPlacement.venues.withdraw` | set | `{venueID}` |
| `flowPlacement.subscriptions.add` | set | `{sourceID, venueID, purposes}`; the source must be in the book |
| `flowPlacement.subscriptions.remove` | set | `{sourceID, venueID}` |

Only the owner or a verified same-entity linked identity may read or write these. The
anchor's agreement template has no `flowPlacement` grant, so no contract opens it. Each
change is persisted under `flowPlacement.book` and emits a FlowElement on topic
`flowPlacement.decisions` carrying the new decisions. Writes are serialized per anchor.

## What a runtime does

1. After it gains access (for example a completed identity link), it writes the
   sources to its entity's anchor.
2. It reports itself with `flowPlacement.venues.report` and repeats before the report
   expires.
3. It reads `flowPlacement.state` (or listens on `flowPlacement.decisions`), and for
   each decision naming its own `venueID` it attaches with a `CellReference`
   (`subscribeFeed: true`) through `CellResolver.loadCell`.

Not implemented here: runtime clients (HavenAgentD, Binding) and moving a running
subscription when the decision changes. Those are WP3–WP7 of the PDD.
