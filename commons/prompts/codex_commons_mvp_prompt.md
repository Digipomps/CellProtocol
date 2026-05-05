# Prompt: Build/Update HAVEN Commons MVP

Du er Codex. Oppdater HAVEN Commons i dette repoet.

Mål:
- library-first implementasjon
- Taxonomy Registry/Resolver
- KeyPath/Reference Registry/Resolver
- local service API
- CellScaffold-klare wrapper-celler (`cell:///CommonsResolver`, `cell:///CommonsTaxonomy`)
- CLI (`haven-commons`) for lint/validate/resolve
- tester for routing, alias/deprecation, permissions, inheritance

Krav:
- `#/purposes` skal være deprecated alias til `#/perspective`
- `#/chronicle/*` skal routes til `ChronicleCell` med separat `storage_domain`
- keypath resolution skal bruke EntityAnchor-bindinger for kryss-celle routing
- keypaths er advisory: uregistrerte/custom paths skal ikke blokkeres, men resolves som åpne referanser
- taxonomy må inkludere incentive guidance:
  - root purpose: alle mennesker er like mye verdt (UDHR artikkel 1)
  - contribution purpose: netto positivt bidrag i systemet man interagerer med
  - goals skal oppmuntres som insentiv, ikke håndheves som hard regel
- bevar kompatibilitet med eksisterende `Package.swift`

Arbeidsflyt:
1. Oppdater plan + filstruktur
2. Implementer datatyper og parsere
3. Implementer resolvere
4. Implementer CLI
5. Implementer/oppdater tester
6. Oppdater docs under `commons/docs`
7. Kjør build + tests
8. Vis `git status` og foreslå commit-melding

Output:
- Oppsummer endrede filer
- Oppgi verifiseringskommandoer og resultat
