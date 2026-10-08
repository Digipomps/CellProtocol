# Correspondence join candidate contract

This describes the candidate on PR 63. It is not evidence of deployment or client integration.

The trusted host calls `await cell.configureTrustedHostAttachmentStorage(root:)` after decoding the stable relation UUID and before serving operations. This local API has no wire operation, identity, grant, or private key. It rebinds each sender store, recovers its index, purges expired entries immediately, and arms remaining expiry timers. The existing requester-authorized storage API remains available.

## Wire

JSON uses Codable's standard Base64 strings for Data and Unix epoch seconds for times. All UUIDs are strings. No name or path is accepted in join types. Operations require the existing authenticated requester proof; forwarding does not authorize a decision.

- SET `join.request`: `CorrespondenceJoinRequest`: `version:1`, `purpose:"haven.correspondence.join.request.v1"`, `invitation`, `identityUUID`, `signingPublicKey`, `signingAlgorithm`, `signingCurve`, `agreementPublicKey` (32 raw X25519 bytes), `requestedAt`, `signature`.
- `invitation`: `version:1`, `purpose:"haven.correspondence.join.invitation.v1"`, `cellUUID`, `invitationID` (UUID), `issuedAt`, `expiresAt`, `signature`. Positive lifetime at most 604800 seconds. Invitation signature is verified against the relation owner's public signing key. Request signature is verified against the submitted public signing key. Both signatures cover `CanonicalPayloadEncoder`'s payload excluding only their respective top-level `signature`; the request includes the entire signed invitation. The request timestamp is within 300 seconds of the host clock; future invitation issuance tolerates five seconds.
- Successful request: `{requestID,status:"pending"}`. Rejected request: `{status:"rejected",code:"invitation.used"|"invitation.expired"|"invitation.invalid"|"join.proof.invalid",requestID:""}` (validation rejection may omit requestID). A valid invitation is consumed atomically on the first valid request, including a later denied request. Invalid proof does not consume it. Consumption survives snapshot decode.
- GET `join.pending`: owner proof required. Returns an array of `{requestID,invitationID,identityUUID,signingPublicKey,signingAlgorithm,signingCurve,agreementPublicKey,receivedAt}` for unexpired pending requests. This read has no payload.
- SET `join.decide`: `{requestID,approve:true,contract:<existing Contract JSON>}` or `{requestID,approve:false}`. Only the proven owner may decide. An approval requires a valid, active, cell-bound owner-signed Contract for the exact requesting identity and X25519 key, issued no earlier than receivedAt minus five seconds. Signed identity labels must be UUID fallbacks; identifying metadata or private material is rejected. Agreement and grant names must equal the fixed attachment template names, conditions must be empty, policy binding nil, and the two signatories must be exactly the owner and requester. Contract issuance cannot be more than five seconds in the future. Response `{requestID,status:"approved"|"denied"|"expired"}`. Invalid approval returns `{status:"rejected"}`; unknown, denied or expired request returns null. This does not install the agreement.
- GET `join.result.<requestID>`: requestID is the trailing keypath component (the Cell GET interface has no separate payload). Requires control of the request's exact signing key and identity UUID. Returns `{requestID,status:"pending"|"approved"|"denied"|"expired",contract?:<Contract>}`. Only approved results contain a contract. An unrelated requester or unknown ID receives JSON null. Pending requests expire at invitation expiry; already approved/denied decisions remain available.
- After approval the invitee submits the returned Contract through existing SET `agreement.accept`; all existing admission checks still apply. The link alone and join approval alone grant no membership.

GET `join.result` is the Explore parent entry, not a result without a requestID. Adapters must forward the full `join.result.<requestID>` keypath. Owner-only accesses throw the existing denied error when requester proof fails.

## Flow and code

Topic `haven.correspondence` carries `join.requested` with `requestID`, `recipientIdentityUUID` (owner), `recipientSigningFingerprint` (owner key); `join.decided` with `requestID`, `status`, `recipientIdentityUUID` (requester), `recipientSigningFingerprint` (request key). The authenticated member publisher filters each join event to its recipient UUID and signing fingerprint. Nonmembers cannot subscribe to this publisher; the pending invitee polls `join.result.<requestID>`. Other members do not see an owner's join request or somebody else's decision.

`CorrespondenceJoinCode.code(cellUUID:invitationID:signingPublicKey:agreementPublicKey:)` hashes the concatenation of UTF-8 cellUUID, UTF-8 invitationID, raw signingPublicKey, raw agreementPublicKey, in that order. Interpret the first four SHA-256 digest bytes as unsigned big-endian UInt32, take modulo 1000000, and format with six decimal digits and leading zeros. Use exact strings from the signed invitation, without normalization. Six-digit codes can collide; a different key is not mathematically guaranteed to produce a different code.

The persisted join ledger has public keys, signed proofs, IDs, timestamps, decision state and an approved public Contract. It keeps invitation consumption permanently. Runtime vault references/private keys and personal labels are not serialized by the correspondence identity codec. Host disk persistence and backup rollback protection remain integration responsibilities.

## Signing-only authenticated requesters

The bridge principal deliberately carries only UUID and signing key. Join matches
both against the request and verifies the invitee signature over the entire
request, including X25519, cell/invitation and timestamp. A requester X25519 key
is optional; when present it must equal the signed request key. `join.result`
still requires control of the same UUID and signing key.

`agreement.accept` obtains X25519 from the owner-signed Contract, checking the
subject/signatory key pair and owner/issuer keys. A supplied presenter X25519
must match; an absent one is accepted after the existing subject UUID/signing-key
binding and live key-control proof. `join.decide` binds the Contract to the
pending request's signed X25519 and signing identity; it does not derive the
invitee key from the owner's transport identity. Revocation is cell/domain-bound
and owner-signed and needs no requester agreement key. None of these paths
changes the transport principal or grants membership from join approval alone.

## Renewal on an approved request (C3)

The proven owner can submit another `join.decide` approval for the same approved
requestID, including after the previous Contract and invitation have expired.
The replacement must be active, have a different Contract UUID, strictly newer
issuance and strictly later expiry, and retain the Agreement UUID, cell, domain,
owner and subject signing/X25519 keys, signatory keys and fixed template rights.
An older or repeated decision, changed keys/rights/cell/Agreement, denial of an
already approved request, or renewal after a recorded subject revocation is
rejected. The revocation check and result replacement run in the auditor's
serialized authorization snapshot operation; replacement also checks freshness
against the latest stored Contract under the ledger lock.

The same requester UUID and signing key can retrieve the latest Contract through
`join.result.<requestID>` without active membership and then present it through
`agreement.accept`. This includes the bridge's signing-only principal. Renewal
replaces the result in place; it neither consumes another invitation nor installs
membership itself. Existing admission replaces the authorization Contract rather
than appending members or Contracts. Snapshots retain the latest result and the
existing revocation cutoff. These are CellProtocol candidate semantics, not
evidence of a deployed client, automatic polling, or a live WebSocket ceremony.
