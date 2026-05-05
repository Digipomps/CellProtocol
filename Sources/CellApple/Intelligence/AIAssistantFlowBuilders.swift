// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import CellBase

// Builders for FlowElement payloads (.object) used by the AI assistant.
// We serialize payloads as ValueType.object so Emit can publish them as FlowElements.

public struct AIAssistantFlowBuilders {
    public init() {}

    // Snapshot payload of ai.* subtree
    public func statePayload(status: String,
                             currentPurposeRef: String?,
                             purposeClusterRefs: [String]?,
                             candidates: [CellConfiguration]?) -> ValueType {
        var obj = Object(propertyValues: [:])
        obj[AIKeys.status] = ValueType.string(status)
        if let ref = currentPurposeRef {
            obj[AIKeys.currentPurposeRef] = ValueType.string(ref)
        }
        if let cluster = purposeClusterRefs {
            obj[AIKeys.purposeClusterRefs] = ValueType.list(cluster.map { .string($0) })
        }
        if let confs = candidates {
            obj[AIKeys.candidates] = ValueType.list(ValueTypeList(confs.map { .cellConfiguration($0) }))
        }
        return .object(obj)
    }

    // Intent request for configurations
    public func requestPayload(currentPurposeRef: String?, purposeClusterRefs: [String]?, context: Object? = nil) -> ValueType {
        var obj = Object(propertyValues: [:])
        obj["debubMode"] = .string("false")
        if let ref = currentPurposeRef {
            obj["currentPurposeRef"] = ValueType.string(ref)
        }
        if let cluster = purposeClusterRefs {
            obj["purposeClusterRefs"] = ValueType.list(cluster.map { .string($0) })
        }
        if let ctx = context {
            obj["context"] = ValueType.object(ctx)
        }
        return .object(obj)
    }

    // Response payload shape (if we need to synthesize one)
    public func responsePayload(configurations: [CellConfiguration], meta: Object? = nil) -> ValueType {
        var obj = Object(propertyValues: [:])
        obj["configurations"] = ValueType.list(ValueTypeList(configurations.map { .cellConfiguration($0) }))
        if let meta = meta {
            obj["meta"] = ValueType.object(meta)
        }
        return .object(obj)
    }
}
