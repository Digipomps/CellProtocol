# Resolver owner proof over a bridge

Bug fix against `b5b7282b495e96a7899a189087592581426f4bfb` (Palazzo S6b).

`CellResolver.requesterProvesSigningControl` previously requested a signature
of arbitrary random bytes. `BridgeIdentityVault` correctly rejects those bytes:
only the bounded `IdentitySigningChallenge` identity-origin envelope may cross
this signing boundary. As a result, creating an identity-unique Cell for a
remote guest failed with `ownerAuthorityUnavailable`. A bridge GET returned
that failure; a bridge SET could reach the existing no-response error path and
time out. This fix removes that cause, without changing general SET error handling.

Resolver now constructs and validates the existing v1 envelope, using:

- the registered identity domain and endpoint name before personal Cell creation;
- the Cell's domain and UUID for non-GeneralCell stored-owner validation;
- `CellResolver` / `identity-mappings:<requester UUID>` for mapping restoration;
- the existing `checkIdentityOrigin` / `GeneralCell` operation and audience.

The fresh 64-byte nonce comes from the runtime CSPRNG. The signature is checked
locally against the requester's public signing key, not by accepting a vault's
self-reported verification. Refusal, malformed challenges and invalid signatures
remain failures. No arbitrary signing, server-vault substitution, new grant,
implicit signing lease, or global identity is introduced. A native client's
existing explicit domain/resource scope policy still applies; the resolver does
not authorize new scopes on its behalf. No JSON shape or stored data changes.

`BridgeIdentityBoundaryTests` uses the real resolver and serialized bridge
commands to prove fresh guest surface creation, a scoped challenge with a fresh
nonce, house rejection on the guest UUID, copied guest descriptor rejection,
and no registration before proof. Existing paired-client signing-lease tests,
resolver recovery tests, and public-key signature tests remain in the gate.
Palazzo's separate suite exercises the actual Vapor route/upgrade/framing,
reaction write, HTTP parity, persistence reload and private graph rejection.
