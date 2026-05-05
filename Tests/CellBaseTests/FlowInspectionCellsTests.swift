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

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousResolver = CellBase.defaultCellResolver
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.defaultCellResolver = previousResolver
        super.tearDown()
    }

    func testFlowProbeCapturesMatchingFlowElements() async throws {
        let vault = MockIdentityVault()
        let resolver = MockCellResolver()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver

        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let source = await ProbeSourceCell(owner: owner)
        try await resolver.registerNamedEmitCell(name: "ProbeSource", emitCell: source, scope: .template, identity: owner)

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
