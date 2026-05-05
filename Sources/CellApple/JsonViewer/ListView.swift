// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  ListView.swift
//  CellUtility
//
//  Created by Kjetil Hustveit on 03/04/2024.
//

import SwiftUI
import CellBase

struct ListView: View {
    let list: ValueTypeList
    var body: some View {
        
        
        VStack(alignment: .leading) {
            ForEach(list) { item in
                VTVF.view(for: item)
            }
        }
    }
}


#Preview {
    ListView(list: [.string("List item1"),.string("List item1"),.float(1.0)])
}
