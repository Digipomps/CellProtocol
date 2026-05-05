# Iteration 9: SDG Pilot Perspective Examples

## What changed
This iteration adds concrete `PerspectiveDocument` examples for the first three SDG pilot domains:
- climate mobility
- local child participation
- institutional accountability

## Why this matters
Up to this point, the SDG pilot work covered:
- taxonomy purpose and goal terms
- runtime `Purpose` templates with helper-cell bundles
- measurable goal fields in the perspective schema

What was still missing was a small set of actual documents that show how those layers fit together in real data.

## Added examples
The new files live in `commons/examples/perspectives/`:
- `sdg-climate-mobility.json`
- `sdg-local-child-participation.json`
- `sdg-institutional-accountability.json`

Each example includes:
- the active SDG pilot purpose
- the two HAVEN root guardrails in `pre.purposes`
- one measurable goal bound to `purpose_id`
- `metric`, `baseline`, `target`, `timeframe`, `data_source` and `evidence_rule`
- phase-specific constraints across `pre`, `during` and `post`

## Test coverage added
`PerspectiveSchemaTests` now decodes all three example files and checks that:
- each example resolves to the expected pilot `purpose_id`
- each example resolves to the expected pilot `goal_id`
- the root guardrail purposes are present in the pre-state
- the goal stays stable across `pre`, `during` and `post`

## Design boundary
These example files are not a locked registry.
They are reference documents that people and scaffolds can adapt when creating their own perspectives.

## What remains for a later step
- target-level expansion inside each pilot domain
- stricter machine-readable evidence expressions if the evaluator layer needs them
- reusable generation helpers for pilot perspective documents
