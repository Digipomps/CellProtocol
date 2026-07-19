# Device ingress security contract

Status: CellProtocol contract, version 1. This document does not claim that an
HTTP or APNS integration is deployed.

## Purpose

`purpose://access.audit.privacy/device-notification-callback` protects the
minimum device-registration and notification-callback authority needed by a
Scaffold while keeping transport, tokens, and device identifiers outside the
authority model.

The contract applies to three Cell operations:

| Operation | Cell resource | Action | Required capability |
| --- | --- | --- | --- |
| `register` | `cell:///DeviceRegistration` | `registerOrUpdateDevice` | `device.registration.write` |
| `resolve` | `cell:///DeviceCallbackBridge` | `resolveTicket` | `device.callback.resolve` |
| `submit` | `cell:///DeviceCallbackBridge` | `submitTicketResult` | `device.callback.submit` |

All operations currently require Cell access `-w--` and the identity domain
`domain:device:notification-callback`.

## Authority path

The transport adapter is never an authority. A successful request follows this
fail-closed chain:

1. The Scaffold issues a subject-bound challenge signed by a pinned public
   Scaffold identity.
2. The requester signs a request that repeats the challenge fields and binds
   the exact canonical challenge bytes and protected body bytes by SHA-256.
3. The verifier checks schema, exact canonical bytes, size, signature, nonce,
   audience, purpose, domain, subject, operation, freshness, body digest, and
   challenge digest.
4. `CellResolverProtocol` resolves the exact Cell resource for the public
   requester identity. Resolution alone grants no authority.
5. CellBase independently decodes and canonical-byte-compares the complete
   signed `Contract`, verifies its issuer as the concrete target Cell owner,
   verifies its exact subject and identity domain, and requires the hashed exact
   ingress scope as a signed Agreement Grant.
6. A durable ledger atomically consumes the challenge/nonce and persists the
   admission record before any protected Cell mutation.
7. That same resolved Cell object performs a serial authority/revocation-
   generation compare-and-swap and the durable mutation as one Cell operation.
   Success is returned only after its bound mutation receipt is verified.

Only `DeviceIngressAdmissionService` can produce a completed result. A Scaffold
composition root creates the service through the `HAVENRuntime` SPI with one
pinned issuer, audience, resolver, and durable ledger. Transport adapters cannot
choose this trust context or invoke intermediate authorization stages.

IDs in `DeviceIngressAuthorityReference`, HTTP routing, proxy identity, bearer
tokens, device metadata, and possession of a challenge never grant authority.

## Canonical wire rules

`cellprotocol.device-ingress.envelope.v1` is the only envelope type. `kind`
distinguishes a Scaffold-signed `challenge` from a requester-signed `request`.

- JSON uses UTF-8, sorted ASCII keys and unescaped slashes. Device-ingress
  identity descriptors omit display names; authority strings are printable
  ASCII; generations and millisecond timestamps stay within JSON's exact
  53-bit integer range. This deliberately bounded profile avoids Unicode and
  number ambiguities between Darwin, Linux and other runtimes.
- A decoder re-encodes and byte-compares the complete envelope. Alternate
  whitespace, ordering, or normalization is rejected.
- `proof` is omitted from the signing payload and included on the wire.
- Maximum envelope size is 65,536 bytes.
- Maximum protected body size is 65,536 bytes.
- Nonces are 32 through 64 bytes. The runtime challenge factory generates a
  32-byte nonce with `SystemRandomNumberGenerator`; transport callers cannot
  provide it.
- Challenges live at most five minutes; requests live at most two minutes and
  cannot outlive their challenge or authority.
- Clock skew is bounded to 30 seconds.
- Authority references live at most 30 days and are always re-resolved.

Golden challenge and request bytes are stored base64-encoded under
`Tests/CellBaseTests/Fixtures/`; decoding yields the exact bytes without a file
line ending. Independent SHA-256 hashes and the issuer UUID/public key are
pinned in `DeviceIngressWireFixtureTests` before signatures and body/challenge
digests are verified.

## Replay, durability, and revocation

`DeviceIngressDurableAdmissionLedger` is a contract for production storage, not
an in-memory convenience. An implementation must atomically and durably:

- reject a previously consumed challenge/nonce;
- persist request, challenge, body, nonce, Agreement, subject, operation, and
  generation hashes/identifiers;
- enforce monotonic authority and revocation generations; and
- return a receipt with `atomic_durable_before_cell_mutation` semantics.

A process crash after a durable commit may require the client to obtain a new
challenge; replaying the old envelope remains forbidden. A process crash before
durable commit must not produce a successful receipt or Cell mutation.

The authority Cell's mutation operation receives an internally constructed
command bound to the concrete Cell UUID, owner signing-key fingerprint, signed
Agreement hash, admission receipt, request hash, and expected authority and
revocation generations. Its receipt promises
`same_cell_atomic_authority_recheck_and_durable_mutation`. A revocation race
consumes the challenge but performs no mutation.

## Integration requirements

CellScaffold and Binding integrations must separately provide and verify:

- persistent challenge-issuer identity and pinned public descriptor rotation;
- a production durable admission-ledger implementation with restart tests;
- target Cells that implement `DeviceIngressAuthorityCell` from persistent
  signed Agreements and revocation state, including atomic durable mutation;
- requester credential provisioning without embedding a shared server secret
  in a client application;
- adapter rate limits, TLS, bounded reads, and sanitized audit logs;
- negative end-to-end tests for wrong host/audience, identity domain, purpose,
  subject, signature, body, challenge, expiry, replay, and revocation; and
- restart tests proving registrations and authority survive without reseeding.

APNS credentials, HTTP route names, push tokens, and device-registration bodies
are intentionally outside CellProtocol. They belong to host adapters and Cells,
and must not be added to this protocol as alternate authority paths.

## Residual limits

This version defines the shared wire, verification, resolver, Agreement,
durability, replay, and revocation boundaries. It does not implement an HTTP
endpoint, APNS delivery, a persistent ledger, a concrete Agreement store, or a
client UI. Until those integrations satisfy the requirements above, the APNS
workflow must not be described as production-ready.
