// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import HavenCoreSchemas

public enum ConfigurationCatalogInsertionMode: String, Codable, CaseIterable, Hashable {
    case root
    case component
    case both
    case unknown
}

public struct ConfigurationCatalogIOSignature: Codable, Hashable {
    public var getKeys: [String]
    public var setKeys: [String]
    public var topics: [String]
    public var filterTypes: [String]

    public init(
        getKeys: [String] = [],
        setKeys: [String] = [],
        topics: [String] = [],
        filterTypes: [String] = []
    ) {
        self.getKeys = Self.uniqueSorted(getKeys)
        self.setKeys = Self.uniqueSorted(setKeys)
        self.topics = Self.uniqueSorted(topics)
        self.filterTypes = Self.uniqueSorted(filterTypes)
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
}

public struct ConfigurationCatalogEntryContract: Codable {
    public var id: String
    public var sourceCellEndpoint: String
    public var sourceCellName: String
    public var purpose: String
    public var purposeDescription: String?
    public var interests: [String]
    public var menuSlots: [String]
    public var displayName: String?
    public var summary: String?
    public var categoryPath: [String]
    public var tags: [String]
    public var purposeRefs: [String]
    public var interestRefs: [String]
    public var supportedInsertionModes: [ConfigurationCatalogInsertionMode]
    public var supportedTargetKinds: [String]
    public var ioSignature: ConfigurationCatalogIOSignature?
    public var authRequired: Bool
    public var policyHints: [String]
    public var flowDriven: Bool
    public var editable: Bool
    public var recommendedContexts: [String]
    public var localizedDisplay: ConfigurationCatalogLocalizedDisplay?
    public var goal: CellConfiguration?
    public var configuration: CellConfiguration?
    public var updatedAtEpochMs: Double?

    public init(
        id: String,
        sourceCellEndpoint: String,
        sourceCellName: String,
        purpose: String,
        purposeDescription: String? = nil,
        interests: [String] = [],
        menuSlots: [String] = [],
        displayName: String? = nil,
        summary: String? = nil,
        categoryPath: [String] = [],
        tags: [String] = [],
        purposeRefs: [String] = [],
        interestRefs: [String] = [],
        supportedInsertionModes: [ConfigurationCatalogInsertionMode] = [],
        supportedTargetKinds: [String] = [],
        ioSignature: ConfigurationCatalogIOSignature? = nil,
        authRequired: Bool = false,
        policyHints: [String] = [],
        flowDriven: Bool = false,
        editable: Bool = false,
        recommendedContexts: [String] = [],
        localizedDisplay: ConfigurationCatalogLocalizedDisplay? = nil,
        goal: CellConfiguration? = nil,
        configuration: CellConfiguration? = nil,
        updatedAtEpochMs: Double? = nil
    ) {
        self.id = id
        self.sourceCellEndpoint = sourceCellEndpoint
        self.sourceCellName = sourceCellName
        self.purpose = purpose
        self.purposeDescription = purposeDescription
        self.interests = Self.uniqueSorted(interests)
        self.menuSlots = Self.uniqueSorted(menuSlots)
        self.displayName = displayName
        self.summary = summary
        self.categoryPath = Self.uniqueSorted(categoryPath)
        self.tags = Self.uniqueSorted(tags)
        self.purposeRefs = Self.uniqueSorted(purposeRefs)
        self.interestRefs = Self.uniqueSorted(interestRefs)
        self.supportedInsertionModes = Array(Set(supportedInsertionModes)).sorted { $0.rawValue < $1.rawValue }
        self.supportedTargetKinds = Self.uniqueSorted(supportedTargetKinds)
        self.ioSignature = ioSignature
        self.authRequired = authRequired
        self.policyHints = Self.uniqueSorted(policyHints)
        self.flowDriven = flowDriven
        self.editable = editable
        self.recommendedContexts = Self.uniqueSorted(recommendedContexts)
        self.localizedDisplay = localizedDisplay
        self.goal = goal
        self.configuration = configuration
        self.updatedAtEpochMs = updatedAtEpochMs
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
}

public struct ConfigurationCatalogLocalizedDisplay: Codable, Hashable {
    public var locale: String?
    public var displayName: String?
    public var summary: String?
    public var purposeLabels: [ResolvedLocalizedTerm]
    public var interestLabels: [ResolvedLocalizedTerm]
    public var unresolvedTermRefs: [String]

    public init(
        locale: String? = nil,
        displayName: String? = nil,
        summary: String? = nil,
        purposeLabels: [ResolvedLocalizedTerm] = [],
        interestLabels: [ResolvedLocalizedTerm] = [],
        unresolvedTermRefs: [String] = []
    ) {
        self.locale = LocalizationDefaults.normalizedLocale(locale)
        self.displayName = displayName
        self.summary = summary
        self.purposeLabels = purposeLabels.sorted { $0.termID < $1.termID }
        self.interestLabels = interestLabels.sorted { $0.termID < $1.termID }
        self.unresolvedTermRefs = Self.uniqueSorted(unresolvedTermRefs)
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
}

public struct ConfigurationCatalogQueryRequest: Codable, Hashable {
    public var text: String?
    public var locale: String?
    public var includeLocalizedLabels: Bool
    public var purposeRefs: [String]
    public var interestRefs: [String]
    public var categoryPath: [String]
    public var sourceCellNames: [String]
    public var supportedInsertionModes: [ConfigurationCatalogInsertionMode]
    public var supportedTargetKinds: [String]
    public var authRequired: Bool?
    public var flowDriven: Bool?
    public var editable: Bool?
    public var limit: Int
    public var offset: Int

    public init(
        text: String? = nil,
        locale: String? = nil,
        includeLocalizedLabels: Bool = false,
        purposeRefs: [String] = [],
        interestRefs: [String] = [],
        categoryPath: [String] = [],
        sourceCellNames: [String] = [],
        supportedInsertionModes: [ConfigurationCatalogInsertionMode] = [],
        supportedTargetKinds: [String] = [],
        authRequired: Bool? = nil,
        flowDriven: Bool? = nil,
        editable: Bool? = nil,
        limit: Int = 20,
        offset: Int = 0
    ) {
        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = (trimmedText?.isEmpty == false) ? trimmedText : nil
        self.locale = LocalizationDefaults.normalizedLocale(locale)
        self.includeLocalizedLabels = includeLocalizedLabels
        self.purposeRefs = Self.uniqueSorted(purposeRefs)
        self.interestRefs = Self.uniqueSorted(interestRefs)
        self.categoryPath = Self.uniqueSorted(categoryPath)
        self.sourceCellNames = Self.uniqueSorted(sourceCellNames)
        self.supportedInsertionModes = Array(Set(supportedInsertionModes)).sorted { $0.rawValue < $1.rawValue }
        self.supportedTargetKinds = Self.uniqueSorted(supportedTargetKinds)
        self.authRequired = authRequired
        self.flowDriven = flowDriven
        self.editable = editable
        self.limit = max(1, limit)
        self.offset = max(0, offset)
    }

    enum CodingKeys: String, CodingKey {
        case text
        case locale
        case includeLocalizedLabels
        case purposeRefs
        case interestRefs
        case categoryPath
        case sourceCellNames
        case supportedInsertionModes
        case supportedTargetKinds
        case authRequired
        case flowDriven
        case editable
        case limit
        case offset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            text: try container.decodeIfPresent(String.self, forKey: .text),
            locale: try container.decodeIfPresent(String.self, forKey: .locale),
            includeLocalizedLabels: try container.decodeIfPresent(Bool.self, forKey: .includeLocalizedLabels) ?? false,
            purposeRefs: try container.decodeIfPresent([String].self, forKey: .purposeRefs) ?? [],
            interestRefs: try container.decodeIfPresent([String].self, forKey: .interestRefs) ?? [],
            categoryPath: try container.decodeIfPresent([String].self, forKey: .categoryPath) ?? [],
            sourceCellNames: try container.decodeIfPresent([String].self, forKey: .sourceCellNames) ?? [],
            supportedInsertionModes: try container.decodeIfPresent([ConfigurationCatalogInsertionMode].self, forKey: .supportedInsertionModes) ?? [],
            supportedTargetKinds: try container.decodeIfPresent([String].self, forKey: .supportedTargetKinds) ?? [],
            authRequired: try container.decodeIfPresent(Bool.self, forKey: .authRequired),
            flowDriven: try container.decodeIfPresent(Bool.self, forKey: .flowDriven),
            editable: try container.decodeIfPresent(Bool.self, forKey: .editable),
            limit: try container.decodeIfPresent(Int.self, forKey: .limit) ?? 20,
            offset: try container.decodeIfPresent(Int.self, forKey: .offset) ?? 0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(locale, forKey: .locale)
        try container.encode(includeLocalizedLabels, forKey: .includeLocalizedLabels)
        try container.encode(purposeRefs, forKey: .purposeRefs)
        try container.encode(interestRefs, forKey: .interestRefs)
        try container.encode(categoryPath, forKey: .categoryPath)
        try container.encode(sourceCellNames, forKey: .sourceCellNames)
        try container.encode(supportedInsertionModes, forKey: .supportedInsertionModes)
        try container.encode(supportedTargetKinds, forKey: .supportedTargetKinds)
        try container.encodeIfPresent(authRequired, forKey: .authRequired)
        try container.encodeIfPresent(flowDriven, forKey: .flowDriven)
        try container.encodeIfPresent(editable, forKey: .editable)
        try container.encode(limit, forKey: .limit)
        try container.encode(offset, forKey: .offset)
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
}

public struct ConfigurationCatalogQueryMatch: Codable {
    public var entryID: String
    public var score: Double
    public var reasons: [String]
    public var scoreBreakdown: [String: Double]
    public var entry: ConfigurationCatalogEntryContract

    public init(
        entryID: String,
        score: Double,
        reasons: [String] = [],
        scoreBreakdown: [String: Double] = [:],
        entry: ConfigurationCatalogEntryContract
    ) {
        self.entryID = entryID
        self.score = score
        self.reasons = Array(Set(reasons)).sorted()
        self.scoreBreakdown = scoreBreakdown
        self.entry = entry
    }
}

public struct ConfigurationCatalogQueryResponse: Codable {
    public var items: [ConfigurationCatalogQueryMatch]
    public var total: Int
    public var offset: Int
    public var limit: Int

    public init(items: [ConfigurationCatalogQueryMatch], total: Int, offset: Int, limit: Int) {
        self.items = items
        self.total = max(0, total)
        self.offset = max(0, offset)
        self.limit = max(1, limit)
    }
}

public struct ConfigurationCatalogFacetCountsRequest: Codable, Hashable {
    public var query: ConfigurationCatalogQueryRequest
    public var facets: [String]

    public init(query: ConfigurationCatalogQueryRequest = ConfigurationCatalogQueryRequest(), facets: [String]) {
        self.query = query
        self.facets = Array(Set(facets.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
}

public struct ConfigurationCatalogFacetBucket: Codable, Hashable {
    public var facet: String
    public var value: String
    public var count: Int

    public init(facet: String, value: String, count: Int) {
        self.facet = facet
        self.value = value
        self.count = max(0, count)
    }
}

public struct ConfigurationCatalogFacetCountsResponse: Codable {
    public var buckets: [ConfigurationCatalogFacetBucket]

    public init(buckets: [ConfigurationCatalogFacetBucket]) {
        self.buckets = buckets.sorted {
            if $0.facet == $1.facet {
                return $0.value < $1.value
            }
            return $0.facet < $1.facet
        }
    }
}
