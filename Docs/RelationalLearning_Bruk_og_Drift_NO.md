# Relasjonslaering for Purpose/Interest/Entity (Bruk og drift)

Sist oppdatert: 2026-03-02

Dette dokumentet viser hvordan `RelationalLearningCell` brukes operativt.

## 1. Keypaths i cellen

### Set

- `purposeStarted`
- `purposeSucceeded`
- `purposeFailed`
- `contextTransition`
- `policyUpdate`
- `userPreference`
- `scorePurposes`
- `replay`

### Get

- `edges`
- `state`

## 2. Minste flyt (quickstart)

1. Send `purposeStarted`.
2. Send relevante `contextTransition` (eller la emittere pushe disse).
3. Send `purposeSucceeded` eller `purposeFailed`.
4. Les `edges` for lagret relasjonstilstand.
5. Kjor `scorePurposes` med kontekstsnapshot for anbefalinger.

## 3. Payload-eksempler

Eksemplene under er JSON-lignende objekter som mappes til `ValueType.object`.

## 3.1 `purposeStarted`

```json
{
  "eventId": "life-start-001",
  "timestamp": 1760000000.0,
  "purposeId": "purpose://networking",
  "activeInterests": ["interest://privacy"],
  "passiveInterests": ["interest://digital-rights"],
  "activeEntities": ["entity://alice"],
  "passiveEntities": [],
  "contextConfidence": 0.9
}
```

## 3.2 `purposeSucceeded`

```json
{
  "eventId": "life-success-001",
  "timestamp": 1760000300.0,
  "purposeId": "purpose://networking",
  "activeInterests": ["interest://privacy"],
  "passiveInterests": ["interest://digital-rights"],
  "activeEntities": ["entity://alice"],
  "passiveEntities": ["entity://bob"],
  "activeContextBlocks": [
    { "domain": "location", "blockId": "home", "confidence": 0.95 },
    { "domain": "time", "blockId": "evening", "confidence": 0.85 }
  ],
  "contextConfidence": 0.9
}
```

Ved suksess genereres `RelationalWeightUpdateEvent` og publiseres som `FlowElement` med topic:

- `relational.learning.weightUpdate`

## 3.3 `purposeFailed`

Samme format som `purposeSucceeded`, men sendes paa keypath `purposeFailed`.

## 3.4 `contextTransition`

```json
{
  "eventId": "ctx-location-12",
  "timestamp": 1760000100.0,
  "domain": "location",
  "fromBlockId": "work",
  "toBlockId": "home",
  "confidence": 0.92
}
```

Publiseres med topic:

- `relational.learning.contextTransition`

## 3.5 `policyUpdate` (decay cutover)

```json
{
  "eventId": "policy-noa-v2",
  "emittedAt": 1760000500.0,
  "policy": {
    "profileId": "noa",
    "version": 2,
    "effectiveFromTimestamp": 1760000500.0,
    "kind": "noaDoubleSigmoid",
    "t1Seconds": 259200.0,
    "t2Seconds": 1209600.0,
    "k1": 0.9,
    "k2": 0.5,
    "rMin": 0.05
  }
}
```

Publiseres med topic:

- `relational.learning.policyUpdated`

## 3.6 `userPreference` (direkte preferanse)

```json
{
  "eventId": "pref-001",
  "timestamp": 1760000600.0,
  "purposeId": "purpose://networking",
  "targetType": "interest",
  "targetId": "interest://privacy",
  "relationType": "purposeInterest",
  "preferenceWeight": 0.6
}
```

Publiserer:

- `relational.learning.explicitPreference`
- `relational.learning.weightUpdate`

## 3.7 `scorePurposes`

```json
{
  "timestamp": 1760000700.0,
  "explainTopN": 5,
  "activeInterests": ["interest://privacy"],
  "passiveInterests": ["interest://digital-rights"],
  "activeEntities": ["entity://alice"],
  "passiveEntities": ["entity://bob"],
  "activeContextBlocks": [
    { "domain": "location", "blockId": "home", "confidence": 0.9 },
    { "domain": "time", "blockId": "evening", "confidence": 0.8 }
  ]
}
```

Respons inneholder `scores[]` med explain-topkanter.

## 3.8 `replay`

```json
{
  "resetFirst": true,
  "events": [
    {
      "eventType": "decayPolicyUpdated",
      "schemaVersion": "1.0",
      "emittedAt": 1760000500.0,
      "payload": { "...": "..." }
    },
    {
      "eventType": "weightUpdate",
      "schemaVersion": "1.0",
      "emittedAt": 1760000600.0,
      "payload": { "...": "..." }
    }
  ]
}
```

Replay returnerer antall replayede/appliserte events.

## 4. Samspill med EventEmitter-celler i CellScaffold

Dagens emittere sender:

- location -> topic `locations`, felter som `symbol`/`position`/`date`
- time -> topic `times`, felter som `symbol`/`date`
- entities -> topic `entities`, felter som `symbol`/`date`

`RelationalLearningCell` tolker disse topicene som kontekstdomener og bygger `RelationalContextTransitionEvent` automatisk (sa langt data er tilstrekkelig til aa utlede blokk-id).

## 5. Drift og observabilitet

## 5.1 Helse/status

Kall `get state`:

- `edgeCount`
- `policyCount`
- `activeContextBlockCount`

## 5.2 Kantinspeksjon

Kall `get edges` for full sortert kantliste.

Kontroller spesielt:

- `weightStored`
- `lastReinforcedAt`
- `decayParamsVersion`
- `metadata.reason`

## 5.3 Vanlige feilkilder

- Manglende `purposeId` i lifecycle payload -> avvises.
- `contextConfidence` under `0.6` -> laering stoppes (ingen weight updates).
- Ugyldig/ukjent `relationType` i preferansepayload -> default velges fra `targetType`.

## 6. Verifisering lokalt

Kjor:

```bash
swift test --filter RelationalLearningEngineTests
```

Forventet dekning:

- replay determinisme
- Noa-decaykurve
- policy cutover

## 7. Anbefalt produksjonsrutine

1. Start med standard Noa-policy (`version=1`).
2. Samle lokal eventlogg.
3. Evaluer explain-data for toppkanter.
4. Rull ut policyjustering med ny `version` + `effectiveFromTimestamp`.
5. Verifiser med replay i test/staging foer produksjon.
