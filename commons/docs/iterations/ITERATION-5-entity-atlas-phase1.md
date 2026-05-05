# Iteration 5: Entity Atlas Phase 1

## Hva som ble gjort
- la til `CellResolverRegistrySnapshot` for atlas-input
- la til `EntityAtlasProjection` som ren service/projeksjon
- la til `EntityAtlasDescribing` for eksplisitt cell-metadata uten stort manifest-hierarki
- la typed Vault-dokumenter for prompt/context/provider/assistant/credential metadata
- la til sync-merge for typed Vault-dokumenter
- la til `CredentialVaultService` og `AppleKeychainSecureCredentialStore`
- la til deterministisk prompt-resolusjon med explain-output
- la til redigert JSON/Markdown-eksport for atlaset
- la til eksplisitte atlas-deskriptorer pa utvalgte production-celler
- la til tester for atlas, vault sync, prompt-resolusjon og secret-isolation

## Viktige filer
- `Sources/CellBase/Cells/CellResolver/CellResolverRegistrySnapshot.swift`
- `Sources/CellBase/EntityAtlas/EntityAtlasModels.swift`
- `Sources/CellBase/EntityAtlas/EntityAtlasProjection.swift`
- `Sources/CellBase/EntityAtlas/AtlasVaultDocuments.swift`
- `Sources/CellBase/EntityAtlas/SecureCredentialStore.swift`
- `Sources/CellBase/EntityAtlas/PromptResolution.swift`
- `Sources/CellApple/EntityAtlas/AppleKeychainSecureCredentialStore.swift`
- `Tests/CellBaseTests/EntityAtlasProjectionTests.swift`

## Beslutninger
- atlaset er ikke pakket inn i en egen cell i denne fasen
- typed Vault-dokumenter ble valgt foran nye celler for prompts/context
- credential metadata kan sync'es; raw secrets kan ikke det
- `CellConfiguration` og registreringer brukes som grunnlag, men kompletteres av `EntityAtlasDescribing`
