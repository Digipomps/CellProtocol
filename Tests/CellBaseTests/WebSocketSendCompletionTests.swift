import Foundation
import XCTest
@testable import CellApple

final class WebSocketSendCompletionTests: XCTestCase {
    func testTextAndDataWaitForURLSessionCompletionAndPropagateFailure() async throws {
        for text in [false, true] {
            let connection = WebSocketTaskConnection2(url: URL(string: "ws://127.0.0.1:1")!)
            let held = HeldWebSocketSend(), returned = SendReturned()
            connection.sendSubmissionForTesting = { message, completion in held.submit(message, completion: completion) }
            let entered = expectation(description: "URLSession send admitted")
            held.entered = { entered.fulfill() }
            let task = Task {
                defer { returned.set() }
                if text { try await connection.send(text: "held") }
                else { try await connection.send(data: Data([1])) }
            }
            await fulfillment(of: [entered], timeout: 1)
            // Drain opportunities after the callback-based overload would have
            // returned, while the actual completion remains explicitly held.
            for _ in 0..<100 { await Task.yield() }
            XCTAssertFalse(returned.value)
            held.finish()
            do { try await task.value; XCTFail("URLSession error was swallowed") }
            catch { XCTAssertEqual((error as NSError).domain, "held-send") }
            XCTAssertTrue(returned.value)
            connection.urlSession.invalidateAndCancel()
        }
    }
}
private final class SendReturned: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    var value: Bool { lock.withLock { done } }
    func set() { lock.withLock { done = true } }
}
private final class HeldWebSocketSend: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Error?) -> Void)?
    var entered: (() -> Void)?
    func submit(_ message: URLSessionWebSocketTask.Message, completion: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { self.completion = completion }; entered?()
    }
    func finish() { let callback = lock.withLock { let result = completion; completion = nil; return result }; callback?(NSError(domain: "held-send", code: 1)) }
}
