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

## Requester refusal before readiness

Requester-bearing GeneralCell entry points reject a presented owner UUID with
an unequal or missing signing-key fingerprint before `ensureRuntimeReady()`.
The preflight first preserves the existing IdentityLinkRegistry route: an
active, same-entity, local-anchor link matching requester UUID, signing key,
Cell domain and scope must also pass `checkIdentityOrigin` against the linked
public descriptor. A registry hit without key control is insufficient.

Without that proof, preflight constructs an explicit `allowed=false` decision
with path `deniedIdentityReferenceMismatch`, records `authorizationDenied`, and
throws `CellAuthorizationError.denied`. It does not call the general policy
selector, so `debugValidateAccessForEverything` cannot disable this refusal.
No runtime binding hook or requested state mutation runs for this request.

Covered entry points are get, set, keys, typeForKey, contract,
operationContracts, schemaDescriptionForKey, flow, advertise, state, attach,
absorbFlow, admit and addAgreement (both requester and authorizing identity).
Nonthrowing admit/addAgreement retain `.denied`/`.rejected` and record the typed
security event. Attach/absorb retain their lifecycle access checks after
preflight. A verified owner, a proven link, and another UUID continue through
normal readiness and subsequent authorization; preflight grants no access.
A permitted link does not repair a missing runtime owner's home vault.
Fresh link completion rejects equal issuer/holder UUIDs (`sameKeyOnBothSides`);
coverage of a same-UUID link uses the separate trusted registry restore path,
not a newly accepted enrollment. Restore callers remain responsible for record
provenance validation.

The no-requester `ensureRuntimeReady()` API remains a trusted runtime boundary.
Subclass overrides that do not call these GeneralCell entry points, direct
runtime access and remote transports require their own verification. This
ordering fix is not evidence of universal attacker exclusion or deployment.
Local execution evidence and exact revision are in the a35 release handoff.
