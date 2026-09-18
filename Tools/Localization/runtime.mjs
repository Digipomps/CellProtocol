// SPDX-License-Identifier: Apache-2.0
// The same bundled code runs in browsers and Apple's JavaScriptCore. Catalogs
// are data: only this application-bundled program is evaluated as JavaScript.
import { IntlMessageFormat } from "intl-messageformat";

const own = (value, key) => value != null && Object.prototype.hasOwnProperty.call(value, key);
const object = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const nonempty = (value) => typeof value === "string" && value.trim().length > 0;
const unique = (values) => [...new Set(values.filter(Boolean))];
const unsafe = new Set(["__proto__", "prototype", "constructor"]);

export function canonicalLocale(value) {
  if (!nonempty(value)) return null;
  try { return Intl.getCanonicalLocales(value.trim())[0] || null; } catch { return null; }
}

function parseLanguages(header) {
  if (typeof header !== "string") return [];
  return header.split(",").map((entry, index) => {
    const parts = entry.trim().split(";");
    const tag = parts.shift().trim();
    if (parts.length > 1) return null;
    let q = 1;
    if (parts.length) {
      const match = /^\s*q=(0(?:\.\d{0,3})?|1(?:\.0{0,3})?)\s*$/i.exec(parts[0]);
      if (!match) return null;
      q = Number(match[1]);
    }
    return (tag === "*" || canonicalLocale(tag)) ? { tag, q, index } : null;
  }).filter(Boolean).sort((a, b) => b.q - a.q || a.index - b.index);
}

export function acceptedLanguages(header) {
  return parseLanguages(header).filter(({ q }) => q > 0).map(({ tag }) => tag);
}

function matchLocale(tag, supported, defaultLocale) {
  if (tag === "*") return supported.includes(defaultLocale) ? defaultLocale : supported[0];
  const canonical = canonicalLocale(tag);
  if (!canonical) return null;
  if (supported.includes(canonical)) return canonical;
  const aliased = canonical === "no" || canonical === "no-NO" ? "nb-NO" : canonical;
  if (supported.includes(aliased)) return aliased;
  const language = aliased.split("-")[0];
  const script = aliased.split("-").find((part) => /^[A-Z][a-z]{3}$/.test(part));
  // Region fallback is deterministic in manifest order. Never change an
  // explicitly requested script, or treat Nynorsk as Bokmål.
  return supported.find((candidate) => candidate.split("-")[0] === language &&
    (!script || candidate.split("-").includes(script))) || null;
}

export function resolveLocale({ entityLocale, languageTags = [], selectedLocale,
  languages = [], acceptLanguage, supportedLocales = ["nb-NO", "en-US"], defaultLocale = "nb-NO" } = {}) {
  const supported = unique(supportedLocales.map(canonicalLocale));
  if (!supported.length) throw new Error("No supported locales");
  const sources = [
    ["entity", [entityLocale, ...languageTags]], ["surface", [selectedLocale]],
    ["environment", acceptLanguage != null ? acceptedLanguages(acceptLanguage) : languages],
  ];
  for (const [source, candidates] of sources) {
    for (const requested of candidates) {
      let available = supported;
      if (source === "environment" && acceptLanguage != null) {
        const acceptedSpecificity = requested === "*" ? 0 : (canonicalLocale(requested)?.split("-").length || 0);
        const rejected = parseLanguages(acceptLanguage).filter(({ q }) => q === 0).map(({ tag }) => tag);
        available = supported.filter((locale) => !rejected.some((range) => {
          const tag = range === "no" || range === "no-NO" ? "nb" : canonicalLocale(range);
          const specificity = range === "*" ? 0 : tag?.split("-").length || 0;
          return (range === "*" || locale === tag || locale.startsWith(`${tag}-`)) && specificity >= acceptedSpecificity;
        }));
      }
      const locale = matchLocale(requested, available, defaultLocale);
      if (locale) return { requested_locale: requested, ui_locale: locale, locale_source: source };
    }
  }
  return { requested_locale: null, ui_locale: supported.includes(defaultLocale) ? defaultLocale : supported[0],
    locale_source: "default", fallback_reason: "default_no_match" };
}

function readPath(value, keypath) {
  if (!nonempty(keypath)) return undefined;
  const parts = keypath.split(".");
  if (parts.some((part) => !part || unsafe.has(part))) return undefined;
  // A host may provide an already-authorized flattened snapshot of root paths.
  if (own(value, keypath)) return value[keypath];
  for (const part of parts) {
    if (!own(value, part)) return undefined;
    value = value[part];
  }
  return value;
}

function bindingValue(binding, scopes) {
  if (own(binding, "value")) return binding.value;
  return readPath(scopes[binding.scope || "root"], binding.keypath);
}

export function validateBinding(binding) {
  if (!object(binding)) return "expected a binding object";
  if (own(binding, "value")) {
    if (own(binding, "keypath") || own(binding, "scope")) return "literal binding cannot have keypath/scope";
    if (!["string", "number", "boolean"].includes(typeof binding.value) ||
        (typeof binding.value === "number" && !Number.isFinite(binding.value))) return "invalid literal argument";
  } else if (!nonempty(binding.keypath) || !["root", "item", "context"].includes(binding.scope || "root") ||
      binding.keypath.split(".").some((p) => !p || unsafe.has(p))) return "invalid scoped keypath";
  return null;
}

export function validateDescriptor(descriptor) {
  if (!object(descriptor)) return "expected a localization object";
  if (own(descriptor, "valueKeypath")) {
    if (own(descriptor, "namespace") || own(descriptor, "key") || own(descriptor, "arguments")) return "mixed localization forms";
    return validateBinding({ keypath: descriptor.valueKeypath, scope: descriptor.scope });
  }
  if (!nonempty(descriptor.namespace) || !nonempty(descriptor.key) || own(descriptor, "scope")) return "expected namespace and key";
  if (descriptor.arguments != null && !object(descriptor.arguments)) return "arguments must be an object";
  for (const [name, binding] of Object.entries(descriptor.arguments || {})) {
    const error = validateBinding(binding);
    if (unsafe.has(name) || error) return `argument ${name}: ${error || "reserved name"}`;
  }
  return null;
}

export const textSlots = Object.freeze({
  Text: ["text"], Button: ["label"], TextField: ["placeholder"], TextArea: ["placeholder"],
});
export function validateSlots(elementType, declarations) {
  if (declarations == null) return null;
  if (!object(declarations)) return "localization must be an object";
  for (const [slot, descriptor] of Object.entries(declarations)) {
    if (!(textSlots[elementType] || []).includes(slot)) return `unsupported ${elementType} localization slot: ${slot}`;
    const error = validateDescriptor(descriptor);
    if (error) return `${slot}: ${error}`;
  }
  return null;
}

export function validateSkeleton(skeleton) {
  const errors = [];
  function walk(value, type, path) {
    if (Array.isArray(value)) { value.forEach((child, i) => walk(child, type, `${path}[${i}]`)); return; }
    if (!object(value)) return;
    if (value.modifiers?.localization != null) {
      const error = validateSlots(type, value.modifiers.localization);
      if (error) errors.push(`${path}.modifiers.localization: ${error}`);
    }
    for (const [key, child] of Object.entries(value)) {
      if (key !== "modifiers" && key !== "payload") walk(child, key, `${path}.${key}`);
    }
  }
  walk(skeleton, "unknown", "$.skeleton");
  return errors;
}

export function validateCatalog(catalog) {
  if (!object(catalog) || catalog.schema !== "haven.localization-catalog.v1" ||
      !nonempty(catalog.namespace) || !nonempty(catalog.revision) ||
      !canonicalLocale(catalog.source_locale) || !object(catalog.messages)) return "invalid catalog envelope";
  for (const [key, message] of Object.entries(catalog.messages)) {
    if (unsafe.has(key) || !object(message) || !["literal", "icu-mf1"].includes(message.format) ||
        !object(message.translations)) return `invalid message: ${key}`;
    for (const [locale, translation] of Object.entries(message.translations)) {
      if (canonicalLocale(locale) !== locale || !object(translation) || typeof translation.value !== "string" ||
          translation.value.length > 16384 ||
          !["draft", "approved", "needs_review"].includes(translation.state)) return `invalid translation: ${key}/${locale}`;
      if (translation.state === "approved" && message.source_hash && translation.source_hash !== message.source_hash) {
        return `stale translation approval: ${key}/${locale}`;
      }
    }
    if (message.arguments != null && !object(message.arguments)) return `invalid arguments: ${key}`;
    for (const [name, type] of Object.entries(message.arguments || {})) {
      if (unsafe.has(name) || !["string", "number", "integer", "date", "boolean"].includes(type)) return `invalid argument type: ${key}/${name}`;
    }
  }
  return null;
}

function candidates(locale, available, explicitFallback) {
  const requested = canonicalLocale(locale);
  return unique([requested, matchLocale(requested, available, "nb-NO"),
    requested?.split("-")[0], canonicalLocale(explicitFallback), "nb-NO", "nb", "en-US", "en"]);
}

function checkArgument(type, value) {
  if (type === "integer") return Number.isSafeInteger(value);
  if (type === "number" || type === "date") return typeof value === "number" && Number.isFinite(value);
  return typeof value === type;
}

export function createRuntime(options = {}) {
  let catalogs = new Map();
  let context = { ui_locale: "nb-NO", timeZone: "UTC", ...options.context };
  let configuration = null;
  let rootData = {};
  const compiled = new Map();
  const intlCache = new Map();
  const metrics = { compilations: 0, formats: 0, resolutions: 0 };
  const diagnostics = new Map();
  const cacheLimit = 256;

  function problem(reason, descriptor) {
    const key = `${reason}:${descriptor?.namespace || ""}:${descriptor?.key || descriptor?.valueKeypath || ""}`;
    if (diagnostics.size < 100 || diagnostics.has(key)) diagnostics.set(key, (diagnostics.get(key) || 0) + 1);
  }
  function fallback(text, reason, descriptor) {
    if (reason) problem(reason, descriptor);
    return { text: typeof text === "string" ? text : "", requested_locale: context.requested_locale ?? context.ui_locale,
      ui_locale: context.ui_locale, resolved_locale: null, fallback_used: Boolean(reason), fallback_reason: reason || null, catalog_revision: null };
  }
  function resolved(text, locale, revision) {
    return { text, requested_locale: context.requested_locale ?? context.ui_locale, ui_locale: context.ui_locale,
      resolved_locale: locale, fallback_used: locale !== context.ui_locale,
      fallback_reason: locale !== context.ui_locale ? "translation_fallback" : null, catalog_revision: revision || null };
  }
  function setConfiguration(next = null, externalCatalogs = []) {
    if (next && (!object(next) || next.version !== 1 || (next.resources != null && !Array.isArray(next.resources)) ||
        (next.catalogs != null && !Array.isArray(next.catalogs)) ||
        (next.sourceLocale != null && !canonicalLocale(next.sourceLocale)) ||
        (next.supportedLocales != null && (!Array.isArray(next.supportedLocales) || !next.supportedLocales.length ||
          next.supportedLocales.some((locale) => !canonicalLocale(locale)))))) throw new Error("Unsupported localization configuration");
    if (!Array.isArray(externalCatalogs)) throw new Error("Expected catalog resources");
    const nextCatalogs = new Map();
    for (const catalog of [...externalCatalogs, ...(next?.resources || [])]) {
      const error = validateCatalog(catalog);
      if (error) throw new Error(error);
      if (nextCatalogs.has(catalog.namespace)) throw new Error(`Duplicate catalog namespace: ${catalog.namespace}`);
      // Freeze ownership: callers cannot mutate accepted resources behind caches.
      nextCatalogs.set(catalog.namespace, JSON.parse(JSON.stringify(catalog)));
    }
    for (const reference of next?.catalogs || []) {
      if (!object(reference) || !nonempty(reference.namespace) || !nonempty(reference.revision)) throw new Error("Invalid catalog reference");
      const catalog = nextCatalogs.get(reference.namespace);
      if (catalog && catalog.revision !== reference.revision) throw new Error(`Catalog revision mismatch: ${reference.namespace}`);
    }
    configuration = next;
    catalogs = nextCatalogs;
    compiled.clear(); intlCache.clear(); diagnostics.clear();
  }
  function setContext(next) {
    if (!object(next) || !canonicalLocale(next.ui_locale)) throw new Error("Invalid UI locale");
    const timeZone = next.timeZone || "UTC";
    new Intl.DateTimeFormat("en", { timeZone }); // Validate before replacing state.
    context = { ...next, ui_locale: canonicalLocale(next.ui_locale), timeZone };
  }
  function format(pattern, locale, args, revisionKey) {
    const key = JSON.stringify([revisionKey, locale, context.timeZone, pattern]);
    let formatter = compiled.get(key);
    if (!formatter) {
      formatter = new IntlMessageFormat(pattern, locale, undefined, { ignoreTag: true, formatters: {
        getNumberFormat: (locales, options) => cachedIntl("NumberFormat", locales, options),
        getDateTimeFormat: (locales, options) => cachedIntl("DateTimeFormat", locales, { ...options, timeZone: context.timeZone }),
        getPluralRules: (locales, options) => cachedIntl("PluralRules", locales, options),
      } });
      if (compiled.size >= cacheLimit) compiled.delete(compiled.keys().next().value);
      compiled.set(key, formatter); metrics.compilations++;
    }
    metrics.formats++;
    const text = formatter.format(args);
    if (typeof text !== "string") throw new Error("Non-text message result");
    return text;
  }
  function cachedIntl(kind, locales, options) {
    const key = JSON.stringify([kind, locales, options]);
    if (!intlCache.has(key)) {
      if (intlCache.size >= cacheLimit) intlCache.delete(intlCache.keys().next().value);
      intlCache.set(key, new Intl[kind](locales, options));
    }
    return intlCache.get(key);
  }
  function resolve(descriptor, legacyText = "", scopes = {}) {
    metrics.resolutions++;
    if (!descriptor) return fallback(legacyText, null);
    const error = validateDescriptor(descriptor);
    if (error) return fallback(legacyText, "invalid_descriptor", descriptor);
    scopes = { root: rootData, ...scopes };
    if (descriptor.valueKeypath) {
      const value = bindingValue({ keypath: descriptor.valueKeypath, scope: descriptor.scope }, scopes);
      if (!object(value) || !object(value.values)) return fallback(legacyText, "missing_localized_value", descriptor);
      for (const locale of candidates(context.ui_locale, Object.keys(value.values), value.fallbackLocale)) {
        if (own(value.values, locale) && typeof value.values[locale] === "string") return resolved(value.values[locale], locale, null);
      }
      return fallback(legacyText, "missing_translation", descriptor);
    }
    const catalog = catalogs.get(descriptor.namespace);
    if (!catalog) return fallback(legacyText, "missing_catalog", descriptor);
    const message = own(catalog.messages, descriptor.key) ? catalog.messages[descriptor.key] : null;
    if (!message) return fallback(legacyText, "missing_message", descriptor);
    const args = Object.create(null);
    for (const [name, type] of Object.entries(message.arguments || {})) {
      const binding = descriptor.arguments?.[name];
      const value = binding ? bindingValue(binding, scopes) : undefined;
      if (!checkArgument(type, value)) return fallback(legacyText, "invalid_argument", descriptor);
      args[name] = value;
    }
    for (const locale of candidates(context.ui_locale, Object.keys(message.translations), catalog.source_locale)) {
      const translation = message.translations[locale];
      if (!translation || translation.state !== "approved") continue;
      try {
        const text = message.format === "literal" ? translation.value : format(translation.value, locale, args, `${catalog.namespace}:${catalog.revision}:${descriptor.key}`);
        return resolved(text, locale, catalog.revision);
      } catch { return fallback(legacyText, "format_error", descriptor); }
    }
    return fallback(legacyText, "missing_translation", descriptor);
  }
  setConfiguration(options.configuration || null, options.catalogs || []);
  setContext(context);
  return { resolve, setConfiguration, setContext, setRootData: (next) => { rootData = next || {}; },
    getContext: () => ({ ...context }), getMetrics: () => ({ ...metrics, cachedMessages: compiled.size }),
    getDiagnostics: () => [...diagnostics].map(([key, count]) => ({ key, count })),
    clear: () => { catalogs.clear(); compiled.clear(); intlCache.clear(); diagnostics.clear(); rootData = {}; configuration = null; } };
}
