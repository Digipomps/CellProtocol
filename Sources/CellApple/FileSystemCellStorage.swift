// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import CFileUtils
import CellBase

public struct FileSystemCellStorage: CellStorage {
    
    private let rootDirectoryName = "CellsContainer"
    private let dataFilename = "typedCell.json"
    
    public enum StorageError: Error {
        case noDocumentRoot
        case invalidDataInStorage
        case unableToCreateDirectory
    }
    
    public init() {}
    
    public func loadEmitCell(with uuid: String, decoder: CellJSONCoder) throws -> Emit {
        guard let documentRootPath = CellBase.documentRootPath else {
            throw StorageError.noDocumentRoot
        }
        let cellURL = URL(fileURLWithPath: documentRootPath).appendingPathComponent(rootDirectoryName).appendingPathComponent(uuid)
        let typedCellURL = cellURL.appendingPathComponent(dataFilename)
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
        guard let documentRootPath = CellBase.documentRootPath else {
            throw StorageError.noDocumentRoot
        }
        let cellURL = URL(fileURLWithPath: documentRootPath).appendingPathComponent(path)
        let typedCellURL = cellURL.appendingPathComponent(dataFilename)
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
//        guard let documentRootPath = CellBase.documentRootPath else {
//            throw StorageError.noDocumentRoot
//        }
        // Check that url is building on documentRoot Path?
        let typedCellURL = cellURL.appendingPathComponent(dataFilename)
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
        let directoryURL = cellDirectoryURL(uuid: uuid)
        let directory = directoryURL.path.cString(using: .utf8)
        if !directoryExists(directory) {
            if mkdir_p(directory) != 0 {
                print("Failed to create directory here: \(directoryURL.path)")
                throw StorageError.unableToCreateDirectory
            }
        }
        try persistedData.write(to: directoryURL.appendingPathComponent(dataFilename))
  
    }
    
    private func cellDirectoryURL(uuid: String) -> URL {
        let cellDirectoryURL = getDocumentsDirectory().appendingPathComponent(rootDirectoryName).appendingPathComponent(uuid)
        return cellDirectoryURL
    }
    func getDocumentsDirectory() -> URL {
        // find all possible documents directories for this user
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        
        // just send back the first one, which ought to be the only one
        return paths[0]
    }
}
