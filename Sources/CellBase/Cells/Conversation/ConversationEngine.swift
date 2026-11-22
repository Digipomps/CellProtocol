// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// How a requester stands in one conversation.
public enum ConversationMemberStatus: Equatable, Sendable {
    case accepted(ConversationMember)
    case pending
    case blocked
    case outsider

    var denial: ConversationDenialReason? {
        switch self {
        case .accepted: return nil
        case .pending: return .pendingInvite
        case .blocked: return .blocked
        case .outsider: return .notMember
        }
    }
}

/// All state changes of one conversation run here, one at a time: sequence
/// allocation, the create-only writes, the index, and the FlowElements. Events
/// are emitted from inside the actor, so the feed carries them in `seq` order.
///
/// Order for a message: inbox copies, then `sent/` (the commit point), then the
/// index, then `message.appended` and the push hook. If a write before `sent/`
/// fails, the inbox copies are removed and nothing is published. If the index
/// fails after `sent/`, the message is kept as committed-but-unindexed; a retry
/// with the same `clientMessageID` completes it with the same `seq`.
actor ConversationEngine {
    nonisolated let conversationID: String
    private let store: ConversationStore
    private let index: ConversationIndex
    private let now: @Sendable () -> Date
    private var initialMeta: ConversationMeta
    private var meta: ConversationMeta
    private var lastSeq = 0
    private var loaded = false
    private var unindexed: [String: ConversationMessage] = [:]
    private var emitter: (@Sendable (FlowElement) -> Void)?
    private var storedHook: (@Sendable (ConversationMessage, [String]) async -> Void)?
    private var membershipObserver: (@Sendable (ConversationMeta) -> Void)?

    // Actor methods are reentrant at every `await`. Sends, read marks and
    // membership changes must not interleave, or two sends take the same seq.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func exclusive<T>(_ body: () async throws -> T) async rethrows -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }

    static let maximumContentLength = 16_000
    static let maximumPageSize = 200

    init(meta: ConversationMeta, store: ConversationStore, index: ConversationIndex, now: @escaping @Sendable () -> Date) {
        self.conversationID = meta.conversationID
        self.initialMeta = meta
        self.meta = meta
        self.store = store
        self.index = index
        self.now = now
    }

    func setEmitter(_ emitter: @escaping @Sendable (FlowElement) -> Void) { self.emitter = emitter }
    func setStoredHook(_ hook: (@Sendable (ConversationMessage, [String]) async -> Void)?) { storedHook = hook }
    func setMembershipObserver(_ observer: @escaping @Sendable (ConversationMeta) -> Void) {
        membershipObserver = observer
        observer(meta)
    }

    // MARK: Loading

    /// Reads the current generation and last sequence from the objects, and
    /// rebuilds the index entry when it does not agree with them.
    func loadIfNeeded() async throws {
        guard !loaded else { return }
        try await exclusive { try await loadLocked() }
    }

    private func loadLocked() async throws {
        guard !loaded else { return }
        if let key = try await store.list(prefix: ConversationStorageLayout.metaPrefix, startAfter: nil).last,
           let data = try await store.read(key) {
            meta = try JSONDecoder().decode(ConversationMeta.self, from: data)
        } else {
            var first = initialMeta
            first.generation = max(1, first.generation)
            try await createIdempotent(ConversationCodec.objectData(first), at: ConversationStorageLayout.metaKey(generation: first.generation))
            meta = first
        }
        let sent = try await store.list(prefix: ConversationStorageLayout.sentPrefix, startAfter: nil)
        lastSeq = sent.last.flatMap(ConversationStorageLayout.seq(fromKey:)) ?? 0
        let indexed = (try? await index.lastSeq(conversationID: conversationID)) ?? -1
        if indexed != lastSeq {
            try await ConversationIndexRebuilder.rebuild(conversationID: conversationID, store: store, index: index)
        } else {
            try await index.recordMeta(meta)
        }
        loaded = true
        membershipObserver?(meta)
    }

    // MARK: Membership

    func status(uuid: String, signingFingerprint: String?) -> ConversationMemberStatus {
        if meta.blockedUUIDs.contains(uuid) { return .blocked }
        if let member = meta.members.first(where: { $0.uuid == uuid }) {
            if let recorded = member.signingPublicKeyFingerprint, recorded != signingFingerprint { return .outsider }
            return .accepted(member)
        }
        if meta.pendingInviteeUUIDs.contains(uuid) { return .pending }
        return .outsider
    }

    func currentMeta() -> ConversationMeta { meta }

    /// Records a new generation when title or membership changed. Returns the
    /// generation now in force.
    @discardableResult
    func applyMembership(title: String, members: [ConversationMember], pending: [String], blocked: [String]) async throws -> Int {
        try await loadIfNeeded()
        return try await exclusive { try await applyMembershipLocked(title: title, members: members, pending: pending, blocked: blocked) }
    }

    private func applyMembershipLocked(title: String, members: [ConversationMember], pending: [String], blocked: [String]) async throws -> Int {
        var next = meta
        next.title = title
        next.members = members.sorted { $0.uuid < $1.uuid }
        next.pendingInviteeUUIDs = Array(Set(pending)).sorted()
        next.blockedUUIDs = Array(Set(blocked)).sorted()
        guard !next.sameMembership(as: meta) else { return meta.generation }
        next.generation = meta.generation + 1
        next.updatedAt = ConversationCodec.timestamp(now())
        try await store.create(ConversationCodec.objectData(next), at: ConversationStorageLayout.metaKey(generation: next.generation))
        meta = next
        try await index.recordMeta(next)
        membershipObserver?(next)
        emit("member.changed", [
            "conversationID": .string(conversationID),
            "generation": .integer(next.generation),
            "lastSeq": .integer(lastSeq)
        ])
        return next.generation
    }

    // MARK: Messages

    func send(author: ConversationMember, clientMessageID: String, contentType: String, content: String) async -> ConversationSendResult {
        let trimmedID = clientMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, trimmedID.count <= 128,
              contentType == "text/plain",
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              content.count <= Self.maximumContentLength else {
            return .failure(.invalidPayload)
        }
        do { try await loadIfNeeded() } catch { return .failure(.storageFailed) }
        return await exclusive {
            await sendLocked(author: author, trimmedID: trimmedID, contentType: contentType, content: content)
        }
    }

    private func sendLocked(author: ConversationMember, trimmedID: String, contentType: String, content: String) async -> ConversationSendResult {
        guard case .accepted = status(uuid: author.uuid, signingFingerprint: author.signingPublicKeyFingerprint) else {
            return .failure(status(uuid: author.uuid, signingFingerprint: author.signingPublicKeyFingerprint).denial ?? .notMember)
        }
        await flushUnindexed(except: trimmedID)

        // Committed earlier but the index failed: finish that message.
        if let pending = unindexed[trimmedID] {
            guard pending.authorUUID == author.uuid else { return .failure(.invalidPayload) }
            do {
                try await index.record(pending)
            } catch {
                return .failure(.storageFailed)
            }
            unindexed.removeValue(forKey: trimmedID)
            await publish(pending)
            return .stored(pending, duplicate: false)
        }
        // Already stored and indexed: the same answer, nothing new.
        do {
            if let known = try await index.message(conversationID: conversationID, clientMessageID: trimmedID) {
                guard known.authorUUID == author.uuid,
                      let data = try await store.read(ConversationStorageLayout.sentKey(seq: known.seq, messageID: known.messageID)) else {
                    return .failure(known.authorUUID == author.uuid ? .storageFailed : .invalidPayload)
                }
                return .stored(try JSONDecoder().decode(ConversationMessage.self, from: data), duplicate: true)
            }
        } catch {
            return .failure(.storageFailed)
        }

        let message = ConversationMessage(
            conversationID: conversationID,
            seq: lastSeq + 1,
            messageID: UUID().uuidString,
            clientMessageID: trimmedID,
            authorUUID: author.uuid,
            authorDisplayName: author.displayName,
            contentType: contentType,
            content: content,
            createdAt: ConversationCodec.timestamp(now())
        )
        let data: Data
        do { data = try ConversationCodec.objectData(message) } catch { return .failure(.storageFailed) }
        let recipients = meta.members.map(\.uuid).filter { $0 != author.uuid && !meta.blockedUUIDs.contains($0) }
        var written = [String]()
        do {
            for member in recipients {
                let key = ConversationStorageLayout.inboxKey(memberUUID: member, seq: message.seq, messageID: message.messageID)
                try await store.create(data, at: key)
                written.append(key)
            }
            try await store.create(data, at: ConversationStorageLayout.sentKey(seq: message.seq, messageID: message.messageID))
        } catch {
            for key in written { try? await store.delete(key) }
            return .failure(.storageFailed)
        }
        lastSeq = message.seq
        do {
            try await index.record(message)
        } catch {
            unindexed[trimmedID] = message
            return .failure(.storageFailed)
        }
        await publish(message)
        if let storedHook { await storedHook(message, recipients) }
        return .stored(message, duplicate: false)
    }

    /// Migration: stores a message written before this conversation had its own
    /// cell, with its original author, time and id (as clientMessageID). Not
    /// published and not pushed. Idempotent on clientMessageID.
    func importMessage(clientMessageID: String, authorUUID: String, authorDisplayName: String,
                       content: String, createdAt: String) async -> ConversationSendResult {
        do { try await loadIfNeeded() } catch { return .failure(.storageFailed) }
        return await exclusive {
            do {
                if let known = try await index.message(conversationID: conversationID, clientMessageID: clientMessageID),
                   let data = try await store.read(ConversationStorageLayout.sentKey(seq: known.seq, messageID: known.messageID)) {
                    return .stored(try JSONDecoder().decode(ConversationMessage.self, from: data), duplicate: true)
                }
                let message = ConversationMessage(
                    conversationID: conversationID, seq: lastSeq + 1, messageID: UUID().uuidString,
                    clientMessageID: clientMessageID, authorUUID: authorUUID, authorDisplayName: authorDisplayName,
                    content: content, createdAt: createdAt)
                let data = try ConversationCodec.objectData(message)
                for member in meta.members.map(\.uuid) where member != authorUUID {
                    try await store.create(data, at: ConversationStorageLayout.inboxKey(memberUUID: member, seq: message.seq, messageID: message.messageID))
                }
                try await store.create(data, at: ConversationStorageLayout.sentKey(seq: message.seq, messageID: message.messageID))
                lastSeq = message.seq
                try await index.record(message)
                return .stored(message, duplicate: false)
            } catch {
                return .failure(.storageFailed)
            }
        }
    }

    /// Every committed message after `afterSeq`, for the hosting scaffold.
    func allMessages(afterSeq: Int) async throws -> [ConversationMessage] {
        var result = [ConversationMessage]()
        var cursor = afterSeq
        while true {
            let page = try await since(afterSeq: cursor, limit: Self.maximumPageSize)
            result += page.messages
            guard page.hasMore, let last = page.messages.last?.seq else { return result }
            cursor = last
        }
    }

    func since(afterSeq: Int, limit: Int) async throws -> ConversationMessagePage {
        try await loadIfNeeded()
        let size = min(max(1, limit), Self.maximumPageSize)
        let keys = try await store.list(
            prefix: ConversationStorageLayout.sentPrefix,
            startAfter: ConversationStorageLayout.sentStartAfter(seq: max(0, afterSeq) + 1)
        )
        var messages = [ConversationMessage]()
        for key in keys.prefix(size) {
            guard let data = try await store.read(key) else { continue }
            let message = try JSONDecoder().decode(ConversationMessage.self, from: data)
            if message.seq > afterSeq { messages.append(message) }
        }
        return ConversationMessagePage(messages: messages, lastSeq: lastSeq, hasMore: keys.count > size)
    }

    func markRead(member: ConversationMember, uptoSeq: Int) async throws -> (readUpto: Int, unread: Int) {
        try await loadIfNeeded()
        return try await exclusive { try await markReadLocked(member: member, uptoSeq: uptoSeq) }
    }

    private func markReadLocked(member: ConversationMember, uptoSeq: Int) async throws -> (readUpto: Int, unread: Int) {
        let target = min(max(0, uptoSeq), lastSeq)
        let current = try await index.readUpto(conversationID: conversationID, memberUUID: member.uuid)
        if target > current {
            try await createIdempotent(Data("{}".utf8), at: ConversationStorageLayout.readKey(memberUUID: member.uuid, uptoSeq: target))
            try await index.setReadUpto(conversationID: conversationID, memberUUID: member.uuid, seq: target)
            emit("read.updated", [
                "conversationID": .string(conversationID),
                "memberUUID": .string(member.uuid),
                "uptoSeq": .integer(target),
                "lastSeq": .integer(lastSeq)
            ])
        }
        let readUpto = max(target, current)
        let unread = try await index.unread(conversationID: conversationID, memberUUID: member.uuid)
        return (readUpto, unread)
    }

    func state(for member: ConversationMember) async throws -> Object {
        try await loadIfNeeded()
        let readUpto = try await index.readUpto(conversationID: conversationID, memberUUID: member.uuid)
        let unread = try await index.unread(conversationID: conversationID, memberUUID: member.uuid)
        let recent = try await since(afterSeq: max(0, lastSeq - 50), limit: 50)
        return [
            "conversationID": .string(conversationID),
            "title": .string(meta.title),
            "members": .list(meta.members.map { .object(["uuid": .string($0.uuid), "displayName": .string($0.displayName)]) }),
            "generation": .integer(meta.generation),
            "lastSeq": .integer(lastSeq),
            "unread": .integer(unread),
            "readUptoSeq": .integer(readUpto),
            "messages": .list(try recent.messages.map { try ConversationCodec.value($0) })
        ]
    }

    func preview() async throws -> Object {
        try await loadIfNeeded()
        return [
            "conversationID": .string(conversationID),
            "title": .string(meta.title),
            "inviterDisplayName": .string(meta.inviterDisplayName)
        ]
    }

    // MARK: Helpers

    private func flushUnindexed(except clientMessageID: String) async {
        for (id, message) in unindexed where id != clientMessageID {
            if (try? await index.record(message)) != nil {
                unindexed.removeValue(forKey: id)
            }
        }
    }

    /// Create-only, but writing the same bytes again counts as done.
    private func createIdempotent(_ data: Data, at key: String) async throws {
        do {
            try await store.create(data, at: key)
        } catch ConversationStoreError.alreadyExists {
            guard try await store.read(key) == data else { throw ConversationStoreError.alreadyExists(key) }
        }
    }

    private func publish(_ message: ConversationMessage) async {
        guard let value = try? ConversationCodec.value(message) else { return }
        emit("message.appended", [
            "conversationID": .string(conversationID),
            "seq": .integer(message.seq),
            "lastSeq": .integer(lastSeq),
            "message": value
        ])
    }

    private func emit(_ event: String, _ content: Object) {
        var element = FlowElement(
            title: event,
            content: .object(content),
            properties: FlowElement.Properties(type: .event, contentType: .object)
        )
        element.topic = ConversationCell.flowTopic
        emitter?(element)
    }
}
