# Vault idea retention v1

A newly created note tagged `idea` receives the owner's default TTL (initially
seven days). Existing notes are not enrolled on load or sweep. The owner can set
an existing note's TTL explicitly. Allowed TTLs are 1–3650 days.

The owner can configure the default, set a deadline from now, touch, restore,
and protect through the `vault.retention.*` and `vault.note.retention.*` set
contracts. Activity adds one day at most once per day. Reading is not activity.
Quarantine inspection does not restore; explicit restore or setting TTL grants
a full new TTL. The recovery interval is seven days starting when a sweep first
quarantines a note, so downtime cannot skip the recovery period.

Protection is monotonic. Vault links protect both ends under the same lock as
sweeps. Project stage also protects. External Todo/project/work-item writers
must successfully register `vault.note.retention.protect` before writing their
reference. The owner coordinator reconciles existing external references and
calls sweep with `externalDependenciesChecked: true` and the exact refreshed
`checkedStateVersion`. Unknown/unavailable dependency sources must block purge.
A stale local scan is rejected. This is an owner-coordinated local contract,
not a distributed transaction across arbitrary clients.

Sweep removes eligible notes from the canonical note collection and retains
minimal ID tombstones to prevent stale recreation. It emits a versioned Vault
mutation without deleted content. Existing mutation history, snapshots, shared
copies and backups retain their prior retention policies; this does not claim
cryptographic erasure or removal from remote replicas. A coordinated replica
policy would be additional work.

All lifecycle state is Codable beside the existing note store. Old Vault
snapshots decode with an empty retention registry. Mutations and encoding share
a recursive storage lock; sweeps never run from get/Explore. Retention mutation
requires the existing Vault write grant and the actual owner identity. It does
not expand a collaborator's delete authority.

Persistent Vault mutations now serialize through a mutation gate and verify a fresh storage read before returning success. Failure returns `vault_snapshot_unverified` with `appliedInMemory: true`; it does not claim rollback.
