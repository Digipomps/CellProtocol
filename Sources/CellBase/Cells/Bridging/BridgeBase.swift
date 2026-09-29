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
    private typealias ConnectPromise = (Result<ConnectState, Error>) -> Void
    private typealias ContractPromise = (Result<AgreementState, Error>) -> Void
    private typealias ValuePromise = (Result<ValueType, Error>) -> Void
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
    private var outboundFeedCommandID: Int?
    private var outboundFeedRequester: Identity?
    private var queuedFeedDeliveries = 0
    private var feedAdmissionPending = false
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
    
    
    private var valuePromises = [Int: ValuePromise]()
    
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
    
    private var readyPublisher = PassthroughSubject<Bool, Error>()
    private var readyValue = false
    private var ready: Bool {
        get { connectionStateLock.withLock { readyValue } }
        set { connectionStateLock.withLock { readyValue = newValue } }
    }
    var signRequestTimeoutNanoseconds: UInt64 = 30_000_000_000
//    private var readyPublisher = Just<Bool>(<#Bool#>)
    private var feedActiveValue = false
    var feedActive: Bool {
        get { connectionStateLock.withLock { feedActiveValue } }
        set { connectionStateLock.withLock { feedActiveValue = newValue } }
    }
    var pendingFeedDeliveries: Int { withCallbackStateLock { queuedFeedDeliveries } }
    let auditor: BridgeBaseAuditor
    // Deterministic seam after the initial lookup, before atomic consumption.
    var afterResponseLookup: (@Sendable (BridgeCommand) async -> Void)?
    
    var feedEndpoint : URL?
    var feedProperties: FeedProperties? {
        get { withDescriptionStateLock { descriptionState.feedProperties } }
        set { withDescriptionStateLock { descriptionState.feedProperties = newValue } }
    }
    private let connectionStateLock: NSRecursiveLock
    private var transportValue: BridgeTransportProtocol?
    private var channelSessionValue: BridgeChannelSession?
    var transport: BridgeTransportProtocol? {
        get { connectionStateLock.withLock { transportValue } }
        set { connectionStateLock.withLock { transportValue = newValue } }
    }
    private var channelSession: BridgeChannelSession? {
        get { connectionStateLock.withLock { channelSessionValue } }
        set { connectionStateLock.withLock { channelSessionValue = newValue } }
    }
    var emitCellAtEndpoint: Emit?
    private var inboundEmitCellCache = [String: Emit]()
    private var inboundPublisherLookupIdentity: Identity?
    private var callbackStateLock: NSRecursiveLock { connectionStateLock }
    private let identityProofAuthorization: BridgeIdentityProofAuthorization
    // Local clock/replay dependencies; configured before use by deterministic
    // lifecycle tests. No remote command can supply these values.
    var signingWallClock: @Sendable () -> Date = { Date() }
    var signingMonotonic: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var consumeSigningChallenge: @Sendable (IdentitySigningChallenge, Date) async -> CellSecurityReplayDecision = { challenge, now in
        await CellBase.signingChallengeReplayStore?.consume(challenge, now: now) ?? .accepted
    }
    
    
    private var descriptionFetchedPublisher = PassthroughSubject<Bool, Error>()
    private var descriptionFetchedDate: Date?
    
    public init(_ config: Config) async throws {
        let lifecycleLock = NSRecursiveLock()
        connectionStateLock = lifecycleLock
        auditor = BridgeBaseAuditor(lock: lifecycleLock)
        identityProofAuthorization = BridgeIdentityProofAuthorization(owner: config.owner, scopes: config.identityProofScopes)
        bridgeLog("Bridge base initialized")
        self.owner = config.owner
        
        let initialAgreement: Agreement
        if let configuredAgreement = config.agreementTemplate {
            initialAgreement = configuredAgreement
        } else {
            initialAgreement = await Agreement()
        }
        descriptionState = DescriptionState(
            uuid: config.uuid,
            agreementTemplate: initialAgreement,
            identityDomain: config.identityDomain
        )
        feedEndpoint = URL(string: "https://localhost/")
        self.transportValue = config.transport
        self.channelSessionValue = config.transport.channelSession
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
        let lifecycleLock = NSRecursiveLock()
        connectionStateLock = lifecycleLock
        auditor = BridgeBaseAuditor(lock: lifecycleLock)
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

    private func withDescriptionStateLock<T>(_ block: () throws -> T) rethrows -> T {
        descriptionStateLock.lock()
        defer { descriptionStateLock.unlock() }
        return try block()
    }

    private func takeValuePromise(for commandID: Int) -> ValuePromise? {
        withCallbackStateLock { valuePromises.removeValue(forKey: commandID) }
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

    private func storeSignRequest(
        _ promise: @escaping SignPromise,
        identity: Identity,
        messageData: Data,
        for commandID: Int
    ) {
        let timeoutNanoseconds = signRequestTimeoutNanoseconds
        let cleanupTask = Task { [weak self] in
            guard timeoutNanoseconds > 0 else { return }
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            guard let expiredRequest = self.takeSignRequest(for: commandID) else { return }
            self.auditor.removeBridgeCommand(for: commandID)
            expiredRequest.promise(.failure(BridgeError.timeout))
        }
        withCallbackStateLock {
            signCallbackRequests[commandID] = SignRequest(
                promise: promise,
                identity: identity,
                messageData: messageData,
                cleanupTask: cleanupTask
            )
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
    
    public var hasAuthenticatedChannel: Bool {
        guard let channelSession else { return false }
        return (try? channelSession.check()) != nil
    }

    /// Explicit client initiation. Ends old streams and pending operations; never
    /// retries a write or subscription. A new physical connection proves a fresh
    /// generation, including when the former connection has already expired.
    public func renewAuthenticatedChannel(requester: Identity, using physical: BridgeTransportProtocol? = nil) async throws {
        guard let owner, owner.referencesSameSigningIdentity(as: requester),
              publisherUuid == nil, let current = transport as? BridgeChannelTransport else {
            throw BridgeChannelAuthentication.Failure.unavailable
        }
        let replacement = try await current.replacementForRenewal(using: physical)
        try await setTransport(replacement, connection: .outbound)
        guard let endpoint = replacement.session.endpoint else { throw BridgeChannelAuthentication.Failure.unavailable }
        try await replacement.setup(URL(string: endpoint.audience)!, identity: requester)
    }

    /// Called locally by the authenticated physical transport, never by a ready frame.
    public func activateAuthenticatedChannel() throws {
        try connectionStateLock.withLock {
            guard let session = transportValue?.channelSession,
                  channelSessionValue == nil || session === channelSessionValue else {
                throw BridgeChannelAuthentication.Failure.unavailable
            }
            try session.check()
            channelSessionValue = session
            readyValue = true
            readyPublisher.send(true)
        }
    }

    public func ready() async throws {
        try await ready(timeout: 5)
    }

    public func ready(timeout: Int) async throws {
        let waiting = try connectionStateLock.withLock { () throws -> PassthroughSubject<Bool, Error>? in
            if readyValue {
                guard let session = channelSessionValue else { throw BridgeChannelAuthentication.Failure.closed }
                try session.check()
                return nil
            }
            return readyPublisher
        }
        guard let waiting else { return }
        _ = try await waiting.getOneWithTimeout(timeout)
        try connectionStateLock.withLock {
            guard waiting === readyPublisher, let session = channelSessionValue else {
                throw BridgeChannelAuthentication.Failure.staleGeneration
            }
            try session.check()
            readyValue = true
        }
    }
    public func setTransport(_ transport: BridgeTransportProtocol, connection: Connection) async throws {
        if let previous = channelSession, previous !== transport.channelSession {
            await channelDidClose(previous)
        }
        connectionStateLock.withLock {
            channelSession = transport.channelSession
            identityProofAuthorization.reset()
            let previousFeedStartTask = withCallbackStateLock { () -> Task<Void, Error>? in
                let task = outboundFeedStartTask
                outboundFeedStartTask = nil
                outboundFeedCommandID = nil
                outboundFeedRequester = nil
                inboundFeedCommandID = nil
                inboundFeedRequester = nil
                localFeedSubscriberCount = 0
                feedActive = false
                feedAdmissionPending = false
                return task
            }
            previousFeedStartTask?.cancel()
            flowElementCallbackCancellable?.cancel()
            flowElementCallbackCancellable = nil
            feedCancellable?.cancel()
            feedCancellable = nil
            self.transport = transport
            ready = false
            readyPublisher = PassthroughSubject<Bool, Error>()
            feedPublisher2 = PassthroughSubject<FlowElement, Error>()
            flowElementCallbackDataPublisher = PassthroughSubject<FlowElement, Error>()
            descriptionFetchedPublisher = PassthroughSubject<Bool, Error>()
            descriptionFetchedDate = nil
        
            switch connection {
            case .inbound(publisherUuid: let publisherUuid):
                self.publisherUuid = publisherUuid
                emitCellAtEndpoint = nil
                withCallbackStateLock { inboundEmitCellCache = [:] }
            case .outbound:
                self.publisherUuid = nil
                emitCellAtEndpoint = nil
                withCallbackStateLock { inboundEmitCellCache = [:] }
            }
        }
        transport.setDelegate(self)
    }
    
    func validateFeedPermission(identity: Identity) -> Bool {
        // Opportunity to abort querying over the net if we already know that it will be denied
        return true
    }
    
    
    public func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, any Error> {
        guard validateFeedPermission(identity: requester) else {
            throw StreamState.denied
        }
        try await ensureOutboundFeed(requester: requester)
        let (generation, publisher) = try withCallbackStateLock { () throws -> (BridgeChannelSession, PassthroughSubject<FlowElement, Error>) in
            guard let generation = channelSessionValue else { throw BridgeChannelAuthentication.Failure.closed }
            try generation.check()
            return (generation, feedPublisher2)
        }
        return publisher
            .handleEvents(
                receiveSubscription: { [weak self] _ in
                    self?.retainLocalFeedSubscriber(generation: generation)
                },
                receiveCompletion: { [weak self] _ in
                    self?.releaseLocalFeedSubscriber(generation: generation)
                },
                receiveCancel: { [weak self] in
                    self?.releaseLocalFeedSubscriber(generation: generation)
                }
            )
            .eraseToAnyPublisher()
    }

    private func ensureOutboundFeed(requester: Identity) async throws {
        let generation = channelSession
        let task = withCallbackStateLock { () -> Task<Void, Error> in
            if let outboundFeedStartTask {
                return outboundFeedStartTask
            }
            let newTask = Task { [weak self] in
                guard let self else {
                    throw BridgeError.transportUnavailable
                }
                try await self.startOutboundFeed(requester: requester)
            }
            outboundFeedStartTask = newTask
            return newTask
        }

        do {
            try await task.value
            try withCallbackStateLock {
                guard let generation, generation === channelSessionValue else { throw BridgeChannelAuthentication.Failure.staleGeneration }
                try generation.check()
            }
        } catch {
            withCallbackStateLock {
                guard generation === channelSessionValue else { return }
                outboundFeedStartTask = nil
                outboundFeedCommandID = nil
                outboundFeedRequester = nil
                feedActive = false
            }
            throw error
        }
    }

    private func startOutboundFeed(requester: Identity) async throws {
        guard let generation = channelSession else { throw BridgeChannelAuthentication.Failure.closed }
        let commandID = auditor.getNewCommandId()
        try withCallbackStateLock {
            guard generation === channelSessionValue else { throw BridgeChannelAuthentication.Failure.staleGeneration }
            try generation.check()
            let destination = feedPublisher2
            flowElementCallbackCancellable = flowElementCallbackDataPublisher
                .sink(receiveCompletion: { [weak self] _ in
                    self?.markOutboundFeedInactive(commandID: commandID)
                }, receiveValue: { flowElement in destination.send(flowElement) })
        }

        do {
            try await sendCommandChecked(
                command: .feed,
                identity: requester,
                payload: nil,
                commandId: commandID,
                expectedSession: generation
            )
            try withCallbackStateLock {
                guard generation === channelSessionValue else { throw BridgeChannelAuthentication.Failure.staleGeneration }
                try generation.check()
                outboundFeedCommandID = commandID
                outboundFeedRequester = requester
                feedActive = true
            }
        } catch {
            withCallbackStateLock {
                if generation === channelSessionValue {
                    flowElementCallbackCancellable?.cancel()
                    flowElementCallbackCancellable = nil
                }
                auditor.removeBridgeCommand(for: commandID)
            }
            throw error
        }
    }

    private func markOutboundFeedInactive(commandID: Int) {
        identityProofAuthorization.complete(commandID)
        withCallbackStateLock {
            guard outboundFeedCommandID == commandID else { return }
            outboundFeedStartTask = nil
            outboundFeedCommandID = nil
            outboundFeedRequester = nil
            feedActive = false
        }
        Task { [weak self] in
            self?.auditor.removeBridgeCommand(for: commandID)
        }
    }

    private func retainLocalFeedSubscriber(generation: BridgeChannelSession) {
        withCallbackStateLock {
            guard generation === channelSessionValue else { return }
            localFeedSubscriberCount += 1
        }
    }

    private func releaseLocalFeedSubscriber(generation: BridgeChannelSession) {
        let feedToStop = withCallbackStateLock { () -> (Int, Identity, BridgeTransportProtocol?)? in
            guard generation === channelSessionValue, localFeedSubscriberCount > 0 else { return nil }
            localFeedSubscriberCount -= 1
            guard localFeedSubscriberCount == 0,
                  let commandID = outboundFeedCommandID,
                  let requester = outboundFeedRequester else {
                return nil
            }
            outboundFeedStartTask = nil
            outboundFeedCommandID = nil
            outboundFeedRequester = nil
            feedActive = false
            identityProofAuthorization.complete(commandID)
            auditor.removeBridgeCommand(for: commandID)
            flowElementCallbackCancellable?.cancel()
            flowElementCallbackCancellable = nil
            return (commandID, requester, transportValue)
        }
        guard let feedToStop else { return }
        Task { [weak self] in
            await self?.sendStopFeed(commandID: feedToStop.0, requester: feedToStop.1, using: feedToStop.2, generation: generation)
        }
    }

    private func sendStopFeed(commandID: Int, requester: Identity, using transport: BridgeTransportProtocol?, generation: BridgeChannelSession) async {
        guard (try? generation.check()) != nil else { return }
        defer {
            Task { [weak self] in
                self?.auditor.removeBridgeCommand(for: commandID)
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
            bridgeLog("Stopping remote feed failed with transport error: code=operation_failed")
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
            let commandID = auditor.getNewCommandId()
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
                bridgeLog("Cloud Bridge connect setup failed with error: code=operation_failed")
                _ = transport
                clearConnectPromise(for: commandID)
                return .notConnected
            }
            do {
                let connectState = try await connectFuture.getOneWithTimeout(5)
                clearConnectPromise(for: commandID)
                return connectState
            } catch {
                bridgeLog("Cloud Bridge connect failed with error: code=operation_failed")
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
                let commandID = self.auditor.getNewCommandId()
                let callbackPublisher = PassthroughSubject<ConnectState, Error>()
                self.storeConnectPublisher(callbackPublisher, for: commandID)
                self.connectCallbackCancellable = callbackPublisher
                    .handleEvents(receiveCancel: {
                        bridgeLog("Cancelled cloud bridge connect")
                        connectPublisher.send(completion: .failure(ConnectError.cancelled ))
                    })
                    .sink(receiveCompletion: {[weak self] completion in
                        bridgeLog("Connect callback publisher completed")
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
        let previous = transport
        feedLease?.release(); feedLease = nil
        channelSession = nil
        ready = false
        identityProofAuthorization.reset()
        feedCancellable?.cancel(); feedCancellable = nil
        transport = nil
        Task {
            if transport == nil && channelSession == nil { failPendingChannelWork() }
            await previous?.close()
        }
    }
    
    public func addAgreement(_ contract: Agreement, for identity: Identity) async throws -> AgreementState {
        var contractState = AgreementState.template
        let commandID = auditor.getNewCommandId()
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
        let commandID = auditor.getNewCommandId()
        // Future retains an immediate response, even before this caller reaches
        // its await. cid ownership also makes old timeout cleanup harmless.
        let result = Future<ValueType, Error> { promise in
            self.withCallbackStateLock { self.valuePromises[commandID] = promise }
        }
        defer {
            _ = takeValuePromise(for: commandID)
            auditor.removeBridgeCommand(for: commandID)
            identityProofAuthorization.complete(commandID)
        }
        try await sendCommandChecked(command: .get, identity: requester, payload: .string(keypath), commandId: commandID)
        return try await result.getOneWithTimeout()
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
        Task {
            await sendCommand(command: .removeConnecion, identity: requester, payload: .string(label))
        }
        
    }
    
    public func dropFlow(label: String, requester: Identity) {
        Task {
            await sendCommand(command: .dropFlow, identity: requester, payload: .string(label))
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
        case timeout
        case someError
    }

    private func resolvedEmitCell(for requester: Identity?) async throws -> Emit {
        guard let currentSession = channelSession else { throw BridgeChannelAuthentication.Failure.closed }
        try currentSession.check(identity: requester, requiresIdentity: true)
        if let publisherUuid {
            guard let resolver = CellBase.defaultCellResolver else {
                throw BridgeError.resolverIsMissing
            }

            let resolvingIdentity = try inboundPublisherResolvingIdentity(for: requester)
            let cacheKey = [channelSession?.generation ?? "host", resolvingIdentity.uuid, resolvingIdentity.signingPublicKeyFingerprint ?? ""].joined(separator: ":")
            if let cached = withCallbackStateLock({ inboundEmitCellCache[cacheKey] }) {
                return cached
            }

            let resolved = try await resolver.cellAtEndpoint(
                endpoint: "cell:///\(publisherUuid)",
                requester: resolvingIdentity
            )
            guard currentSession === channelSession else { throw BridgeChannelAuthentication.Failure.staleGeneration }
            try currentSession.check(identity: requester, requiresIdentity: true)
            withCallbackStateLock { inboundEmitCellCache[cacheKey] = resolved }
            return resolved
        }

        if let emitCellAtEndpoint {
            return emitCellAtEndpoint
        }

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
    
    // Internal decoding seam; callers must never log the description or decoder error.
    func configure(from description: Data) {
        do {
            let anyCell = try JSONDecoder().decode(AnyCell.self, from: description)
            self.configure(from: anyCell)
            
        } catch  {
            bridgeLog("Bridge description rejected code=invalid_description bytes=\(description.count)")
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
        let advertisedEmitter = try await emitter.advertise(for: requester)
        let payload: Object = ["label": .string(label), "publisher": .description(advertisedEmitter)]
        let commandID = auditor.getNewCommandId()
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
        bridgeLog("Absorb flow requested")
        Task {
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
                        Task {
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
                    Task {
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

                Task {
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

                    let commandID = self.auditor.getNewCommandId()
                    let bridgeCommand = BridgeCommand(
                        cmd: Command.sign.rawValue,
                        identity: identity.publicIdentitySnapshot(),
                        payload: .signData(messageData),
                        cid: commandID
                    )
                    self.storeSignRequest(
                        promise,
                        identity: identity,
                        messageData: messageData,
                        for: commandID
                    )
                    guard self.auditor.storeBridgeCommand(bridgeCommand, for: commandID) else {
                        self.takeSignRequest(for: commandID)?.promise(.failure(BridgeChannelAuthentication.Failure.capacity))
                        return
                    }

                    guard let bridgeCommandJSON = try? JSONEncoder().encode(bridgeCommand),
                          let transport = self.transport else {
                        self.takeSignRequest(for: commandID)?.promise(.failure(BridgeError.someError))
                        self.auditor.removeBridgeCommand(for: commandID)
                        return
                    }

                    do {
                        try await transport.sendData(bridgeCommandJSON)
                    } catch {
                        self.takeSignRequest(for: commandID)?.promise(.failure(error))
                        self.auditor.removeBridgeCommand(for: commandID)
                    }
                }
            }
        }.eraseToAnyPublisher()
    }

    private func sendResponse(command: Command, identity: Identity, payload: ValueType?, cid: Int, using transport: BridgeTransportProtocol?) async {
        let bridgeCommand = BridgeCommand(cmd: command.rawValue, identity: identity.publicIdentitySnapshot(), payload: payload, cid: cid)
        
        if let cloudBridgeCommandJson = try? JSONEncoder().encode(bridgeCommand),
        let transport = transport {
            do {
                try await transport.sendData(cloudBridgeCommandJson)
            } catch {
                bridgeLog("Sending response failed with error: code=operation_failed")
            }
        }
    }

    private func sendSigningDenied(
        _ message: String,
        cid: Int,
        using transport: BridgeTransportProtocol?,
        identity: Identity? = nil,
        reasonCode: String = CellSecurityReasonCode.bridgeSigningDenied,
        kind: CellSecurityEventKind = .vaultSignRejected,
        requiredAction: String = "retry_with_valid_identity_signing_challenge"
    ) async {
        bridgeLog("Rejected bridge signing request code=signing_denied cid=\(cid)")
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
        commandId: Int? = nil,
        expectedSession: BridgeChannelSession? = nil
    ) async throws -> Int {
        bridgeLog("Send command: \(command.rawValue)")
        try await ready()
        let admission = try connectionStateLock.withLock { () throws -> (BridgeChannelSession, BridgeTransportProtocol, Int, Data) in
            guard let currentSession = channelSessionValue, let transport = transportValue else {
                throw BridgeChannelAuthentication.Failure.closed
            }
            guard expectedSession == nil || expectedSession === currentSession else { throw BridgeChannelAuthentication.Failure.staleGeneration }
            try currentSession.checkOutbound(identity: identity, requiresIdentity: true)
            let cid = commandId ?? auditor.getNewCommandId()
            let bridgeCommand = BridgeCommand(cmd: command.rawValue, identity: identity, payload: payload, cid: cid)
            guard auditor.storeBridgeCommand(bridgeCommand, for: cid) else { throw BridgeChannelAuthentication.Failure.capacity }
            var wireCommand = bridgeCommand
            wireCommand.identity = identity.publicIdentitySnapshot()
            let bytes = try JSONEncoder().encode(wireCommand)
            identityProofAuthorization.begin(bridgeCommand, now: signingWallClock(), monotonic: signingMonotonic())
            return (currentSession, transport, cid, bytes)
        }
        do { try await admission.1.sendData(admission.3) }
        catch {
            identityProofAuthorization.complete(admission.2)
            auditor.removeBridgeCommand(for: admission.2)
            await channelDidClose(admission.0)
            throw error
        }
        return admission.2
    }
    
    public func sendCommand(command: Command, identity: Identity, payload: ValueType?) async {
        do {
            try await sendCommandChecked(command: command, identity: identity, payload: payload)
        } catch {
            bridgeLog("Sending command failed with error: code=operation_failed")
        }
    }
    
    private func validateOriginSigning(_ data: Data, identity: Identity, session: BridgeChannelSession,
                                       deadline: TimeInterval, permit: BridgeIdentityProofAuthorization.Permit? = nil) throws {
        try Task.checkCancellation()
        guard signingMonotonic() < deadline, ready, session === channelSession else {
            throw BridgeChannelAuthentication.Failure.staleGeneration
        }
        let now = signingWallClock()
        _ = try IdentitySigningChallenge.validateSigningData(data, for: identity, now: now)
        if let permit, !identityProofAuthorization.isCurrent(permit, now: now, monotonic: signingMonotonic()) {
            throw BridgeChannelAuthentication.Failure.closed
        }
        try session.checkOutbound(identity: identity, requiresIdentity: true)
    }

    //Consume command is processing commands relayed over the websocket
    public func consumeCommand(command: BridgeCommand) async throws {
        var command = command
        let transport = self.transport // A suspended old operation must never send on a replacement.
        guard let channelSession else { throw BridgeChannelAuthentication.Failure.unavailable }
        do {
            guard command.command != .ready else { throw BridgeChannelAuthentication.Failure.unexpectedMessage }
            try channelSession.checkInbound(command)
            if command.command != .sign, let presented = command.identity {
                command.identity = try channelSession.requester(for: presented, bridge: self)
            }
        }
        try channelSession.acquire(.operation)
        defer { channelSession.release(.operation) }
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
        bridgeLog("Consume command \(command.diagnosticMetadata)")
            switch command.command {
            case .ready:
                throw BridgeChannelAuthentication.Failure.unexpectedMessage
                
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
                                bridgeLog("Sending response failed with error: code=operation_failed")
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
                            bridgeLog("Bridge payload rejected code=expected_agreement \(command.diagnosticMetadata)")
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
                                    bridgeLog("Consume command \(command.command.rawValue) failed with error: code=operation_failed")
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
                                bridgeLog("Consume command \(command.command.rawValue) failed with error: code=operation_failed")
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
                        cid: command.cid, using: transport
                    )
                    break
                }

                do {
                    guard let keypathLookupPublisher = try await resolvedEmitCell(for: identity) as? Meddle else {
                        await sendGetErrorResponse(
                            message: "Value for keypath failed: publisher does not expose Meddle",
                            cid: command.cid, using: transport
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
                        cid: command.cid, using: transport
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
                        challenge = try IdentitySigningChallenge.validateSigningData(value, for: identity, now: signingWallClock())
                    } catch {
                        await sendSigningDenied(
                            String(describing: error),
                            cid: command.cid,
                            using: transport,
                            identity: identity,
                            reasonCode: CellSecurityReasonCode.invalidSigningChallenge
                        )
                        return
                    }
                    // Freeze the remaining challenge window before any lookup.
                    // A backward wall-clock jump cannot prolong a held request.
                    let signingDeadline = signingMonotonic() + max(0, min(IdentitySigningChallenge.defaultValidity,
                        challenge.expiresAt - signingWallClock().timeIntervalSince1970))
                    guard ready else {
                        await sendSigningDenied(
                            "bridge session is not ready",
                            cid: command.cid,
                            using: transport,
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
                            using: transport,
                            identity: identity,
                            reasonCode: denial.reasonCode,
                            kind: .transportRejected,
                            requiredAction: denial.requiredAction
                        )
                        return
                    }
                    try validateOriginSigning(value, identity: identity, session: channelSession, deadline: signingDeadline)
                    guard let permit = identityProofAuthorization.permit(for: challenge, identity: identity, now: signingWallClock(), monotonic: signingMonotonic()),
                          await permit.vault.identityExistInVault(permit.identity) else {
                        await sendSigningDenied(
                            "no active local operation authorizes this identity and challenge scope",
                            cid: command.cid,
                            using: transport,
                            identity: identity,
                            reasonCode: "unexpected_identity_signing_challenge"
                        )
                        return
                    }
                    try validateOriginSigning(value, identity: identity, session: channelSession, deadline: signingDeadline, permit: permit)
                    do {
                        let replayDecision = await consumeSigningChallenge(challenge, signingWallClock())
                        guard replayDecision == .accepted else {
                            await sendSigningDenied(
                                "signing challenge rejected: \(replayDecision)",
                                cid: command.cid,
                                using: transport,
                                identity: identity,
                                reasonCode: replayDecision.reasonCode,
                                kind: replayDecision == .replay ? .signingChallengeReplay : .vaultSignRejected,
                                requiredAction: replayDecision.requiredAction
                            )
                            return
                        }
                    }
                    
                    try validateOriginSigning(value, identity: identity, session: channelSession, deadline: signingDeadline, permit: permit)
                        do {
                            let signatureData = try await permit.vault.signMessageForIdentity(messageData: value, identity: permit.identity)
                            try validateOriginSigning(value, identity: identity, session: channelSession, deadline: signingDeadline, permit: permit)
                            await self.sendResponse(command: .response, identity: identity, payload: .signature(signatureData), cid: command.cid, using: transport)
                        } catch {
                            bridgeLog("Consume command signing data failed with error: code=operation_failed")
                            await self.sendSigningDenied(
                                String(describing: error),
                                cid: command.cid,
                                using: transport,
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

    private func sendGetErrorResponse(message: String, cid: Int, using transport: BridgeTransportProtocol?) async {
        bridgeLog("Bridge get rejected code=get_failed cid=\(cid)")
        let response = BridgeCommand(cmd: "response", payload: .string("failure: \(message)"), cid: cid)
        do {
            if let responseJSONData = try? JSONEncoder().encode(response),
               let transport {
                try await transport.sendData(responseJSONData)
            }
        } catch {
            bridgeLog("Sending get error response failed with error: code=operation_failed")
        }
    }
  
    private func processDescriptionCommand(command: BridgeCommand) async {
        let transport = self.transport
        let identity = command.identity
        guard let identity = identity else {
            return
        }
        let publisher: Emit
        do {
            publisher = try await resolvedEmitCell(for: identity)
        } catch {
            bridgeLog("Failed to resolve emit cell at endpoint: code=operation_failed")
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
            bridgeLog("Consume command \(command.command.rawValue) failed with error: code=operation_failed")
        }
    }

    private var feedLease: BridgeChannelResourceLease?

    private func processFeedCommand(command: BridgeCommand) async throws {
        guard let currentSession = channelSession else { throw BridgeChannelAuthentication.Failure.closed }
        if let identity =  command.identity {
            let reserved = withCallbackStateLock { () -> Bool in
                guard !feedAdmissionPending else { return false }
                feedAdmissionPending = true
                return true
            }
            guard reserved else { throw BridgeChannelAuthentication.Failure.capacity }
            defer { withCallbackStateLock { if currentSession === channelSessionValue { feedAdmissionPending = false } } }
            let emitter = try await resolvedEmitCell(for: identity)
            if withCallbackStateLock({ feedCancellable == nil }) {
                let lease = try BridgeChannelResourceLease(session: currentSession, resource: .feed)
                let publisher: AnyPublisher<FlowElement, Error>
                do {
                    publisher = try await emitter.flow(requester: identity)
                    try withCallbackStateLock {
                        guard currentSession === channelSessionValue else { throw BridgeChannelAuthentication.Failure.staleGeneration }
                        try currentSession.check(identity: identity, requiresIdentity: true)
                        inboundFeedCommandID = command.cid
                        inboundFeedRequester = identity
                        setupFlow(commandCid: command.cid, from: publisher, lease: lease,
                                  generation: currentSession, transport: transportValue)
                        feedActive = true
                    }
                } catch { lease.release(); throw error }
            }
        }
    }

    private func processStopFeedCommand(command: BridgeCommand) async throws {
        guard let identity = command.identity,
              case let .integer(feedCommandID) = command.payload,
              feedCommandID == inboundFeedCommandID,
              let inboundFeedRequester,
              bridgeIdentitiesReferenceSame(inboundFeedRequester, identity) else {
            bridgeLog("Rejected stopFeed command that did not match the active feed")
            return
        }
        feedCancellable?.cancel()
        feedCancellable = nil
        feedLease?.release(); feedLease = nil
        inboundFeedCommandID = nil
        self.inboundFeedRequester = nil
        feedActive = false
    }

    private func bridgeIdentitiesReferenceSame(_ trusted: Identity, _ presented: Identity) -> Bool {
        guard trusted.uuid == presented.uuid,
              let trustedFingerprint = trusted.signingPublicKeyFingerprint,
              let presentedFingerprint = presented.signingPublicKeyFingerprint else {
            return false
        }
        return trustedFingerprint == presentedFingerprint
    }
    
    private func setupFlow(commandCid: Int, from publisher: AnyPublisher<FlowElement, Error>?, lease: BridgeChannelResourceLease, generation: BridgeChannelSession, transport: BridgeTransportProtocol?) {
        feedLease = lease
        feedCancellable = publisher?
            .handleEvents(receiveCancel: {
                bridgeLog("Cancelled flowElement publisher")
            })
        
            .sink(receiveCompletion: { [weak self] completion in
                lease.release()
                self?.withCallbackStateLock {
                    guard self?.feedLease === lease else { return }
                    self?.feedLease = nil
                    self?.feedCancellable = nil
                    self?.inboundFeedCommandID = nil
                    self?.inboundFeedRequester = nil
                    self?.feedActive = false
                }
            }, receiveValue: { [weak self] flowElement in
                guard let self = self else {return}
                let reserved = self.withCallbackStateLock { () -> Bool in
                    guard self.queuedFeedDeliveries < 32 else { return false }
                    self.queuedFeedDeliveries += 1
                    return true
                }
                guard reserved else { generation.close(); return }
                do { try generation.acquire(.operation) }
                catch {
                    self.withCallbackStateLock { self.queuedFeedDeliveries -= 1 }
                    generation.close(); return
                }
                Task { [weak self] in
                    defer { generation.release(.operation) }
                    guard let self = self else { return }
                    defer { self.withCallbackStateLock { self.queuedFeedDeliveries -= 1 } }
                    guard self.withCallbackStateLock({
                        generation === self.channelSessionValue && self.feedLease === lease &&
                        self.inboundFeedCommandID == commandCid && (try? generation.check()) != nil
                    }) else { return }
                    let payload = ValueType.flowElement(flowElement)
                    let response = BridgeCommand(cmd: "response", payload: payload, cid: commandCid)
                    do {
                        if let responseJSONData = try? JSONEncoder().encode(response),
                           let transport {
                            
                            try await transport.sendData(responseJSONData)
                            self.connectionStateLock.withLock {
                                guard generation === self.channelSessionValue, self.feedLease === lease,
                                      self.inboundFeedCommandID == commandCid,
                                      (try? generation.check()) != nil else { return }
                                self.feedActive = true
                            }
                        }
                    } catch {
                        bridgeLog("Consume command \(commandCid) failed with error: code=operation_failed")
                    }
                }
            })
    }
    
    
    // This is the processing of responses of commands sent over the websocket
    public func consumeResponse(command: BridgeCommand) async throws {
        guard let channelSession else { throw BridgeChannelAuthentication.Failure.unavailable }
        try channelSession.checkInbound(command)
        bridgeLog("Consume response \(command.diagnosticMetadata)")

        guard let lookedUp = auditor.loadBridgeCommandForCommandId(command.cid) else {
            bridgeLog("Unmatched response code=unknown_cid \(command.diagnosticMetadata)")
            return
        }
        await afterResponseLookup?(lookedUp)
        try connectionStateLock.withLock {
            guard channelSession === channelSessionValue else { throw BridgeChannelAuthentication.Failure.staleGeneration }
            try channelSession.checkInbound(command)
            // Re-read the registered operation under the lifecycle lock. A copy
            // returned before retirement/timeout conveys no publication rights.
            guard let commandRequest = auditor.loadBridgeCommandForCommandId(command.cid) else { return }
            let retainCommandForStream = commandRequest.command == .feed
            if !retainCommandForStream { auditor.removeBridgeCommand(for: command.cid) }
            if !retainCommandForStream { identityProofAuthorization.complete(command.cid) }
            switch commandRequest.command {
            case .description:
                if let sentPayload = command.payload {
                    
                    switch sentPayload {
                    case let .description(value):
                        bridgeLog("Got description")
                        self.configure(from: value)
                        
                        
                    default:
                        bridgeLog("Bridge payload rejected code=expected_description \(command.diagnosticMetadata)")
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
                        bridgeLog("Bridge payload rejected code=expected_connect \(command.diagnosticMetadata)")
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
                        bridgeLog("Bridge payload rejected code=expected_contract \(command.diagnosticMetadata)")
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
                        bridgeLog("Bridge payload rejected code=expected_flow \(command.diagnosticMetadata)")
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
                if let sentPayload = command.payload {
                    takeValuePromise(for: command.cid)?(.success(sentPayload))
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
                bridgeLog("Response did not match request \(commandRequest.diagnosticMetadata)")
            }

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
    
    /// A late callback from a retired socket cannot invalidate its replacement.
    func channelDidClose(_ session: BridgeChannelSession) async {
        connectionStateLock.withLock {
            guard channelSessionValue === session else { return }
            session.close()
            failPendingChannelWork()
        }
    }

    /// Ends one logical channel without revoking sibling channels on its socket.
    func retireLogicalChannel() async {
        connectionStateLock.withLock {
            failPendingChannelWork()
            channelSessionValue = nil
            transportValue = nil
        }
    }

    private func failPendingChannelWork() {
        connectionStateLock.withLock {
            ready = false
            identityProofAuthorization.reset()
            feedCancellable?.cancel(); feedCancellable = nil
            feedLease?.release(); feedLease = nil
            flowElementCallbackCancellable?.cancel(); flowElementCallbackCancellable = nil
            outboundFeedStartTask?.cancel()
            let requests = withCallbackStateLock { () -> [SignRequest] in
                let requests = Array(signCallbackRequests.values)
                signCallbackRequests.removeAll()
                return requests
            }
            for request in requests { request.cleanupTask?.cancel(); request.promise(.failure(BridgeChannelAuthentication.Failure.closed)) }
            let failPending: [() -> Void] = withCallbackStateLock {
                let failure = BridgeChannelAuthentication.Failure.closed
                var callbacks: [() -> Void] = []
                for promise in connectCallbackPromises.values { callbacks.append { promise(.failure(failure)) } }
                for promise in contractCallbackPromises.values { callbacks.append { promise(.failure(failure)) } }
                for subject in connectCallbackDataPublishers.values { callbacks.append { subject.send(completion: .failure(failure)) } }
                for subject in contractCallbackDataPublishers.values { callbacks.append { subject.send(completion: .failure(failure)) } }
                for promise in valuePromises.values { callbacks.append { promise(.failure(failure)) } }
                for subject in setValueForKeyCallbackDataPublishers.values { callbacks.append { subject.send(completion: .failure(failure)) } }
                for subject in setValueForKeypathCallbackDataPublishers.values { callbacks.append { subject.send(completion: .failure(failure)) } }
                connectCallbackPromises.removeAll(); contractCallbackPromises.removeAll()
                connectCallbackDataPublishers.removeAll(); contractCallbackDataPublishers.removeAll()
                valuePromises.removeAll(); setValueForKeyCallbackDataPublishers.removeAll()
                setValueForKeypathCallbackDataPublishers.removeAll()
                inboundFeedCommandID = nil; inboundFeedRequester = nil; feedActive = false
                return callbacks
            }
            failPending.forEach { $0() }
            descriptionFetchedPublisher.send(completion: .failure(BridgeChannelAuthentication.Failure.closed))
            readyPublisher.send(completion: .failure(BridgeChannelAuthentication.Failure.closed))
            feedPublisher2.send(completion: .failure(BridgeChannelAuthentication.Failure.closed))
            auditor.clear()
        }
    }

    public func pushError(errorMessage: String?, error: Error?) async {
        let legacyUUID: String? = connectionStateLock.withLock {
            let legacy = channelSessionValue == nil
            channelSessionValue?.close()
            failPendingChannelWork()
            if let errorMessage {
                flowElementCallbackDataPublisher.send(FlowElement(title: "Bridge error", content: .string(errorMessage),
                    properties: FlowElement.Properties(type: .alert, contentType: .string)))
            }
            if let error {
                let event: Object = ["type": .string("closing"), "origin": .string(uuid)]
                flowElementCallbackDataPublisher.send(FlowElement(title: "closing", content: .object(event),
                    properties: FlowElement.Properties(type: .event, contentType: .object)))
                flowElementCallbackDataPublisher.send(completion: .failure(error))
            }
            return legacy && error != nil ? uuid : nil
        }
        if let legacyUUID, let resolver = CellBase.defaultCellResolver { await resolver.unregisterEmitCell(uuid: legacyUUID) }
    }

    public func attachedStatus(for label: String, requester: Identity) async throws -> ConnectionStatus {
        bridgeLog("Bridge base attachedStatus")
        return ConnectionStatus(name: "Not implemented", connected: true, active: true)
    }
    
    public func attachedStatuses(requester: Identity) async throws -> [ConnectionStatus] {
        bridgeLog("Bridge base attachedStatuses")
        return [ConnectionStatus]()
    }
    
}
