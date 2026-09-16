# Skeleton localization — implementation checkpoint

Updated 2026-09-07. Kjetil authorized implementation after the plan was written. First working renderer increment is implemented locally; **the full S0–S6 plan is not complete**. No commits, pushes or deployments.

Primary report:
`CellProtocolDocuments/Deliverables/Lokalisering_Analyse_2026-09-07/IMPLEMENTERINGSSTATUS.md`, with durable evidence alongside it.

## Implemented

- Additive configuration/modifier metadata and typed catalogs, bindings and resolved text in `Sources/CellBase/Skeleton/SkeletonLocalization.swift`; legacy strings/actions/editable values unchanged.
- Shared FormatJS runtime and pinned tooling under `Tools/Localization`, fixtures in `fixtures/localization`.
- Identical generated ~43 KB formatter and license notices in CellApple Resources and CellScaffold Public/js; rebuild with `npm run build` under Tools/Localization and copy both resources together.
- Public JavaScriptCore Apple adapter; Text/Button/TextField/TextArea placeholder integration in the canonical SkeletonView used by Binding.
- PortholeViewModel configuration, locale, deduplicated authorized root argument snapshot loading and requester-change clearing. Language switching does not set skeleton or localMutationVersion. Root projection excludes item/context/action-payload data.
- CellScaffold renderer locale/catalog updates without DOM remount, atomic revisions, plain text safety, cache reuse; Porthole bootstrap normalization and catalog revision tracking. Chat/conference pass configuration and browser context too.
- Binding ContentView config forwarding on load/config changes/rebuild.
- Authoring validator; Explore root-binding collector; Book 12/22 actual-supported-scope documentation.

## Verified

32 Node tests; 15 Swift localization/action tests; 11 CellScaffold projection tests; 22 Playwright localization/Porthole/legacy regression tests; Python Explore suite 11 passed/1 skipped; Binding macOS unsigned build succeeded. Shared 22-case corpus matches Node/Chromium/Apple. Hosted SwiftUI test inspects real accessibility and captures nb/en screenshots, preserving the draft, selection and input identity.

ICU4C experiments: macOS ICU78.3 and Linux ICU74.2 both exact19/20. Only English short time differs by U+202F versus U+0020. Linux C++ probe ran directly under Docker; the emulated Swift interpreter hung and was not counted as passing. The task-specific container was stopped. No Linux production adapter exists yet.

## Next work, in order

1. S2 owner preference load/store and visible selection/save errors, native request-source provenance, application owner-switch integration coverage.
2. Complete S3 with a reusable demo/test Cell exposing actual Explore contracts and actions; native remote Flow snapshot refresh. Current GeneralCell intercepts/mock resolver and browser handler prove rendering but do not implement that product/demo Cell.
3. S4 remaining slots (Picker/Tabs/Toggle/options/nav/upload/accessibility/system messages), extraction/translation workflow, editor preview/commit/clone/publish preservation.
4. S5 real app user path, native performance and paint/layout timings, mobile/long text/third-language/RTL/rollback.
5. S6 Butterpop, then info pages and Interest/Purpose migration. None is translated by this increment.

Only Text.text, Button.label, TextField.placeholder and TextArea.placeholder are currently admitted. Data label descriptors work through those slots. Do not claim the planned full slot set, owner preference persistence or Linux runtime is finished.

## Working tree and recovery

Companion files are already applied to the live repos. Do **not** reapply `/private/tmp/haven-localization-{scaffold,binding,docs}/changed` wholesale: those were intermediate preparations and some are stale. Work from current source and the report's evidence/source manifest.

All repositories had unrelated dirty files. Preserve them. CellProtocol Package.swift already contained ReferenceLoadBenchmark; CellResolver.swift, SkeletonStyleParity.swift and several new cells/tests/worktrees were unrelated. CellScaffold porthole-webo.js and Binding ContentView.swift included substantial existing changes, preserved by exact-baseline checks. Documents book_catalog.json and other indexes/site content were already dirty. Book filenames/catalog entries are unchanged by the appended specification sections.

Relevant temporary logs: `/private/tmp/haven-localization-{node-tests,swift-tests,scaffold-swift,live-playwright,explore-tests,binding-build}.log`. Tests redirect there; durable report evidence retains concise summaries and hashes. The native harness uses a process-scoped AppKit enhanced-accessibility flag (restored after test) to materialize SwiftUI accessibility; it does not change system settings.

Suggested commands:

```sh
npm test --prefix Tools/Localization
node Tools/Localization/validate.mjs fixtures/localization/skeleton.json
swift test --skip-update --jobs 4 --filter 'SkeletonLocalizationTests|SkeletonActionButtonExecutionTests'
# In CellScaffold:
swift test --skip-update --jobs 4 --filter PortholeBootstrapProjectionTests
# In Binding:
xcodebuild -workspace Binding.xcworkspace -scheme HAVEN -destination 'platform=macOS,arch=arm64' -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build
```

The Playwright command/config is captured in the evidence manifest; it selects localization plus atomic-render/navigation/textarea regressions and does not start production services.
