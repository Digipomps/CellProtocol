
# HAVEN — Humanely Attuned Virtual Ecosystem Nexus

HAVEN is a deterministic, privacy-first ecosystem for user-owned distributed
applications. It provides a minimal and explicit protocol for computation,
identity, authorization, trust, and event flows. All components are designed
to be transparent, replayable, and transport-independent.

Documentation is maintained in the companion repository `CellProtocolDocuments`
(intended as a submodule). The book chapters listed below live under
`CellProtocolDocuments/Book`.

---

## 🌐 Project Goals

- Provide a stable, minimal, deterministic execution model (**CellProtocol**)
- Use domain-scoped identity with no global accounts
- Support explicit capability-based contracts for all permissions
- Work offline, peer-to-peer, or via intermittent networks
- Enable human-aligned trust via Purpose and Goals
- Be fully open-source under permissive licensing
- Support long-term autonomy and digital self-determination

---

## 📚 Documentation Table of Contents (TOC)

```
HAVEN Documentation (CellProtocolDocuments/Book)
===================

1. Core Protocol
   - 01_CellProtocol_Core.md
   - 02_Cell_Interfaces.md

2. Identity & Authorization
   - 03_Identity_Model.md
   - 04_Agreements_Contracts.md

3. Event Model & Execution
   - 05_Flows_Lifecycle.md
   - 06_CellResolver.md
   - 07_Scaffold_Runtime.md

4. Connectivity & Semantics
   - 08_Bridging_Transport.md

5. Semantics, Trust & Human Alignment
   - 09_Purpose_Interests.md

6. Developer Guides
   - 10_Quickstart.md
   - 11_Developer_Guide_Cell.md
   - 12_Skeleton_Spec.md
   - 13_Agent_Instructions.md
   - 14_Perspective_Runtime_Matching.md
   - 15_Documentation_Discovery_and_RAG.md

7. Supplementary Material
   - Book_Extras.md

```

---

## 🏗 Core Concepts

**CellProtocol** — deterministic state + event model  
**Identity Model** — domain-scoped cryptographic identity  
**Contracts** — explicit, auditable capability authorizations  
**Flows** — ordered, replayable event streams  
**Resolver** — enforces correctness, identity, and capabilities  
**Scaffold** — runtime for Cells, storage, vault, transport  
**Bridges** — transport-agnostic envelope carriers  
**Purpose Framework** — semantic trust and intent alignment  

---

## 🔐 Privacy & Security Principles

- No global identifiers  
- No cross-domain tracking  
- No behavioural profiling  
- No reputation or scoring  
- Fully explicit permissions  
- Evidence-based trust (optional)  
- Replayable and auditable behaviour  
- Cryptographic material is generated from OS CSPRNG sources
  (`SecRandomCopyBytes` on Apple, `/dev/urandom` on Linux)

HAVEN is designed to empower civil society, communities, and individual users
with safe digital autonomy.

---

## 📦 License

HAVEN source code in this repository is licensed under the Apache License,
Version 2.0. See [LICENSE](./LICENSE).

HAVEN is stewarded as a digital commons by Stiftelsen Digipomps. The Apache
License 2.0 grants broad rights to use, study, modify, fork, and distribute the
code. It does not grant rights to the HAVEN name, logos, certification marks,
official release channels, hosted services, or foundation-operated
infrastructure.

The official HAVEN release process is described in [GOVERNANCE.md](./GOVERNANCE.md).
Use of HAVEN names, logos, and certification marks is governed by
[TRADEMARK.md](./TRADEMARK.md).

DiMy code, if present, is licensed separately and is not covered by the HAVEN
Apache-2.0 license unless explicitly stated in the relevant file headers and
DiMy license files.

Third-party notices are listed in [NOTICE](./NOTICE) and
[THIRD-PARTY-NOTICES.md](./THIRD-PARTY-NOTICES.md).

---

## 📬 Project Stewardship

HAVEN is stewarded by **Stiftelsen Digipomps** (Norway), with a goal of
long-term open development of the HAVEN ecosystem.

---

## 🤝 Contributing

Feedback, research collaboration, and community participation are welcome.  
The project follows a transparent and open contribution model.

---

## 🧭 Getting Started

Documentation files in `CellProtocolDocuments/Book` provide:

- a complete specification of CellProtocol  
- identity and contract models  
- architectural guidelines  
- developer concepts and patterns  
- trust and purpose semantics  
- runtime and transport behaviour  

Start with:

1. **01_CellProtocol_Core.md**  
2. **03_Identity_Model.md**  
3. **06_CellResolver.md**  

## 🤖 Agent Entrypoint

If you are implementing code or UI:

1. **10_Quickstart.md**  
2. **11_Developer_Guide_Cell.md**  
3. **12_Skeleton_Spec.md**  
4. **13_Agent_Instructions.md**
5. **14_Perspective_Runtime_Matching.md**
6. **15_Documentation_Discovery_and_RAG.md**

## 🧩 HAVEN Commons Registry

Taxonomy + KeyPath Commons monorepo ligger i:

- `commons`

Start med:

- `commons/README.md`
- `commons/docs/ARCHITECTURE.md`
- `commons/docs/CELLS.md`

## ✅ Running Skeleton Tests

Skeleton encoding/decoding tests live in `CellBaseTests`:

- Open the workspace you use for app development (for example `Binding.xcworkspace`).
- Ensure the workspace includes the local `CellProtocol` package folder.
- Select the `CellBaseTests` test target in the test plan.
- Run the `SkeletonTests` test suite.

If `CellBaseTests` shows as “missing”, verify these two entries match your local layout:

- `../Binding/Binding.xcworkspace/contents.xcworkspacedata` includes `group:../CellProtocol`
- `../Binding/Binding.xcodeproj/xcshareddata/xctestplans/Binding.xctestplan` uses `container:../CellProtocol`

## ✅ Running Purpose/Interest/Entity Matching Tests

Weighted relationship matching tests for `Purpose`, `Interest`, and
`EntityRepresentation` live in:

- `Tests/CellBaseTests/PurposeAndInterestMatchingTests.swift`

They verify relationship matching for:

- `types`
- `subTypes`
- `parts`
- `partOf`
- `states`

Run only this suite with:

- `swift test --filter PurposeAndInterestMatchingTests`

## 🧪 Contract Testing

For the current contract-testing architecture, runtime probe design, and
purpose/goal linting, see:

- `Docs/Cell_Contract_Testing_Architecture.md`
- `Docs/ContractProbeCell.md`
- `Docs/Observability_and_Runtime_Diagnostics.md`

Implemented primitives in code:

- `ExploreContract.oneOfSchema(...)` for keys that accept multiple payload shapes
- explicit `registerExploreContract(...)` coverage for:
  - `CommonsResolverCell`
  - `CommonsTaxonomyCell`
  - `VaultCell`
  - `GraphIndexCell`
- `ContractProbeCell` for runtime/staging probing of target cells through normal
  `CellProtocol` APIs
- `ContractProbeVerificationRecord` to combine declared contract catalog and
  latest probe result into one JSON/Markdown artifact for docs and RAG
- `cell.exploreContractVerificationChunks(...)` to emit summary, key-contract,
  failed-assertion, and flow-group chunks for RAG retrieval
- `cell.exploreContractCatalog(requester:)` to export structured JSON + Markdown
  records for documentation and RAG indexing
- `Tests/CellBaseTests/RealCellContractTests.swift` for contract, permission, and
  invalid-input checks on real cells
- `Tests/CellBaseTests/ContractProbeCellTests.swift` for runtime probe execution,
  report storage, and flow event checks

Use `ContractProbeCell` when a target must be probed through the runtime
surface in staging or post-deploy environments. Use `XCTest` for deterministic
local and CI verification.

## 🪪 VC Interoperability Work

Current planning and gap documents for standards-facing Verifiable Credentials
interoperability live in:

- `Docs/VerifiableCredentials_Standards_PhasePlan.md`
- `Docs/VerifiableCredentials_EUDI_Gap_Checklist.md`

The first implemented interoperability step in code is DID-focused:

- `Sources/CellBase/Identity/DIDWebParser.swift`
- `Sources/CellBase/Identity/Identity+DID.swift`
- `Sources/CellBase/VerifiableCredentials/DIDDocument.swift`
- `Tests/CellBaseTests/DIDInteroperabilityTests.swift`

The current OpenID4VC interoperability foundation in code also includes:

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
- `Tests/CellBaseTests/OID4VPSignedRequestObjectTests.swift`
- `Tests/CellBaseTests/OID4VPSignedRequestTrustVerifierTests.swift`
- `Tests/CellBaseTests/OID4VCIIssuerMetadataTests.swift`
- `Tests/CellBaseTests/OID4VCIMetadataClientTests.swift`
- `Tests/CellBaseTests/OID4VCICredentialOfferTests.swift`
- `Tests/CellBaseTests/DIDDocumentValidatorTests.swift`
- `Tests/CellBaseTests/OID4VPDCQLTests.swift`
- `Tests/CellBaseTests/OID4VPRequestObjectTests.swift`
- `Tests/CellBaseTests/OID4VPRequestMatcherTests.swift`
- `Tests/CellBaseTests/OID4VPResponseTests.swift`
- `Tests/CellBaseTests/OID4VPVerifierMetadataTests.swift`
- `Tests/CellBaseTests/OID4VPDirectPostTests.swift`
- `Tests/CellBaseTests/OID4VPDirectPostJWTEncryptionTests.swift`

Current OpenID4VP trust coverage in code:

- `decentralized_identifier` signed requests verified against DID Documents
- `verifier_attestation` signed requests verified against trusted attestation issuer keys and `cnf.jwk`
- `x509_hash` signed requests verified against leaf-certificate SHA-256 thumbprints, static trust anchors, and leaf-key signatures
- `x509_san_dns` signed requests verified against DNS SAN bindings, static trust anchors, and leaf-key signatures

The current issuer metadata layer now covers:

- well-known metadata URL derivation
- unsigned `application/json` metadata parsing
- signed `application/jwt` metadata parsing
- structural validation of signed metadata header and payload
- mockable HTTP retrieval for local-first testing

Cryptographic trust verification of signed issuer metadata is still a separate
next step.

The current DID interoperability layer now also covers:

- DID document validation for the subset HAVEN currently emits and consumes
- resolution of referenced assertion/authentication methods
- DID URL key binding checks for issuer-facing assertion keys
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VCI/OID4VCIIssuerMetadata.swift`
- `Tests/CellBaseTests/OID4VCIIssuerMetadataTests.swift`

The current OpenID4VP transport-neutral foundation now covers:

- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPDCQL.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPRequestObject.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPRequestMatcher.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPResponse.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPVerifierMetadata.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPDirectPost.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPDirectPostJWTEncryption.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPDirectPostJWTSubmissionAdapter.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/OpenID4VP/OID4VPStaticVerifierMetadataProvider.swift`
- `Sources/CellBase/VerifiableCredentials/Standards/JOSE/JOSEAESKeyWrap.swift`
- `Tests/CellBaseTests/OID4VPDCQLTests.swift`
- `Tests/CellBaseTests/OID4VPRequestObjectTests.swift`
- `Tests/CellBaseTests/OID4VPRequestMatcherTests.swift`
- `Tests/CellBaseTests/OID4VPResponseTests.swift`
- `Tests/CellBaseTests/OID4VPVerifierMetadataTests.swift`
- `Tests/CellBaseTests/OID4VPDirectPostTests.swift`
- `Tests/CellBaseTests/OID4VPDirectPostJWTEncryptionTests.swift`
- `Tests/CellBaseTests/OID4VPDirectPostJWTSubmissionAdapterTests.swift`
- `Tests/CellBaseTests/JOSEAESKeyWrapTests.swift`

This currently gives HAVEN:

- DCQL parsing and validation
- request-object parsing and validation
- request-to-candidate matching
- deterministic `vp_token` response building
- typed verifier metadata parsing and validation from `client_metadata`
- verifier metadata resolution with explicit client-id-prefix policy
- deterministic preparation of `direct_post.jwt` encryption inputs
- actual compact JWE construction for `direct_post.jwt`
- first happy-path request -> match -> response -> encrypted submission adapter
- `direct_post` and `direct_post.jwt` submission models
- direct-post callback parsing with explicit validation
- static authoritative verifier metadata providers for `pre-registered` and out-of-band resolution

Current encryption scope:

- `alg=ECDH-ES`
- `alg=ECDH-ES+A128KW`
- `alg=ECDH-ES+A192KW`
- `alg=ECDH-ES+A256KW`
- EC recipient JWKs on `P-256`, `P-384`, and `P-521`
- `enc=A128GCM`, `enc=A192GCM`, and `enc=A256GCM`
- compact JWE serialization for both direct key agreement and wrapped-CEK modes
- RFC 3394 AES Key Wrap for JOSE key-management modes

Still intentionally out of scope:

- signed JAR request processing
- content-encryption algorithms beyond AES-GCM
- verifier metadata retrieval from federation, DID, or verifier attestation
- verifier metadata driven response encryption beyond the current direct-post JWE path

Current verifier metadata resolution policy:

- `pre-registered`: requires authoritative metadata from a provider; embedded `client_metadata` is rejected
- `redirect_uri`: uses request-carried `client_metadata`
- `openid_federation`: requires authoritative metadata from a provider and ignores embedded `client_metadata`
- other currently supported prefixes fall back to request-carried `client_metadata`, with provider-based metadata available as an additive extension point

Current authoritative-source support:

- `OID4VPStaticVerifierMetadataProvider` gives a concrete pre-registered / out-of-band registry-backed provider
- `OID4VPCompositeVerifierMetadataProvider` lets us layer multiple authoritative providers without changing request handling
- no network-defined verifier metadata retrieval endpoint is assumed yet, because OpenID4VP does not define a single generic one

The current downstream ingest route for searchable verification artifacts is:

- `POST /v1/cell/cases/{case_id}/contract-verification`

Then explore the remaining chapters based on interest.

---

## 🗺 Roadmap (high-level)

- Complete v1 specification  
- Build production-ready Scaffold runtime  
- Add QUIC and offline bundle transport bridges  
- Develop developer tooling for replay, flow inspection, and contract exploration  
- Implement example Cells for navigation, collaboration, moderation  
- Publish full documentation site  

---

For questions or further development discussions, feel free to open an issue
or contact the project maintainers.
