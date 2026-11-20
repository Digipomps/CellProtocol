# Account erasure contract (CellBase)

Status: contract (AP1) plus CellApple vault destroy/lock (AP4). No holder in CellBase
implements `PersonalDataHolder` yet.

Source: `Sources/CellBase/PersonalData/PersonalDataHolder.swift`,
`Sources/CellBase/Identity/IdentityVaultProtocol.swift`.
Tests: `Tests/CellBaseTests/AccountErasureContractTests.swift`.

## PersonalDataHolder

Every cell or store that keeps data per owner implements:

- `inventory(owner:) -> [PersonalDataInventoryRow]`: what it keeps (kind, count), never the data itself.
- `export(owner:) -> PersonalDataExportPart`: all records for the export file.
- `expireAfter(owner:ttl:) -> PersonalDataExpiry`: a deadline that removes everything even if `erase` never arrives.
- `erase(_ request: ErasureRequest) -> ErasureReceipt`: must call `request.verify(owner:)` first.

## ErasureRequest

Fields: `domain` (`haven.account.erasure.v1`), `purpose` (`purpose://account.erasure`),
`requestID`, `ownerEntity`, `identities` (owner first, then linked identities),
`keyChoice` (`destroy` | `lock30`), `issuedAt`, `signer` (public key descriptor), `signature`.

The owner signs the canonical JSON (`CanonicalPayloadEncoder`, without `signature`).
`verify(owner:)` refuses a missing signature, a wrong signature, a signer that is not
the owner the holder keeps data for, and any other purpose or domain.

## ErasureReceipt

Fields: `domain` (`haven.account.erasure.receipt.v1`), `holder`, `requestID`, `ownerEntity`,
`removedCount`, `remainsWithOthers`, `at`, `holderSigner`, `signature`. Signed by the holder.
`verify(request:holderIdentity:)` checks it answers the request and the holder signed it.

## Vault

`IdentityVaultProtocol.destroyIdentity(_:)`, `lockIdentity(_:until:)` and `unlockIdentity(_:)`.
The default implementation throws `IdentityVaultLifecycleError.notSupported`, so no vault
pretends to delete or lock.

CellApple `IdentityVault` implements all three. The caller must present the stored signing key.
- destroy: `SecItemDelete` of the signing key (`kSecClassKey` by application tag) and the
  key-agreement key (generic password, this vault's service and the tag as account), then
  removes the entry from `Identities.crypt`. The vault-wide main secret stays, since other
  identities need it.
- lock: stores `signingLockedUntil` in `Identities.crypt`, so it survives restart. Signing
  throws `IdentityVaultLifecycleError.locked(until:)` until the date. unlock clears it.
  The lock covers signing only. `privateKeyData(for:role:)` is not blocked.
