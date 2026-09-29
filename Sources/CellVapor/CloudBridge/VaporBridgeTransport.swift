// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 08/12/2022.
//

import Foundation
import CellBase
import Vapor
import NIOCore

private enum VaporBridgeTransportEventLoops {
    static let shared = MultiThreadedEventLoopGroup(numberOfThreads: 2)
}

private final class VaporBridgeSetupWaiter: @unchecked Sendable {
    let promise: EventLoopPromise<Void>
    private let lock = NSLock()
    private var completed = false
    init(on eventLoop: any EventLoop) { promise = eventLoop.makePromise(of: Void.self) }
    func complete(_ result: Result<Void, Error>) {
        let first = lock.withLock { () -> Bool in
            guard !completed else { return false }; completed = true; return true
        }
        if first { promise.completeWith(result) }
    }
}

struct VaporBridgeIdentitySnapshot: Sendable {
    private let encodedIdentity: Data?
    private let fallbackUUID: String
    private let fallbackDisplayName: String

    var uuid: String {
        fallbackUUID
    }

    init(_ identity: Identity) {
        self.encodedIdentity = try? JSONEncoder().encode(identity)
        self.fallbackUUID = identity.uuid
        self.fallbackDisplayName = identity.displayName
    }

    func makeIdentity() -> Identity {
        if
            let encodedIdentity,
            let identity = try? JSONDecoder().decode(Identity.self, from: encodedIdentity)
        {
            return identity
        }
        return Identity(fallbackUUID, displayName: fallbackDisplayName, identityVault: nil)
    }
}

public class VaporBridgeTransport: BridgeTransportProtocol, @unchecked Sendable {
    public func setDelegate(_ delegate: BridgeDelegateProtocol) {
        withStateLock {
            self.delegate = delegate
        }
    }
    

    private let stateLock = NSLock()
    private var delegate: BridgeDelegateProtocol?
    private var webSocket: WebSocket?
    private var closeCleanupCompleted = false
    private var connectionGeneration = UUID()
    private var setupWaiter: VaporBridgeSetupWaiter?
    private var outgoingGroup: MultiThreadedEventLoopGroup?
    private var physicalCloseTask: Task<Void, Never>?
    private var closeUnderlyingChannel: (@Sendable () async -> Void)?
    

    private let receiveLock = NSLock()
    private var receiveBudget = VaporBridgeReceiveBudget.shared
    private var queuedReceives = 0
    private var queuedReceiveBytes = 0
    private var receivesStopped = false
    private var receiveTail: Task<Void, Never>?
    private var dispatchTail: Task<Void, Never>?
    private var receiveCloseTask: Task<Void, Never>?
    // Deterministic test seams, installed before traffic; no production bypass.
    var beforeReceivePreparation: (@Sendable () async -> Void)?
    var receiveSnapshot: (count: Int, bytes: Int, stopped: Bool) {
        receiveLock.withLock { (queuedReceives, queuedReceiveBytes, receivesStopped) }
    }

    convenience init(webSocket: WebSocket, receiveBudget: VaporBridgeReceiveBudget,
                     closeUnderlyingChannel: (@Sendable () async -> Void)? = nil) {
        self.init(closeUnderlyingChannel: closeUnderlyingChannel)
        self.receiveBudget = receiveBudget
        setWebSocket(webSocket)
    }

    var identityDomain:String
    var delegateSource: (() async throws -> BridgeDelegateProtocol?)?
    
    /// Public ingress hosts must pass their owned NIO Channel close operation;
    /// a WebSocket close frame alone cannot force an uncooperative peer to leave.
    public init(webSocket: WebSocket? = nil, closeUnderlyingChannel: (@Sendable () async -> Void)? = nil) {
        self.webSocket = webSocket
        self.closeUnderlyingChannel = closeUnderlyingChannel
        self.identityDomain = "private" // May not be needed?
        if let webSocket {
            self.setupWebSocketCallbacks(on: webSocket)
        }
    }
    
    public static func new() -> BridgeTransportProtocol {
        return VaporBridgeTransport()
    }

    deinit {
        if let group = outgoingGroup {
            Task { try? await group.shutdownGracefully() }
        }
    }

    
    var feedEndpoint : URL?
    private var websocketEndpointURL = URL(string: "ws://127.0.0.1:8081/bridgehead/123456")
    
//    public func setDelegateSource(_ source: (() async throws -> BridgeDelegateProtocol?)?) {
//        Task {
//            delegate = try await source?()
//        }
//    }
    
    private func setWebSocket(_ ws: WebSocket) {
        withStateLock {
            self.webSocket = ws
            self.closeCleanupCompleted = false
        }
        self.setupWebSocketCallbacks(on: ws)
    }
    
    public func setup(_ endpointURL: URL, identity: Identity) async throws {
        try checkReceiving() // A retired adapter cannot inherit a new generation.
        guard let target = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false),
              let scheme = target.scheme, ["ws", "wss"].contains(scheme), let host = target.host else {
            throw TransportError.InvalidURL
        }
        // This adapter owns the outgoing loop so timeout/close also closes TCP
        // channels that have not reached WebSocket onUpgrade yet. A shared global
        // loop cannot cancel one such pre-upgrade connection through WebSocketKit.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var configuration = WebSocketClient.Configuration(maxFrameSize: BridgeInboundPayloadValidator.defaultMaximumBytes)
        configuration.maxAccumulatedFrameSize = BridgeInboundPayloadValidator.defaultMaximumBytes
        configuration.maxAccumulatedFrameCount = 128
        let client = WebSocketClient(eventLoopGroupProvider: .shared(group), configuration: configuration)
        let generation = UUID(), loop = VaporBridgeTransportEventLoops.shared.next()
        let waiter = VaporBridgeSetupWaiter(on: loop)
        let accepted = receiveLock.withLock { () -> Bool in
            guard !receivesStopped else { return false }
            return withStateLock {
                guard outgoingGroup == nil, webSocket == nil, setupWaiter == nil else { return false }
                outgoingGroup = group; connectionGeneration = generation; setupWaiter = waiter
                return true
            }
        }
        guard accepted else {
            waiter.complete(.failure(TransportError.TransportNotFound))
            try? await group.shutdownGracefully()
            throw TransportError.TransportNotFound
        }
        let timeout = loop.scheduleTask(in: .seconds(10)) { waiter.complete(.failure(TransportError.TransportNotFound)) }
        defer { timeout.cancel() }
        let snapshot = VaporBridgeIdentitySnapshot(identity)
        // WebSocketKit's HTTP upgrade future may complete before onUpgrade has
        // installed our socket. Readiness is this explicit callback, not that future.
        let connection: EventLoopFuture<Void> = client.connect(scheme: scheme, host: host,
            port: target.port ?? (scheme == "wss" ? 443 : 80), path: target.percentEncodedPath, query: target.percentEncodedQuery) { [weak self] socket in
            guard let self else { socket.close(promise: nil); waiter.complete(.failure(TransportError.TransportNotFound)); return }
            let installed = self.withStateLock { () -> Bool in
                guard self.connectionGeneration == generation, self.setupWaiter === waiter else { return false }
                self.webSocket = socket; self.closeCleanupCompleted = false
                return true
            }
            guard installed else { socket.close(promise: nil); waiter.complete(.failure(TransportError.TransportNotFound)); return }
            self.setupWebSocketCallbacks(on: socket)
            waiter.complete(.success(()))
            Task { [weak self] in
                await self?.currentDelegate()?.sendCommand(command: .description, identity: snapshot.makeIdentity(), payload: nil)
            }
        }
        connection.whenFailure { waiter.complete(.failure($0)) }
        do {
            try await waiter.promise.futureResult.get()
            withStateLock { if setupWaiter === waiter { setupWaiter = nil } }
        } catch {
            await close()
            throw error
        }
    }
    
    public func sendData(_ data: Data) async throws {
        guard let webSocket = currentWebSocket(), !webSocket.isClosed else {
            await cleanupClosedWebSocketRegistration()
            throw TransportError.TransportNotFound
        }
        do {
            if CellBase.sendDataAsText {
                guard let text = String(data: data, encoding: .utf8) else {
                    throw TransportError.DataToStringError
                }
                try await webSocket.send(text)
            } else {
                try await webSocket.send([UInt8](data))
            }
        } catch {
            await currentDelegate()?.pushError(errorMessage: "bridge_send_failed", error: error)
            throw error
        }
    }

    public func close() async {
        stopReceiving()
        // Overflow, the gate and socket onClose may race. Every caller must
        // await the same physical retirement before it can release a gate slot.
        let physical = withStateLock { () -> Task<Void, Never> in
            if let physicalCloseTask { return physicalCloseTask }
            let task = Task { [self] in await closePhysicalTransport() }
            physicalCloseTask = task
            return task
        }
        await physical.value
        // Delegate cleanup is outside the physical Task: it may re-enter close
        // through the gate, and must not await its own Task.
        await cleanupClosedWebSocketRegistration()
    }

    private func closePhysicalTransport() async {
        let pendingSetup = withStateLock { () -> VaporBridgeSetupWaiter? in
            connectionGeneration = UUID()
            let pending = setupWaiter; setupWaiter = nil; return pending
        }
        pendingSetup?.complete(.failure(TransportError.TransportNotFound))
        let socket = withStateLock { () -> WebSocket? in
            let socket = webSocket; webSocket = nil; return socket
        }
        let hardClose = withStateLock { () -> (@Sendable () async -> Void)? in
            let callback = closeUnderlyingChannel; closeUnderlyingChannel = nil; return callback
        }
        // Do not await peer acknowledgement before closing the host-owned socket.
        if let socket { socket.close(code: .policyViolation, promise: nil) }
        await hardClose?()
        let group = withStateLock { () -> MultiThreadedEventLoopGroup? in
            let group = outgoingGroup; outgoingGroup = nil; return group
        }
        try? await group?.shutdownGracefully()
    }

    private func setupWebSocketCallbacks(on webSocket: WebSocket) {
        // Explicit synchronous signatures: the async overload creates an
        // unaccounted Task per frame before entering this adapter.
        webSocket.onText { [weak self] (ws: WebSocket, text: String) -> Void in
            self?.enqueueReceive(bytes: text.utf8.count) { Data(text.utf8) }
        }
        webSocket.onBinary { [weak self] (ws: WebSocket, buffer: ByteBuffer) -> Void in
            self?.enqueueReceive(bytes: buffer.readableBytes) {
                Data(buffer.readableBytesView)
            }
        }
        webSocket.onClose.whenComplete { [weak self] result in
            self?.handleWebSocketClose(result)
        }
    }

    /// Count/bytes are reserved before copying payloads or creating Tasks.
    /// Preparation is ordered, including handshake completion. Ordinary dispatch
    /// is ordered separately so a held Cell can still complete origin signing.
    private func enqueueReceive(bytes: Int, copy: () -> Data) {
        receiveLock.withLock {
            guard !receivesStopped else { return }
            guard bytes <= BridgeInboundPayloadValidator.defaultMaximumBytes,
                  queuedReceives < VaporBridgeReceiveBudget.connectionCountLimit,
                  bytes <= VaporBridgeReceiveBudget.connectionByteLimit - queuedReceiveBytes,
                  receiveBudget.acquire(bytes: bytes) else {
                stopReceivingLocked()
                scheduleReceiveCloseLocked()
                return
            }
            queuedReceives += 1; queuedReceiveBytes += bytes
            let data = copy(), previous = receiveTail
            receiveTail = Task { [self] in
                await previous?.value
                await beforeReceivePreparation?()
                do {
                    try checkReceiving()
                    let command = try prepareCommand(data)
                    if command.cmd.hasPrefix("channelAuth") {
                        try await dispatchCommand(command)
                        releaseReceive(bytes: bytes)
                        return
                    }
                    let gate = currentDelegate() as? BridgeChannelTransport
                    let control = command.command == .sign || gate?.isOriginSigningResponse(command) == true
                    receiveLock.withLock {
                        let prior = control ? nil : dispatchTail
                        let dispatch = Task { [self] in
                            defer { releaseReceive(bytes: bytes) }
                            await prior?.value
                            do {
                                try checkReceiving()
                                try await dispatchCommand(command)
                            } catch { rejectReceive(error) }
                        }
                        if !control { dispatchTail = dispatch }
                    }
                } catch {
                    releaseReceive(bytes: bytes)
                    rejectReceive(error)
                }
            }
        }
    }

    private func releaseReceive(bytes: Int) {
        receiveLock.withLock {
            queuedReceives -= 1; queuedReceiveBytes -= bytes
            receiveBudget.release(bytes: bytes)
        }
    }

    private func checkReceiving() throws {
        try receiveLock.withLock {
            guard !receivesStopped else { throw BridgeChannelAuthentication.Failure.closed }
        }
    }

    private func stopReceiving() { receiveLock.withLock { stopReceivingLocked() } }
    private func stopReceivingLocked() {
        receivesStopped = true
        // Synchronous revocation, before asynchronous physical/delegate cleanup.
        (currentDelegate() as? BridgeChannelTransport)?.session.close()
    }
    private func scheduleReceiveCloseLocked(_ error: Error? = nil) {
        guard receiveCloseTask == nil else { return }
        receiveCloseTask = Task { [self] in
            await close()
            if let error = error as? BridgeInboundPayloadError {
                await CellBase.recordSecurityEvent(.bridgePayloadRejected(
                    transportIdentifier: "vapor-websocket", error: error))
            }
        }
    }
    private func rejectReceive(_ error: Error? = nil) {
        receiveLock.withLock {
            stopReceivingLocked()
            scheduleReceiveCloseLocked(error)
        }
    }

    func handleWebSocketClose(_ result: Result<Void, Error>) {
        if case .failure = result {
            CellBase.diagnosticLog("Vapor bridge websocket closed with failure: code=transport_failed", domain: .bridge)
        }
        rejectReceive()
    }

    func cleanupClosedWebSocketRegistration() async {
        guard let delegate = markCloseCleanupStartedAndGetDelegate() else {
            return
        }
        if delegate is BridgeChannelTransport {
            await delegate.pushError(errorMessage: "bridge_transport_closed", error: TransportError.TransportNotFound)
        }
        await CellBase.defaultCellResolver?.unregisterEmitCell(uuid: delegate.uuid)
    }
    
    func extractCommand(_ incomingData: Data) async throws {
        do {
            try BridgeInboundPayloadValidator().validate(incomingData)
            try currentDelegate()?.validateInboundPayload(incomingData)
        } catch let error as BridgeInboundPayloadError {
            await CellBase.recordSecurityEvent(.bridgePayloadRejected(
                transportIdentifier: "vapor-websocket",
                error: error
            ))
            await currentDelegate()?.pushError(
                errorMessage: "Rejected invalid bridge payload",
                error: nil
            )
            throw error
        }
        let command = try JSONDecoder().decode(BridgeCommand.self, from: incomingData)
        try await dispatchCommand(command)
    }

    private func prepareCommand(_ incomingData: Data) throws -> BridgeCommand {
        try BridgeInboundPayloadValidator().validate(incomingData)
        try currentDelegate()?.validateInboundPayload(incomingData)
        return try JSONDecoder().decode(BridgeCommand.self, from: incomingData)
    }

    private func dispatchCommand(_ command: BridgeCommand) async throws {
        guard let delegate = currentDelegate() else { throw TransportError.TransportNotFound }
        command.identity?.identityVault = await identityVault(for: command.identity)
        if command.command == .response { try await delegate.consumeResponse(command: command) }
        else { try await delegate.consumeCommand(command: command) }
    }

    public func identityVault(for identity: Identity?) async -> IdentityVaultProtocol {
        if let authenticated = currentDelegate() as? BridgeChannelTransport {
            return await authenticated.identityVault(for: identity)
        }
        let bridge = currentDelegate() as? BridgeProtocol
        if let identity, bridge != nil {
            let identitySnapshot = VaporBridgeIdentitySnapshot(identity)
            if await VaporIdentityVault.shared.identityExistInVault(identity) == false {
                // Preserve visitor lookup metadata; registration grants no signing authority.
                await VaporIdentityVault.shared.addVisitingIdentity(snapshot: identitySnapshot)
            }
        }
        // Every identity resolved here came over the bridge. A known public
        // descriptor is not proof of local origin, even when its key is stored here.
        // With no bridge delegate, the proxy fails closed instead of signing locally.
        return BridgeIdentityVault(cloudBridge: bridge)
    }

    private func currentDelegate() -> BridgeDelegateProtocol? {
        withStateLock {
            delegate
        }
    }

    private func currentWebSocket() -> WebSocket? {
        withStateLock {
            webSocket
        }
    }

    private func markCloseCleanupStartedAndGetDelegate() -> BridgeDelegateProtocol? {
        withStateLock {
            guard closeCleanupCompleted == false else {
                return nil
            }
            closeCleanupCompleted = true
            return delegate
        }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer {
            stateLock.unlock()
        }
        return body()
    }
}
