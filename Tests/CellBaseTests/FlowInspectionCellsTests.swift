// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@testable import CellBase

final class FlowInspectionCellsTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousResolver: CellResolverProtocol?
    private var previousExploreMode: CellBase.ExploreContractEnforcementMode = .permissive

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousResolver = CellBase.defaultCellResolver
        previousExploreMode = CellBase.exploreContractEnforcementMode
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.defaultCellResolver = previousResolver
        CellBase.exploreContractEnforcementMode = previousExploreMode
        super.tearDown()
    }

    func testStrictExploreModeKeepsDecodedDiagnosticHandlersDispatchable() async throws {
        CellBase.exploreContractEnforcementMode = .strict
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let outsider = await vault.identity(for: "outsider", makeNewIfNotFound: true)!

        let flowProbe = try JSONDecoder().decode(
            FlowProbeCell.self,
            from: JSONEncoder().encode(await FlowProbeCell(owner: owner))
        )
        guard case .object = try await flowProbe.get(
            keypath: "flowProbe.status",
            requester: owner
        ) else {
            return XCTFail("Strict decoded FlowProbe status handler was not installed")
        }
        let configuredFlowTarget = try await flowProbe.set(
            keypath: "flowProbe.target",
            value: .string("cell:///StrictProbeSource"),
            requester: owner
        )
        guard case .object = configuredFlowTarget else {
            return XCTFail("Strict decoded FlowProbe target action was not installed")
        }
        try await CellContractHarness.assertAdvertisedKey(
            on: flowProbe,
            key: "flowProbe.target",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "oneOf",
            expectedReturnType: "oneOf"
        )
        try await CellContractHarness.assertPermissions(
            on: flowProbe,
            key: "flowProbe.target",
            requester: owner,
            expected: ["-w--"]
        )

        let snapshot = try JSONDecoder().decode(
            StateSnapshotCell.self,
            from: JSONEncoder().encode(await StateSnapshotCell(owner: owner))
        )
        guard case .object = try await snapshot.get(
            keypath: "stateSnapshot.status",
            requester: owner
        ) else {
            return XCTFail("Strict decoded StateSnapshot status handler was not installed")
        }
        let configuredSnapshotTarget = try await snapshot.set(
            keypath: "stateSnapshot.target",
            value: .string("cell:///StrictSnapshotSource"),
            requester: owner
        )
        guard case .object = configuredSnapshotTarget else {
            return XCTFail("Strict decoded StateSnapshot target action was not installed")
        }
        try await CellContractHarness.assertAdvertisedKey(
            on: snapshot,
            key: "stateSnapshot.capture",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "oneOf",
            expectedReturnType: "oneOf"
        )
        try await CellContractHarness.assertPermissions(
            on: snapshot,
            key: "stateSnapshot.capture",
            requester: owner,
            expected: ["-w--"]
        )
        try await CellContractHarness.assertSetDenied(
            on: flowProbe,
            key: "flowProbe.clear",
            input: .null,
            requester: outsider
        )
        try await CellContractHarness.assertGetDenied(
            on: snapshot,
            key: "stateSnapshot.history",
            requester: outsider
        )
    }

    func testFlowProbeCapturesMatchingFlowElements() async throws {
        let vault = MockIdentityVault()
        let resolver = MockCellResolver()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver

        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let source = await ProbeSourceCell(owner: owner)
        try await resolver.registerNamedEmitCell(name: "ProbeSource", emitCell: source, scope: .template, identity: owner)

        CellBase.exploreContractEnforcementMode = .strict
        let flowProbe = await FlowProbeCell(owner: owner)
        _ = try await flowProbe.set(keypath: "flowProbe.target", value: .string("cell:///ProbeSource"), requester: owner)
        _ = try await flowProbe.set(
            keypath: "flowProbe.filters",
            value: .object([
                "topics": .list([.string("probe.updated")]),
                "limit": .integer(5)
            ]),
            requester: owner
        )

        _ = try await flowProbe.set(keypath: "flowProbe.start", value: .null, requester: owner)
        _ = try await source.set(
            keypath: "emitEvent",
            value: .object([
                "topic": .string("probe.ignored"),
                "message": .string("ignore")
            ]),
            requester: owner
        )
        _ = try await source.set(
            keypath: "emitEvent",
            value: .object([
                "topic": .string("probe.updated"),
                "message": .string("observe")
            ]),
            requester: owner
        )

        try await Task.sleep(nanoseconds: 100_000_000)

        let currentValue = try await flowProbe.get(keypath: "flowProbe.trace.current", requester: owner)
        let currentPayload = try extractObject(from: currentValue, key: "trace")
        let trace: FlowProbeTrace = try decode(currentPayload)
        XCTAssertEqual(trace.status, .running)
        XCTAssertEqual(trace.matchedCount, 1)
        XCTAssertEqual(trace.observations.count, 1)
        XCTAssertEqual(trace.observations.first?.flowElement.topic, "probe.updated")
        XCTAssertEqual(trace.observations.first?.flowElement.origin, source.uuid)

        _ = try await flowProbe.set(keypath: "flowProbe.stop", value: .null, requester: owner)
        let tracesValue = try await flowProbe.get(keypath: "flowProbe.traces", requester: owner)
        let tracesPayload = try extractObject(from: tracesValue, key: "items")
        let traces: [FlowProbeTrace] = try decode(tracesPayload)
        XCTAssertEqual(traces.count, 1)
        XCTAssertEqual(traces.first?.status, .stopped)
    }

    func testStateSnapshotCapturesAndDiffsSelectedKeys() async throws {
        let vault = MockIdentityVault()
        let resolver = MockCellResolver()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver

        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let source = await ProbeSourceCell(owner: owner)
        try await resolver.registerNamedEmitCell(name: "SnapshotSource", emitCell: source, scope: .template, identity: owner)

        CellBase.exploreContractEnforcementMode = .strict
        let snapshotCell = await StateSnapshotCell(owner: owner)
        _ = try await snapshotCell.set(keypath: "stateSnapshot.target", value: .string("cell:///SnapshotSource"), requester: owner)
        _ = try await snapshotCell.set(
            keypath: "stateSnapshot.keys",
            value: .list([.string("state"), .string("details")]),
            requester: owner
        )

        _ = try await snapshotCell.set(keypath: "stateSnapshot.capture", value: .null, requester: owner)
        _ = try await source.set(
            keypath: "mutate",
            value: .object([
                "headline": .string("Updated headline"),
                "count": .integer(2)
            ]),
            requester: owner
        )
        _ = try await snapshotCell.set(keypath: "stateSnapshot.capture", value: .null, requester: owner)

        let diffValue = try await snapshotCell.set(keypath: "stateSnapshot.diff", value: .null, requester: owner)
        guard let diffValue else {
            XCTFail("Expected diff payload")
            return
        }
        let diffPayload = try extractObject(from: diffValue, key: "diff")
        let diff: StateSnapshotDiffRecord = try decode(diffPayload)
        XCTAssertEqual(diff.changeCount, 2)
        XCTAssertTrue(diff.entries.contains(where: { $0.key == "state" && $0.kind == .changed }))
        XCTAssertTrue(diff.entries.contains(where: { $0.key == "details" && $0.kind == .changed }))

        let currentValue = try await snapshotCell.get(keypath: "stateSnapshot.current", requester: owner)
        let snapshotPayload = try extractObject(from: currentValue, key: "snapshot")
        let snapshot: StateSnapshotRecord = try decode(snapshotPayload)
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertEqual(snapshot.items.first(where: { $0.key == "state" })?.status, .ok)
    }

    func testDecodedFlowProbeSupportsImmediateReadAndActionAndConcurrentReadiness() async throws {
        CellBase.exploreContractEnforcementMode = .strict
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault

        let ownerCandidate = await vault.identity(for: "private", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(ownerCandidate)
        let original = await FlowProbeCell(owner: owner)
        _ = try await original.set(
            keypath: "flowProbe.target",
            value: .string("cell:///PersistedFlowSource"),
            requester: owner
        )
        let encoded = try JSONEncoder().encode(original)

        let immediate = try JSONDecoder().decode(FlowProbeCell.self, from: encoded)
        let target = try await immediate.get(keypath: "flowProbe.target.current", requester: owner)
        guard case let .object(targetObject) = target else {
            XCTFail("Expected the decoded flow probe target payload")
            return
        }
        XCTAssertEqual(targetObject["configured"], .bool(true))
        _ = try await immediate.set(
            keypath: "flowProbe.filters",
            value: .object([
                "topics": .list([.string("persisted.updated")]),
                "limit": .integer(7)
            ]),
            requester: owner
        )
        let filters = try await immediate.get(keypath: "flowProbe.filters.current", requester: owner)
        let filterPayload = try extractObject(from: filters, key: "filter")
        let decodedFilter: FlowProbeFilter = try decode(filterPayload)
        XCTAssertEqual(decodedFilter.topics, ["persisted.updated"])
        XCTAssertEqual(decodedFilter.limit, 7)

        let concurrent = try JSONDecoder().decode(FlowProbeCell.self, from: encoded)
        let readiness = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    try await concurrent.ensureRuntimeReady()
                    return try await concurrent.keys(requester: owner).contains("flowProbe.start")
                }
            }
            var results = [Bool]()
            for try await result in group {
                results.append(result)
            }
            return results
        }
        XCTAssertEqual(readiness.count, 24)
        XCTAssertTrue(readiness.allSatisfy { $0 })
        XCTAssertEqual(
            concurrent.agreementTemplate.grants.filter {
                $0.keypath == "flowProbe" && $0.permission.permissionString == "rw--"
            }.count,
            1
        )
    }

    func testDecodedStateSnapshotSupportsImmediateReadAndActionAndConcurrentReadiness() async throws {
        CellBase.exploreContractEnforcementMode = .strict
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault

        let ownerCandidate = await vault.identity(for: "private", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(ownerCandidate)
        let original = await StateSnapshotCell(owner: owner)
        _ = try await original.set(
            keypath: "stateSnapshot.target",
            value: .string("cell:///PersistedSnapshotSource"),
            requester: owner
        )
        _ = try await original.set(
            keypath: "stateSnapshot.keys",
            value: .list([.string("state")]),
            requester: owner
        )
        let encoded = try JSONEncoder().encode(original)

        let immediate = try JSONDecoder().decode(StateSnapshotCell.self, from: encoded)
        let target = try await immediate.get(keypath: "stateSnapshot.target.current", requester: owner)
        guard case let .object(targetObject) = target else {
            XCTFail("Expected the decoded state snapshot target payload")
            return
        }
        XCTAssertEqual(targetObject["configured"], .bool(true))
        _ = try await immediate.set(
            keypath: "stateSnapshot.keys",
            value: .list([.string("details"), .string("state")]),
            requester: owner
        )
        let keys = try await immediate.get(keypath: "stateSnapshot.keys.current", requester: owner)
        guard case let .object(keysObject) = keys else {
            XCTFail("Expected the decoded state snapshot key payload")
            return
        }
        guard case let .list(keyValues)? = keysObject["keys"] else {
            XCTFail("Expected the decoded state snapshot key list")
            return
        }
        XCTAssertEqual(keyValues.compactMap {
            guard case let .string(key) = $0 else { return nil }
            return key
        }, ["details", "state"])

        let concurrent = try JSONDecoder().decode(StateSnapshotCell.self, from: encoded)
        let readiness = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    try await concurrent.ensureRuntimeReady()
                    return try await concurrent.keys(requester: owner).contains("stateSnapshot.capture")
                }
            }
            var results = [Bool]()
            for try await result in group {
                results.append(result)
            }
            return results
        }
        XCTAssertEqual(readiness.count, 24)
        XCTAssertTrue(readiness.allSatisfy { $0 })
        XCTAssertEqual(
            concurrent.agreementTemplate.grants.filter {
                $0.keypath == "stateSnapshot" && $0.permission.permissionString == "rw--"
            }.count,
            1
        )
    }

    private func extractObject(from value: ValueType, key: String) throws -> ValueType {
        guard case let .object(object) = value, let nested = object[key] else {
            throw NSError(domain: "FlowInspectionCellsTests", code: 1)
        }
        return nested
    }

    private func decode<T: Decodable>(_ value: ValueType, as type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private final class ProbeSourceCell: GeneralCell {
    private var headline = "Initial headline"
    private var count = 1

    required init(owner: Identity) async {
        await super.init(owner: owner)
        await setupPermissions(owner: owner)
        await setupKeys(owner: owner)
    }

    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        Task {
            await self.setupPermissions(owner: self.owner)
            await self.setupKeys(owner: self.owner)
        }
    }

    private func setupPermissions(owner: Identity) async {
        agreementTemplate.addGrant("r---", for: "state")
        agreementTemplate.addGrant("r---", for: "details")
        agreementTemplate.addGrant("rw--", for: "mutate")
        agreementTemplate.addGrant("rw--", for: "emitEvent")
        agreementTemplate.addGrant("rw--", for: "feed")
    }

    private func setupKeys(owner: Identity) async {
        await registerExploreSchema(
            requester: owner,
            key: "state",
            schema: .object([
                "headline": .string("string"),
                "count": .string("integer")
            ])
        )
        await registerExploreSchema(
            requester: owner,
            key: "details",
            schema: .object([
                "headlineLength": .string("integer"),
                "isUpdated": .string("bool")
            ])
        )
        await registerExploreSchema(
            requester: owner,
            key: "mutate",
            schema: .object([
                "headline": .string("string"),
                "count": .string("integer")
            ])
        )
        await registerExploreSchema(
            requester: owner,
            key: "emitEvent",
            schema: .object([
                "topic": .string("string"),
                "message": .string("string")
            ])
        )

        await addInterceptForGet(requester: owner, key: "state") { [weak self] _, requester in
            guard let self else { return .null }
            guard await self.validateAccess("r---", at: "state", for: requester) else { return .string("denied") }
            return self.stateValue()
        }

        await addInterceptForGet(requester: owner, key: "details") { [weak self] _, requester in
            guard let self else { return .null }
            guard await self.validateAccess("r---", at: "details", for: requester) else { return .string("denied") }
            return self.detailsValue()
        }

        await addInterceptForSet(requester: owner, key: "mutate") { [weak self] _, value, requester in
            guard let self else { return .null }
            guard await self.validateAccess("-w--", at: "mutate", for: requester) else { return .string("denied") }
            if case let .object(object) = value {
                if case let .string(headline)? = object["headline"] {
                    self.headline = headline
                }
                if case let .integer(count)? = object["count"] {
                    self.count = count
                }
            }
            return self.stateValue()
        }

        await addInterceptForSet(requester: owner, key: "emitEvent") { [weak self] _, value, requester in
            guard let self else { return .null }
            guard await self.validateAccess("-w--", at: "emitEvent", for: requester) else { return .string("denied") }
            let payloadObject = DiagnosticProbeCodec.object(from: value) ?? [:]
            let topic = DiagnosticProbeCodec.string(from: payloadObject["topic"]) ?? "probe.updated"
            let message = DiagnosticProbeCodec.string(from: payloadObject["message"]) ?? "event"
            var flowElement = FlowElement(
                title: "Probe source event",
                content: .object([
                    "message": .string(message),
                    "count": .integer(self.count)
                ]),
                properties: FlowElement.Properties(type: .event, contentType: .object)
            )
            flowElement.topic = topic
            flowElement.origin = self.uuid
            self.pushFlowElement(flowElement, requester: requester)
            return .object([
                "status": .string("ok"),
                "topic": .string(topic)
            ])
        }
    }

    private func stateValue() -> ValueType {
        .object([
            "headline": .string(headline),
            "count": .integer(count)
        ])
    }

    private func detailsValue() -> ValueType {
        .object([
            "headlineLength": .integer(headline.count),
            "isUpdated": .bool(count > 1)
        ])
    }
}
