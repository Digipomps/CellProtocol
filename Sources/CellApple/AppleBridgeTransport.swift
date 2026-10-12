// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 09/12/2022.
//

import Foundation
import CellBase

public class AppleBridgeTransport: BridgeTransportProtocol, WebSocketConnectionDelegate2, @unchecked Sendable {
    public func setDelegate(_ delegate: BridgeDelegateProtocol) {
        withStateLock {
            self.delegate = delegate
        }
    }
    
    private let stateLock = NSLock()
    private var webSocketConnection: WebSocketConnection2?
    var delegateSource: (() async throws -> BridgeDelegateProtocol?)?
    
    private var delegate: BridgeDelegateProtocol?
    private var registrationCleanupTask: Task<Void, Never>?
    private var physicalCloseTask: Task<Void, Never>?
    private let receiveLock = NSLock()
    private var receiveBudget = BridgeWebSocketReceiveBudget.shared
    private var queuedReceives = 0
    private var queuedReceiveBytes = 0
    private var receivesStopped = false
    private var receiveTail: Task<Void, Never>?
    private var dispatchTail: Task<Void, Never>?
    private var multiplexDispatchTails: [ObjectIdentifier: (id: UUID, task: Task<Void, Never>)] = [:]
    private var receiveCloseTask: Task<Void, Never>?
    // Deterministic test seams, installed before traffic; no production bypass.
    var beforeReceivePreparation: (@Sendable () async -> Void)?
    var receiveSnapshot: (count: Int, bytes: Int, stopped: Bool) {
        receiveLock.withLock { (queuedReceives, queuedReceiveBytes, receivesStopped) }
    }


    
    public init(webSocketConnection: WebSocketConnection2? = nil, delegateSource: (() async throws -> BridgeDelegateProtocol?)? = nil) {
        self.webSocketConnection = webSocketConnection
        self.delegateSource = delegateSource
        self.webSocketConnection?.delegate = self
    }
    
    convenience init(webSocketConnection: WebSocketConnection2, receiveBudget: BridgeWebSocketReceiveBudget) {
        self.init(webSocketConnection: webSocketConnection)
        self.receiveBudget = receiveBudget
    }

    deinit {
        CellBase.diagnosticLog("AppleBridgeTransport deinitialized.", domain: .bridge)
    }
    
    public static func new() -> BridgeTransportProtocol {
        return AppleBridgeTransport()
    }
    
    public func setDelegateSource(_ source: (() async throws -> BridgeDelegateProtocol?)?) {
        withStateLock {
            delegateSource = source
        }
    }
    
    public func setup(_ endpointURL: URL, identity: Identity) async throws {
        try checkReceiving()
        let websocketConn = WebSocketTaskConnection2(url: endpointURL)
        let admitted = receiveLock.withLock {
            guard !receivesStopped else { return false }
            return withStateLock {
                guard webSocketConnection == nil, physicalCloseTask == nil,
                      registrationCleanupTask == nil else { return false }
                webSocketConnection = websocketConn
                return true
            }
        }
        guard admitted else {
            try? await websocketConn.disconnect()
            throw TransportError.TransportNotFound
        }
        websocketConn.delegate = self
        do {
            try await websocketConn.connect()
            // we need that this is returned before continuing
            
            try websocketConn.ping()
        } catch {
            CellBase.diagnosticLog("Apple websocket connection failed with error: code=transport_failed", domain: .bridge)
            await currentDelegate()?.sendSetValueState(for: ReservedKeypath.bridgesetup.rawValue, setValueState: .paramErr) // Remember to set back to .error
            await currentDelegate()?.pushError(errorMessage: "Websocket connection failed with error: \(error)", error: error)
            await cleanupClosedWebSocketRegistration()
            throw error
        }
        
    }
    
    public func close() async {
        stopReceiving()
        let physical = withStateLock { () -> Task<Void, Never> in
            if let physicalCloseTask { return physicalCloseTask }
            let connection = webSocketConnection
            webSocketConnection = nil
            let task = Task<Void, Never> { _ = try? await connection?.disconnect() }
            physicalCloseTask = task
            return task
        }
        await physical.value
        await cleanupClosedWebSocketRegistration()
    }

    public func sendData(_ data: Data) async throws {
        guard let webSocketConnection = currentConnection() else {
            CellBase.diagnosticLog("No Apple websocket; bridge target is not reachable.", domain: .bridge)
            await cleanupClosedWebSocketRegistration()
            throw TransportError.TransportNotFound
        }

        if CellBase.sendDataAsText {
            guard let text = String(data: data, encoding: .utf8) else {
                throw TransportError.DataToStringError
            }
            do {
                try await webSocketConnection.send(text: text)
            } catch {
                CellBase.diagnosticLog("Apple websocket text send failed with error: code=transport_failed", domain: .bridge)
                await cleanupClosedWebSocketRegistration()
                throw error
            }
        } else {
            do {
                try await webSocketConnection.send(data: data)
            } catch {
                CellBase.diagnosticLog("Apple websocket binary send failed with error: code=transport_failed", domain: .bridge)
                await cleanupClosedWebSocketRegistration()
                throw error
            }
        }
    }
    
    // WebsocketConnection delegate callbacks
    public func onConnected(connection: WebSocketConnection2) async {
        guard isCurrentConnection(connection) else { return }
        CellBase.diagnosticLog("Apple websocket connected.", domain: .bridge)
    }
    
    public func onDisconnected(connection: WebSocketConnection2, error: Error?) async {
        guard isCurrentConnection(connection) else { return }
        stopReceiving()
        await currentDelegate()?.pushError(errorMessage: "WebSocketConnection disconnected", error: error)
        await cleanupClosedWebSocketRegistration()
    }
    
    public func onError(connection: WebSocketConnection2, error: Error) async {
        guard isCurrentConnection(connection) else { return }
        stopReceiving()
        CellBase.diagnosticLog("Apple websocket error: code=transport_failed", domain: .bridge)
        if let delegate = currentDelegate() {
            await delegate.pushError(errorMessage: "WebSocketConnection error", error: error)
        }
        await cleanupClosedWebSocketRegistration()
    }
    
    public func onMessage(connection: WebSocketConnection2, text: String) async {
        guard isCurrentConnection(connection) else { return }
        enqueueReceive(bytes: text.utf8.count) { Data(text.utf8) }
    }

    public func onMessage(connection: WebSocketConnection2, data: Data) async {
        guard isCurrentConnection(connection) else { return }
        enqueueReceive(bytes: data.count) { data }
    }

    /// Count/bytes are reserved before copying payloads or creating Tasks.
    /// Preparation is ordered, including handshake completion. Live mux channels
    /// have separate ordered dispatch lanes; logical close and origin signing
    /// can progress while a consumer is held. Every lane retains receive quota.
    private func enqueueReceive(bytes: Int, copy: () -> Data) {
        receiveLock.withLock {
            guard !receivesStopped else { return }
            guard bytes >= 0,
                  queuedReceives < BridgeWebSocketReceiveBudget.connectionCountLimit,
                  bytes <= BridgeWebSocketReceiveBudget.connectionByteLimit - queuedReceiveBytes,
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
                    let prepared = gate?.prepareMultiplexDispatch(command)
                    let control = command.command == .sign || gate?.isOriginSigningResponse(command) == true
                        || prepared?.bypassesOrdering == true
                    receiveLock.withLock {
                        let lane = prepared?.laneID, id = UUID()
                        let prior: Task<Void, Never>?
                        if control { prior = nil }
                        else if let lane { prior = multiplexDispatchTails[lane]?.task }
                        else { prior = dispatchTail }
                        let dispatch = Task { [self] in
                            defer {
                                if let lane, !control {
                                    receiveLock.withLock {
                                        if multiplexDispatchTails[lane]?.id == id { multiplexDispatchTails[lane] = nil }
                                    }
                                }
                                releaseReceive(bytes: bytes)
                            }
                            await prior?.value
                            do {
                                try checkReceiving()
                                try await dispatchCommand(command, prepared: prepared)
                            } catch { rejectReceive() }
                        }
                        if !control {
                            if let lane { multiplexDispatchTails[lane] = (id, dispatch) }
                            else { dispatchTail = dispatch }
                        }
                    }
                } catch {
                    rejectReceive()
                    // Auditing is work too. A non-cooperative event sink must
                    // retain this admission rather than escape into close cleanup.
                    if let error = error as? BridgeInboundPayloadError {
                        await currentDelegate()?.pushError(errorMessage: "Rejected invalid bridge payload", error: nil)
                        await CellBase.recordSecurityEvent(.bridgePayloadRejected(
                            transportIdentifier: "apple-websocket", error: error))
                    }
                    releaseReceive(bytes: bytes)
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
    private func scheduleReceiveCloseLocked() {
        guard receiveCloseTask == nil else { return }
        receiveCloseTask = Task { [self] in await close() }
    }
    private func rejectReceive() {
        receiveLock.withLock {
            stopReceivingLocked()
            scheduleReceiveCloseLocked()
        }
    }

    private func prepareCommand(_ incomingData: Data) throws -> BridgeCommand {
        try BridgeInboundPayloadValidator().validate(incomingData)
        try currentDelegate()?.validateInboundPayload(incomingData)
        return try JSONDecoder().decode(BridgeCommand.self, from: incomingData)
    }

    private func dispatchCommand(_ command: BridgeCommand, prepared: BridgeInboundDispatch? = nil) async throws {
        guard let delegate = currentDelegate() else { throw TransportError.TransportNotFound }
        command.identity?.identityVault = await identityVault(for: command.identity)
        if let prepared { try await prepared.consume() }
        else if command.command == .response { try await delegate.consumeResponse(command: command) }
        else { try await delegate.consumeCommand(command: command) }
    }

    // Installed before traffic and used only by deterministic test fixtures.
    func waitForPendingReceivesForTesting() async {
        let prepared = receiveLock.withLock { receiveTail }
        await prepared?.value
        let tasks = receiveLock.withLock { [dispatchTail].compactMap { $0 } + multiplexDispatchTails.values.map(\.task) }
        for task in tasks { await task.value }
    }

    public func identityVault(for identity: Identity?) async -> IdentityVaultProtocol {
        // This API resolves incoming wire descriptors, never local signing authority.
        // Even an exact public-key match must prove origin back at the peer.
        // A missing delegate yields a proxy that fails closed.
        if let gate = currentDelegate() as? BridgeChannelTransport { return await gate.identityVault(for: identity) }
        return BridgeIdentityVault(cloudBridge: currentDelegate() as? BridgeProtocol)
    }

    func cleanupClosedWebSocketRegistration() async {
        let cleanup = withStateLock { () -> (Task<Void, Never>, BridgeDelegateProtocol?) in
            if let registrationCleanupTask { return (registrationCleanupTask, nil) }
            let target = delegate
            let task = Task {
                if let target { await CellBase.defaultCellResolver?.unregisterEmitCell(uuid: target.uuid) }
            }
            registrationCleanupTask = task
            return (task, target)
        }
        await cleanup.0.value
        if let gate = cleanup.1 as? BridgeChannelTransport {
            await gate.pushError(errorMessage: "bridge_transport_closed", error: TransportError.TransportNotFound)
        }
    }

    private func isCurrentConnection(_ connection: WebSocketConnection2) -> Bool {
        withStateLock {
            guard let current = webSocketConnection else { return false }
            return (current as AnyObject) === (connection as AnyObject)
        }
    }

    private func currentConnection() -> WebSocketConnection2? {
        withStateLock {
            webSocketConnection
        }
    }

    private func currentDelegate() -> BridgeDelegateProtocol? {
        withStateLock {
            delegate
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
