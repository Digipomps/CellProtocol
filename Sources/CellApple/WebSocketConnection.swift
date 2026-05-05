// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  WebSocketConnection.swift
//  WebSockets


import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
#if canImport(Combine)
@preconcurrency import Combine
#else
@preconcurrency import OpenCombine
#endif


protocol WebSocketConnection {
    func send(text: String) throws
    func send(data: Data) throws
    func connect() throws
    func disconnect() throws
    func ping() throws

    var delegate: WebSocketConnectionDelegate? {
        get
        set
    }
}

public protocol WebSocketConnection2 {
    func send(text: String) async throws
    func send(data: Data) async throws
    func connect() async throws
    func disconnect() async throws
    func ping() async throws

    var delegate: WebSocketConnectionDelegate2? {
        get
        set
    }
}

enum WebSocketConnectionError: Error {
    case NoTask
    case NoConnection
}

protocol WebSocketConnectionDelegate: AnyObject {
    func onConnected(connection: WebSocketConnection)
    func onDisconnected(connection: WebSocketConnection, error: Error?)
    func onError(connection: WebSocketConnection, error: Error)
    func onMessage(connection: WebSocketConnection, text: String)
    func onMessage(connection: WebSocketConnection, data: Data)
}

public protocol WebSocketConnectionDelegate2: AnyObject {
    func onConnected(connection: WebSocketConnection2) async
    func onDisconnected(connection: WebSocketConnection2, error: Error?) async
    func onError(connection: WebSocketConnection2, error: Error) async
    func onMessage(connection: WebSocketConnection2, text: String) async
    func onMessage(connection: WebSocketConnection2, data: Data) async
}

final class WebSocketTaskConnection: NSObject, WebSocketConnection, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let delegateLock = NSLock()
    private weak var storedDelegate: WebSocketConnectionDelegate?
    var delegate: WebSocketConnectionDelegate? {
        get {
            delegateLock.lock()
            defer {
                delegateLock.unlock()
            }
            return storedDelegate
        }
        set {
            delegateLock.lock()
            storedDelegate = newValue
            delegateLock.unlock()
        }
    }
    var webSocketTask: URLSessionWebSocketTask!
    var urlSession: URLSession!
    let delegateQueue = OperationQueue()
    
    init(url: URL) {
        super.init()
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
        webSocketTask = urlSession.webSocketTask(with: url)
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        self.delegate?.onConnected(connection: self)
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.delegate?.onDisconnected(connection: self, error: nil)
    }
    
    func connect() throws {
        webSocketTask.resume()
        
        try listen()
    }
    
    func disconnect() throws {
        guard let webSocketTask = webSocketTask else {
            throw WebSocketConnectionError.NoTask
        }
        webSocketTask.cancel(with: .goingAway, reason: nil)
        self.webSocketTask = nil
        self.delegateQueue.cancelAllOperations()
        self.urlSession.invalidateAndCancel()
    }
    
    func listen() throws {
        guard let webSocketTask = webSocketTask else {
            throw WebSocketConnectionError.NoTask
        }
        webSocketTask.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.delegate?.onError(connection: self, error: error)
            case .success(let message):
                switch message {
                case .string(let text):
                    self.delegate?.onMessage(connection: self, text: text)
                case .data(let data):
                    self.delegate?.onMessage(connection: self, data: data)
                @unknown default:
                    fatalError()
                }
                
                try? self.listen()
            }
        }
    }
    
    func send(text: String) throws {
        guard let webSocketTask = webSocketTask else {
            throw WebSocketConnectionError.NoTask
        }
        webSocketTask.send(URLSessionWebSocketTask.Message.string(text)) { [weak self] error in
            guard let self = self else { return }
            if let error = error {                
                self.delegate?.onError(connection: self, error: error)
            }
        }
    }
    
    func send(data: Data) throws {
        guard let webSocketTask = webSocketTask else {
            throw WebSocketConnectionError.NoTask
        }
        webSocketTask.send(URLSessionWebSocketTask.Message.data(data)) { [weak self] error in
            guard let self = self else { return }
            if let error = error {                
                self.delegate?.onError(connection: self, error: error)
            }
        }
    }
    
    func ping() throws {
        guard let webSocketTask = webSocketTask else {
            throw WebSocketConnectionError.NoTask
        }
      webSocketTask.sendPing { [weak self] error in
          guard let self = self else { return }
        if let error = error {
          print("Error when sending PING \(error)")
        } else {
//            print("Web Socket connection is alive")
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self = self else { return }
                try? self.ping()
            }
        }
      }
    }
}

final class WebSocketTaskConnection2: NSObject, WebSocketConnection2, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let onConnectedPublisher = CurrentValueSubject<Bool, Never>(false)
    private let delegateLock = NSLock()
    private weak var storedDelegate: WebSocketConnectionDelegate2?
    var delegate: WebSocketConnectionDelegate2? {
        get {
            delegateLock.lock()
            defer {
                delegateLock.unlock()
            }
            return storedDelegate
        }
        set {
            delegateLock.lock()
            storedDelegate = newValue
            delegateLock.unlock()
        }
    }
    var webSocketTask: URLSessionWebSocketTask!
    var urlSession: URLSession!
    let delegateQueue = OperationQueue()
    
    public init(url: URL) {
        super.init()
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
        webSocketTask = urlSession.webSocketTask(with: url)
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task {
            onConnectedPublisher.send(true)
            await self.delegate?.onConnected(connection: self)
        }
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task {
            onConnectedPublisher.send(false)
            await self.delegate?.onDisconnected(connection: self, error: nil)
        }
    }
    
    func connect() async throws {
        webSocketTask.resume()
         
        try await  listen()

        // didOpen can arrive before we start awaiting, so keep a replayable state and wait for `true`.
        _ = try await onConnectedPublisher
            .filter { $0 }
            .getOneWithTimeout(5)
    }
    
    func disconnect() async throws {
        guard let webSocketTask = webSocketTask else {
            throw WebSocketConnectionError.NoTask
        }
        webSocketTask.cancel(with: .goingAway, reason: nil)
        self.webSocketTask = nil
        self.delegateQueue.cancelAllOperations()
        self.urlSession.invalidateAndCancel()
    }
    
    func listen() async throws {
        guard let webSocketTask = webSocketTask else {
            throw WebSocketConnectionError.NoTask
        }
        webSocketTask.receive { [weak self] result in
            guard let self = self else { return }
            Task {
                switch result {
                case .failure(let error):
                    await self.delegate?.onError(connection: self, error: error)
                case .success(let message):
                    switch message {
                    case .string(let text):
                        await self.delegate?.onMessage(connection: self, text: text)
                    case .data(let data):
                        await self.delegate?.onMessage(connection: self, data: data)
                    @unknown default:
                        fatalError()
                    }
                    
                    try? await self.listen()
                }
            }
        }
    }
    
    func send(text: String) async throws {
        guard let webSocketTask = webSocketTask else {
            throw WebSocketConnectionError.NoTask
        }
        webSocketTask.send(URLSessionWebSocketTask.Message.string(text)) { [weak self] error in
            guard let self = self else { return }
            Task {
                if let error = error {
                    await self.delegate?.onError(connection: self, error: error)
                }
            }
        }
    }
    
    func send(data: Data) async throws {
        guard let webSocketTask = webSocketTask else {
            throw WebSocketConnectionError.NoTask
        }
        webSocketTask.send(URLSessionWebSocketTask.Message.data(data)) { [weak self] error in
            guard let self = self else { return }
            Task {
                if let error = error {
                    await self.delegate?.onError(connection: self, error: error)
                }
            }
        }
    }
    
    func ping() throws {
        guard let webSocketTask = webSocketTask else {
            throw WebSocketConnectionError.NoTask
        }
      webSocketTask.sendPing { [weak self] error in
          guard let self = self else { return }
        if let error = error {
          print("Error when sending PING \(error)")
        } else {
//            print("Web Socket connection is alive")
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self = self else { return }
                try? self.ping()
            }
        }
      }
    }
}
