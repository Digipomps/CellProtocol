// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 28/11/2022.
//

import Foundation

public enum CellResolveInitMethod : Codable { // 
    case template // Always instantiate new. Instantiate by name, reach instance by uuid
    case singleton // One running, available by name or uuid
    case persistantSingleton
    case personalPersistantSingleton
}

// Should we migrate to this?
public enum CellUsageScope: String {
    case scaffoldUnique
    case template
//        case entityUnique
    case identityUnique
}

extension CellUsageScope: Codable {
    public init(from decoder: Decoder) throws {
        let singleValueContainer = try decoder.singleValueContainer()
        let value = try singleValueContainer.decode(String.self)
        self = try Self(rawValue: value) ?? { throw StringEnumError.decodeError(value) }()
    }
    
    public func encode(to encoder: Encoder) throws {
        var singleValueContainer = encoder.singleValueContainer()
        try singleValueContainer.encode(self.rawValue)
    }
}

public enum Persistancy: String {
    case persistant
    case ephemeral
}

extension Persistancy: Codable {
    public init(from decoder: Decoder) throws {
        let singleValueContainer = try decoder.singleValueContainer()
        let value = try singleValueContainer.decode(String.self)
        self = try Self(rawValue: value) ?? { throw StringEnumError.decodeError(value) }()
    }
    
    public func encode(to encoder: Encoder) throws {
        var singleValueContainer = encoder.singleValueContainer()
        try singleValueContainer.encode(self.rawValue)
    }
}

class CellResolve {
    let name: String
    let cellType: OwnerInstantiable.Type
    let cellScope: CellUsageScope
    let identityDomain: String
    let cellPersistancy: Persistancy
    let lifecyclePolicy: CellLifecyclePolicy?
    let resolver: CellResolver
    var owner: Identity

    func new() async throws -> OwnerInstantiable {
        return await cellType.init(owner: owner) // Maybe a bit dirty but it should always return from vault
    }
    func new(requester: Identity) async throws -> OwnerInstantiable {
        return await cellType.init(owner: requester) // Maybe a bit dirty but it should always return from vault
    }
    init (name: String, cellType: OwnerInstantiable.Type, cellScope: CellUsageScope = .template, percistancy: Persistancy = .ephemeral, lifecyclePolicy: CellLifecyclePolicy? = nil, identityDomain: String, resolver: CellResolver) async throws {
        self.name = name
        self.cellType = cellType
        self.cellScope = cellScope
        self.identityDomain = identityDomain
        self.resolver = resolver
//        self.owner = Identity() // Dummy
        
            guard let tmpOwner = await (CellBase.defaultIdentityVault?.identity(for: identityDomain, makeNewIfNotFound: true)) else {
                throw IdentityVaultError.noVaultIdentity
            }
            self.owner = tmpOwner
        
        self.cellPersistancy = percistancy // TODO: needs better encoding
        self.lifecyclePolicy = lifecyclePolicy
    }

}
