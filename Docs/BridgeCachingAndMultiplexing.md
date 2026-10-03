# Bridge caching and multiplexing

CellProtocol now has two independent, composable optimizations for remote flows.

## Flow cache

`FlowCacheCell` is placed between an `Emit` source (including a remote `BridgeBase`)
and local subscribers. It keeps one upstream subscription, replays a bounded number
of the most recent `FlowElement` values to new local subscribers, and then continues
with live values.

The cache is process-local and ephemeral. It does not claim durable storage,
cross-process consistency, or replay across a WebSocket reconnect. Its capacity is
bounded and exposed through the Cell's `Explore` contract.

## Bridge multiplexing

Protocol v2 can carry multiple logical bridge channels over one physical transport.
This is the mux envelope version, independent of the
[peer v3 authentication and record profile](../Documentation/BridgePeerChannelV3.md)
and the WS authentication profile.
`BridgeConnectionPool` shares a physical session only when the session URL, identity
UUID, signing-key fingerprint, and home-vault reference all match. Logical channels
remain independently addressed by `channelID` and preserve their own command and
response routing.

Closing a logical channel retains its ID while an admitted physical send is
outstanding. A late response/factory result cannot publish into a replacement
channel or connection; see [bridge lifetimes](../Documentation/BridgeLifecycle.md).

`RemoteCellHostRoute.connectionSharing` defaults to `.dedicated`, preserving the
legacy one-connection-per-bridge behavior. Set it to `.multiplexedV2` only for hosts
that expose the matching `/<websocketEndpoint>/session` route and install a
`BridgeMultiplexServerSession` for each accepted physical connection.

Flow frames may include `streamID` and monotonically increasing `sequence` metadata.
These are continuity watermarks used to detect gaps; they are not a promise that the
bridge can replay missed frames.

## Recommended composition

Use the two mechanisms separately or together:

1. Enable a multiplexed host route to reduce physical WebSocket use.
2. Insert a `FlowCacheCell` only where late local subscribers need bounded replay.
3. Keep durable or reconnect replay in a dedicated storage/replay Cell rather than
   assigning that protocol responsibility to the transport.
