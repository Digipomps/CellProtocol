# Storage-root aliases and missing descendants

On macOS, Foundation standardizes an existing `/private/tmp/...` root to
`/tmp/...`, but may leave a not-yet-created descendant under `/private/tmp`.
The previous string-prefix check could therefore reject creation of a valid
Cell below an existing root. This reproduced while starting the actual
CellScaffold browser fixture.

CellStoragePathPolicy now first checks lexical containment without filesystem
alias rewriting, then uses `realpath` on each existing prefix and appends only
missing descendants. Permission errors, symlink loops and dangling symlinks
fail closed. The second check still rejects symlinks escaping the storage root;
an external symlink pointing inward does not bypass the first check.

The macOS/Linux tests cover root creation before/after lookup, nested missing
children, filenames, traversal, prefix lookalikes, inward aliases, external
aliases and dangling/outward links. Existing path validation remains intact.
This is a path-validation boundary, not descriptor-relative filesystem access:
the host must prevent untrusted processes from changing its storage directories
or symlinks concurrently with a write.
