// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

/// Ephemeral process-local producer used by trusted resolver/runtime code.
/// Its capability is the exact owner object passed at construction, not a
/// serializable Identity claim. Use GeneralCell for remotely accessible feeds.
public class FlowElementPusherCell: Emit {
    public enum AccessError: Error { case localOwnerRequired }
    public func getOwner(requester: Identity) async throws -> Identity {
        _ = requester
        return owner.publicIdentitySnapshot()
    }
    
    public func getEmitterWithUUID(_ uuid: String, requester: Identity) async -> (any Emit)? {
        return nil
    }
    
    
    
    public func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, any Error> {
        guard requester === owner else { throw AccessError.localOwnerRequired }
        return feedPublisher.eraseToAnyPublisher()
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
    
    /// Unchecked producer access for trusted host composition only.
    public func getFeedPublisher() -> AnyPublisher<FlowElement, Error> {
        feedPublisher.eraseToAnyPublisher()
    }
    
    /// Legacy unchecked producer access for trusted host composition only.
    public func flow() async throws -> AnyPublisher<FlowElement, any Error> {
        feedPublisher.eraseToAnyPublisher()
    }
    
    public func admit(context: ConnectContext) async -> ConnectState {
        return context.identity === owner ? .connected : .denied
    }
    
    func connect(context: ConnectContext) -> AnyPublisher<ConnectState, Error> {
        Just(context.identity === owner ? ConnectState.connected : .denied)
            .setFailureType(to: Error.self).eraseToAnyPublisher()
    }
    
    public func addAgreement(_ contract: Agreement, for identity: Identity) async -> AgreementState {
        // This local helper neither negotiates nor signs Contracts.
        return .rejected
    }
    
    func addContract(_ contract: Agreement, for identity: Identity) -> AnyPublisher<AgreementState, Error> {
        Just(AgreementState.rejected).setFailureType(to: Error.self).eraseToAnyPublisher()
    }
    
    public func advertise(for identity: Identity) async -> AnyCell {
        return await AnyCell(uuid: self.uuid, name: "pusher", contractTemplate: Agreement(), owner: self.owner, experiences: nil, feedEndpoint: nil, feedProperties: nil, identityDomain: "private")
    }

    public func pushFlowElement(_ flowElement: FlowElement, requester: Identity) {
        guard requester === owner else { return }
        self.feedPublisher.send(flowElement)
    }
    
    public func pushCompletion(error: Error?, requester: Identity) {
        guard requester === owner else { return }
        if error == nil {
            self.feedPublisher.send(completion: .finished)
        } else {
            self.feedPublisher.send(completion: .failure(error!))
        }
    }
    
}
