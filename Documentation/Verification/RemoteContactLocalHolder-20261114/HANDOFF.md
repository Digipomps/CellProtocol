# Remote contact local-holder source slice

Status: SOURCE_ONLY_PARTIAL_IMPLEMENTATION. NOT_COMPILED, NOT_RUN, NOT_REMOTE_READY.
Base CP00a8b31b744fbf94a3156f12daf8572ba1f39b02. Separate from frozen CP R15/Binding native pair, R25 and the Motion3D CP-O1 Swift35 request. No native/queue/Deploy admission is inferred.

## Implemented source in this slice

- `ContactLocalSigningVault: IdentityVaultProtocol, AnyObject` with `signContactMessage(messageData:originalIdentity:context:)` is an explicit opt-in protocol with no ordinary-signing default. A source vault repeats its exact stored key/home checks after its last await and performs only its synchronous private signing call inside `ContactSigningContext.withSignature(from:messageData:originalIdentity:_:)`.
- The CP-created context binds the exact concrete source object and retains exact bytes, original public descriptor/home and the original `ContactOperationLease`. It checks cancellation, expiry and retirement at the actual synchronous call and consumes once, including a failed signing attempt. Operation retirement and admitted signing serialize through the lease lock; no lock crosses a vault/network await. A private call admitted before retirement may finish; no retroactive zero-effect claim.
- `ContactOperationHolder.prepare(lease:requester:)` captures one explicitly supporting local source, denies proxy/legacy/default signers, proves control using a fresh CP-generated local-binding challenge, and verifies both actual context consumption and the signature. The caller's mutable Identity is not retained across vault awaits. The holder exposes no generic signer, proxy IdentityVault adapter or network-send API. CS must register the original lease with its auth/link/binding retirement owner before calling prepare, under its existing admission serialization.
- Canonical locator/Contract digest, immutable operation and untrusted host-receipt drafts from the preserved branch remain source-only. Reference endpoints now require explicit port and canonical Cell UUID. The ordinary owner-signing `issue` helper is internal fixture scaffolding, not a public owner-export API.
- `ContactInboxCell` and the retained operation accept finite numeric expiry represented as either ValueType.float or ValueType.integer. ValueType decodes integral JSON numbers as integer, so a float-only guard rejected valid whole-second expiry after encode/decode. String/bool/null/nonfinite and existing time/size/authorization limits remain denied. Existing contact/vault tests are unchanged.

## Concrete CS integration seam

The source vault implements `ContactLocalSigningVault`; do not weaken BrowserClientIdentityVault's ordinary full-home signer. After its current loading awaits and strict key/home checks, wrap the existing synchronous `signMessageForVaultIdentity` call in the supplied context. Do not consume outside the closure, await another signer, forward a BridgeIdentityVault, substitute recipient/default vault, or mint a lease from a UUID-only request. A conforming vault is trusted implementation code; a returned signature without context consumption is refused, but CP cannot undo a private-key operation performed by a deliberately nonconforming source.

CS creates the lease only from its authenticated web/native admission, verified binding and immutable durable request. Metadata strings and revisions do not establish trust by themselves. Native person-link/session, selected binding, intent, route/trust and expiry retirement remain CS-owned dependencies. This source slice does not modify CS or Binding.

## Explicit open integration work

1. Actual resolver cell-route propagation/cache/single-flight separation for exact holder, scopes, logical host/port and route generation. Legacy ws/wss scope support does not prove scoped cell:// support.
2. CP-owned exact live resolver/connect/origin contexts, fresh challenges, single-use connect and final channel/cid/generation fencing. The local holder currently proves local preparation only; it is intentionally not wired into Bridge signing.
3. Physical send admission in the actual adapter after its last await. Current draft lease `admitEnqueue` only fences its synchronous callback; calling an asynchronous send afterward cannot satisfy this requirement. No dispatch path in this slice invokes it.
4. Actual Bridge-owned per-RPC validated result including authenticated hosting peer/route/channel provenance. The receipt draft and its echoed fields alone are not proof; no RPC completion is wired here.
5. Narrow owner export signing/commit, encrypted binding/outgoing/receiving transactions and CS/Binding projection. No persistence migration, encryption-at-rest or restart claim.
6. OriginConversationCell / `domain:chat-conversation:v1`: exact acceptance-only Contract, offer codec, same-origin aggregate, separate key-bound member read/send/feed and subscriber retirement. Do not reintroduce a speculative ChatInvitationAcceptanceCell. Contact queued does not grant membership. No generic grant or Flow behavior changed by this slice.

These are separate-source dependencies, not new R15/B1/TestFlight blockers. Preserve the original agreed suites and cleanup gate. The CS proposed contracts are pinned in `CellProtocol/Docs/Verification/ChatRepair-20261112/REMOTE-CONTACT-CS-CONTRACT-20261114`; this slice does not approve all their proposed semantics or claim remote implementation complete.

## Verification and limits

17 new XCTest source methods cover local holder control, retirement/cancellation inside source signing awaits, original snapshot preservation, nil-home/wrong-key/legacy denial, context consumption and no reuse after failure, wrong-byte/home/key/live-scope denial, canonical reference tampering, and actual contact Cell JSON expiry round trips. Positive async barriers use bounded XCTest expectations; no sleeps establish negative effects. All 17 remain NOT_COMPILED/NOT_RUN. The source-level checks and hashes in this packet are not Swift discovery or behavior tests.

Do not change the frozen R15 pair to integrate this work. Swift35/CP-O1 belongs to separate CP25eef29d and stays pending after B2/D1. Original user data, recordings, analyses, entity links, R25 and the hard cleanup gate are untouched.

Adopted exact type/method names from CS BROWSER-CONTACT-SIGNER-INTERFACE-20261114 (INTERFACE SHA774de2a4df438425fd582c9dcc01b1bfa0055b992b5f9c2c96b83606bdfdbf03). The context now also validates the concrete source object; no alternate naming remains. Its only issued stage in this slice is the locally generated bindLocalHolder challenge. Resolver/connect/origin stages are still absent, not implied by the context API.
