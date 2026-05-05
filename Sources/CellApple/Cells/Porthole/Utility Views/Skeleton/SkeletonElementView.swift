// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  SkeletonElementView.swift
//  HAVEN_MVP
//
//  Created by Kjetil Hustveit on 23/10/2024.
//

import SwiftUI
import CellBase

private func skeletonStorageKey(for element: SkeletonElement, suffix: String = "text") -> String {
    // Derive a stable-ish key based on the element's case and associated data description
    // If SkeletonElement conforms to Identifiable/Hashable elsewhere, you can swap this to a proper id
    let base = String(describing: element)
    return "SkeletonElement_\(base)_\(suffix)"
}

private func encodeValueType(_ value: ValueType?) -> String {
    guard let value else { return "__nil__" }
    switch value {
    case .string(let s):
        return "string:\"\(s)\""
    case .integer(let i):
        return "int:\(i)"
    case .float(let d):
        return "double:\(d)"
    case .bool(let b):
        return "bool:\(b)"
    default:
        return "__unknown__"
    }
    
}

private func decodeValueType(_ string: String) -> ValueType? {
    if string == "__nil__" { return nil }
    if string.hasPrefix("string:\"") {
        let start = string.index(string.startIndex, offsetBy: 8)
        let s = String(string[start...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return .string(s)
    }
    if string.hasPrefix("int:") {
        if let i = Int(string.dropFirst(4)) { return .integer(i) }
    }
    if string.hasPrefix("double:") {
        if let d = Double(string.dropFirst(7)) { return .float(d) }
    }
    if string.hasPrefix("bool:") {
        let v = String(string.dropFirst(5))
        return .bool((v as NSString).boolValue)
    }
    return nil
}

@available(*, deprecated, message: "Use SkeletonView from Utility Views/Skeleton/Suggestion/SkeletonView.swift")
struct SkeletonElementView: View {
    @State private var storageKey: String = ""
    @AppStorage("__placeholder__") private var persistedText: String = "..."
    
    @State private var valueStorageKey: String = ""
    @AppStorage("__placeholder_value__") private var persistedValueString: String = "__nil__"

    private var valueTypeBinding: Binding<ValueType?> {
        Binding<ValueType?>(
            get: { decodeValueType(persistedValueString) },
            set: { newValue in
                persistedValueString = encodeValueType(newValue)
            }
        )
    }

    let element: SkeletonElement
    let userInfoValue: ValueType?
    @EnvironmentObject var viewModel:  PortholeViewModel
    
    init(element: SkeletonElement, userInfoValue: ValueType? = nil) {
        self.element = element
        self.userInfoValue = userInfoValue
        
        let key = skeletonStorageKey(for: element, suffix: "text")
        _storageKey = State(initialValue: key)
        _persistedText = AppStorage(wrappedValue: "...", key)
        
        let valueKey = skeletonStorageKey(for: element, suffix: "valueType")
        _valueStorageKey = State(initialValue: valueKey)
        _persistedValueString = AppStorage(wrappedValue: "__nil__", valueKey)
    }
    
    var body: some View {
        switch element {
        case .Text(let cellText):
            TextEditor(text: $persistedText)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .task {
                    // Only fetch/override if we still have the placeholder (not user-entered text)
                    if persistedText == "..." {
                        let content = await cellText.asyncContent(userInfoValue: userInfoValue)
                        if !content.isEmpty {
                            persistedText = content
                        }
                    }
                }
            
        case .VStack(let cellVStack):
            VStack {
                ForEach(cellVStack.elements) { currentElement in
                    SkeletonElementView(element: currentElement, userInfoValue: userInfoValue)
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color.white) // Test
            .padding() // Test
            
        case .HStack(let cellHStack):
            HStack {
                ForEach(cellHStack.elements) { currentElement in
                    SkeletonElementView(element: currentElement, userInfoValue: userInfoValue)
                }
            }
            
        case .List(let skeletonList):
           
            CellListView(skeletonList: skeletonList, userInfoValue: userInfoValue).environmentObject(viewModel)
           
            
        case .Object(let skeletonObject):
            
            VStack {
                
                ForEach(Array(skeletonObject.elements.keys), id: \.self) { key in
                    HStack {
                        Text(key)
                        Text(" : ")
                        SkeletonElementView(element: skeletonObject.elements[key] ?? .Text(SkeletonText(text: "nil")), userInfoValue: userInfoValue)
                    }
                }
            }
            
        case .Spacer(let skeletonSpacer):
            Spacer()
            
        case .Image(let skeletonImage):
            
            Image(skeletonImage.name ?? "Haven_logo_cropped")
                .if(skeletonImage.resizable) { view in
                    view.resizable()
                }
                .if(skeletonImage.scaledToFit) { view in
                    view.scaledToFit()
                }
        case .AttachmentField:
            SkeletonView(element: element, userInfoValue: userInfoValue)
                .environmentObject(viewModel)
        case .FileUpload:
            SkeletonView(element: element, userInfoValue: userInfoValue)
                .environmentObject(viewModel)
        case .Reference(let skeletonCellReference):
            CellReferenceView(skeletonReference: skeletonCellReference, userInfoValue: userInfoValue)
                .if(skeletonCellReference.scaledToFit) { view in
                    view.scaledToFit()
                }
            
        case .Button(let skeletonButton):
            CellButtonView(skeletonButton: skeletonButton, userInfoValue: userInfoValue, responseValue: valueTypeBinding)
            
        default:
            EmptyView()
        }
    }
    

    func dummy() -> some View {
        print("Dummy loaded")
        sleep(1)
        return Text("dummy")
    }
}

#Preview {
    // Ensure CellBase is initialized for previews
    struct PreviewHost: View {
        @State private var initialized = false

        var body: some View {
            Group {
                if let element = SkeletonDescriptions.skeletonDescriptionFromJson().skeleton {
                    SkeletonElementView(element: element)
                        .environmentObject(PortholeViewModel())
                } else {
                    Text("No skeleton available")
                }
            }
            .task {
                if !initialized {
                    await AppInitializer.initialize()
                    initialized = true
                }
            }
        }
    }

    return PreviewHost()
}
    
extension View {
    /// Applies the given transform if the given condition evaluates to `true`.
    /// - Parameters:
    ///   - condition: The condition to evaluate.
    ///   - transform: The transform to apply to the source `View`.
    /// - Returns: Either the original `View` or the modified `View` if the condition is `true`.
    @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
