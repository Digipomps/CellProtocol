// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct CellResolverResolveSnapshot: Codable, Equatable {
    public var name: String
    public var cellType: String
    public var cellScope: CellUsageScope
    public var persistancy: Persistancy
    public var identityDomain: String
    public var hasLifecyclePolicy: Bool

    public init(
        name: String,
        cellType: String,
        cellScope: CellUsageScope,
        persistancy: Persistancy,
        identityDomain: String,
        hasLifecyclePolicy: Bool
    ) {
        self.name = name
        self.cellType = cellType
        self.cellScope = cellScope
        self.persistancy = persistancy
        self.identityDomain = identityDomain
        self.hasLifecyclePolicy = hasLifecyclePolicy
    }
}

public struct CellResolverNamedInstanceSnapshot: Codable, Equatable {
    public var name: String
    public var uuid: String
    public var identityUUID: String?

    public init(name: String, uuid: String, identityUUID: String? = nil) {
        self.name = name
        self.uuid = uuid
        self.identityUUID = identityUUID
    }

    public var endpoint: String {
        if name.hasPrefix("cell:///") || name.contains("://") {
            return name
        }
        return "cell:///\(name)"
    }
}

public struct CellResolverRegistrySnapshot: Codable, Equatable {
    public var resolves: [CellResolverResolveSnapshot]
    public var sharedNamedInstances: [CellResolverNamedInstanceSnapshot]
    public var identityNamedInstances: [CellResolverNamedInstanceSnapshot]

    public init(
        resolves: [CellResolverResolveSnapshot],
        sharedNamedInstances: [CellResolverNamedInstanceSnapshot],
        identityNamedInstances: [CellResolverNamedInstanceSnapshot]
    ) {
        self.resolves = resolves.sorted { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.cellType < rhs.cellType
        }
        self.sharedNamedInstances = sharedNamedInstances.sorted { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.uuid < rhs.uuid
        }
        self.identityNamedInstances = identityNamedInstances.sorted { lhs, rhs in
            if lhs.identityUUID != rhs.identityUUID {
                return (lhs.identityUUID ?? "") < (rhs.identityUUID ?? "")
            }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.uuid < rhs.uuid
        }
    }
}
