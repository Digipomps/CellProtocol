// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

struct DynamicCodingKey:CodingKey {
    var stringValue: String
    var intValue: Int?
    
    init(stringValue: String) {
        self.stringValue = stringValue
    }
    init?(intValue: Int) {
        return nil
    }
}
