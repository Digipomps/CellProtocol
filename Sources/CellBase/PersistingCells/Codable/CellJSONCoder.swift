// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct CellJSONCoder {
    static var cellRegistryKey: CodingUserInfoKey {
        CodingUserInfoKey(rawValue: "registeredCellImplementations")!
    }
    
    var decoders = Decoders()
    
    typealias DecoderFunction = (TypedCell.DecodingContext) throws -> Codable
    typealias Decoders = [String: DecoderFunction]

    mutating func register<T: Codable> (name: String, type: T.Type) throws {
        if decoders[name] != nil {
            throw TypedCellUtilityError.duplicatedCodingName
        }
        CellBase.diagnosticLog("CellJSONCoder registering decoder for \(name) as \(type)", domain: .lifecycle)
        decoders[name] = { context in
            try context.container.decode(T.self, forKey: context.key)
        }
    }
    
    public func decode(from data: Data) throws -> Encodable {
        let decoder = JSONDecoder()
        decoder.userInfo = [CellJSONCoder.cellRegistryKey: decoders]
        let typedCell = try decoder.decode(TypedCell.self , from: data)
        return typedCell.cell
    }
    
    public func decodeEmitCell(from data: Data) throws -> Emit? {
        let decoder = JSONDecoder()
        decoder.userInfo = [CellJSONCoder.cellRegistryKey: decoders]
        let typedCell = try decoder.decode(TypedCell.self , from: data)
        return typedCell.cell as? Emit
    }

    public func decodeRuntimeReady(from data: Data) async throws -> Encodable {
        let decoded = try decode(from: data)
        if let runtimeReady = decoded as? CellRuntimeReady {
            try await runtimeReady.ensureRuntimeReady()
        }
        return decoded
    }

    public func decodeRuntimeReadyEmitCell(from data: Data) async throws -> Emit? {
        guard let cell = try decodeEmitCell(from: data) else {
            return nil
        }
        if let runtimeReady = cell as? CellRuntimeReady {
            try await runtimeReady.ensureRuntimeReady()
        }
        return cell
    }
    
    public static func encodeCell(cellClassName: String, cell: Codable) throws -> Data {
        let typedCell = TypedCell(cellTypeString: cellClassName, cell: cell)
        return try JSONEncoder().encode(typedCell)
    }
}
