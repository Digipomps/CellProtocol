---
name: cellprotocol-contract-testing
description: Use when writing, reviewing, or debugging HAVEN/CellProtocol contract tests, golden fixtures, replay determinism tests, resolver policy tests, skeleton encode/decode parity tests, ContractProbeCell checks, FlowProbeCell checks, state snapshots, or cross-runtime compatibility fixtures.
---

# CellProtocol Contract Testing

Use this skill when the task is to prove that an implementation still behaves
like CellProtocol, especially across cells, runtimes, transports, or languages.

## Core Rules

- Tests should protect protocol behavior, not just implementation details.
- Prefer deterministic fixtures and explicit assertions over screenshots or
  log-reading unless the task is UI/runtime specific.
- Every stable wire or JSON shape needs a golden fixture or an equivalent
  round-trip test.
- Replay tests must assert same input plus same history gives same output.
- Resolver tests must prove both allowed and rejected paths.
- Policy rejection is a first-class success case; test it directly.
- Cross-runtime fixtures must avoid Swift-only assumptions unless the fixture is
  explicitly Swift-specific.

## Read First

Pick the smallest relevant set:

- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/01_CellProtocol_Core.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/05_Flows_Lifecycle.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/06_CellResolver.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/12_Skeleton_Spec.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Docs/Cell_Contract_Testing_Architecture.md`

Useful source/test areas:

- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Sources/CellBase/Cells/Testing`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Tests/CellBaseTests`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Tests/HavenCommonsTests`

## Test Categories

- Interface contract: `Emit`, `Absorb`, `Meddle`, `Explore`.
- Resolver policy: identity, capability, condition, contract, target lookup.
- Replay determinism: ordered flow, reconstructed state, duplicate/reorder
  handling where supported.
- Flow payload stability: topics, IDs, timestamps/sequence rules, value shapes.
- CellConfiguration: decode/encode, reference resolution, discovery fields.
- Skeleton: wrapper form, legacy decode, canonical encode, element limits.
- Diagnostics: ContractProbe, FlowProbe, state snapshot records.
- Cross-language: JSON fixtures and expected decisions independent of Swift
  implementation details.
- Cross-runtime JSON fixtures must live at a path accessible to both Swift and
  target-language tests, such as a `fixtures/` directory in the CellProtocol
  root or a documented path in `CellProtocolDocuments`. Do not inline a fixture
  in one language and call it cross-runtime coverage.

## Required Workflow

1. Name the invariant being protected.
2. Find an existing test pattern before adding new infrastructure.
3. Create fixtures with explicit names and stable JSON ordering where possible.
4. Test positive and negative paths when a policy decision is involved.
5. Keep failure output useful: include keypath, endpoint, capability, expected
   decision, and actual decision.
6. Run the narrowest relevant test target first; then run broader suites when
   touching shared protocol or resolver behavior.
7. If a test documents current limitations, name the limitation in the test.

## Must Not

- Do not bless accidental Swift encoding quirks as protocol without checking
  docs or current cross-runtime intent.
- Do not weaken tests to match broken behavior unless the user explicitly asks
  for a known regression marker.
- Do not rely on wall-clock time when deterministic sequence/time inputs can be
  injected.
- Do not skip rejection tests for security-sensitive paths.

## Completion Checklist

- The invariant is named in test names or comments.
- New/changed tests fail for the bug or missing behavior they protect.
- Golden fixtures are stable and minimal.
- Swift tests were run or the reason they could not run is reported.
- Any required docs or fixture updates are called out.
