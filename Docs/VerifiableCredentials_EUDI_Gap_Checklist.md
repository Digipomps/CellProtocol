# HAVEN VC / EUDI Gap Checklist

## Purpose

This checklist maps current HAVEN files to the main standards requirements for
W3C VC 2.0, OpenID4VCI, OpenID4VP, HAIP, and EUDI wallet interoperability.

Status labels:

- `good foundation`: useful building block already exists
- `partial`: some code exists, but is not yet interoperable
- `missing`: no usable implementation for interop yet

## Core Credential Model

| Area | Current files | Status | Gap | Next action |
|---|---|---|---|---|
| W3C VC object model | `Sources/CellBase/VerifiableCredentials/VCClaim.swift` | partial | still uses legacy-style fields and internal ids | add explicit standards-facing credential envelope |
| Verifiable Presentation model | `Sources/CellBase/VerifiableCredentials/VCPresentation.swift` | partial | local model exists, but no OpenID4VP-compliant request/response layer | add standards-facing VP request/response models |
| Proof representation | `Sources/CellBase/VerifiableCredentials/VCProof.swift` | partial | proof shape is HAVEN-specific, not Data Integrity / JWT / COSE profile-based | introduce proof envelope abstraction |
| Trust and policy | `Sources/CellBase/VerifiableCredentials/TrustedIssuerCell.swift` | good foundation | useful policy engine, but not a wire protocol implementation | keep as policy layer and adapt to standards inputs |

## DID and Key Material

| Area | Current files | Status | Gap | Next action |
|---|---|---|---|---|
| `did:key` generation | `Sources/CellBase/Identity/Identity+DID.swift`, `Sources/CellBase/Identity/DIDKeyParser.swift` | good foundation | now usable, but still not backed by a broader DID resolution layer | keep and extend with resolver/validator |
| `did:web` generation | `Sources/CellBase/Identity/DIDWebParser.swift`, `Sources/CellBase/Identity/Identity+DID.swift` | good foundation | generation and URL resolution exist, but remote retrieval/validation do not | add DID web resolver |
| DID document generation | `Sources/CellBase/VerifiableCredentials/DIDDocument.swift`, `Sources/CellBase/VerifiableCredentials/Standards/DID/DIDDocumentValidator.swift` | good foundation | local document generation, validation, and basic issuer/key binding checks now exist, but remote resolution and richer verification-method semantics are still thin | add DID resolver + richer validation |
| DID signing and verification | `Sources/CellBase/VerifiableCredentials/DIDIdentityVault.swift` | partial | signing path is incomplete and secp256k1 handling needs standards-safe validation | finish signing and curve handling |
| DID utility surface | `Sources/CellBase/Identity/DIDUtilityCell.swift` | missing | cell shell only | do not expose until the standards layer exists |

## OpenID4VCI

| Area | Current files | Status | Gap | Next action |
|---|---|---|---|---|
| Issuer metadata | `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VCI/OID4VCIIssuerMetadata.swift`, `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VCI/OID4VCIMetadataClient.swift` | good foundation | parsing, metadata URL derivation, retrieval, and structural signed-metadata validation exist, but cryptographic trust verification is still missing | add trust-bound signed metadata verification |
| Credential offer | `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VCI/OID4VCICredentialOffer.swift` | good foundation | by-value and by-reference parsing exist, but there is still no retrieval client or issuance flow execution | add OID4VCI client |
| Authorization code / pre-authorized code flow | none | missing | no issuance flow client | add OID4VCI client |
| Proof types | none | missing | no `jwt`, `di_vp`, or attestation proof-type handling for OID4VCI | add proof-type models |
| Wallet attestation / key attestation | none | missing | required for HAIP-aligned high-assurance ecosystems | add after basic issuance |

## OpenID4VP

| Area | Current files | Status | Gap | Next action |
|---|---|---|---|---|
| Request object parsing | `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPRequestObject.swift`, `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPSignedRequestObject.swift`, `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPSignedRequestTrustVerifier.swift`, `Sources/CellBase/VerifiableCredentials/Standards/JOSE/JOSECompactJWS.swift`, `Sources/CellBase/VerifiableCredentials/Standards/JOSE/JOSEJWSVerifier.swift` | strong foundation | unsigned and signed request parsing exist, and trust-bound verification now works for DID-based, verifier-attestation-based, `x509_hash`, and `x509_san_dns` requests, but federation-bound trust and encrypted request objects are still missing | add federation trust rails and encrypted request support only for concrete interop profiles |
| `dcql_query` support | `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPDCQL.swift`, `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPRequestObject.swift`, `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPSignedRequestObject.swift`, `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPRequestMatcher.swift` | strong foundation | parser, signed/unsigned request-object wrappers, and first runtime matcher exist, but signed-request signature validation and request-object decryption are still missing | add trust-bound signature verification and encrypted request support if needed |
| `vp_token` response | `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPResponse.swift` | good foundation | response building exists on top of matcher output, but there is still no signed response construction | add JWS/JARM-style response support if needed |
| Direct post / cross-device flow | `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPDirectPost.swift`, `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPDirectPostJWTEncryption.swift`, `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPDirectPostJWTSubmissionAdapter.swift` | strong foundation | transport-neutral direct-post submission and callback modeling now exist, compact JWE construction exists for `direct_post.jwt`, and there is a first happy-path adapter from request to encrypted submission, but there is still no verifier transport client/server glue | add protocol transport glue |
| Verifier metadata and encryption | `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPVerifierMetadata.swift`, `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPStaticVerifierMetadataProvider.swift`, `Sources/CellBase/VerifiableCredentials/Standards/JOSE/JOSEJWK.swift`, `Sources/CellBase/VerifiableCredentials/Standards/JOSE/JOSECompactJWE.swift`, `Sources/CellBase/VerifiableCredentials/Standards/JOSE/JOSEAESKeyWrap.swift` | strong foundation | typed verifier metadata parsing, client-id-prefix-aware metadata resolution, static authoritative provider support, JWK validation, response planning, and compact JWE construction now exist for `ECDH-ES` and `ECDH-ES+A*KW` with AES-GCM content encryption, but there is still no remote authoritative retrieval and no non-GCM content encryption | add remote authoritative retrieval only for a concrete trust profile |

## Credential Formats

| Area | Current files | Status | Gap | Next action |
|---|---|---|---|---|
| W3C VC Data Integrity | none | missing | no DI proof verification path | add profile module |
| JWT VC JSON | none | missing | no explicit JWT VC support | add profile module |
| SD-JWT VC | none | missing | no SD-JWT issuance, storage, or presentation logic | add profile module |
| ISO mdoc | none | missing | no mdoc handling | add profile module |
| Status / revocation | `Sources/CellBase/Agreement/Condition/Implementation/ProvedClaimCondition.swift` | partial | only legacy-style status assumptions visible | add explicit status-list / token-status support |

## eIDAS 2.0 / EUDI-Specific Requirements

| Requirement | Current files | Status | Gap | Next action |
|---|---|---|---|---|
| Remote presentation via OpenID4VP | none | missing | EUDI relies on OpenID4VP for remote presentation | implement OID4VP |
| Issuance via OpenID4VCI | none | missing | EUDI wallet issuance uses OpenID4VCI | implement OID4VCI |
| SD-JWT VC support | none | missing | EUDI uses SD-JWT VC for remote attestation flows | add SD-JWT VC profile |
| mdoc support | none | missing | EUDI uses ISO mdoc in key issuance/presentation flows | add mdoc profile |
| Selective disclosure | none | missing | required by the EU implementing rules | add format-aware disclosure handling |
| Proof of possession / holder binding | `Sources/CellBase/VerifiableCredentials/VCProof.swift` | partial | local signatures exist, but not protocol/profile-compliant holder binding | add standards proof handling |
| Wallet / relying-party attestation handling | none | missing | EUDI and HAIP ecosystems rely on stronger attestation and trust rails | add after base protocol support |
| Trust/policy scoring | `Sources/CellBase/VerifiableCredentials/TrustedIssuerCell.swift` | good foundation | policy exists, but must be fed by standards-compliant inputs | adapt with external issuer metadata and attestation inputs |

## Integration Targets Beyond EUDI

The same standards family is already used in private and open ecosystems, so
this work is not only for public-sector interoperability.

Examples:

- OpenID Foundation interop participants such as Bundesdruckerei, MATTR, Meeco,
  MyMahi, Fikua, and Open Wallet Foundation test infrastructure
- OpenWallet Foundation projects such as ACA-Py, OID4VC TypeScript,
  Multiformat VC for iOS, and SD-JWT implementations

This means a standards-facing HAVEN module could eventually integrate with:

- government issuers and verifiers
- private wallet and verifier stacks
- reference/open-source toolkits used for conformance and pilots

## What Was Implemented In This Iteration

- `did:web` generation and resolution:
  - `Sources/CellBase/Identity/DIDWebParser.swift`
- `Identity.did(..., type: .web)`:
  - `Sources/CellBase/Identity/Identity+DID.swift`
- actual DID document generation from `Identity`:
  - `Sources/CellBase/VerifiableCredentials/DIDDocument.swift`
- DID document validation and DID URL issuer/key binding:
  - `Sources/CellBase/VerifiableCredentials/Standards/DID/DIDDocumentValidator.swift`
- standards-facing credential format identifiers:
  - `Sources/CellBase/VerifiableCredentials/Standards/StandardsCredentialFormat.swift`
- OpenID4VCI issuer metadata parsing and metadata URL derivation:
  - `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VCI/OID4VCIIssuerMetadata.swift`
- OpenID4VCI issuer metadata retrieval and signed metadata parsing:
  - `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VCI/OID4VCIMetadataClient.swift`
- OpenID4VCI credential offer parsing:
  - `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VCI/OID4VCICredentialOffer.swift`
- OpenID4VP DCQL parsing and validation:
  - `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPDCQL.swift`
- OpenID4VP request object parsing and validation:
  - `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPRequestObject.swift`
- OpenID4VP signed request object parsing and prefix-aware structural validation:
  - `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPSignedRequestObject.swift`
- JOSE compact JWS support for signed request envelopes:
  - `Sources/CellBase/VerifiableCredentials/Standards/JOSE/JOSECompactJWS.swift`
- JOSE JWS verification for `EdDSA` and `ES256`/`ES384`/`ES512`:
  - `Sources/CellBase/VerifiableCredentials/Standards/JOSE/JOSEJWSVerifier.swift`
- OpenID4VP trust-bound signed request verification for DID, verifier attestation, `x509_hash`, and `x509_san_dns`:
  - `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPSignedRequestTrustVerifier.swift`
- OpenID4VP request-to-candidate matching:
  - `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPRequestMatcher.swift`
- OpenID4VP `vp_token` response building:
  - `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPResponse.swift`
- OpenID4VP verifier metadata parsing and `direct_post.jwt` preparation:
  - `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPVerifierMetadata.swift`
- OpenID4VP verifier metadata resolution with client-id-prefix policy:
  - `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPVerifierMetadata.swift`
- OpenID4VP static authoritative verifier metadata providers:
  - `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPStaticVerifierMetadataProvider.swift`
- JOSE JWK/JWKS model used by standards-facing response planning:
  - `Sources/CellBase/VerifiableCredentials/Standards/JOSE/JOSEJWK.swift`
- JOSE base64url and compact JWE support:
  - `Sources/CellBase/VerifiableCredentials/Standards/JOSE/JOSEBase64URL.swift`
  - `Sources/CellBase/VerifiableCredentials/Standards/JOSE/JOSECompactJWE.swift`
- OpenID4VP `direct_post` / `direct_post.jwt` transport modeling:
  - `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPDirectPost.swift`
- OpenID4VP `direct_post.jwt` compact JWE encryption:
  - `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPDirectPostJWTEncryption.swift`
- OpenID4VP `direct_post.jwt` happy-path submission adapter:
  - `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPDirectPostJWTSubmissionAdapter.swift`
- JOSE AES Key Wrap for `ECDH-ES+A*KW`:
  - `Sources/CellBase/VerifiableCredentials/Standards/JOSE/JOSEAESKeyWrap.swift`
- regression and interoperability tests:
  - `Tests/CellBaseTests/DIDInteroperabilityTests.swift`
  - `Tests/CellBaseTests/DIDDocumentValidatorTests.swift`
  - `Tests/CellBaseTests/OID4VCIIssuerMetadataTests.swift`
  - `Tests/CellBaseTests/OID4VCIMetadataClientTests.swift`
  - `Tests/CellBaseTests/OID4VCICredentialOfferTests.swift`
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
  - `Tests/CellBaseTests/OID4VPDirectPostJWTSubmissionAdapterTests.swift`
  - `Tests/CellBaseTests/OID4VPStaticVerifierMetadataProviderTests.swift`
  - `Tests/CellBaseTests/JOSEAESKeyWrapTests.swift`

## Recommended Immediate Next Steps

1. Add cryptographic trust verification for signed issuer metadata.
2. Add DID resolver support and richer verification-method semantics.
3. Add verifier metadata retrieval from federation, DID, or verifier
   attestation.
4. Add federation-bound trust verification only where a concrete
   interoperability profile requires it.
5. Add encrypted request-object support only if a target profile actually uses it.
6. Keep `TrustedIssuerCell` as policy and trust, not transport.

## References

- [W3C VC Data Model 2.0](https://www.w3.org/TR/vc-data-model-2.0/)
- [W3C VC Data Integrity 1.0](https://www.w3.org/TR/vc-data-integrity/)
- [OpenID4VCI 1.0 Final](https://openid.net/specs/openid-4-verifiable-credential-issuance-1_0-final.html)
- [OpenID4VP 1.0](https://openid.net/specs/openid-4-verifiable-presentations-1_0.html)
- [OpenID4VC HAIP 1.0 Final](https://openid.net/specs/openid4vc-high-assurance-interoperability-profile-1_0-final.html)
- [EUDI ARF](https://eudi.dev/latest/architecture-and-reference-framework-main)
- [EU Implementing Regulation 2024/2982](https://eur-lex.europa.eu/legal-content/en/TXT/?qid=1743877664120&uri=CELEX%3A32024R2982)
- [OIDF OpenID4VCI interoperability results](https://openid.net/oidf-demonstrates-interoperability-of-new-digital-identity-issuance-standards/)
- [OWF ACA-Py](https://tac.openwallet.foundation/projects/aca-py/)
- [OWF OID4VC TypeScript](https://tac.openwallet.foundation/projects/oid4vc-ts/)
