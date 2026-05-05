// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 07/12/2022.
//

import Foundation

actor BridgeBaseAuditor {
    private var commandRegistry = [Int: BridgeCommand]()
    private var commandId = 0
    
    func getNewCommandId() -> Int {
        commandId = commandId + 1
        return commandId
    }
    
    func storeBridgeCommand(_ command: BridgeCommand?, for commandId: Int) {
        commandRegistry[commandId] = command
    }
    
    func loadBridgeCommandForCommandId(_ commandId: Int) -> BridgeCommand? {
        return commandRegistry[commandId]
    }
}
