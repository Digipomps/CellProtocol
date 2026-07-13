// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum TypedCellLoadResult {
    case loaded(Emit)
    case missing
    case unavailable
}

public protocol TypedCellProtocol {
    func loadTypedEmitCell(with uuid: String) -> Emit?
    func loadTypedEmitCellResult(with uuid: String) -> TypedCellLoadResult
    func loadTypedEmitCell(at path: String) -> Emit?
    func loadTypedEmitCellResult(at path: String) -> TypedCellLoadResult
    func storeAsTypedCell(cellName: String, cell: Codable, uuid: String)
    func storeAsTypedCell(cellName: String, cell: Codable, uuid: String, options: CellStorageWriteOptions)
    
    init(storage: CellStorage)
}

public extension TypedCellProtocol {
    /// Legacy implementations cannot distinguish a missing record from a
    /// decode, key, or storage failure. Treat an ambiguous `nil` as
    /// unavailable so identity mappings are preserved fail-closed.
    func loadTypedEmitCellResult(with uuid: String) -> TypedCellLoadResult {
        guard let cell = loadTypedEmitCell(with: uuid) else {
            return .unavailable
        }
        return .loaded(cell)
    }

    func loadTypedEmitCellResult(at path: String) -> TypedCellLoadResult {
        guard let cell = loadTypedEmitCell(at: path) else {
            return .unavailable
        }
        return .loaded(cell)
    }

    func loadRuntimeReadyTypedEmitCell(with uuid: String) async throws -> Emit? {
        guard let cell = loadTypedEmitCell(with: uuid) else {
            return nil
        }
        if let runtimeReady = cell as? CellRuntimeReady {
            try await runtimeReady.ensureRuntimeReady()
        }
        return cell
    }

    func loadRuntimeReadyTypedEmitCell(at path: String) async throws -> Emit? {
        guard let cell = loadTypedEmitCell(at: path) else {
            return nil
        }
        if let runtimeReady = cell as? CellRuntimeReady {
            try await runtimeReady.ensureRuntimeReady()
        }
        return cell
    }
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
