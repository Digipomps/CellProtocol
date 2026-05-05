# Iteration Prompt: Purpose Tree Governance

Du er Codex. Stram inn taxonomy-governance for purpose-tree i HAVEN Commons.

Mål:
- Mandatory inherited purposes skal håndheves.
- Purpose-termer som går på tvers av mandatory formål skal avvises.
- Mandatory formål må ha minst ett linked goal.

Krav:
- Oppdater `TaxonomyPackage.Guidance` med:
  - `mandatory_inherited_purposes`
  - `forbidden_relations_to_mandatory`
- Implementer validator i taxonomy resolver.
- Eksponer validator i:
  - CLI (`validate purposes`)
  - `CommonsTaxonomyCell` (`taxonomy.validate.purposeTree`)
- Oppdater seed-data og tester.

Verifisering:
1. `swift build --target HavenCommonsCLI`
2. `swift test --filter HavenCommonsTests`
3. `swift test --filter CommonsCellsTests`
4. `./.build/debug/haven-commons validate purposes --namespace haven.core`
