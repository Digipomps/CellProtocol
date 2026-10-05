// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import Foundation
import XCTest
@testable import CellBase

/// Extract the payload an actual subscriber receives, without looking up current pending state.
func scannerPublishedAction(_ events: [FlowElement], name: String) throws -> ValueType {
    for event in events.reversed() {
        let value = try JSONDecoder().decode(ValueType.self, from: JSONEncoder().encode(event.content))
        if case let .object(payload) = value,
           case let .object(actions)? = payload["actions"],
           case let .object(action)? = actions[name], let result = action["payload"] { return result }
    }
    XCTFail("Missing published action: \(name)")
    throw NSError(domain: "Missing scanner action", code: 1)
}

func scannerDecisionID(_ action: ValueType, key: String = "decisionID") throws -> String {
    guard case let .object(payload) = action, case let .string(id)? = payload[key] else {
        throw NSError(domain: "Missing action instance ID", code: 1)
    }
    return id
}
