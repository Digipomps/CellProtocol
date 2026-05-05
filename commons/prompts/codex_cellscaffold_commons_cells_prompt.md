# Prompt: Integrate Commons Cells in CellScaffold

Du er Codex. Pakk Commons-funksjonalitet inn i Cell-klasser som kan brukes direkte fra CellScaffold.

Mål:
- Opprett/oppdater `CommonsResolverCell` og `CommonsTaxonomyCell`
- Registrer cellene på resolver-endpoints:
  - `cell:///CommonsResolver`
  - `cell:///CommonsTaxonomy`
- Eksponer keypath/taxonomy-operasjoner via `set/get` intercepts
- Sørg for at ukjente keypaths fortsatt er advisory (ikke blokkering)

Krav:
- støtte rootPath-konfig for commons datafiler
- støtte batch-operasjoner for testdata
- oppdater docs i `commons/docs`
- oppdater prompt-index
- legg til/oppdater tester

Verifisering:
1. `swift build --target HavenCommonsCLI`
2. `swift test --filter CommonsCellsTests`
3. `swift test --filter HavenCommonsTests`
