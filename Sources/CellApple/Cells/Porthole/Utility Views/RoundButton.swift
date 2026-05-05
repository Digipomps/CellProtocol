// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import SwiftUI
typealias OnClickHandler = (() -> Void)
typealias OnClickHandler2 = ((Int) -> Void)

protocol Selectable {
    var selected: Bool { get set }
}

struct ActionItem {
    var id = UUID.init().uuidString
    var name: String
    var iconName: String
//    var type: ActionTypes
    var payload: Any
    //    var action:
    
}

struct RoundButton: View /*, Selectable */ {
    @State var imageName: String
//    @Binding var selected: Bool
    @State var onClick: OnClickHandler
//    var actionItem : ActionItem?
    
    
//    var backgroundColor: Color {
//        get {
//            if selected {
//                return .white
//            } else {
//                return .black
//            }
//        }
//    }
    
    var body: some View {
        Button(action: onClick) {
            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40, alignment: .center)
            
                .padding(7.0)
                .background(.white)
                
                .cornerRadius(30)
              
                
                .foregroundColor(.black)
            
                
//                .padding(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 30)
                        .stroke(Color.black, lineWidth: 2)
                )
        }
    }
    
    
}

struct RoundButton_Previews: PreviewProvider {
    @State static var selected = false
    static var previews: some View {
        RoundButton(imageName: "reference" /*, selected: $selected */ , onClick: {
            print("We love closures")
//            imageName = "But in a platonic way"
        })
        
    }
}
