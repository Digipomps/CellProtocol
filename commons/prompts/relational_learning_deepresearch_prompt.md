# Prompt: DeepResearch for Relational Learning Policy

Bruk denne prompten i ChatGPT DeepResearch for aa hente forskningsbasert beslutningsgrunnlag for neste versjon av relasjonslaeringen.

---

ROLE: Deterministic event-sourcing ML systems researcher + privacy-first recommender architect.
DATE CONTEXT: 2026-03-02.

## Problem

Vi har en lokal, deterministisk relasjonslaering for `Purpose`-anbefalinger med noder:

- `Purpose`
- `Interest`
- `EntityRepresentation`
- `ContextBlock`

Og vektede kanter med decay.

Systemet maa forbli:

- replaybart fra eventlogg
- forklarbart paa edge-nivaa
- lokal-foerst (ingen cloudkrav)
- kompatibelt med versjonerte decay policy-events

## Eksisterende baseline (maa brukes som referanse)

- update-regler:
  - success: `w' = w + a * e * (1 - w)`
  - fail: `w' = w - a * e * w`
- default:
  - `unknownWeight=0.1`
  - `explicitPreference=0.6`
  - `alphaSuccess=0.08`
  - `alphaFail=0.05`
  - eligibility: active/passive/context = `1.0 / 0.3 / 0.5`
  - confidence-gate = `0.6`
- decay:
  - Noa double-sigmoid
  - `t1=7d`, `t2=30d`, `k1=1.2`, `k2=0.6`, `rMin=0.05`
- policy cutover:
  - `DecayPolicyUpdated(version, effectiveFromTimestamp, params)`

## Forskningsspoersmaal

1. Hvilke alternativer til dagens update-regel gir bedre stabilitet ved sparse data, uten aa bryte replaybarhet?
2. Hvilken decayfamilie (double-sigmoid, piecewise exponential, Weibull, power-law) passer best for "slow -> fast -> slow" i menneskelig rutinekontekst?
3. Hvordan kalibrere confidence-gating robust naar kildene er heterogene (`location`, `time`, `entities`)?
4. Hvilken explainability-struktur er best for brukerforstaelse uten aa oeke datalekkasjerisiko?
5. Hvilke offline evalueringsmetoder kan brukes paa lokal eventlogg uten labels i stor skala?

## Leveranseformat (obligatorisk)

Gi et svar med disse seksjonene:

1. **Kildegrunnlag**
   - Primarkilder med lenker (papirer, standarder, tekniske rapporter).
   - Kort hvorfor hver kilde er relevant.
2. **Sammenligning av kandidater**
   - Tabell med minst 3 update-regler og 3 decayfamilier.
   - Fordeler/ulemper for determinisme, replay, forklarbarhet, personvern.
3. **Anbefalt policy v2**
   - Konkrete parameterforslag.
   - Triggerkriterier for policy cutover.
   - Risikoanalyse.
4. **Eksperimentplan lokalt**
   - Hvordan evaluere med replay av eksisterende logg.
   - Metrikker (stabilitet, respons, ranking-konsistens, drift).
5. **Migreringsplan uten historikkomskriving**
   - Hvordan introdusere `version+effectiveFromTimestamp`.
   - Hvordan validere bakoverkompatibilitet.
6. **Konkret handlingsliste**
   - Prioritert TODO-liste (kort, implementerbar).

## Viktige avgrensninger

- Ingen forslag som krever sentralisert profilering.
- Ingen forslag som bryter event-sourcing.
- Ingen "black box"-modeller uten edge-nivaa explainability.
- Forslagene maa kunne implementeres i Swift i en actor-basert motor.
