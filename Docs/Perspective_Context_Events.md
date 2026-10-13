# Perspective context events

Last verified against code: 2026-10-12, candidate based on 253b4afe.

PerspectiveCell subscribes to configured semantic source Cells. Sources interpret
location areas, time windows, physical/digital presence or significant news events.
Perspective does not implement GPS, geofencing, schedules or presence detection.

## Source contract

Source get key defaults to `context.observation`. Source Flow topic is
`context.observation.changed`, object content (`contentType: object`, type event).
Every payload is a full source snapshot, not a delta. JSON dates are ISO 8601 UTC.

```json
{"schemaVersion":1,"revision":12,"observedAt":"2026-10-12T07:00:00Z","validUntil":"2026-10-12T08:00:00Z","transition":"entered","labels":["home"],"configurationRevision":3}
```

`transition` is snapshot, entered, left or configurationChanged. Source revisions
are nonnegative and strictly increase for changed data. Snapshot get returns the
last observation unchanged, including transition. FlowElement.id identifies an
event; the source ID comes from the configured subscription label, not origin.
Same revision/different observation is rejected; older revisions and duplicate
observations have no effect. Configuration revisions must be nonnegative.

An empty labels list is known absence. Missing, expired, disabled and unconfirmed
sources are unknown. Labels are case/diacritic normalized by the existing Goal
engine when matching. Observed times over 30 seconds into the future are rejected.
There may be at most 128 unique nonempty labels, each up to 256 UTF-8 bytes.

Source bindings use the requesting Perspective owner's existing resolver/admission
rights. Authorizing a rule never grants new access to a source or to content.

## Perspective operations

| Method | Key | Shape |
|---|---|---|
| get | perspective.context | state (ContextDecision) and configuration |
| get | perspective.context.state | Nested state through perspective root |
| get | perspective.context.configuration | Nested configuration through perspective root |
| set | perspective.context.configure | ContextConfiguration; acknowledgement/error |
| set | perspective.context.sources.attach | Configured sourceID string; re-enable and reconnect |
| set | perspective.context.sources.detach | Configured sourceID string; persist disabled state and disconnect |

The existing perspective root includes state and context. Read permission uses
`perspective`; mutations use its write permission. Runtime readiness restores
configuration and source revision history from PerspectiveContext.json, a separate
Cell-local file. Confirmations are never encoded. Authorized snapshot reads can
reconfirm the same saved revision after restart. Flow subscription and ordinary
purpose queries also reconnect configured sources. Disabled bindings remain disabled
across restart. A changed source endpoint/snapshot key resets that binding's history;
turning it off and on preserves history.

Configure persists before installing sources. A connection failure returns error;
the saved configuration remains available for correction/retry. Observation writes and disconnect/expiry revisions
persist before becoming visible or emitting decisions. A Perspective-only restart
therefore resumes after its last emitted revision when fresh sources reconfirm. Storage failures are not
acknowledged as durable success. For expiry, snapshot and emission use one captured
evaluation time and the same transaction/revision; automatic expiry is also scheduled.

## Rules and purpose weights

Configuration has sources `{sourceID, endpoint, snapshotKey, enabled}` and rules
`{id, priority, definition, label, purposeWeights}`. definition is the existing
GoalDefinition with explicit evidenceSources and a GoalPredicate. Its Codable
fields schema, helperCells, privacy and tags must also be supplied; predicate nodes
require kind, all and any, including empty arrays on leaves. Explore publishes
these requirements; its recursive child descriptors describe the repeated shape. For example:

```json
{"kind":"all","any":[],"all":[{"kind":"contains-label","sourceID":"time","expected":"morning","all":[],"any":[]},{"kind":"any","all":[],"any":[{"kind":"contains-label","sourceID":"place","expected":"home","all":[],"any":[]},{"kind":"contains-label","sourceID":"presence","expected":"family","all":[],"any":[]}]}]}
```

Supply observations for every declared source, including an empty labels list for
known absence: GoalEvaluationEngine returns unknown if a declared source is missing.
Rule matches produce context labels. For purpose overrides, highest priority wins;
lexicographically first rule ID breaks a priority tie. An override can increase,
lower or set weight zero. Zero is omitted from the active set; definitions and manual
ground weights are preserved. Without an active override, the ground weight returns.
Existing purpose reads, derived interests and matching use the effective set.

Purpose references must resolve to known definitions before a rule is configured.
Local references and portable references to known purposes are supported. Configure
normalizes both to the local reference before rule priority is applied. Two aliases
to the same Purpose within one rule are rejected as ambiguous. Define
purposes first (an inactive weight-zero purpose can be activated by a rule). A local
catalogue definition outside the active ground set can also be materialized by its
rule; deleting definitions through unrelated APIs is outside this contract.

Flow `perspective.context.changed` carries ContextDecision: revision, validUntil,
labels, activeRules, purposeWeights, purposeRules, sourceRevisions and unknownSources.
Source observations remain internal. A revision/evidence change is observable even
when effective purpose weights do not change. Input context events are consumed and
are not forwarded as user content. Existing GeneralCell topic loop protection applies.

## Content filter

ContextFlowFilterCell is registered as `cell:///ContextFlowFilter` by AppInitializer.
Its get root `filter` contains state and configuration; mutation `filter.configure`
accepts `{perspectiveEndpoint, contentEndpoints, baseTopics, topicsByLabel}`. It saves
configuration in ContextFilter.json and rebuilds authorized runtime subscriptions.

The Cell subscribes to Perspective control before taking its snapshot, and consumes
all control events. It subscribes separately to authorized content endpoints. Topic
patterns are exact names, prefix.* or *. Every active context restriction intersects
with baseTopics. No restriction expands that base. Unknown/expired context uses the
explicit base policy. Previously delivered content is not removed retroactively.

Malformed control is ignored; conflicting snapshots at equal revision are rejected.
Reconfiguring the same policy preserves the latest control state. A changed policy
blocks delivery from the old binding while reconnection takes place.

A CellConfiguration can subscribe its root to the filter through a CellReference.
The integration test uses the actual resolver loadCell → root.flow path consumed by
CellViewModel, with a configured Perspective and content source. This establishes
Flow delivery to the Porthole input, not screen rendering, phone sensors or deployment.

## Verification boundaries

Model tests cover morning/home/family, office, physical parent meeting, digital group,
news labels, duplicate/delayed/conflicting events, expiry/restart, priority, zero weights
and filter intersection. Runtime tests cover real subscriptions, restored configuration,
non-owner rejection with bypass disabled, same-policy reconfirmation and resolver-loaded
Porthole input. Production phone sources remain a separate integration.

Fixtures: Tests/CellBaseTests/Fixtures/PerspectiveContext. Their observation validator
is in the companion PDD checks/validate_contract.py; Swift also round-trips the same
fixtures. Broad suite status is recorded separately; focused tests alone do not certify it.
