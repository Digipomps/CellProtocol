// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@testable import CellBase

final class FeedAuthorizationRegistryTests: XCTestCase {
    private actor Gate {
        private var pending: CheckedContinuation<Void, Never>?
        private var arrivals: [CheckedContinuation<Void, Never>] = []
        private var arrived = false
        func wait() async {
            arrived = true
            arrivals.forEach { $0.resume() }
            arrivals.removeAll()
            await withCheckedContinuation { pending = $0 }
        }
        func waitForArrival() async {
            if arrived { return }
            await withCheckedContinuation { arrivals.append($0) }
        }
        func release() { pending?.resume(); pending = nil }
    }

    private final class Values {
        private let lock = NSLock()
        private var values: [String] = []
        func receive(_ element: FlowElement) { lock.withLock { values.append(element.title) } }
        var snapshot: [String] { lock.withLock { values } }
    }

    func testBurstKeepsOrderAndPropagatesNormalCompletion() async throws {
        let registry = FeedAuthorizationRegistry()
        let source = PassthroughSubject<FlowElement, Error>()
        let values = Values()
        let completed = expectation(description: "normal completion after authorized queue drains")
        let subscription = registry.publisher(upstream: source.eraseToAnyPublisher(), subjectUUID: "reader") {
            await Task.yield()
            return true
        }.sink(receiveCompletion: { completion in
            if case .failure(let error) = completion { XCTFail("Unexpected failure: \(error)") }
            completed.fulfill()
        }, receiveValue: { values.receive($0) })
        for index in 0..<100 { source.send(element(index)) }
        source.send(completion: .finished)
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(values.snapshot, (0..<100).map(String.init))
        subscription.cancel()
    }

    func testBlockedAuthorizationFailsExplicitlyOnOverflowWithoutLeakingBufferedData() async throws {
        let registry = FeedAuthorizationRegistry()
        let source = PassthroughSubject<FlowElement, Error>()
        let gate = Gate()
        let values = Values()
        let failed = expectation(description: "bounded queue fails on overflow")
        let subscription = registry.publisher(upstream: source.eraseToAnyPublisher(), subjectUUID: "reader") {
            await gate.wait()
            return true
        }.sink(receiveCompletion: { completion in
            guard case .failure(let error) = completion,
                  case GeneralCellErrors.flowBufferOverflow = error else {
                return XCTFail("Expected explicit overflow failure")
            }
            failed.fulfill()
        }, receiveValue: { values.receive($0) })
        source.send(element(0))
        await gate.waitForArrival()
        for index in 1...257 { source.send(element(index)) }
        await fulfillment(of: [failed], timeout: 2)
        await gate.release()
        XCTAssertTrue(values.snapshot.isEmpty)
        subscription.cancel()
    }

    func testCancellationDuringAuthorizationDoesNotDeliverLateValue() async throws {
        let registry = FeedAuthorizationRegistry()
        let source = PassthroughSubject<FlowElement, Error>()
        let gate = Gate()
        let values = Values()
        let checkReturned = expectation(description: "cancelled authorization unwinds")
        let subscription = registry.publisher(upstream: source.eraseToAnyPublisher(), subjectUUID: "reader") {
            await gate.wait()
            checkReturned.fulfill()
            return true
        }.sink(receiveCompletion: { _ in XCTFail("Cancellation must not deliver a completion") }, receiveValue: { values.receive($0) })
        source.send(element(0))
        await gate.waitForArrival()
        subscription.cancel()
        await gate.release()
        await fulfillment(of: [checkReturned], timeout: 2)
        source.send(element(1))
        XCTAssertTrue(values.snapshot.isEmpty)
    }

    private func element(_ index: Int) -> FlowElement {
        FlowElement(title: String(index), content: .number(index), properties: nil)
    }
}
