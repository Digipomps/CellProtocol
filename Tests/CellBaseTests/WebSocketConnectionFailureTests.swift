#if canImport(Darwin)
import Foundation
import XCTest
@testable import CellApple

final class WebSocketConnectionFailureTests: XCTestCase {
    private let url = URL(string: "wss://localhost:443/bridgehead/test")!

    private func failure(_ code: Int = -1202) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code, userInfo: [
            NSURLErrorFailingURLErrorKey: url,
            "preservedPeerEvidence": Data([1, 7, 9])
        ])
    }

    func testReceiveFailureBeforeWaitSurvivesImmediateDelegateClose() async throws {
        let connection = WebSocketTaskConnection2(url: url)
        let delegate = ClosingConnectionDelegate(), closed = expectation(description: "Native error delegate completed")
        connection.delegate = delegate
        delegate.errorCompleted = { closed.fulfill() }
        connection.resumeSubmissionForTesting = { _ in }
        let expected = failure()
        connection.receiveSubmissionForTesting = { _, completion in completion(.failure(expected)) }
        connection.beforeConnectionWaitForTesting = { await self.fulfillment(of: [closed], timeout: 2) }
        do { try await connection.connect(); XCTFail("Native failure was swallowed") }
        catch { assertOriginal(error, expected) }
        XCTAssertEqual(delegate.errorCount, 1)
        XCTAssertNil(connection.webSocketTask)
    }

    func testCompletionDuringResumeSurvivesCloseBeforeListenAdmission() async throws {
        let connection = WebSocketTaskConnection2(url: url)
        let delegate = ClosingConnectionDelegate(), closed = expectation(description: "Native error delegate completed")
        connection.delegate = delegate
        delegate.errorCompleted = { closed.fulfill() }
        let expected = failure()
        connection.resumeSubmissionForTesting = { task in
            connection.urlSession(connection.urlSession, task: task, didCompleteWithError: expected)
            await self.fulfillment(of: [closed], timeout: 2)
        }
        connection.receiveSubmissionForTesting = { _, _ in XCTFail("A closed task cannot enter receive") }
        do { try await connection.connect(); XCTFail("Completion during resume was swallowed") }
        catch { assertOriginal(error, expected) }
        XCTAssertEqual(delegate.errorCount, 1)
    }

    func testTaskCompletionFailureWithoutReceiveCallbackSurvivesClose() async throws {
        let connection = WebSocketTaskConnection2(url: url)
        let delegate = ClosingConnectionDelegate(), closed = expectation(description: "Native error delegate completed")
        connection.delegate = delegate
        delegate.errorCompleted = { closed.fulfill() }
        connection.resumeSubmissionForTesting = { _ in }
        connection.receiveSubmissionForTesting = { _, _ in }
        let expected = failure()
        connection.beforeConnectionWaitForTesting = {
            let task = connection.webSocketTask!
            connection.urlSession(connection.urlSession, task: task, didCompleteWithError: expected)
            await self.fulfillment(of: [closed], timeout: 2)
        }
        do { try await connection.connect(); XCTFail("Task completion failure was swallowed") }
        catch { assertOriginal(error, expected) }
        XCTAssertEqual(delegate.errorCount, 1)
    }

    func testDuplicateReceiveAndCompletionCannotReplaceFirstFailure() async throws {
        let connection = WebSocketTaskConnection2(url: url)
        let delegate = ClosingConnectionDelegate(), closed = expectation(description: "Native error delegate completed")
        connection.delegate = delegate
        delegate.errorCompleted = { closed.fulfill() }
        connection.resumeSubmissionForTesting = { _ in }
        delegate.shouldClose = false
        let expected = failure(), later = failure(-999)
        let task = try XCTUnwrap(connection.webSocketTask)
        connection.receiveSubmissionForTesting = { _, completion in completion(.failure(expected)) }
        connection.beforeConnectionWaitForTesting = {
            await self.fulfillment(of: [closed], timeout: 2)
            await connection.reportFailure(later, from: task)
        }
        do { try await connection.connect(); XCTFail("First failure was lost") }
        catch { assertOriginal(error, expected) }
        // The current task is still present; the awaited duplicate is rejected
        // by first-error ownership, not merely by post-close task identity.
        XCTAssertEqual(delegate.errorCount, 1)
        try await connection.disconnect()
    }

    func testStaleCompletionDoesNotPreventCurrentTaskFromConnecting() async throws {
        let connection = WebSocketTaskConnection2(url: url)
        let delegate = ClosingConnectionDelegate()
        connection.delegate = delegate
        connection.resumeSubmissionForTesting = { _ in }
        connection.receiveSubmissionForTesting = { _, _ in }
        let stale = connection.urlSession.webSocketTask(with: url)
        await connection.reportFailure(failure(), from: stale)
        connection.beforeConnectionWaitForTesting = {
            connection.urlSession(connection.urlSession, webSocketTask: connection.webSocketTask!, didOpenWithProtocol: nil)
        }
        try await connection.connect()
        XCTAssertEqual(delegate.errorCount, 0)
        try await connection.disconnect()
    }

    func testNativeFailureAfterWaitStartsSurvivesImmediateClose() async throws {
        let connection = WebSocketTaskConnection2(url: url)
        let delegate = ClosingConnectionDelegate()
        connection.delegate = delegate
        connection.resumeSubmissionForTesting = { _ in }
        connection.receiveSubmissionForTesting = { _, _ in }
        let waiting = expectation(description: "Connection subscriber received initial state")
        connection.connectionWaitObservedForTesting = { waiting.fulfill() }
        let expected = failure()
        let nativeTask = try XCTUnwrap(connection.webSocketTask)
        let result = Task { () -> Error? in
            do { try await connection.connect(); return nil }
            catch { return error }
        }
        await fulfillment(of: [waiting], timeout: 2)
        // An actual CurrentValueSubject delivery proves subscription has begun;
        // no network timing, task yield or closed-port assumption is involved.
        await connection.reportFailure(expected, from: nativeTask)
        let actual = await result.value
        assertOriginal(try XCTUnwrap(actual), expected)
        XCTAssertEqual(delegate.errorCount, 1)
        XCTAssertNil(connection.webSocketTask)
    }

    func testExplicitCloseRetainsNormalNoTaskBehavior() async throws {
        let connection = WebSocketTaskConnection2(url: url)
        try await connection.disconnect()
        do { try await connection.connect(); XCTFail("Closed connection reopened") }
        catch {
            guard case WebSocketConnectionError.NoTask = error else { XCTFail("Unexpected close error: \(error)"); return }
        }
    }

    private func assertOriginal(_ actual: Error, _ expected: NSError, file: StaticString = #filePath, line: UInt = #line) {
        let native = actual as NSError
        XCTAssertTrue(native === expected, "Keep the exact native error and peer-trust object", file: file, line: line)
        XCTAssertEqual(native.userInfo["preservedPeerEvidence"] as? Data, Data([1, 7, 9]), file: file, line: line)
        XCTAssertEqual(native.userInfo[NSURLErrorFailingURLErrorKey] as? URL, url, file: file, line: line)
    }
}

private final class ClosingConnectionDelegate: WebSocketConnectionDelegate2, @unchecked Sendable {
    private let lock = NSLock()
    private var errors = 0
    var errorCount: Int { lock.withLock { errors } }
    var errorCompleted: (() async -> Void)?
    var shouldClose = true
    func onConnected(connection: WebSocketConnection2) async {}
    func onDisconnected(connection: WebSocketConnection2, error: Error?) async {}
    func onMessage(connection: WebSocketConnection2, text: String) async {}
    func onMessage(connection: WebSocketConnection2, data: Data) async {}
    func onError(connection: WebSocketConnection2, error: Error) async {
        lock.withLock { errors += 1 }
        if shouldClose { try? await connection.disconnect() }
        await errorCompleted?()
    }
}

#endif
