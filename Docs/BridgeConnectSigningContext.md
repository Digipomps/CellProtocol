# Local holder authority for bridge connect signing

The connect transcript and wire profile are unchanged. Connect admits a transport;
Cell access still requires the existing resolver/Agreement/Grant decisions.

`BridgeConnectHolderCapability` is a local object token. Its public constructor
creates an inert token, not authority in another holder vault. A strict holder
adapter retains one token privately after proving its existing strict identity
binding. Only that adapter's direct, possession-validated bind return carries its
authorized startup handle. Public UUID/context lookup, serialization and
`publicIdentitySnapshot()` must not expose or attach that token.

The token's `holderIdentity(_:)` attaches it to a local identity copy. CP reads
that attachment when creating `BridgeChannelClientOperation`; a reconstructed
public descriptor or a freshly constructed token is not the retained holder
authority. The resolver preserves the attachment in its local, proven requester
copy. It does not add it to public snapshots or transmitted identities.

After validating its exact local endpoint, principal, nonces, session,
generation and canonical transcript bytes, the operation issues one
`BridgeConnectSigningContext`. There is no public context initializer, decoder,
lookup or registration API. The context retains immutable exact-byte/principal/
endpoint binding and synchronized active/consumed state, a monotonic deadline,
and the operation's clocks. Cancel, failure, task cancellation and finish
invalidate it. A signing failure does not restore admission authority.

The new `IdentityVaultProtocol` requirement is:

```swift
func signMessageForIdentity(messageData: Data, identity: Identity,
    bridgeConnectContext: BridgeConnectSigningContext) async throws -> Data
```

The default delegates to the old requirement for source compatibility. This is
not an ABI guarantee or a strict-vault security guarantee for legacy vaults.
A strict adapter overrides the requirement through the protocol existential;
it must never fall back to the old path after rejecting a context. Its old path
must reject canonical connect requests even with a correct home descriptor.

The adapter calls `context.validate(holder:messageData:identity:endpoint:)` with
its privately retained token and expected binding. This does not consume the
context: another actor hop or vault load may still suspend. The strict signer
must repeat its ordinary home/key checks after its final await, then call the
synchronous `context.consume(messageData:identity:)` immediately before its
existing synchronous private signing call, without another await. Consumption
is the linearized admission point. Cancel/expiry that wins first produces zero
private signing calls; cancel after admission cannot recall a produced signature,
but CP withholds the proof and rejects subsequent use.

These guarantees concern safe API callers without the retained startup handle
or direct full underlying vault access. Sharing that authorized handle shares
its startup authority. Arbitrary unsafe memory access or a compromised vault
requires a different isolation boundary.

No capability/context is persisted or encoded in Identity or bridge messages.
Strict vault home/fingerprint checks, key selection and storage format remain
at the existing vault boundary. Tests should count actual private signer calls,
use explicit barriers on both sides of admission, and pair all negative cases
with a successful strict holder control.
