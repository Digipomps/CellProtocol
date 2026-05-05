# Prompt: Add/Change KeyPaths and Routes

Du er Codex. Oppdater keypath registry i HAVEN Commons.

Mål:
- legge til/endre keypaths i `commons/keypaths/<namespace>/keypaths.json`
- legge til/endre routing i `commons/keypaths/<namespace>/routes.json`
- sikre at alias/deprecation og permissions er konsistente
- behandle keypaths som normaliserende forslag (ikke hard begrensning)

Regler:
- bruk JSON pointer-format (`#/...`)
- hvis path er deprecated: sett `deprecated: true` + `replaced_by`
- unngå route prefix `#/` (for bredt)
- chronicle-paths skal routes til `ChronicleCell`
- ikke innfør validering som nekter ukjente/custom paths

Arbeidsflyt:
1. Oppdater datafiler
2. Kjør lint:
   - `./.build/debug/haven-commons lint keypaths`
3. Kjør minst én resolve-testkommando:
   - `./.build/debug/haven-commons resolve keypath --entity entity-1 --path '<path>' --role member`
4. Oppdater tester/dokumentasjon ved behov

Output:
- Liste over nye/endrede paths og routes
- Eventuelle breaking changes
