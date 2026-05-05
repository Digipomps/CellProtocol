# SDG Translation to Purpose and Goal in HAVEN

## Purpose
This document explains how the UN Sustainable Development Goals are translated into HAVEN Commons without creating a parallel policy system or replacing the existing moral root.

The translation builds on the two root anchors already defined in `haven.core`:
- `purpose.human-equal-worth`
- `purpose.net-positive-contribution`

Every SDG-derived purpose therefore remains downstream of the same normative root that already governs the rest of HAVEN.

## Translation Rule
HAVEN uses this working translation:
- UN Goal -> `purpose family`
- UN Target -> `goal`
- UN Indicator -> measurement or evidence reference
- local project context -> instantiated goal in perspective or runtime

This keeps the taxonomy compact while still allowing local systems to become measurable.

## Why the 17 Goals are not flat siblings
The 17 Goals are not at the same operational level.

Some are mainly outcome-oriented:
- poverty
- health
- education
- inequality
- climate
- ecosystems

Others are largely enabling or governance-oriented:
- infrastructure and innovation
- institutions and justice
- partnerships

Flattening them directly under the root would make the taxonomy harder to use in runtime configuration, helper-cell design and explainability.

## HAVEN-native intermediate layer
`haven.sdg` introduces a small intermediate layer of meta-purposes:
- `purpose.sdg.basic-living-conditions`
- `purpose.sdg.human-capability-and-equity`
- `purpose.sdg.regenerative-resource-stewardship`
- `purpose.sdg.resilient-communities-and-infrastructure`
- `purpose.sdg.just-coordination-and-partnership`

This layer is not a replacement for the SDGs. It is a practical grouping layer that makes the SDG translation usable inside HAVEN.

## Measurability
To use SDG-derived goals operationally, each instantiated goal should be able to express:
- `purpose_id`
- `metric`
- `baseline`
- `target`
- `timeframe`
- `data_source`
- `evidence_rule`
- optional `indicator_refs`

In practice:
- taxonomy defines the canonical meaning of the goal
- perspective/runtime defines the local measurement window and evidence path

## Root guardrails
All SDG-derived purposes inherit the root and should be evaluated against two guardrails:
- equal human worth: improvement cannot depend on exclusion or discrimination
- net positive contribution: improvement should not quietly shift disproportionate harm to others

This is where HAVEN differs from a neutral policy catalog.

## Helper cells
`Purpose.helperCells` is the runtime mechanism for supporting goal achievement.
Typical helper roles include:
- baseline capture
- evidence collection
- fairness review
- user guidance
- automated remediation where appropriate

The taxonomy remains clean because helper configuration stays in runtime purpose templates, not in taxonomy terms.

## Current scope
The current SDG layer intentionally stays compact:
- 5 meta-purposes
- 17 SDG purpose families
- 17 SDG family goal templates
- 3 concrete pilot domains for deeper operational use

It does not attempt a full import of all 169 UN targets yet.

## Next step after the base translation
The next practical step is to deepen selected pilots rather than importing everything at once:
1. add domain-specific pilot purposes and goals
2. bind helper-cell bundles to those pilots
3. instantiate local perspective documents with baseline and timeframe
4. expand toward target-level templates only where real usage demands it
