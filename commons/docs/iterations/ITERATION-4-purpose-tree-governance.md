# Iteration 3 - Purpose Tree Governance

## Mål
- Håndheve at alle nye purpose-termer arver fra mandatory formål.
- Hindre purpose-termer som går på tvers av mandatory formål.
- Sikre at mandatory formål har konkrete goals for oppfølging.

## Endringer
- Utvidet `TaxonomyPackage.Guidance` med:
  - `mandatory_inherited_purposes`
  - `forbidden_relations_to_mandatory`
- Innført `validatePurposeTree(namespace:)` i taxonomy resolver.
- Innført resultattyper:
  - `PurposeTreeValidationResult`
  - `PurposeTreeValidationIssue`
- Eksponert validering i:
  - CLI: `haven-commons validate purposes --namespace <namespace>`
  - Cell: `taxonomy.validate.purposeTree` i `CommonsTaxonomyCell`
- Oppdatert seed-data:
  - Alle aktive core-purpose har arvebane til `purpose.net-positive-contribution`
  - Nytt goal: `goal.uphold-equal-human-worth` for `purpose.human-equal-worth`

## Resultat
- Mandatory formål (artikkel 1 + netto positivt bidrag) kan brukes som faktisk governance-anker.
- Nye formål kan valideres mot konfliktregler før publisering.
- Goal-kobling for mandatory formål er maskinvaliderbar.
