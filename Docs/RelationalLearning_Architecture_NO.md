# Relasjonslaering for Purpose/Interest/Entity (Arkitektur)

Sist oppdatert: 2026-03-02

## 1. Maal

Denne implementasjonen innforer purpose-drevet relasjonslaering som vektede kanter mellom:

- `Purpose`
- `Interest`
- `EntityRepresentation`
- `ContextBlock`

Laeringen er laget for aa vaere:

- deterministisk
- replaybar fra eventlogg (`FlowElement`-konvolutter)
- forklarbar (explainability)
- lokal-foerst (ingen skyavhengighet)

## 2. Hvor implementasjonen ligger

### Kjerne (CellBase)

- `Sources/CellBase/PurposeAndInterest/RelationalLearningModels.swift`
- `Sources/CellBase/PurposeAndInterest/RelationalDecayPolicy.swift`
- `Sources/CellBase/PurposeAndInterest/RelationalLearningEngine.swift`

### Integrasjon (CellApple)

- `Sources/CellApple/PurposeAndInterest/Cells/RelationalLearningCell.swift`

### Tester

- `Tests/CellBaseTests/RelationalLearningEngineTests.swift`

Plasseringen holder logikk tett paa core (`CellBase`) med en tynn celle-integrasjon (`CellApple`).

## 3. Datamodell

### 3.1 Noder

- `RelationalNodeType.purpose`
- `RelationalNodeType.interest`
- `RelationalNodeType.entityRepresentation`
- `RelationalNodeType.contextBlock`

### 3.2 Kant

`RelationalEdge` inneholder:

- `fromNode`
- `relationType`
- `toNode`
- `weightStored` (0...1)
- `lastReinforcedAt`
- `decayProfileId`
- `decayParamsVersion`
- `metadata`

### 3.3 Eventtyper

Alle laeringsrelevante hendelser kan serialiseres i `RelationalLearningEventEnvelope`:

- `purposeLifecycle`
- `weightUpdate`
- `decayPolicyUpdated`
- `contextTransition`
- `explicitPreference`

## 4. Determinisme og replay

## 4.1 Ingen skjulte mutasjoner

Motoren (`RelationalLearningEngine`) muterer kanttilstand via:

- `applyWeightUpdateEvent(_:)` for vektendringer
- `applyDecayPolicyUpdatedEvent(_:)` for policyregister

Lokal beregning (for eksempel ved `PurposeSucceeded`) gir eksplisitte `RelationalWeightUpdateEvent` som kan pushes i streamen. Dermed kan samme logg reprodusere samme tilstand.

## 4.2 Deterministisk replayrekkefolge

Ved replay sorteres events etter:

1. `emittedAt`
2. `eventType`
3. `eventId` (hvis tilgjengelig i payload)
4. kanonisk payload-streng (sorterte nøkler)

Dette fjerner ikke-determinisme ved tidslikhet/tie-cases.

## 4.3 Idempotens

- Doble `weightUpdate` stoppes via `appliedWeightUpdateEventIDs`
- Doble `decayPolicyUpdated` stoppes via `appliedDecayPolicyEventIDs`

## 5. Laeringsregel

## 5.1 Standardverdier

- `unknownWeight = 0.1`
- `explicitPreferenceWeight = 0.6`
- `alphaSuccess = 0.08`
- `alphaFail = 0.05`
- `eligibilityActive = 1.0`
- `eligibilityPassive = 0.3`
- `eligibilityContextBlock = 0.5`
- `contextConfidenceGate = 0.6`

## 5.2 Oppdatering ved suksess/feil

For kantvekt `w`, eligibility `e`, laeringsrate `a`:

- suksess: `w' = clamp01(w + a * e * (1 - w))`
- feil: `w' = clamp01(w - a * e * w)`

Eksplisitt brukerpreferanse setter direkte vekt:

- `w' = preferenceWeight`

## 5.3 Eligibility traces

Ved `PurposeStarted` opprettes sesjon.
Ved `PurposeSucceeded`/`PurposeFailed` bygges traces fra:

- aktive interesser
- passive interesser
- aktive entiteter
- passive entiteter
- aktive kontekstblokker

Kontekstblokker krever `confidence >= contextConfidenceGate`.
Konteksteligibility skaleres: `eligibilityContextBlock * confidence`.

## 6. Decay-policy og Noa-profil

## 6.1 Policy-objekt

`RelationalDecayPolicy` er versjonert og tidsstyrt:

- `profileId` (f.eks. `noa`)
- `version`
- `effectiveFromTimestamp`
- `kind`
- `noaParameters`

Policy kan oppdateres over tid via `RelationalDecayPolicyUpdatedEvent` uten aa endre historiske events.

## 6.2 Noa slow-fast-slow

Noa implementeres som normalisert dobbel sigmoid med gulv `rMin`.

Effektiv vekt:

- `effectiveWeight = weightStored * R(deltaT)`

Der:

- `deltaT = now - lastReinforcedAt`
- `R(deltaT)` beregnes fra `t1Seconds`, `t2Seconds`, `k1`, `k2`, `rMin`

Standard:

- `t1 = 7d`
- `t2 = 30d`
- `k1 = 1.2`
- `k2 = 0.6`
- `rMin = 0.05`

## 6.3 Policy cutover

Ved scoring/replay brukes policy med:

- riktig `profileId`
- seneste `effectiveFromTimestamp <= tidspunkt`

Det gir deterministic cutover mellom policyversjoner.

## 7. Scoring og explainability

API:

- `scorePurposes(contextSnapshot:at:explainTopN:) -> [RelationalPurposeScore]`

For hver kandidatpurpose returneres:

- `score`
- `explain.rawScore`
- `explain.normalizedScore`
- `explain.topEdges[]`

Hver explain-kant inneholder:

- kantsdata
- `effectiveWeight`
- `contribution`
- `decayProfileId`
- `decayParamsVersion`
- decay-parametre brukt i beregningen

## 8. Integrasjon mot eksisterende EventEmitter-celler

`RelationalLearningCell` kan hente kontekst fra innkommende `FlowElement` via `RelationalContextTransitionEvent.fromFlowElement(_:)`.

Legacy topic-mapping som stoettes:

- `locations` eller `context.location*` -> domain `location`
- `times` eller `context.time*` -> domain `time`
- `entities` eller `context.entities*` -> domain `entities`

Felt som brukes ved parsing:

- tid: `occurredAt`/`date`/`timestamp`
- confidence: `confidence`/`contextConfidence`/`transitionConfidence`
- blokk: `transition.to`/`to`/`symbol`/`context.label`/`context.blockId`

Dette gjoer at dagens emittere i `CellScaffold` kan brukes uten hard break.

## 9. Hva som er verifisert

Foelgende tester passerer (suitefilter):

- `swift test --filter RelationalLearningEngineTests`

Dekning:

- replay-determinisme (samme logg to ganger -> identiske vekter + scorer)
- Noa decay (monotoni + endepunkter)
- policy cutover (versjonsovergang gir forventet scoreeffekt)

## 10. Kjente grenser

- `purposeLifecycle`-events er additive og navngitt `started/succeeded/failed`; eksisterende domeneevents er ikke migrert i denne leveransen.
- `purposePurpose` er med i modell, men brukes ikke aktivt i dagens laeringsregel.
- Full produksjonsorkestrering (oppretting/wiring av cellen i appgraph) maa gjores i runtime-oppsett.
