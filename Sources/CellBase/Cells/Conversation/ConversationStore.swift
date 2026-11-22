// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum ConversationStoreError: Error, Equatable, Sendable {
    /// `create` found an object at the key. Objects are never overwritten.
    case alreadyExists(String)
    case invalidKey(String)
    case backend(String)
}

/// Object storage for one conversation's area. Keys are relative to that area
/// (`sent/…`, `inbox/<member>/…`, `read/<member>/…`, `meta/…`). Every write is
/// create-only: an existing object is never replaced. Implementations: local
/// disk (`LocalFileConversationStore`) and S3 (CellScaffold).
public protocol ConversationStore: Sendable {
    /// Writes `data` at `key` only if nothing is there. Throws
    /// `ConversationStoreError.alreadyExists` otherwise.
    func create(_ data: Data, at key: String) async throws
    func read(_ key: String) async throws -> Data?
    /// Keys under `prefix`, ascending, strictly after `startAfter` when given.
    func list(prefix: String, startAfter: String?) async throws -> [String]
    /// Removes an object. Used only to roll back inbox copies of a message
    /// whose `sent/` commit failed; committed objects are never removed.
    func delete(_ key: String) async throws
}

/// Object names. Sequence numbers are zero-padded so lexical order is
/// sequence order on disk and in S3 listings.
public enum ConversationStorageLayout {
    public static let sentPrefix = "sent/"
    public static let inboxPrefix = "inbox/"
    public static let readPrefix = "read/"
    public static let metaPrefix = "meta/"

    public static func padded(_ seq: Int) -> String {
        let digits = String(max(0, seq))
        return String(repeating: "0", count: max(0, 12 - digits.count)) + digits
    }

    public static func sentKey(seq: Int, messageID: String) -> String {
        "\(sentPrefix)\(padded(seq))-\(messageID).json"
    }

    public static func inboxKey(memberUUID: String, seq: Int, messageID: String) -> String {
        "\(inboxPrefix)\(memberUUID)/\(padded(seq))-\(messageID).json"
    }

    public static func readKey(memberUUID: String, uptoSeq: Int) -> String {
        "\(readPrefix)\(memberUUID)/\(padded(uptoSeq)).json"
    }

    public static func metaKey(generation: Int) -> String {
        "\(metaPrefix)\(padded(generation)).json"
    }

    /// The listing position just before the first message with `seq`.
    public static func sentStartAfter(seq: Int) -> String {
        "\(sentPrefix)\(padded(seq))"
    }

    /// The sequence number encoded in a `sent/`, `inbox/`, `read/` or `meta/` key.
    public static func seq(fromKey key: String) -> Int? {
        let name = key.split(separator: "/").last.map(String.init) ?? key
        let digits = name.prefix { $0.isNumber }
        guard digits.count == 12 else { return nil }
        return Int(digits)
    }

    static func validate(_ key: String) throws {
        guard !key.isEmpty, !key.hasPrefix("/"), !key.contains(".."), !key.contains("\\"),
              !key.split(separator: "/").contains(where: { $0.isEmpty || $0 == "." }) else {
            throw ConversationStoreError.invalidKey(key)
        }
    }
}

/// Stores one conversation under a directory on local disk. A write goes to a
/// temporary file which is then hard-linked into place; the link fails when
/// the name exists, so an object is never overwritten and never half-written.
public struct LocalFileConversationStore: ConversationStore {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func create(_ data: Data, at key: String) async throws {
        try ConversationStorageLayout.validate(key)
        let target = root.appendingPathComponent(key)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw ConversationStoreError.backend("mkdir \(key): \(error)")
        }
        if fm.fileExists(atPath: target.path) { throw ConversationStoreError.alreadyExists(key) }
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temporary)
        } catch {
            throw ConversationStoreError.backend("write \(key): \(error)")
        }
        defer { try? fm.removeItem(at: temporary) }
        do {
            try fm.linkItem(at: temporary, to: target)
        } catch {
            if fm.fileExists(atPath: target.path) { throw ConversationStoreError.alreadyExists(key) }
            throw ConversationStoreError.backend("link \(key): \(error)")
        }
    }

    public func read(_ key: String) async throws -> Data? {
        try ConversationStorageLayout.validate(key)
        let target = root.appendingPathComponent(key)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        do {
            return try Data(contentsOf: target)
        } catch {
            throw ConversationStoreError.backend("read \(key): \(error)")
        }
    }

    public func list(prefix: String, startAfter: String?) async throws -> [String] {
        let fm = FileManager.default
        let base = root.standardizedFileURL.path
        guard let enumerator = fm.enumerator(atPath: base) else { return [] }
        var keys = [String]()
        while let relative = enumerator.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            guard !name.hasPrefix("."), relative.hasPrefix(prefix) else { continue }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: base + "/" + relative, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            if let startAfter, relative <= startAfter { continue }
            keys.append(relative)
        }
        return keys.sorted()
    }

    public func delete(_ key: String) async throws {
        try ConversationStorageLayout.validate(key)
        let target = root.appendingPathComponent(key)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        do {
            try FileManager.default.removeItem(at: target)
        } catch {
            throw ConversationStoreError.backend("delete \(key): \(error)")
        }
    }
}
