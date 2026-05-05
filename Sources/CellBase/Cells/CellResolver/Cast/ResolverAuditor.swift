// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 26/11/2022.
//

import Foundation

actor ResolverAuditor {
    enum AuditorError: Error {
        case registerAtAlreadyTakenEndpoint
        case duplicatedEndpointName
        case personalInstanceAlreadyRegistered
    }
    struct CellInstanceWrapper {
//        let endpoints: [String] // Deprecate it
        let emit: Emit
        var refCount: Int = 1
        mutating func increment() -> Int {
            refCount += 1
            return refCount
        }
        mutating func decrement() -> Int {
            refCount -= 1
            return refCount
        }
    }
    
    private var namedCellResolves = [String : CellResolve]()
    private var loadCellFacilitators = [String : CellClusterFacilitator]()
    
//    private var cellInstances = [CellInstanceWrapper]()
    
    private var personalCellReferences = [String: [CellInstanceWrapper]]() // keys are Identity.uuid
    
    private var cellInstanceDict = [String : CellInstanceWrapper]()
    private var namedCellsDict = [String: String]() // ["name" : "uuid"]
    private var reversedNamedCellsDict = [String: String]() // ["uuid" : "name"]
    
    private var personalCellReferenceDict = [String : [String : String]]()
    
    func registerReference(_ cell: Emit, endpoint: String? = nil) throws {
        let refCount = cellInstanceDict[cell.uuid]?.increment()
        if refCount == nil {
            cellInstanceDict[cell.uuid] = CellInstanceWrapper( emit: cell)
            if let endpoint = endpoint {
                try register(name: endpoint, for: cell.uuid)
            }
        }
    }
    
    func register(name: String, for uuid: String) throws {
        if let existing = namedCellsDict[name] {
            if existing == uuid {
                reversedNamedCellsDict[uuid] = name
                return
            }
            if cellInstanceDict[existing] == nil {
                namedCellsDict[name] = uuid
                reversedNamedCellsDict[existing] = nil
                reversedNamedCellsDict[uuid] = name
                return
            }
            throw AuditorError.registerAtAlreadyTakenEndpoint
        }
        namedCellsDict[name] = uuid
        reversedNamedCellsDict[uuid] = name
    }
    
    func unregisterReference(uuid: String? = nil, endpoint: String? = nil) {
        if let uuid = uuid {
            let refCount = cellInstanceDict[uuid]?.decrement()
            if refCount == 0 {
                cellInstanceDict[uuid] = nil
                if let name = reversedNamedCellsDict[uuid] {
                    namedCellsDict[name] = nil
                }
            }
        }
        if let endpoint = endpoint {
            unregister(name: endpoint)
        }
    }

    func evictCellInstance(uuid: String) {
        cellInstanceDict[uuid] = nil
    }
    
    func unregister(name: String) {
        if let uuid = namedCellsDict[name] {
            namedCellsDict[name] = nil
            reversedNamedCellsDict[uuid] = nil
        }
    }
    
    
//    func registerReference1(_ cell: Emit, endpoint: String? = nil) throws {
//        if let index = indexOfInstance(uuid: cell.uuid, endpoint: endpoint) {
//            var instance = cellInstances[index]
//            if instance.emit.uuid != cell.uuid {
//                throw AuditorError.registerAtAlreadyTakenEndpoint
//            }
//            instance.refCount += 1
//            cellInstances[index] = instance
//            return
//        }
//        let instance = CellInstanceWrapper(
//            endpoints: endpoint.map{[$0]} ?? [],
//            emit: cell)
//        cellInstances.append(instance)
//    }
    
    
    // This should be refactored to lookup in the identity's entity - have in mind when going through permissions
    
    // identity.name.uuid
    
    func registerPersonalReference(_ cell: Emit, endpoint: String, identity: Identity) throws {
        CellBase.diagnosticLog(
            "registerPersonalReference endpoint=\(endpoint) identity=\(identity.uuid) cell=\(cell.uuid)",
            domain: .resolver
        )
        if let _ = personalCellReferenceDict[identity.uuid] {
            let refCount = cellInstanceDict[cell.uuid]?.increment()
            if refCount == nil {
                cellInstanceDict[cell.uuid] = CellInstanceWrapper( emit: cell)
                personalCellReferenceDict[identity.uuid]?[endpoint] =  cell.uuid
                
            }
        } else {
            if (cellInstanceDict[cell.uuid] != nil) {
                throw AuditorError.personalInstanceAlreadyRegistered
            }
            cellInstanceDict[cell.uuid] = CellInstanceWrapper( emit: cell)
            personalCellReferenceDict[identity.uuid] = [endpoint : cell.uuid]
        }
        
    }
    

    func celluuid(for name: String) -> String? {
        
        return self.namedCellsDict[ name]
    }
    
    func cellname(for uuid: String) -> String? {
        return self.reversedNamedCellsDict[uuid]
    }
    
    
    func loadCellInstance(forEndpoint endpoint: String) -> Emit? {
        if let uuid = namedCellsDict[endpoint] {
            _ = cellInstanceDict[uuid]?.increment()
            return cellInstanceDict[uuid]?.emit
        }
        return nil
    }
    
    func loadIdentityCellInstance(uuid: String? = nil, name: String, identity: Identity) -> Emit? {
        guard let uuid = personalCellReferenceDict[identity.uuid]?[name] else {
            return nil
        }
        
        return cellInstanceDict[uuid]?.emit
    }
    
    func loadIdentityCellUuid(uuid: String? = nil, name: String, identity: Identity) -> String? {
        guard let uuid = personalCellReferenceDict[identity.uuid]?[name] else {
            return nil
        }
        
        return uuid
    }
    
    func unregisterIdentityReference(uuid: String? = nil, name: String, identity: Identity) {
        guard let uuid = personalCellReferenceDict[identity.uuid]?[name] else {
            return
        }
        
        let refCount = cellInstanceDict[uuid]?.decrement()
        if refCount == 0 {
            unregisterReference()
            
            personalCellReferenceDict[identity.uuid]?[name] = nil
            if personalCellReferenceDict[identity.uuid]?.count == 0 {
                personalCellReferenceDict[identity.uuid] = nil
            }
        }
        
//        guard var instances = personalCellReferences[identity.uuid],
//              let index = indexOfInstance(uuid: uuid, endpoint: endpoint, instances: instances) else {return}
//        var instance = cellInstances[index]
//        instance.refCount -= 1
//        if instance.refCount > 0 {
//            instances[index] = instance
//        } else {
//            instances.remove(at: index)
//        }
    }

    func loadCellInstance(forUUID uuid: String) -> Emit? {
        return cellInstanceDict[uuid]?.emit
    }
    
    func storeNamedResolve(resolve: CellResolve) throws {
        if namedCellResolves[resolve.name] != nil {
            throw AuditorError.duplicatedEndpointName
        }
        CellBase.diagnosticLog("Adding resolve: \(resolve.name)", domain: .resolver)
        namedCellResolves[resolve.name] = resolve
    }

    func unregisterSharedReference(endpoint: String) {
        guard let uuid = namedCellsDict[endpoint] else {
            return
        }
        namedCellsDict[endpoint] = nil
        reversedNamedCellsDict[uuid] = nil
        cellInstanceDict[uuid] = nil
    }
    
    func loadNamedResolve(_ name: String) -> CellResolve? {
        namedCellResolves[name]
    }
    
    func storeFacilitator(facilitator: CellClusterFacilitator?, for uuid: String) {
        loadCellFacilitators[uuid] = facilitator
    }
    
    func loadFacilitator(_ uuid: String) -> CellClusterFacilitator?{
        loadCellFacilitators[uuid]
    }
    
    func auditorState() -> String {
        let state = "namedCellResolves: \(namedCellResolves) loadCellFacilitators: \(loadCellFacilitators) cellInstances: \(cellInstanceDict)"
        return state
    }
    
    
    func namedCells() -> [String: String] {
        return namedCellsDict
    }
    
    func setNamedCells(_ namedCells: [String: String]) {
        // generate reversed
        
        self.namedCellsDict = namedCells
        self.reversedNamedCellsDict = [String : String]()
        for (name, uuid) in namedCells {
            self.reversedNamedCellsDict[uuid] = name
        }
        CellBase.diagnosticLog("set named cells: \(namedCellsDict)", domain: .resolver)
        CellBase.diagnosticLog("set reversed name cells: \(reversedNamedCellsDict)", domain: .resolver)
    }
    
    func identityNamedCells() -> [String: [String: String]] {
        return personalCellReferenceDict
    }
    
    func setIdentityNamedCells(_ identityNamedCells: [String: [String: String]]) {
        self.personalCellReferenceDict = identityNamedCells
        
        // 
    }

    func resolveSnapshots() -> [CellResolverResolveSnapshot] {
        namedCellResolves.values.map { resolve in
            CellResolverResolveSnapshot(
                name: resolve.name,
                cellType: String(describing: resolve.cellType),
                cellScope: resolve.cellScope,
                persistancy: resolve.cellPersistancy,
                identityDomain: resolve.identityDomain,
                hasLifecyclePolicy: resolve.lifecyclePolicy != nil
            )
        }
    }

    func namedResolves() -> [CellResolve] {
        Array(namedCellResolves.values)
    }

    func sharedNamedInstanceSnapshots() -> [CellResolverNamedInstanceSnapshot] {
        namedCellsDict.compactMap { name, uuid in
            guard cellInstanceDict[uuid] != nil else { return nil }
            return CellResolverNamedInstanceSnapshot(name: name, uuid: uuid)
        }
    }

    func identityNamedInstanceSnapshots() -> [CellResolverNamedInstanceSnapshot] {
        personalCellReferenceDict.flatMap { identityUUID, names in
            names.compactMap { name, uuid in
                guard cellInstanceDict[uuid] != nil else { return nil }
                return CellResolverNamedInstanceSnapshot(name: name, uuid: uuid, identityUUID: identityUUID)
            }
        }
    }
    
}
