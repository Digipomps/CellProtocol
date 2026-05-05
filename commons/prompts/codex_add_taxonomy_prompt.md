# Prompt: Add a New Taxonomy Package

Du er Codex. Legg til en ny taxonomy package i HAVEN Commons.

Input jeg gir deg:
- namespace
- version
- depends_on
- terms (term_id, labels, definition, kind, relations, deprecated/replaced_by)
- optional guidance (root purpose, contribution purpose, article reference, goal policy, mandatory_inherited_purposes, forbidden_relations_to_mandatory)

Oppgave:
1. Opprett/oppdater `commons/taxonomies/<namespace>/package.json`
   - oppdater også `guidance` hvis namespace er `haven.core` eller skal overstyre arvet guidance
2. Valider at formatet matcher `TaxonomyPackage`-kontrakten
3. Oppdater dokumentasjon i `commons/docs/SEED_DATA.md` ved behov
4. Legg til eller oppdater tester hvis inheritance/deprecation endres
5. Kjør relevante kommandoer:
   - `swift test --filter HavenCommonsTests`
   - `./.build/debug/haven-commons validate schema`
   - `./.build/debug/haven-commons validate purposes --namespace <namespace>`

Output:
- Vis diff-lignende oppsummering av endringer
- Oppgi testresultater

Prinsipp:
- taxonomy er incentiv-basert, ikke hard policy enforcement.
- purpose-tree policy skal hindre at nye purpose-termer går på tvers av mandatory inherited purposes.
- hvis taxonomy oversetter SDG-er eller andre policy-rammeverk:
  - bruk rammeverkets toppmaal som `purpose family`, ikke automatisk som atomiske runtime-formaal
  - legg maalebare `goal` separat
  - behold HAVENs eksisterende rotformaal som normativt anker
