#if os(macOS) || os(iOS)
import Foundation
import AVFoundation
import Speech
import CryptoKit
import CellBase

public enum MeetingAppleCaptureError: Error {
    case permissionRequired, unsupportedLocale, assetsNotInstalled, unavailable
    case invalidFormat, conversionFailed, inputBackpressure, alreadyStarted
    case audioExpired, invalidSegment
}

/// Each encrypted chunk authenticates its original segment and PCM format.
/// The host must keep the key in its identity-scoped vault and enforce deletion.
public struct MeetingEncryptedAudioChunk: Codable, Sendable {
    public struct Header: Codable, Sendable {
        public let permit: MeetingRecordingPermit
        public let sequence: UInt64
        public let sampleRate: Double
        public let channels: UInt32
        public let frames: UInt32
        public let commonFormat: UInt
        public let interleaved: Bool
        public let planeSizes: [Int]
    }
    public let header: Header
    public let ciphertext: Data

    public func decryptedPCM(using key: SymmetricKey) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key,
                                authenticating: encoder.encode(header))
    }
}

public struct MeetingTranscriptPart: Codable, Sendable {
    public let permit: MeetingRecordingPermit
    public let start: Double
    public let duration: Double
    public let text: String
}

/// Long-form, on-device Apple Speech. No network recognizer fallback and no
/// implicit asset download. Not registered in any production host yet: the
/// caller must provide durable encrypted storage and participant delivery.
@available(macOS 26.0, iOS 26.0, *)
public final class MeetingAppleCaptureDevice: MeetingCaptureDevice, @unchecked Sendable {
    public typealias AudioSink = @Sendable (MeetingEncryptedAudioChunk) throws -> Void
    public typealias TranscriptSink = @Sendable (MeetingTranscriptPart) throws -> Void
    private let key: SymmetricKey
    private let audioSink: AudioSink
    private let transcriptSink: TranscriptSink
    private let completion: @Sendable (MeetingRecordingPermit, Bool) -> Void

    /// Sinks must not reenter the policy or perform network IO. A throwing sink
    /// fails closed. Completion false must never be presented as a full transcript.
    public init(key: SymmetricKey, audioSink: @escaping AudioSink,
                transcriptSink: @escaping TranscriptSink,
                completion: @escaping @Sendable (MeetingRecordingPermit, Bool) -> Void) {
        self.key = key; self.audioSink = audioSink
        self.transcriptSink = transcriptSink; self.completion = completion
    }

    public func prepare(plan: MeetingPlan) async throws -> any MeetingPreparedCapture {
        // Explicit permission request belongs to the visible host action. This
        // device never prompts, downloads models, or selects a different locale.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw MeetingAppleCaptureError.permissionRequired
        }
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: plan.locale)) else {
            throw MeetingAppleCaptureError.unsupportedLocale
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw MeetingAppleCaptureError.assetsNotInstalled
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: nil) else {
            throw MeetingAppleCaptureError.invalidFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        return Prepared(analyzer: analyzer, transcriber: transcriber, format: format,
                        key: key, audioSink: audioSink, transcriptSink: transcriptSink, completion: completion)
    }

    private final class Prepared: MeetingPreparedCapture, @unchecked Sendable {
        private let lock = NSLock()
        private let processingLock = NSLock()
        private var processingCancelled = false
        private let engine = AVAudioEngine()
        private let analyzer: SpeechAnalyzer
        private let transcriber: SpeechTranscriber
        private let format: AVAudioFormat
        private let key: SymmetricKey
        private let audioSink: AudioSink
        private let transcriptSink: TranscriptSink
        private let completion: @Sendable (MeetingRecordingPermit, Bool) -> Void
        private struct PCM: @unchecked Sendable { let buffer: AVAudioPCMBuffer }
        private var continuation: AsyncStream<PCM>.Continuation?
        private var inputTask: Task<Void, Never>?
        private var ownsAudioSession = false
        private var analysisTask: Task<Void, Never>?
        private var resultTask: Task<Void, Error>?
        private var started = false
        private var stopped = false
        private var failed = false
        private var terminal = false
        private var tapInstalled = false
        private var sequence: UInt64 = 0 // Accessed only by the input processing task.
        private weak var session: MeetingConsentSession?
        private var permit: MeetingRecordingPermit?

        init(analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber, format: AVAudioFormat,
             key: SymmetricKey, audioSink: @escaping AudioSink, transcriptSink: @escaping TranscriptSink,
             completion: @escaping @Sendable (MeetingRecordingPermit, Bool) -> Void) {
            self.analyzer = analyzer; self.transcriber = transcriber; self.format = format
            self.key = key; self.audioSink = audioSink; self.transcriptSink = transcriptSink
            self.completion = completion
        }

        func start(session: MeetingConsentSession, permit: MeetingRecordingPermit) throws {
            lock.lock(); defer { lock.unlock() }
            guard !started, !stopped else { throw MeetingAppleCaptureError.alreadyStarted }
            started = true; self.session = session; self.permit = permit
            let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(16))
            let admitted = AsyncStream<PCM>.makeStream(bufferingPolicy: .bufferingOldest(16))
            continuation = admitted.continuation
            let input = engine.inputNode
            let sourceFormat = input.outputFormat(forBus: 0)
            guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0,
                  let converter = AVAudioConverter(from: sourceFormat, to: format) else {
                throw MeetingAppleCaptureError.invalidFormat
            }
#if os(iOS)
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement)
            try audioSession.setActive(true)
            ownsAudioSession = true
#endif
            input.installTap(onBus: 0, bufferSize: 1024, format: sourceFormat) { [weak self] buffer, _ in
                guard let self else { return }
                do {
                    try session.withAudioAdmission(epoch: permit.epoch) {
                        // Bound admission work: no conversion, encryption, disk
                        // or caller-provided sink under the consent lock.
                        guard buffer.frameLength <= 8192, buffer.format.channelCount <= 8,
                              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
                            throw MeetingAppleCaptureError.invalidFormat
                        }
                        copy.frameLength = buffer.frameLength
                        let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                        guard src.count == dst.count else { throw MeetingAppleCaptureError.invalidFormat }
                        for index in src.indices {
                            guard let from = src[index].mData, let to = dst[index].mData,
                                  src[index].mDataByteSize <= dst[index].mDataByteSize else {
                                throw MeetingAppleCaptureError.invalidFormat
                            }
                            memcpy(to, from, Int(src[index].mDataByteSize))
                        }
                        guard case .enqueued = admitted.continuation.yield(PCM(buffer: copy)) else {
                            throw MeetingAppleCaptureError.inputBackpressure
                        }
                    }
                } catch is MeetingSessionError {
                    // Ordinary stop/new roster closes admission. This is not an
                    // ASR failure: finish the already-admitted old segment.
                    DispatchQueue.global(qos: .userInitiated).async { self.stop() }
                } catch {
                    DispatchQueue.global(qos: .userInitiated).async { self.fail(session: session, permit: permit) }
                }
            }
            tapInstalled = true
            inputTask = Task { [self] in
                defer { pair.continuation.finish() }
                func publish(_ converted: AVAudioPCMBuffer) throws {
                    guard converted.frameLength > 0 else { return }
                        let planes = UnsafeMutableAudioBufferListPointer(converted.mutableAudioBufferList)
                        var pcm = Data(); var sizes: [Int] = []
                        for plane in planes {
                            guard let bytes = plane.mData else { throw MeetingAppleCaptureError.invalidFormat }
                            let count = Int(plane.mDataByteSize); sizes.append(count)
                            pcm.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
                        }
                        let header = MeetingEncryptedAudioChunk.Header(permit: permit, sequence: sequence,
                            sampleRate: format.sampleRate, channels: format.channelCount,
                            frames: converted.frameLength, commonFormat: format.commonFormat.rawValue,
                            interleaved: format.isInterleaved, planeSizes: sizes)
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                        let sealed = try AES.GCM.seal(pcm, using: key, authenticating: encoder.encode(header))
                        guard let ciphertext = sealed.combined else { throw MeetingAppleCaptureError.unavailable }
                        try withProcessing {
                            try audioSink(MeetingEncryptedAudioChunk(header: header, ciphertext: ciphertext))
                            guard case .enqueued = pair.continuation.yield(AnalyzerInput(buffer: converted)) else {
                                throw MeetingAppleCaptureError.inputBackpressure
                            }
                        }
                        sequence += 1
                }
                do {
                    for await packet in admitted.stream {
                        try Task.checkCancellation()
                        let buffer = packet.buffer
                        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / sourceFormat.sampleRate)) + 32
                        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                            throw MeetingAppleCaptureError.conversionFailed
                        }
                        var supplied = false
                        var conversionError: NSError?
                        let status = converter.convert(to: converted, error: &conversionError) { _, state in
                            if supplied { state.pointee = .noDataNow; return nil }
                            supplied = true; state.pointee = .haveData; return buffer
                        }
                        guard conversionError == nil, status != .error else { throw MeetingAppleCaptureError.conversionFailed }
                        guard converted.frameLength > 0 else { continue }
                        try publish(converted)
                    }
                    // Drain only the already-admitted converter tail. A bounded
                    // drain failure is incomplete transcription, never success.
                    var drained = false
                    for _ in 0..<16 {
                        try Task.checkCancellation()
                        guard let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
                            throw MeetingAppleCaptureError.conversionFailed
                        }
                        var drainError: NSError?
                        let status = converter.convert(to: tail, error: &drainError) { _, state in
                            state.pointee = .endOfStream; return nil
                        }
                        guard drainError == nil, status != .error else { throw MeetingAppleCaptureError.conversionFailed }
                        try publish(tail)
                        if status == .endOfStream { drained = true; break }
                    }
                    guard drained else { throw MeetingAppleCaptureError.conversionFailed }

                } catch { fail(session: session, permit: permit) }
            }
            resultTask = Task { [self] in
                do { for try await result in transcriber.results {
                    // Non-volatile preset: each final time range is one part.
                    guard result.isFinal else { continue }
                    try withProcessing {
                        try transcriptSink(MeetingTranscriptPart(permit: permit, start: result.range.start.seconds,
                            duration: result.range.duration.seconds, text: String(result.text.characters)))
                    }
                } } catch { fail(session: session, permit: permit); throw error }
            }
            analysisTask = Task { [self] in
                defer { markTerminal() }
                do {
                    _ = try await analyzer.analyzeSequence(pair.stream)
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    try await resultTask?.value
                    complete(permit)
                } catch {
                    fail(session: session, permit: permit)
                    await analyzer.cancelAndFinishNow()
                    complete(permit)
                }
            }
            engine.prepare()
            do { try engine.start() }
            catch { failed = true; admitted.continuation.finish(); throw error }
        }

        private func fail(session: MeetingConsentSession, permit: MeetingRecordingPermit) {
            lock.lock(); failed = true; lock.unlock()
            session.captureFailed(epoch: permit.epoch, now: Date(), reason: "captureOrTranscriptionFailed")
            stop()
        }

        private func hasFailed() -> Bool { lock.lock(); defer { lock.unlock() }; return failed }
        /// Serialized with cancellation: after cancelProcessing returns no
        /// success callback can begin. The host must still revalidate segment
        /// authority when committing/delivering. Callbacks must not reenter.
        private func complete(_ permit: MeetingRecordingPermit) {
            processingLock.lock(); defer { processingLock.unlock() }
            completion(permit, !processingCancelled && !hasFailed())
        }
        private func markTerminal() { lock.lock(); terminal = true; lock.unlock() }
        var isProcessing: Bool { lock.lock(); defer { lock.unlock() }; return started && !terminal }

        private func withProcessing(_ body: () throws -> Void) throws {
            processingLock.lock(); defer { processingLock.unlock() }
            guard !processingCancelled else { throw CancellationError() }
            try body()
        }

        func cancelProcessing() {
            lock.lock(); failed = true; lock.unlock()
            stop() // Physical stop never waits for a storage callback.
            processingLock.lock()
            guard !processingCancelled else { processingLock.unlock(); return }
            processingCancelled = true; processingLock.unlock()
            inputTask?.cancel(); resultTask?.cancel()
            Task { [analyzer] in await analyzer.cancelAndFinishNow() }
        }

        func stop() {
            lock.lock(); defer { lock.unlock() }
            guard !stopped else { return }
            stopped = true
            engine.stop()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
            // Finish only already-admitted audio; the result retains the old
            // segment, including when a newcomer caused the stop.
            continuation?.finish(); continuation = nil
            if analysisTask == nil { Task { [analyzer] in await analyzer.cancelAndFinishNow() } }
#if os(iOS)
            if ownsAudioSession {
                try? AVAudioSession.sharedInstance().setActive(false)
                ownsAudioSession = false
            }
#endif
        }
    }
}
#endif
