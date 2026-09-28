# Owner-attach entity presence — runtime candidate, 2026-09-28

Purpose: when a human opens a cell they own on another runtime, let them
register that entity presence without another QR ceremony, using a current
owner proof and an explicit decision or a matching saved policy.

This additive candidate registers presence for an already controlled identity.
It does not enroll a new key, merge two unlinked identities, connect scaffold
identities, transfer data, create indexes, or grant notification permissions.
New identities continue to require the signed IdentityLink enrollment protocol.
No production release or cross-platform rollout is claimed.

## Protocol and authorization

- `GeneralCell.attach` invokes an optional task-local handler only after a
  connected response. Hosts opt in around an explicit user action. Generic
  Absorb/background/preview behavior has no automatic identity side effect.
- GET `entityExtension.ownerAttach.offer` requires a fresh proof against the
  real cell owner or a currently verified same-entity linked owner. Shared
  access, copied UUIDs/public descriptors and the debug bypass do not qualify.
- The offer is signed by the receiving runtime's receipt signer and binds
  version 1, purpose `owner_attach_presence`, receiver key, human requester
  key, domain, cell UUID, cell-owner descriptor, random 32-byte nonce and a
  five-minute expiry. The receiver key is not enrolled into the human entity.
- `OwnerAttachEntityExtensionClient` requires the selected human to be the
  requester. A different key yields `enrollmentRequired`. It validates the
  offer, obtains consent/policy and signs a new purpose-bound consent locally.
  A bridge's origin-proof signing lease cannot sign this consent.
- SET `entityExtension.ownerAttach.accept` checks the consent, exact context,
  current owner proof and persistence. A matching durable receipt makes retry
  idempotent; retries still prove current ownership. A receipt is historical
  evidence, never a capability to bypass today's authorization/revocation.
- A dropped completion response is `completionUnconfirmed`, not proof of
  rollback. Reopening the cell retries against the durable receipt.
- Existing verified linked owners now use the same authorization evidence at
  connect admission as at read/write. This fixes previously inconsistent
  rejection at attach; it does not authorize ordinary sharing as ownership.

## Policy and persistence

The client offers once, automatic here, or do not ask here. Persistent choices
expire after one year and bind both complete public keys, UUIDs, algorithms,
curves, domain, purpose and version. Display names and hostnames cannot match a
policy. Automatic use preserves the originally approved expiry; it does not
renew either persistent choice. A navigation change, cancelled task or detached cell cancels the local
operation before signing/sending. Cancellation after a network send cannot
promise remote rollback.

Hosts supply an atomic/read-after-write `OwnerAttachExtensionStore`.
`OwnerAttachEncryptedStore` uses AES-GCM, a host vault-scoped 32-byte secret,
authenticated storage IDs, atomic files and private permissions. Corruption or
unavailable secrets fail closed. There is no plaintext fallback. The optional
`receiverEndpoint` is an encrypted routing hint; future use must authenticate
the receiver key again. It grants no read/write/index authority.

`OwnerAttachExtensionRuntime.configure` uses a dedicated vault-held receipt
signer and secret. Server composition may instead supply its already provisioned
signer and a separate scoped store. Configuration never comes from cell JSON.
Only one host is installed per process; multi-tenant hosts need explicit scoped
composition before adopting this process-wide convenience hook.

## Wire profile

`OwnerAttachWire` encodes sorted JSON keys, UTF-8, Base64 data and ISO8601 UTC
whole-second dates. Its decoder limits input to 256 KiB. Signing removes only
the signature at the level being signed; nested signed evidence remains.
This is the candidate's Swift JSON profile, not a claim of RFC 8785 JCS.
A cross-language port must reproduce the bytes or define a versioned canonical
profile before interoperability is claimed. The missing-signature golden at
`fixtures/owner-attach/v1/offer-missing-signature.json` must round trip byte for
byte and must be rejected for authorization. Swift bridge round trips also
exercise signed offers, consents and persisted receipts.

## Validation and adoption

101 focused CellBase tests passed with the final ISO8601 wire profile, including
bridge origin leases, owner proof rejection, linked-owner revocation, policy
expiry/restart, duplicate completion and encrypted storage corruption. This is
Swift coverage, not evidence of interoperability with Sprout or a deployed host.

To adopt: configure the receiver with durable private storage, install a client
with the selected human context, and wrap only authorized user attach actions
in `OwnerAttachExtensionContext.$handler.withValue`. Detached tasks do not
inherit task locals. Keep the normal cell connection independent of review UI.
See the Binding candidate for UI cancellation and policy removal.

Task-local semantics: https://docs.swift.org/latest/documentation/swift/tasklocal/
