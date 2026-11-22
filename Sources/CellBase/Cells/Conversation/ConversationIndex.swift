// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// One row in a person's conversation list.
public struct ConversationIndexRow: Codable, Equatable, Sendable {
    public var conversationID: String
    public var title: String
    public var people: [String]
    public var lastSeq: Int
    public var lastMessagePreview: String
    public var lastMessageAuthorUUID: String
    public var lastMessageAt: String
    public var unread: Int
    public var readUptoSeq: Int
}

/// A message's identity as the index knows it.
public struct ConversationIndexedMessage: Codable, Equatable, Sendable {
    public var seq: Int
    public var messageID: String
    public var authorUUID: String
}

/// The index behind conversation lists, unread counts and idempotent send.
/// It only ever holds what can be derived again from the conversation's
/// objects (`sent/`, `read/`, `meta/`), so `ConversationIndexRebuilder`
/// can recreate it from scratch. Implementations: in memory (CellProtocol),
/// SQLite (CellScaffold).
public protocol ConversationIndex: Sendable {
    func recordMeta(_ meta: ConversationMeta) async throws
    func record(_ message: ConversationMessage) async throws
    func setReadUpto(conversationID: String, memberUUID: String, seq: Int) async throws
    func readUpto(conversationID: String, memberUUID: String) async throws -> Int
    func lastSeq(conversationID: String) async throws -> Int
    func message(conversationID: String, clientMessageID: String) async throws -> ConversationIndexedMessage?
    func unread(conversationID: String, memberUUID: String) async throws -> Int
    /// Conversations where `memberUUID` is an accepted, not blocked, member,
    /// newest message first. Conversations without messages sort by creation.
    func conversations(forMember memberUUID: String) async throws -> [ConversationIndexRow]
    /// Forgets everything about one conversation (before a rebuild).
    func reset(conversationID: String) async throws
}

/// Reference implementation, used by CellProtocol tests and by hosts without
/// a database. Same semantics as the SQLite index.
public actor InMemoryConversationIndex: ConversationIndex {
    private struct Entry {
        var meta: ConversationMeta?
        var messages: [Int: ConversationMessage] = [:]
        var byClientID: [String: Int] = [:]
        var readUpto: [String: Int] = [:]
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public func recordMeta(_ meta: ConversationMeta) async throws {
        var entry = entries[meta.conversationID] ?? Entry()
        if (entry.meta?.generation ?? -1) <= meta.generation { entry.meta = meta }
        entries[meta.conversationID] = entry
    }

    public func record(_ message: ConversationMessage) async throws {
        var entry = entries[message.conversationID] ?? Entry()
        entry.messages[message.seq] = message
        entry.byClientID[message.clientMessageID] = message.seq
        entries[message.conversationID] = entry
    }

    public func setReadUpto(conversationID: String, memberUUID: String, seq: Int) async throws {
        var entry = entries[conversationID] ?? Entry()
        entry.readUpto[memberUUID] = max(entry.readUpto[memberUUID] ?? 0, seq)
        entries[conversationID] = entry
    }

    public func readUpto(conversationID: String, memberUUID: String) async throws -> Int {
        entries[conversationID]?.readUpto[memberUUID] ?? 0
    }

    public func lastSeq(conversationID: String) async throws -> Int {
        entries[conversationID]?.messages.keys.max() ?? 0
    }

    public func message(conversationID: String, clientMessageID: String) async throws -> ConversationIndexedMessage? {
        guard let entry = entries[conversationID], let seq = entry.byClientID[clientMessageID],
              let message = entry.messages[seq] else { return nil }
        return ConversationIndexedMessage(seq: seq, messageID: message.messageID, authorUUID: message.authorUUID)
    }

    public func unread(conversationID: String, memberUUID: String) async throws -> Int {
        guard let entry = entries[conversationID] else { return 0 }
        let upto = entry.readUpto[memberUUID] ?? 0
        return entry.messages.values.filter { $0.seq > upto && $0.authorUUID != memberUUID }.count
    }

    public func conversations(forMember memberUUID: String) async throws -> [ConversationIndexRow] {
        var rows = [ConversationIndexRow]()
        for (id, entry) in entries {
            guard let meta = entry.meta, meta.acceptedMember(memberUUID) != nil else { continue }
            let last = entry.messages.values.max { $0.seq < $1.seq }
            let upto = entry.readUpto[memberUUID] ?? 0
            rows.append(ConversationIndexRow(
                conversationID: id,
                title: meta.title,
                people: meta.members.filter { $0.uuid != memberUUID }.map(\.displayName),
                lastSeq: last?.seq ?? 0,
                lastMessagePreview: last.map { ConversationIndexRebuilder.preview($0.content) } ?? "",
                lastMessageAuthorUUID: last?.authorUUID ?? "",
                lastMessageAt: last?.createdAt ?? meta.updatedAt,
                unread: entry.messages.values.filter { $0.seq > upto && $0.authorUUID != memberUUID }.count,
                readUptoSeq: upto
            ))
        }
        return ConversationIndexRebuilder.ordered(rows)
    }

    public func reset(conversationID: String) async throws {
        entries.removeValue(forKey: conversationID)
    }
}

/// Recreates a conversation's index entries from its objects alone.
public enum ConversationIndexRebuilder {
    public static func rebuild(conversationID: String, store: ConversationStore, index: ConversationIndex) async throws {
        try await index.reset(conversationID: conversationID)
        if let metaKey = try await store.list(prefix: ConversationStorageLayout.metaPrefix, startAfter: nil).last,
           let data = try await store.read(metaKey) {
            try await index.recordMeta(JSONDecoder().decode(ConversationMeta.self, from: data))
        }
        for key in try await store.list(prefix: ConversationStorageLayout.sentPrefix, startAfter: nil) {
            guard let data = try await store.read(key) else { continue }
            try await index.record(JSONDecoder().decode(ConversationMessage.self, from: data))
        }
        var highest = [String: Int]()
        for key in try await store.list(prefix: ConversationStorageLayout.readPrefix, startAfter: nil) {
            let parts = key.split(separator: "/")
            guard parts.count == 3, let seq = ConversationStorageLayout.seq(fromKey: key) else { continue }
            highest[String(parts[1])] = max(highest[String(parts[1])] ?? 0, seq)
        }
        for (member, seq) in highest {
            try await index.setReadUpto(conversationID: conversationID, memberUUID: member, seq: seq)
        }
    }

    /// One line, at most 120 characters.
    public static func preview(_ content: String) -> String {
        let line = content.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }

    /// Newest message first; ties broken by id so the order is stable.
    public static func ordered(_ rows: [ConversationIndexRow]) -> [ConversationIndexRow] {
        rows.sorted { lhs, rhs in
            lhs.lastMessageAt != rhs.lastMessageAt ? lhs.lastMessageAt > rhs.lastMessageAt : lhs.conversationID < rhs.conversationID
        }
    }
}
