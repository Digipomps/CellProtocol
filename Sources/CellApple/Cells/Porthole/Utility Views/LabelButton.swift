// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import SwiftUI

struct LabelButton: View {
    @State var title: String
    @State var onClick: OnClickHandler
    var body: some View {
  
        Button(action: onClick) {
            Text(title)
                .fontWeight(.regular)
                .font(.footnote)
                .padding(7.0)
                .background(Color.black)
                
                .cornerRadius(30)
              
                
                .foregroundColor(.white)
                
//                .padding(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 30)
                        .stroke(Color.white, lineWidth: 2)
                )
        }
    }
}

struct LabelButton_Previews: PreviewProvider {
    static var previews: some View {
        LabelButton(title: "GURL") {
            print("Label button clicked")
        }
    }
}
