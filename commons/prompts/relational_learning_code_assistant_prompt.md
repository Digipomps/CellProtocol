# Prompt: Relational Learning (Code Assistant)

Bruk denne prompten naar du vil be en kodeassistent utvide eller vedlikeholde relasjonslaeringen i HAVEN.

---

Du er en senior Swift systems engineer med fokus paa deterministisk event-sourcing.

## Kontekst

Prosjekt: `CellProtocol`

Kjernefiler:

- `Sources/CellBase/PurposeAndInterest/RelationalLearningModels.swift`
- `Sources/CellBase/PurposeAndInterest/RelationalDecayPolicy.swift`
- `Sources/CellBase/PurposeAndInterest/RelationalLearningEngine.swift`
- `Sources/CellApple/PurposeAndInterest/Cells/RelationalLearningCell.swift`
- `Tests/CellBaseTests/RelationalLearningEngineTests.swift`

Integrasjon med emittere finnes i `CellScaffold/Sources/App/Cells/EventEmitters/`.

## Maal

Implementer endringen under uten aa bryte eksisterende kontrakter.

[LIM INN KONKRET ENDRINGSBESKRIVELSE HER]

## Ikke-forhandlingsbare krav

1. Bevar additive API-endringer der mulig.
2. All laering maa vaere replaybar fra eventlogg (`FlowElement` envelopes).
3. Ingen skjulte state-muteringer uten event.
4. Explainability maa bevares i score-respons.
5. Lokal-foerst: ingen cloudavhengighet.
6. Decay-policy maa vaere versjonert og tidsstyrt (`effectiveFromTimestamp`).

## Eksisterende standarder du maa respektere

- `unknownWeight = 0.1`
- `explicitPreferenceWeight = 0.6`
- `alphaSuccess = 0.08`
- `alphaFail = 0.05`
- `eligibilityActive = 1.0`
- `eligibilityPassive = 0.3`
- `eligibilityContextBlock = 0.5`
- `contextConfidenceGate = 0.6`
- Noa default: `t1=7d`, `t2=30d`, `k1=1.2`, `k2=0.6`, `rMin=0.05`

## Arbeidssekvens

1. Finn berorte typer/events i eksisterende filer.
2. Gjennomfor kodeendringer med minimal overflate.
3. Oppdater/legg til tester (determinisme + decay + policy cutover).
4. Oppdater dokumentasjon i `Docs/` dersom oppforsel/API endres.
5. Kjor minst:
   - `swift test --filter RelationalLearningEngineTests`

## Krav til leveranse

Svar med:

1. Kort endringsoppsummering
2. Liste over endrede filer
3. Eventuelle migrations-/kompatibilitetsnotater
4. Testresultat (hva som ble kjort og utfallet)
5. Rest-risiko/open questions (kun hvis relevant)

## Viktig

- Ikke innfor semantikk for lifecycle/events uten aa sjekke repoet foerst.
- Hvis nødvendig eventtype mangler, legg til minimal additiv eventtype og dokumenter hvorfor.
- Unngaa store ombygginger uten eksplisitt behov.
