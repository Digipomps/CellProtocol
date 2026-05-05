// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  CellReferenceView.swift
//  HAVEN_MVP
//
//  Created by Kjetil Hustveit on 15/10/2024.
//

import SwiftUI
import CellBase


struct CellReferenceView: View {
    let userInfoValue: ValueType?
    var skeletonReference: SkeletonCellReference
    @EnvironmentObject var viewModel: PortholeViewModel

    init(skeletonReference: SkeletonCellReference, userInfoValue: ValueType? = nil) {
        self.skeletonReference = skeletonReference
        self.userInfoValue = userInfoValue
    }

    private func flowElementUserInfoValue(_ flowElement: FlowElement) -> ValueType {
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

    var body: some View {
        ScrollView {
            ForEach(viewModel.flowElements.filter({ fe in
                let topicMatch = fe.topic == self.skeletonReference.topic
                let typeMatch: Bool = {
                    if let types = self.skeletonReference.filterTypes, !types.isEmpty {
                        return types.contains(fe.properties?.type.rawValue ?? "TypeNotSet")
                    }
                    return true
                }()
                return topicMatch && typeMatch
            })) { flowElement in
                VStack(alignment: .leading) {
                    Text(flowElement.topic)
                    if let skeletonVStack = skeletonReference.flowElementSkeleton {
                        SkeletonView(
                            element: .VStack(skeletonVStack),
                            userInfoValue: flowElementUserInfoValue(flowElement)
                        )
                            .environmentObject(viewModel)
                    } else {
                        if let contentValue = try? flowElement.content.valueType() {
                            VTVF.view(for: contentValue)
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    CellReferenceView(skeletonReference: SkeletonCellReference(keypath: "test", topic: "test"))
        .environmentObject(PortholeViewModel())
}
