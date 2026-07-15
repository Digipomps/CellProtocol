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
    private var previousExploreMode: CellBase.ExploreContractEnforcementMode = .permissive

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousExploreMode = CellBase.exploreContractEnforcementMode
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.exploreContractEnforcementMode = previousExploreMode
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

    func testDecodedCellImmediatelyRestoresStateActionsAndStableBindings() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let ownerCandidate = await vault.identity(for: "flow-cache-decoded-owner", makeNewIfNotFound: true)
        let outsiderCandidate = await vault.identity(for: "flow-cache-decoded-outsider", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(ownerCandidate)
        let outsider = try XCTUnwrap(outsiderCandidate)
        let source = await CacheSourceCell(owner: owner)
        let cache = await FlowCacheCell(owner: owner)

        _ = try await cache.set(
            keypath: "flowCache.capacity",
            value: .integer(2),
            requester: owner
        )
        try await cache.startCaching(
            upstream: source,
            requester: owner,
            targetEndpoint: "cell:///Source"
        )
        source.emit(id: "process-local-only")
        XCTAssertEqual(cache.cacheSnapshot().items.map(\.id), ["process-local-only"])

        let encoded = try JSONEncoder().encode(cache)
        let immediate = try JSONDecoder().decode(FlowCacheCell.self, from: encoded)
        let immediateKeys = try await immediate.keys(requester: owner)
        XCTAssertTrue(immediateKeys.contains("flowCache.status"))
        XCTAssertTrue(immediateKeys.contains("flowCache.clear"))

        let status = try await immediate.get(keypath: "flowCache.status", requester: owner)
        guard case let .object(statusObject) = status else {
            return XCTFail("Expected decoded status object")
        }
        XCTAssertEqual(statusObject["status"], .string("idle"))
        XCTAssertEqual(statusObject["target"], .string(""))
        XCTAssertEqual(statusObject["capacity"], .integer(FlowCacheCell.defaultCapacity))
        XCTAssertEqual(statusObject["cachedCount"], .integer(0))
        XCTAssertEqual(statusObject["totalReceived"], .integer(0))
        XCTAssertEqual(statusObject["reconnectReplayGuaranteed"], .bool(false))
        XCTAssertTrue(immediate.cacheSnapshot().items.isEmpty)
        XCTAssertEqual(immediate.persistancy, .ephemeral)

        let capacityResponse = try await immediate.set(
            keypath: "flowCache.capacity",
            value: .integer(7),
            requester: owner
        )
        XCTAssertEqual(capacityResponse, .integer(7))
        guard case let .object(clearResponse)? = try await immediate.set(
            keypath: "flowCache.clear",
            value: .null,
            requester: owner
        ) else {
            return XCTFail("Expected decoded clear action to dispatch")
        }
        XCTAssertEqual(clearResponse["status"], .string("idle"))

        try await CellContractHarness.assertGetDenied(
            on: immediate,
            key: "flowCache.status",
            requester: outsider
        )
        try await CellContractHarness.assertSetDenied(
            on: immediate,
            key: "flowCache.capacity",
            input: .integer(1),
            requester: outsider
        )
        do {
            _ = try await immediate.flow(requester: outsider)
            XCTFail("Outsider must not subscribe to the decoded cache")
        } catch StreamState.denied {
            // Expected.
        }

        let concurrent = try JSONDecoder().decode(FlowCacheCell.self, from: encoded)
        let persistedGrantCount = concurrent.agreementTemplate.grants.count
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    switch index % 3 {
                    case 0:
                        try await concurrent.ensureRuntimeReady()
                    case 1:
                        _ = try await concurrent.keys(requester: owner)
                    default:
                        _ = try await concurrent.get(keypath: "flowCache.status", requester: owner)
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(concurrent.agreementTemplate.grants.count, persistedGrantCount)
        XCTAssertEqual(
            concurrent.agreementTemplate.grants.filter {
                $0.keypath == "flowCache"
            }.count,
            1
        )
        let concurrentCapacityResponse = try await concurrent.set(
            keypath: "flowCache.capacity",
            value: .integer(9),
            requester: owner
        )
        XCTAssertEqual(concurrentCapacityResponse, .integer(9))
    }

    func testStrictExploreModeSupportsFreshAndDecodedFlowCache() async throws {
        CellBase.exploreContractEnforcementMode = .strict
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let ownerCandidate = await vault.identity(for: "flow-cache-strict-owner", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(ownerCandidate)
        let cache = await FlowCacheCell(owner: owner)

        try await CellContractHarness.assertAdvertisedKey(
            on: cache,
            key: "flowCache.status",
            requester: owner,
            expectedMethod: .get,
            expectedInputType: "null",
            expectedReturnType: "object"
        )
        try await CellContractHarness.assertAdvertisedKey(
            on: cache,
            key: "flowCache.capacity",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "integer",
            expectedReturnType: "oneOf"
        )
        try await CellContractHarness.assertAdvertisedKey(
            on: cache,
            key: "flowCache.clear",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "null",
            expectedReturnType: "object"
        )

        let decoded = try JSONDecoder().decode(
            FlowCacheCell.self,
            from: JSONEncoder().encode(cache)
        )
        guard case .object = try await decoded.get(keypath: "flowCache.status", requester: owner) else {
            return XCTFail("Strict decoded FlowCache status did not dispatch")
        }
        let capacityResponse = try await decoded.set(
            keypath: "flowCache.capacity",
            value: .integer(4),
            requester: owner
        )
        XCTAssertEqual(capacityResponse, .integer(4))
    }

    func testCellJSONCoderReturnsRuntimeReadyFlowCache() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let ownerCandidate = await vault.identity(for: "flow-cache-coder-owner", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(ownerCandidate)
        let source = await FlowCacheCell(owner: owner)
        let encoded = try CellJSONCoder.encodeCell(cellClassName: "FlowCacheCell", cell: source)
        var coder = CellJSONCoder()
        try coder.register(name: "FlowCacheCell", type: FlowCacheCell.self)

        let emit = try await coder.decodeRuntimeReadyEmitCell(from: encoded)
        let decoded = try XCTUnwrap(emit as? FlowCacheCell)
        let keys = try await decoded.keys(requester: owner)
        XCTAssertTrue(keys.contains("flowCache.status"))
        guard case .object = try await decoded.get(keypath: "flowCache.status", requester: owner) else {
            return XCTFail("Runtime-ready decoder did not install FlowCache state")
        }
        guard case .object? = try await decoded.set(
            keypath: "flowCache.clear",
            value: .null,
            requester: owner
        ) else {
            return XCTFail("Runtime-ready decoder did not install FlowCache actions")
        }
    }
}
