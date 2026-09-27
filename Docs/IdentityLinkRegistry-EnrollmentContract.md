# IdentityLinkRegistry: enrollment and genesis

`activeLinks(ownerUUID:)` lists active enrollment records. A genesis self-link
is ownership evidence, not an enrollment. `sameEntityLink` continues to search
all admitted active records, including verified genesis, with its existing
UUID, signing key, scope, domain and local-anchor binding checks. GeneralCell
still requires proof of control of the matching key.

Both CellVapor and CellApple restore the registry after storage loading and
genesis creation. They retain their existing rejection of reserved genesis
records without a valid seal. They now also pass the stored seal to `restore`.
The registry derives its classification by verifying that seal against the exact
record it references. `activeLinks` compares that verified record, not an ID
prefix or the issuer/holder relationship. Other admitted self-links stay listed; the completion protocol still
rejects enrollment with identical keys on both sides. The existing prefix check in EntityAnchor is an admission/revocation
rule; it is not the new list classification.

`restore(ownerUUID:records:genesisSeal:)` replaces the owner's records and derived
classification together. The optional seal defaults to nil for source
compatibility. Callers restoring genesis must supply it; as before, callers
must validate records before restore. `clear` removes both states. No persisted
JSON, seal payload, signature, enrollment proof, resolver policy, or revocation
format changes. Existing disk state needs no migration: classification is
reconstructed during restore. The owner-facing `identityLinks` and
`identityLinks.state` still expose the original genesis record and seal.

Regression purposes: F1 protects the enrollment list contract; F2 protects
genesis storage, restore and authorization. See
`IdentityLinkGenesisClassificationTests`, `EntityAnchorEnrollmentContractTests`
and `EntityAnchorAccessBoundaryTests.testF1F2FirstPersistGenesisRestoresOutsideEnrollments`.
The anchor cases execute both CellApple and CellVapor; the registry cases also
run under the Linux OpenCombine gate.
