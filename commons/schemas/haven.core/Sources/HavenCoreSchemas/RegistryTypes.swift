// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct TaxonomyPackage: Codable, Hashable, Sendable {
    public struct GoalPolicy: Codable, Hashable, Sendable {
        public enum Mode: String, Codable, CaseIterable, Sendable {
            case encouraged
            case optional
        }

        public var mode: Mode
        public var description: String

        public init(mode: Mode, description: String) {
            self.mode = mode
            self.description = description
        }
    }

    public struct Guidance: Codable, Hashable, Sendable {
        public var rootPurposeTermID: String
        public var contributionPurposeTermID: String
        public var articleReference: String
        public var incentiveOnly: Bool
        public var goalPolicy: GoalPolicy
        public var mandatoryInheritedPurposes: [String]
        public var forbiddenRelationsToMandatory: [Term.RelationKind]

        public init(
            rootPurposeTermID: String,
            contributionPurposeTermID: String,
            articleReference: String,
            incentiveOnly: Bool,
            goalPolicy: GoalPolicy,
            mandatoryInheritedPurposes: [String] = [],
            forbiddenRelationsToMandatory: [Term.RelationKind] = []
        ) {
            self.rootPurposeTermID = rootPurposeTermID
            self.contributionPurposeTermID = contributionPurposeTermID
            self.articleReference = articleReference
            self.incentiveOnly = incentiveOnly
            self.goalPolicy = goalPolicy
            self.mandatoryInheritedPurposes = Self.normalizedMandatoryPurposes(
                mandatoryInheritedPurposes,
                fallbackRoot: rootPurposeTermID,
                fallbackContribution: contributionPurposeTermID
            )
            self.forbiddenRelationsToMandatory = forbiddenRelationsToMandatory.isEmpty ? [.opposes] : forbiddenRelationsToMandatory
        }

        enum CodingKeys: String, CodingKey {
            case rootPurposeTermID = "root_purpose_term_id"
            case contributionPurposeTermID = "contribution_purpose_term_id"
            case articleReference = "article_reference"
            case incentiveOnly = "incentive_only"
            case goalPolicy = "goal_policy"
            case mandatoryInheritedPurposes = "mandatory_inherited_purposes"
            case forbiddenRelationsToMandatory = "forbidden_relations_to_mandatory"
        }

        private static func normalizedMandatoryPurposes(
            _ explicit: [String],
            fallbackRoot: String,
            fallbackContribution: String
        ) -> [String] {
            var values = explicit
            if values.isEmpty {
                values = [fallbackRoot, fallbackContribution]
            }

            var seen = Set<String>()
            var normalized: [String] = []
            for value in values where seen.insert(value).inserted {
                normalized.append(value)
            }
            return normalized
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.rootPurposeTermID = try container.decode(String.self, forKey: .rootPurposeTermID)
            self.contributionPurposeTermID = try container.decode(String.self, forKey: .contributionPurposeTermID)
            self.articleReference = try container.decode(String.self, forKey: .articleReference)
            self.incentiveOnly = try container.decode(Bool.self, forKey: .incentiveOnly)
            self.goalPolicy = try container.decode(GoalPolicy.self, forKey: .goalPolicy)
            self.mandatoryInheritedPurposes = Self.normalizedMandatoryPurposes(
                try container.decodeIfPresent([String].self, forKey: .mandatoryInheritedPurposes) ?? [],
                fallbackRoot: rootPurposeTermID,
                fallbackContribution: contributionPurposeTermID
            )
            self.forbiddenRelationsToMandatory =
                try container.decodeIfPresent([Term.RelationKind].self, forKey: .forbiddenRelationsToMandatory) ?? [.opposes]
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(rootPurposeTermID, forKey: .rootPurposeTermID)
            try container.encode(contributionPurposeTermID, forKey: .contributionPurposeTermID)
            try container.encode(articleReference, forKey: .articleReference)
            try container.encode(incentiveOnly, forKey: .incentiveOnly)
            try container.encode(goalPolicy, forKey: .goalPolicy)
            try container.encode(mandatoryInheritedPurposes, forKey: .mandatoryInheritedPurposes)
            try container.encode(forbiddenRelationsToMandatory, forKey: .forbiddenRelationsToMandatory)
        }
    }

    public var namespace: String
    public var version: String
    public var dependsOn: [String]
    public var terms: [Term]
    public var guidance: Guidance?

    public init(
        namespace: String,
        version: String,
        dependsOn: [String],
        terms: [Term],
        guidance: Guidance? = nil
    ) {
        self.namespace = namespace
        self.version = version
        self.dependsOn = dependsOn
        self.terms = terms
        self.guidance = guidance
    }

    enum CodingKeys: String, CodingKey {
        case namespace
        case version
        case dependsOn = "depends_on"
        case terms
        case guidance
    }
}

public struct Term: Codable, Hashable, Sendable {
    public struct Relation: Codable, Hashable, Sendable {
        public var kind: RelationKind
        public var target: String

        public init(kind: RelationKind, target: String) {
            self.kind = kind
            self.target = target
        }
    }

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case purpose
        case goal
        case interest
        case topic
        case role
        case value
        case skill

        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self).lowercased()
            guard let kind = Kind(rawValue: value) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Unknown Term.Kind: \(value)"
                )
            }
            self = kind
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public enum RelationKind: String, Codable, CaseIterable, Sendable {
        case broader
        case narrower
        case related
        case usedWith = "used_with"
        case opposes

        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self).lowercased()
            guard let kind = RelationKind(rawValue: value) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Unknown Term.RelationKind: \(value)"
                )
            }
            self = kind
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public var termId: String
    public var labels: [String: String]
    public var definition: String
    public var kind: Kind
    public var relations: [Relation]
    public var deprecated: Bool
    public var replacedBy: String?
    public var mappings: [String: String]

    public init(
        termId: String,
        labels: [String: String],
        definition: String,
        kind: Kind,
        relations: [Relation] = [],
        deprecated: Bool = false,
        replacedBy: String? = nil,
        mappings: [String: String] = [:]
    ) {
        self.termId = termId
        self.labels = labels
        self.definition = definition
        self.kind = kind
        self.relations = relations
        self.deprecated = deprecated
        self.replacedBy = replacedBy
        self.mappings = mappings
    }

    enum CodingKeys: String, CodingKey {
        case termId = "term_id"
        case labels
        case definition
        case kind
        case relations
        case deprecated
        case replacedBy = "replaced_by"
        case mappings
    }
}

public struct KeyPathSpec: Codable, Hashable, Sendable {
    public var path: String
    public var typeRef: String
    public var owner: String
    public var visibilityClass: PermissionClass
    public var aliases: [String]
    public var deprecated: Bool
    public var replacedBy: String?
    public var storageDomain: String?

    public init(
        path: String,
        typeRef: String,
        owner: String,
        visibilityClass: PermissionClass,
        aliases: [String] = [],
        deprecated: Bool = false,
        replacedBy: String? = nil,
        storageDomain: String? = nil
    ) {
        self.path = path
        self.typeRef = typeRef
        self.owner = owner
        self.visibilityClass = visibilityClass
        self.aliases = aliases
        self.deprecated = deprecated
        self.replacedBy = replacedBy
        self.storageDomain = storageDomain
    }

    enum CodingKeys: String, CodingKey {
        case path
        case typeRef = "type_ref"
        case owner
        case visibilityClass = "visibility_class"
        case aliases
        case deprecated
        case replacedBy = "replaced_by"
        case storageDomain = "storage_domain"
    }
}

public struct PathRoute: Codable, Hashable, Sendable {
    public var prefix: String
    public var cellType: String
    public var resolution: RouteResolution
    public var localPrefix: String

    public init(prefix: String, cellType: String, resolution: RouteResolution, localPrefix: String) {
        self.prefix = prefix
        self.cellType = cellType
        self.resolution = resolution
        self.localPrefix = localPrefix
    }

    enum CodingKeys: String, CodingKey {
        case prefix
        case cellType = "cell_type"
        case resolution
        case localPrefix = "local_prefix"
    }
}

public enum RouteResolution: String, Codable, CaseIterable, Sendable {
    case linked
    case absorbed
    case external
}

public enum PermissionClass: String, Codable, CaseIterable, Sendable {
    case `public`
    case `private`
    case consent
    case aggregated

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self).lowercased()
        guard let permissionClass = PermissionClass(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown PermissionClass: \(value)"
            )
        }
        self = permissionClass
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum RequesterRole: String, Codable, CaseIterable, Sendable {
    case owner
    case member
    case sponsor
    case service
    case unknown
}

public struct RequesterContext: Codable, Hashable, Sendable {
    public var role: RequesterRole
    public var consentTokens: [String]

    public init(role: RequesterRole, consentTokens: [String] = []) {
        self.role = role
        self.consentTokens = consentTokens
    }

    enum CodingKeys: String, CodingKey {
        case role
        case consentTokens = "consent_tokens"
    }
}

public struct PermissionDecision: Codable, Hashable, Sendable {
    public var isAllowed: Bool
    public var permissionClass: PermissionClass
    public var reason: String

    public init(isAllowed: Bool, permissionClass: PermissionClass, reason: String) {
        self.isAllowed = isAllowed
        self.permissionClass = permissionClass
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case isAllowed = "is_allowed"
        case permissionClass = "permission_class"
        case reason
    }
}

public struct KeyPathResolutionAudit: Codable, Hashable, Sendable {
    public var aliasApplied: String?
    public var routePrefix: String?
    public var routeResolution: RouteResolution?
    public var deprecatedPath: Bool
    public var registryMatched: Bool

    public init(
        aliasApplied: String?,
        routePrefix: String?,
        routeResolution: RouteResolution?,
        deprecatedPath: Bool,
        registryMatched: Bool
    ) {
        self.aliasApplied = aliasApplied
        self.routePrefix = routePrefix
        self.routeResolution = routeResolution
        self.deprecatedPath = deprecatedPath
        self.registryMatched = registryMatched
    }

    enum CodingKeys: String, CodingKey {
        case aliasApplied = "alias_applied"
        case routePrefix = "route_prefix"
        case routeResolution = "route_resolution"
        case deprecatedPath = "deprecated_path"
        case registryMatched = "registry_matched"
    }
}

public struct ResolvedKeyPath: Codable, Hashable, Sendable {
    public var entityId: String
    public var inputPath: String
    public var canonicalPath: String
    public var resolvedCellId: String
    public var resolvedCellType: String
    public var resolvedLocalPath: String
    public var typeRef: String
    public var permission: PermissionDecision
    public var auditInfo: KeyPathResolutionAudit
    public var storageDomain: String?

    public init(
        entityId: String,
        inputPath: String,
        canonicalPath: String,
        resolvedCellId: String,
        resolvedCellType: String,
        resolvedLocalPath: String,
        typeRef: String,
        permission: PermissionDecision,
        auditInfo: KeyPathResolutionAudit,
        storageDomain: String?
    ) {
        self.entityId = entityId
        self.inputPath = inputPath
        self.canonicalPath = canonicalPath
        self.resolvedCellId = resolvedCellId
        self.resolvedCellType = resolvedCellType
        self.resolvedLocalPath = resolvedLocalPath
        self.typeRef = typeRef
        self.permission = permission
        self.auditInfo = auditInfo
        self.storageDomain = storageDomain
    }

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case inputPath = "input_path"
        case canonicalPath = "canonical_path"
        case resolvedCellId = "resolved_cell_id"
        case resolvedCellType = "resolved_cell_type"
        case resolvedLocalPath = "resolved_local_path"
        case typeRef = "type_ref"
        case permission
        case auditInfo = "audit_info"
        case storageDomain = "storage_domain"
    }
}

public enum JSONPointer {
    public static func normalize(_ rawPath: String) -> String {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)

        if path.isEmpty {
            return "#/"
        }

        if path.hasPrefix("haven://"), let hashIndex = path.firstIndex(of: "#") {
            path = String(path[hashIndex...])
        }

        if path == "#" {
            return "#/"
        }

        if path.hasPrefix("/") {
            path = "#\(path)"
        }

        if !path.hasPrefix("#") {
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            path = "#/\(trimmed)"
        }

        while path.contains("//") {
            path = path.replacingOccurrences(of: "//", with: "/")
        }

        if path.count > 2, path.hasSuffix("/") {
            path.removeLast()
        }

        return path
    }

    public static func applyPrefix(path: String, prefix: String, localPrefix: String) -> String {
        let normalizedPath = normalize(path)
        let normalizedPrefix = normalize(prefix)
        let normalizedLocalPrefix = normalize(localPrefix)

        guard normalizedPath.hasPrefix(normalizedPrefix) else {
            return normalizedPath
        }

        let suffix = String(normalizedPath.dropFirst(normalizedPrefix.count))
        if suffix.isEmpty {
            return normalizedLocalPrefix
        }

        let suffixWithoutLeadingSlash = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
        if normalizedLocalPrefix == "#/" {
            return normalize("#/\(suffixWithoutLeadingSlash)")
        }

        return normalize("\(normalizedLocalPrefix)/\(suffixWithoutLeadingSlash)")
    }
}
