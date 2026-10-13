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

public enum BridgeOperationError: Error, Equatable {
    case unsupportedOperation(String)
}

public class BridgeBase: BridgeProtocol, Emit, BridgeDelegateProtocol {
    typealias ConnectPromise = (Result<ConnectState, Error>) -> Void
    typealias ContractPromise = (Result<AgreementState, Error>) -> Void
    private typealias SignPromise = (Result<Data, Error>) -> Void
    private struct SignRequest {
        var promise: SignPromise
        var identity: Identity
        var messageData: Data
        var cleanupTask: Task<Void, Never>?
    }
    
    
    
    
    
    public var cellScope: CellUsageScope
    public var persistancy: Persistancy
    
    // WebSocket response callbacks may overlap. Retain and replace description
    // fields under one lock; locking only configure would still race readers.
    private struct DescriptionState {
        var uuid = UUID().uuidString
        var agreementTemplate: Agreement
        var identityDomain: String
        var name: String?
        var feedProperties: FeedProperties?
    }
    private let descriptionStateLock = NSLock()
    private var descriptionState: DescriptionState

    public var uuid: String {
        get { withDescriptionStateLock { descriptionState.uuid } }
        set { withDescriptionStateLock { descriptionState.uuid = newValue } }
    }
    public var agreementTemplate: Agreement {
        get { withDescriptionStateLock { descriptionState.agreementTemplate } }
        set { withDescriptionStateLock { descriptionState.agreementTemplate = newValue } }
    }
    public var identityDomain: String {
        get { withDescriptionStateLock { descriptionState.identityDomain } }
        set { withDescriptionStateLock { descriptionState.identityDomain = newValue } }
    }
    
    var members: [Identity] = [Identity]()
    var experiences: [CellConfiguration]?
    var owner: Identity?
    var name: String? {
        get { withDescriptionStateLock { descriptionState.name } }
        set { withDescriptionStateLock { descriptionState.name = newValue } }
    }
    var publisherUuid: String?
    
    private var connectCancellable: AnyCancellable?
    private var feedCancellable: AnyCancellable?
    private var outboundFeedStartTask: Task<Void, Error>?
    private var outboundFeedStartID: UUID?
    private var outboundFeedCommandID: Int?
    private var outboundFeedRequester: Identity?
    private var inboundFeedCommandID: Int?
    private var inboundFeedRequester: Identity?
    private var localFeedSubscriberCount = 0
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
    
    private var signCallbackRequests = [Int: SignRequest]()
    private var signCallbackDataPublisher: PassthroughSubject<Data, Error>?
    private var signCallbackCancellable: AnyCancellable?
    
    //Publisher and cancellables for getting connection statuses
    private var attachedStatusPublisher: PassthroughSubject<ConnectionStatus, Error>?
    private var attachedStatusCallbackCancellable: AnyCancellable?
    
    private var attachedStatusesPublisher: PassthroughSubject<[ConnectionStatus], Error>?
    private var attachedStatusesCallbackCancellable: AnyCancellable?
    

    private var loadPublisherCancellable: AnyCancellable?
    
    private var readyPublisher = CurrentValueSubject<Bool, Error>(false)
    private var ready: Bool { withCallbackStateLock { readyPublisher.value } }
    private var valueCommandIDs: [String: Int] = [:]
    private var setCommandIDs: [String: Int] = [:]
    private var descriptionPromises: [Int: (Result<Bool, Error>) -> Void] = [:]
    var signRequestTimeoutNanoseconds: UInt64 = 30_000_000_000
//    private var readyPublisher = Just<Bool>(<#Bool#>)
    var feedActive = false
    let auditor = BridgeBaseAuditor()
    
    var feedEndpoint : URL?
    var feedProperties: FeedProperties? {
        get { withDescriptionStateLock { descriptionState.feedProperties } }
        set { withDescriptionStateLock { descriptionState.feedProperties = newValue } }
    }
    var transport: BridgeTransportProtocol?
    var emitCellAtEndpoint: Emit?
    private var inboundEmitCellCache = [String: Emit]()
    private let inboundCacheLock = NSLock()
    private var inboundCacheBytes = 0
    private var inboundCacheGeneration: UInt64 = 0
    private var inboundCacheClosed = false
    private let inboundCacheMaximumCount = 128
    private let inboundCacheMaximumBytes = 64 * 1024
    // D237 observation seam: installed only by tests before concurrent use.
    var inboundCacheAccessObserver: (() -> Void)?
    var inboundResolutionObserver: (() async -> Void)?
    private func withInboundCacheState<T>(_ body: () throws -> T) rethrows -> T {
        inboundCacheLock.lock()
        defer { inboundCacheLock.unlock() }
        inboundCacheAccessObserver?()
        return try body()
    }
    var inboundCacheSnapshot: (count: Int, bytes: Int) {
        withInboundCacheState { (inboundEmitCellCache.count, inboundEmitCellCache.keys.reduce(0) { $0 + $1.utf8.count }) }
    }
    private var inboundPublisherLookupIdentity: Identity?
    private let callbackStateLock = NSLock()
    private let retirementWork = BridgeRetirementWork()
    private var retired = false
    private var retirementFinished = false
    public var isFullyRetired: Bool { withCallbackStateLock { retirementFinished } }
    private var transportConfigured = false
    private var installingTransport = false
    private var pendingTransport: BridgeTransportProtocol?
    private let installationWork = BridgeOwnedTasks(maximumTasks: 1)
    public var isRetired: Bool { withCallbackStateLock { retired } }
    private var retirementTask: Task<Void, Never>?
    private var physicalCloseTask: Task<Void, Never>?
    private func closePhysicalTransport() -> Task<Void, Never> {
        withCallbackStateLock {
            if let physicalCloseTask { return physicalCloseTask }
            let owned = transport
            let task = Task<Void, Never> { await owned?.close() }
            physicalCloseTask = task
            return task
        }
    }
    private var retiringFeedStartTask: Task<Void, Error>?
    private var feedInstallation: UUID?

    private let identityProofAuthorization: BridgeIdentityProofAuthorization
    
    
    private var descriptionFetchedPublisher = PassthroughSubject<Bool, Never>()
    private var descriptionFetchedDate: Date?
    
    public init(_ config: Config) async throws {
        identityProofAuthorization = BridgeIdentityProofAuthorization(owner: config.owner, scopes: config.identityProofScopes)
        bridgeLog("Bridge base init. identity.uuid: \(config.owner.uuid) identityDomain: \(config.identityDomain)")
        self.owner = config.owner
        
        let initialAgreement: Agreement
        if let configuredAgreement = config.agreementTemplate {
            initialAgreement = configuredAgreement
        } else {
            initialAgreement = await Agreement()
        }
        descriptionState = DescriptionState(
            agreementTemplate: initialAgreement,
            identityDomain: config.identityDomain
        )
        feedEndpoint = URL(string: "https://localhost/")
        self.transport = config.transport
        self.inboundPublisherLookupIdentity = config.inboundPublisherLookupIdentity
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
        identityProofAuthorization = BridgeIdentityProofAuthorization(owner: owner)
        self.owner = owner
        descriptionState = DescriptionState(
            agreementTemplate: Agreement(owner: owner),
            identityDomain: "bridge" // Replaced when the remote description arrives.
        )
        cellScope = .template
        persistancy = .ephemeral
    }

    deinit {
        bridgeLog("Bridge Base deinited")
    }

    private func withCallbackStateLock<T>(_ block: () throws -> T) rethrows -> T {
        callbackStateLock.lock()
        defer { callbackStateLock.unlock() }
        return try block()
    }

    // Snapshot of retained callback records, computed under the same mutation lock.
    private var callbackRegistryUsage: (count: Int, bytes: Int) {
        let count = valueForKeyCallbackDataPublishers.count + setValueForKeypathCallbackDataPublishers.count
            + connectCallbackDataPublishers.count + connectCallbackPromises.count
            + contractCallbackDataPublishers.count + contractCallbackPromises.count + signCallbackRequests.count + descriptionPromises.count
        let bytes = valueForKeyCallbackDataPublishers.keys.reduce(0) { $0 + $1.utf8.count }
            + setValueForKeypathCallbackDataPublishers.keys.reduce(0) { $0 + $1.utf8.count }
            + signCallbackRequests.values.reduce(0) { $0 + $1.messageData.count }
        return (count, bytes)
    }
    private func canStoreCallback(bytes: Int) -> Bool {
        let usage = callbackRegistryUsage
        return !retired && usage.count < 128 && !installingTransport && bytes >= 0 && bytes <= 64 * 1024 - usage.bytes
    }
    var callbackRegistrySnapshot: (count: Int, bytes: Int) {
        withCallbackStateLock { callbackRegistryUsage }
    }

    private func withDescriptionStateLock<T>(_ block: () throws -> T) rethrows -> T {
        descriptionStateLock.lock()
        defer { descriptionStateLock.unlock() }
        return try block()
    }

    @discardableResult
    func storeValuePublisher(
        _ publisher: PassthroughSubject<ValueType, Error>,
        for requestedKey: String, commandID: Int? = nil
    ) -> Bool {
        withCallbackStateLock {
            guard valueForKeyCallbackDataPublishers[requestedKey] == nil, canStoreCallback(bytes: requestedKey.utf8.count) else { return false }
            valueForKeyCallbackDataPublishers[requestedKey] = publisher
            valueCommandIDs[requestedKey] = commandID
            return true
        }
    }

    private func takeValuePublisher(
        for requestedKey: String
    ) -> PassthroughSubject<ValueType, Error>? {
        withCallbackStateLock {
            let publisher = valueForKeyCallbackDataPublishers[requestedKey]
            valueForKeyCallbackDataPublishers[requestedKey] = nil
            valueCommandIDs[requestedKey] = nil
            valueForKeyCallbackCancellables[requestedKey] = nil
            return publisher
        }
    }

    func clearValuePublisher(for requestedKey: String, expected: PassthroughSubject<ValueType, Error>) {
        withCallbackStateLock {
            guard valueForKeyCallbackDataPublishers[requestedKey] === expected else { return }
            valueForKeyCallbackDataPublishers[requestedKey] = nil
            valueCommandIDs[requestedKey] = nil
            valueForKeyCallbackCancellables[requestedKey] = nil
        }
    }

    @discardableResult
    func storeSetValueResponsePublisher(
        _ publisher: PassthroughSubject<SetValueResponse, Error>,
        for requestedKey: String, commandID: Int? = nil
    ) -> Bool {
        withCallbackStateLock {
            guard setValueForKeypathCallbackDataPublishers[requestedKey] == nil, canStoreCallback(bytes: requestedKey.utf8.count) else { return false }
            setValueForKeypathCallbackDataPublishers[requestedKey] = publisher
            setCommandIDs[requestedKey] = commandID
            return true
        }
    }

    private func takeSetValueResponsePublisher(
        for requestedKey: String
    ) -> PassthroughSubject<SetValueResponse, Error>? {
        withCallbackStateLock {
            let publisher = setValueForKeypathCallbackDataPublishers[requestedKey]
            setValueForKeypathCallbackDataPublishers[requestedKey] = nil
            setCommandIDs[requestedKey] = nil
            setValueForKeypathCallbackCancellables[requestedKey] = nil
            return publisher
        }
    }

    func clearSetValueResponsePublisher(for requestedKey: String, expected: PassthroughSubject<SetValueResponse, Error>) {
        withCallbackStateLock {
            guard setValueForKeypathCallbackDataPublishers[requestedKey] === expected else { return }
            setValueForKeypathCallbackDataPublishers[requestedKey] = nil
            setCommandIDs[requestedKey] = nil
            setValueForKeypathCallbackCancellables[requestedKey] = nil
        }
    }

    @discardableResult
    private func storeSignRequest(
        _ promise: @escaping SignPromise,
        identity: Identity,
        messageData: Data,
        for commandID: Int
    ) -> Bool {
        let timeoutNanoseconds = signRequestTimeoutNanoseconds
        let cleanupTask = retirementWork.submit { [weak self] in
            guard timeoutNanoseconds > 0 else { return }
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            guard let expiredRequest = self.takeSignRequest(for: commandID) else { return }
            await self.auditor.removeBridgeCommand(for: commandID)
            expiredRequest.promise(.failure(BridgeError.timeout))
        }
        let admitted = withCallbackStateLock { () -> Bool in
            guard !retired, cleanupTask != nil, canStoreCallback(bytes: messageData.count) else { return false }
            signCallbackRequests[commandID] = SignRequest(promise: promise, identity: identity,
                messageData: messageData, cleanupTask: cleanupTask)
            return true
        }
        if !admitted { cleanupTask?.cancel(); promise(.failure(BridgeError.transportUnavailable)) }
        return admitted

    }

    @discardableResult
    func storeConnectPublisher(
        _ publisher: PassthroughSubject<ConnectState, Error>,
        for commandID: Int
    ) -> Bool {
        withCallbackStateLock {
            guard connectCallbackDataPublishers[commandID] == nil, canStoreCallback(bytes: 0) else { return false }
            connectCallbackDataPublishers[commandID] = publisher
            return true
        }
    }

    @discardableResult
    func storeConnectPromise(
        _ promise: @escaping ConnectPromise,
        for commandID: Int
    ) -> Bool {
        withCallbackStateLock {
            guard connectCallbackPromises[commandID] == nil, canStoreCallback(bytes: 0) else { return false }
            connectCallbackPromises[commandID] = promise
            return true
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

    @discardableResult
    func storeContractPublisher(
        _ publisher: PassthroughSubject<AgreementState, Error>,
        for commandID: Int
    ) -> Bool {
        withCallbackStateLock {
            guard contractCallbackDataPublishers[commandID] == nil, canStoreCallback(bytes: 0) else { return false }
            contractCallbackDataPublishers[commandID] = publisher
            return true
        }
    }

    @discardableResult
    func storeContractPromise(
        _ promise: @escaping ContractPromise,
        for commandID: Int
    ) -> Bool {
        withCallbackStateLock {
            guard contractCallbackPromises[commandID] == nil, canStoreCallback(bytes: 0) else { return false }
            contractCallbackPromises[commandID] = promise
            return true
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

    private func takeSignRequest(for commandID: Int) -> SignRequest? {
        withCallbackStateLock {
            let request = signCallbackRequests[commandID]
            signCallbackRequests[commandID] = nil
            request?.cleanupTask?.cancel()
            return request
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

    var beforeReadySubscription: (() async -> Void)?
    public func ready(timeout: Int) async throws {
        let publisher = try withCallbackStateLock { () throws -> CurrentValueSubject<Bool, Error> in
            guard !retired else { throw BridgeError.transportUnavailable }
            return readyPublisher
        }
        await beforeReadySubscription?()
        _ = try await publisher.filter { $0 }.getOneWithTimeout(timeout)
    }
    var beforeTransportInstallation: (@Sendable () async -> Void)?
    public func setTransport(_ proposed: BridgeTransportProtocol, connection: Connection) async throws {
        var closeRejected = false
        let task = withCallbackStateLock { () -> Task<Void, Error>? in
            let alreadyOwned = (transport as AnyObject?) === (proposed as AnyObject)
                || (pendingTransport as AnyObject?) === (proposed as AnyObject)
            guard !retired, !transportConfigured, !installingTransport,
                  callbackRegistryUsage.count == 0,
                  transport == nil || (transport as AnyObject?) === (proposed as AnyObject) else {
                closeRejected = !alreadyOwned
                return nil
            }
            // Publish ownership before the task can suspend or a duplicate arrive.
            installingTransport = true
            pendingTransport = proposed
            guard let task = installationWork.submit({ try await self.installTransport(proposed, connection: connection) }) else {
                installingTransport = false; pendingTransport = nil
                closeRejected = !alreadyOwned
                return nil
            }
            return task
        }
        guard let task else {
            if closeRejected { await proposed.close() }
            throw BridgeError.transportUnavailable
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func installTransport(_ proposed: BridgeTransportProtocol, connection: Connection) async throws {
        defer { withCallbackStateLock { installingTransport = false; pendingTransport = nil } }
        await beforeTransportInstallation?()
        let installed = withCallbackStateLock { () -> Bool in
            guard !retired, !Task.isCancelled else { return false }
            transport = proposed
            transportConfigured = true
            readyPublisher = CurrentValueSubject<Bool, Error>(false)
            return true
        }
        guard installed else {
            let ownedByFinalizer = withCallbackStateLock { (transport as AnyObject?) === (proposed as AnyObject) }
            if !ownedByFinalizer { await proposed.close() }
            throw BridgeError.transportUnavailable
        }
        proposed.setDelegate(self)
        identityProofAuthorization.reset()
        withDescriptionStateLock { descriptionFetchedDate = nil }
        try withInboundCacheState {
            guard !inboundCacheClosed else { throw BridgeError.transportUnavailable }
            inboundCacheGeneration &+= 1
            inboundEmitCellCache.removeAll()
            inboundCacheBytes = 0
            switch connection {
            case .inbound(publisherUuid: let publisherUuid): self.publisherUuid = publisherUuid
            case .outbound: self.publisherUuid = nil
            }
            emitCellAtEndpoint = nil
        }
    }
    
    func validateFeedPermission(identity: Identity) -> Bool {
        // Opportunity to abort querying over the net if we already know that it will be denied
        return true
    }
    
    
    public func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, any Error> {
        guard validateFeedPermission(identity: requester) else {
            throw StreamState.denied
        }
        guard !isRetired else { throw BridgeError.transportUnavailable }
        let source = feedPublisher2
            .handleEvents(
                receiveSubscription: { [weak self] _ in
                    self?.retainLocalFeedSubscriber()
                },
                receiveCompletion: { [weak self] _ in
                    self?.releaseLocalFeedSubscriber()
                },
                receiveCancel: { [weak self] in
                    self?.releaseLocalFeedSubscriber()
                }
            )
            .eraseToAnyPublisher()
        return BridgeFeedSubscriptionPublisher(source: source) { [weak self] in
            guard let self else { return }
            if self.retirementWork.submit({ [weak self] in
                guard let self else { return }
                do { try await self.ensureOutboundFeed(requester: requester) }
                catch {
                    if !self.isRetired { self.feedPublisher2.send(completion: .failure(error)) }
                }
            }) == nil { self.beginRetirement() }
        }.eraseToAnyPublisher()
    }

    private func ensureOutboundFeed(requester: Identity) async throws {
        let pending = try withCallbackStateLock { () throws -> (UUID, Task<Void, Error>) in
            guard !retired, localFeedSubscriberCount > 0 else { throw BridgeError.transportUnavailable }
            if let task = outboundFeedStartTask, let id = outboundFeedStartID { return (id, task) }
            let id = UUID()
            outboundFeedStartID = id
            let task = Task { [weak self] in
                guard let self else { throw BridgeError.transportUnavailable }
                try await self.startOutboundFeed(requester: requester, startID: id)
            }
            outboundFeedStartTask = task
            return (id, task)
        }
        do { try await pending.1.value }
        catch {
            withCallbackStateLock {
                guard outboundFeedStartID == pending.0 else { return }
                outboundFeedStartID = nil; outboundFeedStartTask = nil
                outboundFeedCommandID = nil; outboundFeedRequester = nil; feedActive = false
            }
            throw error
        }
    }

    private func startOutboundFeed(requester: Identity, startID: UUID) async throws {
        let commandID = await auditor.getNewCommandId()
        let subscription = flowElementCallbackDataPublisher.sink(receiveCompletion: { [weak self] _ in
            self?.markOutboundFeedInactive(commandID: commandID)
        }, receiveValue: { [weak self] element in self?.feedPublisher2.send(element) })
        do {
            try withCallbackStateLock {
                guard !retired, outboundFeedStartID == startID, localFeedSubscriberCount > 0 else { throw BridgeError.transportUnavailable }
                flowElementCallbackCancellable = subscription
                outboundFeedCommandID = commandID; outboundFeedRequester = requester
            }
            try await sendCommandChecked(command: .feed, identity: requester, payload: nil, commandId: commandID)
            try withCallbackStateLock {
                guard !retired, outboundFeedStartID == startID else { throw BridgeError.transportUnavailable }
                feedActive = true
            }
        } catch {
            subscription.cancel()
            withCallbackStateLock {
                if outboundFeedCommandID == commandID { flowElementCallbackCancellable = nil }
            }
            await finishOperation(commandID)
            throw error
        }
    }

    private func markOutboundFeedInactive(commandID: Int) {
        identityProofAuthorization.complete(commandID)
        withCallbackStateLock {
            guard outboundFeedCommandID == commandID else { return }
            outboundFeedStartID = nil
            outboundFeedStartTask = nil
            outboundFeedCommandID = nil
            outboundFeedRequester = nil
            feedActive = false
        }
        retirementWork.submit { [weak self] in
            await self?.auditor.removeBridgeCommand(for: commandID)
        }
    }

    private func retainLocalFeedSubscriber() {
        withCallbackStateLock {
            localFeedSubscriberCount += 1
        }
    }

    private func releaseLocalFeedSubscriber() {
        let feedToStop = withCallbackStateLock { () -> (Int, Identity)? in
            guard localFeedSubscriberCount > 0 else { return nil }
            localFeedSubscriberCount -= 1
            guard localFeedSubscriberCount == 0 else { return nil }
            outboundFeedStartTask?.cancel()
            outboundFeedStartTask = nil; outboundFeedStartID = nil
            guard let commandID = outboundFeedCommandID,
                  let requester = outboundFeedRequester else {
                return nil
            }
            outboundFeedStartTask = nil
            outboundFeedCommandID = nil
            outboundFeedRequester = nil
            feedActive = false
            return (commandID, requester)
        }
        guard let feedToStop else { return }
        identityProofAuthorization.complete(feedToStop.0)

        flowElementCallbackCancellable?.cancel()
        flowElementCallbackCancellable = nil
        retirementWork.submit { [weak self] in
            await self?.sendStopFeed(commandID: feedToStop.0, requester: feedToStop.1)
        }
    }

    private func sendStopFeed(commandID: Int, requester: Identity) async {
        defer {
            retirementWork.submit { [weak self] in
                await self?.auditor.removeBridgeCommand(for: commandID)
            }
        }
        let command = BridgeCommand(
            cmd: Command.stopFeed.rawValue,
            identity: requester,
            payload: .integer(commandID),
            cid: commandID
        )
        guard let data = try? JSONEncoder().encode(command), let transport else {
            return
        }
        do {
            try await transport.sendData(data)
        } catch {
            bridgeLog("Stopping remote feed failed with transport error: \(error)")
        }
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
            var registered = false
            let connectFuture = Future<ConnectState, Error> { promise in
                registered = self.storeConnectPromise(promise, for: commandID)
            }
            guard registered else { return .notConnected }
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
                await finishOperation(commandID)
                return .notConnected
            }
            do {
                let connectState = try await connectFuture.getOneWithTimeout(5)
                clearConnectPromise(for: commandID)
                await finishOperation(commandID)
                return connectState
            } catch {
                bridgeLog("Cloud Bridge connect failed with error: \(error)")
                clearConnectPromise(for: commandID)
                await finishOperation(commandID)
            }
        }
        return .notConnected
    }

    
    public func connect(context: ConnectContext) -> AnyPublisher<ConnectState, Error> {
        // Preserve eager, one-request-per-call behaviour and replay the result
        // to late subscribers. The existing CID-routed promise is failed by
        // retirement; refused admission must also complete the publisher.
        Future<ConnectState, Error> { [weak self] promise in
            guard let self else { promise(.failure(BridgeError.transportUnavailable)); return }
            let task = self.retirementWork.submit { [weak self] in
                guard let self else { promise(.failure(BridgeError.transportUnavailable)); return }
                let state = await self.admit(context: context)
                promise(.success(state))
            }
            guard task != nil else { promise(.failure(BridgeError.transportUnavailable)); return }
        }.eraseToAnyPublisher()
    }

    /// Terminal, owner-driven EOF cleanup. This does not change requester
    /// authorization or the wire protocol and cannot reopen this bridge object.
    public func requestRetirement() {
        withInboundCacheState {
            inboundCacheClosed = true
            inboundCacheGeneration &+= 1
            inboundEmitCellCache.removeAll()
            inboundCacheBytes = 0
        }
        installationWork.requestStop()
        retirementWork.requestStop()
        let cleanup = withCallbackStateLock { () -> (AnyCancellable?, AnyCancellable?, [SignRequest], [ConnectPromise], [ContractPromise]) in
            retired = true
            let feed = feedCancellable; feedCancellable = nil
            let outbound = flowElementCallbackCancellable; flowElementCallbackCancellable = nil
            feedInstallation = nil
            inboundFeedCommandID = nil; inboundFeedRequester = nil
            outboundFeedCommandID = nil; outboundFeedRequester = nil
            feedActive = false; localFeedSubscriberCount = 0
            if let task = outboundFeedStartTask { retiringFeedStartTask = task }
            outboundFeedStartTask = nil
            let signs = Array(signCallbackRequests.values); signCallbackRequests.removeAll()
            let connects = Array(connectCallbackPromises.values); connectCallbackPromises.removeAll()
            let contracts = Array(contractCallbackPromises.values); contractCallbackPromises.removeAll()
            return (feed, outbound, signs, connects, contracts)
        }
        let publishers = withCallbackStateLock { () -> ([PassthroughSubject<ValueType, Error>], [PassthroughSubject<SetValueResponse, Error>], [PassthroughSubject<ConnectState, Error>], [PassthroughSubject<AgreementState, Error>]) in
            let values = Array(valueForKeyCallbackDataPublishers.values)
            let sets = Array(setValueForKeypathCallbackDataPublishers.values)
            let connects = Array(connectCallbackDataPublishers.values)
            let contracts = Array(contractCallbackDataPublishers.values)
            valueForKeyCallbackDataPublishers.removeAll()
            valueCommandIDs.removeAll()
            setValueForKeypathCallbackDataPublishers.removeAll()
            setCommandIDs.removeAll()
            connectCallbackDataPublishers.removeAll()
            contractCallbackDataPublishers.removeAll()
            return (values, sets, connects, contracts)
        }
        publishers.0.forEach { $0.send(completion: .failure(BridgeError.transportUnavailable)) }
        publishers.1.forEach { $0.send(completion: .failure(BridgeError.transportUnavailable)) }
        publishers.2.forEach { $0.send(completion: .failure(BridgeError.transportUnavailable)) }
        publishers.3.forEach { $0.send(completion: .failure(BridgeError.transportUnavailable)) }
        let descriptions = withCallbackStateLock {
            let all = Array(descriptionPromises.values); descriptionPromises.removeAll(); return all
        }
        descriptions.forEach { $0(.failure(BridgeError.transportUnavailable)) }
        cleanup.0?.cancel(); cleanup.1?.cancel()
        withCallbackStateLock { retiringFeedStartTask }?.cancel()
        cleanup.2.forEach { $0.cleanupTask?.cancel(); $0.promise(.failure(BridgeError.transportUnavailable)) }
        cleanup.3.forEach { $0(.failure(BridgeError.transportUnavailable)) }
        cleanup.4.forEach { $0(.failure(BridgeError.transportUnavailable)) }
        feedPublisher2.send(completion: .failure(BridgeError.transportUnavailable))
        readyPublisher.send(completion: .failure(BridgeError.transportUnavailable))
        identityProofAuthorization.reset()
    }

    private func retirementFinalizer() -> Task<Void, Never> {
        requestRetirement()
        return withCallbackStateLock {
            if let retirementTask { return retirementTask }
            let task = Task { [self] in
                await closePhysicalTransport().value
                await installationWork.finishStop()
                await retirementWork.finishStop()
                let feedTask = withCallbackStateLock { retiringFeedStartTask }
                _ = try? await feedTask?.value
                await auditor.retire()
                withCallbackStateLock { retiringFeedStartTask = nil; transport = nil }
                withInboundCacheState { emitCellAtEndpoint = nil; inboundPublisherLookupIdentity = nil }
                withCallbackStateLock { retirementFinished = true }
            }
            retirementTask = task
            return task
        }
    }
    /// External join only. An owned frame/send must request close and return.
    public func finishRetirement() async { await retirementFinalizer().value }
    /// Request complete cleanup from owned work without joining that work itself.
    public func beginRetirement() { _ = retirementFinalizer() }
    public func close(requester: Identity) { _ = retirementFinalizer() }

    public func addAgreement(_ contract: Agreement, for identity: Identity) async throws -> AgreementState {
        var contractState = AgreementState.template
        let commandID = await auditor.getNewCommandId()
        var registered = false
        let contractFuture = Future<AgreementState, Error> { promise in
            registered = self.storeContractPromise(promise, for: commandID)
        }
        guard registered else { throw BridgeError.transportUnavailable }
        do {
            try await sendCommandChecked(
                command: .agreement,
                identity: identity,
                payload: .agreementPayload(contract),
                commandId: commandID
            )
            contractState = try await contractFuture.getOneWithTimeout(5)
            clearContractPromise(for: commandID)
            await finishOperation(commandID)
        } catch {
            clearContractPromise(for: commandID)
            await finishOperation(commandID)
            throw error
        }
        return contractState
    }
    
    
    public func advertise(for requester: Identity) async throws -> AnyCell {
        _ = requester
        let description = withDescriptionStateLock { descriptionState }
        let publicOwner = self.owner?.publicIdentitySnapshot()
        let publicAgreement = try description.agreementTemplate.publicDescriptorSnapshot()
        return AnyCell(uuid: description.uuid, name: description.name ?? "CBCSP", contractTemplate: publicAgreement, owner: publicOwner, experiences: self.experiences, feedEndpoint: self.feedEndpoint, feedProperties: description.feedProperties, identityDomain: description.identityDomain)
    }
    
    public func state(requester: Identity) async throws -> ValueType {
        _ = requester
        throw BridgeOperationError.unsupportedOperation("state")
    }
    
    public func getOwner(requester: Identity) async throws -> Identity {
        _ = requester
        if let owner = self.owner {
            return owner.publicIdentitySnapshot()
        }
        throw BridgeError.noOwner
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
    
    // Subscribe synchronously before send can suspend; Future retains the one
    // result even if a transport responds before send returns.
    private func retainedResult<T>(_ source: PassthroughSubject<T, Error>) -> (Future<T, Error>, AnyCancellable) {
        var subscription: AnyCancellable!
        let future = Future<T, Error> { promise in
            subscription = source.first().sink(receiveCompletion: { completion in
                if case .failure(let error) = completion { promise(.failure(error)) }
                else { promise(.failure(BridgeError.transportUnavailable)) }
            }, receiveValue: { promise(.success($0)) })
        }
        return (future, subscription)
    }

    private func finishOperation(_ commandID: Int) async {
        identityProofAuthorization.complete(commandID)
        await auditor.removeBridgeCommand(for: commandID)
    }

    public func retrieveProxyRepresentation(for identity: Identity) async throws {
        let commandID = await auditor.getNewCommandId()
        var admitted = false
        let result = Future<Bool, Error> { promise in
            admitted = self.withCallbackStateLock {
                guard self.canStoreCallback(bytes: 0), self.descriptionPromises.isEmpty else { return false }
                self.descriptionPromises[commandID] = promise
                return true
            }
        }
        guard admitted else { throw BridgeError.transportUnavailable }
        do {
            try await sendCommandChecked(command: .description, identity: identity, payload: nil, commandId: commandID)
            _ = try await result.getOneWithTimeout()
            withDescriptionStateLock { descriptionFetchedDate = Date() }
            withCallbackStateLock { descriptionPromises[commandID] = nil }
            await finishOperation(commandID)
        } catch {
            withCallbackStateLock { descriptionPromises[commandID] = nil }
            await finishOperation(commandID)
            throw error
        }
    }

    public func get(keypath: String, requester: Identity) async throws -> ValueType {
        let commandID = await auditor.getNewCommandId()
        let valuePublisher = PassthroughSubject<ValueType, Error>()
        let (result, subscription) = retainedResult(valuePublisher)
        defer { subscription.cancel() }
        guard storeValuePublisher(valuePublisher, for: keypath, commandID: commandID) else { throw BridgeError.transportUnavailable }
        do {
            try await sendCommandChecked(command: .get, identity: requester, payload: .string(keypath), commandId: commandID)
            let value = try await result.getOneWithTimeout()
            clearValuePublisher(for: keypath, expected: valuePublisher)
            await finishOperation(commandID)
            return value
        } catch {
            clearValuePublisher(for: keypath, expected: valuePublisher)
            await finishOperation(commandID)
            throw error
        }
    }

    public func set(keypath: String, value: ValueType, requester: Identity) async throws -> ValueType? {
        let commandID = await auditor.getNewCommandId()
        let setValueStatePublisher = PassthroughSubject<SetValueResponse, Error>()
        let (result, subscription) = retainedResult(setValueStatePublisher)
        defer { subscription.cancel() }
        guard storeSetValueResponsePublisher(setValueStatePublisher, for: keypath, commandID: commandID) else { throw BridgeError.transportUnavailable }
        do {
            try await sendCommandChecked(command: .set, identity: requester, payload: .keyValue(KeyValue(key: keypath, value: value)), commandId: commandID)
            let response = try await result.getOneWithTimeout()
            clearSetValueResponsePublisher(for: keypath, expected: setValueStatePublisher)
            await finishOperation(commandID)
            guard response.state == .ok else { throw SetValueError.error }
            return response.value
        } catch {
            clearSetValueResponsePublisher(for: keypath, expected: setValueStatePublisher)
            await finishOperation(commandID)
            throw error
        }
    }

    public func keys(requester: Identity) async throws -> [String] {
        _ = requester
        throw BridgeOperationError.unsupportedOperation("keys")
    }
    
    public func typeForKey(key: String, requester: Identity) async throws -> ValueType {
        _ = requester
        throw BridgeOperationError.unsupportedOperation("typeForKey:\(key)")
    }
    
    public func isMember(identity: Identity, requester: Identity) -> Bool {
        _ = identity
        _ = requester
        // Transport cannot manufacture protocol membership locally.
        return false
    }
    
    public func detach(label: String, requester: Identity) {
        retirementWork.submit { [self] in
            await sendCommand(command: .removeConnecion, identity: requester, payload: .string(label))
        }
        
    }
    
    public func dropFlow(label: String, requester: Identity) {
        retirementWork.submit { [self] in
            await sendCommand(command: .dropFlow, identity: requester, payload: .string(label))
        }
    }
    
    public func dropAllFlows(requester: Identity) {
        retirementWork.submit { [self] in
            await sendCommand(command: .unsubscribeAll, identity: requester, payload: nil)
        }
    }
    
    public func detachAll(requester: Identity) {
        retirementWork.submit { [self] in
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
        case timeout
        case someError
    }

    func resolvedEmitCell(for requester: Identity?) async throws -> Emit {
        // Snapshot routing and generation while protected, then resolve without a
        // blocking lock. Signing responses must remain free to enter the bridge.
        let context = try withInboundCacheState { () -> (String?, Emit?, Identity, UInt64) in
            guard !inboundCacheClosed else { throw BridgeError.transportUnavailable }
            return (publisherUuid, emitCellAtEndpoint,
                    try inboundPublisherResolvingIdentity(for: requester), inboundCacheGeneration)
        }
        if let publisherUuid = context.0 {
            guard let resolver = CellBase.defaultCellResolver else { throw BridgeError.resolverIsMissing }
            let resolvingIdentity = context.2
            let cacheKey = resolvingIdentity.uuid.lowercased()
            if let cached = try withInboundCacheState({ () throws -> Emit? in
                guard !inboundCacheClosed, inboundCacheGeneration == context.3 else { throw BridgeError.transportUnavailable }
                return inboundEmitCellCache[cacheKey]
            }) { return cached }
            let resolved = try await resolver.cellAtEndpoint(
                endpoint: "cell:///\(publisherUuid)", requester: resolvingIdentity
            )
            await inboundResolutionObserver?()
            return try withInboundCacheState {
                guard !inboundCacheClosed, inboundCacheGeneration == context.3 else { throw BridgeError.transportUnavailable }
                if let cached = inboundEmitCellCache[cacheKey] { return cached }
                // Saturation only skips memoization; every miss still uses the
                // authoritative resolver and the original requester identity.
                let cost = cacheKey.utf8.count
                if inboundEmitCellCache.count < inboundCacheMaximumCount,
                   cost <= inboundCacheMaximumBytes - inboundCacheBytes {
                    inboundEmitCellCache[cacheKey] = resolved
                    inboundCacheBytes += cost
                }
                return resolved
            }
        }
        if let emitter = context.1 { return emitter }
        throw BridgeError.emitterUnavailable
    }

    private func inboundPublisherResolvingIdentity(for requester: Identity?) throws -> Identity {
        if let inboundPublisherLookupIdentity {
            return inboundPublisherLookupIdentity
        }
        if let requester {
            return requester
        }
        if let owner {
            return owner
        }
        throw BridgeError.noOwner
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
        withDescriptionStateLock {
            identityProofAuthorization.discovered(domain: description.identityDomain, resource: description.uuid)
            descriptionState = DescriptionState(
                uuid: description.uuid,
                agreementTemplate: description.agreementTemplate,
                identityDomain: description.identityDomain,
                name: description.name,
                feedProperties: description.feedProperties
            )
        }
        // Subscriber callbacks and async proof traffic must never run with the
        // description lock held. No transport-wide serialization is introduced.
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
//        retirementWork.submit { [self] in
//            await self.sendCommand(command: .connectEmitter, identity: requester, payload: .object(payload))
//        }
//        return PassthroughSubject<ConnectState, Error>().eraseToAnyPublisher()  // Not implemented
//    }
    
    public func attach(emitter: Emit, label: String, requester: Identity) async throws -> ConnectState {
        let advertisedEmitter = try await emitter.advertise(for: requester)
        let payload: Object = ["label": .string(label), "publisher": .description(advertisedEmitter)]
        let commandID = await auditor.getNewCommandId()
        let callbackPublisher = PassthroughSubject<ConnectState, Error>()
        let (result, subscription) = retainedResult(callbackPublisher)
        defer { subscription.cancel() }
        guard storeConnectPublisher(callbackPublisher, for: commandID) else { throw BridgeError.transportUnavailable }

        do {
            try await sendCommandChecked(
                command: .connectEmitter,
                identity: requester,
                payload: .object(payload),
                commandId: commandID
            )
            let connectState = try await result.getOneWithTimeout()
            clearConnectPublisher(for: commandID)
            await finishOperation(commandID)
            return connectState
        } catch {
            clearConnectPublisher(for: commandID)
            await finishOperation(commandID)
            throw error
        }
    }

    
    public func absorbFlow(label: String, requester: Identity) {
        bridgeLog("Absorb flow requested for label: \(label)")
        retirementWork.submit { [self] in
            await self.sendCommand(command: .absorbFlow, identity: requester, payload: .string(label))
        }
    }
    
    public func signMessageForIdentity(messageData: Data, identity: Identity) -> AnyPublisher<Data, Error> {
        Deferred { [weak self] () -> Future<Data, Error> in
            Future { promise in
                do {
                    try IdentitySigningChallenge.validateSigningData(messageData, for: identity)
                } catch {
                    if let self {
                        self.retirementWork.submit {
                            await self.recordSigningDeniedEvent(
                                String(describing: error),
                                identity: identity,
                                reasonCode: CellSecurityReasonCode.invalidSigningChallenge
                            )
                        }
                    }
                    promise(.failure(error))
                    return
                }

                guard let self else {
                    promise(.failure(BridgeError.someError))
                    return
                }
                guard self.ready else {
                    self.retirementWork.submit {
                        await self.recordSigningDeniedEvent(
                            "bridge session is not ready",
                            identity: identity,
                            reasonCode: CellSecurityReasonCode.bridgeNotReady,
                            kind: .transportRejected,
                            requiredAction: "wait_for_bridge_ready"
                        )
                    }
                    promise(.failure(BridgeError.denied))
                    return
                }

                let task = self.retirementWork.submit(bytes: messageData.count) {
                    if let denial = await self.signingContainmentDenial(for: identity) {
                        await self.recordSigningDeniedEvent(
                            denial.message,
                            identity: identity,
                            reasonCode: denial.reasonCode,
                            kind: .transportRejected,
                            requiredAction: denial.requiredAction
                        )
                        promise(.failure(BridgeError.denied))
                        return
                    }

                    let commandID = await self.auditor.getNewCommandId()
                    let bridgeCommand = BridgeCommand(
                        cmd: Command.sign.rawValue,
                        identity: identity,
                        payload: .signData(messageData),
                        cid: commandID
                    )
                    let signRegistered = self.storeSignRequest(
                        promise,
                        identity: identity,
                        messageData: messageData,
                        for: commandID
                    )
                    guard signRegistered else { return }
                    guard await self.auditor.storeBridgeCommand(bridgeCommand, for: commandID) else {
                        self.takeSignRequest(for: commandID)?.promise(.failure(BridgeError.transportUnavailable))
                        return
                    }

                    guard let bridgeCommandJSON = try? JSONEncoder().encode(bridgeCommand),
                          let transport = self.transport else {
                        self.takeSignRequest(for: commandID)?.promise(.failure(BridgeError.someError))
                        await self.auditor.removeBridgeCommand(for: commandID)
                        return
                    }

                    do {
                        try await transport.sendData(bridgeCommandJSON)
                    } catch {
                        self.takeSignRequest(for: commandID)?.promise(.failure(error))
                        await self.auditor.removeBridgeCommand(for: commandID)
                    }
                }
                if task == nil { promise(.failure(BridgeError.transportUnavailable)) }
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

    private func sendSigningDenied(
        _ message: String,
        cid: Int,
        identity: Identity? = nil,
        reasonCode: String = CellSecurityReasonCode.bridgeSigningDenied,
        kind: CellSecurityEventKind = .vaultSignRejected,
        requiredAction: String = "retry_with_valid_identity_signing_challenge"
    ) async {
        bridgeLog("Rejected bridge signing request: \(message)")
        await recordSigningDeniedEvent(
            message,
            identity: identity,
            reasonCode: reasonCode,
            kind: kind,
            requiredAction: requiredAction
        )
        let response = BridgeCommand(cmd: "response", payload: .string("signing denied: \(message)"), cid: cid)
        if let responseJSONData = try? JSONEncoder().encode(response),
           let transport {
            try? await transport.sendData(responseJSONData)
        }
    }

    private func recordSigningDeniedEvent(
        _ message: String,
        identity: Identity?,
        reasonCode: String,
        kind: CellSecurityEventKind = .vaultSignRejected,
        requiredAction: String = "retry_with_valid_identity_signing_challenge"
    ) async {
        await CellBase.recordSecurityEvent(
            .bridgeSigningDenied(
                bridgeUUID: uuid,
                identity: identity,
                reasonCode: reasonCode,
                message: message,
                kind: kind,
                requiredAction: requiredAction,
                identityDomain: identityDomain
            )
        )
    }

    private func signingContainmentDenial(
        for identity: Identity
    ) async -> (message: String, reasonCode: String, requiredAction: String)? {
        guard let controller = CellBase.securityContainmentController else {
            return nil
        }

        if await controller.isQuarantined(resourceKind: "bridge", identifier: uuid) {
            return (
                "bridge is temporarily quarantined",
                CellSecurityReasonCode.bridgeQuarantined,
                "wait_for_quarantine_or_reauthenticate"
            )
        }

        let fingerprint = identity.signingPublicKeyFingerprint ?? "missing-signing-key"
        let scope = [
            "bridge",
            uuid,
            "sign",
            identity.uuid,
            fingerprint,
            identityDomain
        ].joined(separator: ":")
        let decision = await controller.checkSigningRateLimit(
            scope: scope,
            policy: CellBase.securityContainmentPolicy
        )
        switch decision {
        case .allowed:
            return nil
        case .denied(let retryAfter):
            let seconds = max(1, Int(ceil(retryAfter)))
            return (
                "signing is rate limited; retry after \(seconds)s",
                CellSecurityReasonCode.signingRateLimited,
                "wait_before_retrying_signing"
            )
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
        guard await auditor.storeBridgeCommand(bridgeCommand, for: resolvedCommandId) else {
            throw BridgeError.transportUnavailable
        }

        guard let bridgeCommandJson = try? JSONEncoder().encode(bridgeCommand) else {
            throw BridgeError.someError
        }
        guard let transport else {
            throw BridgeError.transportUnavailable
        }

        identityProofAuthorization.begin(bridgeCommand)
        do {
            try await transport.sendData(bridgeCommandJson)
        } catch {
            identityProofAuthorization.complete(resolvedCommandId)
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
        guard !withCallbackStateLock({ retired }) else { throw BridgeError.transportUnavailable }
        var command = command
        if command.command != .sign, let presented = command.identity {
            // A transport may hydrate an identity for routing, but a public wire
            // descriptor never grants access to this process's signing vault.
            // Origin proofs for remote requesters must travel back to the peer.
            let requester = presented.publicIdentitySnapshot()
            // Preserve the intrinsic public-metadata grant installed by Identity's
            // constructor/decoder. Do not import caller-supplied runtime grants.
            requester.grants = [Grant(keypath: "displayName", permission: "r---")]
            requester.identityVault = BridgeIdentityVault(cloudBridge: self)
            command.identity = requester
        }
        bridgeLog("Consume command cmd: \(command.cmd)")
            switch command.command {
            case .ready:
                let publisher = withCallbackStateLock { readyPublisher }
                publisher.send(true)
                
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
//                    retirementWork.submit { [self] in
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
//                            retirementWork.submit { [self] in
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
                        var setValueResponse = SetValueResponse(state: .ok)
                        do {
                            if let result = try await keypathLookupPublisher.set(keypath: payload.key, value: setValue, requester: identity) {
                                setValueResponse.value = result
                            }
                            
                            
                        } catch {
                            setValueResponse.state = .error
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
                guard let identity = command.identity,
                      case let .string(key) = command.payload else {
                    await sendGetErrorResponse(
                        message: "Value for keypath failed: missing identity or keypath payload",
                        cid: command.cid
                    )
                    break
                }

                do {
                    guard let keypathLookupPublisher = try await resolvedEmitCell(for: identity) as? Meddle else {
                        await sendGetErrorResponse(
                            message: "Value for keypath failed: publisher does not expose Meddle",
                            cid: command.cid
                        )
                        break
                    }
                    let valueType = try await keypathLookupPublisher.get(keypath: key, requester: identity)
                    let response = BridgeCommand(cmd: "response", payload: valueType, cid: command.cid)
                    if let responseJSONData = try? JSONEncoder().encode(response),
                       let transport = transport {
                        try await transport.sendData(responseJSONData)
                    }
                } catch {
                    await sendGetErrorResponse(
                        message: "Consume command \(command.cmd) failed for get(\(key)): \(error)",
                        cid: command.cid
                    )
                }
            
            case .sign:
                bridgeLog("Got sign command")
                if let sentPayload = command.payload,
                   case let .signData(value) = sentPayload,
                   let identity = command.identity
                {
                    let challenge: IdentitySigningChallenge
                    do {
                        challenge = try IdentitySigningChallenge.validateSigningData(value, for: identity)
                    } catch {
                        await sendSigningDenied(
                            String(describing: error),
                            cid: command.cid,
                            identity: identity,
                            reasonCode: CellSecurityReasonCode.invalidSigningChallenge
                        )
                        return
                    }
                    guard ready else {
                        await sendSigningDenied(
                            "bridge session is not ready",
                            cid: command.cid,
                            identity: identity,
                            reasonCode: CellSecurityReasonCode.bridgeNotReady,
                            kind: .transportRejected,
                            requiredAction: "wait_for_bridge_ready"
                        )
                        return
                    }
                    if let denial = await signingContainmentDenial(for: identity) {
                        await sendSigningDenied(
                            denial.message,
                            cid: command.cid,
                            identity: identity,
                            reasonCode: denial.reasonCode,
                            kind: .transportRejected,
                            requiredAction: denial.requiredAction
                        )
                        return
                    }
                    guard let permit = identityProofAuthorization.permit(for: challenge, identity: identity),
                          await permit.vault.identityExistInVault(permit.identity) else {
                        await sendSigningDenied(
                            "no active local operation authorizes this identity and challenge scope",
                            cid: command.cid,
                            identity: identity,
                            reasonCode: "unexpected_identity_signing_challenge"
                        )
                        return
                    }
                    if let replayStore = CellBase.signingChallengeReplayStore {
                        let replayDecision = await replayStore.consume(challenge)
                        guard replayDecision == .accepted else {
                            await sendSigningDenied(
                                "signing challenge rejected: \(replayDecision)",
                                cid: command.cid,
                                identity: identity,
                                reasonCode: replayDecision.reasonCode,
                                kind: replayDecision == .replay ? .signingChallengeReplay : .vaultSignRejected,
                                requiredAction: replayDecision.requiredAction
                            )
                            return
                        }
                    }
                    
                    guard identityProofAuthorization.isCurrent(permit) else { return }
                        do {
                            let signatureData = try await permit.vault.signMessageForIdentity(messageData: value, identity: permit.identity)
                            guard identityProofAuthorization.isCurrent(permit) else { return }
                            await self.sendResponse(command: .response, identity: identity, payload: .signature(signatureData), cid: command.cid)
                        } catch {
                            bridgeLog("Consume command signing data failed with error: \(error)")
                            await self.sendSigningDenied(
                                String(describing: error),
                                cid: command.cid,
                                identity: identity,
                                reasonCode: CellSecurityReasonCode.bridgeSigningDenied
                            )
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

            case .stopFeed:
                try await processStopFeedCommand(command: command)
                
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

    private func sendGetErrorResponse(message: String, cid: Int) async {
        bridgeLog(message)
        let response = BridgeCommand(cmd: "response", payload: .string("failure: \(message)"), cid: cid)
        do {
            if let responseJSONData = try? JSONEncoder().encode(response),
               let transport {
                try await transport.sendData(responseJSONData)
            }
        } catch {
            bridgeLog("Sending get error response failed with error: \(error)")
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
            let advertisedPublisher = try await publisher.advertise(for: identity)
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
        guard let identity = command.identity else { return }
        let token = UUID()
        let admitted = withCallbackStateLock { () -> Bool in
            guard !retired, feedInstallation == nil else { return false }
            feedInstallation = token
            return true
        }
        guard admitted else { return }
        do {
            let emitter = try await resolvedEmitCell(for: identity)
            let publisher = try await emitter.flow(requester: identity)
            setupFlow(commandCid: command.cid, requester: identity, token: token, from: publisher)
        } catch {
            withCallbackStateLock { if feedInstallation == token { feedInstallation = nil } }
            throw error
        }
    }

    private func processStopFeedCommand(command: BridgeCommand) async throws {
        let subscription = withCallbackStateLock { () -> AnyCancellable? in
            guard let identity = command.identity,
                  case let .integer(feedCommandID) = command.payload,
                  feedCommandID == inboundFeedCommandID,
                  let requester = inboundFeedRequester,
                  bridgeIdentitiesReferenceSame(requester, identity) else { return nil }
            let subscription = feedCancellable
            feedCancellable = nil; feedInstallation = nil
            inboundFeedCommandID = nil; inboundFeedRequester = nil; feedActive = false
            return subscription
        }
        subscription?.cancel()
    }

    private func bridgeIdentitiesReferenceSame(_ trusted: Identity, _ presented: Identity) -> Bool {
        guard trusted.uuid == presented.uuid,
              let trustedFingerprint = trusted.signingPublicKeyFingerprint,
              let presentedFingerprint = presented.signingPublicKeyFingerprint else {
            return false
        }
        return trustedFingerprint == presentedFingerprint
    }
    
    private func setupFlow(commandCid: Int, requester: Identity, token: UUID,
                           from publisher: AnyPublisher<FlowElement, Error>?) {
        guard withCallbackStateLock({ !retired && feedInstallation == token }) else { return }
        // Publishers may synchronously emit/complete while subscribing. Never
        // call into Combine under callbackStateLock, then recheck installation.
        let subscription = publisher?.sink(receiveCompletion: { [weak self] _ in
            self?.withCallbackStateLock {
                guard self?.feedInstallation == token else { return }
                self?.feedInstallation = nil; self?.feedCancellable = nil
                self?.inboundFeedCommandID = nil; self?.inboundFeedRequester = nil
                self?.feedActive = false
            }
        }, receiveValue: { [weak self] element in
            guard let self, self.withCallbackStateLock({ !self.retired && self.feedInstallation == token }) else { return }
            let accepted = self.retirementWork.submitEncoded({
                try JSONEncoder().encode(BridgeCommand(cmd: "response", payload: .flowElement(element), cid: commandCid))
            }, send: { [weak self] data in
                guard let self, let transport = self.withCallbackStateLock({ self.transport }) else { return }
                do { try await transport.sendData(data) }
                catch { bridgeLog("Feed transport send failed") }
            })
            if !accepted { self.beginRetirement() }
        })
        let installed = withCallbackStateLock { () -> Bool in
            guard !retired, feedInstallation == token else { return false }
            feedCancellable = subscription
            inboundFeedCommandID = commandCid; inboundFeedRequester = requester
            feedActive = subscription != nil
            return true
        }
        if !installed { subscription?.cancel() }
    }

    // This is the processing of responses of commands sent over the websocket
    public func consumeResponse(command: BridgeCommand) async throws {
        guard !withCallbackStateLock({ retired }) else { throw BridgeError.transportUnavailable }
        bridgeLog("Consume response cmd: \(command.cmd)")

        if let commandRequest = await auditor.loadBridgeCommandForCommandId(command.cid) {
            let retainCommandForStream = commandRequest.command == .feed
            if !retainCommandForStream { identityProofAuthorization.complete(command.cid) }
            switch commandRequest.command {
            case .description:
                let promise = withCallbackStateLock { () -> ((Result<Bool, Error>) -> Void)? in
                    guard !retired else { return nil }
                    return descriptionPromises.removeValue(forKey: command.cid)
                }
                if let promise {
                    if case .description(let value) = command.payload {
                        configure(from: value)
                        promise(.success(true))
                    } else { promise(.failure(BridgeError.noDescription)) }
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
                guard withCallbackStateLock({ !retired && outboundFeedCommandID == command.cid }) else { return }
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
                    let publisher = withCallbackStateLock { () -> PassthroughSubject<SetValueResponse, Error>? in
                        guard !retired, setCommandIDs[keyValue.key] == command.cid else { return nil }
                        return setValueForKeypathCallbackDataPublishers[keyValue.key]
                    }
                    publisher?.send(setValueResponse)
                    publisher?.send(completion: .finished)
                }
                
            case .get:
                if let sentPayload = command.payload, let requestedKeyValue = commandRequest.payload {
                    if case let .string(requestedKey) = requestedKeyValue {
                        let publisher = withCallbackStateLock { () -> PassthroughSubject<ValueType, Error>? in
                            guard !retired, valueCommandIDs[requestedKey] == command.cid else { return nil }
                            return valueForKeyCallbackDataPublishers[requestedKey]
                        }
                        publisher?.send(sentPayload)
                        publisher?.send(completion: .finished)
//                        print("Got valueForKeypath payload. \(String(describing: try? sentPayload.jsonString())) Key: \(requestedKey)") //Do we need registery?
                    }
                }
                
            case .sign:
                bridgeLog("Got sign response")
                let signRequest = takeSignRequest(for: command.cid)
                switch command.payload {
                case let .signature(value):
                    guard let signRequest else {
                        bridgeLog("No pending sign request for response cid=\(command.cid)")
                        break
                    }
                    let verified = IdentityPublicKeySignatureVerifier.verify(
                        signature: value,
                        messageData: signRequest.messageData,
                        identity: signRequest.identity
                    )
                    guard verified else {
                        bridgeLog("Bridge sign response failed verification for cid=\(command.cid)")
                        signRequest.promise(.failure(IdentityVaultError.signingFailed))
                        break
                    }
                    signRequest.promise(.success(value))
                    
                    
                default:
                    bridgeLog("Did not get signature as payload")
                    signRequest?.promise(.failure(ValueTypeError.unexpectedValueType))
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

            if retainCommandForStream == false {
                await auditor.removeBridgeCommand(for: command.cid)
            }
            
        } else {
            bridgeLog("Could not find command request for response: \(command)")
        }
    }
   
    private func extractCommand(_ incomingData: Data) async throws {
//        retirementWork.submit { [self] in
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

// Starting only after receive(subscriber:) returned closes the initial-frame
// gap without buffering or relying on Task scheduling relative to sink setup.
struct BridgeFeedSubscriptionPublisher: Publisher {
    typealias Output = FlowElement
    typealias Failure = Error
    let source: AnyPublisher<FlowElement, Error>
    let start: () -> Void
    func receive<S: Subscriber>(subscriber: S) where S.Input == FlowElement, S.Failure == Error {
        source.receive(subscriber: subscriber)
        start()
    }
}
