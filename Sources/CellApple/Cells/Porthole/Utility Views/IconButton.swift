// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import SwiftUI



struct IconButton: View {
    @State var imageName: String
    @State var onClick: OnClickHandler
    
    var body: some View {
        Button(action: onClick) {
            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40, alignment: .center)
                .padding(7.0)
                .background(.white)
        }
    }
}

struct IconButton_Previews: PreviewProvider {
    static var previews: some View {
        IconButton(imageName: "configuration") {
            print("clicked icon")
        }
    }
}
