# Iteration 6: Atlas Inspection Surface

## Endringer
- la til `EntityAtlasInspectorCell` som tynn query/export-wrapper rundt `EntityAtlasService`
- registrerte `cell:///EntityAtlas` i `AppInitializer`
- la til tester for snapshot, coverage og redigert eksport via cell-kontrakt
- forberedte CellScaffold for egen inspeksjonsflate med samme projeksjon

## Hvorfor
Phase 1-atlaset trengte en faktisk bruksoverflate:
- for Porthole/CellScaffold via cell-kontrakt
- for mennesker via redigert JSON/Markdown-inspeksjon

Løsningen holder atlaset som projeksjon og lar cellen kun bygge on-demand snapshot fra resolver + optional Vault.

## Invarianter
- ingen ny lagret sannhet i cellen
- ingen raw secrets i eksport
- query-resultater kommer fra samme projeksjon som tjenestelaget

## Viktige filer
- `Sources/CellBase/Cells/Commons/EntityAtlasInspectorCell.swift`
- `Sources/CellBase/EntityAtlas/EntityAtlasDescriptorConformance.swift`
- `Sources/CellApple/Cells/Porthole/Utility Views/Skeleton/AppInitializer.swift`
- `Tests/CellBaseTests/EntityAtlasInspectorCellTests.swift`
- `Tests/CellBaseTests/RealCellContractTests.swift`
