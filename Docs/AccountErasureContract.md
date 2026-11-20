# Account erasure contract (CellBase)

Status: contract only (PDD_kontosletting_2026-11-20, AP1). No holder in CellBase
implements `PersonalDataHolder` yet, and no vault implements destroy or lock.

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

`IdentityVaultProtocol.destroyIdentity(_:)` and `lockIdentity(_:until:)`. The default
implementation throws `IdentityVaultLifecycleError.notSupported`, so no vault pretends to
delete or lock. Real implementations are AP4.
