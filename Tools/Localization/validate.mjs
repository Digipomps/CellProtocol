// SPDX-License-Identifier: Apache-2.0
// Authoring/CI admission, separate from the small client formatter bundle.
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { IntlMessageFormat } from "intl-messageformat";
import { createRuntime, validateSkeleton } from "./runtime.mjs";

export function validateConfiguration(configuration) {
  const errors = [];
  try { createRuntime({ configuration: configuration.localization || null }); }
  catch (error) { errors.push(`$.localization: ${error.message}`); }
  errors.push(...validateSkeleton(configuration.skeleton));
  for (const catalog of configuration.localization?.resources || []) {
    for (const [key, message] of Object.entries(catalog.messages || {})) {
      if (message.format !== "icu-mf1") continue;
      for (const [locale, translation] of Object.entries(message.translations || {})) {
        try {
          const ast = new IntlMessageFormat(translation.value, locale, undefined, { ignoreTag: true }).getAst();
          const names = new Set();
          function argumentsIn(nodes) {
            for (const node of nodes) {
              if (node.type >= 1 && node.type <= 6) names.add(node.value);
              for (const option of Object.values(node.options || {})) argumentsIn(option.value);
            }
          }
          argumentsIn(ast);
          for (const name of names) {
            if (!Object.hasOwn(message.arguments || {}, name)) throw new Error(`Undeclared argument: ${name}`);
          }
        } catch (error) { errors.push(`${catalog.namespace}.${key}/${locale}: ${error.message}`); }
      }
    }
  }
  return errors;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (!process.argv[2]) { console.error("Usage: node Tools/Localization/validate.mjs <CellConfiguration.json>"); process.exit(2); }
  try {
    const errors = validateConfiguration(JSON.parse(readFileSync(process.argv[2], "utf8")));
    console.log(JSON.stringify({ valid: errors.length === 0, errors }, null, 2));
    process.exitCode = errors.length ? 1 : 0;
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
