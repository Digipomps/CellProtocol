# Credential Vault Phase 1

## Formaal
Credential-handtering er delt i to:
- syncbar metadata i `AtlasCredentialHandleRecord`
- raw secret-materiale i `SecureCredentialStore`

## Sikkerhetsgrenser
Raw secret skal aldri lagres i:
- `FlowElement`
- `ValueType`
- `VaultNoteRecord.content`
- prompt/context docs
- debug-logger

## Implementasjon
`CellBase`:
- `SecureCredentialStore`
- `InMemorySecureCredentialStore`
- `CredentialVaultService`

`CellApple`:
- `AppleKeychainSecureCredentialStore`

## Operasjoner
- create handle + secret
- rotate secret
- revoke handle
- hent secret via handle-id

## Sync
Kun metadata sync'es. Secret-materiale maa reprovisjoneres eller replikeres via en eksplisitt sikker kanal i senere faser.

## Eksport
`EntityAtlasExporter` og `EntityAtlasService` eksporterer credential handles i redigert form:
- handle id
- provider
- credential class
- access mode
- label
- metadata keys

Selve secret-verdien eksporteres aldri.

## Trusselmodell Phase 1
Beskyttet:
- utilsiktet lekkasje til vanlige dokumentlagre
- utilsiktet lekkasje til atlas-projeksjon
- utilsiktet lekkasje til prompt/context-lag

Ikke dekket enda:
- multi-device secure replication
- hardware-backed attestering
- full audit-logg for secret-bruk
