# Registered job artifact metadata — HD-0154

This is an opt-in local collector. It is not installed or enrolled by copying
source into a checkout. The owner must enroll one private configuration per host
and storage identity, and separately authorize a GraphStore target for upload.
No file content, prompt, environment or command line is read into the journal.

The collector stores append-only events in a private SQLite journal, with an
explicit owner/host binding, full synchronous transactions and a page limit.
`snapshot` deterministically replays the journal. Nothing deletes or truncates
the journal automatically. A full journal rejects new events and the caller must
report degraded provenance. Terminal failures leave the attempt active, which
blocks cleanup classification.

Configuration (example identifiers and paths; do not install unchanged):

```json
{
  "schema": "haven.artifacts.v1",
  "ownerRef": "OWNER-IDENTITY-UUID",
  "hostID": "OWNER-SCOPED-HOST-ID",
  "spool": "/owner-private/artifact-journal",
  "roots": [
    {"path": "/enrolled/job-root", "volumeID": "ENROLLED-VOLUME-ID", "device": 123}
  ],
  "maxEntries": 2000,
  "maxJournalBytes": 67108864
}
```

The configuration must be mode 0600 and the existing spool directory 0700,
owned by the executing OS user. Enroll canonical paths without symlinks.
`device` is the enrolled root's `os.stat(root).st_dev`; a different device stops
traversal and produces a coverage gap. `volumeID` is the owner's stable volume
reference, not a device number reused as a permanent identity. Re-enrollment is
required after a mount/device change. No automatic OS-wide scan is performed.

```sh
/usr/bin/python3 Scripts/haven_artifacts.py --config /owner-private/config.json \
  start --job registered-job-id --project registered-project-id --path /enrolled/job-root
# Save the returned attempt UUID before running the registered job.
/usr/bin/python3 Scripts/haven_artifacts.py --config /owner-private/config.json \
  created --attempt ATTEMPT-UUID --path /enrolled/job-root/new-directory
/usr/bin/python3 Scripts/haven_artifacts.py --config /owner-private/config.json \
  finish --attempt ATTEMPT-UUID --result succeeded
/usr/bin/python3 Scripts/haven_artifacts.py --config /owner-private/config.json snapshot
```

`snapshot` emits one complete UTF-8 JSON frame, including its trailing newline,
bounded to 256 KiB by default. `--max-bytes` accepts 1024 through 4194304 bytes.
Oversized output returns exit 2, an empty stdout and a fixed `snapshot_too_large`
message; it neither trims records nor deletes journal events. The sender must
still drain subprocess output while it runs, account for transport-envelope
overhead and retain pending status until a matching durable receipt arrives.
This collector does not make network requests. A bounded snapshot is not proof
of enrollment, a remote grant, or an implemented background sender.

`created` is a declaration by the registered writer immediately after it creates
the exact path; recursively inventoried children remain observations. The writer
must not call it for existing files. `recover --result interrupted` closes only
the specified attempt after its owning job runner has established interruption.
`finish` also accepts `failed`, `cancelled` and `interrupted`. Identical terminal
retries are idempotent; changing the result of a terminal attempt is rejected.

For bounded Swift jobs, set `HAVEN_ARTIFACT_CONFIG` to the enrolled configuration.
Optional `HAVEN_ARTIFACT_JOB_ID` and `HAVEN_ARTIFACT_PROJECT_ID` provide registered
identifiers; otherwise the lease attempt and stable cache key are recorded.
Install `haven-swiftpm.sh`, `haven-artifacts-hook.sh` and `haven_artifacts.py`
together. Collection failure does not change the build's exit code. Existing
lease, capacity and cache-deletion policies remain the runner's responsibility.

## Evidence limits

- Start/end inventories always say **partial**, including when every visited
  directory was readable. Transient files and outside-scope writes can be missed.
- Inventory does not prove creation or use of individual children. Only the
  registered job root has `usedBy`; children have `observedDuring`.
- Birth time is used when exposed by Python's stat result. Without it, changed
  ctime starts a new observation generation; the collector does not claim a
  stable identity through arbitrary inode reuse, moves or modifications.
- Directory size is zero here. This is per-file metadata, not a recursive `du`
  total. Hardlinks/reflinks require volume-aware accounting before summing disk
  usage. The first Workbench view must not present an aggregate reclaimed size.
- Disappearance is `not_observed`, not proof of deletion. Replaced paths keep
  their old generation as `replaced`.
- TTL, dependencies, open processes, live leases, mounts and Git/recovery state
  are not certified by inventory. Terminal files stay **unknown**; there is no
  delete command or eligible-for-cleanup state in this collector.
- Local replay is implemented. Automatic signed upload/reconnect, journal
  compaction, Linux end-to-end and full Workbench verification remain release
  gates in HD-0154. Do not claim that source changes are deployed.

## Local tests

`python3 -B Scripts/test_haven_artifacts.py -v` exercises capture, scope,
owner/host binding, replay, rollback, symlinks, partial coverage and fake build
failures. `bash Tests/Scripts/HavenSwiftPMRunnerTests.sh` exercises existing lease
and GC semantics using generated test fixtures and a fake Swift executable.
Neither test invokes a real Swift build or touches production caches.
