ROLE: Codex

TASK:
Legg atlas-projeksjonen ut som en tynn bruksoverflate uten aa gjore den til ny sannhetskilde.

KRAV:
- lag `EntityAtlasInspectorCell` i `CellBase`
- bruk eksisterende `EntityAtlasService`
- registrer `cell:///EntityAtlas`
- eksponer snapshot, redigert JSON/Markdown og basisqueryer
- hold secrets redigert
- legg til test for snapshot + coverage + eksport

IKKE:
- lag egen persistent atlas-state
- innfor nye parallelle manifestsystemer
- legg raw secrets i `ValueType` eller eksport

CELL-OPERASJONER:
- `atlas.snapshot`
- `atlas.export.redactedJSON`
- `atlas.export.redactedMarkdown`
- `atlas.query.cellsForPurpose`
- `atlas.query.scaffoldCandidates`
- `atlas.query.purposesForCell`
- `atlas.query.cellsRequiringCredentials`
- `atlas.query.knowledgeCells`
- `atlas.query.dependencies`
- `atlas.query.coverage`
