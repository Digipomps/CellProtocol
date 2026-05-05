// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  CellView.swift
//  HAVEN_MVP
//
//  Created by Kjetil Hustveit on 10/10/2024.
//

import SwiftUI
import CellBase
import Combine






struct CellConfigView: View {
    
    @ObservedObject var viewModel:  CellViewModel
//    @State var cellConfiguration: CellConfiguration
    
    init(cellConfiguration: CellConfiguration) {
        viewModel = CellViewModel(cellConfiguration: cellConfiguration)
        viewModel.setCellConfiguration(cellConfiguration)
    }
    
    var body: some View {
        //        List(self.viewModel.)
        
        ForEach(self.viewModel.cellConfiguration.cellReferences!, id: \.self) { cellReference in
            ZStack {
                Rectangle()
                    .fill(.white)
                    .padding(.all, 40.0)
                    
                    
                    
                    
//                    .scaledToFill()
                
                VStack {
                    Text(cellReference.label)
                        .background(.white)
                    ScrollView {
                        ForEach(self.viewModel.flowElements) { element in
                            HStack {
                                Text(element.title)
                                Text(element.topic)
                            }.padding(10.0)
                        }
                    }
                    
                    
                    
                    
                    //            .scaledToFill()
                }
            }
        }
        
        
    }
    
    func setCellConfiguration(_ cellConfiguration: CellConfiguration){
        viewModel.setCellConfiguration(cellConfiguration)
    }
}

#Preview {
    
    let cellConf = CellConfiguration(name: "Preview", cellReferences:   buildPreviewReferences())
    CellConfigView(cellConfiguration: cellConf)
}


func buildPreviewReferences() -> [CellReference] {
    var eventEmitterReference = CellReference(endpoint: "cell:///EventEmitter", label: "GeneralTest")
    eventEmitterReference.addKeyAndValue(KeyValue(key: "start", value: nil))
    return [eventEmitterReference]
}
