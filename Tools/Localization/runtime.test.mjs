// SPDX-License-Identifier: Apache-2.0
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRuntime, resolveLocale, acceptedLanguages, validateDescriptor, validateSlots } from "./runtime.mjs";

const fixture = JSON.parse(readFileSync(new URL("../../fixtures/localization/messages.json", import.meta.url)));
const descriptor = (key, args = {}) => ({ namespace: "demo", key,
  arguments: Object.fromEntries(Object.entries(args).map(([name, value]) => [name, { value }])) });

for (const sample of fixture.cases) {
  test(`shared fixture: ${sample.id}`, () => {
    const runtime = createRuntime({ configuration: fixture.configuration, context: { ui_locale: sample.locale } });
    const result = runtime.resolve(descriptor(sample.key, sample.arguments), "Legacy");
    assert.equal(result.text, sample.expected);
    assert.equal(result.fallback_reason, sample.fallbackReason);
    assert.equal(result.resolved_locale, sample.fallbackReason ? null : sample.locale);
  });
}

test("argument and locale updates reuse compiled messages without persisting formatted private data", () => {
  const runtime = createRuntime({ configuration: fixture.configuration, context: { ui_locale: "en-US" } });
  const reference = { namespace: "demo", key: "count", arguments: { count: { scope: "root", keypath: "demo.count" } } };
  runtime.setRootData({ demo: { count: 1 } });
  assert.equal(runtime.resolve(reference).text, "1 track");
  runtime.setRootData({ demo: { count: 5 } });
  assert.equal(runtime.resolve(reference).text, "5 tracks");
  assert.equal(runtime.getMetrics().compilations, 1);
  runtime.setContext({ ui_locale: "nb-NO" });
  assert.equal(runtime.resolve(reference).text, "5 spor");
  runtime.setContext({ ui_locale: "en-US" });
  assert.equal(runtime.resolve(reference).text, "5 tracks");
  assert.equal(runtime.getMetrics().compilations, 2);
});

test("localized item values have deterministic fallback and no guessed language for legacy text", () => {
  const runtime = createRuntime({ context: { ui_locale: "en-US" } });
  const reference = { valueKeypath: "localizedLabel", scope: "item" };
  const scopes = { item: { localizedLabel: { values: { "nb-NO": "Musikk", fr: "Musique" } } } };
  const result = runtime.resolve(reference, "Old name", scopes);
  assert.equal(result.text, "Musikk"); assert.equal(result.resolved_locale, "nb-NO");
  assert.equal(result.fallback_reason, "translation_fallback");
  assert.equal(runtime.resolve(reference, "Unknown language").resolved_locale, null);
  assert.equal(runtime.resolve({ valueKeypath: "constructor.name", scope: "item" }, "Safe").text, "Safe");
});

test("unapproved translations cannot masquerade as released translations", () => {
  const config = structuredClone(fixture.configuration);
  config.resources[0].messages.title.translations["en-US"].state = "draft";
  const runtime = createRuntime({ configuration: config, context: { ui_locale: "en-US" } });
  const result = runtime.resolve(descriptor("title"));
  assert.equal(result.text, "Musikkstudio"); assert.equal(result.resolved_locale, "nb-NO");
});

test("catalog replacement is atomic, checks revision, and isolates accepted resources from later mutation", () => {
  const config = structuredClone(fixture.configuration);
  const runtime = createRuntime({ configuration: config, context: { ui_locale: "en-US" } });
  config.resources[0].messages.title.translations["en-US"].value = "Modified after admission";
  assert.equal(runtime.resolve(descriptor("title")).text, "Music studio");
  config.catalogs[0].revision = "2";
  assert.throws(() => runtime.setConfiguration(config), /revision mismatch/);
  assert.equal(runtime.resolve(descriptor("title")).text, "Music studio");
  assert.throws(() => runtime.setContext({ ui_locale: "en-US", timeZone: "invalid-zone" }));
  assert.equal(runtime.getContext().timeZone, "UTC");
});

test("scoped arguments never inherit properties and distinguish raw user text from references", () => {
  const runtime = createRuntime({ configuration: fixture.configuration, context: { ui_locale: "en-US" } });
  const reference = { namespace: "demo", key: "greeting", arguments: { name: { scope: "item", keypath: "name" } } };
  assert.equal(runtime.resolve(reference, "Safe", { item: Object.create({ name: "Inherited" }) }).text, "Safe");
  assert.equal(runtime.resolve(null, "demo.title").text, "demo.title");
  assert.equal(validateDescriptor({ namespace: "demo", key: "title", valueKeypath: "name" }), "mixed localization forms");
  assert.match(validateSlots("TextField", { text: descriptor("title") }), /unsupported/);
  assert.equal(validateSlots("TextField", { placeholder: descriptor("placeholder") }), null);
});

test("owner preference, language tags, surface selection and environment have one ordered policy", () => {
  assert.equal(resolveLocale({ entityLocale: "en-GB", selectedLocale: "nb-NO", languages: ["nb"] }).ui_locale, "en-US");
  assert.equal(resolveLocale({ entityLocale: "invalid_tag", languageTags: ["nn", "en"] }).ui_locale, "en-US");
  assert.equal(resolveLocale({ selectedLocale: "en", languages: ["nb"] }).locale_source, "surface");
  assert.equal(resolveLocale({ languages: ["no"] }).ui_locale, "nb-NO");
  assert.equal(resolveLocale({ languages: ["nn"] }).locale_source, "default");
  assert.equal(resolveLocale({ languages: ["zh-Hant"], supportedLocales: ["zh-Hans", "nb-NO"] }).ui_locale, "nb-NO");
  assert.deepEqual(acceptedLanguages("nb;q=0,en-GB;q=0.9,fr;q=0.9,de;q=2,en;q=0.1234"), ["en-GB", "fr"]);
  assert.equal(resolveLocale({ acceptLanguage: "nb;q=0.1, en;q=0.9" }).ui_locale, "en-US");
  assert.equal(resolveLocale({ acceptLanguage: "nb;q=0, *;q=1" }).ui_locale, "en-US");
  assert.equal(resolveLocale({ acceptLanguage: "en;q=0, en-US;q=1" }).ui_locale, "en-US");
  assert.equal(resolveLocale({ acceptLanguage: "*;q=0, en;q=1" }).ui_locale, "en-US");
});

test("approval tied to an earlier source hash is rejected", () => {
  const config = structuredClone(fixture.configuration);
  config.resources[0].messages.title.source_hash = "new-source";
  config.resources[0].messages.title.translations["en-US"].source_hash = "old-source";
  assert.throws(() => createRuntime({ configuration: config }), /stale translation approval/);
});

test("two hosts retain independent locale, data and cache state", () => {
  const a = createRuntime({ configuration: fixture.configuration, context: { ui_locale: "nb-NO" } });
  const b = createRuntime({ configuration: fixture.configuration, context: { ui_locale: "en-US" } });
  assert.equal(a.resolve(descriptor("title")).text, "Musikkstudio");
  assert.equal(b.resolve(descriptor("title")).text, "Music studio");
  a.clear();
  assert.equal(b.resolve(descriptor("title")).text, "Music studio");
});
