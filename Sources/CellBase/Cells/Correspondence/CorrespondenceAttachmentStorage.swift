// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A sender-owned Cell component hosted by CorrespondenceCell. Its data actions
/// are exposed exclusively through the parent's exact Agreement-gated operations.
/// Being stored on a relationship host does not give the other member ownership.
public final class CorrespondenceAttachmentCell: GeneralCell {
    let storage: CorrespondenceAttachmentStorage
    private let storageRoot: URL

    public required init(owner: Identity) async {
        storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("haven-attachment-cell-\(UUID().uuidString)")
        storage = CorrespondenceAttachmentStorage(root: storageRoot)
        await super.init(owner: owner)
    }

    init(owner: Identity, root: URL) async {
        storageRoot = root
        storage = CorrespondenceAttachmentStorage(root: root)
        await super.init(owner: owner)
        persistancy = .persistant
    }

    private enum CodingKeys: String, CodingKey { case storageRoot }
    public required init(from decoder: Decoder) throws {
        storageRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HAVEN/CorrespondenceAttachments/restored")
        storage = CorrespondenceAttachmentStorage(root: storageRoot)
        try super.init(from: decoder)
    }
    func provisionStorage(root: URL) async { await storage.provision(root: root) }
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)

    }
}

public struct CorrespondenceAttachmentSourceDescriptor: Codable, Sendable {
    public var metadata: CorrespondenceAttachmentMetadata
    public var referenceURL: URL?
}

public struct CorrespondenceAttachmentPlan: Codable, Sendable {
    public var attachmentID: String
    public var metadata: CorrespondenceAttachmentMetadata
    public var mode: CorrespondenceAttachmentMode
    public var reason: String
    public var reference: String?
    public var header: AttachmentStreamHeader
    /// Present only for a source already held by the sender's Cell. Copy keys
    /// stay in the sender's client and encrypted message, never in server state.
    public var sourceContentKey: Data?
}

public struct CorrespondenceAttachmentRequest: Codable, Equatable, Sendable {
    public var attachmentID: String?
    public var messageID: String
    public var agreementID: String
    public var senderIdentityUUID: String
    public var sourceID: String?
    public var metadata: CorrespondenceAttachmentMetadata?
    public var header: AttachmentStreamHeader?
    public var chunk: AttachmentStreamChunk?
    public var index: UInt64?
    public var confirmation: String?

    private enum CodingKeys: String, CodingKey {
        case attachmentID, messageID, agreementID, senderIdentityUUID, sourceID, metadata, header, chunk, index, confirmation
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(attachmentID, forKey: .attachmentID)
        try values.encode(messageID, forKey: .messageID)
        try values.encode(agreementID, forKey: .agreementID)
        try values.encode(senderIdentityUUID, forKey: .senderIdentityUUID)
        try values.encodeIfPresent(sourceID, forKey: .sourceID)
        if var safe = metadata { safe.name = ""; try values.encode(safe, forKey: .metadata) }
        try values.encodeIfPresent(header, forKey: .header)
        try values.encodeIfPresent(chunk, forKey: .chunk)
        try values.encodeIfPresent(index, forKey: .index)
        try values.encodeIfPresent(confirmation, forKey: .confirmation)
    }

    public init(messageID: String, agreementID: String, senderIdentityUUID: String,
                attachmentID: String? = nil, sourceID: String? = nil,
                metadata: CorrespondenceAttachmentMetadata? = nil,
                header: AttachmentStreamHeader? = nil, chunk: AttachmentStreamChunk? = nil,
                index: UInt64? = nil, confirmation: String? = nil) {
        self.messageID = messageID; self.agreementID = agreementID
        self.senderIdentityUUID = senderIdentityUUID; self.attachmentID = attachmentID
        self.sourceID = sourceID; self.metadata = metadata; self.header = header
        self.chunk = chunk; self.index = index; self.confirmation = confirmation
    }
}

public enum CorrespondenceAttachmentTransfer {
    public static let confirmation = "I understand: the recipient owns this file; I cannot revoke it and it will not expire with the message."
}

actor CorrespondenceAttachmentStorage {
    struct Source: Codable {
        var file: URL
        var metadata: CorrespondenceAttachmentMetadata
        var retainsStorage: Bool
        var referenceURL: URL?
        var reachableKeys: [String: Date]
        var modificationDate: Date?
    }
    struct Entry: Codable {
        var plan: CorrespondenceAttachmentPlan
        var messageID: String
        var agreementID: String
        var sender: String
        var sourceID: String?
        var expiresAt: Date
        var published: Bool = false
        var chunkCount: UInt64 = 0
        var byteCount: UInt64 = 0
        var complete: Bool = false
        var receipts: Set<String> = []
        var revoked: Bool = false
        var transferOffered: Bool = false
        var transferredTo: String?
    }
    struct State: Codable {
        // Local sources stay in memory on the sender's machine. Never persist
        // cleartext source names, URLs, or local paths on a relationship host.
        var sources: [String: Source] = [:]
        var entries: [String: Entry] = [:]
        init() {}
        enum CodingKeys: CodingKey { case entries }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            entries = try values.decodeIfPresent([String: Entry].self, forKey: .entries) ?? [:]
            for id in entries.keys {
                entries[id]?.plan.metadata.name = ""
                entries[id]?.plan.reference = nil
            }
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            var safe = entries
            for id in safe.keys {
                safe[id]?.plan.metadata.name = ""
                safe[id]?.plan.reference = nil
            }
            try values.encode(safe, forKey: .entries)
        }
    }
    private(set) var root: URL
    private var state: State?
    private var committedState: State?
    private var sealers: [String: AttachmentStreamSealer] = [:]
    private var readers: [String: FileHandle] = [:]
    private var cursors: [String: UInt64] = [:]
    // Injectable only through the internal test/host boundary, never on the wire.
    private var writeIndex: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    var writeFile: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    private var eraseDirectory: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    func setEraserForTesting(_ eraser: @escaping (URL) throws -> Void) { eraseDirectory = eraser }

    init(root: URL) { self.root = root }
    func provision(root: URL) {
        self.root = root
        state = nil
        committedState = nil
        recover(now: Date())
    }

    private func load() throws {
        guard state == nil else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let index = root.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: index.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: index))
        } else { state = State() }
        committedState = state
        // Rewrite legacy indexes through the redacting codec before exposing them.
        if FileManager.default.fileExists(atPath: index.path) { try save() }
    }
    private func save() throws {
        do {
            try writeIndex(JSONEncoder().encode(state!), root.appendingPathComponent("state.json"))
            committedState = state
        } catch {
            // A failed durable write must never be observable as a committed
            // transfer/receipt through the actor's in-memory status.
            state = committedState ?? State()
            throw error
        }
    }
    private func directory(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    private func chunkURL(_ id: String, _ index: UInt64) -> URL {
        directory(id).appendingPathComponent("\(index).json")
    }
    private func erase(_ id: String) throws {
        sealers.removeValue(forKey: id)
        if let reader = readers.removeValue(forKey: id) { try reader.close() }
        let path = directory(id)
        if FileManager.default.fileExists(atPath: path.path) {
            do { try eraseDirectory(path) }
            catch { throw CorrespondenceAttachmentError.cleanupFailure("cleanupFailed") }
        }
    }
    func purge(now: Date) throws {
        try load()
        var failed = false
        for (id, entry) in state!.entries where entry.expiresAt <= now && entry.transferredTo == nil {
            // Persist denial before cleanup; a full disk or crash cannot make a
            // stale entry readable because expiry is checked on every request.
            do {
                try erase(id)
                state!.entries.removeValue(forKey: id)
            } catch { failed = true }
        }
        try save()
        if failed { throw CorrespondenceAttachmentError.cleanupFailure("cleanupFailed") }
    }
    func recover(now: Date) {
        try? purge(now: now)
        for entry in state?.entries.values ?? Dictionary<String, Entry>().values where entry.transferredTo == nil {
            scheduleExpiry(at: entry.expiresAt)
        }
    }
    func setIndexWriterForTesting(_ writer: @escaping (Data, URL) throws -> Void) { writeIndex = writer }
    func setWriterForTesting(_ writer: @escaping (Data, URL) throws -> Void) { writeFile = writer }
    func registerSource(id: String, file: URL, metadata: CorrespondenceAttachmentMetadata,
                        retainsStorage: Bool, referenceURL: URL? = nil) throws {
        try load()
        guard state!.sources[id] == nil else { throw CorrespondenceAttachmentError.unavailable }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, values.fileSize.map({ $0 >= 0 && UInt64($0) == metadata.byteCount }) == true else {
            throw CorrespondenceAttachmentError.sizeMismatch
        }
        if let referenceURL {
            guard referenceURL.isFileURL,
                  referenceURL.resolvingSymlinksInPath().standardizedFileURL == file.resolvingSymlinksInPath().standardizedFileURL else {
                throw CorrespondenceAttachmentError.contextMismatch
            }
        }
        state!.sources[id] = Source(file: file, metadata: metadata,
            retainsStorage: retainsStorage, referenceURL: referenceURL, reachableKeys: [:], modificationDate: values.contentModificationDate)
        try save()
    }
    func sourceDescriptor(sourceID: String) throws -> CorrespondenceAttachmentSourceDescriptor {
        try load()
        guard let source = state!.sources[sourceID] else { throw CorrespondenceAttachmentError.unavailable }
        return CorrespondenceAttachmentSourceDescriptor(metadata: source.metadata, referenceURL: source.referenceURL)
    }
    func probe(sourceID: String, recipientKey: String, now: Date) throws -> CorrespondenceAttachmentMetadata {
        try load()
        guard var source = state!.sources[sourceID], source.referenceURL != nil else {
            throw CorrespondenceAttachmentError.unavailable
        }
        // The authenticated recipient records its own successful local reference
        // probe; no bytes are read and the sender cannot assert this on its behalf.
        source.reachableKeys[recipientKey] = now
        state!.sources[sourceID] = source
        try save()
        return source.metadata
    }
    func prepare(_ request: CorrespondenceAttachmentRequest, recipientKeys: Set<String>,
                 reference: String, now: Date) throws -> CorrespondenceAttachmentPlan {
        try purge(now: now)
        let id = UUID().uuidString
        var sealer: AttachmentStreamSealer?
        let plan: CorrespondenceAttachmentPlan
        if let sourceID = request.sourceID {
            guard let source = state!.sources[sourceID] else { throw CorrespondenceAttachmentError.unavailable }
            let reached = Set(source.reachableKeys.filter { now.timeIntervalSince($0.value) >= 0 && now.timeIntervalSince($0.value) < 300 }.keys)
            let mode: CorrespondenceAttachmentMode = !source.retainsStorage ? .copy
                : source.referenceURL != nil && recipientKeys.isSubset(of: reached) ? .reference : .fetchOnDemand
            if mode != .reference { sealer = try AttachmentStreamSealer() }
            plan = CorrespondenceAttachmentPlan(attachmentID: id, metadata: source.metadata,
                mode: mode, reason: mode == .copy ? "Source storage policy does not retain sender storage."
                    : mode == .reference ? "Every recipient has recently verified access to the shared source reference. No bytes are copied."
                    : "Source is in the sender's Cell; no currently verified shared reference reaches every recipient.",
                reference: mode == .reference ? source.referenceURL?.absoluteString : nil,
                header: sealer?.header ?? AttachmentStreamHeader(),
                sourceContentKey: sealer?.contentKey.withUnsafeBytes { Data($0) })
        } else {
            guard let metadata = request.metadata, let header = request.header,
                  header.chunkSize == AttachmentStreamV1.defaultChunkSize else {
                throw CorrespondenceAttachmentError.contextMismatch
            }
            plan = CorrespondenceAttachmentPlan(attachmentID: id, metadata: .init(name: "", mediaType: metadata.mediaType, byteCount: metadata.byteCount), mode: .copy,
                reason: "Local source is outside the Cell's reach; encrypted chunks are imported.",
                reference: nil, header: header, sourceContentKey: nil)
        }
        var persistedPlan = plan
        persistedPlan.sourceContentKey = nil
        state!.entries[id] = Entry(plan: persistedPlan, messageID: request.messageID,
            agreementID: request.agreementID, sender: request.senderIdentityUUID,
            sourceID: request.sourceID, expiresAt: now.addingTimeInterval(3600))
        try FileManager.default.createDirectory(at: directory(id), withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try save()
        sealers[id] = sealer
        scheduleExpiry(at: now.addingTimeInterval(3600))
        return plan
    }
    private func entry(_ request: CorrespondenceAttachmentRequest, now: Date,
                       allowTransferred: Bool = false) throws -> (String, Entry) {
        try load()
        guard let id = request.attachmentID, let entry = state!.entries[id] else {
            throw CorrespondenceAttachmentError.unavailable
        }
        guard entry.messageID == request.messageID, entry.agreementID == request.agreementID,
              entry.sender == request.senderIdentityUUID else { throw CorrespondenceAttachmentError.contextMismatch }
        if entry.expiresAt <= now && !(allowTransferred && entry.transferredTo != nil) {
            try erase(id); throw CorrespondenceAttachmentError.expired
        }
        guard !entry.revoked else { throw CorrespondenceAttachmentError.unavailable }
        return (id, entry)
    }
    func upload(_ request: CorrespondenceAttachmentRequest, now: Date) throws {
        let (id, item) = try entry(request, now: now)
        guard item.sourceID == nil, !item.published, let chunk = request.chunk else {
            throw CorrespondenceAttachmentError.contextMismatch
        }
        try store(chunk, id: id)
    }
    private func store(_ chunk: AttachmentStreamChunk, id: String) throws {
        var item = state!.entries[id]!
        guard !item.complete, chunk.index == item.chunkCount else { throw CorrespondenceAttachmentError.incomplete }
        let length = chunk.combinedCiphertext.count - 28
        guard length >= 0, length <= item.plan.header.chunkSize,
              chunk.isFinal ? length == 0 : length > 0 else { throw CorrespondenceAttachmentError.incomplete }
        let sum = item.byteCount.addingReportingOverflow(UInt64(length))
        guard !sum.overflow, sum.partialValue <= item.plan.metadata.byteCount,
              !chunk.isFinal || sum.partialValue == item.plan.metadata.byteCount else {
            throw CorrespondenceAttachmentError.sizeMismatch
        }
        do {
            try writeFile(JSONEncoder().encode(chunk), chunkURL(id, chunk.index))
            item.chunkCount += 1
            item.byteCount = sum.partialValue
            item.complete = chunk.isFinal
            state!.entries[id] = item
            try save()
        } catch {
            state!.entries[id]?.revoked = true
            do { try erase(id); try save() }
            catch { throw CorrespondenceAttachmentError.cleanupFailure("cleanupFailed") }
            throw CorrespondenceAttachmentError.storageFailure("storageFailed")
        }
    }
    func publish(_ request: CorrespondenceAttachmentRequest, expiresAt: Date, now: Date) throws {
        let (id, item) = try entry(request, now: now)
        guard !item.published, item.sourceID != nil || item.complete else { throw CorrespondenceAttachmentError.incomplete }
        state!.entries[id]?.published = true
        state!.entries[id]?.expiresAt = expiresAt
        try save()
        scheduleExpiry(at: expiresAt)
    }
    private func scheduleExpiry(at date: Date) {
        Task { [weak self] in
            let seconds = max(0, date.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(min(seconds, 90 * 86400) * 1_000_000_000))
            do { try await self?.purge(now: Date()) }
            catch { /* A later purge retries each failed entry; other entries still expire. */ }
        }
    }
    func metadata(_ request: CorrespondenceAttachmentRequest, now: Date) throws -> CorrespondenceAttachmentPlan {
        let (_, item) = try entry(request, now: now)
        guard item.published else { throw CorrespondenceAttachmentError.incomplete }
        var safe = item.plan
        safe.metadata.name = ""
        safe.reference = nil
        return safe
    }
    func fetch(_ request: CorrespondenceAttachmentRequest, recipientKey: String, now: Date) throws -> AttachmentStreamChunk {
        let (id, item) = try entry(request, now: now)
        guard item.plan.mode != .reference, item.published, let index = request.index, item.transferredTo == nil else {
            throw CorrespondenceAttachmentError.incomplete
        }
        let cursorKey = id + ":" + recipientKey
        let expected = index == 0 ? 0 : cursors[cursorKey, default: 0]
        guard index == expected else { throw CorrespondenceAttachmentError.incomplete }
        if index >= item.chunkCount, let sourceID = item.sourceID {
            guard let sealer = sealers[id], let source = state!.sources[sourceID] else {
                // No key/nonce state is recreated after restart. Fail closed.
                throw CorrespondenceAttachmentError.unavailable
            }
            do {
                let version = try source.file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard version.contentModificationDate == source.modificationDate,
                      version.fileSize.map({ $0 >= 0 && UInt64($0) == source.metadata.byteCount }) == true else {
                    throw CorrespondenceAttachmentError.sizeMismatch
                }
                if readers[id] == nil { readers[id] = try FileHandle(forReadingFrom: source.file) }
                let bytes = try readers[id]!.read(upToCount: sealer.header.chunkSize) ?? Data()
                let chunk = try bytes.isEmpty ? sealer.finish() : sealer.sealChunk(bytes)
                try store(chunk, id: id)
                if chunk.isFinal { try readers.removeValue(forKey: id)?.close(); sealers.removeValue(forKey: id) }
            } catch {
                state!.entries[id]?.revoked = true
                try erase(id); try save()
                throw error
            }
        }
        guard index < state!.entries[id]!.chunkCount else { throw CorrespondenceAttachmentError.incomplete }
        let chunk = try JSONDecoder().decode(AttachmentStreamChunk.self, from: Data(contentsOf: chunkURL(id, index)))
        cursors[cursorKey] = index + 1
        return chunk
    }
    func receipt(_ request: CorrespondenceAttachmentRequest, recipientKey: String, now: Date) throws {
        let (id, item) = try entry(request, now: now)
        if item.receipts.contains(recipientKey) { return }
        guard item.complete, cursors[id + ":" + recipientKey] == item.chunkCount else {
            throw CorrespondenceAttachmentError.recipientHasNotFetched
        }
        state!.entries[id]?.receipts.insert(recipientKey)
        try save()
    }
    func revoke(_ request: CorrespondenceAttachmentRequest, now: Date) throws {
        let (id, item) = try entry(request, now: now)
        guard item.transferredTo == nil else { throw CorrespondenceAttachmentError.transferNotOffered }
        state!.entries[id]?.revoked = true
        try save(); try erase(id)
    }
    func transfer(_ request: CorrespondenceAttachmentRequest, now: Date) throws {
        let (id, item) = try entry(request, now: now)
        guard item.plan.mode == .copy else { throw CorrespondenceAttachmentError.transferNotOffered }
        guard !item.receipts.isEmpty else { throw CorrespondenceAttachmentError.recipientHasNotFetched }
        guard request.confirmation == CorrespondenceAttachmentTransfer.confirmation else {
            throw CorrespondenceAttachmentError.confirmationRequired
        }
        state!.entries[id]?.transferOffered = true
        try save()
    }
    func acceptTransfer(_ request: CorrespondenceAttachmentRequest, recipientKey: String, now: Date) throws {
        let (id, item) = try entry(request, now: now, allowTransferred: true)
        guard item.plan.mode == .copy, item.transferOffered else { throw CorrespondenceAttachmentError.transferNotOffered }
        guard item.receipts.contains(recipientKey) else { throw CorrespondenceAttachmentError.recipientHasNotFetched }
        guard item.transferredTo == nil || item.transferredTo == recipientKey else { throw CorrespondenceAttachmentError.wrongRecipient }
        // Durable transfer tombstone precedes deletion. Retry finishes cleanup.
        state!.entries[id]?.transferredTo = recipientKey
        try save(); try erase(id)
    }
    func status(_ request: CorrespondenceAttachmentRequest, now: Date) throws -> (Bool, Bool) {
        let (_, item) = try entry(request, now: now, allowTransferred: true)
        return (item.transferOffered, item.transferredTo != nil)
    }
}
