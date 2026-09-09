# Bridge identity-origin proofs

Incoming identity descriptors do not confer authority to use a local vault.
`BridgeBase.consumeCommand` copies remote requester descriptors and routes their
origin proofs through `BridgeIdentityVault` back to the peer. This applies even
when a transport previously attached a local vault to a decoded descriptor.
The local owner object is not mutated by this boundary.
The requester keeps only the intrinsic `displayName: r---` public-metadata grant
that Identity's constructor and wire decoder install. Arbitrary runtime grants
from an incoming object are discarded. This preserves the default Agreement's
public-display-name condition without granting access to a local signer.

A received `sign` command is accepted only when all of these checks pass:

- The bridge session is ready and local containment policy permits signing.
- The identity matches the public key and UUID of the locally configured owner.
- A locally initiated operation is active for the expected domain and Cell UUID.
- The challenge is an identity-origin proof with `checkIdentityOrigin` as action
  and `GeneralCell` as audience, and passes format, validity and replay checks.
- The configured local vault still holds the matching signing identity.

Finding an identity in the default vault, receiving a public descriptor, or
receiving a challenge cannot create signing authority. Non-stream operations
lose proof authority on their response or after five seconds. Active feeds
retain it until stopped. Closing or replacing the transport invalidates all
proof authority for the old session, including a signature awaiting delivery.

## Host configuration and compatibility

Outbound bridges must be configured with the actual local requester as `owner`.
CellResolver does this for both direct WebSocket and routed `cell://` bridges.
Use a separate bridge per principal; the remote connection pool already keys
its entries by proven principal.

The default permits proofs for the direct Cell described by that bridge, after
discovery and only while a local operation is pending. Hosts can pin an explicit
`identityProofScopes` list in `BridgeBase.Config`. This is necessary for a Cell
that requires identity proof before returning its description, or for calls
delegated to known child Cells in additional scopes. An empty explicit list
disables local proof callbacks. Remote discovery cannot replace a pinned list.

This deliberately rejects the old behavior of answering arbitrary unsolicited
challenges. Hosts relying on undiscovered or cross-Cell proof callbacks must
declare their expected scopes; do not restore default-vault fallback. Before
deployment, exercise the host's protected discovery and nested-route paths.

The command and signing-challenge wire formats are unchanged. These checks do
not authenticate a server's description or replace the host's trusted route/TLS
configuration. A discovered scope is associated with the contacted route; use
explicit scopes when the host needs an independently established resource pin.

## Verification

`BridgeIdentityBoundaryTests` reproduces a copied-owner protected read and
verifies legitimate proof exchange, including two serialized bridge endpoints
with separate client and server vaults. `BridgeIdentityProofAuthorizationTests`
checks wrong principal/domain/resource/action/audience, expiry, completion,
transport reset, and hostile discovery against a pinned scope. `BridgeTests`
retains successful signing, replay, readiness and containment tests while
requiring a locally initiated operation for successful callbacks.

See `SecurityAuditImplementation-2026-09-10.md` for source and execution evidence.
