// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

// helper Cell used in resolver when calling pushFlowElement()
public class FlowElementPusherCell: Emit {
    public func getOwner(requester: Identity) async throws -> Identity {
        return self.owner
    }
    
    public func getEmitterWithUUID(_ uuid: String, requester: Identity) async -> (any Emit)? {
        return nil
    }
    
    
    
    public func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, any Error> {
        feedPublisher.eraseToAnyPublisher()
    }
    public func state(requester: Identity) async throws -> ValueType {
        return .string("not implemented")
    }
    public var cellScope: CellUsageScope = .template
    
    public var persistancy: Persistancy = .ephemeral
    
   
    


    
    
    public func close(requester: Identity) {
        //closing... clean up!
    }
    
    let owner: Identity
    public let uuid = UUID().uuidString
    public let identityDomain = "private"
    public var agreementTemplate: Agreement
    
    var feedPublisher = PassthroughSubject<FlowElement, Error>()
    
    public init(owner: Identity) {
        self.owner = owner
        self.agreementTemplate = Agreement(owner: owner)
    }
    
    public func startFeed(requester: Identity) {
    }
    
    public func getFeedPublisher() -> AnyPublisher<FlowElement, Error> {
        feedPublisher.eraseToAnyPublisher()
    }
    
    public func flow() async throws -> AnyPublisher<FlowElement, any Error> {
        feedPublisher.eraseToAnyPublisher()
    }
    
    public func admit(context: ConnectContext) async -> ConnectState {
        return .connected
    }
    
    func connect(context: ConnectContext) -> AnyPublisher<ConnectState, Error> {
        let connectPublisher = PassthroughSubject<ConnectState, Error>()
        Task {
            if self.owner == context.identity {
                connectPublisher.send(.connected)
                connectPublisher.send(completion: .finished)
            }
        }
        
        return connectPublisher.eraseToAnyPublisher()
    }
    
    public func addAgreement(_ contract: Agreement, for identity: Identity) async -> AgreementState {
        return .signed
    }
    
    func addContract(_ contract: Agreement, for identity: Identity) -> AnyPublisher<AgreementState, Error> {
        let addContractPublisher = PassthroughSubject<AgreementState, Error>()
        
        
        return addContractPublisher.eraseToAnyPublisher()
    }
    
    public func advertise(for identity: Identity) async -> AnyCell {
        return await AnyCell(uuid: self.uuid, name: "pusher", contractTemplate: Agreement(), owner: self.owner, experiences: nil, feedEndpoint: nil, feedProperties: nil, identityDomain: "private")
    }

    public func pushFlowElement(_ flowElement: FlowElement, requester: Identity) {
        self.feedPublisher.send(flowElement)
    }
    
    public func pushCompletion(error: Error?, requester: Identity) {
        if error == nil {
            self.feedPublisher.send(completion: .finished)
        } else {
            self.feedPublisher.send(completion: .failure(error!))
        }
    }
    
}
