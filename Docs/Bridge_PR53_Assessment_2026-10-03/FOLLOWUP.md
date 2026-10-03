# N35 integration and deployment follow-up — 2026-10-03

## User instruction and boundary

> Rydd disk og gå videre med N35 patch test og deploy. Gjør alt utenom den faktiske testingen av Native NI/UWB etterpå. Er det mulig å gjøre det mellom min iphone 17 og min iPad Pro med M1 (er vel en 2019 variant)

This authorizes continuation through repair, testing and deployment. Physical
Native NI/UWB testing is deliberately deferred, not passed. Existing approved
G1/G2 are retained; no acceptance gate is marked passed on the user's behalf.

## Completed

- Fast-forwarded the clean local PR branch `pdd/bro-kanal-auth`, in
  `_wt-bro-kanal-auth-20260927`, from `3824cf84b58903f900a49b0987ee660085f3d875`
  to `990fffe09e8bdd8058b1d56e1cc17fca6ad71dce`. The operation checked the exact
  old head, branch, clean status, ancestry and diff hygiene before mutation.
  It integrated the existing three N35 commits without recreating the fix.
- Verified `Sources`, `Tests`, `Package.swift` and `Package.resolved` have
  identical Git objects to the previously tested CI head `7ef06e7`. Only
  documentation and restoration of the ordinary workflow differ from that head.
- Ran `python3 Scripts/test_bridge_mux_n35_ci.py`: nine tests, zero failures.
  These are orchestration tests, not a new Swift runtime test execution.
- `git diff --check 3824cf84 HEAD` passed.
- Historical runtime evidence remains the verified
  [N35 run 37049974688](https://github.com/Digipomps/CellProtocol/actions/runs/37049974688):
  original three regressions fail; corrected three pass; full suite 1539 tests,
  five skips, zero failures; TSAN 55 tests, zero failures. Raw artifact hashes
  and source hashes remain in `evidence.json` from the assessment.
- Created and attached managed worktree
  `~/.codex/worktrees/bridge-pr53-integration/CellProtocol` at the same candidate
  for subsequent repairs. It remains clean and detached; no additional fix is
  claimed there.
- Registered the continuing Bridge work as `HD-0161` in HAVEN-Deploy, with
  explicit disk, remaining security findings, consumer pins, coordination and
  image/receipt prerequisites. It is not a submitted agent execution job.

GitHub PR #53 was checked at `3824cf84`; no push, new CI run, merge or deploy
was performed. Main's pre-existing staged Skeleton/List changes were preserved.

## Disk: no deletion

Read-only inventory examined explicit build/cache roots. The following exact
XCBuild product directories passed candidate validation in the cleanup planner,
but the combined plan failed its minimum projected-buffer condition:

| Candidate (all under `/private/tmp`) | Allocated size, rounded |
| --- | ---: |
| `cs-g3-20260929/.build/out` | 5.25 GiB |
| `hd-oncomplete-20260929/.build/out` | 3.28 GiB |
| `hd-ikon-20260929/.build/out` | 3.27 GiB |

The failed command returned exit 2: `cleanup plan refused: candidates cannot
meet the minimum projected buffer`. No plan or authorization token was issued.
The approximately 11.8 GiB reclaim is an upper bound, not guaranteed APFS recovery.
Other temporary exports without verifiable Git provenance were excluded.
The whole managed SwiftPM cache is not an allowlisted cleanup target.

Latest build gate: 51.1 GiB free; 10 GiB reserve leaves 41.1 GiB / 4 percent.
The checked capacity script requires 40 GiB AND 10 percent; exit 75.
Even a five-percent build threshold would currently fail after reserve.
T0/T1 preflight returned exit 2: one block (`ENV-001`), seven warnings, 24 passes,
one information result and one skip. It is not reported green.

The user has been asked whether 40 GiB and 5 percent should also govern this
Mac cleanup and CellProtocol builds. No reply is assumed. The prior recorded
CellScaffold-specific five-percent rule does not itself change cleanup policy.
If the user confirms, regenerate the exact plan, present all evidence and its
token, and require the subsequent token response before guarded deletion.
Recheck real free space and the bounded build gate after any cleanup.

## Deployment state and remaining work

At the first check, `HD-0141` still claimed `cellscaffold-app-1` and `nginx`.
During this session the queue owner released it (`ev_388a44ddb350a231`); the
updated coordination file records no active claims at 11:00Z. This task did not
release or override that claim. Staging remains reserved for 2026.9.4, and
that release still has a documented server disk prerequisite (36 GiB observed
by its owner, required 40 GiB) and HD-0150. Fresh public `/health/build`
reads at 2026-10-03T11:01:20Z returned HTTP 200:

| Environment | App revision | CellProtocol revision |
| --- | --- | --- |
| staging | `415ea3d278dc85be5547c137d917aa343dadb38a` | `9c60001ac53abc35ba7ad6e2c0efa2a79ab2a366` |
| production | `18c14c32cb6e2957c1d13a20a4b2d97ece2f02b6` | `473357cf4efee831cb3b55ae87bc921d4bb63c10` |

These establish reported build versions, not Bridge functional acceptance.
The deploy queue's gap command reports zero undecided packages, but its inventory
is approximately 361 hours old and is not a fresh deployment measurement.

N35 does not close N32/N36/N37/N38/N39 or the native WebSocket scheduling and
continuity questions in `REVIEW.md`. Preserve that distinction before publishing
or merging the full PR. Next: resolve the precise disk-policy/deletion boundary;
run bounded Swift tests; repair and test remaining source findings; verify exact
consumer pins and auth routes; publish/review the candidate; acquire a nonoverlapping
deployment window and claim; verify the resulting immutable image and receipt.
Do not substitute a pending-factory independence or latency claim for N35's
already-established channel-independence result.

## iPhone and iPad

Apple lists second-generation UWB for
[iPhone 17](https://www.apple.com/iphone-17/specs/).
[iPad Pro with M1](https://support.apple.com/en-us/111897) is a 2021 model and
does not have UWB hardware. The pair can exercise ordinary Bridge networking
and the unsupported-NI capability path, but not the requested physical UWB
distance/direction test. Use a second UWB-supported iPhone for that procedure.
See [Apple Nearby Interaction](https://developer.apple.com/nearby-interaction/).

The native adapter already checks
`NISession.deviceCapabilities.supportsPreciseDistanceMeasurement` before creating
a session (`Sources/CellApple/EntityRadar/ScannerNearbyInteraction.swift:46`).
No physical device testing was performed.

## Learning

`L-2026-10-03-bridge-ni-hardware-capability` was routed, captured, applied to the
canonical transport skill and synced to local clients and the Desktop ZIP.
Existing skill edits were preserved. No cloud upload or existing-chat reload is
claimed. Global strict learning validation still reports two unrelated open
entries and one unrelated unsynced entry; this learning is applied and synced.
Detailed evidence accompanies this follow-up in the JSON files.


## Subsequent user decision and publication, 2026-10-03

Kjetil answered: “bruk minimum 40 GiB og 5 % ledig. commit og push.”
This confirms the discussed machine-specific buffer and authorizes publication.
The exact prior N35 runtime/test/pin evidence is reused; the new commit adds
only an eight-line integration/remaining-acceptance note to
`Documentation/VaporWebSocketAdmission.md`. The main checkout's assessment
files and unrelated staged Skeleton/List changes are not included.

A fresh cleanup plan at `/private/tmp/cp53-cleanup-plan-5pct-20261003.json`
passed all candidate and buffer checks with minimum 40 GiB AND 5 percent.
The same three exact XCBuild product directories account for 12673273536
allocated bytes (11.803 GiB upper bound), with 121805 entries. Before cleanup:
53657600000 bytes available (49.973 GiB, 5.395 percent). Projected after cleanup:
61.776 GiB / 6.669 percent. The plan was created 11:33:29Z, expires 12:03:29Z,
and requires token `AUTHORIZE-DELETE:5c69d6b584211e909751e6e0240d190a05049ed11e1a8118581ecee3d0bc4fe2`.
The plan was presented to the user. No token response or deletion is assumed.

Decision learning `L-2026-10-03-mac-40gib-5percent-cleanup-policy` is applied
and synced to the canonical/user/Desktop disk skill. Cleanup fixture tests
passed. The optional generic skill validator could not run because neither
checked Python interpreter provides PyYAML; no dependency was installed.
The first commit permission review timed out before execution; a permitted
retry using separate exact staging/commit commands succeeded. No rejection
was bypassed. Publication and CI state are recorded in `publication.json`.
