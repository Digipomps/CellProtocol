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
    func storeCell(cellName: String, cell: Codable, uuid: String, options: CellStorageWriteOptions) throws {
        try storeCell(cellName: cellName, cell: cell, uuid: uuid)
    }
}
