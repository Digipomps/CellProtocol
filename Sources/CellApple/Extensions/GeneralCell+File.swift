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
        // find all possible documents directories for this user
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        
        // just send back the first one, which ought to be the only one
        return paths[0]
    }
    
    func getCellDirectory() throws -> URL {
        
        
        let directoryURL = CellApple.getCellsDocumentsDirectory().appending(path: self.name)
        let directory = directoryURL.path
        
        let fileManager = FileManager.default
        
        if !fileManager.fileExists(atPath:directory) {
            print("******** Directory does not exist trying to create. path: \(directoryURL.path)")
            
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            
        }
        return directoryURL
    }
    
    func getFileDataInCellDirectory(filename: String) async throws -> Data {
//        guard let docRoot = CellVapor.getCellsDocumentsDirectory()
//            throws
//        }
    
       let directoryURL = try getCellDirectory()
        let fileURL = directoryURL.appending(path: filename)
        let fileData = try Data(contentsOf: fileURL)
//    try data.write(to: directoryURL.appendingPathComponent(dataFilename))
    
        return fileData
    }
    
    func writeFileDataInCellDirectory(fileData: Data, filename: String) async throws {
        if fileData.isEmpty {
            return
        }
//        print("GeneralCell.writeFileDataInCellDirectory data:\n\(String(describing: String(data:fileData, encoding: .utf8 )))")
        let directoryURL = try getCellDirectory()
        let fileURL = directoryURL.appending(path: filename)
        try fileData.write(to: fileURL)
    }
}
