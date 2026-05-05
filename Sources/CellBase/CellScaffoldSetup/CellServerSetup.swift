// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

//public struct CellServerSetup {
//    
//    public enum CellSetupError: Error {
//        case missingPersistanceUtility
//    }
//    
//    let identityDomain = "LoonLab"
//    let resolver: CellResolver
//    let tcUtility: TypedCellUtility?
//
//    public init(resolver: CellResolver, tcUtility: TypedCellUtility? = nil) {
//        self.resolver = resolver
//        self.tcUtility = tcUtility
//    }
//    
//    public func setupTemplateWithEndpoint(route: String? = nil, implementation: (Emit & OwnerInstantiable).Type) async throws {
//        try await resolver.addCellResolve(
//            name: route ?? String(describing: implementation.self),
//            cellScope: .template,
//            identityDomain: identityDomain,
//            type: implementation)
//    }
//    
//    public func setupSingletonWithEndpoint(route: String? = nil, implementation: (Emit & OwnerInstantiable).Type) async throws {
//        try await resolver.addCellResolve(
//            name: route ?? String(describing: implementation.self),
//            cellScope: .singleton,
//            identityDomain: identityDomain,
//            type: implementation)
//    }
//    
//    public func setupPersistingSingletonWithEndpoint(route: String? = nil, implementationCodeName: String? = nil, implementation: (Emit & OwnerInstantiable & Codable).Type) async throws {
//        let name = route ?? String(describing: implementation.self)
//        try await resolver.addCellResolve(
//            name: name,
//            cellScope: .persistantSingleton,
//            identityDomain: identityDomain,
//            type: implementation)
//        guard let tcUtility = tcUtility else {
//            throw CellSetupError.missingPersistanceUtility
//        }
//        try tcUtility.register(
//            name: implementationCodeName ?? name,
//            type: implementation)
//    }
//    
//    public func setupPersonalPersistingSingletonWithEndpoint(route: String? = nil, implementationCodeName: String? = nil, implementation: (Emit & OwnerInstantiable & Codable).Type) async throws {
//        let name = route ?? String(describing: implementation.self)
//        try await resolver.addCellResolve(
//            name: name,
//            cellScope: .personalPersistantSingleton,
//            identityDomain: identityDomain,
//            type: implementation)
//        guard let tcUtility = tcUtility else {
//            throw CellSetupError.missingPersistanceUtility
//        }
//        try tcUtility.register(
//            name: implementationCodeName ?? name,
//            type: implementation)
//    }
//
//    
//    // endpoint have uuid instead of name
//    public func setupPersistingDynamicEndpoint(implementationCodeName: String? = nil, implementation: Codable.Type) async throws {
//        guard let tcUtility = tcUtility else {
//            throw CellSetupError.missingPersistanceUtility
//        }
//        try tcUtility.register(
//            name: implementationCodeName ?? String(describing: implementation.self),
//            type: implementation)
//    }
//    
//}
