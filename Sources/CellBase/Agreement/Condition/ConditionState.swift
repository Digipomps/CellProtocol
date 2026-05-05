// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// TODO: check how it is different from ConditionState
public enum ContractCondition {
    case met
    case unmet
    case unresolved
}

public enum ConditionState: String, Codable {
    case met
    case unmet
    case unresolved
    case engage
}

extension ConditionState {
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
