// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  HitCollector.swift
//  CellProtocol
//
//  Created by Kjetil Hustveit on 03/02/2026.
//
// This is a suggestion from ChatGPT that we will probably not use

import Foundation
import CellBase

public actor HitCollector {
    private var refs = Set<String>()
    public func record(_ ref: String) { refs.insert(ref) }
    public func results() -> [String] { Array(refs) }
}
