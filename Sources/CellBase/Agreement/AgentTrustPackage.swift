// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// purposeRef: purpose://candidate.tillitspakke-agentflaate.projeksjon

/// A projection of fleet configuration and observed authority sources.
/// Neither this package, its digest nor a purpose reference grants authority.
public struct AgentTrustPackage: Codable, Equatable, Sendable {
    public static let schemaV0 = "haven.agent-trust-package.v0"

    public enum Role: String, Codable, Sendable {
        case agent, service, secrets
    }

    public struct ModelRoute: Codable, Equatable, Sendable {
        public enum Hosting: String, Codable, Sendable {
            case hosted, local
        }

        public var providerID: String
        public var model: String
        public var hosting: Hosting
        public var baseURLDigest: String

        public init(providerID: String, model: String, hosting: Hosting, baseURLDigest: String) {
            self.providerID = providerID
            self.model = model
            self.hosting = hosting
            self.baseURLDigest = baseURLDigest
        }
    }

    public struct Instruction: Codable, Equatable, Sendable {
        public var keypath: String
        public var digest: String

        public init(keypath: String, digest: String) {
            self.keypath = keypath
            self.digest = digest
        }
    }

    public struct Grant: Codable, Equatable, Sendable {
        public var keypath: String
        public var permission: String

        public init(keypath: String, permission: String) {
            self.keypath = keypath
            self.permission = permission
        }
    }

    public struct Contract: Codable, Equatable, Sendable {
        public var contractID: String
        public var subject: String
        public var grants: [String]
        public var expiresAt: String
        public var verified: Bool

        public init(contractID: String, subject: String, grants: [String], expiresAt: String, verified: Bool) {
            self.contractID = contractID
            self.subject = subject
            self.grants = grants
            self.expiresAt = expiresAt
            self.verified = verified
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(contractID, forKey: .contractID)
            try container.encode(subject, forKey: .subject)
            try container.encode(grants, forKey: .grants)
            try container.encode(AgentTrustPackageCanonicalEncoder.rfc3339UTC(expiresAt), forKey: .expiresAt)
            try container.encode(verified, forKey: .verified)
        }

        enum CodingKeys: String, CodingKey {
            case contractID, subject, grants, expiresAt, verified
        }
    }

    public struct Ceiling: Codable, Equatable, Sendable {
        public enum ProviderTools: String, Codable, Sendable {
            case off
            case notApplicable = "n/a"
        }

        public var destinations: [String]
        public var dataClasses: [String]
        public var hostPatterns: [String]
        public var methods: [String]
        public var https: Bool
        public var allowCredentials: Bool
        public var storage: Bool
        public var disclosure: Bool
        public var providerTools: ProviderTools

        public init(
            destinations: [String], dataClasses: [String], hostPatterns: [String], methods: [String],
            https: Bool, allowCredentials: Bool, storage: Bool, disclosure: Bool, providerTools: ProviderTools
        ) {
            self.destinations = destinations
            self.dataClasses = dataClasses
            self.hostPatterns = hostPatterns
            self.methods = methods
            self.https = https
            self.allowCredentials = allowCredentials
            self.storage = storage
            self.disclosure = disclosure
            self.providerTools = providerTools
        }
    }

    public struct Policy: Codable, Equatable, Sendable {
        public var policyID: String
        public var policyVersion: String
        public var policyDigest: String
        public var configDigest: String
        public var taxonomyDigest: String

        public init(
            policyID: String, policyVersion: String, policyDigest: String,
            configDigest: String, taxonomyDigest: String
        ) {
            self.policyID = policyID
            self.policyVersion = policyVersion
            self.policyDigest = policyDigest
            self.configDigest = configDigest
            self.taxonomyDigest = taxonomyDigest
        }
    }

    public struct Cell: Codable, Equatable, Sendable {
        public var id: String
        public var endpoint: String
        public var role: Role
        public var modelRoute: ModelRoute?
        public var instruction: Instruction?
        public var templateGrants: [Grant]?
        public var contracts: [Contract]?
        public var ceiling: Ceiling?
        public var policy: Policy?

        public init(
            id: String, endpoint: String, role: Role, modelRoute: ModelRoute? = nil,
            instruction: Instruction? = nil, templateGrants: [Grant]? = nil,
            contracts: [Contract]? = nil, ceiling: Ceiling? = nil, policy: Policy? = nil
        ) {
            self.id = id
            self.endpoint = endpoint
            self.role = role
            self.modelRoute = modelRoute
            self.instruction = instruction
            self.templateGrants = templateGrants
            self.contracts = contracts
            self.ceiling = ceiling
            self.policy = policy
        }
    }

    public struct Edge: Codable, Equatable, Sendable {
        public var from: String
        public var to: String
        public var keypath: String
        public var permission: String

        public init(from: String, to: String, keypath: String, permission: String) {
            self.from = from
            self.to = to
            self.keypath = keypath
            self.permission = permission
        }
    }

    public struct ReachEntry: Codable, Equatable, Sendable {
        public var agent: String
        public var path: [String]
        public var destinations: [String]
        public var credentials: Bool
        public var permissions: String
        public var summary: String

        public init(
            agent: String, path: [String], destinations: [String], credentials: Bool,
            permissions: String, summary: String
        ) {
            self.agent = agent
            self.path = path
            self.destinations = destinations
            self.credentials = credentials
            self.permissions = permissions
            self.summary = summary
        }
    }

    /// The contract uses entries. The supplied WP1 fixture instead contains this
    /// one unresolved reference, preserved verbatim for a lossless round-trip.
    /// A reference is not resolved or treated as evidence of reachable authority;
    /// only its literal text, not the referenced file, is covered by the digest.
    public enum Reach: Codable, Equatable, Sendable {
        case entries([ReachEntry])
        case fixtureReference

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let reference = try? container.decode(String.self) {
                guard reference == Self.reference else {
                    throw Swift.DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown reach reference")
                }
                self = .fixtureReference
            } else {
                self = .entries(try container.decode([ReachEntry].self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .entries(let entries): try container.encode(entries)
            case .fixtureReference: try container.encode(Self.reference)
            }
        }

        private static let reference = "see fleet-webfetch.reach.json"
    }

    public var schema: String
    public var fleetID: String
    public var generatedAt: String
    public var packageDigest: String
    public var cells: [Cell]
    public var edges: [Edge]
    public var reach: Reach

    public init(
        schema: String = Self.schemaV0, fleetID: String, generatedAt: String,
        packageDigest: String = "", cells: [Cell], edges: [Edge], reach: Reach
    ) {
        self.schema = schema
        self.fleetID = fleetID
        self.generatedAt = generatedAt
        self.packageDigest = packageDigest
        self.cells = cells
        self.edges = edges
        self.reach = reach
    }

    public func encode(to encoder: Encoder) throws {
        // Validate the entire wire representation even with a plain JSONEncoder.
        // Contents avoids recursively invoking this guard while inspecting it.
        _ = try AgentTrustPackageCanonicalEncoder.encode(Contents(package: self))
        try encodeContents(to: encoder)
    }

    private struct Contents: Encodable {
        let package: AgentTrustPackage

        func encode(to encoder: Encoder) throws {
            try package.encodeContents(to: encoder)
        }
    }

    private func encodeContents(to encoder: Encoder) throws {
        guard schema == Self.schemaV0 else {
            throw AgentTrustPackageCanonicalEncoder.ValidationError.unsupportedSchema
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(fleetID, forKey: .fleetID)
        try container.encode(AgentTrustPackageCanonicalEncoder.rfc3339UTC(generatedAt), forKey: .generatedAt)
        try container.encode(packageDigest, forKey: .packageDigest)
        try container.encode(cells, forKey: .cells)
        try container.encode(edges, forKey: .edges)
        try container.encode(reach, forKey: .reach)
    }

    enum CodingKeys: String, CodingKey {
        case schema, fleetID, generatedAt, packageDigest, cells, edges, reach
    }
}

/// Canonical UTF-8 JSON: sorted object keys, no insignificant whitespace, no
/// escaped slashes, original array order and RFC3339 UTC timestamps. The digest
/// covers every encoded field except the top-level `packageDigest` itself.
///
/// Secret guard (`test.tp.ingen-hemmeligheter`): recursively reject field names
/// containing `key`, `secret`, `token`, `password` or `prompt`, case-insensitively,
/// except the exact name `keypath` (also case-insensitive). Reject string values
/// containing `sk-`, `AKIA` or `-----BEGIN`, or consisting entirely of more than
/// 40 ASCII base64 characters (A-Z, a-z, 0-9, +, /, optional trailing = padding),
/// with no whitespace. This conservative heuristic can reject benign opaque
/// identifiers; it cannot identify all secrets or arbitrary prose instructions.
/// Errors contain neither the rejected field name nor its value.
public enum AgentTrustPackageCanonicalEncoder {
    public enum ValidationError: Error, Equatable, Sendable {
        case forbiddenField
        case secretLikeValue
        case invalidTimestamp
        case unsupportedSchema
    }

    /// Encode a package or an Encodable projection through the same secret guard.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try validate(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
        return data
    }

    public static func canonicalBytes(for package: AgentTrustPackage) throws -> Data {
        let data = try encode(package)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "packageDigest")
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    public static func digest(for package: AgentTrustPackage) throws -> String {
        try PurposeBindingDigest.sha256(
            domain: AgentTrustPackage.schemaV0,
            components: [canonicalBytes(for: package)]
        )
    }

    private static func validate(_ value: Any) throws {
        if let object = value as? [String: Any] {
            for (field, child) in object {
                let name = field.lowercased()
                if name != "keypath" && ["key", "secret", "token", "password", "prompt"].contains(where: name.contains) {
                    throw ValidationError.forbiddenField
                }
                try validate(child)
            }
        } else if let array = value as? [Any] {
            for child in array { try validate(child) }
        } else if let string = value as? String {
            let base64 = string.utf8.count > 40
                && string.range(of: #"\A[A-Za-z0-9+/]+={0,2}\z"#, options: .regularExpression) != nil
            if string.contains("sk-") || string.contains("AKIA") || string.contains("-----BEGIN") || base64 {
                throw ValidationError.secretLikeValue
            }
        }
    }

    /// Normalize the timezone without rounding away fractional seconds. Keeping
    /// the fractional digits as text ensures even sub-millisecond changes bind.
    // WP9 reuses this normalization for signed receipts.
    // purposeRef: purpose://candidate.tillitspakke-agentflaate.signert-kvittering
    static func rfc3339UTC(_ value: String) throws -> String {
        let pattern = #"\A([0-9]{4}-[0-9]{2}-[0-9]{2})[Tt]([0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})\z"#
        let expression = try NSRegularExpression(pattern: pattern)
        guard let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else {
            throw ValidationError.invalidTimestamp
        }
        func part(_ index: Int) -> String {
            guard let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range])
        }
        let zone = part(4).uppercased()
        // RFC3339 -00:00 means an unknown offset, not known UTC.
        guard zone != "-00:00" else { throw ValidationError.invalidTimestamp }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let whole = part(1) + "T" + part(2)
        guard let date = formatter.date(from: whole + zone) else { throw ValidationError.invalidTimestamp }
        if zone == "Z" {
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
        } else {
            let hours = Int(zone.dropFirst().prefix(2))!
            let minutes = Int(zone.suffix(2))!
            guard hours <= 23, minutes <= 59,
                  let timeZone = TimeZone(secondsFromGMT: (zone.first == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)) else {
                throw ValidationError.invalidTimestamp
            }
            formatter.timeZone = timeZone
        }
        // Reject dates that Foundation would silently normalize (e.g. Feb 31).
        guard formatter.string(from: date).hasPrefix(whole) else { throw ValidationError.invalidTimestamp }
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        var fraction = part(3)
        while fraction.last == "0" { fraction.removeLast() }
        if fraction == "." { fraction = "" }
        return String(formatter.string(from: date).dropLast()) + fraction + "Z"
    }
}
