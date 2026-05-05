// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  JsonViewerView.swift
//  CellUtility
//
//  Created by Kjetil Hustveit on 03/04/2024.
//

import SwiftUI
import  CellBase

struct JsonViewerView: View {
    var valueType: ValueType
    var showTitle = false
    var title = "Json Viewer"
    
    var body: some View {
        if showTitle == true {
            Text(title).bold()
        }
        VTVF.view(for: valueType)
    }
}

#Preview {
    JsonViewerView(valueType: .object(["key1" : .string("value"), "key2" : .float(1.0), "list" : .list([.string("List item1"),.string("List item2"),.float(1.0)])]))
}
