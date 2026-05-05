# Iteration 7: SDG Purpose Translation

## What changed
This iteration introduced the first SDG translation layer in Commons:
- a new taxonomy package: `haven.sdg`
- a HAVEN-native intermediate layer for grouping SDG families
- a first set of measurable goal templates
- a minimal perspective-schema extension for measurement and evidence metadata

## Added files
- `commons/taxonomies/haven.sdg/package.json`
- `commons/docs/architecture/sdg-purpose-translation.md`
- extended `PerspectiveGoal` fields in `HavenPerspectiveSchemas`

## Design choices
- the 17 UN Goals were not imported as 17 flat runtime purposes
- the existing root remained unchanged:
  - `purpose.human-equal-worth`
  - `purpose.net-positive-contribution`
- UN Goal is treated as `purpose family`
- local measurement details live in perspective/runtime rather than in taxonomy alone

## Why this was the right first cut
This gives HAVEN:
- a normatively consistent topology
- a compact schema surface
- a clean separation between canonical meaning and local measurement instantiation

## Explicitly deferred
- full import of all 169 UN targets
- new relation kinds such as `enables` or `measured_by`
- a runtime evaluator for every new goal field
