// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  TestCellSkeleetonView.swift
//  HAVEN_MVP
//
//  Created by Kjetil Hustveit on 22/10/2024.
//

import SwiftUI
import CellBase

struct TestCellSkeletonView: View {
    @EnvironmentObject var viewModel:  PortholeViewModel
    var description: CellConfiguration
    
    var body: some View {
//        VStack {
        if let element = viewModel.skeleton {
            SkeletonView(element: element)
        }
//        }
        
        
    }
}

#Preview {
    let configuration = CellConfiguration(name: "Preview config", cellReferences: [CellReference(endpoint: "cell:///EventEmitter", label: "eventTest")])
    let cellText = SkeletonText(text: "String")
    let element = SkeletonElement.Text(cellText)
//    let description = SkeletonDescription(cellConfiguration: configuration, skeletonContent: element)
    TestCellSkeletonView(description: SkeletonDescriptions.skeletonDescriptionFromJson()).environmentObject(PortholeViewModel())
}



/*
 case Spacer(CellSpacer)
 case Image(CellImage)
 case Text(CellText)
 case HStack(CellHStack)
 case VStack(CellVStack)
 
 */
