// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum LocalizationDefaults {
    public static let defaultRequiredLocales = ["nb-NO", "en-US"]
    public static let fallbackLocales = ["nb-NO", "nb", "en-US", "en"]

    public static func normalizedLocale(_ locale: String?) -> String? {
        normalizedIdentifier(locale)
    }

    public static func normalizedIdentifier(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    public static func candidateLocales(
        for requestedLocale: String?,
        fallbackLocales: [String] = LocalizationDefaults.fallbackLocales
    ) -> [String] {
        var candidates: [String] = []

        if let requestedLocale = normalizedLocale(requestedLocale) {
            candidates.append(requestedLocale)
            if let base = requestedLocale.split(separator: "-").first {
                candidates.append(String(base))
            }
        }

        candidates.append(contentsOf: fallbackLocales)
        return unique(candidates)
    }

    public static func resolveText(
        values: [String: String],
        requestedLocale: String?,
        fallbackLocales: [String] = LocalizationDefaults.fallbackLocales,
        fallbackValue: String? = nil
    ) -> ResolvedLocalizedText? {
        var normalizedValues: [String: String] = [:]
        for (key, value) in values {
            let normalizedKey = normalizedLocale(key)
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let normalizedKey, !trimmedValue.isEmpty, normalizedValues[normalizedKey] == nil else { continue }
            normalizedValues[normalizedKey] = value
        }

        let requested = normalizedLocale(requestedLocale)
        for candidate in candidateLocales(for: requested, fallbackLocales: fallbackLocales) {
            if let value = normalizedValues[candidate] {
                return ResolvedLocalizedText(
                    value: value,
                    requestedLocale: requested,
                    resolvedLocale: candidate,
                    fallbackUsed: candidate != requested
                )
            }
        }

        if let firstLocale = normalizedValues.keys.sorted().first,
           let value = normalizedValues[firstLocale] {
            return ResolvedLocalizedText(
                value: value,
                requestedLocale: requested,
                resolvedLocale: firstLocale,
                fallbackUsed: firstLocale != requested
            )
        }

        guard let fallbackValue else { return nil }
        return ResolvedLocalizedText(
            value: fallbackValue,
            requestedLocale: requested,
            resolvedLocale: nil,
            fallbackUsed: true
        )
    }

    public static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}

public struct ResolvedLocalizedText: Codable, Hashable, Sendable {
    public var value: String
    public var requestedLocale: String?
    public var resolvedLocale: String?
    public var fallbackUsed: Bool

    public init(
        value: String,
        requestedLocale: String? = nil,
        resolvedLocale: String? = nil,
        fallbackUsed: Bool = false
    ) {
        self.value = value
        self.requestedLocale = LocalizationDefaults.normalizedLocale(requestedLocale)
        self.resolvedLocale = LocalizationDefaults.normalizedLocale(resolvedLocale)
        self.fallbackUsed = fallbackUsed
    }
}

public struct LocalizedTextMap: Codable, Hashable, Sendable {
    public var values: [String: String]
    public var fallbackLocale: String?

    public init(values: [String: String] = [:], fallbackLocale: String? = nil) {
        self.values = values
        self.fallbackLocale = LocalizationDefaults.normalizedLocale(fallbackLocale)
    }

    public func resolved(locale requestedLocale: String?) -> ResolvedLocalizedText? {
        let fallbackLocales: [String]
        if let fallbackLocale {
            fallbackLocales = LocalizationDefaults.unique([fallbackLocale] + LocalizationDefaults.fallbackLocales)
        } else {
            fallbackLocales = LocalizationDefaults.fallbackLocales
        }

        return LocalizationDefaults.resolveText(
            values: values,
            requestedLocale: requestedLocale,
            fallbackLocales: fallbackLocales
        )
    }
}

public struct SemanticTermRef: Codable, Hashable, Sendable {
    public var termID: String
    public var namespace: String?
    public var kind: Term.Kind?

    public init(termID: String, namespace: String? = nil, kind: Term.Kind? = nil) {
        self.termID = termID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.namespace = LocalizationDefaults.normalizedIdentifier(namespace)
        self.kind = kind
    }
}

public struct ResolvedLocalizedTerm: Codable, Hashable, Sendable {
    public var termID: String
    public var namespace: String
    public var kind: Term.Kind
    public var label: String
    public var requestedLocale: String?
    public var resolvedLocale: String?
    public var fallbackUsed: Bool

    public init(
        termID: String,
        namespace: String,
        kind: Term.Kind,
        label: String,
        requestedLocale: String? = nil,
        resolvedLocale: String? = nil,
        fallbackUsed: Bool = false
    ) {
        self.termID = termID
        self.namespace = LocalizationDefaults.normalizedIdentifier(namespace) ?? namespace
        self.kind = kind
        self.label = label
        self.requestedLocale = LocalizationDefaults.normalizedLocale(requestedLocale)
        self.resolvedLocale = LocalizationDefaults.normalizedLocale(resolvedLocale)
        self.fallbackUsed = fallbackUsed
    }
}

public struct TaxonomyLocalizationCoverageIssue: Codable, Hashable, Sendable {
    public enum Severity: String, Codable, CaseIterable, Sendable {
        case warning
    }

    public var severity: Severity
    public var namespace: String
    public var termID: String
    public var kind: Term.Kind
    public var locale: String
    public var message: String

    public init(
        severity: Severity = .warning,
        namespace: String,
        termID: String,
        kind: Term.Kind,
        locale: String,
        message: String
    ) {
        self.severity = severity
        self.namespace = namespace
        self.termID = termID
        self.kind = kind
        self.locale = locale
        self.message = message
    }
}

public struct TaxonomyLocalizationCoverageResult: Codable, Hashable, Sendable {
    public var namespace: String
    public var requiredLocales: [String]
    public var issues: [TaxonomyLocalizationCoverageIssue]
    public var warningCount: Int
    public var isComplete: Bool

    public init(
        namespace: String,
        requiredLocales: [String],
        issues: [TaxonomyLocalizationCoverageIssue]
    ) {
        self.namespace = namespace
        self.requiredLocales = LocalizationDefaults.unique(requiredLocales)
        self.issues = issues
        self.warningCount = issues.count
        self.isComplete = issues.isEmpty
    }
}
