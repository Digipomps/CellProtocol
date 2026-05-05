// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import HavenCoreSchemas

public enum KeyPathRegistryError: Error, CustomStringConvertible, Sendable {
    case unreadableDirectory(URL)
    case duplicatePath(String)
    case aliasConflict(String)

    public var description: String {
        switch self {
        case .unreadableDirectory(let url):
            return "Could not read keypath directory: \(url.path)"
        case .duplicatePath(let path):
            return "Duplicate keypath specification for path '\(path)'"
        case .aliasConflict(let alias):
            return "Alias '\(alias)' points to multiple canonical paths"
        }
    }
}

public struct KeyPathRegistry: Sendable {
    public let specs: [KeyPathSpec]
    public let routes: [PathRoute]

    private let aliasMap: [String: String]

    public init(specs: [KeyPathSpec], routes: [PathRoute]) throws {
        var canonicalByPath = Set<String>()
        var aliasMap: [String: String] = [:]

        let normalizedSpecs = specs.map { spec in
            KeyPathSpec(
                path: JSONPointer.normalize(spec.path),
                typeRef: spec.typeRef,
                owner: spec.owner,
                visibilityClass: spec.visibilityClass,
                aliases: spec.aliases.map(JSONPointer.normalize),
                deprecated: spec.deprecated,
                replacedBy: spec.replacedBy.map(JSONPointer.normalize),
                storageDomain: spec.storageDomain
            )
        }

        for spec in normalizedSpecs {
            if !canonicalByPath.insert(spec.path).inserted {
                throw KeyPathRegistryError.duplicatePath(spec.path)
            }

            for alias in spec.aliases {
                if let existing = aliasMap[alias], existing != spec.path {
                    throw KeyPathRegistryError.aliasConflict(alias)
                }
                aliasMap[alias] = spec.path
            }

            if spec.deprecated, let replacement = spec.replacedBy {
                if let existing = aliasMap[spec.path], existing != replacement {
                    throw KeyPathRegistryError.aliasConflict(spec.path)
                }
                aliasMap[spec.path] = replacement
            }
        }

        self.specs = normalizedSpecs
        self.routes = routes.map {
            PathRoute(
                prefix: JSONPointer.normalize($0.prefix),
                cellType: $0.cellType,
                resolution: $0.resolution,
                localPrefix: JSONPointer.normalize($0.localPrefix)
            )
        }
        self.aliasMap = aliasMap
    }

    public static func load(from keypathsURL: URL = CommonsPaths.keypathsURL()) throws -> KeyPathRegistry {
        let fileManager = FileManager.default
        let namespaces: [URL]

        do {
            namespaces = try fileManager.contentsOfDirectory(
                at: keypathsURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw KeyPathRegistryError.unreadableDirectory(keypathsURL)
        }

        let decoder = JSONDecoder()
        var specs: [KeyPathSpec] = []
        var routes: [PathRoute] = []

        for namespaceURL in namespaces {
            let values = try namespaceURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                continue
            }

            let keyPathSpecsURL = namespaceURL.appendingPathComponent("keypaths.json")
            if fileManager.fileExists(atPath: keyPathSpecsURL.path) {
                let data = try Data(contentsOf: keyPathSpecsURL)
                specs.append(contentsOf: try decoder.decode([KeyPathSpec].self, from: data))
            }

            let routesURL = namespaceURL.appendingPathComponent("routes.json")
            if fileManager.fileExists(atPath: routesURL.path) {
                let data = try Data(contentsOf: routesURL)
                routes.append(contentsOf: try decoder.decode([PathRoute].self, from: data))
            }
        }

        return try KeyPathRegistry(specs: specs, routes: routes)
    }

    public func canonicalize(path inputPath: String) -> (path: String, aliasApplied: String?, deprecated: Bool) {
        var candidate = JSONPointer.normalize(inputPath)
        var aliasApplied: String?
        var seen = Set<String>()

        while let replacement = aliasMap[candidate], !seen.contains(candidate) {
            if aliasApplied == nil {
                aliasApplied = candidate
            }
            seen.insert(candidate)
            candidate = JSONPointer.normalize(replacement)
        }

        let matchedSpec = spec(for: candidate)
        return (candidate, aliasApplied, matchedSpec?.deprecated ?? false)
    }

    public func spec(for inputPath: String) -> KeyPathSpec? {
        let path = JSONPointer.normalize(inputPath)

        if let exact = specs.first(where: { $0.path == path }) {
            return exact
        }

        let wildcardMatches = specs.filter { spec in
            guard spec.path.hasSuffix("/*") else {
                return false
            }

            let prefix = String(spec.path.dropLast(2))
            return path == prefix || path.hasPrefix(prefix + "/")
        }

        return wildcardMatches.max { left, right in
            left.path.count < right.path.count
        }
    }

    public func route(for inputPath: String) -> PathRoute? {
        let path = JSONPointer.normalize(inputPath)
        let matches = routes.filter {
            path == $0.prefix || path.hasPrefix($0.prefix + "/")
        }

        return matches.max { left, right in
            left.prefix.count < right.prefix.count
        }
    }

    public func lintIssues() -> [String] {
        var issues: [String] = []
        let canonicalPaths = Set(specs.map(\.path))

        for spec in specs where spec.deprecated {
            if let replacement = spec.replacedBy, !canonicalPaths.contains(replacement) {
                issues.append("Deprecated path '\(spec.path)' points to missing replacement '\(replacement)'.")
            }
        }

        for (alias, target) in aliasMap where !canonicalPaths.contains(target) {
            issues.append("Alias '\(alias)' points to missing canonical path '\(target)'.")
        }

        for route in routes {
            if route.prefix == "#/" {
                issues.append("Route prefix '#/' is too broad and can shadow all other routes.")
            }
        }

        return issues.sorted()
    }
}
