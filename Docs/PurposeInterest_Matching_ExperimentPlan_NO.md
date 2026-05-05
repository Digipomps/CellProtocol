# Purpose/Interest Matching: Videre plan og vitenskapelig testoppsett

Sist oppdatert: 2026-03-26

## 1. Utgangspunkt i dagens kode

Vi har allerede to relevante fundament i kodebasen:

1. En enkel, deterministisk signalmatcher:
   - `Sources/CellBase/PurposeAndInterest/Signal.swift`
   - `Sources/CellBase/PurposeAndInterest/Purpose.swift`
   - `Sources/CellBase/PurposeAndInterest/Interest.swift`
   - `Tests/CellBaseTests/PurposeAndInterestMatchingTests.swift`

   Dagens matcher fungerer i praksis som:

   - velg relasjon (`types`, `parts`, `interests`, ...)
   - sammenlign signalvekt mot kantvekt innenfor toleranse
   - registrer treff i `HitCollector`

   Dette er et godt utgangspunkt for et-lags matching. Samtidig er dagens `Signal`
   bare delvis utnyttet: `ttl` og `hops` finnes i modellen, men brukes ikke aktivt
   i matchingflyten enda.

2. En nyere relasjonslaeringsmotor:
   - `Sources/CellBase/PurposeAndInterest/RelationalLearningEngine.swift`
   - `Sources/CellBase/PurposeAndInterest/RelationalLearningModels.swift`
   - `Sources/CellApple/PurposeAndInterest/Cells/RelationalLearningCell.swift`
   - `Tests/CellBaseTests/RelationalLearningEngineTests.swift`

   Denne motoren gir:

   - replaybare og deterministiske vekter
   - scoring av `Purpose` fra kontekstsnapshot
   - explainability
   - lokale, eventdrevne oppdateringer

Det som mangler mellom disse to sporene er en felles match-orchestrering:

- signalinstans med lokal tilstand
- flerlags grafgjennomgang
- collector/oppsamlingsnoder med terskler
- et kontrollert eksperiment som sammenligner vektet grafmatching mot vektor/cosinus

## 2. Maal

Vi vil svare paa to ulike sporsmaal:

1. Er forhaandsjusterte vekter i ferdigoppsatte grafer bedre enn cosinuslikhet i
   vektorrom for raske, praktiske `Purpose`/`Interest`-matcher?
2. Naar en enkel, ferdigjustert graf ikke er nok, kan vi ga over i et dypere og
   mer iterativt grafloep uten aa miste determinisme og forklarbarhet?

Dette tilsvarer:

- System 1: rask matching i ferdigkonfigurert graf
- System 2: dypere, oppgavekonfigurert iterasjon gjennom flere perspektivlag

## 3. Foreslaatt arkitekturretning

## 3.1 Fase 1: Et-lags matching som ren baseline

Foerste leveranse boer vaere en ren og avgrenset baseline som bygger videre paa
dagens matcher.

Foreslaatte endringer:

- Behold dagens `Weight<T>`-kanter og relasjoner som primitiv.
- Introduser en egen runtime-struktur, for eksempel `SignalRunState`, slik at vi
  skiller:
  - statisk matchforesporsel
  - lokal tilstand for den konkrete signalinstansen
- La signalinstansen vedlikeholde:
  - `visitedRefs`
  - `path`
  - `accumulatedEvidence`
  - `accumulatedScore`
  - `localVariables`
  - `remainingHops`
  - `deadline`

Viktig prinsipp:

- `Signal` beskriver hva som skal matches.
- `SignalRunState` beskriver hva som har skjedd i denne konkrete gjennomkjoringen.

Foerste et-lags flyt:

1. Velg startnode i `Perspective`.
2. Foelg en relasjonstype.
3. Filtrer paa vekt og toleranse.
4. Send treff til en eller flere collectors.
5. Returner forklarbar evidens, ikke bare refs.

Resultatet boer vaere et nytt svarobjekt, for eksempel:

- `MatchResult`
- `MatchHit`
- `MatchEvidence`

slik at vi ikke er laast til bare `HitCollector` med `Set<String>`.

## 3.2 Fase 1b: Collector-/oppsamlingsnoder

Naar et-lags matching fungerer, boer neste steg ikke vaere full grafdybde, men
oppsamlingsnoder med tydelig policy.

Collector-node boer minst ha:

- `collectorId`
- `threshold`
- `aggregationStrategy`
- `subscribers`
- `maxHits`
- `explainMode`

Eksempelstrategier:

- sum av bidrag
- maks-bidrag
- top-N gjennomsnitt
- minst ett hardt treff

Da kan ulike celler abonnere paa ulike collectors med ulike terskler, uten at vi
maa bygge ny matchinglogikk per celle.

## 3.3 Fase 2: Perspektivgrafer med flere lag

Naar vi har et robust et-lags loep, kan vi innfoere en eksplisitt grafmodell for
matching.

Foreslaatt modell:

- `PerspectiveMatchGraph`
- `PerspectiveMatchNode`
- `PerspectiveMatchEdge`
- `PerspectiveMatchProgram`

Node-typer:

- `source`
- `perspective`
- `filter`
- `transform`
- `collector`
- `terminal`

En `perspective`-node representerer et sted der signalet kan:

- lese lokale variable
- skrive lokale variable
- velge neste relasjon
- endre toleranse/terskel
- splitte signalet til flere grener

Dette gjor det mulig aa konfigurere oppgavespesifikke loep uten aa hardkode hver
analyse i `Purpose`, `Interest` eller `Perspective`.

## 3.4 Fase 3: System 1 og System 2 i samme motor

Etter at flerlagsgrafen finnes, boer vi eksplisitt modellere to kjoremodi:

- `fastPath`
  - ferdigoppsatt graf
  - faa hopp
  - stramme terskler
  - lav latency

- `deepPath`
  - dynamisk valgt graf eller subgraf
  - flere hopp
  - flere collectors
  - bedre recall og dypere analyse

Beslutningen mellom disse boer vaere styrt av policy:

- hoy usikkerhet i fastPath
- ingen collector over terskel
- sterk konflikt mellom collectors
- bruker eller celle ber eksplisitt om dyp analyse

## 3.5 Fase 4: Hybrid med vektorrom

Vektor/cosinus boer ikke sees som erstatning for grafmatching, men som en egen
arm i eksperimentet og eventuelt som fallback.

Anbefalt rolle for vektorrom:

- kandidatgenerering
- fuzzy semantikk naar grafen er tynn
- system-2-hjelp for aa foreslaa nye grafkanter eller nye startnoder

Anbefalt rolle for vektet grafmatching:

- raske beslutninger
- forklarbare beslutninger
- stabilitet over tid
- styrte terskler og abonnement

## 4. Konkrete leveranser i kode

## 4.1 Sprint A: Gjore et-lags matcher maale- og testbar

Lever:

- `SignalRunState`
- `MatchResult` med evidens
- collector som returnerer scorer, ikke bare refs
- scenariofixtures for ferdigoppsatte grafer

Legg dette naer:

- `Sources/CellBase/PurposeAndInterest/Signal.swift`
- ny testfil ved siden av `Tests/CellBaseTests/PurposeAndInterestMatchingTests.swift`

## 4.2 Sprint B: Oppsamlingsnoder og abonnement

Lever:

- collector-konfigurasjon
- terskler per collector
- fan-out til flere collectors
- enkel subscription-kontrakt for celler

## 4.3 Sprint C: Flerlags perspektivgraf

Lever:

- grafkonfigurasjon
- hoppkontroll
- lokale variabler i signalinstans
- path tracing
- cutoff-regler

## 4.4 Sprint D: Sammenligningsarm for vektor/cosinus

Lever:

- en ren baseline med embeddings + cosinus
- samme inputsett
- samme kandidatsett
- samme evalueringsprotokoll

Poenget er aa sammenligne metodene under like rammer, ikke bare vise at den ene
har mer informasjon enn den andre.

## 5. Vitenskapelig testoppsett

## 5.1 Hovedhypoteser

H1:
For oppgaver med godt kuraterte perspektivgrafer vil forhaandsjusterte vekter gi
hoyere presisjon og lavere latency enn ren vektor/cosinus-matching.

H2:
For oppgaver med svakt kuratert graf eller mer tvetydig semantikk vil
vektor/cosinus gi bedre recall enn ren et-lags vektmatching.

H3:
En hybridmodell vil gi best samlet nytte:

- grafmatching for presisjon og forklaring
- vektorrom for kandidatgenerering og fuzzy recall

## 5.2 Match-armer som skal sammenlignes

Vi boer minst teste fire armer:

1. `Weighted-Static`
   - forhaandsjusterte vekter
   - et-lags matching

2. `Weighted-Graph`
   - forhaandsjusterte eller laerte vekter
   - flerlags matching

3. `Vector-Cosine`
   - embedding per node eller nodebeskrivelse
   - cosinus mot query eller maalkonfigurasjon

4. `Hybrid`
   - vektor for kandidatgenerering
   - graf for endelig scoring og forklaring

Hvis vi vil teste lokale, laerte vekter separat, legg til:

5. `Weighted-Learned`
   - scorer fra `RelationalLearningEngine`

## 5.3 Datasett og ground truth

Testen maa baseres paa et fast og versjonert datasett. Ikke test paa ad hoc
eksempler alene.

Datasettet boer bestaa av:

- et sett `Purpose`-noder
- et sett `Interest`-noder
- eventuelle `EntityRepresentation`-noder
- ferdigoppsatte perspektivgrafer
- match-queries eller kontekstsnapshots
- fasitlabels

Hver testcase boer ha:

- `caseId`
- `input`
- `candidateSet`
- `expectedTopMatches`
- `acceptableMatches`
- `difficulty`
- `graphCoverage`

Anbefalt inndeling:

- enkle saker med sterk grafdekning
- middels saker med delvis grafdekning
- vanskelige saker med tvetydig spraak eller tynn graf

Ground truth boer lages blindt av minst to personer dersom mulig:

- annotator A merker riktige matcher
- annotator B merker riktige matcher
- uenighet logges og loeses eksplisitt

Da unngaar vi at motoren evalueres mot forfatterens magefoelelse alene.

## 5.4 Rettferdig sammenligning

Dette er viktig: forhaandsjusterte vekter og vektorrom er ikke automatisk
epler-mot-epler.

For aa gjoere sammenligningen rettferdig maa vi kontrollere:

- samme kandidatsett per case
- samme tekstgrunnlag per kandidat
- samme metadata-tilgang
- samme tidsbudsjett hvis latency er del av maalet
- samme maate aa beregne top-K paa

Hvis grafarmen bruker kuraterte relasjoner som vektorarmen ikke faar tilgang til,
maa det oppgis eksplisitt i resultatene. Da tester vi en systemforskjell, ikke
bare en algoritmeforskjell.

## 5.5 Metrikker

Vi boer maale minst disse dimensjonene:

- `Precision@1`
- `Precision@3`
- `Recall@3`
- `MRR`
- `nDCG@K`
- `p50 latency`
- `p95 latency`
- minnebruk per kjoring
- determinisme/replaybarhet
- forklarbarhet

Forklarbarhet kan maales enklere i starten:

- andel resultater med eksplisitt evidenssti
- gjennomsnittlig antall forklarbare bidrag per toppmatch

Senere kan dette utvides med menneskelig vurdering.

## 5.6 Eksperimentprotokoll

1. Frys datasett og versjoner grafer/vekter.
2. Del datasettet i:
   - tune/dev
   - endelig test
3. Juster terskler bare paa tune/dev.
4. La testsettet vaere urort til slutt.
5. Kjor alle armer paa nøyaktig samme testsett.
6. Logg alle resultater som artefakter.
7. Sammenlign med parvise statistiske tester.

Anbefalte statistiske analyser:

- bootstrap 95 % konfidensintervall for `Precision@K`, `Recall@K`, `MRR`
- Wilcoxon signed-rank for per-case scoreforskjeller
- McNemar for topp-1 riktig/feil dersom vi reduserer til binar beslutning

Rapporter alltid:

- gjennomsnitt
- median
- spredning
- konfidensintervall

Ikke rapporter bare enkeltcaser eller beste-case.

## 5.7 Robusthetstester

I tillegg til hovedtesten boer vi kjoere ablasjoner og stress:

- stoy i kantvekter
- manglende noder
- manglende kanter
- feilklassifiserte interesser
- varierende terskler i collectors
- varierende hoppdybde

Dette svarer paa om metoden er:

- presis
- stabil
- skjore eller robust

## 5.8 Operasjonell effektivitet

"Effektiv" maa defineres eksplisitt. Her boer vi bruke minst tre akser:

- match-kvalitet
- runtime-kostnad
- vedlikeholdskostnad

Forhaandsjusterte vekter kan vaere overlegne paa runtime, men dyrere aa
vedlikeholde. Vektorrom kan vaere enklere aa sette opp, men svakere paa
forklarbarhet. Derfor boer sluttrapporten ha baade:

- ren modellkvalitet
- total systemnytte

## 6. Anbefalt foerste milepael

Foerste milepael boer vaere liten og skarp:

1. Bygg et-lags matching med `SignalRunState` og collector-score.
2. Lag 30-50 faste testcases med kuraterte perspektivgrafer.
3. Lag en enkel vektor/cosinus-baseline paa samme cases.
4. Sammenlign:
   - kvalitet
   - latency
   - forklarbarhet
5. Avgjør deretter om flerlags grafmatching skal prioriteres foer hybridmodus.

Dette gir et reelt beslutningsgrunnlag tidlig, uten at vi maa bygge hele
System-2-motoren foerst.

## 7. Praktisk anbefaling for dette repoet

Den mest naturlige rekkefolgen i denne kodebasen er:

1. Utvid den eksisterende `Signal`-matcheren til en ordentlig runtime-primitive.
2. Lag et eget eksperiment-/benchmarklag i tester med faste fixtures.
3. Gjenbruk `RelationalLearningEngine` som separat laert-vekt-arm.
4. Koble `GraphMatchTool` til ekte matchresultater etter at testgrunnlaget er paa plass.
5. Bygg flerlags perspektivgraf bare etter at baseline-data viser hvor gevinsten er.

Da faar vi en utviklingsretning som er:

- inkrementell
- forklarbar
- testbar
- beslutningsdrevet

## 8. Status etter gjennomgang: hva er nok, og hva maa utvides

Det finnes nok bibliotek til aa vaere nyttig i en foerste lukket MVP:

- `PerspectiveCell` kan eksponere aktive formaal, aggregere interesser og matche
  direkte eller via interesser.
- `commons/taxonomies/haven.core` og `haven.sdg` gir en felles, versjonert
  sannhet for formaal/interesser med root-guardrails:
  - `purpose.human-equal-worth`
  - `purpose.net-positive-contribution`
- benchmarklaget har kuraterte scenarier, challenge-cases, weighted baseline,
  cosine baseline og rapportartefakt.

Det er likevel ikke nok til et omdoemmebasert trust-rammeverk alene. Vi mangler
fortsatt en eksplisitt bro mellom:

- at en aktor hevder aa kunne oppfylle/laase et formaal
- at mottakeren bekrefter at formaalet faktisk ble loest
- at mottakeren frivillig publiserer attestasjonen til et relevant
  entity-nettverk
- at andre kan bruke attestasjonen som kontekstuell evidens uten aa lage global
  personscore

Nytt prinsipp for tuning:

- HAVEN-hostet baseline er den felles sannheten.
- Lokale vekter skal vaere et overlay, ikke en fork av baseline.
- En lokal overlay maa kunne testes mot samme scenarier som baseline.
- Rapporten maa vise hvor lokal tuning endrer top-resultat eller confidence.

Foerste verktøy for dette finnes naa i `haven-commons benchmark purpose-interest`:

```bash
./.build/debug/haven-commons benchmark purpose-interest --format markdown
./.build/debug/haven-commons benchmark purpose-interest --format markdown --tuning Docs/benchmarks/purpose_interest_local_tuning_example.json
```

Tuningfilen beskriver lokale justeringer:

```json
{
  "tuningId": "local.feedback-burst-example",
  "description": "Local overlay, not shared truth.",
  "adjustments": [
    {
      "purposeId": "purpose.feedback-burst",
      "interestId": "interest.onboarding",
      "operation": "set",
      "value": 0.8
    }
  ]
}
```

Dette er ikke ferdig trust-infrastruktur, men det gir et konkret maaleverktøy for
aa se om lokale vekter drar brukeren for langt unna den felles modellen.

## 9. Neste manglende bibliotek: purpose-lock attestations

Neste bibliotek bør modelleres som kontekstuell evidens, ikke som global
reputation:

- `PurposeCapabilityClaim`
  - hvem hevder aa kunne oppfylle et formaal
  - hvilket `purpose_id`
  - hvilke interesser/kontekst claimet gjelder for
  - hvilke goal/evidence-regler som maa vaere oppfylt

- `PurposeFulfillmentAttestation`
  - hvem mottok hjelp
  - hvilket formaal ble loest
  - hvilke goal/evidence-regler ble brukt
  - om mottakeren tillater publisering
  - hvilket entity-nettverk attestasjonen kan publiseres til

- `PurposeTrustEvaluation`
  - scorer en claim/attestation lokalt og forklarbart
  - bruker felles baseline + lokale vekter
  - respekterer root: likeverd og netto positivt bidrag

Publisering maa vaere mottakerstyrt:

1. en aktor hevder aa kunne oppfylle/laase et formaal
2. mottakeren aksepterer hjelp under eksplisitt agreement
3. goal/evidence blir verifisert
4. mottakeren velger om attestasjonen skal publiseres
5. relevant entity-nettverk kan bruke den som kontekstuell evidens

Dette holder systemet i tråd med HAVEN: likeverd først, positivt bidrag som
insentiv, og trust som kontekstuell evidens fremfor global rangering av mennesker.
