# External Agreement admission — local probe

This document describes the isolated a36 probe on base `68069b6`. It is not a release or deployment claim.

At the base revision, `Contract.SigningPayload` covers issuer, subject, domain,
Agreement and times, but not the Cell UUID. The probe adds optional
`targetCellUUID` to both the wire Contract and signed payload. Nil retains the
legacy payload and semantics. `acceptExternallySignedAgreement` requires an
exact Cell binding; unbound legacy contracts are rejected on this new path.
Existing local admission and its `.ownerApprovalRequired` policy are retained.
Cell-bound authorization is also checked on later access.

The import freezes the presented Contract through JSON before suspending,
verifies the issuer/subject/domain/signature/time, proves the presenting
subject, compares grants, duration, policy binding and conditions with the
current template, evaluates conditions and installs only public descriptors.
The fixture keeps owner, host and subject in separate ephemeral vaults. The
host cannot sign as the owner. The owner sends JSON bytes; the subject presents
the decoded Contract directly to the Cell API. This is a single-process local
probe, not a tested two-machine transport or deployed correspondence Cell.

`BridgeIdentityVault.signMessageForIdentity` is an existing challenge-signing
proxy. `BridgeBase.consumeCommand` requires a matching local operation lease
from `BridgeIdentityProofAuthorization` before its local vault signs. A public
subject descriptor by itself cannot prove key control. This probe adds no
bridge command for importing a Contract; remote import remains untested.

Same-identity owner reads and separately admitted subject reads both require
key control. `GeneralCell` does not select a different authentication mode for
admission and ordinary access. Apple vault paths may use user-presence-protected
Keychain keys and reuse an authentication context. A fresh Touch ID/password
prompt on each admission, and no prompt on agent read/send, are not established
by this probe.

Evidence from the HAVEN root: `HAVEN-Deploy/_handoff/KORR-UT/bolk1/` and
`CellProtocolDocuments/Deliverables/PDD_kryptert-korrespondanse-med-vedlegg-ut_2026-10-06/handoff/BOLK-1-RAPPORT.md`.
The document is retained in the local probe commit and its exported patch;
no main-branch implementation is claimed.
