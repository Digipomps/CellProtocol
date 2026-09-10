// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

final class FlowElementPusherSecurityTests: XCTestCase {
    func testLocalProducerRequiresOwnerObjectAndNeverClaimsContractSignature() async throws {
        let owner = Identity()
        let copy = owner.publicIdentitySnapshot()
        let producer = FlowElementPusherCell(owner: owner)
        let admitted = await producer.admit(context: .init(source: nil, target: nil, identity: owner))
        let denied = await producer.admit(context: .init(source: nil, target: nil, identity: copy))
        XCTAssertEqual(admitted, .connected)
        XCTAssertEqual(denied, .denied)
        do {
            _ = try await producer.flow(requester: copy)
            XCTFail("A serializable identity claim is not a local producer capability")
        } catch { }
        let agreement = await producer.addAgreement(Agreement(owner: owner), for: owner)
        XCTAssertEqual(agreement, .rejected)
        var titles = [String]()
        var completions = 0
        let subscription = try await producer.flow(requester: owner).sink(receiveCompletion: { _ in
            completions += 1
        }, receiveValue: { titles.append($0.title) })
        producer.pushFlowElement(.init(title: "forged", content: .string("value"), properties: nil), requester: copy)
        producer.pushCompletion(error: nil, requester: copy)
        producer.pushFlowElement(.init(title: "owned", content: .string("value"), properties: nil), requester: owner)
        XCTAssertEqual(titles, ["owned"])
        XCTAssertEqual(completions, 0)
        producer.pushCompletion(error: nil, requester: owner)
        XCTAssertEqual(completions, 1)
        subscription.cancel()
    }
}
