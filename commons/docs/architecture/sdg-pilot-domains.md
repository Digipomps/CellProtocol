# SDG Pilot Domains and Helper Cells

## Purpose
This document describes the first three operational SDG pilot domains added on top of the base `haven.sdg` translation.

The goal is to move from general SDG purpose families to concrete, measurable purpose templates that a person, team or scaffold can actually use.

## Pilot domains
The current pilot set is intentionally small:
- climate mobility
- local child participation
- institutional accountability

These were chosen because together they exercise three different kinds of measurement and support:
- environmental intensity reduction
- inclusive participation and retention
- accountable process and publication discipline

## Pilot 1: Climate mobility
Taxonomy terms:
- `purpose.sdg.climate.member-mobility-decarbonization`
- `goal.sdg.climate.member-mobility-emissions-intensity`

Intent:
- reduce emissions intensity for member and participant travel
- keep access fair across geography and income

Typical metric:
- `kgCO2e_per_member_km`

Typical guardrail:
- do not reduce access for lower-income or remote participants while improving the metric

Runtime helper bundle:
- baseline capture via `VaultCell`
- evidence-path normalization via `CommonsResolverCell`
- fairness and coverage review via `CommonsTaxonomyCell` and `EntityAtlas`

## Pilot 2: Local child participation
Taxonomy terms:
- `purpose.sdg.local-child-participation-and-belonging`
- `goal.sdg.local-child-participation.active-retention-rate`

Intent:
- increase active participation and long-term belonging for children in local activities
- avoid widening participation gaps between neighborhoods, genders or backgrounds

Typical metrics:
- active child count
- retention rate across a season or year

Typical guardrail:
- a higher participation number is not enough if access becomes less fair across groups

Runtime helper bundle:
- baseline capture via `VaultCell`
- evidence routing toward perspective-goal tracking
- fairness and coverage review via taxonomy and atlas

## Pilot 3: Institutional accountability
Taxonomy terms:
- `purpose.sdg.institutional-decision-transparency-and-remedy`
- `goal.sdg.institutional.decision-rationale-publication-latency`

Intent:
- make decisions explainable, reviewable and correctable within an agreed window

Typical metric:
- share of decisions published with rationale within seven days

Typical guardrail:
- publication discipline must not come at the cost of excluding affected parties from review or remedy

Runtime helper bundle:
- baseline capture via `VaultCell`
- evidence routing toward chronicle/graph-style records
- fairness and coverage review via taxonomy and atlas

## Why helper cells are runtime, not taxonomy
`TaxonomyPackage` does not carry `helperCells`, and that is the correct boundary.

Taxonomy should answer:
- what a purpose means
- how it relates to other purposes and goals

Runtime purpose templates should answer:
- which helper cells to open
- which evidence path to normalize
- how to seed a baseline note
- how to run fairness checks before calling a goal successful

This iteration therefore introduces `SDGPilotPurposeCatalog` in `CellBase` instead of bloating the taxonomy schema.

## Runtime catalog
`SDGPilotPurposeCatalog` exposes:
- `templates()`
- `template(for:)`
- `makePurpose(for:)`
- `allPilotPurposes()`

Each returned `Purpose` has:
- a concrete goal configuration
- three helper cells
  - baseline capture
  - evidence routing
  - fairness guardrail

## Perspective examples
This iteration also adds typed `PerspectiveDocument` examples for each pilot domain:
- `commons/examples/perspectives/sdg-climate-mobility.json`
- `commons/examples/perspectives/sdg-local-child-participation.json`
- `commons/examples/perspectives/sdg-institutional-accountability.json`

The examples are intentionally small, but they show the minimum operational shape:
- the active pilot purpose
- the inherited HAVEN root guardrails in `pre.purposes`
- one measurable pilot goal with `purpose_id`
- baseline, target, timeframe, data source and evidence rule
- stage-specific constraints across `pre`, `during` and `post`

These files are meant to be copied, adapted and validated, not treated as a closed catalog.

## Extension rule
When adding another pilot domain, the minimum bar should be:
- one taxonomy `purpose`
- one taxonomy `goal`
- one measurable metric hint
- one runtime purpose template
- at least one helper for baseline, one for evidence and one for guardrails
