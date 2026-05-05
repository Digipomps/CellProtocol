// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 17/08/2022.
//

import Foundation
import CellBase
import Vapor

extension GeneralCell {
    public func cellDirectoryURL() async -> URL {
        var cellDirectoryURL: URL
        if let home = Environment.get("HOME") {
            cellDirectoryURL = URL(fileURLWithPath: home)
        } else {
            cellDirectoryURL = URL(fileURLWithPath: "/")
        }
        
        return  cellDirectoryURL.appendingPathComponent("CellsContainer").appendingPathComponent(self.uuid)
    }
}
