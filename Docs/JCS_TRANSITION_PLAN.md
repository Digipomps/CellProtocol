# JCS transition plan

Status: **plan**. Nothing here is implemented except `JCSCanonicalizer`
(`Sources/CellBase/Canonicalization/JCSCanonicalizer.swift`) and its RFC 8785
test vectors (`Tests/CellBaseTests/JCSCanonicalizerTests.swift`). No signing or
hashing path uses JCS yet.

Decision (Kjetil, 2026-11-23):

1. Canonicalization becomes **RFC 8785 (JCS)**, as **one** standard for every
   signed or hashed object.
2. `SecureKey.date` becomes **ISO 8601 UTC** in the same transition.
3. `SecureKey.use` and `size` are **derived** from algorithm and curve
   (`SecureKeyDerivation.swift`, PR "SecureKey: derive use and size").

Why: today there are at least four canonical forms, chosen per type, and they
are hard to reproduce outside Swift Foundation (see "Today's forms"). The
Kotlin port (`Digipomps/KotlinCellProtocol`) needs one rule it can implement
from a public spec.

## Today's forms

| Profile id (proposed) | How Swift makes the bytes | Traps for another implementation |
|---|---|---|
| `foundation-jsonserialization-sortedkeys` | `JSONSerialization.data(withJSONObject:options:[.sortedKeys])` (`CanonicalPayloadEncoder`, `FlowCanonicalEncoder`, `FlowSignatureMaterial`) | Keys sorted case-insensitively with digit runs as numbers (`item2` < `item10` < `Zulu`); `/` written as `\/`; doubles not exact in binary differ between Darwin (`0.10000000000000001`) and Linux (`0.1`) |
| `foundation-jsonserialization-sortedkeys-noslash` | Same, plus `.withoutEscapingSlashes` (`DeviceIngressWire`, `AgentTrustPackage`) | As above, without slash escaping |
| `foundation-jsonencoder-sortedkeys` | `JSONEncoder` with `.sortedKeys` (`IdentitySigningChallenge`, `ContractRevocation`, `TrustPacketCell`, ...) | Code-point key order; `/` as `\/`; `Date` as seconds since 2001 unless a strategy is set |
| `foundation-jsonencoder-sortedkeys-noslash` | `JSONEncoder` with `.sortedKeys, .withoutEscapingSlashes` (`VCProof`, `VCClaim`, `ReceiptSigning`, `EntityAuthorityCanonical`, bridge-channel envelopes) | Code-point key order; some set `dateEncodingStrategy = .iso8601` |

The pinned fixtures (`fixtures/interop/v1`, `fixtures/interop/flow-v1`) describe
these forms exactly and remain the reference for legacy verification.

## Target: `jcs-rfc8785`

- Bytes: `JCSCanonicalizer.canonicalize(...)`. UTF-16 key order, ECMAScript
  number format, minimal escaping, `/` never escaped, no whitespace.
- HAVEN profile on top of RFC 8785:
  - Integers whose magnitude can exceed 2^53 travel as **strings**. The
    canonicalizer refuses an integer literal above 2^53 (`unsafeInteger`).
    `FlowEnvelope.sequence` (`UInt64`) is **bounded to 2^53**: a larger value
    is refused, both when signing and when verifying (Besluttet av Kjetil
    2026-11-23). Still to review: byte counts. Millisecond timestamps are
    safe (2^53 ms is about 285 000 years).
  - `Data` stays standard base64 with padding.
  - Absent optionals stay absent (never `null`).
  - Dates are ISO 8601 UTC strings (rule below), never numbers.

### Date rule

**Besluttet av Kjetil 2026-11-23:** always three fractional digits.

`yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`: UTC, always three fractional digits, `Z`
suffix. Truncated (not rounded) to milliseconds. One fixed width means no
platform formatter choices. `SecureKey.date` first; every other `Date` in a
signed type moves at the same time, because they share the marker.

## The version marker

Every signed or hashed object states which canonical form its bytes use. The
marker is **inside the signed bytes**, so it cannot be swapped without
breaking the signature.

| Object kind | Marker |
|---|---|
| Types with a `proof`/`signature` that is excluded from the bytes (invite, chat, identity-link, organization, VC) | New top-level member `"canonicalization":"jcs-rfc8785"` in the signed payload. Absent means legacy |
| `FlowEnvelope` | `envelopeVersion: 2` means JCS (1 = legacy) |
| `IdentitySigningChallenge` | `version: 2` means JCS |
| Bridge channel | Profile `org.haven.bridge-channel.v2` (transcript and challenge in JCS) |
| Hashes used as ids (`MeetingPlanReference.hash`, `relational-weight-v1-…`, `certificateID`) | No general `-v2` rule; handled one by one, see "Hash ids" below (Besluttet av Kjetil 2026-11-23) |

A verifier reads the marker from the parsed object, then rebuilds the bytes
with that profile. Unknown marker: refuse.

## Phases

1. **P0, reference (now).** `JCSCanonicalizer` with RFC 8785 vectors; legacy
   flow fixtures pinned (`fixtures/interop/flow-v1`, with a note that a JCS set
   follows). Kotlin implements JCS against the same vectors.
2. **P1, verify both.** Every verifier accepts legacy and `jcs-rfc8785`
   objects, chosen by the marker. Signers still sign legacy. Ship to every
   Swift runtime (apps, Scaffold, staging, prod) before P2. JCS fixture sets
   (`fixtures/interop/v2`, `fixtures/interop/flow-v2`) are added next to the
   legacy ones; the test suite checks both.
3. **P2, sign JCS only.** Every signer emits `jcs-rfc8785` with the marker.
   Verifiers keep accepting legacy. This is the transition period: **both are
   verified, only JCS is signed.** Kotlin signs JCS only from day one and needs
   legacy verification only for objects made before P2.
4. **P3, retire legacy for live traffic.** After an announced date, legacy is
   refused for live protocol messages (challenges, bridge admission, flows,
   invitations). **Stored** legacy objects (genesis seals, VC claims,
   organization records, receipts, journals) are **re-signed by their owner**
   with JCS. Legacy verification is not kept forever (Besluttet av Kjetil
   2026-11-23). Legacy verification code stays until every stored object of a
   type is re-signed or handled as below.

### Re-signing in two tracks (Besluttet av Kjetil 2026-11-23)

Track 1: the owner re-signs its own stored objects with JCS.

Track 2: the owner can re-sign only what the owner signed. Objects signed by
others (credential issuers, counterparties, trusted-issuer receipts, replica
acknowledgements) go this way:

1. **Ask the original signer to re-sign** in JCS where that is possible: the
   issuer is reachable and still holds the key.
2. **Otherwise the owner makes a JCS-signed attestation** that binds to the
   old object and records the legacy check:
   `{"canonicalization":"jcs-rfc8785", "type":"org.haven.legacy-verification-attestation.v1",
   "subject":<sha256 of the object's legacy canonical bytes>, "legacyProfile":<profile id>,
   "originalSigner":<public key descriptor>, "verifiedAt":<ISO 8601 date>, "result":"valid"}`.
   The route is decided; the exact field list above is a proposal.
   The legacy object is kept unchanged next to the attestation, so a third
   party can still check it with the legacy profile if it wants to.
3. The attestation says "the owner checked this signature at this time". It
   is not the issuer's signature. A verifier that needs the issuer's own
   word (a credential presented to a stranger) treats it as weaker evidence
   and asks for a re-issued credential.

### Switch together

These change in **one release**, because client and server must agree on the
same bytes in one handshake:

- `IdentitySigningChallenge` v2 (JCS) and the bridge-channel transcript
  (`BridgeChannelAuthentication`, profile v2). The server accepts v1 and v2 in
  P1–P2; the client uses v2 when the server lists it in `channelAuthHello`
  (new optional field `profiles`), otherwise v1.
- `SecureKey.date` as ISO 8601, derived `use`/`size` (legacy `size: 32` and
  `count * 8` sites normalized to 256), behind the same marker: an object
  marked `jcs-rfc8785` encodes its `SecureKey`s the new way; a legacy object
  keeps the old encoding byte for byte.

## Where `.sortedKeys` is used for signing or hashing today

From a search of `Sources/` on `origin/main` (2026-11-23): 59 files mention
`sortedKeys`, and 19 more reach it through `CanonicalPayloadEncoder`. Sections
A–C make bytes that are signed, hashed or authenticated (about 45 files). Each
one moves to JCS (or gets an explicit legacy profile) in P1/P2. Files that only persist, export or display JSON are
listed last, out of scope.

### A. Signature bytes

| File | What is signed |
|---|---|
| `CellBase/Crypto/CryptoAgilityModels.swift` (`CanonicalPayloadEncoder`) | Shared encoder (`JSONSerialization` + `.sortedKeys`). Its users are the Chat, Correspondence, Meeting, Crypto, Identity, Invitation, Organization and backup rows below, and `ContentCryptoEnvelopeUtility` in C |
| `CellBase/Cells/Chat/ChatInvitationProofUtility.swift`, `Chat/ChatCell.swift` | Chat invitation and acceptance |
| `CellBase/Cells/Correspondence/CorrespondenceEnvelope.swift`, `CorrespondenceJoin.swift` | Correspondence envelopes, join records |
| `CellBase/Cells/Meeting/MeetingSignedEvidence.swift` | Meeting evidence |
| `CellBase/Crypto/DatabaseServiceGrant.swift`, `SecretCredentialContract.swift` | Grants, credential contracts |
| `CellBase/Identity/EntityGenesis.swift`, `IdentityLinkingModels.swift` | Genesis seal, enrollment request/approval/revocation |
| `CellBase/Invitation/HavenInviteTicket.swift`, `HavenInvitePublication.swift`, `HavenInviteReply.swift` | Invitation ticket (also the token), publication, reply, revocation, contact request |
| `CellBase/Organization/GovernancePolicy.swift`, `OrganizationApproval.swift`, `OrganizationGenesis.swift`, `OrganizationRoles.swift`, `OrganizationVault.swift` | Organization policy, approvals, genesis, role status lists |
| `CellBase/PersistingCells/UserOwnedBackupCodec.swift` | Backup manifests |
| `CellBase/Flow/FlowCanonicalEncoder.swift`, `FlowSignatureMaterial.swift` | Flow envelope and provenance |
| `CellBase/Identity/IdentitySigningChallenge.swift` | Identity signing challenge |
| `CellBase/Cells/Bridging/BridgeChannelAuthentication.swift` | Bridge-channel transcript and challenge |
| `CellBase/Agreement/Contract.swift`, `ContractRevocation.swift`, `ReceiptSignature.swift`, `SignedAgreementEntityCommit.swift` | Contracts, revocations, receipts, agreement commits |
| `CellBase/Cells/TrustPacket/TrustPacketCell.swift` | Trust packet origin signature |
| `CellBase/VerifiableCredentials/VCProof.swift`, `VCClaim.swift`, `VCPresentation.swift` | VC proofs and presentations |
| `CellBase/VerifiableCredentials/TrustedIssuerEvaluationReceipt.swift` | Evaluation receipts |
| `CellBase/PersistingCells/EntityAuthorityCommit.swift` | Entity authority commit request and receipt |
| `CellBase/Identity/OwnerAttachEntityExtension.swift` | Owner-attach statements |
| `CellBase/DeviceIngress/DeviceIngressWire.swift` | Device ingress records |
| `CellApple/EntityRadar/NearbyAccessAgreement.swift` | Nearby access agreement and advertisement proof |
| `CellBase/Cells/Contact/ContactReferenceContract.swift` | Contact reference (`contractDigest` binds it to the exact contract bytes) |

### B. Hashes, digests and derived ids

| File | Hash |
|---|---|
| `CellBase/Agreement/AgentTrustPackage.swift` | `packageDigest` |
| `CellBase/Cells/Meeting/MeetingConsentSession.swift` | `MeetingPlanReference.hash`, command replay key |
| `CellBase/PurposeAndInterest/RelationalLearningEngine.swift` | `relational-weight-v1-<sha256>` event ids; payload ordering |
| `CellBase/Cells/GeneralCell/GeneralCell.swift` | Condition policy compared against a template |
| `CellBase/VerifiableCredentials/TrustedIssuerCell.swift` | Normalized evidence and evaluation record ordering and size |
| `CellBase/PurposeAndInterest/EntityRepresentationDataCodec.swift` | Representation equality in `EntityRelationRecordV1` |
| `CellBase/Cells/Contact/ContactInboxCell.swift` | Payload equality for idempotent re-delivery |
| `CellApple/Cells/EntityAnchorCell.swift`, `CellVapor/Cells/EntityAnchorCell.swift` | `canonicalEntityData` equality during journal recovery; keypath storage and journal bytes |

### C. Authenticated data (AEAD)

| File | AAD |
|---|---|
| `CellBase/Crypto/ContentCryptoEnvelopeUtility.swift` (via `CanonicalPayloadEncoder`) | Content envelope header |
| `CellBase/Crypto/DatabaseServiceGrant.swift` (via `CanonicalPayloadEncoder`) | Grant scope |
| `CellApple/MeetingAppleCaptureDevice.swift`, `MeetingArchivedCaptureDevice.swift` | Encrypted audio chunk header |

AAD bytes are made by the sender and must be remade identically by the
receiver, so they need the marker too, or the header must travel as the exact
bytes that were authenticated.

### D. Bounds and ordering that only need to be deterministic locally

`PurposeAndInterest/RelationalLearningModels.swift` (size bound),
`PurposeAndInterest/WeightedGraphRuntime.swift` (cache key),
`Cells/CellResolver/CellAccessGraphContracts.swift`,
`Cells/Correspondence/CorrespondenceCell.swift`,
`Cells/Correspondence/CorrespondenceIdentityStateCodec.swift`,
`Agreement/Agreement.swift` (public snapshot round trip),
`VerifiableCredentials/Standards/OpenID4VP/OID4VPDirectPost.swift`,
`OID4VPDirectPostJWTEncryption.swift`, `OID4VPVerifierMetadata.swift` (JWT
parts: the signature covers the transmitted bytes, so these do not need
canonicalization at all). No marker needed; move to JCS when convenient.

### Out of scope (persist, export, display)

`Calendar/CalendarImportExport.swift`, `Cells/GeneralCell/ExploreContractCatalog.swift`,
`Cells/Testing/ContractProbeVerificationChunk.swift`, `ContractProbeVerificationRecord.swift`,
`EntityAtlas/AtlasVaultDocuments.swift`, `EntityAtlas/EntityAtlasExporter.swift`,
`Flow/FlowPlacementRemoteAccess.swift`, `PurposeAndInterest/Perspective.swift`,
`RuntimeLifecycle/RuntimeLifecycleAuthority.swift`, `RuntimeLifecycleDurableStores.swift`,
`Skeleton/SkeletonStyleParity.swift`, `ValueTypes/ValueType.swift`,
`CodableHelpers/JsonEncoder.swift`, `SkeletonCheckCLI/main.swift`,
`CellApple/Cells/OrchestratorCell.swift`, `CellApple/Intelligence/Tools/GraphMatchTool.swift`,
`CellApple/JsonViewer/ObjectView.swift`, `CellApple/Cells/Porthole/Utility Views/SkeletonListTree.swift`.

The lists are a starting point. Before P1, each entry in A–C gets its owner,
its marker and its fixture; a search for `JSONSerialization`, `JSONEncoder`
and `SHA256` near `sign`/`verify` catches sites that canonicalize without
`.sortedKeys`.

## For the Kotlin port

- Implement **only** `jcs-rfc8785` for signing. Run the vectors in
  `JCSCanonicalizerTests` (RFC 8785 §3.2.2, §3.2.3 and Appendix B).
- For P1–P2 interop with existing Swift peers, verify legacy objects against
  the pinned fixtures (`fixtures/interop/v1`, `fixtures/interop/flow-v1`),
  profile by profile as in the table above.
- Integers above 2^53: refuse, as Swift does, or read them as strings.

## Hash ids (Besluttet av Kjetil 2026-11-23)

There is no general `-v2` rule. Each hash is handled as below.

| Hash | Why content-addressed | Decision |
|---|---|---|
| `MeetingPlanReference.hash` (`MeetingConsentSession.swift`) | Binds consent to one plan revision. Compared only inside the same process; the signed consent carries the whole plan and is checked against it | **Random UUID/token per revision** (new on every invalidation). No JCS needed |
| `relational-weight-v1-<sha256>` (`RelationalLearningEngine.swift`) | Replay determinism: the same source event must give the same id, also in another runtime | Stays deterministic. New id version `relational-weight-event-id-v2` over JCS bytes. Today's id hashes `JSONEncoder` output of a `ValueType` object, which changes with `CellBase.usesExplicitObjectWire`; that dependency is removed in a separate fix |
| `certificateID` (`EntityAuthorityReplication.swift`) | One id per quorum evidence, recomputed by every replica | Kept deterministic; it moves with the marker of its certificate |
| `requestHash`, organization `policyHash`, replication and inventory hashes, `packageDigest`, `snapshotHash`, `contractDigest` | Bind a signature to exact content, or check integrity. Not ids | Binding digests follow the version marker of the object they live in: no `-v2` prefix and no parallel field. `ContactReferenceContract` is listed under A (signing) |

## Open questions

1. ~~Date format~~: always three fractional digits. Besluttet av Kjetil 2026-11-23.
2. ~~Stored legacy objects~~: re-signing in two tracks (owner re-signs own
   objects; others' objects are re-signed by the issuer or counterparty, or
   covered by an owner attestation). Besluttet av Kjetil 2026-11-23.
3. ~~Hash ids~~: no general `-v2` rule, one decision per hash (see "Hash ids"). Besluttet av Kjetil 2026-11-23.
4. ~~`FlowEnvelope.sequence`~~: bounded to 2^53, larger is refused. Besluttet av Kjetil 2026-11-23.
