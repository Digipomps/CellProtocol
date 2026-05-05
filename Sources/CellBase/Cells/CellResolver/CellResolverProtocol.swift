// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

public protocol CellResolverProtocol {
    
    func cellAtEndpoint(endpoint: String, requester: Identity) async throws -> Emit
    func loadCell(from experienceTemplate: CellConfiguration, into sourceCellClient: Absorb, requester: Identity) async throws -> [Emit]
    
    func registerNamedEmitCell(name: String, emitCell: Emit, scope: CellUsageScope, identity: Identity) async throws
    func unregisterEmitCell(uuid: String) async
    
    func registerTransport(_ transportType: BridgeTransportProtocol.Type, for scheme: String) async throws
    func registerRemoteCellHost(_ host: String, route: RemoteCellHostRoute)
    func unregisterRemoteCellHost(_ host: String)
    func remoteCellHostRoutesSnapshot() -> [String: RemoteCellHostRoute]
    
    func logAction(context: ConnectContext, action: String, param: String)
    func logReference(emitter: Emit)
    
    
    func cellUUID(for name: String) async -> String? // These should be subject of permissions too?
    func namedCell(for uuid: String) async -> String?
    func namedCells(requester: Identity) async -> [String: String]
    func setNamedCells(_ namedCells: [String : String], requester: Identity) async
    func identityNamedCells(requester: Identity) async -> [String : [String : String]]
    func resolverRegistrySnapshot(requester: Identity) async -> CellResolverRegistrySnapshot
    func setResolverEmitter(_ emitter: FlowElementPusherCell, requester: Identity) async  throws
    func setIdentityNamedCells(_ identityNamedCells: [String : [String : String]], requester: Identity) async
    
    func get(from url: URL, requester: Identity) async throws -> ValueType?
    func set(value: ValueType, into url: URL, requester: Identity) async throws -> ValueType?
}
