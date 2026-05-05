// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@testable import CellBase

final class MockCellResolver: CellResolverProtocol {
    enum ResolverError: Error {
        case notFound
    }

    private var emitByEndpoint: [String: Emit] = [:]
    private var emitByUUID: [String: Emit] = [:]
    private var nameByUUID: [String: String] = [:]
    private var uuidByName: [String: String] = [:]
    private var namedCellsByIdentity: [String: [String: String]] = [:]
    private var transportsByScheme: [String: BridgeTransportProtocol.Type] = [:]
    private var remoteCellHostRoutes: [String: RemoteCellHostRoute] = [:]
    private var valuesByURL: [String: ValueType] = [:]
    private var resolverEmitter: FlowElementPusherCell?
    private var resolveSnapshots: [String: CellResolverResolveSnapshot] = [:]
    private var unregisteredUUIDs: [String] = []

    func cellAtEndpoint(endpoint: String, requester: Identity) async throws -> Emit {
        let normalized = endpoint.hasPrefix("cell:///") ? String(endpoint.dropFirst("cell:///".count)) : endpoint
        if let uuid = namedCellsByIdentity[requester.uuid]?[normalized],
           let emit = emitByUUID[uuid] {
            return emit
        }
        if let emit = emitByEndpoint[endpoint] {
            return emit
        }
        throw ResolverError.notFound
    }

    func loadCell(from experienceTemplate: CellConfiguration, into sourceCellClient: Absorb, requester: Identity) async throws -> [Emit] {
        return []
    }

    func registerNamedEmitCell(name: String, emitCell: Emit, scope: CellUsageScope, identity: Identity) async throws {
        emitByUUID[emitCell.uuid] = emitCell
        nameByUUID[emitCell.uuid] = name
        switch scope {
        case .identityUnique:
            var named = namedCellsByIdentity[identity.uuid] ?? [:]
            named[name] = emitCell.uuid
            namedCellsByIdentity[identity.uuid] = named
        case .template, .scaffoldUnique:
            emitByEndpoint["cell:///\(name)"] = emitCell
            uuidByName[name] = emitCell.uuid
        }
    }

    func unregisterEmitCell(uuid: String) async {
        unregisteredUUIDs.append(uuid)
        if let name = nameByUUID[uuid] {
            emitByEndpoint.removeValue(forKey: "cell:///\(name)")
            emitByUUID.removeValue(forKey: uuid)
            uuidByName.removeValue(forKey: name)
            nameByUUID.removeValue(forKey: uuid)
            for identityUUID in namedCellsByIdentity.keys {
                namedCellsByIdentity[identityUUID]?[name] = nil
            }
        }
    }

    func unregisteredUUIDsSnapshot() -> [String] {
        unregisteredUUIDs
    }

    func registerTransport(_ transportType: BridgeTransportProtocol.Type, for scheme: String) async throws {
        transportsByScheme[scheme] = transportType
    }

    func registeredTransportType(for scheme: String) -> BridgeTransportProtocol.Type? {
        transportsByScheme[scheme]
    }

    func registerRemoteCellHost(_ host: String, route: RemoteCellHostRoute) {
        remoteCellHostRoutes[host.lowercased()] = route
    }

    func unregisterRemoteCellHost(_ host: String) {
        remoteCellHostRoutes.removeValue(forKey: host.lowercased())
    }

    func remoteCellHostRoutesSnapshot() -> [String : RemoteCellHostRoute] {
        remoteCellHostRoutes
    }

    func logAction(context: ConnectContext, action: String, param: String) {
        // no-op for tests
    }

    func logReference(emitter: Emit) {
        // no-op for tests
    }

    func cellUUID(for name: String) async -> String? {
        return uuidByName[name]
    }

    func namedCell(for uuid: String) async -> String? {
        return nameByUUID[uuid]
    }

    func namedCells(requester: Identity) async -> [String: String] {
        return uuidByName
    }

    func setNamedCells(_ namedCells: [String : String], requester: Identity) async {
        uuidByName = namedCells
        nameByUUID = Dictionary(uniqueKeysWithValues: namedCells.map { ($1, $0) })
    }

    func identityNamedCells(requester: Identity) async -> [String : [String : String]] {
        return namedCellsByIdentity
    }

    func resolverRegistrySnapshot(requester: Identity) async -> CellResolverRegistrySnapshot {
        let sharedNamedInstances = uuidByName.map { name, uuid in
            CellResolverNamedInstanceSnapshot(name: name, uuid: uuid)
        }
        let identityNamedInstances = namedCellsByIdentity.flatMap { identityUUID, named in
            named.map { name, uuid in
                CellResolverNamedInstanceSnapshot(name: name, uuid: uuid, identityUUID: identityUUID)
            }
        }
        return CellResolverRegistrySnapshot(
            resolves: Array(resolveSnapshots.values),
            sharedNamedInstances: sharedNamedInstances,
            identityNamedInstances: identityNamedInstances
        )
    }

    func setResolverEmitter(_ emitter: FlowElementPusherCell, requester: Identity) async throws {
        resolverEmitter = emitter
    }

    func setIdentityNamedCells(_ identityNamedCells: [String : [String : String]], requester: Identity) async {
        namedCellsByIdentity = identityNamedCells
    }

    func setResolveSnapshot(_ snapshot: CellResolverResolveSnapshot) {
        resolveSnapshots[snapshot.name] = snapshot
    }

    func get(from url: URL, requester: Identity) async throws -> ValueType? {
        return valuesByURL[url.absoluteString]
    }

    func set(value: ValueType, into url: URL, requester: Identity) async throws -> ValueType? {
        valuesByURL[url.absoluteString] = value
        return value
    }
}
