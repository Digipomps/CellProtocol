// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import SwiftUI
import CellBase

private func gridItemsLocal(from cols: [SkeletonGridColumn]) -> [GridItem] {
    cols.map { col in
        switch col.type {
        case .fixed:
            return GridItem(.fixed(CGFloat(col.value ?? 0)))
        case .flexible:
            return GridItem(.flexible(minimum: CGFloat(col.min ?? 0), maximum: CGFloat(col.max ?? .infinity)))
        case .adaptive:
            return GridItem(.adaptive(minimum: CGFloat(col.min ?? 0), maximum: CGFloat(col.max ?? .infinity)))
        }
    }
}

private func gridResolvedUserInfoValue(from value: ValueType) -> ValueType {
    switch value {
    case .flowElement(let flowElement):
        return gridFlowElementUserInfoValue(flowElement)
    default:
        return value
    }
}

private func gridFlowElementUserInfoValue(_ flowElement: FlowElement) -> ValueType {
    let contentValue = (try? flowElement.content.valueType()) ?? .null
    var flowObject: Object = [
        "id": .string(flowElement.id),
        "title": .string(flowElement.title),
        "topic": .string(flowElement.topic),
        "content": contentValue
    ]

    if case let .object(contentObject) = contentValue {
        for (key, value) in contentObject where flowObject[key] == nil {
            flowObject[key] = value
        }
    }

    if let origin = flowElement.origin {
        flowObject["origin"] = .string(origin)
    }

    if let properties = flowElement.properties {
        var propertiesObject: Object = [
            "type": .string(properties.type.rawValue)
        ]
        if let mimetype = properties.mimetype {
            propertiesObject["mimetype"] = .string(mimetype)
        }
        if let contentType = properties.contentType {
            propertiesObject["contentType"] = .string(contentType.rawValue)
        }
        flowObject["properties"] = .object(propertiesObject)
    }

    return .object(flowObject)
}

struct CellGridView: View {
    let userInfoValue: ValueType?
    var skeletonGrid: SkeletonGrid
    @State private var valueTypeList: ValueTypeList = ValueTypeList()
    @EnvironmentObject var viewModel: PortholeViewModel

    init(skeletonGrid: SkeletonGrid, userInfoValue: ValueType? = nil) {
        self.skeletonGrid = skeletonGrid
        self.userInfoValue = userInfoValue
    }

    private var resolvedColumns: [GridItem] {
        gridItemsLocal(from: skeletonGrid.columns)
    }

    private var hasDynamicSource: Bool {
        skeletonGrid.keypath?.isEmpty == false
    }

    var body: some View {
        LazyVGrid(columns: resolvedColumns, spacing: CGFloat(skeletonGrid.spacing ?? 8)) {
            if hasDynamicSource {
                ForEach(Array(valueTypeList.enumerated()), id: \.offset) { _, value in
                    gridItemView(for: value)
                }
            } else {
                ForEach(skeletonGrid.elements, id: \.id) { element in
                    SkeletonView(element: element, userInfoValue: userInfoValue)
                        .environmentObject(viewModel)
                }
            }
        }
        .task(id: refreshTaskID()) {
            guard hasDynamicSource else {
                return
            }
            if let items = try? await skeletonGrid.getItems() {
                valueTypeList = items
            }
        }
    }

    private func refreshTaskID() -> String {
        let keypath = skeletonGrid.keypath ?? "__static__"
        let revision = hasDynamicSource ? String(viewModel.localMutationVersion) : "static"
        return "\(keypath)::\(revision)"
    }

    @ViewBuilder
    private func gridItemView(for value: ValueType) -> some View {
        if let itemSkeleton = skeletonGrid.itemSkeleton {
            SkeletonView(
                element: itemSkeleton,
                userInfoValue: gridResolvedUserInfoValue(from: value)
            )
            .environmentObject(viewModel)
        } else {
            VTVF.view(for: value)
        }
    }
}
