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
    
    

    private var contracts = [Agreement]()
    func loadContracts() -> [Agreement] {
        return contracts
    }
    func addContract(_ contract: Agreement) {
        contracts.append(contract)
    }
    func removeContract(contract: Agreement) {
        contracts.removeAll(where: { storedContract in
            storedContract.uuid == contract.uuid
        })
    }
    
    private var members = [Identity]()
    
    func loadMembers() -> [Identity] {
        return members
    }
    func addMember(_ member: Identity) {
        members.append(member)
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
