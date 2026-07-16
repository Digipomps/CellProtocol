// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import CFileUtils
import CellBase

public struct FileSystemCellStorage: CellStorage {
    
    private let dataFilename = "typedCell.json"
    
    public enum StorageError: Error {
        case noDocumentRoot
        case invalidDataInStorage
        case unableToCreateDirectory
    }
    
    public init() {}
    
    public func loadEmitCell(with uuid: String, decoder: CellJSONCoder) throws -> Emit {
        let cellURL = try CellStoragePathPolicy.component(
            uuid,
            under: CellApple.getCellsDocumentsDirectory()
        )
        let typedCellURL = try CellStoragePathPolicy.filename(dataFilename, under: cellURL)
        let stored = try Data(contentsOf: typedCellURL)
        let cellJson = try CellPersistenceCrypto.decodeFromStorage(stored: stored, uuid: uuid)
        
        let cell = try decoder.decodeEmitCell(from: cellJson)
        guard let cell = cell else {
            throw StorageError.invalidDataInStorage
        }
        return cell
    }
    
    // Loads cell relative to documentRootPath
    public func loadEmitCell(at path: String, decoder: CellJSONCoder) throws -> Emit {
        let cellURL = try CellStoragePathPolicy.relativePath(
            path,
            under: CellApple.getDocumentsDirectory()
        )
        let typedCellURL = try CellStoragePathPolicy.filename(dataFilename, under: cellURL)
        let stored = try Data(contentsOf: typedCellURL)
        let cellJson = try CellPersistenceCrypto.decodeFromStorage(
            stored: stored,
            uuid: cellURL.lastPathComponent
        )
        
        let cell = try decoder.decodeEmitCell(from: cellJson)
        guard let cell = cell else {
            throw StorageError.invalidDataInStorage
        }
        return cell
    }
    
    public func loadEmitCell(with cellURL: URL, decoder: CellJSONCoder) throws -> Emit {
        let confinedCellURL = try CellStoragePathPolicy.existingURL(
            cellURL,
            under: CellApple.getDocumentsDirectory()
        )
        let typedCellURL = try CellStoragePathPolicy.filename(dataFilename, under: confinedCellURL)
        let stored = try Data(contentsOf: typedCellURL)
        let cellJson = try CellPersistenceCrypto.decodeFromStorage(
            stored: stored,
            uuid: confinedCellURL.lastPathComponent
        )
        let cell = try decoder.decodeEmitCell(from: cellJson)
        guard let cell = cell else {
            throw StorageError.invalidDataInStorage
        }
        return cell
    }
    
    public func storeCell(cellName: String, cell: Codable, uuid: String) throws {
        try storeCell(
            cellName: cellName,
            cell: cell,
            uuid: uuid,
            options: CellStorageWriteOptions()
        )
    }

    public func storeCell(
        cellName: String,
        cell: Codable,
        uuid: String,
        options: CellStorageWriteOptions
    ) throws {
        let data = try CellJSONCoder.encodeCell(cellClassName: cellName, cell: cell)
        let persistedData = try CellPersistenceCrypto.encodeForStorage(
            plaintext: data,
            uuid: uuid,
            options: options
        )
        let directoryURL = try cellDirectoryURL(uuid: uuid)
        let directory = directoryURL.path.cString(using: .utf8)
        if !directoryExists(directory) {
            if mkdir_p(directory) != 0 {
                CellBase.diagnosticLog("Failed to create cell storage directory: \(directoryURL.path)", domain: .lifecycle)
                throw StorageError.unableToCreateDirectory
            }
        }
        let fileURL = try CellStoragePathPolicy.filename(dataFilename, under: directoryURL)
        try persistedData.write(to: fileURL, options: [.atomic])
  
    }
    
    private func cellDirectoryURL(uuid: String) throws -> URL {
        try CellStoragePathPolicy.component(
            uuid,
            under: CellApple.getCellsDocumentsDirectory()
        )
    }
    func getDocumentsDirectory() -> URL {
        CellApple.getDocumentsDirectory()
    }
}
