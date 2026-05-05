# HAVEN Commons Architecture

## Oversikt
HAVEN Commons er implementert som library-first moduler med et tynt local service API.
Fokus i MVP er:
- Taxonomy Registry + Resolver
- KeyPath/Reference Registry + Resolver
- Kryss-celle routing via EntityAnchor-bindinger
- CLI for lint/validate/resolve

## Moduler
- `HavenCoreSchemas`
  - Canoniske datastrukturer: `TaxonomyPackage`, `Term`, `KeyPathSpec`, `PathRoute`
  - Felles typer: permissions, requester context, resolved result
- `HavenPerspectiveSchemas`
  - `PerspectiveDocument` (`pre`, `during`, `post`)
- `TaxonomyResolver`
  - `TaxonomyRegistry` for lasting/validering av taxonomy-pakker
  - `TaxonomyTermResolver` for inheritance, i18n labels og deprecation replacement
  - guidance-resolve for incentive-basert root purpose + goal policy
  - purpose-tree validering (`validatePurposeTree`) for mandatory arv + konfliktregler + goal-link checks
- `KeyPathResolver`
  - `KeyPathRegistry` for specs, aliases, routes og lint
  - `KeyPathResolver` for canonicalization, routing, permission-evaluering
  - `CommonsLocalService` som lokal API-fasade
- `CellBase Commons Cells`
  - `CommonsResolverCell` som wrapper for keypath-resolver/logikk
  - `CommonsTaxonomyCell` som wrapper for taxonomy/guidance-logikk
  - registrert for CellScaffold som `cell:///CommonsResolver` og `cell:///CommonsTaxonomy`

## Resolution flyt (keypath)
1. Normaliser path (`#/...`)
2. Alias/deprecation canonicalization (f.eks. `#/purposes -> #/perspective`)
3. Slå opp `KeyPathSpec` for canonical path
   - hvis path ikke finnes i registry: opprett en åpen/advisory spec (`haven.core#/OpenValue`)
4. Finn beste route via lengste prefix-match
5. Match route/cell mot `EntityAnchorBinding`
6. Kalkuler `resolved_cell_id`, `resolved_local_path`, `type_ref`
7. Evaluer tilgang ut fra `PermissionClass` + `RequesterContext`
8. Returner audit-info (alias, route, deprecated flagg)

## Taxonomy-prinsipp (incentives)
- Root purpose: `purpose.human-equal-worth` (UDHR Article 1)
- Overliggende bidragspurpose: `purpose.net-positive-contribution`
- Purposes bør følges av `goal`, men dette håndheves som insentiv (ikke hard regel)
- `mandatory_inherited_purposes` i guidance brukes som obligatorisk arve-anker for alle nye purpose-termer.
- `forbidden_relations_to_mandatory` sperrer formål som går på tvers av de obligatoriske.
- Runtime `Purpose` i CellBase støtter i tillegg `helperCells: [CellConfiguration]` for måloppnåelse.
  - helper-cell kan være helt automatisk remediation
  - eller kun en instruksjons-/veiledningscelle for brukeren

## SDG-oversettelse
- `haven.sdg` bygger paa `haven.core` og innforer et lite HAVEN-nativt mellomlag for aa oversette FNs baerekraftsmaal.
- Oversettelsesregelen i denne iterasjonen er:
  - FN Goal -> `purpose family`
  - FN Target -> `goal`
  - indikatorer -> maale- og evidensdefinisjoner i perspective/runtime
- Dette holder topologien ryddig og unngaar at 17 globale policymaal blir brukt som 17 flate runtime-formaal.

## Chronicle
- Alle `#/chronicle/*` paths går til `ChronicleCell`.
- `storage_domain` er satt til `chronicle-store` i keypath specs.
- Storage er dermed separerbar uten å bryte global keypath-kontrakt.

## Permission-prinsipp i MVP
- `public`: alltid tillatt
- `private`: owner/member/service
- `consent`: owner/service, eller eksplisitt consent token
- `aggregated`: alle autentiserte roller, sponsor kun aggregated

## Path URI
- Format: `haven://entity/<entity_id>#<json_pointer>`
- Støtte for `haven://entity/self#...` i CLI resolution
