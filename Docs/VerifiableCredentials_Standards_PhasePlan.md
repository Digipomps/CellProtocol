# Verifiable Credentials Standards Phase Plan

## Purpose

This document defines the smallest credible path from HAVEN's current internal
credential model to a standards-facing interoperability layer that can talk to
external issuers, wallets, and verifiers.

The design goal is additive migration, not a rewrite.

## Current Ground Truth

HAVEN already has useful internal pieces:

- local credential objects in `VCClaim`, `VCPresentation`, and `VCProof`
- a trust and policy layer in `TrustedIssuerCell`
- partial DID support in `Identity+DID`, `DIDKeyParser`, and `DIDDocument`
- local-first storage, Cells, and resolver patterns that we should preserve

HAVEN does **not** yet have:

- a standards-correct proof envelope
- OpenID4VCI / OpenID4VP protocol support
- SD-JWT VC or mdoc support
- a production-ready DID transport and resolution layer

## Phase Structure

### Phase 0: Foundation Stabilization

Goal: stop the DID and document layer from being a blocker.

This iteration implements:

- `did:web` generation and reverse URL resolution
- real DID document generation from `Identity`
- multikey-based verification method generation for `did:key` and `did:web`
- standards-facing OpenID4VCI issuer metadata parsing
- standards-facing OpenID4VCI issuer metadata retrieval through a mockable HTTP
  transport
- standards-facing OpenID4VCI signed metadata parsing and structural validation
  for `application/jwt` responses
- standards-facing DID document validation and DID URL issuer/key binding checks
- standards-facing OpenID4VP DCQL parsing and validation
- standards-facing OpenID4VP request object parsing around `dcql_query`
- standards-facing OpenID4VP signed request object parsing using compact JWS,
  explicit `oauth-authz-req+jwt` typing, and client-id-prefix-aware policy
  validation for `redirect_uri`, `decentralized_identifier`,
  `verifier_attestation`, `x509_san_dns`, and `x509_hash`
- trust-bound verification for signed OpenID4VP requests using DID documents
  and trusted verifier-attestation issuer keys
- trust-bound verification for `x509_hash` and `x509_san_dns` signed requests
  using static trust anchors, Security-backed chain evaluation, leaf-certificate
  binding, and JWS signature verification
- standards-facing OpenID4VP request-to-candidate matching for formats, claim
  paths, trust hints, holder binding, and credential/claim set evaluation
- standards-facing OpenID4VP `vp_token` response building on top of matcher
  output
- standards-facing OpenID4VP verifier metadata parsing and validation from
  `client_metadata`, including JWK set validation and encryption capability
  selection
- verifier metadata resolution with explicit policy for `pre-registered`,
  `redirect_uri`, and `openid_federation`
- static authoritative verifier metadata providers for pre-registered and
  out-of-band trust configurations
- standards-facing OpenID4VP `direct_post` / `direct_post.jwt` transport
  modeling, including deterministic form encoding and callback parsing
- deterministic preparation of `direct_post.jwt` encryption inputs
- actual compact JWE construction for `direct_post.jwt` using `ECDH-ES` and
  `ECDH-ES+A*KW` with EC verifier JWKs and AES-GCM content encryption
- a first happy-path adapter for request -> match -> response -> encrypted
  `direct_post.jwt` submission
- standards-facing OpenID4VCI credential offer parsing, including by-value and
  by-reference offer URLs
- explicit external credential format identifiers

Files:

- `Sources/CellBase/Identity/DIDWebParser.swift`
- `Sources/CellBase/Identity/Identity+DID.swift`
- `Sources/CellBase/VerifiableCredentials/DIDDocument.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/StandardsCredentialFormat.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/JOSE/JOSEJWK.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/JOSE/JOSEBase64URL.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/JOSE/JOSECompactJWS.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/JOSE/JOSEJWSVerifier.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/JOSE/JOSECompactJWE.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VCI/OID4VCIIssuerMetadata.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VCI/OID4VCIMetadataClient.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VCI/OID4VCICredentialOffer.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/DID/DIDDocumentValidator.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPDCQL.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPRequestObject.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPSignedRequestObject.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPSignedRequestTrustVerifier.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPRequestMatcher.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPResponse.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPVerifierMetadata.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPDirectPost.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPDirectPostJWTEncryption.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPDirectPostJWTSubmissionAdapter.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPStaticVerifierMetadataProvider.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/JOSE/JOSEAESKeyWrap.swift`
- `Tests/CellBaseTests/DIDInteroperabilityTests.swift`
- `Tests/CellBaseTests/OID4VCIIssuerMetadataTests.swift`
- `Tests/CellBaseTests/OID4VCIMetadataClientTests.swift`
- `Tests/CellBaseTests/OID4VCICredentialOfferTests.swift`
- `Tests/CellBaseTests/DIDDocumentValidatorTests.swift`
- `Tests/CellBaseTests/OID4VPDCQLTests.swift`
- `Tests/CellBaseTests/OID4VPRequestObjectTests.swift`
- `Tests/CellBaseTests/OID4VPSignedRequestObjectTests.swift`
- `Tests/CellBaseTests/OID4VPSignedRequestTrustVerifierTests.swift`
- `Tests/CellBaseTests/OID4VPRequestMatcherTests.swift`
- `Tests/CellBaseTests/OID4VPResponseTests.swift`
- `Tests/CellBaseTests/OID4VPVerifierMetadataTests.swift`
- `Tests/CellBaseTests/OID4VPVerifierMetadataResolverTests.swift`
- `Tests/CellBaseTests/OID4VPDirectPostTests.swift`
- `Tests/CellBaseTests/OID4VPDirectPostJWTEncryptionTests.swift`
- `Tests/CellBaseTests/OID4VPStaticVerifierMetadataProviderTests.swift`

### Phase 1: Standards-Facing Core Types

Goal: add a new interop layer without breaking current local models.

Recommended file layout:

```text
Sources/CellBase/VerifiableCredentials/Standards/
  StandardsCredentialFormat.swift
  StandardsCredentialEnvelope.swift
  StandardsPresentationEnvelope.swift
  StandardsProofEnvelope.swift
  StandardsStatusReference.swift
  StandardsIssuerMetadata.swift
  StandardsVerifierRequest.swift
  StandardsWalletResponse.swift
  StandardsTrustBinding.swift
  Adapters/
    VCClaim+StandardsMapping.swift
    TrustedIssuerCell+StandardsPolicy.swift
```

Responsibilities:

- represent external credential formats explicitly
- separate transport metadata from trust policy
- support loss-minimized mapping from HAVEN internal objects to standards-facing
  envelopes

Recommended first enums / types:

- `StandardsCredentialFormat`
  - `w3cVcDataIntegrity`
  - `jwtVcJson`
  - `sdJwtVc`
  - `isoMdoc`
- `StandardsProofEnvelope`
  - Data Integrity proof object
  - JWT proof object
  - COSE / mdoc proof object
- `StandardsStatusReference`
  - token/status-list reference
  - refresh semantics

### Phase 2: DID and Issuer Binding

Goal: make issuer identity and key resolution standards-correct.

Recommended file layout:

```text
Sources/CellBase/VerifiableCredentials/Standards/DID/
  DIDMethodResolver.swift
  DIDWebResolver.swift
  DIDKeyResolver.swift
  DIDDocumentValidator.swift
  DIDIssuerBindingValidator.swift
```

Responsibilities:

- resolve `did:key`
- resolve `did:web`
- validate DID documents against the subset HAVEN currently emits and consumes
- validate verification method selection for assertion/authentication
- validate binding between issuer metadata and issuer identity

This phase should keep `did:cell` as an internal method, not an interop method.

### Phase 3: OpenID4VCI / OpenID4VP Protocol Layer

Goal: speak the ecosystem protocols directly.

Recommended file layout:

```text
Sources/CellBase/VerifiableCredentials/Standards/OpenID4VCI/
  OID4VCIIssuerMetadata.swift
  OID4VCICredentialOffer.swift
  OID4VCITokenRequest.swift
  OID4VCICredentialRequest.swift
  OID4VCIProofTypes.swift
  OID4VCIClient.swift

Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/
  OID4VPRequestObject.swift
  OID4VPDCQL.swift
  OID4VPClientMetadata.swift
  OID4VPResponse.swift
  OID4VPDirectPost.swift
  OID4VPVerifierClient.swift
```

Responsibilities:

- parse issuer metadata
- retrieve issuer metadata with explicit `Accept` and `Accept-Language` hints
- support unsigned JSON metadata and signed JWT metadata responses
- perform structural validation of signed metadata before trust verification
- parse credential offers
- submit token and credential requests
- parse OpenID4VP presentation requests
- build `vp_token` responses
- support `dcql_query`

### Phase 4: Credential Format Profiles

Goal: interoperate with the formats ecosystems actually use.

Recommended file layout:

```text
Sources/CellBase/VerifiableCredentials/Standards/Formats/
  W3CVCDataIntegrityProfile.swift
  SDJWTVCProfile.swift
  IsoMdocProfile.swift
  JwtVcJsonProfile.swift
```

Responsibilities:

- encode/decode format-specific envelopes
- verify proofs
- extract disclosed claims
- resolve holder binding and status information

## Why This Should Stay Inside `CellBase` For Now

Keeping the first standards-facing layer inside `CellBase` is the least risky
option.

Reasons:

- existing credential code already lives there
- the resolver, value model, and trust cells already depend on `CellBase`
- we avoid creating another top-level package before the public API is stable

If the standards layer becomes large and stable, it can later move into its own
target, for example `HavenVCStandards`.

## Migration Rules

1. Do not break `VCClaim`-based flows immediately.
2. Do not make `TrustedIssuerCell` responsible for wire protocols.
3. Do not mix raw OpenID4VC transport payloads into generic Cells unless the
   payload type is explicit.
4. Keep external formats explicit rather than “best effort” inferred.
5. Treat `did:cell` as internal and `did:key` / `did:web` as interop-facing.

## First Practical Build Order

1. Stabilize DID generation and document generation.
2. Add standards-facing format and proof enums.
3. Add the first request-to-match flow on top of OpenID4VP request objects.
4. Add the first `vp_token` response model on top of the matcher output.
5. Add the first credential offer parser for OpenID4VCI.
6. Add issuer metadata retrieval and signed metadata structural validation.
7. Add DID document validation and DID URL issuer/key binding checks.
8. Add one end-to-end happy path:
   - parse issuer metadata
   - parse credential offer
   - validate issuer DID document / key binding
   - parse verifier DCQL request
   - parse OpenID4VP request object
   - match one credential
   - answer one `vp_token` request

## External Standards This Plan Targets

- W3C Verifiable Credentials Data Model v2.0
- W3C Verifiable Credential Data Integrity 1.0
- OpenID for Verifiable Credential Issuance 1.0
- OpenID for Verifiable Presentations 1.0
- OpenID4VC High Assurance Interoperability Profile 1.0
- EUDI Wallet Architecture and Reference Framework

References:

- [W3C VC Data Model 2.0](https://www.w3.org/TR/vc-data-model-2.0/)
- [W3C VC Data Integrity 1.0](https://www.w3.org/TR/vc-data-integrity/)
- [OpenID4VCI 1.0 Final](https://openid.net/specs/openid-4-verifiable-credential-issuance-1_0-final.html)
- [OpenID4VP 1.0](https://openid.net/specs/openid-4-verifiable-presentations-1_0.html)
- [OpenID4VC HAIP 1.0 Final](https://openid.net/specs/openid4vc-high-assurance-interoperability-profile-1_0-final.html)
- [EUDI ARF](https://eudi.dev/latest/architecture-and-reference-framework-main)
