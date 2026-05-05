// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 26/11/2022.
//

import Foundation

actor CellClusterFacilitator {
    
    private var connectedCellEmitters = [String: Emit]()
    func loadConnectedCellEmitter(for refId: String) -> Emit? {
        return connectedCellEmitters[refId]
    }
    func storeConnectedCellEmitter(publisher: Emit?, for refId: String) {
        connectedCellEmitters[refId] = publisher
    }
    func empty() {
        connectedCellEmitters = [String: Emit]()
    }

    var all: [Emit] {
        connectedCellEmitters.values.map{$0}
    }
}
