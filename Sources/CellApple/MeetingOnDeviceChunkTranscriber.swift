#if os(macOS) || os(iOS)
import Foundation
import AVFoundation
import Speech
import CryptoKit
import CellBase

/// Local fallback for languages absent from SpeechTranscriber, including nb-NO
/// on the verified machine. One bounded request, never a 60-minute dictation
/// task. The host schedules ordered <=45s groups from an already stopped segment.
/// It must preserve boundary uncertainty and never label these as approved minutes.
public enum MeetingOnDeviceChunkTranscriber {
    public static let maximumDuration: Double = 45

    public static func transcribe(_ chunks: [MeetingEncryptedAudioChunk], from segment: MeetingSegment,
                                  using key: SymmetricKey) async throws -> MeetingTranscriptPart {
        try segment.plan.validate()
        guard let stoppedAt = segment.stoppedAt, stoppedAt >= segment.startedAt, !chunks.isEmpty else {
            throw MeetingAppleCaptureError.invalidSegment
        }
        guard Date() < segment.startedAt.addingTimeInterval(segment.plan.rawAudioLifetime) else {
            throw MeetingAppleCaptureError.audioExpired
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw MeetingAppleCaptureError.permissionRequired
        }
        let locale = Locale(identifier: segment.plan.locale)
        guard SFSpeechRecognizer.supportedLocales().contains(locale),
              let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { throw MeetingAppleCaptureError.unsupportedLocale }
        let buffers = try validatedBuffers(chunks, segment: segment, key: key)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let operation = Recognition()
        let deadline = segment.startedAt.addingTimeInterval(segment.plan.rawAudioLifetime)
        let timeout = min(55, deadline.timeIntervalSinceNow)
        guard timeout > 0 else { throw MeetingAppleCaptureError.audioExpired }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let part: MeetingTranscriptPart = try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error { operation.finish(.failure(error)); return }
                    guard let result, result.isFinal else { return }
                    guard Date() < deadline else { operation.finish(.failure(MeetingAppleCaptureError.audioExpired)); return }
                    let duration = buffers.reduce(0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
                    // Sequence numbers are not a time index. The host supplies
                    // this group's position when assembling the full transcript.
                    operation.finish(.success(MeetingTranscriptPart(permit: chunks[0].header.permit,
                        start: 0, duration: duration, text: result.bestTranscription.formattedString)))
                }
                operation.attach(task)
                for buffer in buffers { operation.append(buffer, to: request) }
                request.endAudio()
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    operation.finish(.failure(MeetingAppleCaptureError.unavailable))
                }
            }
            try Task.checkCancellation()
            guard Date() < deadline else { throw MeetingAppleCaptureError.audioExpired }
            return part
        } onCancel: { operation.finish(.failure(CancellationError())) }
    }

    /// Also used by tests with synthetic PCM: authenticated format/segment,
    /// ordered chunks, bounded memory and a duration below Apple's task limit.
    static func validatedBuffers(_ chunks: [MeetingEncryptedAudioChunk], segment: MeetingSegment,
                                 key: SymmetricKey) throws -> [AVAudioPCMBuffer] {
        guard !chunks.isEmpty, chunks.count <= 4096 else { throw MeetingAppleCaptureError.invalidFormat }
        var duration = 0.0
        var byteCount = 0
        var buffers: [AVAudioPCMBuffer] = []
        var expected = chunks[0].header.sequence
        let epoch = chunks[0].header.permit.epoch
        for chunk in chunks {
            let h = chunk.header
            guard h.permit.plan == segment.reference, h.permit.segmentID == segment.id,
                  h.permit.recorder == segment.plan.recorder, h.permit.epoch == epoch,
                  h.sequence == expected, expected < UInt64.max,
                  h.frames > 0, h.frames <= 8192, (1...8).contains(h.channels),
                  h.sampleRate.isFinite, (8000...192000).contains(h.sampleRate),
                  let common = AVAudioCommonFormat(rawValue: h.commonFormat),
                  [.pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32].contains(common),
                  let format = AVAudioFormat(commonFormat: common, sampleRate: h.sampleRate,
                                            channels: h.channels, interleaved: h.interleaved),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: h.frames) else {
                throw MeetingAppleCaptureError.invalidFormat
            }
            duration += Double(h.frames) / h.sampleRate
            guard duration <= maximumDuration else { throw MeetingAppleCaptureError.invalidFormat }
            buffer.frameLength = h.frames
            let planes = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let sizes = planes.map { Int($0.mDataByteSize) }
            let count = sizes.reduce(0, +)
            byteCount += count
            guard h.planeSizes == sizes, chunk.ciphertext.count == count + 28,
                  byteCount <= 32 * 1024 * 1024 else { throw MeetingAppleCaptureError.invalidFormat }
            let pcm = try chunk.decryptedPCM(using: key)
            guard pcm.count == count else { throw MeetingAppleCaptureError.invalidFormat }
            var offset = 0
            pcm.withUnsafeBytes { source in
                for plane in planes {
                    let size = Int(plane.mDataByteSize)
                    memcpy(plane.mData!, source.baseAddress!.advanced(by: offset), size)
                    offset += size
                }
            }
            buffers.append(buffer); expected += 1
        }
        return buffers
    }

    private final class Recognition: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<MeetingTranscriptPart, Error>?
        private var task: SFSpeechRecognitionTask?
        private var result: Result<MeetingTranscriptPart, Error>?
        func install(_ continuation: CheckedContinuation<MeetingTranscriptPart, Error>) {
            lock.lock(); defer { lock.unlock() }
            if let result { continuation.resume(with: result) } else { self.continuation = continuation }
        }
        func attach(_ task: SFSpeechRecognitionTask) {
            lock.lock(); let done = result != nil
            if !done { self.task = task }; lock.unlock()
            if done { task.cancel() }
        }
        func append(_ buffer: AVAudioPCMBuffer, to request: SFSpeechAudioBufferRecognitionRequest) {
            lock.lock(); defer { lock.unlock() }
            guard result == nil else { return }
            request.append(buffer)
        }
        func finish(_ result: Result<MeetingTranscriptPart, Error>) {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return }
            self.result = result
            let continuation = self.continuation; self.continuation = nil
            let task = self.task; self.task = nil
            lock.unlock()
            task?.cancel(); continuation?.resume(with: result)
        }
    }
}
#endif
