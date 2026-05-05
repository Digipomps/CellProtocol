// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors


import Foundation

enum TypedCellUtilityError: Error {
    case duplicatedCodingName
}

public class TypedCellUtility: TypedCellProtocol {
    private var decoder = CellJSONCoder()
    var storage: CellStorage
    
    required public init(storage: CellStorage) {
        self.storage = storage
    }
    
    public func register<T: Codable> (name: String, type: T.Type) throws {
        CellBase.diagnosticLog("TypedCellUtility registering \(name) as \(type)", domain: .lifecycle)
        try decoder.register(name: name, type: type)
    }
    
    private static var utility: TypedCellProtocol? {
        guard let typedCellUtility = CellBase.typedCellUtility else {
            CellBase.diagnosticLog("TypedCellUtility missing from CellBase.typedCellUtility", domain: .lifecycle)
            return nil
        }
        return typedCellUtility
    }
    
    public static func loadTypedCellPublisher(with uuid: String) -> Emit? {
        Self.utility?.loadTypedEmitCell(with: uuid)
    }
    
    public static func loadTypedCellPublisher(at path: String) -> Emit? {
        Self.utility?.loadTypedEmitCell(at: path)
    }
    
    
    
    public func loadTypedEmitCell(with uuid: String) -> Emit? {
        do {
            return try storage.loadEmitCell(with: uuid, decoder: decoder)
        } catch {
            logLoadFailure(error, location: "uuid:\(uuid)")
            return nil
        }
    }
    
    public func loadTypedEmitCell(at path: String) -> Emit? {
        do {
            return try storage.loadEmitCell(at: path, decoder: decoder)
        } catch {
            logLoadFailure(error, location: "path:\(path)")
            return nil
        }
    }
    
    public static func storeAsTypedCell(cellName: String, cell: Codable, uuid: String) {
        Self.utility?.storeAsTypedCell(cellName: cellName, cell: cell, uuid: uuid)
    }

    public static func storeAsTypedCell(
        cellName: String,
        cell: Codable,
        uuid: String,
        options: CellStorageWriteOptions
    ) {
        Self.utility?.storeAsTypedCell(cellName: cellName, cell: cell, uuid: uuid, options: options)
    }
    
    public func storeAsTypedCell(cellName: String, cell: Codable, uuid: String) {
        storeAsTypedCell(
            cellName: cellName,
            cell: cell,
            uuid: uuid,
            options: CellStorageWriteOptions()
        )
    }

    public func storeAsTypedCell(
        cellName: String,
        cell: Codable,
        uuid: String,
        options: CellStorageWriteOptions
    ) {
        do {
            try storage.storeCell(cellName: cellName, cell: cell, uuid: uuid, options: options)
        } catch {
            CellBase.diagnosticLog(
                "Persisting typed cell failed for \(uuid) with error: \(error)",
                domain: .lifecycle
            )
        }
    }

    private func logLoadFailure(_ error: Error, location: String) {
        if Self.isMissingStoredCell(error) {
            CellBase.diagnosticLog("No persisted typed cell at \(location)", domain: .lifecycle)
            return
        }
        CellBase.diagnosticLog(
            "Loading persisted typed cell failed at \(location) with error: \(error)",
            domain: .lifecycle
        )
    }

    private static func isMissingStoredCell(_ error: Error) -> Bool {
        let nsError = error as NSError
        let missingFileCodes: Set<Int> = [
            CocoaError.Code.fileNoSuchFile.rawValue,
            CocoaError.Code.fileReadNoSuchFile.rawValue
        ]
        if nsError.domain == NSCocoaErrorDomain, missingFileCodes.contains(nsError.code) {
            return true
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == 2 {
            return true
        }

        return false
    }
}
