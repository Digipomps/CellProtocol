// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 26/11/2022.
//

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

enum FlowSubscriptionStart {
    case ready(id: String, emitter: Emit, flight: FlowSubscriptionFlight)
    case pending(FlowSubscriptionFlight)
    case active
    case noEmitter
}

enum FlowSubscriptionEvent {
    case value(FlowElement)
    case completion
}

final class FlowSubscriptionFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var resolution: Result<Void, Error>?
    private var waiters = [CheckedContinuation<Void, Error>]()

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let resolution {
                lock.unlock()
                resume(continuation, with: resolution)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        guard resolution == nil else {
            lock.unlock()
            return
        }
        resolution = result
        let continuations = waiters
        waiters.removeAll()
        lock.unlock()
        continuations.forEach { resume($0, with: result) }
    }

    private func resume(
        _ continuation: CheckedContinuation<Void, Error>,
        with result: Result<Void, Error>
    ) {
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private final class FlowSubscriptionCancellationPayload: @unchecked Sendable {
    let continuation: AsyncStream<FlowSubscriptionEvent>.Continuation?
    let processor: Task<Void, Never>?
    let cancellable: AnyCancellable?

    init(
        continuation: AsyncStream<FlowSubscriptionEvent>.Continuation?,
        processor: Task<Void, Never>?,
        cancellable: AnyCancellable?
    ) {
        self.continuation = continuation
        self.processor = processor
        self.cancellable = cancellable
    }

    func cancel() {
        continuation?.finish()
        processor?.cancel()
        cancellable?.cancel()
    }
}

private final class FlowSubscriptionResources: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<FlowSubscriptionEvent>.Continuation?
    private var processor: Task<Void, Never>?
    private var cancellable: AnyCancellable?
    private let overflowState: FlowBufferOverflowState

    init(
        continuation: AsyncStream<FlowSubscriptionEvent>.Continuation,
        processor: Task<Void, Never>,
        cancellable: AnyCancellable,
        overflowState: FlowBufferOverflowState
    ) {
        self.continuation = continuation
        self.processor = processor
        self.cancellable = cancellable
        self.overflowState = overflowState
    }

    func hasOverflowed() -> Bool {
        overflowState.didOverflow()
    }

    func beginInvalidation() {
        overflowState.invalidate()
    }

    func waitForForwardingToDrain() async {
        await overflowState.waitForForwardReservationsToDrain()
    }

    func finishExternalCancellation() async {
        let payload = takeCancellationPayload()
        if let payload {
            await Task.detached {
                payload.cancel()
            }.value
        }
    }

    private func takeCancellationPayload() -> FlowSubscriptionCancellationPayload? {
        lock.lock()
        guard continuation != nil || processor != nil || cancellable != nil else {
            lock.unlock()
            return nil
        }
        let payload = FlowSubscriptionCancellationPayload(
            continuation: continuation,
            processor: processor,
            cancellable: cancellable
        )
        self.continuation = nil
        self.processor = nil
        self.cancellable = nil
        lock.unlock()
        return payload
    }

    deinit {
        beginInvalidation()
        guard let payload = takeCancellationPayload() else { return }
        Task.detached {
            payload.cancel()
        }
    }
}

actor GeneralAuditor {
    typealias AuthorizationSnapshot = (revision: Int, contracts: [Contract], members: [Identity])
    private var subscribedFeeds: [String: AnyPublisher<FlowElement, Error>] = [:]
    private var pendingFlowSubscriptionIDs: [String: String] = [:]
    private var pendingFlowSubscriptionFlights: [String: FlowSubscriptionFlight] = [:]
    private var activeFlowSubscriptionIDs: [String: String] = [:]
    private var flowSubscriptionResources: [String: FlowSubscriptionResources] = [:]
    private var connectedCellEmitters: [String: Emit] = [:]
    private var admissionSessionsByLabel: [String: AdmissionSession] = [:]
    private var admissionTargetsByLabel: [String: Emit] = [:]
    
    private var setValueForKeyPublisher: PassthroughSubject<SetValueState, Error>?
    
    func loadSubscribedFeedsForLabel(_ label: String) -> AnyPublisher<FlowElement, Error>? {
        return subscribedFeeds[label]
    }

    func beginFlowSubscription(for label: String) async -> FlowSubscriptionStart {
        if flowSubscriptionResources[label]?.hasOverflowed() == true {
            await clearFlowSubscription(
                for: label,
                pendingError: GeneralCellErrors.flowBufferOverflow
            )
        }
        guard let emitter = connectedCellEmitters[label] else {
            return .noEmitter
        }
        if let pendingFlight = pendingFlowSubscriptionFlights[label] {
            return .pending(pendingFlight)
        }
        guard subscribedFeeds[label] == nil,
              flowSubscriptionResources[label] == nil,
              activeFlowSubscriptionIDs[label] == nil else {
            return .active
        }
        let id = UUID().uuidString
        let flight = FlowSubscriptionFlight()
        pendingFlowSubscriptionIDs[label] = id
        pendingFlowSubscriptionFlights[label] = flight
        return .ready(id: id, emitter: emitter, flight: flight)
    }

    func isFlowSubscriptionCurrent(
        label: String,
        id: String,
        emitterUUID: String
    ) -> Bool {
        guard connectedCellEmitters[label]?.uuid == emitterUUID else {
            return false
        }
        return pendingFlowSubscriptionIDs[label] == id ||
            activeFlowSubscriptionIDs[label] == id
    }

    func installFlowSubscription(
        for label: String,
        id: String,
        emitterUUID: String,
        subscribedFeed: AnyPublisher<FlowElement, Error>,
        feedCancellable: AnyCancellable,
        eventProcessor: Task<Void, Never>,
        eventContinuation: AsyncStream<FlowSubscriptionEvent>.Continuation,
        overflowState: FlowBufferOverflowState
    ) async -> Bool {
        let resources = FlowSubscriptionResources(
            continuation: eventContinuation,
            processor: eventProcessor,
            cancellable: feedCancellable,
            overflowState: overflowState
        )
        guard pendingFlowSubscriptionIDs[label] == id,
              connectedCellEmitters[label]?.uuid == emitterUUID else {
            if pendingFlowSubscriptionIDs[label] == id {
                pendingFlowSubscriptionIDs.removeValue(forKey: label)
                pendingFlowSubscriptionFlights.removeValue(forKey: label)?.resolve(
                    .failure(CancellationError())
                )
            }
            resources.beginInvalidation()
            await resources.finishExternalCancellation()
            return false
        }
        let installed = overflowState.performIfNotOverflowed {
            subscribedFeeds[label] = subscribedFeed
            flowSubscriptionResources[label] = resources
            pendingFlowSubscriptionIDs.removeValue(forKey: label)
            let pendingFlight = pendingFlowSubscriptionFlights.removeValue(forKey: label)
            activeFlowSubscriptionIDs[label] = id
            pendingFlight?.resolve(.success(()))
        }
        guard installed else {
            pendingFlowSubscriptionIDs.removeValue(forKey: label)
            pendingFlowSubscriptionFlights.removeValue(forKey: label)?.resolve(
                .failure(GeneralCellErrors.flowBufferOverflow)
            )
            resources.beginInvalidation()
            await resources.finishExternalCancellation()
            return false
        }
        return true
    }

    func reserveFlowElementForwardIfCurrent(
        label: String,
        id: String,
        emitterUUID: String,
        overflowState: FlowBufferOverflowState
    ) -> FlowForwardReservation? {
        guard isFlowSubscriptionCurrent(
            label: label,
            id: id,
            emitterUUID: emitterUUID
        ) else {
            return nil
        }
        return overflowState.reserveForwardIfNotOverflowed()
    }

    func completeFlowSubscription(
        for label: String,
        id: String,
        emitterUUID: String
    ) async {
        guard isFlowSubscriptionCurrent(
            label: label,
            id: id,
            emitterUUID: emitterUUID
        ) else {
            return
        }
        await clearFlowSubscription(for: label)
    }

    func invalidateFlowSubscriptionAfterOverflow(
        label: String,
        id: String,
        emitterUUID: String
    ) async {
        guard isFlowSubscriptionCurrent(
            label: label,
            id: id,
            emitterUUID: emitterUUID
        ) else {
            return
        }
        await clearFlowSubscription(
            for: label,
            pendingError: GeneralCellErrors.flowBufferOverflow
        )
    }

    func cancelFlowSubscription(
        for label: String,
        pendingID: String? = nil,
        pendingError: Error = CancellationError()
    ) async {
        if let pendingID,
           pendingFlowSubscriptionIDs[label] != pendingID {
            return
        }
        await clearFlowSubscription(for: label, pendingError: pendingError)
    }

    private func clearFlowSubscription(
        for label: String,
        pendingError: Error = CancellationError()
    ) async {
        pendingFlowSubscriptionIDs.removeValue(forKey: label)
        let pendingFlight = pendingFlowSubscriptionFlights.removeValue(forKey: label)
        activeFlowSubscriptionIDs.removeValue(forKey: label)
        subscribedFeeds.removeValue(forKey: label)
        let resources = flowSubscriptionResources.removeValue(forKey: label)
        pendingFlight?.resolve(.failure(pendingError))
        guard let resources else { return }

        resources.beginInvalidation()
        let externalCancellation = Task.detached {
            await resources.finishExternalCancellation()
        }
        await resources.waitForForwardingToDrain()
        await externalCancellation.value
    }
    
    func getSetValueForKeyPulisher() -> PassthroughSubject<SetValueState, Error> {
        setValueForKeyPublisher = PassthroughSubject<SetValueState, Error>()
        return setValueForKeyPublisher!
    }
    
    func loadConnectedCellEmitterForLabel(_ label: String) -> Emit? {
        return connectedCellEmitters[label]
    }

    func connectEmitter(_ emitter: Emit, for label: String) async {
        let emitterChanged = connectedCellEmitters[label].map {
            ObjectIdentifier($0) != ObjectIdentifier(emitter)
        } ?? true
        connectedCellEmitters[label] = emitter
        if emitterChanged {
            await clearFlowSubscription(for: label)
        }
    }

    func disconnectEmitter(for label: String) async {
        connectedCellEmitters.removeValue(forKey: label)
        await clearFlowSubscription(for: label)
    }

    func connectedLabels() -> [String] {
        return connectedCellEmitters.keys.sorted()
    }
    
    func connectedEmitter(for uuid: String) -> Emit? {
        var emitter: Emit?
        for currentEmitter in connectedCellEmitters.values {
            if currentEmitter.uuid == uuid {
                emitter = currentEmitter
                break
            }
        }
        return emitter
    }
    func connectedLabel(for uuid: String) -> String? {
        var label: String?
        for (currentLabel, currentEmitter) in connectedCellEmitters {
            if currentEmitter.uuid == uuid {
                label = currentLabel
                break
            }
        }
        return label
    }

    func loadAdmissionSessionForLabel(_ label: String) -> AdmissionSession? {
        admissionSessionsByLabel[label]
    }

    func loadAdmissionSession(id: String) -> AdmissionSession? {
        admissionSessionsByLabel.values.first(where: { $0.id == id })
    }

    func loadAdmissionSessions() -> [AdmissionSession] {
        Array(admissionSessionsByLabel.values)
    }

    func storeAdmissionSession(_ session: AdmissionSession) {
        admissionSessionsByLabel[session.label] = session
    }

    func storeAdmissionTarget(_ target: Emit, for label: String) {
        admissionTargetsByLabel[label] = target
    }

    func loadAdmissionTargetForLabel(_ label: String) -> Emit? {
        admissionTargetsByLabel[label]
    }

    func removeAdmissionSessionForLabel(_ label: String) {
        admissionSessionsByLabel.removeValue(forKey: label)
        admissionTargetsByLabel.removeValue(forKey: label)
    }
    
    

    private var contracts = [Contract]()
    private var authorizationRevision = 0
    func loadContracts() -> [Contract] {
        return contracts
    }
    func addContract(_ contract: Contract) {
        contracts.removeAll(where: {
            $0.uuid == contract.uuid ||
                $0.authorizationDeduplicationKey == contract.authorizationDeduplicationKey
        })
        contracts.append(contract)
    }
    func replaceContracts(_ contracts: [Contract]) {
        self.contracts = contracts
    }
    func removeContract(contract: Contract) {
        contracts.removeAll(where: { storedContract in
            storedContract.uuid == contract.uuid
        })
    }

    func removeContracts(subjectUUID: String) {
        contracts.removeAll { $0.subject.uuid == subjectUUID }
    }
    
    private var members = [Identity]()

    func installAuthorization(
        contract: Contract,
        member: Identity,
        restoring persisted: AuthorizationSnapshot
    ) -> AuthorizationSnapshot {
        hydrateAuthorizationIfEmpty(from: persisted)
        addContract(contract)
        addMember(member)
        authorizationRevision += 1
        return authorizationSnapshot()
    }

    func removeAuthorization(
        subjectUUID: String,
        restoring persisted: AuthorizationSnapshot
    ) -> AuthorizationSnapshot {
        hydrateAuthorizationIfEmpty(from: persisted)
        contracts.removeAll { $0.subject.uuid == subjectUUID }
        members.removeAll { $0.uuid == subjectUUID }
        authorizationRevision += 1
        return authorizationSnapshot()
    }

    func replaceAuthorization(
        contracts: [Contract],
        members: [Identity],
        revision: Int
    ) -> AuthorizationSnapshot {
        guard revision >= authorizationRevision else {
            return authorizationSnapshot()
        }
        self.contracts = contracts
        self.members = members
        authorizationRevision = max(authorizationRevision, revision)
        return authorizationSnapshot()
    }

    private func hydrateAuthorizationIfEmpty(from persisted: AuthorizationSnapshot) {
        guard contracts.isEmpty,
              members.isEmpty,
              authorizationRevision == 0,
              persisted.revision >= authorizationRevision,
              persisted.contracts.isEmpty == false || persisted.members.isEmpty == false else {
            return
        }
        contracts = persisted.contracts
        members = persisted.members
        authorizationRevision = max(authorizationRevision, persisted.revision)
    }

    func authorizationSnapshot() -> AuthorizationSnapshot {
        (authorizationRevision, contracts, members)
    }
    
    func loadMembers() -> [Identity] {
        return members
    }
    func addMember(_ member: Identity) {
        members.removeAll(where: { storedMember in
            storedMember.uuid == member.uuid
        })
        members.append(member)
    }
    func replaceMembers(_ members: [Identity]) {
        self.members = members
    }
    func removeMember(_ member: Identity) {
        members.removeAll(where: { storedMember in
            storedMember == member
        })
    }
    func removeMember(_ uuid: String) {
        members.removeAll(where: { storedMember in
            storedMember.uuid == uuid
        })
    }
    

    
    func auditorState() -> String {
        let state = "connectedCellPublishers: \(connectedCellEmitters) subscribedFeeds: \(subscribedFeeds) pendingFlowSubscriptionIDs: \(pendingFlowSubscriptionIDs) activeFlowSubscriptionIDs: \(activeFlowSubscriptionIDs) members: \(members) admissionSessions: \(admissionSessionsByLabel) admissionTargets: \(admissionTargetsByLabel)"
        return state
    }
}
