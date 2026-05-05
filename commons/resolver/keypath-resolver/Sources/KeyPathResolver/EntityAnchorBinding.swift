// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import HavenCoreSchemas

public struct EntityAnchorBinding: Codable, Hashable, Sendable {
    public struct CellBinding: Codable, Hashable, Sendable {
        public var cellId: String
        public var cellType: String
        public var resolution: RouteResolution
        public var prefixes: [String]

        public init(cellId: String, cellType: String, resolution: RouteResolution, prefixes: [String]) {
            self.cellId = cellId
            self.cellType = cellType
            self.resolution = resolution
            self.prefixes = prefixes
        }

        enum CodingKeys: String, CodingKey {
            case cellId = "cell_id"
            case cellType = "cell_type"
            case resolution
            case prefixes
        }
    }

    public var entityId: String
    public var anchorCellId: String
    public var bindings: [CellBinding]

    public init(entityId: String, anchorCellId: String, bindings: [CellBinding]) {
        self.entityId = entityId
        self.anchorCellId = anchorCellId
        self.bindings = bindings
    }

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case anchorCellId = "anchor_cell_id"
        case bindings
    }

    public func cellBinding(for cellType: String, matching path: String) -> CellBinding? {
        let normalizedPath = JSONPointer.normalize(path)

        let candidates = bindings
            .filter { $0.cellType == cellType }
            .sorted {
                let leftMax = $0.prefixes.map { JSONPointer.normalize($0).count }.max() ?? 0
                let rightMax = $1.prefixes.map { JSONPointer.normalize($0).count }.max() ?? 0
                return leftMax > rightMax
            }

        for candidate in candidates {
            if candidate.prefixes.isEmpty {
                return candidate
            }

            let matched = candidate.prefixes.contains { prefix in
                let normalizedPrefix = JSONPointer.normalize(prefix)
                return normalizedPath == normalizedPrefix || normalizedPath.hasPrefix(normalizedPrefix + "/")
            }

            if matched {
                return candidate
            }
        }

        return nil
    }

    public static func seeded(entityId: String) -> EntityAnchorBinding {
        EntityAnchorBinding(
            entityId: entityId,
            anchorCellId: "anchor:\(entityId)",
            bindings: [
                .init(
                    cellId: "identity:\(entityId)",
                    cellType: "IdentityCell",
                    resolution: .absorbed,
                    prefixes: ["#/identity"]
                ),
                .init(
                    cellId: "credentials:\(entityId)",
                    cellType: "CredentialsCell",
                    resolution: .linked,
                    prefixes: ["#/credentials", "#/proofs"]
                ),
                .init(
                    cellId: "perspective:\(entityId)",
                    cellType: "PerspectiveCell",
                    resolution: .linked,
                    prefixes: ["#/perspective"]
                ),
                .init(
                    cellId: "chronicle:\(entityId)",
                    cellType: "ChronicleCell",
                    resolution: .external,
                    prefixes: ["#/chronicle"]
                )
            ]
        )
    }
}
