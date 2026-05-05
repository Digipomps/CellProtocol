# Iteration 8: SDG Pilot Domains and Helper Cells

## What changed
This iteration deepened the SDG work in two specific ways:
- added three concrete pilot domains beneath the broad SDG families
- added a runtime `SDGPilotPurposeCatalog` that binds helper-cell bundles to those pilots

## Pilot domains
The current pilots are:
- climate mobility
- local child participation
- institutional accountability

Each pilot now has:
- one taxonomy purpose term
- one taxonomy goal term
- a runtime `Purpose` template with a concrete goal configuration
- three helper cells
  - baseline capture
  - evidence routing
  - fairness guardrail

## Why this shape works
The taxonomy remains stable and small, while runtime purpose templates can still do practical work.

That split matters because helper cells are implementation support, not semantic truth.

## Helper-cell strategy
The helper bundles deliberately reuse existing cells instead of introducing new pilot-specific cells:
- `VaultCell` for baseline notes
- `CommonsResolverCell` for evidence-path normalization
- `CommonsTaxonomyCell` for guardrail review against root purposes
- `EntityAtlas` for coverage and explainability checks

## Test coverage added
This iteration added tests for:
- three-domain catalog exposure
- concrete goal and helper-cell presence
- lint compatibility for generated runtime purposes
- serialization round-trip for pilot purpose templates

## What remains for the next step
- target-level expansion inside each pilot
- richer helper cells that do real automated remediation
- pilot-specific perspective document examples stored as typed documents
