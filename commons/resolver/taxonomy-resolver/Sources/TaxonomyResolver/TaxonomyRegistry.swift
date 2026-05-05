// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import HavenCoreSchemas

public enum TaxonomyRegistryError: Error, CustomStringConvertible, Sendable {
    case unreadableDirectory(URL)
    case missingPackage(String)
    case duplicateNamespace(String)
    case duplicateTerm(String, namespace: String)
    case cyclicDependency(String)

    public var description: String {
        switch self {
        case .unreadableDirectory(let url):
            return "Could not read taxonomy directory: \(url.path)"
        case .missingPackage(let namespace):
            return "Missing taxonomy package: \(namespace)"
        case .duplicateNamespace(let namespace):
            return "Duplicate taxonomy namespace: \(namespace)"
        case .duplicateTerm(let termID, let namespace):
            return "Duplicate term_id '\(termID)' in package '\(namespace)'"
        case .cyclicDependency(let namespace):
            return "Cyclic taxonomy dependency discovered at namespace '\(namespace)'"
        }
    }
}

public struct TaxonomyRegistry: Sendable {
    public let packages: [String: TaxonomyPackage]

    public init(packages: [TaxonomyPackage]) throws {
        var packageMap: [String: TaxonomyPackage] = [:]

        for package in packages {
            if packageMap[package.namespace] != nil {
                throw TaxonomyRegistryError.duplicateNamespace(package.namespace)
            }

            var seenTermIDs = Set<String>()
            for term in package.terms {
                if !seenTermIDs.insert(term.termId).inserted {
                    throw TaxonomyRegistryError.duplicateTerm(term.termId, namespace: package.namespace)
                }
            }

            packageMap[package.namespace] = package
        }

        self.packages = packageMap
    }

    public static func load(from taxonomiesURL: URL = CommonsPaths.taxonomiesURL()) throws -> TaxonomyRegistry {
        let fileManager = FileManager.default
        let namespaceDirectories: [URL]

        do {
            namespaceDirectories = try fileManager.contentsOfDirectory(
                at: taxonomiesURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw TaxonomyRegistryError.unreadableDirectory(taxonomiesURL)
        }

        let decoder = JSONDecoder()
        var packages: [TaxonomyPackage] = []

        for directory in namespaceDirectories {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                continue
            }

            let packageURL = directory.appendingPathComponent("package.json")
            guard fileManager.fileExists(atPath: packageURL.path) else {
                continue
            }

            let data = try Data(contentsOf: packageURL)
            let package = try decoder.decode(TaxonomyPackage.self, from: data)
            packages.append(package)
        }

        return try TaxonomyRegistry(packages: packages)
    }

    public func package(named namespace: String) -> TaxonomyPackage? {
        packages[namespace]
    }

    public func lookupTerm(termID: String, namespace: String? = nil) throws -> (term: Term, namespace: String)? {
        for package in try resolutionOrder(startingAt: namespace) {
            if let term = package.terms.first(where: { $0.termId == termID }) {
                return (term, package.namespace)
            }
        }

        return nil
    }

    public func resolutionOrder(startingAt namespace: String? = nil) throws -> [TaxonomyPackage] {
        guard let namespace else {
            return packages.keys.sorted().compactMap { packages[$0] }
        }

        var result: [TaxonomyPackage] = []
        var visited = Set<String>()
        var stack = Set<String>()

        func visit(_ current: String) throws {
            if visited.contains(current) {
                return
            }

            if stack.contains(current) {
                throw TaxonomyRegistryError.cyclicDependency(current)
            }

            guard let package = packages[current] else {
                throw TaxonomyRegistryError.missingPackage(current)
            }

            stack.insert(current)
            result.append(package)

            for dependency in package.dependsOn {
                try visit(dependency)
            }

            stack.remove(current)
            visited.insert(current)
        }

        try visit(namespace)
        return result
    }
}
