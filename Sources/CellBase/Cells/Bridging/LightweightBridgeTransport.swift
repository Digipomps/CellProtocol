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

private actor URLSessionLightweightWebSocketState {
    private enum Phase {
        case idle
        case connecting
        case connected
        case closed
    }

    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var phase: Phase = .idle

    func prepare(session: URLSession, task: URLSessionWebSocketTask) {
        urlSession = session
        webSocketTask = task
        connectContinuation = nil
        phase = .connecting
    }

    func installContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        guard phase == .connecting else {
            continuation.resume(throwing: LightweightBridgeTransportError.connectionCancelled)
            return
        }
        connectContinuation = continuation
    }

    func completeConnection() -> CheckedContinuation<Void, Error>? {
        guard phase == .connecting else {
            return nil
        }
        phase = .connected
        let continuation = connectContinuation
        connectContinuation = nil
        return continuation
    }

    func timeoutConnectionAttempt() -> URLSessionLightweightWebSocketSnapshot? {
        guard phase == .connecting else {
            return nil
        }
        return close(shouldNotifyDisconnect: false)
    }

    func close(shouldNotifyDisconnect: Bool = true) -> URLSessionLightweightWebSocketSnapshot {
        let snapshot = URLSessionLightweightWebSocketSnapshot(
            task: webSocketTask,
            session: urlSession,
            continuation: connectContinuation,
            shouldNotifyDisconnect: shouldNotifyDisconnect && phase == .connected
        )
        webSocketTask = nil
        urlSession = nil
        connectContinuation = nil
        phase = .closed
        return snapshot
    }

    func activeTask() -> URLSessionWebSocketTask? {
        guard phase == .connected else {
            return nil
        }
        return webSocketTask
    }
}

private enum URLSessionLightweightWebSocketOperation {
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

private final class URLSessionLightweightWebSocketCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?

    func install(
        _ continuation: CheckedContinuation<Void, Error>,
        operation: URLSessionLightweightWebSocketOperation
    ) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()

        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: operation.timeoutNanoseconds)
            } catch {
                return
            }
            self?.resume(with: .failure(operation.timeoutError))
        }

        lock.lock()
        if self.continuation == nil {
            lock.unlock()
            timeoutTask.cancel()
            return
        }
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    func resume(with result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>?
        let timeoutTask: Task<Void, Never>?

        lock.lock()
        continuation = self.continuation
        self.continuation = nil
        timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        guard let continuation else {
            return
        }

        timeoutTask?.cancel()
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private final class URLSessionLightweightWebSocketClient: NSObject, LightweightWebSocketClient, URLSessionWebSocketDelegate, @unchecked Sendable {
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

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        let task = session.webSocketTask(with: url)

        await state.prepare(session: session, task: task)

        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.connectTimeoutNanoseconds)
            } catch {
                return
            }
            await self?.failPendingConnect(error: URLError(
                .timedOut,
                userInfo: [NSLocalizedDescriptionKey: "Lightweight websocket connect timed out"]
            ))
        }

        defer {
            timeoutTask.cancel()
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Task {
                    await state.installContinuation(continuation)
                    task.resume()
                }
            }
        } onCancel: {
            Task {
                await self.cancelPendingConnect()
            }
        }
    }

    func disconnect() async throws {
        let snapshot = await state.close(shouldNotifyDisconnect: false)
        snapshot.continuation?.resume(throwing: LightweightBridgeTransportError.connectionCancelled)
        snapshot.task?.cancel(with: .goingAway, reason: nil)
        snapshot.session?.invalidateAndCancel()
        delegateQueue.cancelAllOperations()
    }

    func send(text: String) async throws {
        guard let task = await state.activeTask() else {
            throw LightweightBridgeTransportError.notConnected
        }
        try await perform(operation: .sendText) { completion in
            task.send(.string(text), completionHandler: completion)
        }
    }

    func send(data: Data) async throws {
        guard let task = await state.activeTask() else {
            throw LightweightBridgeTransportError.notConnected
        }
        try await perform(operation: .sendData) { completion in
            task.send(.data(data), completionHandler: completion)
        }
    }

    func ping() async throws {
        guard let task = await state.activeTask() else {
            throw LightweightBridgeTransportError.notConnected
        }
        try await perform(operation: .ping) { completion in
            task.sendPing(pongReceiveHandler: completion)
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task {
            let continuation = await state.completeConnection()
            continuation?.resume()
            receiveNextMessage()
            await delegate?.clientDidConnect(self)
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task {
            await terminateConnection(error: nil, shouldNotifyDisconnect: true)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            return
        }
        Task {
            await terminateConnection(error: error, shouldNotifyDisconnect: true)
        }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        guard let error else {
            return
        }
        Task {
            await terminateConnection(error: error, shouldNotifyDisconnect: true)
        }
    }

    private func perform(
        operation: URLSessionLightweightWebSocketOperation,
        using block: @escaping (@escaping @Sendable (Error?) -> Void) -> Void
    ) async throws {
        let completion = URLSessionLightweightWebSocketCompletion()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                completion.install(continuation, operation: operation)
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
    }

    private func failPendingConnect(error: Error) async {
        guard let snapshot = await state.timeoutConnectionAttempt() else {
            return
        }
        snapshot.task?.cancel(with: .goingAway, reason: nil)
        snapshot.session?.invalidateAndCancel()
        snapshot.continuation?.resume(throwing: error)
        delegateQueue.cancelAllOperations()
    }

    private func cancelPendingConnect() async {
        let snapshot = await state.close(shouldNotifyDisconnect: false)
        snapshot.continuation?.resume(throwing: CancellationError())
        snapshot.task?.cancel(with: .goingAway, reason: nil)
        snapshot.session?.invalidateAndCancel()
        delegateQueue.cancelAllOperations()
    }

    private func terminateConnection(error: Error?, shouldNotifyDisconnect: Bool) async {
        let snapshot = await state.close(shouldNotifyDisconnect: shouldNotifyDisconnect)
        let disconnectError = error ?? LightweightBridgeTransportError.connectionClosed

        snapshot.task?.cancel(with: .goingAway, reason: nil)
        snapshot.session?.invalidateAndCancel()
        delegateQueue.cancelAllOperations()

        snapshot.continuation?.resume(throwing: disconnectError)

        guard snapshot.shouldNotifyDisconnect else {
            return
        }
        await delegate?.clientDidDisconnect(self, error: error)
    }

    private func receiveNextMessage() {
        Task {
            guard let task = await state.activeTask() else {
                return
            }

            task.receive { [weak self] result in
                guard let self else {
                    return
                }
                Task {
                    switch result {
                    case .failure(let error):
                        await self.terminateConnection(error: error, shouldNotifyDisconnect: true)
                    case .success(let message):
                        switch message {
                        case .string(let text):
                            await self.delegate?.client(self, didReceive: text)
                        case .data(let data):
                            await self.delegate?.client(self, didReceive: data)
                        @unknown default:
                            await self.delegate?.client(self, didReceive: LightweightBridgeTransportError.connectionClosed)
                        }
                        self.receiveNextMessage()
                    }
                }
            }
        }
    }
}

private struct LightweightBridgeReconnectContext: Sendable {
    let endpointURL: URL
    let generation: UUID
}

private struct LightweightBridgeReconnectPlan: Sendable {
    let context: LightweightBridgeReconnectContext
    let attempt: Int
    let delayNanoseconds: UInt64
}

private actor LightweightBridgeReconnectCoordinator {
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
        guard let context, context.generation == generation else {
            reconnecting = false
            reconnectAttempt = 0
            return false
        }

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
    private var delegate: BridgeDelegateProtocol?
    private var connection: (any LightweightWebSocketClient)?
    private var activeConnectionIdentifier: ObjectIdentifier?
    private var localIdentityUUID: String?
    private var localIdentityVault: IdentityVaultProtocol?
    private let connectionFactory: @Sendable (URL) -> any LightweightWebSocketClient
    private let keepAliveIntervalNanoseconds: UInt64
    private let reconnectBaseDelayNanoseconds: UInt64
    private let reconnectMaximumDelayNanoseconds: UInt64
    private let reconnectCoordinator = LightweightBridgeReconnectCoordinator()
    private var keepAliveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private lazy var lifecycleObserver = LightweightBridgeLifecycleObserver { [weak self] trigger in
        Task { [weak self] in
            await self?.handleLifecycleReactivation(trigger: trigger)
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
        self.delegate = delegate
    }

    public func setup(_ endpointURL: URL, identity: Identity) async throws {
        cancelReconnectLoop()
        keepAliveTask?.cancel()
        keepAliveTask = nil
        localIdentityUUID = identity.uuid
        localIdentityVault = identity.identityVault ?? CellBase.defaultIdentityVault

        if let existingConnection = connection {
            clearActiveConnection()
            try? await existingConnection.disconnect()
        }

        let reconnectContext = await reconnectCoordinator.configure(endpointURL: endpointURL)
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
        guard let connection else {
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
        if let identity {
            if let localIdentityUUID,
               identity.uuid == localIdentityUUID,
               let localIdentityVault {
                return localIdentityVault
            }
            if let defaultVault = CellBase.defaultIdentityVault {
                if await defaultVault.identityExistInVault(identity) {
                    return defaultVault
                }
            }
            if let localIdentityVault,
               await localIdentityVault.identityExistInVault(identity) {
                return localIdentityVault
            }
        }
        if let bridge = delegate as? BridgeProtocol {
            return BridgeIdentityVault(cloudBridge: bridge)
        }
        if let defaultVault = CellBase.defaultIdentityVault {
            return defaultVault
        }
        return BridgeIdentityVault()
    }

    func clientDidConnect(_ client: any LightweightWebSocketClient) async {
    }

    func clientDidDisconnect(_ client: any LightweightWebSocketClient, error: Error?) async {
        await handleConnectionLoss(
            from: client,
            error: error,
            message: reconnectMessage(for: error, base: "Lightweight bridge disconnected"),
            disconnectUnderlying: false,
            attemptReconnect: shouldReconnect(after: error)
        )
    }

    func client(_ client: any LightweightWebSocketClient, didReceive text: String) async {
        guard let data = text.data(using: .utf8) else {
            await delegate?.pushError(
                errorMessage: "Failed to decode text frame as UTF-8",
                error: LightweightBridgeTransportError.invalidTextPayload
            )
            return
        }
        await handleIncomingData(data)
    }

    func client(_ client: any LightweightWebSocketClient, didReceive data: Data) async {
        await handleIncomingData(data)
    }

    func client(_ client: any LightweightWebSocketClient, didReceive error: Error) async {
        await handleConnectionLoss(
            from: client,
            error: error,
            message: reconnectMessage(for: error, base: "Lightweight bridge transport error"),
            disconnectUnderlying: false,
            attemptReconnect: shouldReconnect(after: error)
        )
    }

    private func establishConnection(
        using reconnectContext: LightweightBridgeReconnectContext,
        enableAutoReconnectOnSuccess: Bool,
        connectedDetail: String? = nil
    ) async throws {
        let connection = connectionFactory(reconnectContext.endpointURL)
        connection.delegate = self
        installActiveConnection(connection)

        do {
            try await connection.connect()
            try await connection.ping()
            _ = await reconnectCoordinator.markConnected(
                for: reconnectContext.generation,
                enableAutoReconnect: enableAutoReconnectOnSuccess
            )
            postConnectionStatus(.connected, endpoint: reconnectContext.endpointURL, detail: connectedDetail)
            startKeepAliveLoop(connection: connection)
        } catch {
            if isActiveConnection(connection) {
                clearActiveConnection()
            }
            keepAliveTask?.cancel()
            keepAliveTask = nil
            try? await connection.disconnect()
            throw error
        }
    }

    private func startKeepAliveLoop(connection: any LightweightWebSocketClient) {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
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
    }

    private func handleIncomingData(_ data: Data) async {
        guard let command = try? JSONDecoder().decode(BridgeCommand.self, from: data),
              let delegate else {
            await self.delegate?.pushError(errorMessage: "Failed to decode bridge command", error: nil)
            return
        }

        let vault = await identityVault(for: command.identity)
        command.identity?.identityVault = vault

        do {
            switch command.command {
            case .response:
                try await delegate.consumeResponse(command: command)
            default:
                try await delegate.consumeCommand(command: command)
            }
        } catch {
            await delegate.pushError(errorMessage: "Lightweight bridge delegate handling failed", error: error)
        }
    }

    private func handleConnectionLoss(
        from client: any LightweightWebSocketClient,
        error: Error?,
        message: String?,
        disconnectUnderlying: Bool,
        attemptReconnect: Bool
    ) async {
        guard isActiveConnection(client) else {
            return
        }

        keepAliveTask?.cancel()
        keepAliveTask = nil
        clearActiveConnection()

        if disconnectUnderlying {
            try? await client.disconnect()
        }

        if let message {
            await delegate?.pushError(errorMessage: message, error: error)
        }

        if let endpointURL = await reconnectCoordinator.currentEndpointURL() {
            postConnectionStatus(
                attemptReconnect ? .reconnecting : .disconnected,
                endpoint: endpointURL,
                detail: message ?? error?.localizedDescription
            )
        }

        guard attemptReconnect else {
            cancelReconnectLoop()
            await reconnectCoordinator.cancelReconnect()
            return
        }

        await scheduleReconnectIfNeeded()
    }

    private func scheduleReconnectIfNeeded() async {
        guard let reconnectContext = await reconnectCoordinator.reserveReconnect() else {
            return
        }

        cancelReconnectLoop()
        reconnectTask = Task { [weak self] in
            guard let self else { return }

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
                    let shouldContinue = await self.reconnectCoordinator.finishReconnectAttempt(
                        for: reconnectContext.generation,
                        success: false
                    )
                    if plan.attempt == 1 {
                        await self.delegate?.pushError(
                            errorMessage: "Lightweight bridge reconnect failed; retrying with backoff",
                            error: error
                        )
                    }
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

    private func installActiveConnection(_ connection: any LightweightWebSocketClient) {
        self.connection = connection
        activeConnectionIdentifier = ObjectIdentifier(connection as AnyObject)
    }

    private func clearActiveConnection() {
        connection = nil
        activeConnectionIdentifier = nil
    }

    private func isActiveConnection(_ connection: any LightweightWebSocketClient) -> Bool {
        activeConnectionIdentifier == ObjectIdentifier(connection as AnyObject)
    }

    private func cancelReconnectLoop() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }
}
