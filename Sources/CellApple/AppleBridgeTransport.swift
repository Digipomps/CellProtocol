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
    private var closeCleanupCompleted = false
    private var localIdentityUUID: String?
    
    public init(webSocketConnection: WebSocketConnection2? = nil, delegateSource: (() async throws -> BridgeDelegateProtocol?)? = nil) {
        self.webSocketConnection = webSocketConnection
        self.delegateSource = delegateSource
        self.webSocketConnection?.delegate = self
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
        let wsEndpoint = endpointURL
        let websocketConn = WebSocketTaskConnection2(url: wsEndpoint)
        withStateLock {
            localIdentityUUID = identity.uuid
        }
        setWebSocketConnection(websocketConn)
        do {
            try await websocketConn.connect()
            // we need that this is returned before continuing
            
            try websocketConn.ping()
        } catch {
            CellBase.diagnosticLog("Apple websocket connection failed with error: \(error)", domain: .bridge)
            await currentDelegate()?.sendSetValueState(for: ReservedKeypath.bridgesetup.rawValue, setValueState: .paramErr) // Remember to set back to .error
            await currentDelegate()?.pushError(errorMessage: "Websocket connection failed with error: \(error)", error: error)
            await cleanupClosedWebSocketRegistration()
        }
        
    }
    
    public func sendData(_ data: Data) async throws {
        guard let webSocketConnection = currentConnection() else {
            CellBase.diagnosticLog("No Apple websocket; bridge target is not reachable.", domain: .bridge)
            await cleanupClosedWebSocketRegistration()
            return
        }

        if CellBase.sendDataAsText {
            guard let text = String(data: data, encoding: .utf8) else {
                throw TransportError.DataToStringError
            }
            do {
                try await webSocketConnection.send(text: text)
            } catch {
                CellBase.diagnosticLog("Apple websocket text send failed with error: \(error)", domain: .bridge)
                await cleanupClosedWebSocketRegistration()
                throw error
            }
        } else {
            do {
                try await webSocketConnection.send(data: data)
            } catch {
                CellBase.diagnosticLog("Apple websocket binary send failed with error: \(error)", domain: .bridge)
                await cleanupClosedWebSocketRegistration()
                throw error
            }
        }
    }
    
    // WebsocketConnection delegate callbacks
    public func onConnected(connection: WebSocketConnection2) async {
        CellBase.diagnosticLog("Apple websocket connected.", domain: .bridge)
    }
    
    public func onDisconnected(connection: WebSocketConnection2, error: Error?) async {
        await currentDelegate()?.pushError(errorMessage: "WebSocketConnection disconnected", error: error)
        await cleanupClosedWebSocketRegistration()
    }
    
    public func onError(connection: WebSocketConnection2, error: Error) async {
        CellBase.diagnosticLog("Apple websocket error: \(error)", domain: .bridge)
        if let delegate = currentDelegate() {
            await delegate.pushError(errorMessage: "WebSocketConnection error", error: error)
        }
        await cleanupClosedWebSocketRegistration()
    }
    
    public func onMessage(connection: WebSocketConnection2, text: String) async {
        if let data = text.data(using: .utf8) {
            await self.extractCommandFromData(data)
        }
    }
    
    public func onMessage(connection: WebSocketConnection2, data: Data) async {
        await self.extractCommandFromData(data)
    }
    
    private func extractCommandFromData(_ data: Data) async {
        let decoder = JSONDecoder()
        if let bridgeCommand = try? decoder.decode(BridgeCommand.self, from: data),
           let delegate = currentDelegate() {
            let currentCommand = bridgeCommand.command
            
            switch currentCommand {
            case .response:
                try? await delegate.consumeResponse(command: bridgeCommand)
            default:
                try? await delegate.consumeCommand(command: bridgeCommand)
            }
        }
    }
    
    public func identityVault(for identity: Identity?) async -> IdentityVaultProtocol {
        if let identity {
            if identity.uuid == currentLocalIdentityUUID() {
                return IdentityVault.shared
            }
            if await IdentityVault.shared.identityExistsInVault(uuid: identity.uuid) {
                return IdentityVault.shared
            }
        }
        if let bridgeProtocol = currentDelegate() as? BridgeProtocol {
            return BridgeIdentityVault(cloudBridge: bridgeProtocol)
        }
        return IdentityVault.shared
    }

    func cleanupClosedWebSocketRegistration() async {
        guard let delegate = markCloseCleanupStartedAndGetDelegate() else {
            return
        }
        await CellBase.defaultCellResolver?.unregisterEmitCell(uuid: delegate.uuid)
    }

    private func setWebSocketConnection(_ incomingConnection: WebSocketConnection2) {
        var connection = incomingConnection
        withStateLock {
            webSocketConnection = connection
            closeCleanupCompleted = false
        }
        connection.delegate = self
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

    private func currentLocalIdentityUUID() -> String? {
        withStateLock {
            localIdentityUUID
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
