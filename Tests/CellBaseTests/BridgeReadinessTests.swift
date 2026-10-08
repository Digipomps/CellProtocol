// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

final class BridgeReadinessTests: XCTestCase {
    func testReadyFrameRacingSubscriptionDoesNotLoseReadiness() async throws {
        // A transport callback may deliver ready while the resolver begins
        // retrieveProxyRepresentation. Readiness must survive that handoff.
        for _ in 0..<16 {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<128 {
                    group.addTask {
                        let owner = Identity(UUID().uuidString, displayName: "ready-race", identityVault: nil)
                        let bridge = BridgeBase(owner: owner)
                        let waiter = Task { try await bridge.ready(timeout: 1) }
                        await Task.yield()
                        try await bridge.consumeCommand(command: BridgeCommand(cmd: Command.ready.rawValue, payload: nil, cid: 0))
                        try await waiter.value
                        // A late waiter must also observe the retained state.
                        try await bridge.ready(timeout: 1)
                    }
                }
                try await group.waitForAll()
            }
        }
    }

}
