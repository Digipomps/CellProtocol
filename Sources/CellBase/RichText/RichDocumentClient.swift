// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// Client side of the rich document contract (`haven.document.v1` from
// `document.current`, `haven.document.change.v1` to `document.change`). The
// cell is the only revision authority; this client keeps a queue of local
// changes, sends one at a time, rebases on conflict and keeps unconfirmed
// text on the device. It mirrors CellScaffold `Public/js/haven-rich-document.js`
// so Binding and the web behave the same.

public struct RichDocumentRange: Codable, Equatable, Sendable {
    public var index: Int
    public var length: Int
    public init(index: Int, length: Int) { self.index = index; self.length = length }
}

public struct RichDocumentCommand: Codable, Equatable, Sendable {
    public var schema = "haven.document.change.v1"
    public var operationId: String
    public var clientId: String
    public var baseRevision: Int
    public var kind: String
    public var ops: [RichTextOp]?
    public var range: RichDocumentRange?
    public var text: String?
    public var commentId: String?

    public init(operationId: String = UUID().uuidString, clientId: String, baseRevision: Int, kind: String,
                ops: [RichTextOp]? = nil, range: RichDocumentRange? = nil, text: String? = nil, commentId: String? = nil) {
        self.operationId = operationId; self.clientId = clientId; self.baseRevision = baseRevision; self.kind = kind
        self.ops = ops; self.range = range; self.text = text; self.commentId = commentId
    }
}

public struct RichDocumentSnapshot: Codable, Equatable, Sendable {
    public struct Comment: Codable, Equatable, Sendable {
        public var id: String
        public var author: String
        public var range: RichDocumentRange
        public var text: String
        public var resolved: Bool?
        public var detached: Bool?
    }
    public struct Presence: Codable, Equatable, Sendable {
        public var author: String
        public var clientId: String
        public var range: RichDocumentRange?
        public var updatedAt: Double?
    }
    public struct Message: Codable, Equatable, Sendable {
        public var id: String
        public var author: String
        public var text: String
    }
    public struct HelpEntry: Codable, Equatable, Sendable {
        public var id: String
        public var author: String
        public var question: String
        public var answer: String
    }
    public struct Event: Codable, Equatable, Sendable {
        public var sequence: Int
        public var revision: Int
        public var author: String
        public var command: RichDocumentCommand
    }

    public var schema: String
    public var documentId: String
    public var revision: Int
    public var sequence: Int
    public var ops: [RichTextOp]
    public var comments: [Comment]?
    public var presence: [Presence]?
    public var messages: [Message]?
    public var help: [HelpEntry]?
    public var onboarding: String?
    public var events: [Event]?

    public static let schemaName = "haven.document.v1"
    public var document: RichTextDelta { RichTextDelta(ops) }

    public init(documentId: String, revision: Int, sequence: Int, ops: [RichTextOp], comments: [Comment] = [], presence: [Presence] = [],
                messages: [Message] = [], help: [HelpEntry] = [], events: [Event] = []) {
        self.schema = Self.schemaName; self.documentId = documentId; self.revision = revision; self.sequence = sequence; self.ops = ops
        self.comments = comments; self.presence = presence; self.messages = messages; self.help = help; self.events = events
    }

    /// Reads a `document.current` value. Returns nil for anything that is not
    /// a `haven.document.v1` snapshot (for example `denied`).
    public init?(value: ValueType) {
        guard let plain = RichTextValue(valueType: value),
              let data = try? JSONEncoder().encode(plain),
              let snapshot = try? JSONDecoder().decode(RichDocumentSnapshot.self, from: data),
              snapshot.schema == Self.schemaName else { return nil }
        self = snapshot
    }
}

extension RichTextValue {
    /// Plain JSON view of a cell value; nil for values JSON cannot hold.
    public init?(valueType: ValueType) {
        switch valueType {
        case .null: self = .null
        case .bool(let value): self = .bool(value)
        case .number(let value), .integer(let value): self = .int(value)
        case .float(let value): self = .double(value)
        case .string(let value): self = .string(value)
        case .list(let list):
            var items: [RichTextValue] = []
            for item in list { guard let converted = RichTextValue(valueType: item) else { return nil }; items.append(converted) }
            self = .array(items)
        case .object(let object):
            var items: [String: RichTextValue] = [:]
            for (key, item) in object { guard let converted = RichTextValue(valueType: item) else { return nil }; items[key] = converted }
            self = .object(items)
        default: return nil
        }
    }

    public var valueType: ValueType {
        switch self {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .int(let value): return .integer(value)
        case .double(let value): return .float(value)
        case .string(let value): return .string(value)
        case .array(let items): return .list(items.map(\.valueType))
        case .object(let items): return .object(items.mapValues(\.valueType))
        }
    }

    /// Any Encodable as plain JSON (for commands and drafts).
    public init?<T: Encodable>(encoding value: T) {
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(RichTextValue.self, from: data) else { return nil }
        self = decoded
    }
}

extension RichDocumentCommand {
    public var valueType: ValueType { RichTextValue(encoding: self)?.valueType ?? .null }
}

/// How the session reaches the document cell.
public protocol RichDocumentTransport: Sendable {
    /// `get document.current`.
    func current() async throws -> ValueType?
    /// `set document.change`; returns the cell's answer `{status, current}`.
    func send(_ command: ValueType) async throws -> ValueType?
}

/// Unconfirmed changes kept on the device, per document.
public struct RichDocumentDraft: Codable, Equatable, Sendable {
    public struct Pending: Codable, Equatable, Sendable {
        public var operationId: String
        public var ops: [RichTextOp]
        /// The exact envelope once sent; retried unchanged after an ambiguous failure.
        public var sent: RichDocumentCommand?
    }
    public var documentId: String
    public var clientId: String
    public var confirmedRevision: Int
    public var confirmedOps: [RichTextOp]
    public var queue: [Pending]
}

public protocol RichDocumentDraftStore: Sendable {
    func load(documentId: String) -> RichDocumentDraft?
    func save(_ draft: RichDocumentDraft)
    func remove(documentId: String)
}

/// Drafts as JSON files in a directory (Application Support on Apple platforms).
public struct RichDocumentFileDraftStore: RichDocumentDraftStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    private func url(for documentId: String) -> URL {
        let safe = documentId.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
        return directory.appendingPathComponent("document-draft-\(safe).json")
    }
    public func load(documentId: String) -> RichDocumentDraft? {
        guard let data = try? Data(contentsOf: url(for: documentId)) else { return nil }
        return try? JSONDecoder().decode(RichDocumentDraft.self, from: data)
    }
    public func save(_ draft: RichDocumentDraft) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(draft) else { return }
        try? data.write(to: url(for: draft.documentId), options: .atomic)
    }
    public func remove(documentId: String) { try? FileManager.default.removeItem(at: url(for: documentId)) }
}

public enum RichDocumentStatus: Equatable, Sendable {
    case opening
    case saving(pending: Int)
    case saved
    /// The cell could not be reached; changes stay on the device and are retried.
    case offline(pending: Int)
    case waitingForSafeStorage
    case denied
    /// The cell's history skipped a revision; editing stops so nothing is lost.
    case historyGap
    case rejected(String)
    case notice(String)

    public var text: String {
        switch self {
        case .opening: return "Åpner dokument …"
        case .saving: return "Lagrer endringer …"
        case .saved: return "Alle endringer er lagret i dokumentcellen"
        case .offline(let pending): return pending == 1 ? "Venter på nett · 1 endring lagret på enheten" : "Venter på nett · \(pending) endringer lagret på enheten"
        case .waitingForSafeStorage: return "Venter på sikker lagring. Utkastet beholdes; prøver igjen …"
        case .denied: return "Du har ikke tilgang til å skrive i dette dokumentet."
        case .historyGap: return "Endringshistorikken er ufullstendig. Eksporter utkastet før du åpner dokumentet på nytt."
        case .rejected(let status): return "Endringen ble avvist (\(status)). Utkastet er beholdt; eksporter en kopi."
        case .notice(let text): return text
        }
    }
}

public enum RichDocumentSessionUpdate: Sendable {
    /// Replace the editor's content (first open, restored draft, other document).
    case reset(RichTextDelta, RichDocumentSnapshot)
    /// Apply this change, already rebased over unsent local edits, to the editor.
    case remote(RichTextDelta, RichDocumentSnapshot)
    /// Comments, presence, messages or help changed.
    case snapshot(RichDocumentSnapshot)
    case status(RichDocumentStatus)
}

public enum RichDocumentMetaResult: Equatable, Sendable {
    case accepted
    case waitForText
    case failed(String)
}

/// Runs on the main actor, like the web adapter on its one thread: a local
/// edit, a remote change and the editor's view of the document are always
/// applied in the order they happen. Network calls suspend without blocking.
@MainActor
public final class RichDocumentSession {
    public nonisolated let clientId: String
    private let transport: RichDocumentTransport
    private let drafts: RichDocumentDraftStore?
    private let retryDelay: UInt64
    private var listener: ((RichDocumentSessionUpdate) -> Void)?

    private var latest: RichDocumentSnapshot?
    private var confirmedDocumentId: String?
    private var confirmedRevision = 0
    private var confirmedOps = RichTextDelta()
    private var queue: [RichDocumentDraft.Pending] = []
    private var effectiveClientId: String
    private var busy = false
    private var stopped = false
    private var readOnly = false
    private var retryTask: Task<Void, Never>?
    private var pendingMeta: [String: RichDocumentCommand] = [:]
    public private(set) var status: RichDocumentStatus = .opening

    nonisolated public init(transport: RichDocumentTransport, drafts: RichDocumentDraftStore? = nil,
                clientId: String = UUID().uuidString, retryDelay: Double = 2.5) {
        self.transport = transport
        self.drafts = drafts
        self.clientId = clientId
        self.effectiveClientId = clientId
        self.retryDelay = UInt64(max(0, retryDelay) * 1_000_000_000)
    }

    public func setListener(_ listener: ((RichDocumentSessionUpdate) -> Void)?) { self.listener = listener }

    public var snapshot: RichDocumentSnapshot? { latest }
    public var pendingCount: Int { queue.count }
    public var isReadOnly: Bool { readOnly }
    /// The document as this client has it: confirmed plus every unsent change.
    public var localDocument: RichTextDelta { queue.reduce(confirmedOps) { $0.compose(RichTextDelta($1.ops)) } }

    private func emit(_ update: RichDocumentSessionUpdate) { listener?(update) }

    private func setStatus(_ next: RichDocumentStatus) {
        guard next != status else { return }
        status = next
        emit(.status(next))
    }

    private func settledStatus() {
        guard !stopped else { return }
        setStatus(queue.isEmpty ? .saved : .saving(pending: queue.count))
    }

    /// Reads `document.current` and folds it in.
    @discardableResult
    public func refresh() async -> Bool {
        do {
            guard let value = try await transport.current() else { return false }
            if case .string(let text) = value, text == "denied" {
                readOnly = true; stopped = true; setStatus(.denied); return false
            }
            guard let snapshot = RichDocumentSnapshot(value: value) else { return false }
            accept(snapshot)
            return true
        } catch {
            if confirmedDocumentId != nil { setStatus(.offline(pending: queue.count)) }
            return false
        }
    }

    /// Marks the session read-only (requester lacks write access); nothing is sent.
    public func setReadOnly(_ value: Bool) { readOnly = value }

    public func accept(_ snapshot: RichDocumentSnapshot) {
        if let latest, latest.documentId == snapshot.documentId, snapshot.sequence < latest.sequence { return }
        let previous = latest
        latest = snapshot
        if confirmedDocumentId != snapshot.documentId {
            // First open, or the reference now points at another document.
            queue = []; effectiveClientId = clientId; stopped = false
            if let draft = drafts?.load(documentId: snapshot.documentId), !draft.queue.isEmpty {
                confirmedRevision = draft.confirmedRevision
                confirmedOps = RichTextDelta(draft.confirmedOps)
                effectiveClientId = draft.clientId
                queue = draft.queue
            } else {
                confirmedRevision = snapshot.revision
                confirmedOps = snapshot.document
            }
            confirmedDocumentId = snapshot.documentId
            emit(.reset(localDocument, snapshot))
        }
        for event in snapshot.events ?? [] where event.revision > confirmedRevision {
            guard event.revision == confirmedRevision + 1 else {
                stopped = true; setStatus(.historyGap); return
            }
            var remote = RichTextDelta(event.command.ops ?? [])
            confirmedOps = confirmedOps.compose(remote)
            confirmedRevision = event.revision
            if let first = queue.first, first.operationId == event.command.operationId {
                queue.removeFirst()
            } else {
                for index in queue.indices {
                    let local = RichTextDelta(queue[index].ops)
                    queue[index].ops = remote.transform(local, priority: true).ops
                    remote = local.transform(remote, priority: false)
                }
                emit(.remote(remote, snapshot))
            }
        }
        if previous.map({ $0 != snapshot }) ?? true { emit(.snapshot(snapshot)) }
        saveDraft()
        settledStatus()
        Task { [weak self] in await self?.pump() }
    }

    /// A change the user made in the editor, relative to `localDocument`.
    public func localEdit(_ change: RichTextDelta) {
        guard !change.ops.isEmpty, !readOnly else { return }
        if let tail = queue.last, tail.sent == nil {
            let composed = RichTextDelta(tail.ops).compose(change)
            if composed.ops.isEmpty { queue.removeLast() } else { queue[queue.count - 1].ops = composed.ops }
        } else {
            queue.append(.init(operationId: UUID().uuidString, ops: change.ops, sent: nil))
        }
        saveDraft()
        settledStatus()
        Task { [weak self] in await self?.pump() }
    }

    public func pump() async {
        guard !busy, !stopped, !readOnly, confirmedDocumentId != nil, let item = queue.first else { return }
        busy = true
        let payload = item.sent ?? RichDocumentCommand(operationId: item.operationId, clientId: effectiveClientId,
                                                       baseRevision: confirmedRevision, kind: "delta", ops: item.ops)
        queue[0].sent = payload
        saveDraft()
        let outcome: ValueType?
        do {
            outcome = try await transport.send(payload.valueType)
        } catch {
            busy = false
            guard queue.contains(where: { $0.operationId == item.operationId }) else { settledStatus(); await pump(); return }
            setStatus(.offline(pending: queue.count))
            scheduleRetry()
            return
        }
        busy = false
        let (answer, current) = Self.unwrap(outcome)
        switch answer ?? "" {
        case "conflict":
            if let index = queue.firstIndex(where: { $0.operationId == item.operationId }) { queue[index].sent = nil }
            if let current { accept(current) }
        case "accepted", "duplicate":
            if let current { accept(current) }
        case "persistencePending", "":
            setStatus(answer == nil ? .offline(pending: queue.count) : .waitingForSafeStorage)
            scheduleRetry(); return
        case "denied":
            readOnly = true; stopped = true; setStatus(.denied); return
        default:
            stopped = true; setStatus(.rejected(answer ?? "ukjent")); return
        }
        if !queue.isEmpty, !stopped { await pump() }
    }

    /// Stops sending and retrying, as when the app closes. Unsent changes stay
    /// in the draft store; `refresh()` opens the session again.
    public func close() {
        stopped = true
        retryTask?.cancel()
        retryTask = nil
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        let delay = retryDelay
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.pump()
        }
    }

    /// Comments, presence and messages. Waits for text changes first, like the web.
    public func sendMeta(kind: String, range: RichDocumentRange? = nil, text: String? = nil, commentId: String? = nil) async -> RichDocumentMetaResult {
        guard !readOnly else { return .failed(RichDocumentStatus.denied.text) }
        guard let latest else { return .failed("Dokumentet er ikke åpnet ennå.") }
        guard queue.isEmpty else { return .waitForText }
        let key = "\(kind)|\(range.map { "\($0.index):\($0.length)" } ?? "")|\(text ?? "")|\(commentId ?? "")"
        var payload = pendingMeta[key] ?? RichDocumentCommand(clientId: effectiveClientId, baseRevision: latest.revision, kind: kind,
                                                              range: range, text: text, commentId: commentId)
        pendingMeta[key] = payload
        let textOnly = kind == "help.ask" || kind == "chat.post"
        let documentId = latest.documentId
        for attempt in 0..<2 {
            let outcome: ValueType?
            do { outcome = try await transport.send(payload.valueType) } catch { return .failed("Frakoblet. Prøv igjen.") }
            let (answer, current) = Self.unwrap(outcome)
            let status = answer ?? ""
            if let current {
                guard current.documentId == documentId else { return .failed("Ingen bekreftelse fra dokumentcellen.") }
                accept(current)
            }
            // A conflict proves the envelope was not applied. Text-only messages
            // have no position, so one retry may use the new revision.
            if status == "conflict", textOnly, attempt == 0, let fresh = self.latest, fresh.revision > payload.baseRevision {
                payload.baseRevision = fresh.revision
                pendingMeta[key] = payload
                continue
            }
            pendingMeta[key] = nil
            switch status {
            case "accepted", "duplicate": return .accepted
            case "conflict": return .failed("Dokumentet ble endret. Kontroller markeringen og prøv igjen.")
            case "denied": return .failed(RichDocumentStatus.denied.text)
            default: return .failed("Kunne ikke lagre (\(status.isEmpty ? "ingen bekreftelse" : status)).")
            }
        }
        return .failed("Kunne ikke lagre.")
    }

    private func saveDraft() {
        guard let drafts, let documentId = confirmedDocumentId else { return }
        if queue.isEmpty { drafts.remove(documentId: documentId); return }
        drafts.save(RichDocumentDraft(documentId: documentId, clientId: effectiveClientId, confirmedRevision: confirmedRevision,
                                      confirmedOps: confirmedOps.ops, queue: queue))
    }

    nonisolated static func unwrap(_ value: ValueType?) -> (String?, RichDocumentSnapshot?) {
        guard case .object(var object)? = value else {
            if case .string(let text)? = value { return (text, nil) }
            return (nil, nil)
        }
        if case .object(let inner)? = object["result"] { object = inner }
        guard case .string(let status)? = object["status"] else { return (nil, nil) }
        return (status, object["current"].flatMap(RichDocumentSnapshot.init(value:)))
    }
}
