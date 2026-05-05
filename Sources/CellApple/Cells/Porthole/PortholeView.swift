// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  PortholeView.swift
//  HAVEN_MVP
//
//  Created by Kjetil Hustveit on 25/09/2024.
//
import SwiftUI
import CellBase




public struct PortholeView : View {
    @EnvironmentObject var viewModel:  PortholeViewModel
    
    let topLeftButtonStateStack = [ButtonState(label: "test", selected: false, iconName: "reference"), ButtonState(label: "test", selected: false, iconName: "reference")]
    let bottomLeftButtonStateStack = [ButtonState(label: "test", selected: false, iconName: "reference"), ButtonState(label: "test", selected: false, iconName: "reference")]
    
    public init() {}
    
    public var body: some View {
        
        ZStack(alignment: .top) {
            VStack { Image("Mycelium")
                    .resizable()
//                    .scaledToFill()
                //                .edgesIgnoringSafeArea(.all)
            }
            VStack {
                if let element = viewModel.skeleton {
                    SkeletonView(element: element)
                        .background(Color.white)
                    //                    .scaledToFit()
                }
                
                
                Spacer()
            }
            .alert(isPresented: $viewModel.showAlert) {
                Alert(
                    title: Text(viewModel.alertTitle),
                    message: Text(viewModel.alertMessage),
                    dismissButton: .default(Text(viewModel.alertPrimaryActionLabel)) {
                        viewModel.executeAlertPrimaryAction()
                    }
                )
            }
            VStack {
                
                StacksBarView(direction: .down, leftButtonStateStack: buildOutwardButtonStack(cellConfigurations: viewModel.outWardMenuConfigurations),
                              rightButtonStateStack: buildHistoryButtonStack(cellConfigurations: viewModel.historyMenuConfigurations)
                ).environmentObject(viewModel)
//                    .offset(y: 200.0) // hmmm
                Spacer()
                StacksBarView(direction: .up, leftButtonStateStack: bottomLeftButtonStateStack).environmentObject(viewModel)
            }
            
        }
//        .edgesIgnoringSafeArea(.all)
    }
    
    func buildOutwardButtonStack(cellConfigurations: [CellConfiguration]) -> [ButtonState] {
        var buttonStack = [ButtonState]()
        for cellConf in cellConfigurations  {
//            print("Adding cell configuration: \(cellConf)")
            let buttonState = ButtonState(label: "test", selected: false, iconName: "reference", cellConfiguration: cellConf)
            buttonStack.append(buttonState)
            
            
            
        }
        return buttonStack
    }
    
    func buildHistoryButtonStack(cellConfigurations: [CellConfiguration]) -> [ButtonState] {
        var buttonStack = [ButtonState]()
        for cellConf in cellConfigurations  {
            
            let buttonState = ButtonState(label: "test", selected: false, iconName: "reference", cellConfiguration: cellConf)
            buttonStack.append(buttonState)
            
            
            
        }
        return buttonStack
    }
    
    func buildPreviewReferences() -> [CellReference] {
        var eventEmitterReference = CellReference(endpoint: "cell:///EventEmitter", label: "GeneralTest")
        eventEmitterReference.addKeyAndValue(KeyValue(key: "start", value: nil))
        return [eventEmitterReference]
    }
    

}

#Preview {
    PortholeView().environmentObject(PortholeViewModel())
}
