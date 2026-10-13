# Owner-controlled database key custody

Purpose: `purpose://access.audit.privacy.database-key-custody`.
Choose this contract when private cell instances need isolated, encrypted databases,
portable blind secret storage, owner/device-controlled unwrapping, recovery or an
explicitly approved service session. Discovery is not authorization.

`SecretCredentialContract` signs immutable cell/domain/owner/recipient/version
bindings around RFC 9180 HPKE X25519/HKDF-SHA256/ChaChaPoly envelopes. The blind
store never becomes an implicit recipient. At least two different recipients
are required; actual recovery independence is the owner's deployment decision.
`SecretUnwrappingProvider` exposes operations rather than private wrapping keys.
`SecretKeyMaterial` is deliberately non-Codable and redacts ordinary inspection.

`DatabaseServiceRequest` authenticates an execution identity and one file, purpose,
audience, action, nonce, recipient and expiry. After native owner consent,
`DatabaseServiceGrant.approve` checks the current secret record, unwraps locally,
and seals only the v1-derived file key to that ephemeral recipient. The service
must pin the owner/record/request and consume its pending challenge once. A
runtime identity signature is not machine attestation. A hostile authorized
recipient can retain released keys and plaintext; TTL is not cryptographic revocation.

`HTTPSSecretCredentialTransport` requires HTTPS, rejects redirects and uses no
cookies/disk cache. Private PKI anchors must come from trusted local configuration;
hostname, validity and certificate chain validation are still required. This
transport must not be placed behind body-recording middleware or generic LLM tools.

CellApple supplies `AppleDatabaseSecretUnwrapper` (Data Protection Keychain,
WhenUnlockedThisDeviceOnly, fresh userPresence, explicit create versus open) and
`AppleDatabaseOwnerApproval` (native typed approval and persistent version pins).
The key is software X25519, not Secure Enclave. Apple HPKE requires macOS 14/iOS 17.
There is no automatic file-key, server-master-key or new-key fallback on failure.
The identity-proof-only BridgeIdentityVault is unchanged.

CellScaffold owns SQLite/SQLCipher sessions, handle shutdown, blind repository,
replay journal, recovery checkpoints and crash-safe multi-file root rotation.
Binding owns visible native approval. See CellProtocolDocuments Book 25 and
CellScaffold `Documentation/Cell_Database_Key_Custody.md` for operational guidance.

Validation on macOS: 32 focused CellProtocol contract/identity/security tests;
127 SQLCipher database/integration tests and 104 scaffold infrastructure regressions
in the consuming integration. Signed Binding builds. Real Keychain user-presence
acceptance is separate and cannot be inferred from these synthetic tests.
