# EntityAnchor side-file encryption

Apple and Vapor use the same `EntityAnchorPersistence` codec for
`keypathstorage.json` and `entity-authority-journal.json`. The Agreement's
lifecycle policy determines encryption, defaulting to required when absent or
invalid, as for resolver snapshots. Required encryption fails if no master key
is available. There is no automatic plaintext fallback.

Ciphertext is bound to the Cell UUID, filename and owner. Files cannot be moved
between Cells or substituted between journal and snapshot. Atomic file writes
retain the existing journal-before-snapshot commit order, signature verification
and replay behavior. This remains a local authority commit, not quorum or
distributed durability.

On successful loading, valid legacy plaintext files are atomically encrypted
after their Entity/journal content and authority receipts have been validated.
An invalid file or failed decryption is retained and blocks subsequent writes.
A partial migration remains readable on restart. This does not erase old disk
blocks, snapshots or backups; their retention remains a host responsibility.

Hosts must configure the existing scoped secret provider or persistence master
key before constructing EntityAnchor directly. Resolver creation now restores
the key before invoking the Cell initializer. Existing test hosts explicitly
provide synthetic keys. No real personal files are used by regression tests.

Legacy readers cannot read these encrypted side files. Upgrade readers together
with writers; keep the durable master key available across restarts. An explicit
`ColdStorageCondition(encryptedAtRestRequired: false)` still permits plaintext;
this is trusted host policy, not an implicit downgrade when encryption fails.
