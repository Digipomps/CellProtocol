# Runtime binding refusal diagnostics

Last verified against code: 2026-10-07 (GeneralCell; execution evidence in release handoff).

Setup authorization remains unchanged: an active instance-bound runtime token,
or the matching owner with successful `checkIdentityOrigin`, is required.
Decoded identities carry no vault; restore runtime handlers through
`ensureRuntimeReady()` and `installCellRuntimeBindingsForAccess()`.

Every denied setup operation records an in-memory row in
`registeredKeypathAudit().refused`: `key`, `operation`, `condition`,
`requesterUUID`, and `runtimeToken`. Conditions distinguish
`requesterNotOwner`, `identityMissingVault`, and `signatureProofFailed`.
`runtimeToken=missingOrUnauthorized` describes why the runtime exception did not
apply. Key denotes the keypath/topic, never cryptographic key material.
The refusal line includes cell type and UUID and is emitted even when diagnostic
domains are disabled, through the configured diagnostic handler or stdout.
Values, signing keys, token contents and signatures are not emitted.

Audit `ok` is false while any historical refusal is retained, even if a later
installation succeeds. Rows are process-local diagnostics, not persisted state
or a protocol flow/wire-format migration. No reset API is introduced.

`ensureRuntimeReady()` throws `CellRuntimeBindingError.setupRefused` if the
cell's refusal count increases while its installation hook runs. The readiness
coordinator does not mark such an installation complete and permits retry.
This conservatively includes concurrent denied setup on that same cell.
A child task that finishes after the hook returns is outside this interval;
subclasses must await their binding work inside the hook.

The setup methods retain their existing non-throwing APIs. Changing them to
`throws` would require migrating existing cell implementations and asynchronous
initializers. The additive audit plus the already-throwing readiness boundary
provides the operational failure without that source compatibility change.
