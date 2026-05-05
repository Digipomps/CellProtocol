// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 05/02/2024.
//

import Foundation
import CFileUtils
import CellBase

extension GeneralCell {
    public enum FileError: Error {
        case noDocumentRoot
        case invalidDataInStorage
        case unableToCreateDirectory
    }
    
    
    public func checkCellDirectories(targetFolderURL: URL) throws {
        let directory = targetFolderURL.path.cString(using: .utf8)
        
        if !directoryExists(directory) {
            print("******** Directory does not exist trying to create. path: \(targetFolderURL.path)")
            if mkdir_p(directory) != 0 {
                throw FileError.unableToCreateDirectory
            }
        }
    }
    
    public func getCellDirectory() throws -> URL {
        let directoryURL = CellVapor.getCellsDocumentsDirectory().appending(path: self.name)
        let directory = directoryURL.path.cString(using: .utf8)
        
        if !directoryExists(directory) {
            print("******** Directory does not exist trying to create. path: \(directoryURL.path)")
            if mkdir_p(directory) != 0 {
                throw FileError.unableToCreateDirectory
            }
        }
        return directoryURL
    }
    
    public func getFileDataInCellDirectory(filename: String) async throws -> Data {
    
       let directoryURL = try getCellDirectory()
        let fileURL = directoryURL.appending(path: filename)
        let fileData = try Data(contentsOf: fileURL)
//    try data.write(to: directoryURL.appendingPathComponent(dataFilename))
    
        return fileData
    }
    
    public func writeFileDataInCellDirectory(fileData: Data, filename: String) async throws {
        let directoryURL = try getCellDirectory()
        let fileURL = directoryURL.appending(path: filename)
        try fileData.write(to: fileURL)
    }
}
