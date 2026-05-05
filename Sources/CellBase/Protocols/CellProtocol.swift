// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

public protocol CellProtocol: Absorb, Emit, Meddle, Explore, GroupProtocol {}

public protocol Absorb {
    func attach(emitter: Emit, label: String, requester: Identity) async throws -> ConnectState
    func absorbFlow(label: String, requester: Identity) async throws// gets the labeled cell publishers feed publisher and start responding to it
    func detach(label: String, requester: Identity)
    func dropFlow(label: String, requester: Identity)
    func dropAllFlows(requester: Identity)
    func detachAll(requester: Identity)
    func attachedStatus(for label: String, requester: Identity) async throws -> ConnectionStatus
    func attachedStatuses(requester: Identity) async throws -> [ConnectionStatus]
}

public protocol Emit: AnyObject {
    
    func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, Error>
    
    func admit(context: ConnectContext) async -> ConnectState 
    func close(requester: Identity)
    func addAgreement(_ contract: Agreement, for identity: Identity) async throws -> AgreementState
    func advertise(for requester: Identity) async -> AnyCell
    func state(requester: Identity) async throws -> ValueType
    var uuid: String { get }
    var agreementTemplate: Agreement { get set } // Must be protected with access control
    var identityDomain: String { get }
    var cellScope: CellUsageScope { get set } // Must be protected with access control
    var persistancy: Persistancy { get set }
    func getOwner(requester: Identity) async throws -> Identity
    func getEmitterWithUUID(_ uuid: String, requester: Identity) async -> Emit?
    
}

//public protocol Lookupable {
//    func valueForKey(key: String, requester: Identity) async throws -> ValueType
//    func setValueForKey(key: String, value: AnyPublisher<ValueType, Never>, requester: Identity) -> AnyPublisher<SetValueState, Error>
//}

public protocol Meddle {
    func get(keypath: String, requester: Identity) async throws -> ValueType
    func set(keypath: String, value: ValueType, requester: Identity) async throws -> ValueType?
}



public protocol Explore {
    func keys(requester: Identity) async throws -> [String]
    func typeForKey(key: String, requester: Identity) async throws -> ValueType
}

public protocol GroupProtocol {
    func isMember(identity: Identity, requester: Identity) async -> Bool
}
