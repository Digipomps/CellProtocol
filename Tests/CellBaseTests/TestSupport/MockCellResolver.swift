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

    // Scanner retires sibling channels concurrently; registry access must match.
    private let stateLock = NSLock()
    private var lookupCount = 0
    func lookupCountSnapshot() -> Int { stateLock.withLock { lookupCount } }

    func cellAtEndpoint(endpoint: String, requester: Identity) async throws -> Emit {
        try stateLock.withLock {
            lookupCount += 1
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
    }

    func loadCell(from experienceTemplate: CellConfiguration, into sourceCellClient: Absorb, requester: Identity) async throws -> [Emit] {
        return []
    }

    func registerNamedEmitCell(name: String, emitCell: Emit, scope: CellUsageScope, identity: Identity) async throws {
        stateLock.withLock {
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
    }

    func unregisterEmitCell(uuid: String) async {
        stateLock.withLock {
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
    }

    func unregisteredUUIDsSnapshot() -> [String] {
        stateLock.withLock {
            unregisteredUUIDs
        }
    }

    func registerTransport(_ transportType: BridgeTransportProtocol.Type, for scheme: String) async throws {
        stateLock.withLock {
            transportsByScheme[scheme] = transportType
        }
    }

    func registeredTransportType(for scheme: String) -> BridgeTransportProtocol.Type? {
        stateLock.withLock {
            transportsByScheme[scheme]
        }
    }

    func registerRemoteCellHost(_ host: String, route: RemoteCellHostRoute) {
        stateLock.withLock {
            remoteCellHostRoutes[host.lowercased()] = route
        }
    }

    func unregisterRemoteCellHost(_ host: String) {
        _ = stateLock.withLock {
            remoteCellHostRoutes.removeValue(forKey: host.lowercased())
        }
    }

    func remoteCellHostRoutesSnapshot() -> [String : RemoteCellHostRoute] {
        stateLock.withLock {
            remoteCellHostRoutes
        }
    }

    func logAction(context: ConnectContext, action: String, param: String) {
        // no-op for tests
    }

    func logReference(emitter: Emit) {
        // no-op for tests
    }

    func cellUUID(for name: String) async -> String? {
        stateLock.withLock {
            return uuidByName[name]
        }
    }

    func namedCell(for uuid: String) async -> String? {
        stateLock.withLock {
            return nameByUUID[uuid]
        }
    }

    func namedCells(requester: Identity) async -> [String: String] {
        stateLock.withLock {
            return uuidByName
        }
    }

    func setNamedCells(_ namedCells: [String : String], requester: Identity) async {
        stateLock.withLock {
            uuidByName = namedCells
            nameByUUID = Dictionary(uniqueKeysWithValues: namedCells.map { ($1, $0) })
        }
    }

    func identityNamedCells(requester: Identity) async -> [String : [String : String]] {
        stateLock.withLock {
            return namedCellsByIdentity
        }
    }

    func resolverRegistrySnapshot(requester: Identity) async -> CellResolverRegistrySnapshot {
        stateLock.withLock {
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
    }

    func setResolverEmitter(_ emitter: FlowElementPusherCell, requester: Identity) async throws {
        stateLock.withLock {
            resolverEmitter = emitter
        }
    }

    func setIdentityNamedCells(_ identityNamedCells: [String : [String : String]], requester: Identity) async {
        stateLock.withLock {
            namedCellsByIdentity = identityNamedCells
        }
    }

    func setResolveSnapshot(_ snapshot: CellResolverResolveSnapshot) {
        stateLock.withLock {
            resolveSnapshots[snapshot.name] = snapshot
        }
    }

    func get(from url: URL, requester: Identity) async throws -> ValueType? {
        stateLock.withLock {
            return valuesByURL[url.absoluteString]
        }
    }

    func set(value: ValueType, into url: URL, requester: Identity) async throws -> ValueType? {
        stateLock.withLock {
            valuesByURL[url.absoluteString] = value
            return value
        }
    }
}
