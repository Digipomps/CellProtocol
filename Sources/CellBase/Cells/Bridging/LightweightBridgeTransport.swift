// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

public extension Notification.Name {
    static let lightweightBridgeConnectionStatusDidChange = Notification.Name("LightweightBridgeConnectionStatusDidChange")
}

public struct LightweightBridgeConnectionStatus: Sendable {
    public enum Phase: String, Sendable {
        case connecting
        case connected
        case reconnecting
        case disconnected
        case failed
    }

    public let phase: Phase
    public let endpoint: String
    public let detail: String?
    public let attempt: Int?
    public let updatedAt: Date

    public init(
        phase: Phase,
        endpoint: String,
        detail: String? = nil,
        attempt: Int? = nil,
        updatedAt: Date = Date()
    ) {
        self.phase = phase
        self.endpoint = endpoint
        self.detail = detail
        self.attempt = attempt
        self.updatedAt = updatedAt
    }

    public init?(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let phaseRaw = userInfo[Self.phaseKey] as? String,
              let phase = Phase(rawValue: phaseRaw),
              let endpoint = userInfo[Self.endpointKey] as? String,
              let updatedAt = userInfo[Self.updatedAtKey] as? Date
        else {
            return nil
        }

        self.init(
            phase: phase,
            endpoint: endpoint,
            detail: userInfo[Self.detailKey] as? String,
            attempt: userInfo[Self.attemptKey] as? Int,
            updatedAt: updatedAt
        )
    }

    var notificationUserInfo: [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            Self.phaseKey: phase.rawValue,
            Self.endpointKey: endpoint,
            Self.updatedAtKey: updatedAt
        ]
        if let detail {
            userInfo[Self.detailKey] = detail
        }
        if let attempt {
            userInfo[Self.attemptKey] = attempt
        }
        return userInfo
    }

    private static let phaseKey = "phase"
    private static let endpointKey = "endpoint"
    private static let detailKey = "detail"
    private static let attemptKey = "attempt"
    private static let updatedAtKey = "updatedAt"
}

protocol LightweightWebSocketClientDelegate: AnyObject, Sendable {
    func clientDidConnect(_ client: any LightweightWebSocketClient) async
    func clientDidDisconnect(_ client: any LightweightWebSocketClient, error: Error?) async
    func client(_ client: any LightweightWebSocketClient, didReceive text: String) async
    func client(_ client: any LightweightWebSocketClient, didReceive data: Data) async
    func client(_ client: any LightweightWebSocketClient, didReceive error: Error) async
}

protocol LightweightWebSocketClient: AnyObject, Sendable {
    var delegate: LightweightWebSocketClientDelegate? { get set }
    func connect() async throws
    func disconnect() async throws
    func send(text: String) async throws
    func send(data: Data) async throws
    func ping() async throws
}

private final class WeakLightweightWebSocketDelegateBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var storedDelegate: LightweightWebSocketClientDelegate?

    var delegate: LightweightWebSocketClientDelegate? {
        get {
            lock.lock()
            defer {
                lock.unlock()
            }
            return storedDelegate
        }
        set {
            lock.lock()
            storedDelegate = newValue
            lock.unlock()
        }
    }
}

public enum LightweightBridgeTransportError: Error {
    case notConnected
    case invalidTextPayload
    case connectionClosed
    case connectionCancelled
}

private struct URLSessionLightweightWebSocketSnapshot {
    let task: URLSessionWebSocketTask?
    let session: URLSession?
    let continuation: CheckedContinuation<Void, Error>?
    let shouldNotifyDisconnect: Bool
}

private final class URLSessionLightweightWebSocketState: @unchecked Sendable {
    private let lock = NSLock()
    private enum Phase { case idle, connecting, connected, closed }
    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var phase: Phase = .idle

    func prepare(session: URLSession, task: URLSessionWebSocketTask) -> Bool {
        lock.withLock {
            guard phase == .idle else { return false }
            urlSession = session; webSocketTask = task; phase = .connecting
            return true
        }
    }
    func installContinuation(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        let admitted = lock.withLock { () -> Bool in
            guard phase == .connecting, connectContinuation == nil else { return false }
            connectContinuation = continuation
            return true
        }
        if !admitted { continuation.resume(throwing: LightweightBridgeTransportError.connectionCancelled) }
        return admitted
    }
    func completeConnection(session: URLSession, task: URLSessionWebSocketTask) -> CheckedContinuation<Void, Error>? {
        lock.withLock {
            guard phase == .connecting, urlSession === session, webSocketTask === task,
                  let continuation = connectContinuation else { return nil }
            phase = .connected; connectContinuation = nil
            return continuation
        }
    }
    func matches(session: URLSession, task: URLSessionTask) -> Bool {
        lock.withLock { phase != .closed && urlSession === session && webSocketTask === task }
    }
    func close(shouldNotifyDisconnect: Bool = true) -> URLSessionLightweightWebSocketSnapshot {
        lock.withLock {
            let snapshot = URLSessionLightweightWebSocketSnapshot(task: webSocketTask, session: urlSession,
                continuation: connectContinuation, shouldNotifyDisconnect: shouldNotifyDisconnect && phase == .connected)
            webSocketTask = nil; urlSession = nil; connectContinuation = nil; phase = .closed
            return snapshot
        }
    }
    func activeTask() -> URLSessionWebSocketTask? { lock.withLock { phase == .connected ? webSocketTask : nil } }
}

enum URLSessionLightweightWebSocketOperation {
    case sendText
    case sendData
    case ping

    var timeoutNanoseconds: UInt64 {
        switch self {
        case .sendText, .sendData:
            return 15_000_000_000
        case .ping:
            return 10_000_000_000
        }
    }

    var description: String {
        switch self {
        case .sendText:
            return "send text"
        case .sendData:
            return "send data"
        case .ping:
            return "ping"
        }
    }

    var timeoutError: Error {
        URLError(
            .timedOut,
            userInfo: [NSLocalizedDescriptionKey: "Lightweight websocket \(description) timed out"]
        )
    }
}

final class URLSessionLightweightWebSocketCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var terminal: Result<Void, Error>?
    let beforeTimeoutReturn: (@Sendable () async -> Void)?
    init(beforeTimeoutReturn: (@Sendable () async -> Void)? = nil) { self.beforeTimeoutReturn = beforeTimeoutReturn }
    private var timeoutTask: Task<Void, Never>?

    @discardableResult
    func install(_ continuation: CheckedContinuation<Void, Error>, operation: URLSessionLightweightWebSocketOperation) -> Bool {
        lock.lock()
        if let terminal { lock.unlock(); continuation.resume(with: terminal); return false }
        self.continuation = continuation
        let hook = beforeTimeoutReturn
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: operation.timeoutNanoseconds) } catch {}
            if !Task.isCancelled { self?.resume(with: .failure(operation.timeoutError)) }
            await hook?()
        }
        lock.unlock()
        return true
    }
    func resume(with result: Result<Void, Error>) {
        lock.lock()
        guard terminal == nil else { lock.unlock(); return }
        terminal = result
        let continuation = self.continuation; self.continuation = nil
        let timeout = timeoutTask
        lock.unlock()
        timeout?.cancel()
        continuation?.resume(with: result)
    }
    func finishTimeout() async {
        let task = lock.withLock { timeoutTask }
        task?.cancel()
        await task?.value
        lock.withLock { timeoutTask = nil }
    }

}

private final class LightweightInvalidation: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var waiter: CheckedContinuation<Void, Never>?
    func complete() {
        let waiter = lock.withLock { completed = true; let current = self.waiter; self.waiter = nil; return current }
        waiter?.resume()
    }
    // Only the shared disconnect finalizer waits here.
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { if completed { return true }; waiter = continuation; return false }
            if ready { continuation.resume() }
        }
    }
}

final class URLSessionLightweightWebSocketClient: NSObject, LightweightWebSocketClient, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let delegateBox = WeakLightweightWebSocketDelegateBox()

    var delegate: LightweightWebSocketClientDelegate? {
        get {
            delegateBox.delegate
        }
        set {
            delegateBox.delegate = newValue
        }
    }

    private let url: URL
    private let delegateQueue = OperationQueue()
    private let state = URLSessionLightweightWebSocketState()
    private let callbacks = BridgeOwnedTasks()
    private let invalidated = LightweightInvalidation()
    private let closeLock = NSLock()
    private var connectStarted = false
    private var closeTask: Task<Void, Never>?
    private static let connectTimeoutNanoseconds: UInt64 = 20_000_000_000
    private static let requestTimeoutInterval: TimeInterval = 300
    private static let resourceTimeoutInterval: TimeInterval = 86_400

    init(url: URL) {
        self.url = url
        super.init()
        delegateQueue.maxConcurrentOperationCount = 1
    }

    func connect() async throws {
        let configuration = URLSessionConfiguration.default
#if !os(Linux)
        configuration.waitsForConnectivity = true
#endif
        configuration.timeoutIntervalForRequest = Self.requestTimeoutInterval
        configuration.timeoutIntervalForResource = Self.resourceTimeoutInterval

        let task = try closeLock.withLock { () throws -> URLSessionWebSocketTask in
            guard closeTask == nil, !connectStarted else { throw LightweightBridgeTransportError.connectionCancelled }
            connectStarted = true
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            let task = session.webSocketTask(with: url)
            task.maximumMessageSize = 1024 * 1024
            // Construction/registration and close share one admission lock.
            precondition(state.prepare(session: session, task: task))
            return task
        }

        let timeoutTask = callbacks.submit { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.connectTimeoutNanoseconds)
            } catch {
                return
            }
            _ = self?.requestDisconnect(error: URLError(
                .timedOut,
                userInfo: [NSLocalizedDescriptionKey: "Lightweight websocket connect timed out"]
            ))
        }

        defer {
            timeoutTask?.cancel()
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if state.installContinuation(continuation) { task.resume() }
            }
        } onCancel: {
            _ = self.requestDisconnect(error: CancellationError())
        }
    }

    @discardableResult
    private func requestDisconnect(error: Error? = nil, notify: Bool = false) -> Task<Void, Never> {
        closeLock.withLock {
            if let closeTask { return closeTask }
            callbacks.requestStop()
            let snapshot = state.close(shouldNotifyDisconnect: notify)
            let observer = delegate
            delegate = nil
            snapshot.continuation?.resume(throwing: error ?? LightweightBridgeTransportError.connectionCancelled)
            snapshot.task?.cancel(with: .goingAway, reason: nil)
            snapshot.session?.invalidateAndCancel()
            let task = Task { [self] in
                if snapshot.session != nil { await invalidated.wait() }
                await callbacks.finishStop()
                if snapshot.shouldNotifyDisconnect { await observer?.clientDidDisconnect(self, error: error) }
            }
            closeTask = task
            return task
        }
    }
    func disconnect() async throws { await requestDisconnect().value }

    func send(text: String) async throws {
        guard let task = state.activeTask() else {
            throw LightweightBridgeTransportError.notConnected
        }
        try await perform(operation: .sendText) { completion in
            task.send(.string(text), completionHandler: completion)
        }
    }

    func send(data: Data) async throws {
        guard let task = state.activeTask() else {
            throw LightweightBridgeTransportError.notConnected
        }
        try await perform(operation: .sendData) { completion in
            task.send(.data(data), completionHandler: completion)
        }
    }

    func ping() async throws {
        guard let task = state.activeTask() else {
            throw LightweightBridgeTransportError.notConnected
        }
        try await perform(operation: .ping) { completion in
            task.sendPing(pongReceiveHandler: completion)
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard let task = callbacks.submit({ [self] in
            guard let continuation = state.completeConnection(session: session, task: webSocketTask) else { return }
            continuation.resume()
            guard !callbacks.isClosed else { return }
            receiveNextMessage()
            await delegate?.clientDidConnect(self)
        }) else { _ = requestDisconnect(); return }
        _ = task
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard state.matches(session: session, task: webSocketTask) else { return }
        _ = requestDisconnect(notify: true)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, state.matches(session: session, task: task) else { return }
        _ = requestDisconnect(error: error, notify: true)
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        invalidated.complete()
        _ = requestDisconnect(error: error, notify: true)
    }

    var beforeTimeoutReturn: (@Sendable () async -> Void)?
    func perform(
        operation: URLSessionLightweightWebSocketOperation,
        using block: @escaping (@escaping @Sendable (Error?) -> Void) -> Void
    ) async throws {
        let completion = URLSessionLightweightWebSocketCompletion(beforeTimeoutReturn: beforeTimeoutReturn)
        do {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard completion.install(continuation, operation: operation) else { return }
                block { error in
                    if let error {
                        completion.resume(with: .failure(error))
                    } else {
                        completion.resume(with: .success(()))
                    }
                }
            }
        } onCancel: {
            completion.resume(with: .failure(CancellationError()))
        }
        } catch {
            await completion.finishTimeout()
            throw error
        }
        await completion.finishTimeout()
    }

    private func receiveNextMessage() {
        guard !callbacks.isClosed, let task = state.activeTask() else { return }
        task.receive { [self] result in
            let cost: Int
            switch result {
            case .failure: cost = 0
            case .success(.string(let text)): cost = text.utf8.count
            case .success(.data(let data)): cost = data.count
            @unknown default: cost = Int.max
            }
            guard cost <= 1024 * 1024,
                  self.callbacks.submit(bytes: cost, { [self] in
                guard !callbacks.isClosed, state.activeTask() === task else { return }
                switch result {
                case .failure(let error): _ = requestDisconnect(error: error, notify: true)
                case .success(let message):
                    switch message {
                    case .string(let text): await delegate?.client(self, didReceive: text)
                    case .data(let data): await delegate?.client(self, didReceive: data)
                    @unknown default: _ = requestDisconnect(error: LightweightBridgeTransportError.connectionClosed, notify: true)
                    }
                    receiveNextMessage()
                }
            }) != nil else { _ = self.requestDisconnect(error: LightweightBridgeTransportError.connectionClosed, notify: true); return }
        }
    }
}

struct LightweightBridgeReconnectContext: Sendable {
    let endpointURL: URL
    let generation: UUID
}

struct LightweightBridgeReconnectPlan: Sendable {
    let context: LightweightBridgeReconnectContext
    let attempt: Int
    let delayNanoseconds: UInt64
}

actor LightweightBridgeReconnectCoordinator {
    private var context: LightweightBridgeReconnectContext?
    private var autoReconnectEnabled = false
    private var reconnecting = false
    private var reconnectAttempt = 0

    func configure(endpointURL: URL) -> LightweightBridgeReconnectContext {
        let context = LightweightBridgeReconnectContext(
            endpointURL: endpointURL,
            generation: UUID()
        )
        self.context = context
        autoReconnectEnabled = false
        reconnecting = false
        reconnectAttempt = 0
        return context
    }

    func clear() {
        context = nil
        autoReconnectEnabled = false
        reconnecting = false
        reconnectAttempt = 0
    }

    func markConnected(for generation: UUID, enableAutoReconnect: Bool) -> Bool {
        guard context?.generation == generation else {
            return false
        }
        reconnectAttempt = 0
        reconnecting = false
        if enableAutoReconnect {
            autoReconnectEnabled = true
        }
        return true
    }

    func reserveReconnect() -> LightweightBridgeReconnectContext? {
        guard autoReconnectEnabled, !reconnecting, let context else {
            return nil
        }
        reconnecting = true
        reconnectAttempt = 0
        return context
    }

    func nextReconnectPlan(
        for generation: UUID,
        baseDelayNanoseconds: UInt64,
        maximumDelayNanoseconds: UInt64
    ) -> LightweightBridgeReconnectPlan? {
        guard reconnecting, let context, context.generation == generation else {
            return nil
        }

        let attempt = reconnectAttempt + 1
        let delayNanoseconds: UInt64
        if attempt == 1 {
            delayNanoseconds = 0
        } else {
            let exponent = min(attempt - 2, 8)
            let multiplier = UInt64(1) << UInt64(exponent)
            let scaled = baseDelayNanoseconds.multipliedReportingOverflow(by: multiplier)
            delayNanoseconds = scaled.overflow ? maximumDelayNanoseconds : min(scaled.partialValue, maximumDelayNanoseconds)
        }

        reconnectAttempt = attempt
        return LightweightBridgeReconnectPlan(
            context: context,
            attempt: attempt,
            delayNanoseconds: delayNanoseconds
        )
    }

    func finishReconnectAttempt(for generation: UUID, success: Bool) -> Bool {
        guard let context, context.generation == generation else { return false }

        if success {
            reconnecting = false
            reconnectAttempt = 0
            autoReconnectEnabled = true
            return false
        }

        return reconnecting && autoReconnectEnabled
    }

    func cancelReconnect(for generation: UUID? = nil) {
        if let generation {
            guard context?.generation == generation else {
                return
            }
        }
        reconnecting = false
        reconnectAttempt = 0
    }

    func hasReconnectContext() -> Bool {
        context != nil && autoReconnectEnabled
    }

    func currentEndpointURL() -> URL? {
        context?.endpointURL
    }
}

private final class LightweightBridgeLifecycleObserver {
    private var notificationTokens: [(NotificationCenter, NSObjectProtocol)] = []

    init(onReactivation: @escaping @Sendable (String) -> Void) {
#if canImport(UIKit)
        let notificationCenter = NotificationCenter.default
        notificationTokens.append((
            notificationCenter,
            notificationCenter.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: nil
            ) { _ in
                onReactivation("foreground reactivation")
            }
        ))
        notificationTokens.append((
            notificationCenter,
            notificationCenter.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { _ in
                onReactivation("app activation")
            }
        ))
#endif
#if canImport(AppKit)
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        notificationTokens.append((
            workspaceCenter,
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { _ in
                onReactivation("wake")
            }
        ))
        let notificationCenter = NotificationCenter.default
        notificationTokens.append((
            notificationCenter,
            notificationCenter.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { _ in
                onReactivation("app activation")
            }
        ))
#endif
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        guard !notificationTokens.isEmpty else {
            return
        }

        for (center, token) in notificationTokens {
            center.removeObserver(token)
        }
        notificationTokens.removeAll()
    }
}

public final class LightweightBridgeTransport: BridgeTransportProtocol, LightweightWebSocketClientDelegate, @unchecked Sendable {
    private let lifecycleLock = NSLock()
    private let work = BridgeOwnedTasks()
    private var closed = false
    private var setupInProgress = false
    private var contextGeneration: UUID?
    private struct OwnedConnection {
        let client: any LightweightWebSocketClient
        var retirement: Task<Void, Never>?
    }
    private var ownedConnections: [ObjectIdentifier: OwnedConnection] = [:]
    private var lossEpoch = UUID()
    // Every created physical connection stays charged until disconnect returns.
    private func retireConnection(_ client: any LightweightWebSocketClient) -> Task<Void, Never>? {
        lifecycleLock.withLock {
            let id = ObjectIdentifier(client)
            guard ownedConnections[id] != nil else { return nil }
            if let task = ownedConnections[id]?.retirement { return task }
            let task = Task { [self] in
                try? await client.disconnect()
                lifecycleLock.withLock { ownedConnections[id] = nil }
            }
            if ownedConnections[id] != nil { ownedConnections[id]?.retirement = task }
            return task
        }
    }
    private var closeTask: Task<Void, Never>?
    private var isClosed: Bool { lifecycleLock.withLock { closed } }
    private var _delegate: BridgeDelegateProtocol?
    private var delegate: BridgeDelegateProtocol? {
        get { lifecycleLock.withLock { _delegate } }
        set { lifecycleLock.withLock { _delegate = newValue } }
    }
    private var _connection: (any LightweightWebSocketClient)?
    private var connection: (any LightweightWebSocketClient)? {
        get { lifecycleLock.withLock { _connection } }
        set { lifecycleLock.withLock { _connection = newValue } }
    }
    private var _activeConnectionIdentifier: ObjectIdentifier?
    private var activeConnectionIdentifier: ObjectIdentifier? {
        get { lifecycleLock.withLock { _activeConnectionIdentifier } }
        set { lifecycleLock.withLock { _activeConnectionIdentifier = newValue } }
    }
    private var _localIdentityUUID: String?
    private var localIdentityUUID: String? {
        get { lifecycleLock.withLock { _localIdentityUUID } }
        set { lifecycleLock.withLock { _localIdentityUUID = newValue } }
    }
    private var _localIdentityVault: IdentityVaultProtocol?
    private var localIdentityVault: IdentityVaultProtocol? {
        get { lifecycleLock.withLock { _localIdentityVault } }
        set { lifecycleLock.withLock { _localIdentityVault = newValue } }
    }
    private let connectionFactory: @Sendable (URL) -> any LightweightWebSocketClient
    private let keepAliveIntervalNanoseconds: UInt64
    private let reconnectBaseDelayNanoseconds: UInt64
    private let reconnectMaximumDelayNanoseconds: UInt64
    private let reconnectCoordinator = LightweightBridgeReconnectCoordinator()
    private var _keepAliveTask: Task<Void, Error>?
    private var keepAliveTask: Task<Void, Error>? {
        get { lifecycleLock.withLock { _keepAliveTask } }
        set { lifecycleLock.withLock { _keepAliveTask = newValue } }
    }
    private var _reconnectTask: Task<Void, Error>?
    private var reconnectTask: Task<Void, Error>? {
        get { lifecycleLock.withLock { _reconnectTask } }
        set { lifecycleLock.withLock { _reconnectTask = newValue } }
    }
    private lazy var lifecycleObserver = LightweightBridgeLifecycleObserver { [weak self] trigger in
        guard let self else { return }
        if self.work.submit({ await self.handleLifecycleReactivation(trigger: trigger) }) == nil {
            _ = self.requestClose()
        }
    }

    public init() {
        self.connectionFactory = { url in
            URLSessionLightweightWebSocketClient(url: url)
        }
        self.keepAliveIntervalNanoseconds = 10_000_000_000
        self.reconnectBaseDelayNanoseconds = 1_000_000_000
        self.reconnectMaximumDelayNanoseconds = 30_000_000_000
        _ = lifecycleObserver
    }

    init(
        connectionFactory: @escaping @Sendable (URL) -> any LightweightWebSocketClient,
        keepAliveIntervalNanoseconds: UInt64 = 10_000_000_000,
        reconnectBaseDelayNanoseconds: UInt64 = 1_000_000_000,
        reconnectMaximumDelayNanoseconds: UInt64 = 30_000_000_000
    ) {
        self.connectionFactory = connectionFactory
        self.keepAliveIntervalNanoseconds = keepAliveIntervalNanoseconds
        self.reconnectBaseDelayNanoseconds = reconnectBaseDelayNanoseconds
        self.reconnectMaximumDelayNanoseconds = reconnectMaximumDelayNanoseconds
        _ = lifecycleObserver
    }

    deinit {
        keepAliveTask?.cancel()
        reconnectTask?.cancel()
        lifecycleObserver.invalidate()
    }

    public static func new() -> BridgeTransportProtocol {
        LightweightBridgeTransport()
    }

    public func setDelegate(_ delegate: BridgeDelegateProtocol) {
        lifecycleLock.withLock { if !closed { _delegate = delegate } }
    }

    @discardableResult
    private func requestClose() -> Task<Void, Never> {
        lifecycleLock.withLock {
            if let closeTask { return closeTask }
            closed = true
            contextGeneration = nil
            let connections = ownedConnections.values.map(\.client)
            _connection = nil; _activeConnectionIdentifier = nil
            _delegate = nil
            _keepAliveTask?.cancel(); _reconnectTask?.cancel()
            work.requestStop()
            let task = Task { [self] in
                lifecycleObserver.invalidate()
                await reconnectCoordinator.clear()
                let retirements = connections.compactMap { retireConnection($0) }
                for retirement in retirements { await retirement.value }
                await work.finishStop()
                lifecycleLock.withLock { _keepAliveTask = nil; _reconnectTask = nil }
            }
            closeTask = task
            return task
        }
    }

    public func close() async { await requestClose().value }

    public func setup(_ endpointURL: URL, identity: Identity) async throws {
        guard let task = work.submit({ try await self.setupOwned(endpointURL, identity: identity) }) else {
            throw LightweightBridgeTransportError.connectionCancelled
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func setupOwned(_ endpointURL: URL, identity: Identity) async throws {
        try lifecycleLock.withLock {
            guard !closed, !setupInProgress else { throw LightweightBridgeTransportError.connectionCancelled }
            setupInProgress = true
            contextGeneration = nil
            lossEpoch = UUID()
        }
        defer { lifecycleLock.withLock { setupInProgress = false } }
        cancelReconnectLoop()
        keepAliveTask?.cancel()
        keepAliveTask = nil
        localIdentityUUID = identity.uuid
        localIdentityVault = identity.identityVault ?? CellBase.defaultIdentityVault

        if let existingConnection = connection {
            clearActiveConnection()
            await retireConnection(existingConnection)?.value
        }

        let reconnectContext = await reconnectCoordinator.configure(endpointURL: endpointURL)
        try lifecycleLock.withLock {
            guard !closed else { throw LightweightBridgeTransportError.connectionCancelled }
            contextGeneration = reconnectContext.generation
        }
        postConnectionStatus(.connecting, endpoint: endpointURL)

        do {
            try await establishConnection(
                using: reconnectContext,
                enableAutoReconnectOnSuccess: true,
                connectedDetail: "Initial connection established"
            )
        } catch {
            postConnectionStatus(.failed, endpoint: endpointURL, detail: error.localizedDescription)
            await reconnectCoordinator.clear()
            await delegate?.sendSetValueState(for: ReservedKeypath.bridgesetup.rawValue, setValueState: .paramErr)
            await delegate?.pushError(errorMessage: "Lightweight bridge setup failed", error: error)
            throw error
        }
    }

    public func sendData(_ data: Data) async throws {
        let task = lifecycleLock.withLock { () -> Task<Void, Error>? in
            guard !closed, data.count <= 1024 * 1024, let client = _connection, let generation = contextGeneration else { return nil }
            return work.submit(bytes: data.count, { try await self.sendOwned(data, client: client, generation: generation) })
        }
        guard let task else {
            _ = requestClose()
            throw LightweightBridgeTransportError.connectionCancelled
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    var beforeOwnedSend: (@Sendable () async -> Void)?
    private func sendOwned(_ data: Data, client connection: any LightweightWebSocketClient, generation: UUID) async throws {
        await beforeOwnedSend?()
        guard isActiveConnection(connection), lifecycleLock.withLock({ contextGeneration == generation }) else {
            throw LightweightBridgeTransportError.notConnected
        }

        do {
            if CellBase.sendDataAsText {
                guard let text = String(data: data, encoding: .utf8) else {
                    throw LightweightBridgeTransportError.invalidTextPayload
                }
                try await connection.send(text: text)
            } else {
                try await connection.send(data: data)
            }
            guard isActiveConnection(connection) else { throw LightweightBridgeTransportError.connectionCancelled }
        } catch {
            await handleConnectionLoss(
                from: connection,
                error: error,
                message: "Lightweight bridge send failed; attempting reconnect",
                disconnectUnderlying: false,
                attemptReconnect: true
            )
            throw error
        }
    }

    public func identityVault(for identity: Identity?) async -> IdentityVaultProtocol {
        // This API resolves incoming wire descriptors, never local signing authority.
        // Even an exact public-key match must prove origin back at the peer.
        // A missing delegate yields a proxy that fails closed.
        return BridgeIdentityVault(cloudBridge: delegate as? BridgeProtocol)
    }

    func clientDidConnect(_ client: any LightweightWebSocketClient) async {
    }

    func clientDidDisconnect(_ client: any LightweightWebSocketClient, error: Error?) async {
        guard isActiveConnection(client) else { return }
        guard let task = work.submit({ await self.handleConnectionLoss(from: client, error: error,
                message: self.reconnectMessage(for: error, base: "Lightweight bridge disconnected"),
                disconnectUnderlying: false, attemptReconnect: self.shouldReconnect(after: error)) }) else { _ = requestClose(); return }
        _ = try? await task.value
    }

    func client(_ client: any LightweightWebSocketClient, didReceive text: String) async {
        guard let data = text.data(using: .utf8) else { _ = requestClose(); return }
        await receiveOwned(data, client: client)
    }

    func client(_ client: any LightweightWebSocketClient, didReceive data: Data) async {
        await receiveOwned(data, client: client)
    }

    private func receiveOwned(_ data: Data, client: any LightweightWebSocketClient) async {
        guard isActiveConnection(client) else { return }
        let command: BridgeCommand
        do {
            try BridgeInboundPayloadValidator().validate(data)
            command = try JSONDecoder().decode(BridgeCommand.self, from: data)
        } catch {
            // Close admission before auditing; an owned callback must not join itself.
            let rejectedDelegate = delegate
            let audit = work.submit(bytes: data.count) {
                if let payloadError = error as? BridgeInboundPayloadError {
                    await CellBase.recordSecurityEvent(.bridgePayloadRejected(transportIdentifier: "lightweight-websocket", error: payloadError))
                }
                await rejectedDelegate?.pushError(errorMessage: "Rejected invalid bridge payload", error: nil)
            }
            _ = requestClose()
            _ = try? await audit?.value
            return
        }
        // Channel authentication (main #53) keeps its contract: a frame the
        // delegate's channel gate refuses is reported and dropped, the socket stays.
        do {
            try delegate?.validateInboundPayload(data)
        } catch {
            let rejectedDelegate = delegate
            let audit = work.submit(bytes: data.count) {
                if let payloadError = error as? BridgeInboundPayloadError {
                    await CellBase.recordSecurityEvent(.bridgePayloadRejected(transportIdentifier: "lightweight-websocket", error: payloadError))
                    await rejectedDelegate?.pushError(errorMessage: "Rejected invalid bridge payload", error: nil)
                } else {
                    await rejectedDelegate?.pushError(errorMessage: "bridge_payload_rejected", error: error)
                }
            }
            guard let audit else { _ = requestClose(); return }
            _ = try? await audit.value
            return
        }
        guard data.count <= 1024 * 1024,
              let task = work.submit(bytes: data.count, { await self.handleIncomingCommand(command, client: client) }) else {
            _ = requestClose(); return
        }
        _ = try? await task.value
    }

    func client(_ client: any LightweightWebSocketClient, didReceive error: Error) async {
        await clientDidDisconnect(client, error: error)
    }

    private func establishConnection(
        using reconnectContext: LightweightBridgeReconnectContext,
        enableAutoReconnectOnSuccess: Bool,
        connectedDetail: String? = nil
    ) async throws {
        let connection = connectionFactory(reconnectContext.endpointURL)
        connection.delegate = self
        try installActiveConnection(connection, generation: reconnectContext.generation)

        do {
            try await connection.connect()
            guard isActiveConnection(connection) else { throw LightweightBridgeTransportError.connectionCancelled }
            try await connection.ping()
            guard isActiveConnection(connection) else { throw LightweightBridgeTransportError.connectionCancelled }
            let marked = await reconnectCoordinator.markConnected(
                for: reconnectContext.generation,
                enableAutoReconnect: enableAutoReconnectOnSuccess
            )
            guard marked, isActiveConnection(connection) else { throw LightweightBridgeTransportError.connectionCancelled }
            postConnectionStatus(.connected, endpoint: reconnectContext.endpointURL, detail: connectedDetail)
            startKeepAliveLoop(connection: connection)
        } catch {
            clearActiveConnection(ifMatching: connection)
            await retireConnection(connection)?.value
            throw error
        }
    }

    private func startKeepAliveLoop(connection: any LightweightWebSocketClient) {
        lifecycleLock.lock()
        guard !closed, _activeConnectionIdentifier == ObjectIdentifier(connection) else { lifecycleLock.unlock(); return }
        _keepAliveTask?.cancel()
        _keepAliveTask = work.submit { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: keepAliveIntervalNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                do {
                    try await connection.ping()
                } catch {
                    await self.handleConnectionLoss(
                        from: connection,
                        error: error,
                        message: "Lightweight bridge keepalive failed; attempting reconnect",
                        disconnectUnderlying: true,
                        attemptReconnect: true
                    )
                    return
                }
            }
        }
        let admitted = _keepAliveTask != nil
        lifecycleLock.unlock()
        if !admitted { _ = requestClose() }
    }

    private func handleIncomingCommand(_ command: BridgeCommand, client: any LightweightWebSocketClient) async {
        guard isActiveConnection(client), let delegate else { return }
        let vault = await identityVault(for: command.identity)
        guard isActiveConnection(client) else { return }
        command.identity?.identityVault = vault

        do {
            switch command.command {
            case .response:
                try await delegate.consumeResponse(command: command)
            default:
                try await delegate.consumeCommand(command: command)
            }
        } catch {
            guard isActiveConnection(client) else { return }
            await delegate.pushError(errorMessage: "Lightweight bridge delegate handling failed", error: error)
        }
    }

    private func handleConnectionLoss(
        from client: any LightweightWebSocketClient,
        error: Error?, message: String?, disconnectUnderlying: Bool, attemptReconnect: Bool
    ) async {
        let token = lifecycleLock.withLock { () -> (UUID, UUID?)? in
            guard !closed, _activeConnectionIdentifier == ObjectIdentifier(client) else { return nil }
            _connection = nil; _activeConnectionIdentifier = nil
            _keepAliveTask?.cancel(); _keepAliveTask = nil
            lossEpoch = UUID()
            return (lossEpoch, contextGeneration)
        }
        guard let token else { return }
        let retirement = retireConnection(client)
        // A URLSession disconnect notification can originate in its own finalizer.
        // Return that callback first; separate owned work waits physical retirement.
        guard work.submit({ [self] in
            await retirement?.value
            func current() -> Bool { lifecycleLock.withLock { !closed && lossEpoch == token.0 && contextGeneration == token.1 } }
            guard current() else { return }
            if let message { await delegate?.pushError(errorMessage: message, error: error) }
            guard current() else { return }
            let endpoint = await reconnectCoordinator.currentEndpointURL()
            guard current() else { return }
            if let endpoint { postConnectionStatus(attemptReconnect ? .reconnecting : .disconnected, endpoint: endpoint, detail: message ?? error?.localizedDescription) }
            guard current() else { return }
            if attemptReconnect { await scheduleReconnectIfNeeded() }
            else if let generation = token.1 { await reconnectCoordinator.cancelReconnect(for: generation) }
        }) != nil else { _ = requestClose(); return }
    }

    var reconnectTaskDidReturn: (@Sendable () -> Void)?
    private func scheduleReconnectIfNeeded() async {
        guard let reconnectContext = await reconnectCoordinator.reserveReconnect() else {
            return
        }

        lifecycleLock.lock()
        guard !closed, contextGeneration == reconnectContext.generation else { lifecycleLock.unlock(); return }
        _reconnectTask?.cancel()
        _reconnectTask = work.submit { [weak self] in
            guard let self else { return }
            let returned = self.reconnectTaskDidReturn
            defer { returned?() }

            while !Task.isCancelled {
                guard let plan = await self.reconnectCoordinator.nextReconnectPlan(
                    for: reconnectContext.generation,
                    baseDelayNanoseconds: self.reconnectBaseDelayNanoseconds,
                    maximumDelayNanoseconds: self.reconnectMaximumDelayNanoseconds
                ) else {
                    return
                }

                self.postConnectionStatus(
                    .reconnecting,
                    endpoint: plan.context.endpointURL,
                    detail: self.reconnectAttemptDescription(for: plan.delayNanoseconds),
                    attempt: plan.attempt
                )

                if plan.delayNanoseconds > 0 {
                    do {
                        try await Task.sleep(nanoseconds: plan.delayNanoseconds)
                    } catch {
                        await self.reconnectCoordinator.cancelReconnect(for: reconnectContext.generation)
                        return
                    }
                }

                guard !Task.isCancelled else {
                    await self.reconnectCoordinator.cancelReconnect(for: reconnectContext.generation)
                    return
                }

                do {
                    try await self.establishConnection(
                        using: plan.context,
                        enableAutoReconnectOnSuccess: true,
                        connectedDetail: plan.attempt == 1 ? "Reconnected" : "Reconnected after \(plan.attempt) attempts"
                    )
                    _ = await self.reconnectCoordinator.finishReconnectAttempt(for: reconnectContext.generation, success: true)
                    return
                } catch {
                    guard self.lifecycleLock.withLock({ !self.closed && self.contextGeneration == reconnectContext.generation }) else { return }
                    let shouldContinue = await self.reconnectCoordinator.finishReconnectAttempt(
                        for: reconnectContext.generation,
                        success: false
                    )
                    guard self.lifecycleLock.withLock({ !self.closed && self.contextGeneration == reconnectContext.generation }) else { return }
                    if plan.attempt == 1 {
                        await self.delegate?.pushError(
                            errorMessage: "Lightweight bridge reconnect failed; retrying with backoff",
                            error: error
                        )
                    }
                    guard self.lifecycleLock.withLock({ !self.closed && self.contextGeneration == reconnectContext.generation }) else { return }
                    guard shouldContinue else {
                        self.postConnectionStatus(
                            .failed,
                            endpoint: plan.context.endpointURL,
                            detail: error.localizedDescription,
                            attempt: plan.attempt
                        )
                        return
                    }
                }
            }
        }
        let admitted = _reconnectTask != nil
        lifecycleLock.unlock()
        if !admitted { _ = requestClose() }
    }

    private func shouldReconnect(after error: Error?) -> Bool {
        switch error {
        case nil:
            return true
        case is CancellationError:
            return false
        case let error as LightweightBridgeTransportError:
            switch error {
            case .connectionCancelled:
                return false
            default:
                return true
            }
        case let urlError as URLError:
            return urlError.code != .cancelled
        default:
            return true
        }
    }

    private func reconnectMessage(for error: Error?, base: String) -> String? {
        shouldReconnect(after: error) ? "\(base); attempting reconnect" : base
    }

    private func reconnectAttemptDescription(for delayNanoseconds: UInt64) -> String {
        guard delayNanoseconds > 0 else {
            return "Retrying now"
        }

        let seconds = Double(delayNanoseconds) / 1_000_000_000
        if seconds >= 10 {
            return String(format: "Retrying in %.0fs", seconds)
        }
        return String(format: "Retrying in %.1fs", seconds)
    }

    private func postConnectionStatus(
        _ phase: LightweightBridgeConnectionStatus.Phase,
        endpoint: URL,
        detail: String? = nil,
        attempt: Int? = nil
    ) {
        guard !isClosed else { return }
        let status = LightweightBridgeConnectionStatus(
            phase: phase,
            endpoint: endpoint.absoluteString,
            detail: detail,
            attempt: attempt
        )
        NotificationCenter.default.post(
            name: .lightweightBridgeConnectionStatusDidChange,
            object: nil,
            userInfo: status.notificationUserInfo
        )
    }

    func handleLifecycleReactivation(trigger: String = "reactivation") async {
        guard !isClosed else { return }
        if let connection {
            do {
                try await connection.ping()
            } catch {
                await handleConnectionLoss(
                    from: connection,
                    error: error,
                    message: "Lightweight bridge \(trigger) health check failed; attempting reconnect",
                    disconnectUnderlying: true,
                    attemptReconnect: true
                )
            }
            return
        }

        guard await reconnectCoordinator.hasReconnectContext() else {
            return
        }
        await scheduleReconnectIfNeeded()
    }

    private func installActiveConnection(_ connection: any LightweightWebSocketClient, generation: UUID) throws {
        try lifecycleLock.withLock {
            guard !closed, ownedConnections.count < 64, contextGeneration == generation else { throw LightweightBridgeTransportError.connectionCancelled }
            ownedConnections[ObjectIdentifier(connection)] = OwnedConnection(client: connection, retirement: nil)
            lossEpoch = UUID()
            _connection = connection
            _activeConnectionIdentifier = ObjectIdentifier(connection)
        }
    }

    private func clearActiveConnection() {
        lifecycleLock.withLock { _connection = nil; _activeConnectionIdentifier = nil }
    }

    @discardableResult
    private func clearActiveConnection(ifMatching client: any LightweightWebSocketClient) -> Bool {
        lifecycleLock.withLock {
            guard !closed, _activeConnectionIdentifier == ObjectIdentifier(client) else { return false }
            _connection = nil; _activeConnectionIdentifier = nil
            _keepAliveTask?.cancel(); _keepAliveTask = nil
            return true
        }
    }

    private func isActiveConnection(_ connection: any LightweightWebSocketClient) -> Bool {
        lifecycleLock.withLock { !closed && _activeConnectionIdentifier == ObjectIdentifier(connection) }
    }

    private func cancelReconnectLoop() {
        lifecycleLock.withLock { _reconnectTask?.cancel(); _reconnectTask = nil }
    }
}
