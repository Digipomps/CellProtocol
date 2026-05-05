# Seed Data

## Taxonomies

### `haven.core`
Seedede term-kategorier:
- purposes: `human-equal-worth` (root), `net-positive-contribution`, `learn`, `network`, `collaborate`, `sell`, `buy`, `hire`, `invest`, `present` (deprecated), `share`, `discuss`, `research`
- goals: `reduce-emissions`, `support-local-community`, `increase-child-participation`, `uphold-equal-human-worth`
- interests/topics/roles/values/skills: utvidet minimumssett for testbar MVP

Deprecation:
- `purpose.present` er deprecated og erstattes av `purpose.share`

Guidance:
- `root_purpose_term_id`: `purpose.human-equal-worth` (UDHR Article 1)
- `contribution_purpose_term_id`: `purpose.net-positive-contribution`
- `mandatory_inherited_purposes`: `purpose.human-equal-worth`, `purpose.net-positive-contribution`
- `forbidden_relations_to_mandatory`: `opposes`
- `goal_policy.mode`: `encouraged`
- `incentive_only`: `true` (ikke hard rule enforcement)

### `haven.conference`
Bygger på `haven.core` (`depends_on: ["haven.core"]`) med:
- `conference.session`
- `conference.track`
- `conference.workshop`
- `conference.expo`
- `conference.sponsor`
- `conference.exhibitor`
- `conference.hosted-buyer`
- `conference.lead`

### `haven.sdg`
Bygger på `haven.core` (`depends_on: ["haven.core"]`) med:
- 5 HAVEN-native metaformål for SDG-oversettelse
- 17 purpose families som dekker de 17 baerekraftsmaalene
- 17 goal-templates, ett per purpose family
- 3 pilot domains med dypere operasjonalisering:
  - climate mobility
  - local child participation
  - institutional accountability

Eksempler:
- `purpose.sdg.no-poverty`
- `purpose.sdg.climate-stability-and-adaptation`
- `purpose.sdg.justice-and-accountable-institutions`
- `goal.sdg.climate.emissions-intensity-reduction`
- `goal.sdg.justice.decision-transparency-rate`
- `purpose.sdg.climate.member-mobility-decarbonization`
- `goal.sdg.local-child-participation.active-retention-rate`
- `goal.sdg.institutional.decision-rationale-publication-latency`

Prinsipp:
- FN Goal oversettes til `purpose family`
- maale- og evidensnaere oppfoelging legges i `goal`
- alle SDG-avledede purposes arver fortsatt root via `haven.core`
- runtime helper bundles for pilot domains ligger i `Sources/CellBase/PurposeAndInterest/SDGPilotPurposeCatalog.swift`

## Keypaths
Seedede nøkkelpaths i `commons/keypaths/haven.core/keypaths.json`:
- `#/identity/names`
- `#/identity/addresses`
- `#/identity/contacts`
- `#/credentials/verifiable`
- `#/credentials/presentations`
- `#/proofs`
- `#/proofs/keypaths`
- `#/representations/entities`
- `#/perspective`
- `#/perspective/pre`
- `#/perspective/during`
- `#/perspective/post`
- `#/perspective/pre/goals`
- `#/perspective/during/goals`
- `#/perspective/post/goals`
- `#/perspective/*`
- `#/purposes` (deprecated -> `#/perspective`)
- `#/chronicle`
- `#/chronicle/events`
- `#/chronicle/graph`

## Routes
Seedede routes i `commons/keypaths/haven.core/routes.json`:
- `#/identity` -> `IdentityCell`
- `#/credentials` -> `CredentialsCell`
- `#/proofs` -> `CredentialsCell`
- `#/representations` -> `EntityAnchorCell`
- `#/perspective` -> `PerspectiveCell`
- `#/chronicle` -> `ChronicleCell`

Merk:
- Uregistrerte keypaths er tillatt og resolves som åpne referanser.
