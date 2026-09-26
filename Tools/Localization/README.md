# Skeleton localization

Shared FormatJS runtime for CellScaffold/web and CellApple/Binding, with a versioned JSON catalog and explicit Skeleton text bindings. This is the first renderer increment; see `../../Docs/Localization_Implementation_Status_2026-09-07.md` for verified scope and remaining work.

From this directory:

```sh
npm ci --ignore-scripts
npm test
npm run build
node validate.mjs ../../fixtures/localization/skeleton.json
```

`build.mjs` produces the bundled JavaScript and license notices in `Sources/CellApple/Resources`. Copy those two generated files to `CellScaffold/Public/js` together when updating the companion web renderer. The files must be byte-identical across hosts. No CDN or remote evaluator is involved; catalogs and arguments cross the bridge as JSON data.

`fixtures/localization/messages.json` is the shared formatter corpus; `skeleton.json` is a full authoring/demo fixture with extra `testData` and `testContract` used by tests, not production endpoints. The native test mounts the canonical SwiftUI Skeleton renderer, captures English/Norwegian screenshots and inspects accessibility. Web tests include Porthole bootstrap/catalog refresh, editable drafts, in-flight actions, plain text safety, formatter reuse and 1000 list items.

The optional ICU probes are experiments, not a Linux production backend. `probe-icu.cpp` uses public ICU4C; `probe-icu.swift` drives the nonfallback corpus. Current ICU 74.2/Linux and 78.3/macOS differ from the browser/Apple bundle in the English short-time separator (U+202F versus U+0020). Keep that difference visible instead of normalizing evidence to claim exact parity.

Dependencies are pinned in `package-lock.json`. `THIRD_PARTY_NOTICES.md` is copied into both distributed resource directories; review it along with dependency updates. Runtime caches hold compiled messages/Intl formatters (bounded to 256 entries each), not formatted private argument values. Each host owns its catalogs, argument snapshot, context and diagnostics. Discard that scope when switching owner.
