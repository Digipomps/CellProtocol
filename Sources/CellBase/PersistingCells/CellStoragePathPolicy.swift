// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Constrains persisted-cell paths to a caller-owned storage root.
public enum CellStoragePathPolicy {
    public enum Violation: Error, Equatable {
        case invalidComponent
        case invalidRelativePath
        case outsideStorageRoot
    }

    public static func component(_ component: String, under root: URL) throws -> URL {
        try validateComponent(component)
        return try confinedURL(
            root.appendingPathComponent(component, isDirectory: true),
            under: root,
            allowRoot: false
        )
    }

    public static func relativePath(_ path: String, under root: URL) throws -> URL {
        guard path.utf8.count <= 4_096,
              path.isEmpty == false,
              path.hasPrefix("/") == false,
              path.hasSuffix("/") == false,
              path.contains("\\") == false,
              path.contains("\0") == false else {
            throw Violation.invalidRelativePath
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.isEmpty == false else {
            throw Violation.invalidRelativePath
        }

        var candidate = root
        for component in components {
            try validateComponent(component)
            candidate.appendPathComponent(component, isDirectory: true)
        }
        return try confinedURL(candidate, under: root, allowRoot: false)
    }

    public static func existingURL(_ candidate: URL, under root: URL) throws -> URL {
        try confinedURL(candidate, under: root, allowRoot: false)
    }

    public static func filename(_ filename: String, under directory: URL) throws -> URL {
        try validateComponent(filename)
        return try confinedURL(
            directory.appendingPathComponent(filename, isDirectory: false),
            under: directory,
            allowRoot: false
        )
    }

    private static func validateComponent(_ component: String) throws {
        guard component.isEmpty == false,
              component != ".",
              component != "..",
              component.utf8.count <= 255,
              component.contains("/") == false,
              component.contains("\\") == false,
              component.contains("\0") == false else {
            throw Violation.invalidComponent
        }
    }

    private static func confinedURL(
        _ candidate: URL,
        under root: URL,
        allowRoot: Bool
    ) throws -> URL {
        guard candidate.isFileURL, root.isFileURL else {
            throw Violation.outsideStorageRoot
        }

        let standardizedRoot = root.standardizedFileURL
        let standardizedCandidate = candidate.standardizedFileURL
        try requireContained(
            candidatePath: standardizedCandidate.path,
            rootPath: standardizedRoot.path,
            allowRoot: allowRoot
        )

        // Resolve existing symlink components as a second boundary check.
        let resolvedRoot = standardizedRoot.resolvingSymlinksInPath()
        let resolvedCandidate = standardizedCandidate.resolvingSymlinksInPath()
        try requireContained(
            candidatePath: resolvedCandidate.path,
            rootPath: resolvedRoot.path,
            allowRoot: allowRoot
        )
        return standardizedCandidate
    }

    private static func requireContained(
        candidatePath: String,
        rootPath: String,
        allowRoot: Bool
    ) throws {
        if allowRoot, candidatePath == rootPath {
            return
        }
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidatePath.hasPrefix(rootPrefix) else {
            throw Violation.outsideStorageRoot
        }
    }
}
