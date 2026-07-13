// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct CellStorageWriteOptions: Sendable, Equatable {
    public var ownerIdentityUUID: String?
    public var encryptedAtRestRequired: Bool

    public init(
        ownerIdentityUUID: String? = nil,
        encryptedAtRestRequired: Bool = false
    ) {
        self.ownerIdentityUUID = ownerIdentityUUID
        self.encryptedAtRestRequired = encryptedAtRestRequired
    }
}

public protocol CellStorage {
    func loadEmitCell(with uuid: String, decoder: CellJSONCoder) throws -> Emit
    func loadEmitCell(at path: String, decoder: CellJSONCoder) throws -> Emit
    func storeCell(cellName: String, cell: Codable, uuid: String) throws
    func storeCell(cellName: String, cell: Codable, uuid: String, options: CellStorageWriteOptions) throws
}

public extension CellStorage {
    func loadRuntimeReadyEmitCell(with uuid: String, decoder: CellJSONCoder) async throws -> Emit {
        let cell = try loadEmitCell(with: uuid, decoder: decoder)
        if let runtimeReady = cell as? CellRuntimeReady {
            try await runtimeReady.ensureRuntimeReady()
        }
        return cell
    }

    func loadRuntimeReadyEmitCell(at path: String, decoder: CellJSONCoder) async throws -> Emit {
        let cell = try loadEmitCell(at: path, decoder: decoder)
        if let runtimeReady = cell as? CellRuntimeReady {
            try await runtimeReady.ensureRuntimeReady()
        }
        return cell
    }

    func storeCell(cellName: String, cell: Codable, uuid: String, options: CellStorageWriteOptions) throws {
        try storeCell(cellName: cellName, cell: cell, uuid: uuid)
    }
}
