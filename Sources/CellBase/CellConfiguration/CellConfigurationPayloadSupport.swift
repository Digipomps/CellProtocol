// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum CellConfigurationPayloadSupport {
    public struct Lookup: Equatable {
        public let uuid: String?
        public let name: String?
        public let sourceCellEndpoint: String?

        public var hasIdentity: Bool {
            uuid != nil || name != nil || sourceCellEndpoint != nil
        }
    }

    private static let nestedConfigurationKeys = [
        "&cellConfiguration",
        "cellConfiguration",
        "configuration",
        "goal",
        "skeletonConfiguration"
    ]
    private static let nestedLookupKeys = [
        "configurationLookup",
        "lookup"
    ]

    public static func decodeCellConfiguration(from value: ValueType?) -> CellConfiguration? {
        guard let value else { return nil }

        if case let .cellConfiguration(configuration) = value {
            return configuration
        }

        if case let .object(object) = value {
            for key in nestedConfigurationKeys {
                if let nestedValue = object[key],
                   let configuration = decodeCellConfiguration(from: nestedValue) {
                    return configuration
                }
            }
        }

        guard let json = try? value.jsonString(),
              let data = json.data(using: .utf8) else {
            return nil
        }

        let decoder = JSONDecoder()
        if let direct = try? decoder.decode(CellConfiguration.self, from: data) {
            return direct
        }

        guard let rawObject = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        return decodeCellConfiguration(fromJSONObject: rawObject, decoder: decoder)
    }

    public static func decodeLookup(from value: ValueType?) -> Lookup? {
        guard case let .object(object)? = value else { return nil }

        if let direct = decodeLookupObject(object), direct.hasIdentity {
            return direct
        }

        for key in nestedLookupKeys {
            guard let nestedValue = object[key] else { continue }
            if let nestedLookup = decodeLookup(from: nestedValue), nestedLookup.hasIdentity {
                return nestedLookup
            }
        }

        for key in nestedConfigurationKeys {
            guard let nestedValue = object[key] else { continue }
            if let nestedLookup = decodeLookup(from: nestedValue), nestedLookup.hasIdentity {
                return nestedLookup
            }
        }

        return nil
    }

    public static func resolveCellConfiguration(
        from value: ValueType,
        requester: Identity,
        candidates: [CellConfiguration] = []
    ) async -> CellConfiguration? {
        if let direct = decodeCellConfiguration(from: value) {
            return retargetingLocalCellEndpointsIfNeeded(
                in: direct,
                sourceEndpoint: direct.discovery?.sourceCellEndpoint
            )
        }

        guard let lookup = decodeLookup(from: value), lookup.hasIdentity else {
            return nil
        }

        if let sourceEndpoint = lookup.sourceCellEndpoint,
           let sourceConfiguration = await resolveSourceBackedOrPublishedConfiguration(
            from: sourceEndpoint,
            requester: requester
           ) {
            return sourceConfiguration
        }

        guard let matched = resolveCellConfiguration(lookup: lookup, candidates: candidates) else {
            return nil
        }
        return retargetingLocalCellEndpointsIfNeeded(
            in: matched,
            sourceEndpoint: matched.discovery?.sourceCellEndpoint
        )
    }

    public static func resolveCellConfiguration(
        from value: ValueType,
        candidates: [CellConfiguration]
    ) -> CellConfiguration? {
        if let direct = decodeCellConfiguration(from: value) {
            return direct
        }

        guard let lookup = decodeLookup(from: value), lookup.hasIdentity else {
            return nil
        }

        return resolveCellConfiguration(lookup: lookup, candidates: candidates)
    }

    public static func decodeConfigurations(from value: ValueType) -> [CellConfiguration] {
        switch value {
        case .list(let values):
            return values.compactMap { decodeCellConfiguration(from: $0) }
        case .object(let object):
            return object.values.compactMap { decodeCellConfiguration(from: $0) }
        default:
            return decodeCellConfiguration(from: value).map { [$0] } ?? []
        }
    }

    public static func retargetingLocalCellEndpoints(
        in configuration: CellConfiguration,
        toScaffoldEndpoint scaffoldEndpoint: String
    ) -> CellConfiguration {
        guard let origin = RetargetOrigin(scaffoldEndpoint: scaffoldEndpoint) else {
            return configuration
        }

        return rewriteEndpointStrings(in: configuration) {
            rewriteLocalCellEndpoint($0, to: origin)
        }
    }

    public static func rewriteLocalCellEndpoint(
        _ endpoint: String,
        toScaffoldEndpoint scaffoldEndpoint: String
    ) -> String {
        guard let origin = RetargetOrigin(scaffoldEndpoint: scaffoldEndpoint) else {
            return endpoint
        }
        return rewriteLocalCellEndpoint(endpoint, to: origin)
    }

    private static func resolveCellConfiguration(
        lookup: Lookup,
        candidates: [CellConfiguration]
    ) -> CellConfiguration? {
        let normalizedUUID = normalizedLookupToken(lookup.uuid)
        let normalizedName = normalizedLookupToken(lookup.name)
        let normalizedEndpoint = normalizedLookupToken(lookup.sourceCellEndpoint)

        return candidates.first { configuration in
            if let normalizedUUID,
               normalizedLookupToken(configuration.uuid) == normalizedUUID {
                return true
            }

            if let normalizedName,
               normalizedLookupToken(configuration.name) == normalizedName {
                if let normalizedEndpoint {
                    let candidateEndpoint = normalizedLookupToken(configuration.discovery?.sourceCellEndpoint)
                    return candidateEndpoint == normalizedEndpoint
                }
                return true
            }

            return false
        }
    }

    private static func resolveSourceBackedOrPublishedConfiguration(
        from sourceEndpoint: String,
        requester: Identity
    ) async -> CellConfiguration? {
        guard let resolver = CellBase.defaultCellResolver,
              let sourceCell = try? await resolver.cellAtEndpoint(
                endpoint: sourceEndpoint,
                requester: requester
              ) as? Meddle
        else {
            return nil
        }

        if let editableStateValue = try? await sourceCell.get(
            keypath: "editableCellConfigurationState",
            requester: requester
        ), let editableConfiguration = decodeEditableStateConfiguration(from: editableStateValue) {
            return retargetingLocalCellEndpointsIfNeeded(
                in: editableConfiguration,
                sourceEndpoint: sourceEndpoint
            )
        }

        for keypath in ["skeletonConfiguration", "purposeGoal", "configuration"] {
            guard let value = try? await sourceCell.get(keypath: keypath, requester: requester),
                  let configuration = decodeCellConfiguration(from: value) else {
                continue
            }

            return retargetingLocalCellEndpointsIfNeeded(
                in: configuration,
                sourceEndpoint: sourceEndpoint
            )
        }

        return nil
    }

    private static func decodeEditableStateConfiguration(from value: ValueType) -> CellConfiguration? {
        guard case let .object(object) = value else { return nil }
        return decodeCellConfiguration(from: object["configuration"])
            ?? decodeCellConfiguration(from: object["fallbackConfiguration"])
    }

    private static func retargetingLocalCellEndpointsIfNeeded(
        in configuration: CellConfiguration,
        sourceEndpoint: String?
    ) -> CellConfiguration {
        guard let sourceEndpoint else { return configuration }
        return retargetingLocalCellEndpoints(
            in: configuration,
            toScaffoldEndpoint: sourceEndpoint
        )
    }

    private static func decodeCellConfiguration(
        fromJSONObject rawObject: Any,
        decoder: JSONDecoder
    ) -> CellConfiguration? {
        guard let dictionary = rawObject as? [String: Any] else { return nil }

        if let data = try? JSONSerialization.data(withJSONObject: dictionary),
           let direct = try? decoder.decode(CellConfiguration.self, from: data) {
            return direct
        }

        for key in nestedConfigurationKeys {
            if let nested = dictionary[key],
               let configuration = decodeCellConfiguration(fromJSONObject: nested, decoder: decoder) {
                return configuration
            }
        }

        return nil
    }

    private static func decodeLookupObject(_ object: Object) -> Lookup? {
        let uuid = trimmedLookupToken(stringValue(object["uuid"]))
        let name = trimmedLookupToken(stringValue(object["name"]))
        let sourceCellEndpoint = trimmedLookupToken(
            stringValue(object["sourceCellEndpoint"])
                ?? stringValue(object["endpoint"])
        )

        let lookup = Lookup(
            uuid: uuid,
            name: name,
            sourceCellEndpoint: sourceCellEndpoint
        )

        return lookup.hasIdentity ? lookup : nil
    }

    private static func stringValue(_ value: ValueType?) -> String? {
        switch value {
        case .string(let string):
            return string
        case .integer(let integer):
            return String(integer)
        case .number(let number):
            return String(number)
        case .float(let float):
            return String(float)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .object(let object):
            return stringValue(object["value"])
        default:
            return nil
        }
    }

    private static func normalizedLookupToken(_ value: String?) -> String? {
        trimmedLookupToken(value)?.lowercased()
    }

    private static func trimmedLookupToken(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func rewriteEndpointStrings(
        in configuration: CellConfiguration,
        transform: (String) -> String
    ) -> CellConfiguration {
        guard let data = try? JSONEncoder().encode(configuration),
              let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let rewrittenObject = rewriteJSONValue(jsonObject, transform: transform),
              JSONSerialization.isValidJSONObject(rewrittenObject),
              let rewrittenData = try? JSONSerialization.data(withJSONObject: rewrittenObject),
              let rewrittenConfiguration = try? JSONDecoder().decode(CellConfiguration.self, from: rewrittenData)
        else {
            return configuration
        }

        return rewrittenConfiguration
    }

    private static func rewriteJSONValue(
        _ value: Any,
        transform: (String) -> String
    ) -> Any? {
        switch value {
        case let string as String:
            return rewriteStringIfEndpointLike(string, transform: transform)
        case let dictionary as [String: Any]:
            var rewritten: [String: Any] = [:]
            rewritten.reserveCapacity(dictionary.count)
            for (key, childValue) in dictionary {
                rewritten[key] = rewriteJSONValue(childValue, transform: transform) ?? childValue
            }
            return rewritten
        case let array as [Any]:
            return array.map { rewriteJSONValue($0, transform: transform) ?? $0 }
        default:
            return value
        }
    }

    private static func rewriteStringIfEndpointLike(
        _ value: String,
        transform: (String) -> String
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("cell://") else {
            return value
        }

        let rewritten = transform(trimmed)
        guard rewritten != trimmed else {
            return value
        }

        let prefixLength = value.distance(
            from: value.startIndex,
            to: value.range(of: trimmed)?.lowerBound ?? value.startIndex
        )
        let suffixLength = value.distance(
            from: value.range(of: trimmed)?.upperBound ?? value.endIndex,
            to: value.endIndex
        )

        let prefix = value.prefix(prefixLength)
        let suffix = value.suffix(suffixLength)
        return "\(prefix)\(rewritten)\(suffix)"
    }

    private static func rewriteLocalCellEndpoint(
        _ endpoint: String,
        to origin: RetargetOrigin
    ) -> String {
        guard var components = URLComponents(string: endpoint),
              components.scheme?.lowercased() == "cell"
        else {
            return endpoint
        }

        let normalizedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedPath.isEmpty else { return endpoint }

        let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLocal = host == nil || host?.isEmpty == true || host?.lowercased() == "localhost"
        guard isLocal else { return endpoint }

        components.host = origin.host
        components.port = origin.port
        components.path = "/" + normalizedPath
        return components.string ?? endpoint
    }

    private struct RetargetOrigin {
        let host: String
        let port: Int?

        init?(scaffoldEndpoint: String) {
            guard let components = URLComponents(string: scaffoldEndpoint),
                  let scheme = components.scheme?.lowercased(),
                  ["cell", "ws", "wss", "http", "https"].contains(scheme),
                  let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !host.isEmpty
            else {
                return nil
            }

            self.host = host
            self.port = components.port
        }
    }
}
