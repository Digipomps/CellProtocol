// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import CodableHelpers

enum TypedCellError: Error {
    case typeNotFound
}

public struct TypedCell: Codable {
    let cellTypeString: String
    let cell: Codable
    
    init(cellTypeString: String, cell: Codable) {
        self.cellTypeString = cellTypeString
        self.cell = cell
    }
    
    public enum CodingKeys: String, CodingKey {
        case cellTypeString
        case cell
    }
    
    public struct DecodingContext {
        let container: KeyedDecodingContainer<TypedCell.CodingKeys>
        let key: CodingKeys
        let cellTypeString: String
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let cellTypeString = try container.decode(String.self, forKey: .cellTypeString)
        self.cellTypeString = cellTypeString
        let decoderFunction = try Self.cellType(for: cellTypeString, decoder: decoder)
        
//        self.cell =  try container.decode(DIDTestingCell.self, forKey: .cell)
        
        let context = DecodingContext(container: container, key: .cell, cellTypeString: cellTypeString)
        self.cell = try decoderFunction(context)
        
    }
    
    private static func cellType(for name: String, decoder: Decoder) throws -> CellJSONCoder.DecoderFunction {
        guard
            let decoders = decoder.userInfo[CellJSONCoder.cellRegistryKey] as? CellJSONCoder.Decoders,
            let type = decoders[name]
        else {
            throw TypedCellError.typeNotFound
        }
        return type
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(AnyEncodable(cell), forKey: .cell)
        try container.encode(cellTypeString, forKey: .cellTypeString)
    }
}
