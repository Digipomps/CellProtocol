#if os(macOS) || os(iOS)
import Foundation
import AVFoundation
import Speech
import CryptoKit
import CellBase

/// Capture for installed on-device dictation locales (including Norwegian).
/// Audio admission stays in the common consent gate. Recognition happens after
/// physical stop in bounded requests, never in an unbounded dictation session.
public final class MeetingArchivedCaptureDevice: MeetingCaptureDevice, @unchecked Sendable {
    private let key: SymmetricKey
    private let sink: @Sendable (MeetingEncryptedAudioChunk) throws -> Void
    private let completion: @Sendable (MeetingRecordingPermit, Bool) -> Void
    public init(key: SymmetricKey, sink: @escaping @Sendable (MeetingEncryptedAudioChunk) throws -> Void,
                completion: @escaping @Sendable (MeetingRecordingPermit, Bool) -> Void) {
        self.key = key; self.sink = sink; self.completion = completion
    }
    public func prepare(plan: MeetingPlan) async throws -> any MeetingPreparedCapture {
        // The coordinator reaches preparation only after every active approval
        // and an explicit Start. OS dialogs never open the microphone; the full
        // plan and presence are checked again when they return.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              SFSpeechRecognizer.authorizationStatus() == .authorized else { throw MeetingAppleCaptureError.permissionRequired }
        guard SFSpeechRecognizer.supportedLocales().contains(Locale(identifier: plan.locale)),
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: plan.locale)),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { throw MeetingAppleCaptureError.unsupportedLocale }
        return Prepared(key: key, sink: sink, completion: completion)
    }
    private final class Prepared: MeetingPreparedCapture, @unchecked Sendable {
        private let lock = NSLock()
        private let processing = NSLock()
        private let engine = AVAudioEngine()
        private let key: SymmetricKey
        private let sink: @Sendable (MeetingEncryptedAudioChunk) throws -> Void
        private let completion: @Sendable (MeetingRecordingPermit, Bool) -> Void
        private var stopped = false, started = false, terminal = false, failed = false, cancelled = false, tapped = false
        private var continuation: AsyncStream<PCM>.Continuation?
        private var task: Task<Void, Never>?
        private struct PCM: @unchecked Sendable { let buffer: AVAudioPCMBuffer }
        init(key: SymmetricKey, sink: @escaping @Sendable (MeetingEncryptedAudioChunk) throws -> Void,
             completion: @escaping @Sendable (MeetingRecordingPermit, Bool) -> Void) {
            self.key = key; self.sink = sink; self.completion = completion
        }
        func start(session: MeetingConsentSession, permit: MeetingRecordingPermit) throws {
            lock.lock(); defer { lock.unlock() }
            guard !started, !stopped else { throw MeetingAppleCaptureError.alreadyStarted }
            started = true
#if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
            try AVAudioSession.sharedInstance().setActive(true)
#endif
            let input = engine.inputNode, source = input.outputFormat(forBus: 0)
            guard source.sampleRate > 0, let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: source, to: target) else { throw MeetingAppleCaptureError.invalidFormat }
            let stream = AsyncStream<PCM>.makeStream(bufferingPolicy: .bufferingOldest(16)); continuation = stream.continuation
            input.installTap(onBus: 0, bufferSize: 4096, format: source) { [weak self] buffer, _ in
                guard let self else { return }
                do {
                    try session.withAudioAdmission(epoch: permit.epoch) {
                        guard buffer.frameLength > 0, buffer.frameLength <= 8192, buffer.format.channelCount <= 8,
                              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { throw MeetingAppleCaptureError.invalidFormat }
                        copy.frameLength = buffer.frameLength
                        let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                        guard src.count == dst.count else { throw MeetingAppleCaptureError.invalidFormat }
                        for i in src.indices {
                            guard let from = src[i].mData, let to = dst[i].mData, src[i].mDataByteSize <= dst[i].mDataByteSize else { throw MeetingAppleCaptureError.invalidFormat }
                            memcpy(to, from, Int(src[i].mDataByteSize))
                        }
                        guard case .enqueued = stream.continuation.yield(PCM(buffer: copy)) else { throw MeetingAppleCaptureError.inputBackpressure }
                    }
                } catch is MeetingSessionError { DispatchQueue.global().async { self.stop() } }
                catch { DispatchQueue.global().async { self.fail(session, permit) } }
            }
            tapped = true
            task = Task { [self] in
                var sequence: UInt64 = 0
                func publish(_ buffer: AVAudioPCMBuffer) throws {
                    guard buffer.frameLength > 0 else { return }
                    let planes = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                    var bytes = Data(); var sizes: [Int] = []
                    for plane in planes {
                        guard let data = plane.mData else { throw MeetingAppleCaptureError.invalidFormat }
                        sizes.append(Int(plane.mDataByteSize)); bytes.append(data.assumingMemoryBound(to: UInt8.self), count: Int(plane.mDataByteSize))
                    }
                    let header = MeetingEncryptedAudioChunk.Header(permit: permit, sequence: sequence, sampleRate: target.sampleRate,
                        channels: target.channelCount, frames: buffer.frameLength, commonFormat: target.commonFormat.rawValue,
                        interleaved: target.isInterleaved, planeSizes: sizes)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let sealed = try AES.GCM.seal(bytes, using: key, authenticating: encoder.encode(header))
                    guard let ciphertext = sealed.combined else { throw MeetingAppleCaptureError.unavailable }
                    try processing.withLock {
                        guard !cancelled else { throw CancellationError() }
                        try sink(MeetingEncryptedAudioChunk(header: header, ciphertext: ciphertext))
                    }
                    sequence += 1
                }
                do {
                    for await packet in stream.stream {
                        try Task.checkCancellation()
                        let capacity = AVAudioFrameCount(ceil(Double(packet.buffer.frameLength) * target.sampleRate / source.sampleRate)) + 32
                        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw MeetingAppleCaptureError.conversionFailed }
                        var supplied = false; var error: NSError?
                        let status = converter.convert(to: converted, error: &error) { _, state in
                            if supplied { state.pointee = .noDataNow; return nil }
                            supplied = true; state.pointee = .haveData; return packet.buffer
                        }
                        guard error == nil, status != .error else { throw MeetingAppleCaptureError.conversionFailed }
                        try publish(converted)
                    }
                    var drained = false
                    for _ in 0..<16 {
                        try Task.checkCancellation()
                        guard let tail = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { throw MeetingAppleCaptureError.conversionFailed }
                        var error: NSError?
                        let status = converter.convert(to: tail, error: &error) { _, state in state.pointee = .endOfStream; return nil }
                        guard error == nil, status != .error else { throw MeetingAppleCaptureError.conversionFailed }
                        try publish(tail)
                        if status == .endOfStream { drained = true; break }
                    }
                    guard drained else { throw MeetingAppleCaptureError.conversionFailed }
                } catch { fail(session, permit) }
                processing.withLock {
                    completion(permit, !cancelled && !lock.withLock { failed })
                }
                lock.withLock { terminal = true }
            }
            engine.prepare()
            do { try engine.start() } catch { failed = true; stream.continuation.finish(); throw error }
        }
        private func fail(_ session: MeetingConsentSession, _ permit: MeetingRecordingPermit) {
            lock.withLock { failed = true }
            session.captureFailed(epoch: permit.epoch, now: Date(), reason: "audioArchiveFailed"); stop()
        }
        var isProcessing: Bool { lock.withLock { started && !terminal } }
        func cancelProcessing() {
            stop()
            processing.withLock { cancelled = true }
            task?.cancel()
        }
        func stop() {
            lock.withLock {
                guard !stopped else { return }; stopped = true
                engine.stop()
                if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
                continuation?.finish(); continuation = nil
#if os(iOS)
                try? AVAudioSession.sharedInstance().setActive(false)
#endif
            }
        }
    }
}
#endif
