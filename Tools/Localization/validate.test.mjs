// SPDX-License-Identifier: Apache-2.0
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { validateConfiguration } from "./validate.mjs";
const fixture = JSON.parse(readFileSync(new URL("../../fixtures/localization/skeleton.json", import.meta.url)));

test("authoring validation accepts legacy and the shared localization fixture", () => {
  assert.deepEqual(validateConfiguration({ skeleton: { Text: { text: "Legacy" } } }), []);
  assert.deepEqual(validateConfiguration(fixture), []);
  assert.deepEqual(validateConfiguration({ skeleton: { Button: { label: "Save", keypath: "demo.save", payload: {
    modifiers: { localization: { text: { valueKeypath: "demo.actionData" } } } } } } }), []);
});
test("authoring validation reports unsupported fields, malformed ICU and undeclared arguments", () => {
  const config = structuredClone(fixture);
  config.skeleton = { TextField: { modifiers: { localization: { text: { namespace: "demo", key: "title" } } } } };
  assert.match(validateConfiguration(config).join("\n"), /unsupported TextField/);
  config.localization.resources[0].messages.count.translations["en-US"].value = "{count, plural, one {one}}";
  assert.match(validateConfiguration(config).join("\n"), /demo.count\/en-US/);
  config.localization.resources[0].messages.count.translations["en-US"].value = "Hello {undeclared}";
  assert.match(validateConfiguration(config).join("\n"), /Undeclared argument: undeclared/);
});
