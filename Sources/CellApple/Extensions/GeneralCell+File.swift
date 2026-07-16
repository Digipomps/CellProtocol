// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 05/02/2024.
//

import Foundation
import CellBase
//import CellApple
//import CFileUtils


extension GeneralCell {
    public enum FileError: Error {
        case noDocumentRoot
        case invalidDataInStorage
        case unableToCreateDirectory
    }
    
    
    func checkCellDirectories(targetFolderURL: URL) throws {
        let manager = FileManager.default
        
        if !manager.fileExists(atPath: targetFolderURL.relativePath) {
            try manager.createDirectory(
                at: targetFolderURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }
    
    public func getDocumentsDirectory() -> URL {
        CellApple.getDocumentsDirectory()
    }
    
    func getCellDirectory() throws -> URL {
        
        
        let directoryURL = try CellStoragePathPolicy.component(
            self.name,
            under: CellApple.getCellsDocumentsDirectory()
        )
        let directory = directoryURL.path
        
        let fileManager = FileManager.default
        
        if !fileManager.fileExists(atPath:directory) {
            CellBase.diagnosticLog("Creating cell directory: \(directoryURL.path)", domain: .lifecycle)
            
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            
        }
        return directoryURL
    }
    
    func getFileDataInCellDirectory(filename: String) async throws -> Data {
        let directoryURL = try getCellDirectory()
        let fileURL = try CellStoragePathPolicy.filename(filename, under: directoryURL)
        let fileData = try Data(contentsOf: fileURL)
        return fileData
    }

    func fileExistsInCellDirectory(filename: String) -> Bool {
        guard let directoryURL = try? CellStoragePathPolicy.component(
            self.name,
            under: CellApple.getCellsDocumentsDirectory()
        ), let fileURL = try? CellStoragePathPolicy.filename(filename, under: directoryURL) else {
            return false
        }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
    
    func writeFileDataInCellDirectory(fileData: Data, filename: String) async throws {
        if fileData.isEmpty {
            return
        }
//        print("GeneralCell.writeFileDataInCellDirectory data:\n\(String(describing: String(data:fileData, encoding: .utf8 )))")
        let directoryURL = try getCellDirectory()
        let fileURL = try CellStoragePathPolicy.filename(filename, under: directoryURL)
        try fileData.write(to: fileURL, options: [.atomic])
    }
}
