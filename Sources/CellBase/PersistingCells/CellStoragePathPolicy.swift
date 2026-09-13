// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

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

        // Foundation's standardization may rewrite /private/tmp to /tmp only
        // when a path exists. Use a purely lexical first check, then resolve
        // the existing prefix of both paths with the same filesystem rule.
        let rootPath = lexicalPath(root.path)
        let candidatePath = lexicalPath(candidate.path)
        try requireContained(
            candidatePath: candidatePath,
            rootPath: rootPath,
            allowRoot: allowRoot
        )

        // Resolve existing symlink components as a second boundary check.
        try requireContained(
            candidatePath: try physicalPath(candidatePath),
            rootPath: try physicalPath(rootPath),
            allowRoot: allowRoot
        )
        return URL(fileURLWithPath: candidatePath, isDirectory: candidate.hasDirectoryPath)
    }

    private static func lexicalPath(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func physicalPath(_ path: String) throws -> String {
        var prefix = path
        var missing: [String] = []
        while true {
            if let resolved = realpath(prefix, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                let suffix = missing.reversed().joined(separator: "/")
                return suffix.isEmpty ? base : (base == "/" ? base : base + "/") + suffix
            }
            // Do not treat permission errors, loops, or a dangling symlink as
            // an ordinary not-yet-created directory and erase its boundary.
            guard errno == ENOENT, prefix != "/",
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: prefix)) == nil else {
                throw Violation.outsideStorageRoot
            }
            let split = prefix.lastIndex(of: "/")!
            missing.append(String(prefix[prefix.index(after: split)...]))
            prefix = split == prefix.startIndex ? "/" : String(prefix[..<split])
        }
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
