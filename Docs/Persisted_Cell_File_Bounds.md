# Persisted Cell file bounds

Status: production hardening contract
Scope: `FileSystemCellStorage` in CellApple and CellVapor

## Purpose and invariant

`purpose://access.audit.privacy` requires persisted Cell state to fail closed
when the local disk contains an unexpected file. A corrupt or adversarial
`typedCell.json` must not cause an unbounded allocation before decryption or
JSON decoding.

Both file-system stores therefore use the same descriptor-based reader. It:

- opens the final path with `O_NOFOLLOW` and rejects non-regular files and
  multiply-linked files;
- validates `fstat` size on that exact descriptor before reserving memory;
- reads in bounded chunks from the same inode and detects growth after the
  metadata check;
- exposes only stable error cases, never a path or stored contents.

## Compatibility limit

The maximum on-disk `typedCell.json` size is **67,108,864 bytes (64 MiB)**.
The limit applies after optional encryption, including the encrypted envelope.
It leaves substantial headroom for ordinary JSON state and is not a wire-format
change. Writes above the same limit are refused so a runtime cannot create a
file that it will reject on restart.

Before rollout, operations must run a size-only inventory over the target
volume while the service is quiesced. Any existing regular `typedCell.json`
above 64 MiB blocks rollout and requires an explicit migration/capacity review;
the file must never be truncated or silently skipped.

Raising this limit is a compatibility and capacity decision. It requires a
measured legitimate payload, bounded-memory tests at the new exact boundary,
and an operations review; it must not be made dynamically from untrusted Cell
metadata.

## Residual boundary

`CellStoragePathPolicy` confines and resolves the Cell directory before the
reader opens the final filename. The descriptor prevents a final-file symlink
swap, but an actor able to rewrite ancestor directories concurrently remains a
stronger local-compromise scenario. Deployment permissions must therefore keep
the storage root writable only by the runtime identity. A future descriptor-
relative `openat` walk can harden that ancestor-directory race without changing
the persisted format.
