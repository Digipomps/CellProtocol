// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  StacksBarView.swift
//  HAVEN_MVP
//
//  Created by Kjetil Hustveit on 09/10/2024.
//

import SwiftUI

struct StacksBarView: View {
    @EnvironmentObject var viewModel:  PortholeViewModel
    var direction: ExpandDirection = .down
    var leftButtonStateStack = [ButtonState]()
//    var middleButtonStateStack = [ButtonState]()
    var rightButtonStateStack = [ButtonState]()
    var body: some View {
        HStack(alignment: .center) {
            StackView(direction: direction, buttonStateStack: leftButtonStateStack)
            Spacer()
            StackView(direction: direction, buttonStateStack: rightButtonStateStack)
        }
        .padding(30.0)
    }
}

#Preview {
    StacksBarView().environmentObject(PortholeViewModel())
}
