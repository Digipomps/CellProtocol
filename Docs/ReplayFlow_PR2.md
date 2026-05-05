# Replay and Provenance: PR2 Signing and Verification

This document captures PR2, where we add cryptographic support for envelope-level and origin-level verification.

## Scope

PR2 adds:

- `FlowEnvelopeSigner` for producing signed envelopes.
- `FlowEnvelopeVerifier` for payload/signature/provenance verification.
- `FlowIntegrityError` for explicit integrity failures.
- tests for valid signatures, tampering, and identity mismatch.

PR2 still does **not** include resolver enforcement or replay ledger integration.

## Concepts

### Producer signature

The producer signs canonical envelope-core bytes, excluding the producer signature field itself and excluding the provenance proof block. Provenance is verified with its own origin signature so provenance tampering reports provenance-specific integrity errors instead of being masked as a producer-signature failure.

Verification checks:

1. payload hash matches canonical payload bytes
2. producer signature exists
3. producer signature validates against canonical envelope-core bytes

### Provenance signature

Origin proof is signed separately using canonical origin material:

- `originCell`
- `originIdentity`
- `payloadHash`

This protects source attribution independently from transport and later revision metadata.

### Error model

`FlowIntegrityError` exposes machine-readable failure reasons, including:

- payload hash mismatch
- missing/invalid producer signature
- missing/invalid provenance signature
- identity mismatch in provenance binding

## Process Used

1. Added integrity error enum and shared signature-material utility.
2. Implemented envelope signing with optional provenance auto-population.
3. Implemented envelope verifier with strict payload hash check before signature checks.
4. Added crypto tests for:
- successful sign+verify
- payload tampering rejection
- wrong signer rejection
- provenance tampering rejection

## Files Added

- `Sources/CellBase/Flow/FlowIntegrityError.swift`
- `Sources/CellBase/Flow/FlowSignatureMaterial.swift`
- `Sources/CellBase/Flow/FlowEnvelopeSigner.swift`
- `Sources/CellBase/Flow/FlowEnvelopeVerifier.swift`
- `Tests/CellBaseTests/FlowEnvelopeCryptoTests.swift`

## Notes

- Signing uses existing `Identity.sign(data:)` and `Identity.verify(signature:for:)` plumbing.
- Canonical encoding from PR1 is reused to ensure deterministic signing bytes.
- Resolver/Bridge enforcement and append-only replay storage are reserved for later PRs.
