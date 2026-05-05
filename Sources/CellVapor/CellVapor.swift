// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import Vapor

public struct CellVapor {
    public private(set) var text = "Hello, World!"

    public init() {
    }
    
    public static func getDocumentsDirectory() -> URL {
        if let home = Environment.get("HOME") {
            return URL(fileURLWithPath: home)
        }
        
        return URL(fileURLWithPath: "/tmp")
    }
    
    public static func getCellsDocumentsDirectory() -> URL {
        getDocumentsDirectory().appendingPathComponent("CellsContainer")
    }
}

