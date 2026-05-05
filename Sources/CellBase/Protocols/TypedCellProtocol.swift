// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public protocol TypedCellProtocol {
    func loadTypedEmitCell(with uuid: String) -> Emit?
    func loadTypedEmitCell(at path: String) -> Emit?
    func storeAsTypedCell(cellName: String, cell: Codable, uuid: String)
    func storeAsTypedCell(cellName: String, cell: Codable, uuid: String, options: CellStorageWriteOptions)
    
    init(storage: CellStorage)
}

public extension TypedCellProtocol {
    func storeAsTypedCell(cellName: String, cell: Codable, uuid: String, options: CellStorageWriteOptions) {
        storeAsTypedCell(cellName: cellName, cell: cell, uuid: uuid)
    }
}

// TODO: to be removed
public protocol PersistableCell: Codable, OwnerInstantiable {
    func persistCell()
    func cellDirectoryURL() -> URL
}
