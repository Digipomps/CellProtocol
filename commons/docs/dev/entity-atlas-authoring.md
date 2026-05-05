# Entity Atlas Authoring

## Nar holder CellConfiguration alene
`CellConfiguration` og resolver-registreringer er nok til:
- a finne at en celle finnes
- a vite om den er scaffold-available
- a hente enkel discovery-purpose fra config
- a lese strukturelle referanser

## Nar det ikke holder
De er ikke nok til a vite sikkert:
- hvilke capabilities cellen faktisk eksponerer uten `ExploreContract`
- hvilke andre celler den kjenner til eller indekserer
- hvilke credential-klasser den krever
- hvilke purposes den eksplisitt dekker utover config-hints

## Anbefalt mønster
For cells som skal bli godt synlige i atlaset, implementer `EntityAtlasDescribing` og bruk `ExploreContract` for capabilities.

Minimal descriptor bor angi:
- title
- summary
- purpose refs
- dependency refs
- required credential classes
- knowledge roles

## Prinsipp
Ingen magisk inferens for knowledge-roller. Hvis en celle vet om andre celler, maa den si det eksplisitt.

## Production descriptors i Phase 1
Folgene production-celler deklarerer na atlas-descriptor eksplisitt:
- `VaultCell`
- `GraphIndexCell`
- `CommonsResolverCell`
- `CommonsTaxonomyCell`
- `PerspectiveCell`
- `RelationalLearningCell`
- `AppleIntelligenceCell`
- `EntityScannerCell`
