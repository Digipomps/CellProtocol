// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 07/12/2022.
//

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

private func bridgeLog(_ message: @autoclosure () -> String) {
    CellBase.diagnosticLog(message(), domain: .bridge)
}

public class BridgeBase: BridgeProtocol, Emit, BridgeDelegateProtocol {
    private typealias ConnectPromise = (Result<ConnectState, Error>) -> Void
    private typealias ContractPromise = (Result<AgreementState, Error>) -> Void
    private typealias SignPromise = (Result<Data, Error>) -> Void
    
    
    
    
    
    public var cellScope: CellUsageScope
    public var persistancy: Persistancy
    
    public var uuid = UUID().uuidString
    public var agreementTemplate: Agreement
    public var identityDomain: String
    
    var members: [Identity] = [Identity]()
    var experiences: [CellConfiguration]?
    var owner: Identity?
    var name: String?
    var publisherUuid: String?
    
    private var connectCancellable: AnyCancellable?
    private var feedCancellable: AnyCancellable?
    private var connectPublisher: PassthroughSubject<ConnectState, Error>?
    private var feedPublisher2 = PassthroughSubject<FlowElement, Error>()
    
    private var valueForKeyCancellables = [String : AnyCancellable]()
    private var setValueForKeyCancellables = [String : AnyCancellable]()
    private var addContractCancellables = [String : AnyCancellable]()
    
    private var keysCancellables = [String : AnyCancellable]()
    private var typeForKeyCancellables = [String : AnyCancellable]()
    
    private var connectCallbackDataPublishers = [Int: PassthroughSubject<ConnectState, Error>]()
    private var connectCallbackPromises = [Int: ConnectPromise]()
    private var connectCallbackCancellable: AnyCancellable?

    private var contractCallbackDataPublishers = [Int: PassthroughSubject<AgreementState, Error>]()
    private var contractCallbackPromises = [Int: ContractPromise]()
    private var contractCallbackCancellable: AnyCancellable?
    
    private var stateCallbackDataPublisher: PassthroughSubject<ValueType, Error>?
    private var stateCallbackCancellable: AnyCancellable?
    
    private var flowElementCallbackDataPublisher = PassthroughSubject<FlowElement, Error>()
    private var flowElementCallbackCancellable: AnyCancellable?
    
//
    private var setValueForKeyCallbackDataPublishers = [String: PassthroughSubject<SetValueState, Error>]()
    private var setValueForKeyCallbackCancellables = [String : AnyCancellable]()
    
    private var setValueForKeypathCallbackDataPublishers = [String: PassthroughSubject<SetValueResponse, Error>]()
    private var setValueForKeypathCallbackCancellables = [String : AnyCancellable]()
    
    
    private var valueForKeyCallbackDataPublishers = [String: PassthroughSubject<ValueType, Error>]()
    private var valueForKeyCallbackCancellables = [String : AnyCancellable]()
    
//    private var valueForKeypathCallbackDataPublishers = [String: PassthroughSubject<ValueType, Error>]()
//    private var valueForKeypathCallbackCancellables = [String : AnyCancellable]()
    
    
    private var subscribeFeedCallBackPublishers = [String: PassthroughSubject<ValueType, Error>]()
    
    //Publishers and cancellables for keys
    private var keysCallbackDataPublishers = [String: PassthroughSubject<ValueType, Error>]()
    private var keysCallbackCancellables = [String : AnyCancellable]()
    
    private var signCallbackPromises = [Int: SignPromise]()
    private var signCallbackDataPublisher: PassthroughSubject<Data, Error>?
    private var signCallbackCancellable: AnyCancellable?
    
    //Publisher and cancellables for getting connection statuses
    private var attachedStatusPublisher: PassthroughSubject<ConnectionStatus, Error>?
    private var attachedStatusCallbackCancellable: AnyCancellable?
    
    private var attachedStatusesPublisher: PassthroughSubject<[ConnectionStatus], Error>?
    private var attachedStatusesCallbackCancellable: AnyCancellable?
    

    private var loadPublisherCancellable: AnyCancellable?
    
    private var readyPublisher = PassthroughSubject<Bool, Error>()
    private var ready = false
//    private var readyPublisher = Just<Bool>(<#Bool#>)
    var feedActive = false
    let auditor = BridgeBaseAuditor()
    
    var feedEndpoint : URL?
    var feedProperties: FeedProperties?
    var transport: BridgeTransportProtocol?
    var emitCellAtEndpoint: Emit?
    private var inboundEmitCellCache = [String: Emit]()
    private let callbackStateLock = NSLock()
    
    
    private var descriptionFetchedPublisher = PassthroughSubject<Bool, Never>()
    private var descriptionFetchedDate: Date?
    
    public init(_ config: Config) async throws {
        bridgeLog("Bridge base init. identity.uuid: \(config.owner.uuid) identityDomain: \(config.identityDomain)")
        self.owner = config.owner
        
        if config.agreementTemplate != nil {
            agreementTemplate = config.agreementTemplate!
        } else {
            agreementTemplate = await Agreement()
        }
        feedEndpoint = URL(string: "https://localhost/")
        identityDomain = config.identityDomain
        self.transport = config.transport
        self.cellScope = .template // TODO: get from config's 
//        self.cellScope = config.cellRepresentation?.cellScope
        self.persistancy = .ephemeral
//        switch config.connection {
//        case .inbound(publisherUuid: let publisherUuid):
//            self.publisherUuid = publisherUuid
//            guard let resolver = CellBase.defaultCellResolver else {
//                throw BridgeError.resolverIsMissing
//            }
//            emitCellAtEndpoint = try await resolver.cellAtEndpoint(endpoint: "cell:///\(publisherUuid)", requester: nil) // requester == owner ???
//        case .outbound:
//            self.publisherUuid = nil
//            emitCellAtEndpoint = nil
//        }
    }
    
    public required init(owner: Identity) {
        self.owner = owner
        agreementTemplate = Agreement(owner: owner)
        identityDomain = "bridge" // Must be changed to reflect remote side 
        fatalError("Bridge Base Init owner: NOT IMPLEMENTED")
    }

    deinit {
        bridgeLog("Bridge Base deinited")
    }

    private func withCallbackStateLock<T>(_ block: () throws -> T) rethrows -> T {
        callbackStateLock.lock()
        defer { callbackStateLock.unlock() }
        return try block()
    }

    private func storeValuePublisher(
        _ publisher: PassthroughSubject<ValueType, Error>,
        for requestedKey: String
    ) {
        withCallbackStateLock {
            valueForKeyCallbackDataPublishers[requestedKey] = publisher
        }
    }

    private func takeValuePublisher(
        for requestedKey: String
    ) -> PassthroughSubject<ValueType, Error>? {
        withCallbackStateLock {
            let publisher = valueForKeyCallbackDataPublishers[requestedKey]
            valueForKeyCallbackDataPublishers[requestedKey] = nil
            valueForKeyCallbackCancellables[requestedKey] = nil
            return publisher
        }
    }

    private func clearValuePublisher(for requestedKey: String) {
        withCallbackStateLock {
            valueForKeyCallbackDataPublishers[requestedKey] = nil
            valueForKeyCallbackCancellables[requestedKey] = nil
        }
    }

    private func storeSetValueResponsePublisher(
        _ publisher: PassthroughSubject<SetValueResponse, Error>,
        for requestedKey: String
    ) {
        withCallbackStateLock {
            setValueForKeypathCallbackDataPublishers[requestedKey] = publisher
        }
    }

    private func takeSetValueResponsePublisher(
        for requestedKey: String
    ) -> PassthroughSubject<SetValueResponse, Error>? {
        withCallbackStateLock {
            let publisher = setValueForKeypathCallbackDataPublishers[requestedKey]
            setValueForKeypathCallbackDataPublishers[requestedKey] = nil
            setValueForKeypathCallbackCancellables[requestedKey] = nil
            return publisher
        }
    }

    private func clearSetValueResponsePublisher(for requestedKey: String) {
        withCallbackStateLock {
            setValueForKeypathCallbackDataPublishers[requestedKey] = nil
            setValueForKeypathCallbackCancellables[requestedKey] = nil
        }
    }

    private func storeSignPromise(
        _ promise: @escaping SignPromise,
        for commandID: Int
    ) {
        withCallbackStateLock {
            signCallbackPromises[commandID] = promise
        }
    }

    private func storeConnectPublisher(
        _ publisher: PassthroughSubject<ConnectState, Error>,
        for commandID: Int
    ) {
        withCallbackStateLock {
            connectCallbackDataPublishers[commandID] = publisher
        }
    }

    private func storeConnectPromise(
        _ promise: @escaping ConnectPromise,
        for commandID: Int
    ) {
        withCallbackStateLock {
            connectCallbackPromises[commandID] = promise
        }
    }

    private func takeConnectPublisher(
        for commandID: Int
    ) -> PassthroughSubject<ConnectState, Error>? {
        withCallbackStateLock {
            let publisher = connectCallbackDataPublishers[commandID]
            connectCallbackDataPublishers[commandID] = nil
            return publisher
        }
    }

    private func clearConnectPublisher(for commandID: Int) {
        withCallbackStateLock {
            connectCallbackDataPublishers[commandID] = nil
        }
    }

    private func takeConnectPromise(for commandID: Int) -> ConnectPromise? {
        withCallbackStateLock {
            let promise = connectCallbackPromises[commandID]
            connectCallbackPromises[commandID] = nil
            return promise
        }
    }

    private func clearConnectPromise(for commandID: Int) {
        withCallbackStateLock {
            connectCallbackPromises[commandID] = nil
        }
    }

    private func storeContractPublisher(
        _ publisher: PassthroughSubject<AgreementState, Error>,
        for commandID: Int
    ) {
        withCallbackStateLock {
            contractCallbackDataPublishers[commandID] = publisher
        }
    }

    private func storeContractPromise(
        _ promise: @escaping ContractPromise,
        for commandID: Int
    ) {
        withCallbackStateLock {
            contractCallbackPromises[commandID] = promise
        }
    }

    private func takeContractPublisher(
        for commandID: Int
    ) -> PassthroughSubject<AgreementState, Error>? {
        withCallbackStateLock {
            let publisher = contractCallbackDataPublishers[commandID]
            contractCallbackDataPublishers[commandID] = nil
            return publisher
        }
    }

    private func clearContractPublisher(for commandID: Int) {
        withCallbackStateLock {
            contractCallbackDataPublishers[commandID] = nil
        }
    }

    private func takeContractPromise(for commandID: Int) -> ContractPromise? {
        withCallbackStateLock {
            let promise = contractCallbackPromises[commandID]
            contractCallbackPromises[commandID] = nil
            return promise
        }
    }

    private func clearContractPromise(for commandID: Int) {
        withCallbackStateLock {
            contractCallbackPromises[commandID] = nil
        }
    }

    private func takeSignPromise(for commandID: Int) -> SignPromise? {
        withCallbackStateLock {
            let promise = signCallbackPromises[commandID]
            signCallbackPromises[commandID] = nil
            return promise
        }
    }

    private func takeSetValueStatePublisher(
        for requestedKey: String
    ) -> PassthroughSubject<SetValueState, Error>? {
        withCallbackStateLock {
            let publisher = setValueForKeyCallbackDataPublishers[requestedKey]
            setValueForKeyCallbackDataPublishers[requestedKey] = nil
            setValueForKeyCallbackCancellables[requestedKey] = nil
            return publisher
        }
    }
    
    public func ready() async throws {
        try await ready(timeout: 5)
    }

    public func ready(timeout: Int) async throws {
        if ready {
            return
        }

        _ = try await readyPublisher.getOneWithTimeout(timeout)
        ready = true
    }
    public func setTransport(_ transport: BridgeTransportProtocol, connection: Connection) async throws {
        self.transport = transport
        transport.setDelegate(self)
        ready = false
        readyPublisher = PassthroughSubject<Bool, Error>()
        descriptionFetchedPublisher = PassthroughSubject<Bool, Never>()
        descriptionFetchedDate = nil
        
        switch connection {
        case .inbound(publisherUuid: let publisherUuid):
            self.publisherUuid = publisherUuid
            emitCellAtEndpoint = nil
            inboundEmitCellCache = [:]
        case .outbound:
            self.publisherUuid = nil
            emitCellAtEndpoint = nil
            inboundEmitCellCache = [:]
        }
        
        
    }
    
    func validateFeedPermission(identity: Identity) -> Bool {
        // Opportunity to abort querying over the net if we already know that it will be denied
        return true
    }
    
    
    public func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, any Error> {
        if !feedActive {
            if validateFeedPermission(identity: requester) {
                flowElementCallbackCancellable = flowElementCallbackDataPublisher
                    .handleEvents(receiveCancel: {
                        bridgeLog("Cancelled feed")
                    })
                    .sink(receiveCompletion: { [weak self] completion in
                        bridgeLog("Bridge got flowElement publisher completion: \(completion)")
                        self?.flowElementCallbackCancellable = nil
                    }, receiveValue: { flowElement in
                        bridgeLog("BridgeBase got flowElement: \(flowElement)")
                        self.feedPublisher2.send(flowElement)
                    })
                try await sendCommandChecked(command: .feed, identity: requester, payload: nil)
            } else {
                throw StreamState.denied
            }
        }
        return feedPublisher2.eraseToAnyPublisher()
    }
    // Should this be moved to base?
    enum ConnectError: Error {
        case denied
        case cancelled
        case otherError
    }
    
    
    public func admit(context: ConnectContext) async -> ConnectState {
        if let identity = context.identity,
           let transport {
            let commandID = await auditor.getNewCommandId()
            let connectFuture = Future<ConnectState, Error> { [weak self] promise in
                self?.storeConnectPromise(promise, for: commandID)
            }
            do {
                try await sendCommandChecked(
                    command: .admit,
                    identity: identity,
                    payload: nil,
                    commandId: commandID
                )
            } catch {
                bridgeLog("Cloud Bridge connect setup failed with error: \(error)")
                _ = transport
                clearConnectPromise(for: commandID)
                return .notConnected
            }
            do {
                let connectState = try await connectFuture.getOneWithTimeout(5)
                clearConnectPromise(for: commandID)
                return connectState
            } catch {
                bridgeLog("Cloud Bridge connect failed with error: \(error)")
                clearConnectPromise(for: commandID)
            }
        }
        return .notConnected
    }

    
    public func connect(context: ConnectContext) -> AnyPublisher<ConnectState, Error> {
        bridgeLog("Cloud Bridge connect")
//        currentCommand = .connect
        let connectPublisher = PassthroughSubject<ConnectState, Error>()
        self.connectPublisher = connectPublisher
        
        Task {
            if let identity = context.identity,
               let connectPublisher = self.connectPublisher
            {
                let commandID = await self.auditor.getNewCommandId()
                let callbackPublisher = PassthroughSubject<ConnectState, Error>()
                self.storeConnectPublisher(callbackPublisher, for: commandID)
                self.connectCallbackCancellable = callbackPublisher
                    .handleEvents(receiveCancel: {
                        bridgeLog("Cancelled cloud bridge connect")
                        connectPublisher.send(completion: .failure(ConnectError.cancelled ))
                    })
                    .sink(receiveCompletion: {[weak self] completion in
                        bridgeLog("Connect callback publisher completed: \(completion)")
                        connectPublisher.send(completion: .finished)
                        self?.connectCallbackCancellable = nil
                    }, receiveValue: { connectState in
                        bridgeLog("Connection state: \(connectState)")
                        connectPublisher.send(connectState)
                    })
                do {
                    try await self.sendCommandChecked(
                        command: .admit,
                        identity: identity,
                        payload: nil,
                        commandId: commandID
                    )
                } catch {
                    connectPublisher.send(completion: .failure(error))
                    self.connectCallbackCancellable = nil
                    self.clearConnectPublisher(for: commandID)
                }
            }
        }
        return connectPublisher.eraseToAnyPublisher()
    }
    
    public func close(requester: Identity) {
        bridgeLog("Closing bridge base")
        transport = nil
    }
    
    public func addAgreement(_ contract: Agreement, for identity: Identity) async throws -> AgreementState {
        var contractState = AgreementState.template
        let commandID = await auditor.getNewCommandId()
        let contractFuture = Future<AgreementState, Error> { [weak self] promise in
            self?.storeContractPromise(promise, for: commandID)
        }
        do {
            try await sendCommandChecked(
                command: .agreement,
                identity: identity,
                payload: .agreementPayload(contract),
                commandId: commandID
            )
            contractState = try await contractFuture.getOneWithTimeout(5)
            clearContractPromise(for: commandID)
        } catch {
            clearContractPromise(for: commandID)
            throw error
        }
        return contractState
    }
    
    
    public func advertise(for requester: Identity) -> AnyCell {
        // TODO: check what is to be revealed for supplied Identity
        let announcedCell = AnyCell(uuid: self.uuid, name: self.name ?? "CBCSP", contractTemplate: self.agreementTemplate, owner: self.owner, experiences: self.experiences, feedEndpoint: self.feedEndpoint, feedProperties: self.feedProperties, identityDomain: self.identityDomain)
        
        return announcedCell
    }
    
    public func state(requester: Identity) async throws -> ValueType {
        var stateType: ValueType = .string("error")
        self.stateCallbackDataPublisher = PassthroughSubject<ValueType, Error>()
        
        
        if let stateCallbackDataPublisher = self.stateCallbackDataPublisher {
            stateType = try await stateCallbackDataPublisher.getOneWithTimeout(5)
        }
        
        
        
        return stateType
    }
    
    public func getOwner(requester: Identity) async throws -> Identity {
        // Chect access
        if let owner = self.owner {
            return owner
        }
        throw BridgeError.noOwner
        
        // throw BridgeError.denied on no access
    }
    
    public func getEmitterWithUUID(_ uuid: String, requester: Identity) async -> (any Emit)? {
        return nil // This is tricky...
        
        /*
         var contractState = AgreementState.template
         self.contractCallbackDataPublisher = PassthroughSubject<AgreementState, Error>()
         if let contractCallbackDataPublisher = self.contractCallbackDataPublisher {
             await sendCommand(command: .agreement, identity: identity, payload: .agreementPayload(contract))
             contractState = try await contractCallbackDataPublisher.getOneWithTimeout(5)
         }
         return contractState
         */
    }
    
    public func retrieveProxyRepresentation(for identity: Identity) async throws {
        try await ready()
        try await sendCommandChecked(command: .description, identity: identity, payload: nil)
        // wait until the command response is returned or timeout
        
        
        if try await descriptionFetchedPublisher.getOneWithTimeout() {
            //TODO: Set date for fetch? or other way to allow refetch?
            self.descriptionFetchedDate = Date()
        } else {
            throw BridgeError.noDescription
        }
    }
    
    
    public func get(keypath: String, requester: Identity) async throws -> ValueType {
        let valuePublisher = PassthroughSubject<ValueType, Error>()
        storeValuePublisher(valuePublisher, for: keypath)
        do {
            try await sendCommandChecked(command: .get, identity: requester, payload: .string(keypath))
        } catch {
            clearValuePublisher(for: keypath)
            throw error
        }
        do {
            let value = try await valuePublisher.getOneWithTimeout()
            clearValuePublisher(for: keypath)
            return value
        } catch {
            clearValuePublisher(for: keypath)
            throw error
        }
    }
    
    public func set(keypath: String, value: ValueType, requester: Identity) async throws -> ValueType? {
        let setValueStatePublisher = PassthroughSubject<SetValueResponse, Error>()
        storeSetValueResponsePublisher(setValueStatePublisher, for: keypath)
        
        let keyValue = KeyValue(key: keypath, value: value)
        
        
        do {
            try await sendCommandChecked(command: .set, identity: requester, payload: .keyValue(keyValue))
        } catch {
            clearSetValueResponsePublisher(for: keypath)
            throw error
        }
        let result: SetValueResponse
        do {
            result = try await setValueStatePublisher.getOneWithTimeout()
            clearSetValueResponsePublisher(for: keypath)
        } catch {
            clearSetValueResponsePublisher(for: keypath)
            throw error
        }
    
        let response = result.value
        
        if result.state != .ok {
            throw  SetValueError.error
        }
        
 
        // need to wait for response here
        return response
    }
    
    public func keys(requester: Identity) async throws -> [String] {
        return ["Not yet implemented (BridgeBase)"]
//        let keysPublisher = PassthroughSubject<SetValueState, Error>()
        
        
    }
    
    public func typeForKey(key: String, requester: Identity) async throws -> ValueType {
        return .string("Not yet implemented (BridgeBase)")
    }
    
    public func isMember(identity: Identity, requester: Identity) -> Bool {
        return true //TODO: do the actual method
    }
    
    public func detach(label: String, requester: Identity) {
        Task {
            await sendCommand(command: .removeConnecion, identity: requester, payload: nil)
        }
        
    }
    
    public func dropFlow(label: String, requester: Identity) {
        Task {
            await sendCommand(command: .dropFlow, identity: requester, payload: nil)
        }
    }
    
    public func dropAllFlows(requester: Identity) {
        Task {
            await sendCommand(command: .unsubscribeAll, identity: requester, payload: nil)
        }
    }
    
    public func detachAll(requester: Identity) {
        Task {
            await sendCommand(command: .disconnectAll, identity: requester, payload: nil)
        }
    }
    
    enum BridgeError: Error {
        case noTransportForScheme
        case transportUnavailable
        case resolverIsMissing
        case noDescription
        case noOwner
        case denied
        case emitterUnavailable
        case someError
    }

    private func resolvedEmitCell(for requester: Identity?) async throws -> Emit {
        if let publisherUuid {
            guard let resolver = CellBase.defaultCellResolver else {
                throw BridgeError.resolverIsMissing
            }

            let resolvingIdentity: Identity
            if let requester {
                resolvingIdentity = requester
            } else if let owner {
                resolvingIdentity = owner
            } else {
                throw BridgeError.noOwner
            }

            let cacheKey = resolvingIdentity.uuid.lowercased()
            if let cached = inboundEmitCellCache[cacheKey] {
                return cached
            }

            let resolved = try await resolver.cellAtEndpoint(
                endpoint: "cell:///\(publisherUuid)",
                requester: resolvingIdentity
            )
            inboundEmitCellCache[cacheKey] = resolved
            return resolved
        }

        if let emitCellAtEndpoint {
            return emitCellAtEndpoint
        }

        throw BridgeError.emitterUnavailable
    }

        public func sendSetValueState(for requestedKey: String, setValueState: SetValueState) {
            let publisher = takeSetValueStatePublisher(for: requestedKey)
            publisher?.send(setValueState)
            publisher?.send(completion: .finished)
        }
    
    public func sendSetValueResponse(for requestedKey: String, setValueResponse: SetValueResponse) {
        let publisher = takeSetValueResponsePublisher(for: requestedKey)
        publisher?.send(setValueResponse)
        publisher?.send(completion: .finished)
    }
    
    private func configure(from description: Data) {
        do {
            let anyCell = try JSONDecoder().decode(AnyCell.self, from: description)
            self.configure(from: anyCell)
            
        } catch  {
            bridgeLog("Decoding of AnyCell failed. source: \(String(describing: String(data: description, encoding: .utf8 )))")
        }
        
        
    }
    
    
    
    private func configure(from description: AnyCell) {
            self.agreementTemplate = description.agreementTemplate
            self.name = description.name
            self.uuid = description.uuid
            self.feedProperties = description.feedProperties
            self.identityDomain = description.identityDomain
        
        self.sendSetValueState(for: ReservedKeypath.bridgesetup.rawValue, setValueState: .ok)
         //send a message that description is fetched
        self.descriptionFetchedPublisher.send(true)
        
//        print("Configured cell with identityDomain: \(self.identityDomain)")
    }
    

    
  
    func addSetValueCancellableForKey(key: String, cancellable: AnyCancellable) {
        setValueForKeyCancellables[key] = cancellable
    }
    
    func removeSetValueCancellableForKey(_ key: String) {
        setValueForKeyCancellables[key]?.cancel()
        setValueForKeyCancellables[key] = nil
    }
    
//    public func connectCellPublisher(cellPublisher: Emit, label: String, requester: Identity) -> AnyPublisher<ConnectState, Error> {
//        
//        let payload: Object = ["label": .string(label), "publisher": .description(cellPublisher.announce(for: requester))]
//        Task {
//            await self.sendCommand(command: .connectEmitter, identity: requester, payload: .object(payload))
//        }
//        return PassthroughSubject<ConnectState, Error>().eraseToAnyPublisher()  // Not implemented
//    }
    
    public func attach(emitter: Emit, label: String, requester: Identity) async throws -> ConnectState {
        let advertisedEmitter = await emitter.advertise(for: requester)
        let payload: Object = ["label": .string(label), "publisher": .description(advertisedEmitter)]
        let commandID = await auditor.getNewCommandId()
        let callbackPublisher = PassthroughSubject<ConnectState, Error>()
        storeConnectPublisher(callbackPublisher, for: commandID)

        do {
            try await sendCommandChecked(
                command: .connectEmitter,
                identity: requester,
                payload: .object(payload),
                commandId: commandID
            )
            let connectState = try await callbackPublisher.getOneWithTimeout()
            clearConnectPublisher(for: commandID)
            return connectState
        } catch {
            clearConnectPublisher(for: commandID)
            throw error
        }
    }

    
    public func absorbFlow(label: String, requester: Identity) {
        bridgeLog("Absorb flow requested for label: \(label)")
        Task {
            await self.sendCommand(command: .absorbFlow, identity: requester, payload: .string(label))
        }
    }
    
    public func signMessageForIdentity(messageData: Data, identity: Identity) -> AnyPublisher<Data, Error> {
        Deferred { [weak self] () -> Future<Data, Error> in
            Future { promise in
                guard let self else {
                    promise(.failure(BridgeError.someError))
                    return
                }

                Task {
                    let commandID = await self.auditor.getNewCommandId()
                    let bridgeCommand = BridgeCommand(
                        cmd: Command.sign.rawValue,
                        identity: identity,
                        payload: .signData(messageData),
                        cid: commandID
                    )
                    self.storeSignPromise(promise, for: commandID)
                    await self.auditor.storeBridgeCommand(bridgeCommand, for: commandID)

                    guard let bridgeCommandJSON = try? JSONEncoder().encode(bridgeCommand),
                          let transport = self.transport else {
                        self.takeSignPromise(for: commandID)?(.failure(BridgeError.someError))
                        return
                    }

                    do {
                        try await transport.sendData(bridgeCommandJSON)
                    } catch {
                        self.takeSignPromise(for: commandID)?(.failure(error))
                    }
                }
            }
        }.eraseToAnyPublisher()
    }

    private func sendResponse(command: Command, identity: Identity, payload: ValueType?, cid: Int) async {
        let bridgeCommand = BridgeCommand(cmd: command.rawValue, identity: identity, payload: payload, cid: cid)
        
        if let cloudBridgeCommandJson = try? JSONEncoder().encode(bridgeCommand),
        let transport = transport {
            do {
                try await transport.sendData(cloudBridgeCommandJson)
            } catch {
                bridgeLog("Sending response failed with error: \(error)")
            }
        }
    }

    @discardableResult
    private func sendCommandChecked(
        command: Command,
        identity: Identity,
        payload: ValueType?,
        commandId: Int? = nil
    ) async throws -> Int {
        bridgeLog("Send command: \(command.rawValue)")
        try await ready()
        let resolvedCommandId: Int
        if let commandId {
            resolvedCommandId = commandId
        } else {
            resolvedCommandId = await auditor.getNewCommandId()
        }
        let bridgeCommand = BridgeCommand(cmd: command.rawValue, identity: identity, payload: payload, cid: resolvedCommandId)
        await auditor.storeBridgeCommand(bridgeCommand, for: resolvedCommandId)

        guard let bridgeCommandJson = try? JSONEncoder().encode(bridgeCommand) else {
            throw BridgeError.someError
        }
        guard let transport else {
            throw BridgeError.transportUnavailable
        }

        do {
            try await transport.sendData(bridgeCommandJson)
        } catch {
            await pushError(errorMessage: "Bridge transport send failed", error: error)
            throw error
        }
        return resolvedCommandId
    }
    
    public func sendCommand(command: Command, identity: Identity, payload: ValueType?) async {
        do {
            try await sendCommandChecked(command: command, identity: identity, payload: payload)
        } catch {
            bridgeLog("Sending command failed with error: \(error)")
        }
    }
    
    //Consume command is processing commands relayed over the websocket
    public func consumeCommand(command: BridgeCommand) async throws {
        bridgeLog("Consume command cmd: \(command.cmd)")
            switch command.command {
            case .ready:
                ready = true
                self.readyPublisher.send(true)
                
            case .admit:
                if let identity = command.identity {
                    let publisher = try await resolvedEmitCell(for: identity)
                    let connectState = await publisher.admit(context: ConnectContext(source: self, target: publisher, identity: identity))
                    if connectState != .notConnected {
                        let payload = ValueType.connectState(connectState)
                        let response = BridgeCommand(cmd: "response", payload: payload, cid: command.cid)
                        if let connectStateJSONData = try? JSONEncoder().encode(response),
                           let transport = transport {
                            do {
                                try await transport.sendData(connectStateJSONData)
                            } catch {
                                bridgeLog("Sending response failed with error: \(error)")
                            }
                        } else {
                            bridgeLog("Could not encode ConnectState: \(connectState)")
                        }
                    } else {
                        bridgeLog("Connect state was not connected")
                    }
                } else {
                    bridgeLog("Connect skipped due to no decoded Identity")
                }
                //                }
            case .agreement:
                if let identity = command.identity {
                    let publisher = try await resolvedEmitCell(for: identity)
//                    Task {
                        var agreement: Agreement
                        let sentPayload = command.payload
                        
                        switch sentPayload {
                        case let .agreementPayload(value):
                            agreement =  value
                        default:
                            bridgeLog("Did not get expected agreement payload: \(String(describing: command.payload))")
                            return
                        }
                        let contractState = try await publisher.addAgreement(agreement, for: identity)
                        if contractState != .template {
                            let payload = ValueType.contractState(contractState)
                            let response = BridgeCommand(cmd: "response", payload: payload, cid: command.cid)
//                            Task {
                                do {
                                    if let responseJSONData = try? JSONEncoder().encode(response),
                                       let transport = transport {
                                        try await transport.sendData(responseJSONData)
                                    }
                                } catch {
                                    bridgeLog("Consume command \(command.cmd) failed with error: \(error)")
                                }
//                            }
                        }
//                    }
                } else {
                    bridgeLog("No publisher in add contract")
                }
            case .emitter:
                bridgeLog("BridgeBase consume command emitter")
                
            case .feed:
                try await processFeedCommand(command: command)
            case .description:
                await processDescriptionCommand(command: command)

                
            case .set:
                    if let identity =  command.identity,
                       case let .keyValue(payload) = command.payload,
                       let keypathLookupPublisher = try await resolvedEmitCell(for: identity) as? Meddle,
                       let setValue = payload.value
                    {
                        var setValueState = SetValueState.ok
                        var setValueResponse = SetValueResponse(state: setValueState)
                        do {
                            if let result = try await keypathLookupPublisher.set(keypath: payload.key, value: setValue, requester: identity) {
                                setValueResponse.value = result
                            }
                            
                            
                        } catch {
                            setValueState = .error
                        }
                        
                        let response = BridgeCommand(cmd: "response", payload: .setValueResponse(setValueResponse), cid: command.cid)
                        
                            do {
                                if let responseJSONData = try? JSONEncoder().encode(response),
                                   let transport = transport {
                                    try await transport.sendData(responseJSONData)
                                }
                            } catch {
                                bridgeLog("Consume command \(command.cmd) failed with error: \(error)")
                            }
                        
                        
                    } else {
                        // Analyse and handle error...
                        bridgeLog("Set value for keypath failed")
                    }
                    
                
            case .get:
                    if
                        let identity =  command.identity,
                        case let .string(key) = command.payload,
                        let keypathLookupPublisher = try await resolvedEmitCell(for: identity) as? Meddle
                    {
                        do {
                            let valueType = try await keypathLookupPublisher.get(keypath: key, requester: identity)
                            let response = BridgeCommand(cmd: "response", payload: valueType, cid: command.cid)
                            if let responseJSONData = try? JSONEncoder().encode(response),
                               let transport = transport {
                                try await transport.sendData(responseJSONData)
                            }
                        } catch {
                            bridgeLog("Consume command \(command.cmd) failed with error: \(error)")
                        }
                    } else {
                        // Analyse and handle error...
                        bridgeLog("Value for keypath failed")
                    }
            
            case .sign:
                bridgeLog("Got sign command")
                if let sentPayload = command.payload,
                   case let .signData(value) = sentPayload,
                   let identity = command.identity
                {
                    
                    Task {
                        do {
                            if let signatureData = try await identity.sign(data: value) {
                                await self.sendResponse(command: .response, identity: identity, payload: .signature(signatureData), cid: command.cid)
                            }
                        } catch {
                            bridgeLog("Consume command signing data failed with error: \(error)")
                        }
                    }
                    
                }
                
            case .disconnectAll:
                if
                    let identity =  command.identity,
                    let client = try await resolvedEmitCell(for: identity) as? Absorb
                {
                    client.detachAll(requester: identity)
                }
                
            case .unsubscribeAll:
                if
                    let identity =  command.identity,
                    let client = try await resolvedEmitCell(for: identity) as? Absorb
                {
                    client.dropAllFlows(requester: identity)
                }
                
            case .removeConnecion:
                if
                    let identity =  command.identity,
                    let client = try await resolvedEmitCell(for: identity) as? Absorb,
                    case let .string(label) = command.payload
                {
                    client.detach(label: label, requester: identity)
                }
                
            case .dropFlow:
                if
                    let identity =  command.identity,
                    let client = try await resolvedEmitCell(for: identity) as? Absorb,
                    case let .string(label) = command.payload
                {
                    client.dropFlow(label: label, requester: identity)
                }
                
            case .attachedStatus:
                bridgeLog("AttachedStatus command")
                if
                    let identity =  command.identity,
                    let client = try await resolvedEmitCell(for: identity) as? Absorb,
                    case let .string(label) = command.payload
                {
                    _ = try await client.attachedStatus(for: label, requester: identity)
                }
                
            case .attachedStatuses:
                bridgeLog("AttachedStatuses command")
                if
                    let identity =  command.identity,
                    let client = try await resolvedEmitCell(for: identity) as? Absorb
                {
                    _ = try await client.attachedStatuses(requester: identity)
                }
                
            case .response: // Will have to rewrite this later
                try await self.consumeResponse(command: command)
            default:
                bridgeLog("Could not recognise command: \(command.command.rawValue)")
            }
    }
  
    private func processDescriptionCommand(command: BridgeCommand) async {
        let identity = command.identity
        guard let identity = identity else {
            return
        }
        let publisher: Emit
        do {
            publisher = try await resolvedEmitCell(for: identity)
        } catch {
            bridgeLog("Failed to resolve emit cell at endpoint: \(error)")
            return
        }
        do {
            let advertisedPublisher = await publisher.advertise(for: identity)
            let payload = ValueType.description(advertisedPublisher)
            let response = BridgeCommand(cmd: "response", payload: payload, cid: command.cid)
            
            if let responseJSONData = try? JSONEncoder().encode(response),
               let transport = transport {
                try await transport.sendData(responseJSONData)
            }
        } catch {
            bridgeLog("Consume command \(command.cmd) failed with error: \(error)")
        }
    }

    private func processFeedCommand(command: BridgeCommand) async throws {
        if let identity =  command.identity {
            let emitter = try await resolvedEmitCell(for: identity)
            if self.feedCancellable == nil {
                
                
                
                setupFlow(
                    commandCid: command.cid,
                    from: try await emitter.flow(requester: identity)
                ) // thats wrong - every command ceates new subsciption
            }
//            await emitter.startFeed(requester: identity)
            
            
            feedActive = true
        }
    }
    
    private func setupFlow(commandCid: Int, from publisher: AnyPublisher<FlowElement, Error>?) {
        feedCancellable = publisher?
            .handleEvents(receiveCancel: {
                bridgeLog("Cancelled flowElement publisher \(self.uuid)")
            })
        
            .sink(receiveCompletion: { [weak self] completion in
                self?.feedCancellable = nil
            }, receiveValue: { [weak self] flowElement in
                guard let self = self else {return}
                Task { [weak self] in
                    guard let self = self else { return }
                    let payload = ValueType.flowElement(flowElement)
                    let response = BridgeCommand(cmd: "response", payload: payload, cid: commandCid)
                    do {
                        if let responseJSONData = try? JSONEncoder().encode(response),
                           let transport = self.transport {
                            
                            try await transport.sendData(responseJSONData)
                            self.feedActive = true
                        }
                    } catch {
                        bridgeLog("Consume command \(commandCid) failed with error: \(error)")
                    }
                }
            })
    }
    
    
    // This is the processing of responses of commands sent over the websocket
    public func consumeResponse(command: BridgeCommand) async throws {
        bridgeLog("Consume response cmd: \(command.cmd)")

        if let commandRequest = await auditor.loadBridgeCommandForCommandId(command.cid) {
            switch commandRequest.command {
            case .description:
                if let sentPayload = command.payload {
                    
                    switch sentPayload {
                    case let .description(value):
                        bridgeLog("Got description")
                        self.configure(from: value)
                        
                        
                    default:
                        bridgeLog("Did not get expected description payload: \(String(describing: command.payload))")
                    }
                }
                
                
            case .admit, .connectEmitter:
                let promise = takeConnectPromise(for: command.cid)
                let publisher = takeConnectPublisher(for: command.cid)
                if let sentPayload = command.payload {
                    
                    switch sentPayload {
                    case let .connectState(value):
                        promise?(.success(value))
                        publisher?.send(value)
                        publisher?.send(completion: .finished)
                    default:
                        bridgeLog("Did not get expected connect payload: \(String(describing: command.payload))")
                        promise?(.failure(ValueTypeError.unexpectedValueType))
                        publisher?.send(completion: .failure(ValueTypeError.unexpectedValueType))
                    }
                } else {
                    bridgeLog("Missing payload")
                    promise?(.failure(ValueTypeError.unexpectedValueType))
                    publisher?.send(completion: .failure(ValueTypeError.unexpectedValueType))
                }
                
            case .agreement:
                let promise = takeContractPromise(for: command.cid)
                let publisher = takeContractPublisher(for: command.cid)
                if let sentPayload = command.payload {
                    switch sentPayload {
                    case let .contractState(value):
                        promise?(.success(value))
                        publisher?.send(value)
                        publisher?.send(completion: .finished)
                    default:
                        bridgeLog("Did not get expected contract payload: \(String(describing: command.payload))")
                        promise?(.failure(ValueTypeError.unexpectedValueType))
                        publisher?.send(completion: .failure(ValueTypeError.unexpectedValueType))
                    }
                } else {
                    promise?(.failure(ValueTypeError.unexpectedValueType))
                    publisher?.send(completion: .failure(ValueTypeError.unexpectedValueType))
                }
                
            case .feed:
                if let sentPayload = command.payload {
                    
                    switch sentPayload {
                    case let .flowElement(value):
                        flowElementCallbackDataPublisher.send(value)
                        
                    default:
                        bridgeLog("Did not get expected flow payload: \(String(describing: command.payload))")
                    }
                }
                
            case .emitter:
                bridgeLog("BridgeBase consume response emitter")
                
                
            case .set:
                if
                    case let .setValueResponse(setValueResponse) = command.payload,
                    case let .keyValue(keyValue) = commandRequest.payload
                {
                    self.sendSetValueResponse(for: keyValue.key, setValueResponse: setValueResponse)
                }
                
            case .get:
                if let sentPayload = command.payload, let requestedKeyValue = commandRequest.payload {
                    if case let .string(requestedKey) = requestedKeyValue {
                        let publisher = takeValuePublisher(for: requestedKey)
                        publisher?.send(sentPayload)
                        publisher?.send(completion: .finished)
//                        print("Got valueForKeypath payload. \(String(describing: try? sentPayload.jsonString())) Key: \(requestedKey)") //Do we need registery?
                    }
                }
                
            case .sign:
                bridgeLog("Got sign response")
                let promise = takeSignPromise(for: command.cid)
                switch command.payload {
                case let .signature(value):
                    promise?(.success(value))
                    
                    
                default:
                    bridgeLog("Did not get signature as payload")
                    promise?(.failure(ValueTypeError.unexpectedValueType))
                }
            
             
            case .attachedStatus:
                bridgeLog("Got attachedStatus response")
                switch command.payload {
                case let .signature(value):
                    signCallbackDataPublisher?.send(value)
                    signCallbackDataPublisher?.send(completion: .finished)
                    
                    
                default:
                    bridgeLog("Did not get signature as payload")
                    signCallbackDataPublisher?.send(completion: .failure(ValueTypeError.unexpectedValueType))
                }
               signCallbackCancellable = nil
                
            case .attachedStatuses:
                bridgeLog("Got attachedStatuses response")
                switch command.payload {
                case let .signature(value):
                    signCallbackDataPublisher?.send(value)
                    signCallbackDataPublisher?.send(completion: .finished)
                    
                    
                default:
                    bridgeLog("Did not get signature as payload")
                    signCallbackDataPublisher?.send(completion: .failure(ValueTypeError.unexpectedValueType))
                }
               signCallbackCancellable = nil
                
            default:
                bridgeLog("Response did not match commands: \(commandRequest.cmd)")
            }
            
        } else {
            bridgeLog("Could not find command request for response: \(command)")
        }
    }
   
    private func extractCommand(_ incomingData: Data) async throws {
//        Task {
            if let command = try? JSONDecoder().decode(BridgeCommand.self, from: incomingData)
               
            {
                if let transport = transport,
                    let identity = command.identity { // is there commands without identity?
                    let vault = await transport.identityVault(for: identity)
                    
                    switch command.command {
                    case .response:
                        command.identity?.identityVault = vault
                        try await consumeResponse(command: command)
                        
                    default:
                        command.identity?.identityVault = vault
                        try await self.consumeCommand(command: command)
                    }
                }
            }
//        }
    }
    
    public func pushError(errorMessage: String?, error: Error?) async {
        if let errorMessage = errorMessage {
            let feedItem = FlowElement(title: "Bridge error", content: .string(errorMessage), properties: FlowElement.Properties(type: .alert, contentType: .string))
            flowElementCallbackDataPublisher.send(feedItem)
        }
        if let error = error {
            let eventDescription: Object = ["type" : .string("closing"), "origin" : .string(uuid)]
            let feedItem = FlowElement(title: "closing", content: .object(eventDescription), properties: FlowElement.Properties(type: .event, contentType: .object))
            flowElementCallbackDataPublisher.send(feedItem)
            flowElementCallbackDataPublisher.send(completion: .failure(error))
            if let resolver = CellBase.defaultCellResolver {
                await resolver.unregisterEmitCell(uuid: uuid)
            }
        }
    }
    
    public func attachedStatus(for label: String, requester: Identity) async throws -> ConnectionStatus {
        bridgeLog("Bridge base attachedStatus for: \(label)")
        return ConnectionStatus(name: "Not implemented", connected: true, active: true)
    }
    
    public func attachedStatuses(requester: Identity) async throws -> [ConnectionStatus] {
        bridgeLog("Bridge base attachedStatuses")
        return [ConnectionStatus]()
    }
    
}
