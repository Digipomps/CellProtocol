// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors


import Foundation

#if canImport(Combine)
import Combine
#else
import OpenCombine
import OpenCombineDispatch
#endif

public enum AsyncError: Error, LocalizedError {
    case finishedWithoutValue
    case timeout
    case other(Error)
    
    public var flatError: Error {
        switch self {
        case .other(let error): return error
        default: return self
        }
    }
    
    public var errorDescription: String? {
        switch self {
        case .finishedWithoutValue: return "Finished without value"
        case .timeout: return "timeout"
        case .other(let error): return error.localizedDescription
        }
    }
}

private final class AsyncPublisherOneShot<Output> {
    private let lock = NSLock()
    private var didResume = false
    private var cancellable: AnyCancellable?
    private var timeout: DispatchWorkItem?

    // A publisher may deliver synchronously inside sink, or on another thread
    // before sink returns. Late installation must cancel, never retain a
    // subscription after its one-shot result has already completed.
    func install(_ value: AnyCancellable) {
        lock.lock()
        let finished = didResume
        if !finished { cancellable = value }
        lock.unlock()
        if finished { value.cancel() }
    }

    func installTimeout(_ value: DispatchWorkItem) {
        lock.lock()
        let finished = didResume
        if !finished { timeout = value }
        lock.unlock()
        if finished { value.cancel() }
    }

    func resume(
        _ continuation: CheckedContinuation<Output, Error>,
        with result: Result<Output, Error>
    ) -> Bool {
        lock.lock()
        guard didResume == false else {
            lock.unlock()
            return false
        }
        didResume = true
        let subscription = cancellable, timer = timeout
        cancellable = nil; timeout = nil
        lock.unlock()

        // Cancellation can call back synchronously; do not hold the state lock.
        timer?.cancel()
        subscription?.cancel()

        switch result {
        case .success(let output):
            continuation.resume(returning: output)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
        return true
    }
}

public extension Publisher {
    func getOneWithTimeout(_ timeout: Int = 30) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            let oneShot = AsyncPublisherOneShot<Output>()
            let timeoutWorkItem = DispatchWorkItem {
                _ = oneShot.resume(continuation, with: .failure(AsyncError.timeout))
            }
            oneShot.installTimeout(timeoutWorkItem)
            oneShot.install(first().sink(
                receiveCompletion: { completion in
                    switch completion {
                    case .finished:
                        _ = oneShot.resume(continuation, with: .failure(AsyncError.finishedWithoutValue))
                    case .failure(let error):
                        _ = oneShot.resume(continuation, with: .failure(AsyncError.other(error)))
                    }
                },
                receiveValue: { output in
                    _ = oneShot.resume(continuation, with: .success(output))
                }
            ))

            DispatchQueue.global().asyncAfter(
                deadline: .now() + .seconds(timeout),
                execute: timeoutWorkItem
            )
        }
    }

    func getOneWithoutTimeout() async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            let oneShot = AsyncPublisherOneShot<Output>()
            oneShot.install(first().sink(
                receiveCompletion: { completion in
                    switch completion {
                    case .finished:
                        _ = oneShot.resume(continuation, with: .failure(AsyncError.finishedWithoutValue))
                    case .failure(let error):
                        _ = oneShot.resume(continuation, with: .failure(AsyncError.other(error)))
                    }
                },
                receiveValue: { output in
                    _ = oneShot.resume(continuation, with: .success(output))
                }
            ))
        }
    }
}
