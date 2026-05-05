# TrustedIssuerCell Proposal (W3C VC-aligned)

Date: 2026-02-16
Scope: API and scoring model for scaffold-local trusted issuers.

## Goal

Add a dedicated cell that evaluates issuer trust per context, while keeping Verifiable Credentials aligned with W3C VC Data Model.

This proposal covers:

1. Concrete `TrustedIssuerCell` keypath API and payload contracts.
2. Deterministic credibility scoring algorithm and test matrix.

## Design Principles

- Context-local trust only. No global reputation score.
- Deterministic and replayable evaluation.
- Explicit grants/capabilities for all reads/writes.
- W3C VC-compliant evidence handling: we verify VC/VP; we do not invent custom VC fields.
- Trust policy is external to VC (stored in `TrustedIssuerCell`), so VC format remains standard.

## W3C VC Interop Profile (Required)

The cell should accept and verify credentials/presentations that follow W3C VC Data Model fields.

### Verifiable Credential requirements

- `@context` includes an accepted VC context URI.
- `type` contains `"VerifiableCredential"`.
- `issuer` is URI/DID.
- `credentialSubject` exists.
- Signature proof is valid for the credential bytes/canonicalized form according to supported proof suite.
- Time checks:
  - `validFrom` and `validUntil` if present.
  - backwards-compatible handling of `issuanceDate` and `expirationDate` when encountered.
- `credentialStatus` is validated when policy requires revocation checks.

### Verifiable Presentation requirements

- `type` contains `"VerifiablePresentation"`.
- `holder` is bound to requester identity.
- Proof challenge and domain are checked (anti-replay) when challenge flow is used.
- Embedded VCs all pass credential checks above.

### Trust policy boundary

- VC remains standard JSON-LD/VC structure.
- Trust weighting, issuer tiers, endorsements, and source weighting live in `TrustedIssuerCell` policy objects, not inside VC fields.

## TrustedIssuerCell Capabilities

Suggested capabilities:

- `trustedIssuers.read`
- `trustedIssuers.write`
- `trustedIssuers.policy.manage`
- `trustedIssuers.attestation.publish`
- `trustedIssuers.evaluate`
- `trustedIssuers.audit.read`

Owner has explicit bypass, consistent with existing agreement-template behavior.

## Keypath API Contract

All command-style operations use `SET <keypath>` with payload object, same style as `ConfigurationCatalogCell`.

### Read endpoints

- `GET trustedIssuers.state`
  - Returns full state snapshot filtered by caller capability.
- `GET trustedIssuers.policies`
  - Returns context policies.
- `GET trustedIssuers.issuers`
  - Returns issuer registry and baseline metadata.
- `GET trustedIssuers.attestations`
  - Returns published attestations visible to caller.
- `GET trustedIssuers.evaluations.current`
  - Returns latest evaluation results per `(issuer, context)`.
- `GET trustedIssuers.evaluations.history`
  - Returns immutable decision snapshots for audit/replay.

### Write endpoints

- `SET trustedIssuers.policy.upsert`
- `SET trustedIssuers.policy.delete`
- `SET trustedIssuers.issuer.upsert`
- `SET trustedIssuers.issuer.delete`
- `SET trustedIssuers.attestation.publish`
- `SET trustedIssuers.attestation.revoke`
- `SET trustedIssuers.evaluate`

## Payload Contracts

The payloads below are written as JSON-like objects and map directly to `ValueType.object`.

### `SET trustedIssuers.policy.upsert`

```json
{
  "contextId": "age_over_13",
  "displayName": "Alder over 13",
  "claimSchema": {
    "credentialType": "AgeCredential",
    "subjectPath": "credentialSubject.age",
    "operator": ">=",
    "expectedValue": 13
  },
  "threshold": 0.72,
  "requireRevocationCheck": true,
  "requireSubjectBinding": true,
  "requireIndependentSources": 2,
  "maxGraphDepth": 2,
  "acceptedIssuerKinds": ["institution", "company", "person", "community"],
  "acceptedDidMethods": ["did:key", "did:web"],
  "timeDecayHalfLifeDays": 180,
  "status": "active"
}
```

### `SET trustedIssuers.issuer.upsert`

```json
{
  "issuerId": "did:web:nav.no",
  "displayName": "NAV",
  "issuerKind": "institution",
  "baseWeight": 0.85,
  "contexts": ["age_over_13", "income_proof"],
  "metadata": {
    "country": "NO",
    "orgNumber": "889640782"
  },
  "status": "active"
}
```

### `SET trustedIssuers.attestation.publish`

Attestation is not a replacement for VC. It is trust evidence about issuer credibility or purpose-fulfillment credibility in a given context.

```json
{
  "attestationId": "auto-or-client-generated-id",
  "subjectIssuerId": "did:key:z6MkSubjectIssuer",
  "contextId": "can_deliver:babysitting",
  "statement": "trusted_for_context",
  "weight": 0.35,
  "scope": "group",
  "audience": "cell:///groups/friends-bergen",
  "validFrom": "2026-02-16T18:00:00Z",
  "validUntil": "2026-08-16T18:00:00Z",
  "evidenceRef": "cell:///flow/elements/abc123",
  "issuer": "did:key:z6MkEndorser",
  "proof": {
    "type": "Ed25519Signature2020",
    "created": "2026-02-16T18:00:00Z",
    "verificationMethod": "did:key:z6MkEndorser#z6MkEndorser",
    "proofPurpose": "assertionMethod",
    "proofValue": "<signature>"
  }
}
```

### `SET trustedIssuers.evaluate`

```json
{
  "evaluationId": "auto-id",
  "issuerId": "did:key:z6MkIssuer",
  "contextId": "can_deliver:babysitting",
  "requesterId": "did:key:z6MkRequester",
  "candidateVc": { "...": "standard VC object" },
  "candidateVp": { "...": "standard VP object (optional)" },
  "options": {
    "now": "2026-02-16T18:15:00Z",
    "includeNetworkAttestations": true,
    "maxGraphDepth": 2
  }
}
```

### Evaluation response (`ValueType.object`)

```json
{
  "evaluationId": "id",
  "issuerId": "did:key:z6MkIssuer",
  "contextId": "can_deliver:babysitting",
  "score": 0.78,
  "decision": "trusted",
  "threshold": 0.72,
  "reasons": [
    "vc_signature_valid",
    "subject_binding_ok",
    "base_weight_0.55",
    "endorsement_weighted_sum_0.23"
  ],
  "components": {
    "baseWeight": 0.55,
    "endorsementContribution": 0.23,
    "freshnessFactor": 0.91,
    "diversityFactor": 1.0,
    "penalties": 0.0
  },
  "snapshotHash": "base64",
  "createdAt": "2026-02-16T18:15:00Z"
}
```

## Deterministic Scoring Algorithm (v1)

Score is per `(issuerId, contextId, evaluationTime)`.

### Inputs

- `baseWeight` from issuer registry (0.0 to 1.0).
- Valid attestations from trusted sources for same context.
- Source trust values from issuer registry for each attesting source.
- Freshness factor from attestation validity window and half-life.
- Optional penalties (revocation unknown, proof gaps, policy violations).

### Formula

Let:

- `B = clamp(baseWeight, 0, 1)`
- `Ai = attestationWeight_i` (0..1)
- `Si = sourceTrust_i` (0..1)
- `Fi = freshness_i` (0..1)
- `Ci = contextMatch_i` (0 or 1 in v1)
- `Di = diversityFactor` (0.7..1.0)
- `P = penaltySum` (0..1)

Then:

- `endorsementSum = sum(Ai * Si * Fi * Ci)`
- `normalizedEndorsement = 1 - exp(-endorsementSum)` (deterministic saturating curve)
- `rawScore = (0.6 * B) + (0.4 * normalizedEndorsement)`
- `score = clamp((rawScore * Di) - P, 0, 1)`

Decision:

- `trusted` when `score >= threshold` and all hard policy checks pass.
- `untrusted` otherwise.

### Hard policy checks (fail-fast)

Before numeric scoring, fail if any required checks fail:

- VC/VP cryptographic proof invalid.
- Subject binding required but not satisfied.
- Required VC status/revocation check unavailable or failed.
- Credential time window invalid.
- Insufficient independent sources (`requireIndependentSources`).

If fail-fast triggers, return score `0` with explicit reason list.

## Network/Graph Trust Expansion

To support "sporre andre trusted sources":

- Start from local trusted source set for context.
- Traverse attestations breadth-first up to `maxGraphDepth`.
- Apply depth discount:
  - depth 0: `1.0`
  - depth 1: `0.75`
  - depth 2: `0.55`
- Never traverse revoked/inactive sources.
- Keep deterministic ordering (sort by source ID + attestation ID before aggregation).

## Test Matrix (v1)

Use fixed timestamp in all tests for deterministic outputs.

| ID | Scenario | Input summary | Expected |
|---|---|---|---|
| T1 | Institution strong issuer (NAV) | Valid VC, baseWeight 0.85, no endorsements needed | trusted, score >= threshold |
| T2 | Bank issuer with fresh support | Valid VC, baseWeight 0.75 + 2 trusted endorsements | trusted, score higher than T1 only if endorsements strong |
| T3 | Person issuer in friend group | Valid VC, baseWeight 0.35 + 3 independent friend attestations | trusted if independent source rule satisfied |
| T4 | Person issuer with colluding duplicates | 5 attestations but same source identity | untrusted due to independent source check |
| T5 | Company issuer stale evidence | baseWeight 0.55, endorsements expired | borderline/untrusted due to freshness decay |
| T6 | Revocation status failure | Signature valid but status check required and fails | untrusted, fail-fast reason `revocation_check_failed` |
| T7 | Subject mismatch | VC subject does not match requester and binding required | untrusted, fail-fast |
| T8 | Replay VP | VP proof challenge mismatch | untrusted, fail-fast `challenge_mismatch` |
| T9 | Context mismatch | Credential type valid but wrong context policy | untrusted |
| T10 | Graph depth limit | Trust only available via depth 3 path, max depth 2 | untrusted or lower score per policy |
| T11 | Mixed institutional + person evidence | Medium baseWeight + diverse sources | trusted with explainable component weights |
| T12 | Determinism replay | Same inputs and time repeated | identical score, reasons, snapshot hash |

## Integration with Agreement/Condition Flow

For VC-based condition evaluation:

1. Validate VC/VP with W3C-compliant checks.
2. Build evaluation request to `trustedIssuers.evaluate`.
3. Condition is `met` only when:
   - claim predicate is true (e.g. `age >= 13`)
   - trust decision is `trusted`
4. Persist evaluation snapshot reference in agreement/flow audit trail.

## Minimal Implementation Sequence

1. Add `TrustedIssuerCell` with state, policy, issuer registry, attestations, evaluation store.
2. Implement fail-fast VC/VP checks and deterministic scoring function.
3. Add capability checks and audit events per operation.
4. Add unit tests for matrix T1-T12.
5. Wire `ProvedClaimCondition` to call `trustedIssuers.evaluate` for issuer trust decision.

