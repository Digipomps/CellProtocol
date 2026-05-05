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
        lock.unlock()

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
            var cancellable: AnyCancellable?

            let timeoutWorkItem = DispatchWorkItem {
                if oneShot.resume(continuation, with: .failure(AsyncError.timeout)) {
                    cancellable?.cancel()
                    cancellable = nil
                }
            }

            cancellable = first().sink(
                receiveCompletion: { completion in
                    switch completion {
                    case .finished:
                        if oneShot.resume(continuation, with: .failure(AsyncError.finishedWithoutValue)) {
                            timeoutWorkItem.cancel()
                            cancellable?.cancel()
                            cancellable = nil
                        }
                    case .failure(let error):
                        if oneShot.resume(continuation, with: .failure(AsyncError.other(error))) {
                            timeoutWorkItem.cancel()
                            cancellable?.cancel()
                            cancellable = nil
                        }
                    }
                },
                receiveValue: { output in
                    if oneShot.resume(continuation, with: .success(output)) {
                        timeoutWorkItem.cancel()
                        cancellable?.cancel()
                        cancellable = nil
                    }
                }
            )

            DispatchQueue.global().asyncAfter(
                deadline: .now() + .seconds(timeout),
                execute: timeoutWorkItem
            )
        }
    }

    func getOneWithoutTimeout() async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            let oneShot = AsyncPublisherOneShot<Output>()
            var cancellable: AnyCancellable?

            cancellable = first().sink(
                receiveCompletion: { completion in
                    switch completion {
                    case .finished:
                        if oneShot.resume(continuation, with: .failure(AsyncError.finishedWithoutValue)) {
                            cancellable?.cancel()
                            cancellable = nil
                        }
                    case .failure(let error):
                        if oneShot.resume(continuation, with: .failure(AsyncError.other(error))) {
                            cancellable?.cancel()
                            cancellable = nil
                        }
                    }
                },
                receiveValue: { output in
                    if oneShot.resume(continuation, with: .success(output)) {
                        cancellable?.cancel()
                        cancellable = nil
                    }
                }
            )
        }
    }
}
