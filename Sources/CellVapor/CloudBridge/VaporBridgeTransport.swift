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
    

    var identityDomain:String
    var delegateSource: (() async throws -> BridgeDelegateProtocol?)?
    
    public init(webSocket: WebSocket? = nil) {
        self.webSocket = webSocket
        self.identityDomain = "private" // May not be needed?
        if let webSocket {
            self.setupWebSocketCallbacks(on: webSocket)
        }
    }
    
    public static func new() -> BridgeTransportProtocol {
        return VaporBridgeTransport()
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
        websocketEndpointURL = endpointURL
        if let websocketEndpointURL = websocketEndpointURL {
//            let promise = eventLoopGroup.next().makePromise(of: String.self) // We should probably use promise and not semaphore
            let identitySnapshot = VaporBridgeIdentitySnapshot(identity)
            let _ = try await WebSocket.connect(to: websocketEndpointURL.absoluteString, on: VaporBridgeTransportEventLoops.shared) { [weak self] ws in
                    // Connected WebSocket.
                   guard let self = self else {return}
                  self.setWebSocket(ws)
                   Task { [weak self, identitySnapshot] in // Hmm - should Task be broader scoped?
                       guard let self else {
                           return
                       }
                       await self.currentDelegate()?.sendCommand(
                           command: .description,
                           identity: identitySnapshot.makeIdentity(),
                           payload: nil
                       )
                   }
                }
            
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

    private func setupWebSocketCallbacks(on webSocket: WebSocket) {
        webSocket.onText{[weak self] ws, text in
            if let incomingData = text.data(using: .utf8) {
                try? await self?.extractCommand(incomingData)
            }
        }
        webSocket.onBinary{ [weak self] ws, buf in
            if let incomingData = buf.getData(at: 0, length: buf.readableBytes) {
                try? await self?.extractCommand(incomingData)
            }
        }
        webSocket.onClose.whenComplete { [weak self] result in
            self?.handleWebSocketClose(result)
        }
    }

    func handleWebSocketClose(_ result: Result<Void, Error>) {
        if case .failure(let error) = result {
            CellBase.diagnosticLog("Vapor bridge websocket closed with failure: \(error)", domain: .bridge)
        }
        Task { [weak self] in
            await self?.cleanupClosedWebSocketRegistration()
        }
    }

    func cleanupClosedWebSocketRegistration() async {
        guard let delegate = markCloseCleanupStartedAndGetDelegate() else {
            return
        }
        await CellBase.defaultCellResolver?.unregisterEmitCell(uuid: delegate.uuid)
    }
    
    func extractCommand(_ incomingData: Data) async throws {
        do {
            try BridgeInboundPayloadValidator().validate(incomingData)
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
        let command = try? JSONDecoder().decode(BridgeCommand.self, from: incomingData)
        let delegate = currentDelegate()
        guard let command = command,
              let delegate = delegate
        else {
            return
        }
        let identity = command.identity
        let vault = await self.identityVault(for: identity)
        switch command.command {
        case .response:
            command.identity?.identityVault = vault
            try await delegate.consumeResponse(command: command)
        default:
            command.identity?.identityVault = vault
            try await delegate.consumeCommand(command: command)
        }

    }

    public func identityVault(for identity: Identity?) async -> IdentityVaultProtocol {
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
