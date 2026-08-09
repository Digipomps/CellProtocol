# Owner-mediated cross-Scaffold entity association

Status: static review candidate; no runtime implementation, camera/UI work, or
live entity mutation

Date: 2026-07-21

Repository baseline: `CellProtocol` at
`79740304167aa4f4daadd148c5a369e919d25a6a` (`origin/main` at inventory time)

## Decision

In this initiative, **linking means association**.

It does not mean either of the following:

- **equivalence**: the protocol does not assert that two representations are
  the same natural person, organisation, device, or global Entity;
- **delegation**: the association grants no read, write, execute, storage,
  forwarding, impersonation, recovery, ownership, or administrative authority.

The strongest statement an association certificate may support is:

> Two domain-scoped endpoint proof paths completed this exact, short-lived,
> context-bound exchange and each endpoint produced an explicit confirmation
> over the same transcript.

That statement is intentionally weaker than “same entity”. The existing
`IdentityLinkingModels` and `IdentityLinkCompletion` surfaces use
`same_entity`, approved scopes, and live `EntityAnchorCell` storage. They are
therefore a no-touch surface for this work, not a substrate to rename or extend.

Every wire object in this proposal MUST bind
`associationSemantics = "association"` and `grantsAuthority = false`. A
different semantic or an authority-bearing field is a different protocol and
MUST be rejected rather than downgraded or ignored.

## Formål and Goals

| purposeRef | Intent | Observable Goal | Static status |
| --- | --- | --- | --- |
| `purpose://human-agency` | Let owners deliberately associate two representations without claiming personhood. | The semantic boundary and human decision points are explicit. | satisfied for design review |
| `purpose://access.audit.privacy` | Keep QR and association artifacts non-authoritative, minimal, bounded, and revocable. | The threat matrix covers the requested attacks, data classes, denial behavior, and residual risks. | satisfied for design review |
| `purpose://test.acceptance` | Make a future inert implementation falsifiable. | Focused positive/negative tests pass on the exact additive contract. | blocked by the 2026-07-21 hard-disk gate; no tests run |

The relay/proximity sub-goal is terminal but not satisfied: a copyable QR and a
network transcript cannot prove physical proximity or prevent a transparent
relay. This is a product/security decision gate, not an implementation detail.

## Claim ledger and adjudication

| ID | Root claim | Type / strength | Counterclaim | Adjudication |
| --- | --- | --- | --- | --- |
| C1 | Association is the only safe meaning of “link” in this scope. | normative, moderated | A same-owner flow might justify equivalence or delegated scopes. | **supported**. CellProtocol identity is domain-scoped with no automatic cross-domain linkage; authority requires a separate verified path. Existing `same_entity` code is already materially different and live. |
| C2 | A QR can be used as non-authoritative rendezvous data without carrying a durable secret or portable identity. | project capability, moderated | Possession or replay of the QR can become a bearer credential. | **supported as a design constraint**, not as implemented capability. The QR carries only public, expiring session material and a commitment; every transition still needs local owner admission and signed endpoint evidence. |
| C3 | Mutual proofs, exact transcript binding, single-use challenges, and two endpoint confirmations can detect replay, downgrade, and endpoint substitution. | project capability, moderated | Incorrect canonicalization, replay storage, state races, or UI ambiguity can defeat the design. | **supported as a fail-closed contract decision; runtime claim blocked**. The static contract requires all checks and rejects completion if durable replay state or authenticated human comparison is unavailable. It supplies no implementation or runtime evidence. |
| C4 | QR exchange prevents relay and proves co-presence. | factual, assertive | A screenshot or forwarded QR can be relayed, and an unchanged transcript is indistinguishable from direct carriage. | **contradicted**. The design can prevent a relay from substituting endpoints or gaining authority; it cannot prove proximity or stop a transparent relay from carrying an unchanged exchange. |
| C5 | A bilateral certificate prevents unilateral or half-complete state from becoming an active association. | project capability, moderated | Separate Scaffolds cannot guarantee simultaneous local materialization during partitions. | **supported as an artifact rule; runtime claim blocked**: no certificate exists without two confirmations. Local views can still be temporarily inconsistent, and strict distributed atomic visibility is explicitly not claimed. Because the certificate grants no authority, inconsistency MUST fail closed and MUST NOT affect access. |
| C6 | QR, signatures, local user verification, and confirmation prove free consent and absence of coercion. | factual, assertive | A coerced or deceived person can perform every cryptographic step. | **contradicted**. Coercion and duress are an explicit unsolved boundary. |

The practical-reasoning questions for C1 are answered for this gate: the goal
is bounded association, the live alternatives carry stronger semantics, the
association has fewer authorization consequences, and the remaining relay and
coercion risks are recorded rather than hidden. C3 and C5 have terminal static
contract decisions, but their runtime-security claims remain blocked and
receive no implementation support from this document alone.

## Priority 7B terminal security decisions

These decisions close the static contract review only. They do not certify an
implementation, transport, user interface, deployment, or live identity flow.

### Replay: closed as a conditional contract GO

Replay handling is acceptable for an inert future contract only under all of
these non-negotiable rules:

- QR and protocol messages confer no authority and cannot materialize an
  association without both current proofs and both current confirmations;
- role-specific challenges, session IDs, message IDs, canonical payload hashes,
  expiry, and state revisions are checked together, never independently;
- the session ledger and compare-and-swap state are durable for the complete
  acceptance window. Missing, corrupt, rolled-back, or unavailable replay state
  makes the operation unavailable; it never resets a session to unused;
- exact retries return the same receipt, while a different payload for an
  already-seen identifier or challenge fails as a conflict;
- a second distinct valid responder makes the offer terminally `contested`;
- a certificate identifier is deterministically derived from the final
  transcript hash. A certificate received as remote input cannot recreate a
  locally deleted or incomplete association; local materialization requires the
  original, complete local session transition;
- certificate terminal state and any revocation tombstone follow a separately
  reviewed retention policy and cannot be forgotten in a way that re-enables a
  remote replay.

The contract decision is **GO** for this bounded shape. The runtime claim is
**NO EVIDENCE / BLOCKED** until persistence, rollback, concurrency,
canonicalization, and negative tests can run after the disk gate is lifted.

### Relay: closed as a proximity and anti-relay NO-GO

A transparent relay of an unchanged QR and transcript is indistinguishable
from direct carriage. The protocol can keep the relay from substituting a
proof key, changing the bound context, or acquiring authority, but it cannot
prove that the endpoints are physically close or stop a relayer from carrying
the honest bytes between them.

Therefore QR-only association is **NO-GO** for any product requirement or
claim of co-presence, distance bounding, anti-relay, in-person identity, or
location. If any such property is required, this protocol must be rejected for
that use case and a separately threat-modeled proximity/authentication
mechanism is required. Confirmation does not upgrade this result.

### MITM: closed as conditional transcript protection, not peer identity

Commitment, mutual signatures, complete transcript binding, and fail-closed
version handling can detect modification or endpoint substitution *inside the
same committed session*. They do not authenticate a real-world person at first
contact and do not by themselves detect wholesale replacement of the QR with a
different valid offer.

Confirmation is acceptable only after both humans compare the final value and
the intended context labels through an authentic interaction independent of
the rendezvous transport. A success flag delivered by that same transport is
not an independent comparison. If comparison is unavailable, mismatched,
ambiguous, skipped, or not usability-tested, completion fails closed; there is
no “confirm anyway” path.

The contract is therefore conditionally **GO** for detecting transcript
modification and key/context substitution, but **NO-GO** for claims of general
MITM prevention, phishing resistance, intended-person identity, or protection
when a user confirms a wholly substituted offer. First-contact keys remain
self-asserted unless a separate trust anchor is selected and reviewed.

### Coercion and duress: closed as an accepted unsolved boundary

A coerced or deceived person can complete every cryptographic and local-owner
step. The bilateral certificate remains evidence only of the bounded proof
paths and confirmations; it is not evidence of identity, comprehension, freely
given consent, presence, or absence of coercion. Cancellation and revocation
reduce future product effect but neither proves coercion nor erases previously
observed history.

The protocol is **NO-GO** wherever proof of free consent or absence of duress
is a requirement. No hidden duress action, secret duress PIN, or silent claim
of safety is introduced. Recovery, cooling-off, disclosure, and duress policy
remain separately human-owned product work with their own abuse trade-offs.

## Protected resource, action, and authority path

Protected resources:

- each endpoint's private, short-lived association session;
- a future local projection of a complete bilateral association certificate;
- cancellation and revocation state for that exact association.

Candidate local actions:

- `association.createOffer`
- `association.acceptOffer`
- `association.submitProof`
- `association.confirm`
- `association.cancel`
- `association.revoke`
- `association.readOwnState`

These names describe a future contract; they are not implemented keypaths.

The requester for every state-changing action is the local endpoint's
domain-scoped owner Identity. The local owner-only Cell MUST verify the normal
owner path through the Resolver/Cell boundary, match the vault's UUID and
signing-key fingerprint, and require the applicable `IdentityDomainBinding`
inside the signed payload. A QR, remote message, endpoint label, UUID, public
key, deep link, bridge, or transport session is never that authority path.

Remote protocol messages are evidence proposals. They MUST NOT directly invoke
a local entity mutation. A local owner action validates them and chooses
whether to advance the private session state.

An association certificate is not an Agreement, Contract, Grant, capability,
ownership proof, recovery proof, or identity-equivalence credential. Any later
access requires a separate resolver-enforced authorization path with its own
conditions, expiry, revocation, and tests. An implementation MUST NOT interpret
association presence as a grant shortcut.

## What mutual proof establishes

Each endpoint proof establishes control of the private signing key
corresponding to the endpoint descriptor for one exact transcript. A local
owner-Cell attestation can additionally establish that the local runtime
accepted its own owner path for that session.

Across a first-contact boundary, the other Scaffold still does not gain an
external truth oracle for personhood or ownership. It learns that the
committed key and local Cell assertion produced the proof. Independent trust
anchors would be a separate policy layer.

Therefore the protocol does not prove:

- a legal or natural identity;
- that the holder and subject are the same person;
- that only one natural person can use the authenticator;
- physical proximity or presence at a particular location;
- comprehension, freely given consent, or absence of coercion;
- permission to access either Entity;
- future control after key loss, rotation, or compromise.

## Data classification

### QR payload: public, expiring, and non-authoritative

The QR payload is a transport representation of an offer. It MUST contain only:

- exact QR schema and protocol version;
- exact suite identifier, with no legacy fallback;
- a cryptographically random opaque session ID;
- the initiator's cryptographically random single-use challenge;
- issued-at and expiry values with a protocol-bounded lifetime;
- an opaque, short-lived rendezvous locator that carries no bearer authority;
- a salted commitment to the initiator endpoint descriptor;
- size/encoding metadata needed for strict parsing.

The QR payload MUST NOT contain:

- a private key, seed, recovery phrase, password, access token, cookie, shared
  secret, portable credential, Contract, Grant, or capability;
- a durable Identity UUID, DID, public key, signing-key fingerprint, global
  Entity identifier, stable entity URL, or reusable owner proof;
- personal profile data, display name, email, phone number, or entity graph;
- an association certificate or a confirmation that can be replayed elsewhere.

The session ID and challenge are public nonces, not secrets. Possession allows
an attempt to join the rendezvous and can cause nuisance or contention; it
allows no confirmation, proof, association, or access.

The v0 review profile requires `expiresAt - issuedAt <= 300 seconds`. Each
endpoint proof and confirmation must be created no more than 60 seconds before
validation, must not be more than 30 seconds in the validator's future, and
must remain within the session expiry. A deployment may choose shorter windows
but may not lengthen these bounds without a new reviewed profile. Retry never
extends any window.

Illustrative shape, not a production encoding:

```json
{
  "schema": "cellprotocol.owner-mediated-association-qr.v0",
  "protocolVersion": 0,
  "suiteID": "cellprotocol.owner-mediated-association-transcript.v0",
  "sessionID": "base64url(32 random bytes)",
  "initiatorChallenge": "base64url(32 random bytes)",
  "initiatorCommitment": "base64url(hash(canonical endpoint reveal))",
  "rendezvous": "opaque short-lived locator",
  "issuedAt": "bounded UTC instant",
  "expiresAt": "bounded UTC instant"
}
```

The exact canonical encoding, time representation, signature suites, and size
bounds MUST be fixed before implementation. The v0 lifetime bounds above are
part of the signed profile. Unknown versions or suites fail closed. Neither
endpoint may silently retry with an older version.

### Private transcript data

Endpoint descriptors are exchanged only after local admission and MUST remain
private to the two owner sessions. Each descriptor binds:

- a pairwise Scaffold binding for this counterparty and context;
- the exact identity domain;
- a pairwise entity-context reference, not a global Entity ID;
- the endpoint's verification key descriptor and fingerprint;
- the non-authoritative `IdentityDomainBinding` with
  `grantsAuthority = false`;
- the association context/purpose shown to the human;
- the local owner-Cell attestation for this session.

Pairwise values are required because stable identifiers and keys can correlate
activity across contexts. The initiator's reveal includes a fresh commitment
salt; the QR commitment MUST match before its endpoint proof is accepted.

Transcript signatures provide integrity and bounded proof of key control, not
confidentiality. No delivery mechanism is selected by this document. Current
Chat, a one-shot envelope to a long-lived recipient X25519 key, persisted-Cell
encryption, and TLS/WSS MUST NOT be described as server-blind E2EE or
recipient-compromise forward secrecy for this exchange. Before implementation,
reviewers must either select and independently assess a message-level
confidentiality protocol or explicitly place the rendezvous host inside the
trusted plaintext endpoint set and accept its visibility and correlation risk.
Until then, private-transcript delivery is unresolved and blocked.

### Logs and read models

Public read models are forbidden for pending sessions and certificates. Logs,
diagnostics, flow events, and denial responses may contain only schema/version,
coarse state, bounded reason code, and hashes needed for idempotence. They MUST
NOT contain QR bytes, challenges, endpoint descriptors, public keys, domain
bindings, comparison values, confirmations, signatures, or certificate bodies.

## Canonical transcript

Both endpoint signatures and both confirmations bind the same transcript hash.
The canonical transcript contains at least:

- protocol schema, exact version, suite ID, and canonicalization ID;
- `associationSemantics = "association"`;
- `grantsAuthority = false`;
- session ID, QR hash, initiator commitment and commitment reveal;
- both independent single-use challenges;
- both complete endpoint descriptors;
- initiator and responder roles;
- exact Scaffold, domain, pairwise entity and context bindings for both sides;
- issued-at, expiry and bounded session revision;
- a hash of every prior protocol message in role order;
- a context statement suitable for human display;
- no requested or approved capabilities.

Arrays, object keys, binary values, strings and time MUST have one unambiguous
canonical encoding. The hash/signature input excludes only its own signature
field. A parser MUST reject duplicate keys, unknown security-critical fields,
wrong types, overlong values, missing fields, reordered role messages that
change semantics, and non-canonical encodings.

The human comparison value is derived from the final transcript hash and shown
on both endpoints with the same context labels. Its rendering and minimum
effective entropy are an unresolved UX/security choice. Until fixed and
usability-tested, no implementation may claim MITM-resistant human comparison.

## Inert state machine

```text
absent
  -> offered
  -> candidateBound
  -> mutuallyProved
  -> awaitingConfirmations
  -> certificateComplete

offered/candidateBound/mutuallyProved/awaitingConfirmations
  -> cancelled | expired | contested | rejected

certificateComplete
  -> revoked
```

Rules:

1. The initiator's owner-only Cell creates the offer and first challenge using
   a CSPRNG. QR rendering is outside this contract.
2. The responder's owner-only Cell admits the scan locally, generates an
   independent responder challenge, and signs a candidate message bound to the
   QR hash and association context.
3. The initiator validates the candidate and signs the complete transcript.
4. The responder validates the initiator commitment/proof and signs the same
   complete transcript. Both proof paths verify UUID plus public key/fingerprint
   plus domain binding; UUID alone is insufficient.
5. Both endpoints display the exact semantic boundary, counterparty bindings,
   context, expiry, and comparison value. Each endpoint requires a separate
   explicit local confirmation over the final transcript hash.
6. A `BilateralAssociationCertificate` exists only when both valid endpoint
   proofs and both unexpired confirmations are present for the same transcript.
   The certificate repeats `grantsAuthority = false`.
7. Pending messages never become an association record, never alter live
   Identity/Entity state, and expire without side effects.

The confirmation signature is the final decision for that short-lived session.
Before signing, the endpoint may cancel. After signing, a unilateral message is
still inert until the peer also confirms; after a bilateral certificate exists,
the correct operation is revocation rather than pretending the signed history
never existed.

## Replay, contention, and idempotence

Each endpoint maintains, for at least the acceptance window, a private ledger
of session IDs, challenge hashes, message IDs, canonical payload hashes, state
revision, expiry, and terminal outcome.

- A challenge is accepted only for its exact session, role, peer challenge,
  endpoint bindings, transcript, and expiry.
- A valid first use consumes the role/challenge tuple. An identical retry is
  idempotent and returns the same receipt. A different payload using the same
  ID or challenge is rejected as a conflict.
- Invalid unauthenticated input does not consume a challenge, but it may be
  rate-limited. A second distinct valid responder for one QR makes the session
  `contested`; first-scanner-wins is forbidden. The safe recovery is a new
  session and QR.
- Terminal cancellation, expiry, contention, rejection, certificate completion,
  or revocation is monotonic. A retry cannot move a terminal state backwards.
- Expiry is checked at every transition and confirmation. It cannot be extended
  by retry or clock skew; restart requires fresh challenges and a new QR.
- State changes use compare-and-swap against the signed session revision so
  duplicate or reordered messages cannot overwrite a newer terminal state.

## Cancellation, revocation, and partial failure

Cancellation is local-owner authorized and terminal before that endpoint's
confirmation. The cancellation statement binds session ID, transcript prefix,
state revision, reason code, and time. The peer treats a valid cancellation as
terminal. If delivery is unavailable, the session expires and cannot produce a
certificate without both confirmations.

Revocation is available to either associated endpoint after certificate
completion. A signed revocation tombstone binds association ID, certificate
hash, revoking endpoint, reason code, and time. Either valid endpoint
revocation makes the association unusable as a current relationship once
observed. A stale offline copy can remain unaware; because association never
authorizes access, that propagation delay cannot lawfully preserve authority.

Partial-failure rules:

- one proof or one confirmation is pending evidence, never an association;
- no local `active` projection may be created without the complete bilateral
  certificate;
- identical retries return the same result; conflicting retries fail closed;
- persistence failure leaves the operation pending/failed, not successful;
- certificate delivery loss may make endpoint views temporarily inconsistent,
  but cannot create a unilateral certificate or authority;
- reconciliation revalidates the complete certificate and current revocation
  state; it does not merge entities or create grants.

Strict simultaneous visibility in two independent stores is not claimed. If a
product requirement treats temporary view divergence as forbidden “partial
linking”, it needs a separately reviewed atomic storage/coordinator design.

## Threat matrix

| Threat | Required response | Residual boundary |
| --- | --- | --- |
| QR replay | Short expiry, random session/challenge, single-use ledger, exact transcript binding. | A replay can cause a denied attempt or nuisance, not association. Missing or rolled-back replay state fails unavailable, not unused. |
| Protocol-message replay | Role-specific challenges, message IDs, payload hashes, expiry, monotonic state, idempotent exact retry only. | Ledger durability and multi-node consistency require tests; no runtime evidence exists. |
| Transparent relay | Relay gets no secret or authority; both key proofs and both confirmations remain required. | Direct versus transparently relayed carriage is indistinguishable. QR-only proximity and anti-relay claims are NO-GO. |
| MITM substitution | Initiator commitment, both endpoint descriptors and challenges in one transcript, mutual signatures, authentic two-sided comparison and confirmation. | Whole-offer replacement, first-contact peer identity, skipped comparison, and human deception remain. General MITM/phishing-resistance claims are NO-GO. |
| Downgrade | Exact version/suite/canonicalization in QR, transcript, proofs, and confirmations; unknown values rejected; no legacy fallback. | Future migration needs an explicit new protocol, not negotiation by omission. |
| Endpoint/scaffold/domain/entity/context substitution | Every binding is signed and included in the transcript hash; proof key/fingerprint and domain binding must match. | The remote side sees a local owner assertion, not independent proof of a real-world Entity. |
| Screenshot/shoulder surfing | QR has no durable secret or portable identity; expiry and contention limit use; scan grants nothing. | A timely screenshot can be relayed or used for denial/contestation. |
| Multiple scanners | Distinct valid responders make the offer `contested`; no first-scanner-wins; restart with fresh QR. | An observer can cause denial of service, not association. |
| Partial/truncated/oversized scan | Strict schema, size, type, canonicalization, and completeness checks before state creation. | Parser safety still needs fuzz/property tests after the disk gate. |
| Expired or future-dated input | Bounded lifetime and clock-skew policy checked at every step; no extension. | Clock policy is not yet fixed. |
| Cancellation race | Confirmation is accepted only against current monotonic revision; cancellation before confirmation is terminal. | After an endpoint signs final confirmation, later withdrawal is revocation, not cancellation. |
| Revocation replay/substitution | Tombstone binds association/certificate hash, endpoint proof key and monotonic status; either side may revoke. | Offline peers can be stale; association must never authorize access. |
| Duplicate delivery | Same message ID plus same canonical hash is idempotent; same ID plus different hash is conflict. | Durable receipt storage is unimplemented. |
| Persistence/transport failure | Pending states and complete-certificate requirement; no success response before durable local receipt. | Cross-store simultaneous display is not guaranteed. |
| QR treated as consent | QR is public offer data only; separate explicit confirmation at each owner-only endpoint. | Confirmation still cannot prove comprehension or free consent. |
| Coercion/duress | Explicit warning, cancel before confirm, expiry, later unilateral revocation, and recovery path as future product policy. | Cryptography cannot establish free consent or absence of coercion. Consent-proof use cases are NO-GO. |

## Denial contract

A future pure validator should return bounded machine-readable outcomes such as:

- `malformedOffer`
- `unsupportedVersion`
- `unsupportedSuite`
- `expiredSession`
- `challengeReplay`
- `challengeMismatch`
- `endpointBindingMismatch`
- `domainBindingMismatch`
- `transcriptMismatch`
- `invalidEndpointProof`
- `missingLocalOwnerProof`
- `confirmationRequired`
- `authenticatedComparisonRequired`
- `contestedSession`
- `cancelledSession`
- `conflictingRetry`
- `revokedAssociation`
- `persistenceUnavailable`

Denials MUST not echo secrets, raw inputs, endpoint descriptors, signatures, or
comparison values. A caller-facing required action may say retry, restart with
a fresh QR, compare again, or contact the owner; it must never auto-grant.

## Coercion and duress: unsolved by design

The following invariant must appear in protocol docs and future UX:

> QR scanning, key control, local user verification, matching comparison text,
> and signed confirmation do not prove identity, physical presence, free
> consent, comprehension, or absence of coercion.

Possible later mitigations include a cooling-off period, delayed disclosure,
safe cancellation language, recovery contacts, unilateral revocation, and a
duress-aware product policy. Each has safety and abuse trade-offs and requires
a human-owned design decision. No “duress PIN” or silent emergency action is
specified here.

## Focused future test contract

No tests were run in this iteration because the authoritative hard-disk gate
freezes builds, dependency resolution, and tests. After an explicit admin lift,
an additive inert model should have at least these focused tests before review:

1. happy path produces a certificate only after two matching proofs and two
   confirmations;
2. the QR model cannot encode durable identities, key material, credentials,
   capabilities, or grants;
3. QR possession alone and remote input without local owner proof are denied;
4. missing/forged proof, wrong key with same UUID, wrong vault/domain, and wrong
   Scaffold/entity/context are denied;
5. replayed challenge/message/confirmation and cross-session swapping are
   denied;
6. expired, future, overlong, malformed, partial, duplicate-key, non-canonical,
   and unknown-version/suite payloads fail closed;
7. downgrade and legacy fallback are denied;
8. initiator, responder, commitment, challenge, role, and message-order
   substitution are denied;
9. a second distinct valid scanner makes the session contested, while an exact
   retry is idempotent;
10. cancellation, expiry, and revocation are monotonic and reject later
    completion;
11. persistence failure and lost replies cannot yield a unilateral certificate
    or an authority-bearing state;
12. public state, events, logs, and denials contain none of the prohibited
    private fields;
13. association is never accepted by Resolver policy as a capability, Contract,
    Grant, owner proof, recovery proof, or identity equivalence;
14. deterministic canonical encoding and transcript hashes have fixed golden
    fixtures across supported runtimes;
15. missing, corrupt, rolled-back, or unavailable replay state fails
    unavailable and cannot reset a challenge or session;
16. whole-offer replacement, comparison mismatch, skipped comparison, and a
    comparison result delivered only by the rendezvous transport cannot reach
    confirmation.

Relay prevention, human comprehension, and absence of coercion are not
testable cryptographic acceptance claims. Tests can only lock the honest copy
and ensure the protocol does not overstate them.

## Implementation and review gates

An additive inert Swift model is justified only after Kjetil accepts:

- association semantics and the explicit no-authority invariant;
- the transparent-relay/proximity limitation;
- QR/session maximum lifetime and clock policy;
- comparison rendering and confirmation UX;
- pairwise endpoint identifier and correlation policy;
- persistence/coordinator semantics for cancellation and partial failure;
- revocation discovery and retention policy;
- recovery and duress boundaries.

Then the hard-disk gate must be explicitly lifted. Proposed future files should
be new and isolated (for example an association model plus one focused test
file); they must not modify `IdentityLinkingModels`, `IdentityLinkCompletion`,
Apple/Vapor `EntityAnchorCell`, IdentityVault, Resolver behavior, camera/UI, or
live entity state in the first implementation round.

The phase order remains: decision/threat review, additive inert model, focused
tests, independent security review, integration design, human-assisted UX,
staged operational trial, and only then any separately authorized production
work.

## Source audit

Repository-grounded sources reviewed:

- `Sources/CellBase/Identity/IdentityLinkingModels.swift`
- `Sources/CellBase/Identity/IdentityLinkCompletion.swift`
- `Sources/CellBase/Identity/IdentitySigningChallenge.swift`
- `Sources/CellBase/Identity/IdentityDomainBinding.swift`
- `Sources/CellBase/Identity/IdentityVaultProtocol.swift`
- Apple/Vapor `EntityAnchorCell.swift` identity-link paths (read-only)
- `Tests/CellBaseTests/IdentityLinkingModelsTests.swift` (read-only; not run)
- `Docs/Swarm_Identity_Admission_and_Entity_Link_NO.md`
- `Docs/Security_Development_Guide_NO.md`
- `SECURITY.md`
- CellProtocolDocuments Book chapters 03, 04, 06, 23, 27, 29, and 30

Primary external sources checked:

- [W3C Verifiable Credentials Data Model 2.0](https://www.w3.org/TR/vc-data-model-2.0/): verification does not establish the truth of claims, and a holder is not always the subject.
- [W3C Web Authentication Level 3](https://www.w3.org/TR/webauthn-3/): user verification does not concretely identify a natural person, and remotely invokable authenticators do not establish physical proximity.
- [NIST SP 800-63B-4 authenticator requirements](https://pages.nist.gov/800-63-4/sp800-63b/authenticators/): replay resistance uses freshness/challenges, while phishing resistance requires verifier binding and an authenticated protected channel.
- [RFC 9449, DPoP](https://www.rfc-editor.org/rfc/rfc9449): proof of key possession is not by itself authentication or access control; short-lived proofs, endpoint binding, nonce handling, and single-use identifiers limit replay.
- [RFC 8446, TLS 1.3](https://www.rfc-editor.org/rfc/rfc8446): transcript-bound authentication and fail-closed version handling inform the no-downgrade design. This proposal does not claim TLS conformance.
- [Noise Protocol Framework](https://noiseprotocol.org/noise.html): the handshake-hash pattern informs complete transcript binding. This proposal does not select or implement a Noise handshake.

These standards support individual design constraints; none proves this
unimplemented CellProtocol association contract secure.
