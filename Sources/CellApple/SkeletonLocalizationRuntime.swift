// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

#if canImport(JavaScriptCore)
import Foundation
import JavaScriptCore
import CellBase

/// One runtime per host. The only evaluated program is the bundled formatter;
/// descriptors, catalogs and user values cross the bridge as data, never code.
/// No Cell, network or process APIs are exposed to the JavaScript context.
public final class SkeletonLocalizationRuntime {
    private let lock = NSRecursiveLock()
    private let context: JSContext?
    private let runtime: JSValue?
    public let initializationError: String?

    public enum RuntimeError: Error { case unavailable(String), javascript(String), invalidResult }

    public init() {
        let context = JSContext()
        var error: String?
        var runtime: JSValue?
        if let url = Bundle.module.url(forResource: "haven-localization", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8), let context {
            context.evaluateScript(source, withSourceURL: url)
            if let exception = context.exception {
                error = exception.toString()
            } else {
                runtime = context.objectForKeyedSubscript("HavenLocalization")?.invokeMethod("createRuntime", withArguments: [])
                error = context.exception?.toString()
            }
        } else {
            error = "Bundled skeleton localization runtime unavailable"
        }
        self.context = context
        self.runtime = runtime
        self.initializationError = error
    }

    public func configure(_ configuration: SkeletonLocalizationConfiguration?, catalogs: [LocalizationCatalog] = [],
                          skeleton: SkeletonElement? = nil) throws {
        try locked {
            if let skeleton, let context {
                context.exception = nil
                let result = context.objectForKeyedSubscript("HavenLocalization")?.invokeMethod("validateSkeleton", withArguments: [try jsonObject(skeleton)])
                if let exception = context.exception { throw RuntimeError.javascript(exception.toString()) }
                if let errors = result?.toArray() as? [String], !errors.isEmpty {
                    throw RuntimeError.javascript(errors.joined(separator: "; "))
                }
            }
            _ = try invoke("setConfiguration", [try configuration.map(jsonObject) ?? NSNull(), try jsonObject(catalogs)])
        }
    }

    public func setLocale(_ locale: String, timeZone: String = "UTC") throws {
        try locked { _ = try invoke("setContext", [["ui_locale": locale, "timeZone": timeZone]]) }
    }

    /// The caller supplies an already-authorized snapshot. A language switch
    /// never calls this method or re-reads Cell data.
    public func setRootData(_ data: ValueType) throws {
        try locked { _ = try invoke("setRootData", [try jsonObject(data)]) }
    }

    public func resolve(_ descriptor: SkeletonLocalizedText?, fallback: String,
                        item: ValueType? = nil, contextValue: ValueType? = nil) throws -> ResolvedSkeletonText {
        try locked {
            var scopes: [String: Any] = [:]
            if let item { scopes["item"] = try jsonObject(item) }
            if let contextValue { scopes["context"] = try jsonObject(contextValue) }
            let result = try invoke("resolve", [try descriptor.map(jsonObject) ?? NSNull(), fallback, scopes])
            guard let object = result?.toDictionary() else { throw RuntimeError.invalidResult }
            return try JSONDecoder().decode(ResolvedSkeletonText.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    public func text(_ descriptor: SkeletonLocalizedText?, fallback: String,
                     item: ValueType? = nil, contextValue: ValueType? = nil) -> String {
        guard descriptor != nil else { return fallback }
        return (try? resolve(descriptor, fallback: fallback, item: item, contextValue: contextValue))?.text ?? fallback
    }

    public func chooseLocale(entityLocale: String? = nil, languageTags: [String] = [],
                             selectedLocale: String? = nil, languages: [String] = Locale.preferredLanguages,
                             supportedLocales: [String] = ["nb-NO", "en-US"]) throws -> String {
        try locked {
            guard initializationError == nil, let context else { throw RuntimeError.unavailable(initializationError ?? "No context") }
            var options: [String: Any] = ["languageTags": languageTags, "languages": languages, "supportedLocales": supportedLocales]
            if let entityLocale { options["entityLocale"] = entityLocale }
            if let selectedLocale { options["selectedLocale"] = selectedLocale }
            context.exception = nil
            let result = context.objectForKeyedSubscript("HavenLocalization")?.invokeMethod("resolveLocale", withArguments: [options])
            if let exception = context.exception { throw RuntimeError.javascript(exception.toString()) }
            guard let locale = result?.objectForKeyedSubscript("ui_locale")?.toString() else { throw RuntimeError.invalidResult }
            return locale
        }
    }

    public func metrics() -> [String: Int] {
        locked { (try? invoke("getMetrics", [])?.toDictionary()) as? [String: Int] ?? [:] }
    }

    public func clear() { locked { _ = try? invoke("clear", []) } }

    private func invoke(_ method: String, _ arguments: [Any]) throws -> JSValue? {
        guard initializationError == nil, let context, let runtime else {
            throw RuntimeError.unavailable(initializationError ?? "No runtime")
        }
        context.exception = nil
        let result = runtime.invokeMethod(method, withArguments: arguments)
        if let exception = context.exception { throw RuntimeError.javascript(exception.toString()) }
        return result
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }
    private func locked<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try work()
    }
}
#endif
