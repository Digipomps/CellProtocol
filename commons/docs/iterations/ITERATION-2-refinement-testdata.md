# Iteration 2 - Refinement and Test Data

## Mål
- Øke robusthet og testbarhet for CellScaffold-integrasjonen.

## Endringer
- Batch-endpoints for keypaths og taxonomy.
- Store fixture-datasett:
  - `CommonsKeypathRequests.json` (30 requests)
  - `CommonsTermRequests.json` (20 requests)
  - `CommonsHelperCellExamples.json` (helperCell-eksempler)
- Oppdatert tester for cells + fixture validering.
- Oppdatert dokumentasjon og prompt-maler.

## Resultat
- Commons kan brukes direkte fra CellConfiguration-referanser i scaffold.
- Både automatiske og veiledende helper-celler støttes i praksis.
