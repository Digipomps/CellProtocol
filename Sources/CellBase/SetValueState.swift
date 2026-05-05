// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum SetValueState: String, Codable {
    case ok
    case denied // TODO: review if its used
    case paramErr
    case error
}

public enum SetValueError: Error {
    case denied // TODO: review if its used
    case paramErr
    case noParamValue(String)
    case wrongParamType
    case error
}

extension SetValueState {
    public init(from decoder: Decoder) throws {
        let singleValueContainer = try decoder.singleValueContainer()
        let value = try singleValueContainer.decode(String.self)
        self = try Self(rawValue: value) ?? { throw StringEnumError.decodeError(value) }()
    }
    
    public func encode(to encoder: Encoder) throws {
        var singleValueContainer = encoder.singleValueContainer()
        try singleValueContainer.encode(self.rawValue)
    }
}


public struct SetValueResponse: Codable {
    var state: SetValueState
    var value: ValueType?
}
