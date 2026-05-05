// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  ObjectView.swift
//  CellUtility
//
//  Created by Kjetil Hustveit on 03/04/2024.
//

import SwiftUI
import CellBase
import Collections

struct ObjectView: View {
    let object: Object
    
    
    var body: some View {
        let orderedDict = OrderedDictionary(uniqueKeys: object.keys.sorted(), values: object.values)
        
        
        let sortedKeys = object.keys.sorted()
        VStack(alignment: .leading) {
                    ForEach(sortedKeys, id: \.self) { key in
                        HStack(alignment: .top) {
                            Text("\(key): ")
                                .frame(minWidth: 60, idealWidth: 100, alignment: .trailing)
                            if let value = object[key] {
                                    VTVF.view(for: value)
                            }
                        }
                    }
                }
    }
}

#Preview {
    ObjectView(object: ["key1" : .string("value"), "key2" : .float(1.0), "list" : .list([.string("List item1"),.string("List item2"),.float(1.0)])])
}
