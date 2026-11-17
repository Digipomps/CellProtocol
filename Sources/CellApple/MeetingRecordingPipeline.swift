#if os(macOS) || os(iOS)
import Foundation
import CryptoKit
import CellBase

/// Durable encrypted PCM plus a completion fence. A crash without the fence is
/// always incomplete. The host owns the vault key and the periodic maintenance.
public final class MeetingAudioArchive: @unchecked Sendable {
    private let store: any MeetingDurableStore
    private let lock = NSLock()
    private var written: [UUID: (UInt64, Int)] = [:]
    public init(store: any MeetingDurableStore) { self.store = store }
    private func prefix(_ id: UUID) -> String { "audio-" + id.uuidString + "-" }
    public func append(_ chunk: MeetingEncryptedAudioChunk) throws {
        try lock.withLock {
            let id = chunk.header.permit.segmentID
            let prior = written[id] ?? (0, 0)
            guard chunk.header.sequence == prior.0, prior.0 < 72000,
                  chunk.ciphertext.count <= 262144, prior.1 <= 512 * 1024 * 1024 - chunk.ciphertext.count else { throw MeetingAppleCaptureError.inputBackpressure }
            let key = prefix(id) + String(format: "%08llu", prior.0)
            try store.commit(JSONEncoder().encode(chunk), key: key)
            written[id] = (prior.0 + 1, prior.1 + chunk.ciphertext.count)
        }
    }
    public struct Fence: Codable, Sendable { public let chunks: UInt64; public let complete: Bool }
    public func finish(_ id: UUID, complete: Bool) throws {
        try lock.withLock {
            try store.commit(JSONEncoder().encode(Fence(chunks: written[id]?.0 ?? 0, complete: complete)), key: prefix(id) + "fence")
            written[id] = nil
        }
    }
    public func keys(_ id: UUID) throws -> [String] { try store.keys().filter { $0.hasPrefix(prefix(id)) && !$0.hasSuffix("fence") }.sorted() }
    public func chunk(_ key: String) throws -> MeetingEncryptedAudioChunk {
        guard let bytes = try store.read(key) else { throw MeetingAppleCaptureError.invalidSegment }
        return try JSONDecoder().decode(MeetingEncryptedAudioChunk.self, from: bytes)
    }
    public func fence(_ id: UUID) throws -> Fence? {
        try store.read(prefix(id) + "fence").map { try JSONDecoder().decode(Fence.self, from: $0) }
    }
    public func remove(_ id: UUID) throws {
        try lock.withLock {
            for key in try store.keys() where key.hasPrefix(prefix(id)) { try store.remove(key) }
            written[id] = nil
        }
    }
}

/// App composition of the real capture adapter, durable archive, local ASR and
/// the Cell's recipient-bound delivery queue. All processing is re-authorized
/// between requests and immediately before committing the transcript package.
public actor MeetingRecordingPipeline {
    public typealias Recognize = @Sendable ([MeetingEncryptedAudioChunk], MeetingSegment, SymmetricKey) async throws -> MeetingTranscriptPart
    public nonisolated let archive: MeetingAudioArchive
    private let cell: MeetingSessionCell
    private let key: SymmetricKey
    private let recognize: Recognize
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var failures: [UUID: String] = [:]
    public init(cell: MeetingSessionCell, store: any MeetingDurableStore, key: SymmetricKey,
                recognize: @escaping Recognize = { try await MeetingOnDeviceChunkTranscriber.transcribe($0, from: $1, using: $2) }) {
        self.cell = cell; self.archive = MeetingAudioArchive(store: store); self.key = key; self.recognize = recognize
    }
    public nonisolated func makeCaptureDevice() -> MeetingArchivedCaptureDevice {
        MeetingArchivedCaptureDevice(key: key, sink: { [archive] in try archive.append($0) }, completion: { [weak self, archive] permit, complete in
            // Called after physical stop and draining admitted buffers. Never
            // reenter the policy while the device's processing lock is held.
            do { try archive.finish(permit.segmentID, complete: complete) } catch { /* missing fence => incomplete */ }
            Task { await self?.schedule(permit.segmentID) }
        })
    }
    private func authorized(_ id: UUID) throws -> MeetingSegment {
        let snapshot = try cell.durableSnapshot()
        guard !(snapshot.processingRevokedSegments ?? []).contains(id),
              let segment = snapshot.segments.first(where: { $0.id == id }), segment.stoppedAt != nil,
              Date() < segment.startedAt.addingTimeInterval(segment.plan.rawAudioLifetime) else { throw MeetingSessionError.forbidden }
        return segment
    }
    private func schedule(_ id: UUID) {
        guard jobs[id] == nil else { return }
        jobs[id] = Task { [weak self] in
            guard let self else { return }
            do { try await self.process(id); await self.finished(id, error: nil) }
            catch { await self.finished(id, error: String(describing: error)) }
        }
    }
    private func finished(_ id: UUID, error: String?) { jobs[id] = nil; failures[id] = error }
    public func processingFailures() -> [UUID: String] { failures }
    /// On open/resume and periodically: resume stopped segments, expire audio,
    /// cancel revoked work, and purge delivery packets at their own deadlines.
    public func maintain(recoverInterrupted: Bool = false) async throws {
        let snapshot = try cell.durableSnapshot()
        for segment in snapshot.segments {
            if (snapshot.processingRevokedSegments ?? []).contains(segment.id) || Date() >= segment.startedAt.addingTimeInterval(segment.plan.rawAudioLifetime) {
                jobs[segment.id]?.cancel(); try archive.remove(segment.id)
            } else if segment.stoppedAt != nil, !(try archive.keys(segment.id)).isEmpty,
                      try (recoverInterrupted || archive.fence(segment.id) != nil) {
                schedule(segment.id)
            }
        }
        try await cell.purgeDelivery()
    }
    private func process(_ id: UUID) async throws {
        let segment = try authorized(id)
        if try await cell.hasTranscript(for: id) { try archive.remove(id); return }
        let keys = try archive.keys(id), fence = try archive.fence(id)
        var incomplete = fence?.complete != true || fence?.chunks != UInt64(keys.count) || keys.isEmpty
        var parts: [String] = [], group: [MeetingEncryptedAudioChunk] = []
        var duration = 0.0, expected: UInt64 = 0, groups = 0
        var uncertainties = ["Automatisk transkript, ikke godkjent referat. Tale ved bolkgrenser kan mangle eller gjentas."]
        func run(_ chunks: [MeetingEncryptedAudioChunk]) async throws -> String {
            try Task.checkCancellation(); _ = try authorized(id)
            let part = try await recognize(chunks, segment, key)
            try Task.checkCancellation(); _ = try authorized(id)
            return part.text
        }
        for name in keys {
            try Task.checkCancellation(); _ = try authorized(id)
            let chunk = try archive.chunk(name)
            guard chunk.header.sequence == expected, chunk.header.permit.segmentID == id,
                  chunk.header.sampleRate.isFinite, chunk.header.sampleRate > 0 else { throw MeetingAppleCaptureError.invalidSegment }
            let length = Double(chunk.header.frames) / chunk.header.sampleRate
            guard length > 0, length <= 1 else { throw MeetingAppleCaptureError.invalidFormat }
            if duration + length > 40, !group.isEmpty {
                do { parts.append(try await run(group)) } catch is CancellationError { throw CancellationError() }
                catch { incomplete = true; uncertainties.append("En lydbolk kunne ikke transkriberes lokalt.") }
                groups += 1; group = []; duration = 0
            }
            group.append(chunk); duration += length; expected += 1
        }
        if !group.isEmpty {
            do { parts.append(try await run(group)) } catch is CancellationError { throw CancellationError() }
            catch { incomplete = true; uncertainties.append("Siste lydbolk kunne ikke transkriberes lokalt.") }
            groups += 1
        }
        _ = try authorized(id); try Task.checkCancellation()
        if fence == nil { uncertainties.append("Opptaket ble avbrutt før fullføringskvittering ble lagret.") }
        if groups == 0 { incomplete = true; uncertainties.append("Ingen lyd ble bevart.") }
        _ = try await cell.completeSegment(id, transcript: parts.joined(separator: "\n\n"), incomplete: incomplete,
                                          uncertainties: Array(Set(uncertainties)).sorted())
        try archive.remove(id) // only after the encrypted delivery packet committed
    }
}
#endif
