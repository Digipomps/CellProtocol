// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class PushFlowElementTests: XCTestCase {
    func testPushElementCleanInstantiatedCells() throws {
        
        let identity = Identity()
        let resolver = CellResolver.sharedInstance
        let cell = GeneralCell(owner: identity)
        
        let flowElement = FlowElement(title: "Test", content: .string("test  string"), properties: FeedItem.Properties(type: .content, contentType: .string))
        resolver.pushFlowElement(flowElement, into: cell)
        XCTAssertTrue(resolver.instantiatedCells.count == 0)
    }
    
    func testCeneralCellCleanConnectedPublishers() throws {
        
        let identity = Identity()
        let resolver = CellResolver.sharedInstance
        let cell = GeneralCell(owner: identity)
        
        let flowElement = FeedItem(title: "Test", content: .string("test  string"), properties: FeedItem.Properties(type: .content, contentType: .string))
        resolver.pushFeedItem(flowElement, into: cell)
        
        cell.disconnectAll(requester: identity)
        
        Task {
            let connectedLabels = await cell.connectedLabels(requester: identity)
            XCTAssertTrue(connectedLabels.count == 0)
        }
    }
}
