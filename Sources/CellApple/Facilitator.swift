// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public class Facilitator {
    public var version: Int?
    public var uuids = [String : String]()
    
    public init(version: Int? = nil) {
        self.version = version
    }
}
