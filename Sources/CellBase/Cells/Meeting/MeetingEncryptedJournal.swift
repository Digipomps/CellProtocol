import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Host state journal; the caller obtains the 256-bit key from its existing
/// identity vault. The key is never written alongside these encrypted records.
/// The journal cannot restore recording authority; MeetingConsentSession restore
/// creates a fresh incarnation and invalidates every approval.
public final class MeetingEncryptedJournal: @unchecked Sendable {
    public struct Record: Codable, Sendable {
        public let sequence: UInt64
        public let previousHash: String?
        public let cellID: String
        public let owner: MeetingPrincipal
        public let snapshot: MeetingConsentSnapshot?
        public let consents: [MeetingSignedConsent]
        public let startOperations: [UUID]
        public let initialOperations: [UUID: MeetingOperationRecord]
    }
    private let lock = NSLock()
    private let store: any MeetingDurableStore
    private let key: SymmetricKey
    private let cellID: String
    private let owner: MeetingPrincipal
    private var sequence: UInt64 = 0
    private var headHash: String?
    private var pending: (Record, Data)?
    public private(set) var latest: Record?

    public init(store: any MeetingDurableStore, key: Data, cellID: String, owner: MeetingPrincipal) throws {
        guard key.count == 32, UUID(uuidString: cellID) != nil else { throw MeetingSessionError.invalidPlan }
        self.store = store; self.key = SymmetricKey(data: key); self.cellID = cellID; self.owner = owner
        let keys = try store.keys().filter { $0.hasPrefix("journal-") }.sorted()
        guard keys.count <= 4096 else { throw MeetingSessionError.unavailable }
        for name in keys {
            guard name == fileKey(sequence + 1), let encrypted = try store.read(name) else { throw MeetingSessionError.wrongPackage }
            let decoded = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: self.key, authenticating: aad(sequence + 1))
            let record = try JSONDecoder().decode(Record.self, from: decoded)
            guard record.sequence == sequence + 1, record.previousHash == headHash,
                  record.cellID == cellID, record.owner == owner else { throw MeetingSessionError.wrongPackage }
            latest = record; sequence = record.sequence; headHash = FlowHasher.sha256Hex(encrypted)
        }
    }
    private func fileKey(_ sequence: UInt64) -> String { "journal-" + String(format: "%020llu", sequence) }
    private func aad(_ sequence: UInt64) -> Data { Data("haven.meeting.journal.v1|\(cellID)|\(sequence)".utf8) }
    public func commit(snapshot: MeetingConsentSnapshot?, consents: [MeetingSignedConsent], startOperations: [UUID], initialOperations: [UUID: MeetingOperationRecord] = [:]) throws {
        lock.lock(); defer { lock.unlock() }
        if let (record, encrypted) = pending {
            try store.commit(encrypted, key: fileKey(record.sequence))
            guard try store.read(fileKey(record.sequence)) == encrypted else { throw MeetingSessionError.unavailable }
            latest = record; sequence = record.sequence; headHash = FlowHasher.sha256Hex(encrypted); pending = nil
        }
        guard sequence < 4096 else { throw MeetingSessionError.unavailable }
        let record = Record(sequence: sequence + 1, previousHash: headHash, cellID: cellID, owner: owner,
                            snapshot: snapshot, consents: consents, startOperations: startOperations, initialOperations: initialOperations)
        let plaintext = try MeetingEvidence.bytes(record)
        guard plaintext.count < 16 * 1024 * 1024 else { throw MeetingSessionError.unavailable }
        let encrypted = try AES.GCM.seal(plaintext, using: key, authenticating: aad(record.sequence)).combined!
        pending = (record, encrypted)
        try store.commit(encrypted, key: fileKey(record.sequence))
        guard try store.read(fileKey(record.sequence)) == encrypted else { throw MeetingSessionError.unavailable }
        latest = record; sequence = record.sequence; headHash = FlowHasher.sha256Hex(encrypted); pending = nil
    }
}
