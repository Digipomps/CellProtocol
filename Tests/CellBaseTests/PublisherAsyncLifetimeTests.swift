import Foundation
import XCTest
import CombineHelpers
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

final class PublisherAsyncLifetimeTests: XCTestCase {
    func testSynchronousAndConcurrentFirstDeliveryWhileSubscriptionIsInstalled() async throws {
        for timed in [false, true] {
            let immediate = timed ? try await Just(42).getOneWithTimeout(1) : try await Just(42).getOneWithoutTimeout()
            XCTAssertEqual(immediate, 42)
            try await withThrowingTaskGroup(of: Int.self) { group in
                for value in 0..<256 {
                    group.addTask {
                        let publisher = Future<Int, Error> { promise in
                            DispatchQueue.global().async { promise(.success(value)) }
                        }
                        return timed ? try await publisher.getOneWithTimeout(5) : try await publisher.getOneWithoutTimeout()
                    }
                }
                var delivered = Set<Int>()
                for try await value in group { XCTAssertTrue(delivered.insert(value).inserted) }
                XCTAssertEqual(delivered, Set(0..<256))
            }
        }
    }

    func testEmptyFailureAndTimeoutCompleteOnceAndCancelUpstream() async throws {
        for timed in [false, true] {
            do {
                let empty = Empty<Int, Error>()
                _ = timed ? try await empty.getOneWithTimeout(1) : try await empty.getOneWithoutTimeout()
                XCTFail("Empty publisher returned a value")
            } catch AsyncError.finishedWithoutValue {} catch { XCTFail("Unexpected \(error)") }
            do {
                let failed = Fail<Int, Error>(error: CancellationError())
                _ = timed ? try await failed.getOneWithTimeout(1) : try await failed.getOneWithoutTimeout()
                XCTFail("Failed publisher returned a value")
            } catch AsyncError.other(let error) { XCTAssertTrue(error is CancellationError) }
        }
        let cancelled = expectation(description: "timed out subscription cancelled exactly once")
        cancelled.assertForOverFulfill = true
        do {
            _ = try await Empty<Int, Error>(completeImmediately: false)
                .handleEvents(receiveCancel: { cancelled.fulfill() }).getOneWithTimeout(0)
            XCTFail("Never publisher returned a value")
        } catch AsyncError.timeout {} catch { XCTFail("Unexpected \(error)") }
        await fulfillment(of: [cancelled], timeout: 1)
    }
}
