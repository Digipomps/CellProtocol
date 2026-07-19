# Vapor identity vault offline inventory

`VaporIdentityVault.inspectAllExistingBindings()` is a migration and recovery
primitive. It returns the complete canonical set of persisted
UUID/context/signing-key-fingerprint tuples after authenticating the encrypted
vault. The projection grants no authority and contains no private key fields,
but it is operationally sensitive because it can correlate identity domains.

## Authorized execution boundary

Complete inventory is authorized only inside a deliberately offline
provisioning or recovery ceremony in which all of the following are true:

1. the serving application is stopped and remains stopped;
2. the inspection process has no application ingress or egress network path;
3. the operator holds the exclusive deployment and volume lock for the full
   inspection and any subsequent migration decision;
4. the encrypted vault and master key are opened from the intended volume with
   their production ownership and file-mode checks intact;
5. the returned `revision` is recorded and revalidated immediately before any
   later mutation; and
6. the output is written only to a restricted recovery artifact, never an HTTP
   route, ordinary log, metric, renderer, or user-facing diagnostic.

The method enforces only a process-local part of this boundary: it rejects a
vault instance after strict serving mode has been activated, authenticates the
entire encrypted file, rejects inconsistent key material, and performs no
write. It cannot prove that another process is stopped, that the caller holds
an exclusive host/volume lock, or that networking is disabled. The offline
provisioner and deployment procedure must establish those conditions before
calling it.

## Authority and failure semantics

- A tuple is inventory evidence, not an Agreement, Contract, capability,
  ownership proof, or authorization decision.
- No tuple may be selected, deleted, merged, or replaced merely because it is
  older, newer, first, last, or associated with a familiar context string.
- Missing vaults, tamper, duplicate UUIDs or contexts, incomplete key material,
  a serving runtime, or revision drift fail closed.
- Inspection must not create a vault, key, identity, alias, migration, or
  recovery result.
- Recovery needs a separately reviewed, explicit mutation plan bound to the
  exact inventory revision and independent identity-control evidence.

The Linux CI gate compiles the exact production `VaporIdentityVault.swift`
against the exact `CellBase` sources and runs the complete strict vault test
class. It intentionally excludes unrelated CellVapor files that require the
private FileUtils-c dependency; it neither stubs that dependency nor claims to
test the complete CellVapor product.
