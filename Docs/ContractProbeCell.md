# ContractProbeCell

Status: implemented

## Purpose

`ContractProbeCell` is a runtime cell for probing another cell through ordinary
`CellProtocol` APIs:

- `keys(requester:)`
- `typeForKey(key:requester:)`
- `get(keypath:requester:)`
- `set(keypath:value:requester:)`
- `flow(requester:)`

It is meant for:

- staging verification
- runtime diagnostics
- agent-driven verification
- post-deploy checks where `XCTest` is not available

It is not a replacement for deterministic unit/integration tests.

## Prerequisites

`ContractProbeCell` depends on normal runtime plumbing:

- `CellBase.defaultCellResolver` must be configured
- the probe caller must have access to the target cell
- the probe cell owner or caller must have `probe` read/write access

If the resolver is missing, `probe.run` returns a structured error payload.

## Important interface note

`GeneralCell` currently stores one `Explore` contract object per key.
That means one key cannot cleanly expose both a `get` and a `set` contract at
the same time.

Because of that, the implemented API uses:

- setter keys for commands
- separate `.current` getter keys for readback

This is intentional and matches the current limits of `typeForKey(...)`.

## Implemented runtime API

Set operations:

- `probe.target`
- `probe.contract`
- `probe.run`

Get operations:

- `probe.status`
- `probe.target.current`
- `probe.contract.current`
- `probe.lastReport`
- `probe.reports`

The setter keys are commands. The `.current` keys are read models.

## Target configuration

`probe.target` accepts:

1. A string endpoint:

```json
"cell:///Vault"
```

2. An explicit target object:

```json
{
  "endpoint": "cell:///Vault",
  "label": "vault"
}
```

3. A `CellConfiguration` payload.

If a `CellConfiguration` is used, the first `cellReferences` entry becomes the
probe target.

Successful response shape:

```json
{
  "status": "ok",
  "message": "Configured contract probe target",
  "target": {
    "endpoint": "cell:///Vault",
    "label": "vault"
  }
}
```

## Expected contract configuration

`probe.contract` accepts:

1. `null`
   - clears configured expected contracts
2. One contract object
3. A list of contract objects
4. An object with `items: [...]`

Each configured contract must include a non-empty `key`.

If no expected contracts are configured, `probe.run` uses the target cell's own
declared `Explore` contracts as the baseline and verifies runtime behavior
against them.

If expected contracts are configured, `probe.run` also verifies:

- expected keys missing from target
- target keys missing from expected bundle
- equality between expected and declared contract objects

Successful response shape:

```json
{
  "status": "ok",
  "message": "Configured expected contracts",
  "count": 2,
  "items": [
    { "key": "state", "method": "get" },
    { "key": "publish", "method": "set" }
  ]
}
```

## Run options

`probe.run` accepts `null`, `{}`, or an object with:

- `keys: [String]?`
  - limit the run to selected keys
- `sampleInputs: { [String]: ValueType }`
  - explicit payloads for `set` keys
- `includeBehaviorChecks: Bool`
  - call `get`/`set` and validate runtime outputs against declared return schema
- `includePermissionChecks: Bool`
  - probe access denial using a fresh unsigned identity
- `includeInvalidInputChecks: Bool`
  - generate an invalid payload candidate from the declared input schema
- `includeFlowChecks: Bool`
  - observe declared `flowEffects`
- `timeoutSeconds: Int`
  - max wait per flow observation window

Defaults:

- behavior checks: enabled
- permission checks: enabled
- invalid input checks: enabled
- flow checks: enabled
- timeout: `1`

Minimal valid run command:

```json
{}
```

## Sample input behavior

For `set` keys, the probe uses:

1. `sampleInputs[key]` if provided
2. otherwise a generated sample derived from the declared input schema

Schema-derived samples work for common declared shapes:

- `string`
- `bool`
- `integer`
- `float`
- `list`
- `object` with `properties` / `requiredKeys`
- `oneOf`

If no sample can be derived, the valid set-call check is marked as `skipped`.

## What a probe run validates

For each selected key, the probe can verify:

1. Declared contract shape
2. Declared contract equality against configured expected contracts
3. `get` output matches declared return schema
4. `set` output matches declared return schema
5. unsigned identity is denied when permissions are declared
6. derived invalid input is rejected
7. declared `flowEffects` actually appear on `flow(...)`

Common assertion phases:

- `contract.shape`
- `contract.expectedEquality`
- `contract.expectedCoverage`
- `behavior.get`
- `behavior.set`
- `permissions.get`
- `permissions.set`
- `behavior.invalidInput`
- `flow.<topic>`
- `probe.execution`
- `probe.targetResolution`

## Flow topics

`probe.run` emits:

- `contract.run.started`
- `contract.assertion.passed`
- `contract.assertion.failed`
- `contract.flow.observed`
- `contract.run.finished`

These events make it usable from admin tooling, staging monitors, and agent
workflows without scraping logs.

## Report model

`probe.run` returns a `ContractProbeReport`.

Important fields:

- `id`
- `targetCell`
- `startedAt`
- `finishedAt`
- `status`
  - `running`, `completed`, or `failed`
- `usedExpectedContracts`
- `options`
- `passedCount`
- `failedCount`
- `skippedCount`
- `assertions`
- `errorMessage`

Each assertion contains:

- `key`
- `phase`
- `status`
  - `passed`, `failed`, `skipped`
- `message`
- `expected`
- `observed`

Typical success response:

```json
{
  "id": "9D4D5E0E-9A5C-4EC6-A2F1-8A9D7EEA715B",
  "targetCell": "cell:///ProbeTarget",
  "startedAt": "2026-03-08T18:22:10Z",
  "finishedAt": "2026-03-08T18:22:10Z",
  "status": "completed",
  "usedExpectedContracts": false,
  "options": {
    "includeBehaviorChecks": true,
    "includePermissionChecks": true,
    "includeInvalidInputChecks": true,
    "includeFlowChecks": true,
    "timeoutSeconds": 1,
    "sampleInputs": {
      "publish": {
        "message": "Hello from probe"
      }
    }
  },
  "passedCount": 7,
  "failedCount": 0,
  "skippedCount": 0,
  "assertions": []
}
```

## Report history

The cell stores:

- the latest report at `probe.lastReport`
- recent report history at `probe.reports`

History is currently capped at 20 reports per probe cell instance.

## Verification record export

The first docs/RAG integration step is now implemented as
`ContractProbeVerificationRecord`.

Use it to combine:

- `exploreContractCatalog(requester:)`
- one `ContractProbeReport`

into one export artifact with:

- declared keys
- latest verification status
- failing assertions
- freshness metadata
- Markdown ready for indexing

Convenience API:

```swift
let verification = try await cell.exploreContractVerificationRecord(
    requester: owner,
    probeReport: report,
    targetEndpoint: "cell:///Vault",
    targetLabel: "vault"
)
```

This is intended as the canonical bridge from runtime probe output into
documentation and RAG indexing.

Chunk-level retrieval API:

```swift
let chunks = try await cell.exploreContractVerificationChunks(
    requester: owner,
    probeReport: report,
    targetEndpoint: "cell:///Vault",
    targetLabel: "vault"
)
```

The current chunk kinds are:

- `summary`
- `key_contract`
- `failed_assertion`
- `flow_assertion_group`

The current downstream ingest route for these artifacts is:

- `POST /v1/cell/cases/{case_id}/contract-verification`

## Practical example

Configure target:

```json
"cell:///CommonsResolver"
```

Run with sample input:

```json
{
  "sampleInputs": {
    "commons.resolve.keypath": {
      "entity_id": "entity-1",
      "path": "#/purposes",
      "context": {
        "role": "owner",
        "consent_tokens": []
      }
    }
  }
}
```

Typical sequence:

1. `set("probe.target", ...)`
2. optionally `set("probe.contract", ...)`
3. `set("probe.run", ...)`
4. `get("probe.lastReport")`
5. subscribe to `flow(...)` for incremental runtime feedback

## Readback keys

`probe.status` returns a compact operational summary:

```json
{
  "status": "ok",
  "probe_state": "completed",
  "target_configured": true,
  "target_endpoint": "cell:///Vault",
  "expected_contract_count": 2,
  "report_count": 1,
  "has_last_report": true
}
```

`probe.target.current` returns the configured target:

```json
{
  "status": "ok",
  "configured": true,
  "target": {
    "endpoint": "cell:///Vault",
    "label": "vault"
  }
}
```

`probe.contract.current` returns stored expected contracts:

```json
{
  "status": "ok",
  "count": 2,
  "items": [
    { "key": "state", "method": "get" },
    { "key": "publish", "method": "set" }
  ]
}
```

## Current limitations

1. `Explore` currently exposes one contract per key, which is why `.current`
   readback keys exist.
2. Permission checks assume a fresh identity with no grants or agreements.
3. Invalid-input checks are heuristic and depend on schema quality.
4. If a cell declares `unknown` input/output types, probe coverage becomes more
   limited.
5. The probe is runtime-oriented; use `XCTest` as the primary correctness gate.

## Recommended usage split

Use `ContractProbeCell` when:

- the target only exists in a running environment
- you need post-deploy verification
- an agent or admin UI needs structured probe output
- you want flow events instead of log scraping

Use `XCTest` when:

- correctness must be deterministic
- you need stable CI gates
- the target can be exercised locally in package tests
- failures should block merges or releases

## Tests

Reference tests:

- `Tests/CellBaseTests/ContractProbeCellTests.swift`
- `Tests/CellBaseTests/RealCellContractTests.swift`

## Next step

For the next concrete step to connect probe output into docs/RAG, see:

- `Docs/ContractProbeCell_RAG_Followup.md`
