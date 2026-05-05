// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  CellConfigurationStackView.swift
//  HAVEN_MVP
//
//  Created by Kjetil Hustveit on 09/10/2024.
//

import SwiftUI
import CellBase


enum ExpandDirection {
    case up
    case down
}

struct ButtonState {
    var label: String
    var selected: Bool
    var iconName: String
    var cellConfiguration: CellConfiguration?
}


struct StackView: View {
    @State private var expanded = false
    var direction: ExpandDirection = .down
    var buttonStateStack = [ButtonState]()
    var stackIconName = "configuration"
    var iconOffset = CGSize(width: 0.0, height: 0.0)
    @EnvironmentObject var viewModel:  PortholeViewModel

    
    var multiplier: CGFloat {
        get {
            if expanded {
                if direction == .down {
                    return 60.0
                }
                else {
                    return -60.0
                }
            }
            else {
                return 0.0
            }
        }
    }
    var opacity: Double {
        get {
            if expanded {
                return 1.0
            } else {
                return 0.0
            }
        }
    }
    
    var body: some View {
        ZStack(alignment: .leading) {
            
            
            
            
            ForEach(0 ..< buttonStateStack.count, id: \.self) { index in
                
                
                RoundButton(imageName: "reference" /*, selected: $selected*/ , onClick: {
                    loadCellConfiguration(index: index)
                })
                .offset(x: /*@START_MENU_TOKEN@*/0.0/*@END_MENU_TOKEN@*/, y: multiplier * CGFloat((index + 1)))
                .opacity(opacity)
                .animation(.easeInOut)
            }
            
            
            RoundButton(imageName: stackIconName, onClick: toggleExpansion)
                .offset(iconOffset)
                .animation(.easeInOut)
        }
    }
    
    func toggleExpansion() {
        if self.expanded {
            self.expanded = false
        } else {
            self.expanded = true
        }
    }
    

    
    func loadCellConfiguration(index: Int) {
        print("Loading cell config at index: \(index)")
        if let cellConfig = self.buttonStateStack[index].cellConfiguration {
            self.viewModel.loadCellConfiguration(cellConfig)
        }
    }
}

#Preview {
    StackView(buttonStateStack: [ButtonState(label: "Test", selected: false, iconName: "reference"), ButtonState(label: "Test", selected: false, iconName: "reference")]).environmentObject(PortholeViewModel())
}
