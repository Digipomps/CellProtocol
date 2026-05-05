// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  PurposeWrapper.swift
//  CellProtocol
//
//  Created by Kjetil Hustveit on 05/02/2026.
//
import Foundation
import FoundationModels
import CellBase

@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 11.0, visionOS 2.0, *)
@Generable
struct PurposeWrapper: Equatable {
    @Guide(description: "A describing name for the purpose.")
    let title: String
    
    @Guide(description: "A description of the purpose.")
    let description: String
    
    @Guide(description: "The actual  purpose. See `Purpose` for more information.")
    let purposeRef: String
}

