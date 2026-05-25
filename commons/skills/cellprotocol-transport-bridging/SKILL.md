---
name: cellprotocol-transport-bridging
description: Use when working on CellProtocol bridges, transport adapters, WebSocket/IPC/P2P/QUIC/WebRTC routing, cell:// endpoints, remote references, bridge payload ordering, transport security policy, or cross-runtime connectivity. Enforces that transport does not own protocol semantics.
---

# CellProtocol Transport Bridging

Use this skill when Cells communicate across process, device, network, or
runtime boundaries.

## Core Rules

- Transport is semantically neutral. It carries ordered payloads; it does not
  decide protocol authority.
- Resolver, identity, capability, and contract checks remain authoritative.
- `cell://` routing must not become a global identity system.
- Payload ordering and integrity matter for replay.
- Bridge failures should be observable and isolated.
- Security policy for insecure transports must be explicit.
- Do not let convenience bridge code mutate Cell state outside Meddle/resolver
  paths.

## Read First

- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/08_Bridging_Transport.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/06_CellResolver.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/05_Flows_Lifecycle.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/21_Contact_Endpoint_Cell.md`

Common source anchors:

- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Sources/CellBase/Cells/Bridging`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Sources/CellVapor`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Sources/CellBase/Cells/CellResolver`

## Required Workflow

1. Identify the bridge boundary:
   - local process
   - IPC
   - WebSocket
   - HTTP/Vapor
   - P2P/private route
   - other
2. Identify payload type and ordering/integrity requirements.
3. Trace where identity and capability are checked.
4. Ensure transport errors are surfaced as transport errors, not protocol
   decisions.
5. Add tests or probes for:
   - accepted payload path
   - rejected unauthorized path
   - malformed payload
   - ordering/replay behavior where relevant
   - disconnect/retry behavior where relevant
6. Document endpoint and security assumptions.

## Security Boundaries

- `ws://` may be acceptable only in explicit local/dev contexts.
- `wss://` or equivalent secure channels are required for real remote use unless
  another approved secure envelope exists.
- Private route/contact endpoint TTL and wakeup behavior must be explicit.
- Transport possession does not equal capability possession.

## Must Not

- Do not put agreement/condition decisions in bridge-only code.
- Do not use remote endpoint strings as trust anchors.
- Do not reorder events without a documented deterministic rule.
- Do not swallow bridge failures that affect replay or audit.
- Do not expose private payloads through logs, debug UI, or diagnostics.

## Completion Checklist

- Transport boundary and trust model are clear.
- Resolver/policy path remains authoritative.
- Tests/probes cover failure and rejection paths.
- Docs updated if bridge contract changed.
