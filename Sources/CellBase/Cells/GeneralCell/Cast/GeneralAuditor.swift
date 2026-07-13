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


actor GeneralAuditor {
    typealias AuthorizationSnapshot = (revision: Int, contracts: [Contract], members: [Identity])
    private var subscribedFeeds: [String: AnyPublisher<FlowElement, Error>] = [:]
    private var feedCancellables: [String: AnyCancellable] = [:]
    private var connectedCellEmitters: [String: Emit] = [:]
    private var admissionSessionsByLabel: [String: AdmissionSession] = [:]
    private var admissionTargetsByLabel: [String: Emit] = [:]
    
    private var setValueForKeyPublisher: PassthroughSubject<SetValueState, Error>?
    
    func loadSubscribedFeedsForLabel(_ label: String) -> AnyPublisher<FlowElement, Error>? {
        return subscribedFeeds[label]
    }
    func storeSubscribedFeedForLabel(label: String, subscribedFeed: AnyPublisher<FlowElement, Error>?) {
        subscribedFeeds[label] = subscribedFeed
    }
    
    func loadFeedCancellablesForLabel(_ label: String) -> AnyCancellable? {
        return feedCancellables[label]
    }
    func storeFeedCancellablesForLabel(label: String, feedCancellable: AnyCancellable?) {
        feedCancellables[label] = feedCancellable
    }
    
    func getSetValueForKeyPulisher() -> PassthroughSubject<SetValueState, Error> {
        setValueForKeyPublisher = PassthroughSubject<SetValueState, Error>()
        return setValueForKeyPublisher!
    }
    
    func loadConnectedCellEmitterForLabel(_ label: String) -> Emit? {
        return connectedCellEmitters[label]
    }
    func storeConnectedCellEmitterForLabel(label: String, emitter: Emit?) {
        connectedCellEmitters[label] = emitter
    }
    func connectedLabels() -> [String] {
        return Array(connectedCellEmitters.keys)
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
        let state = "connectedCellPublishers: \(connectedCellEmitters) subscribedFeeds: \(subscribedFeeds) members: \(members) admissionSessions: \(admissionSessionsByLabel) admissionTargets: \(admissionTargetsByLabel)"
        return state
    }
}
