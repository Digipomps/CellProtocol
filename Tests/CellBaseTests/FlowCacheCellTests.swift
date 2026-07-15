// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@testable import CellBase

final class FlowCacheCellTests: XCTestCase {
    private final class CacheSourceCell: GeneralCell {
        private let subject = PassthroughSubject<FlowElement, Error>()
        private let stateLock = NSLock()
        private var flowRequests = 0

        required init(owner: Identity) async {
            await super.init(owner: owner)
        }

        required init(from decoder: Decoder) throws {
            try super.init(from: decoder)
        }

        override func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, Error> {
            _ = requester
            stateLock.withLock { flowRequests += 1 }
            return subject.eraseToAnyPublisher()
        }

        func emit(id: String) {
            subject.send(FlowElement(
                id: id,
                title: id,
                content: .string(id),
                properties: .init(type: .event, contentType: .string)
            ))
        }

        func flowRequestCount() -> Int {
            stateLock.withLock { flowRequests }
        }
    }

    private var previousVault: IdentityVaultProtocol?

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        super.tearDown()
    }

    func testBoundedCacheReplaysLatestElementsThenContinuesLiveWithOneUpstreamFlow() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let ownerValue = await vault.identity(for: "flow-cache-owner", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(ownerValue)
        let source = await CacheSourceCell(owner: owner)
        let cache = await FlowCacheCell(owner: owner)
        _ = try await cache.set(keypath: "flowCache.capacity", value: .integer(2), requester: owner)
        try await cache.startCaching(
            upstream: source,
            requester: owner,
            targetEndpoint: "cell:///Source"
        )

        source.emit(id: "one")
        source.emit(id: "two")
        source.emit(id: "three")

        let replayed = expectation(description: "late subscriber receives bounded replay")
        replayed.expectedFulfillmentCount = 2
        let live = expectation(description: "late subscriber continues with live flow")
        let valuesLock = NSLock()
        var received: [String] = []
        let firstCancellable = try await cache.flow(requester: owner).sink(
            receiveCompletion: { _ in },
            receiveValue: { element in
                let count = valuesLock.withLock { () -> Int in
                    received.append(element.id)
                    return received.count
                }
                if count <= 2 {
                    replayed.fulfill()
                }
                if element.id == "four" {
                    live.fulfill()
                }
            }
        )

        await fulfillment(of: [replayed], timeout: 1)
        XCTAssertEqual(valuesLock.withLock { received }, ["two", "three"])

        source.emit(id: "four")
        await fulfillment(of: [live], timeout: 1)
        XCTAssertEqual(valuesLock.withLock { received }, ["two", "three", "four"])

        let secondReplay = expectation(description: "second subscriber receives current bounded replay")
        secondReplay.expectedFulfillmentCount = 2
        var secondValues: [String] = []
        let secondCancellable = try await cache.flow(requester: owner).sink(
            receiveCompletion: { _ in },
            receiveValue: { element in
                secondValues.append(element.id)
                if secondValues.count <= 2 {
                    secondReplay.fulfill()
                }
            }
        )
        await fulfillment(of: [secondReplay], timeout: 1)

        XCTAssertEqual(secondValues, ["three", "four"])
        XCTAssertEqual(source.flowRequestCount(), 1)
        let snapshot = cache.cacheSnapshot()
        XCTAssertEqual(snapshot.capacity, 2)
        XCTAssertEqual(snapshot.totalReceived, 4)
        XCTAssertEqual(snapshot.droppedCount, 2)
        XCTAssertEqual(snapshot.items.map(\.id), ["three", "four"])
        XCTAssertEqual(cache.persistancy, .ephemeral)
        withExtendedLifetime((firstCancellable, secondCancellable)) {}
    }

    func testExploreContractStatesProcessLocalSemanticsAndExposesBoundedItems() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let ownerValue = await vault.identity(for: "flow-cache-explore-owner", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(ownerValue)
        let source = await CacheSourceCell(owner: owner)
        let cache = await FlowCacheCell(owner: owner)
        try await cache.startCaching(upstream: source, requester: owner)
        source.emit(id: "visible")

        let keys = try await cache.keys(requester: owner)
        XCTAssertTrue(keys.contains("flowCache.status"))
        XCTAssertTrue(keys.contains("flowCache.items"))
        XCTAssertTrue(keys.contains("flowCache.start"))
        _ = try await cache.typeForKey(key: "flowCache.status", requester: owner)

        let status = try await cache.get(keypath: "flowCache.status", requester: owner)
        guard case let .object(statusObject) = status else {
            return XCTFail("Expected status object")
        }
        XCTAssertEqual(statusObject["replayScope"], .string("process-local"))
        XCTAssertEqual(statusObject["reconnectReplayGuaranteed"], .bool(false))
        XCTAssertEqual(statusObject["cachedCount"], .integer(1))

        let items = try await cache.get(keypath: "flowCache.items", requester: owner)
        guard case let .list(itemValues) = items,
              case let .flowElement(item)? = itemValues.first else {
            return XCTFail("Expected cached flow element list")
        }
        XCTAssertEqual(item.id, "visible")
    }
}
