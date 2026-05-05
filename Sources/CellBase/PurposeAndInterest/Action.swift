// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 18/09/2023.
//

import Foundation


public struct WeightedAction: Codable {
    var weight: Double
    var action: CellConfiguration
}
// Obsolete?
public struct Action: Codable {
    var name: String
    var cellRef: CellReference 
}
