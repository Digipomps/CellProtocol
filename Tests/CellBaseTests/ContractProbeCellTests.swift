// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@testable import CellBase

final class ContractProbeCellTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousResolver: CellResolverProtocol?
    private var previousDebugFlag = false

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousResolver = CellBase.defaultCellResolver
        previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = false
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.defaultCellResolver = previousResolver
        CellBase.debugValidateAccessForEverything = previousDebugFlag
        super.tearDown()
    }

    func testProbeRunPublishesReportAndFlowEvents() async throws {
        let vault = MockIdentityVault()
        let resolver = MockCellResolver()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver

        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let target = await makeProbeTarget(owner: owner)
        try await resolver.registerNamedEmitCell(name: "ProbeTarget", emitCell: target, scope: .template, identity: owner)

        let probe = await ContractProbeCell(owner: owner)

        let feed = try await probe.flow(requester: owner)
        let finishedExpectation = expectation(description: "probe finished")
        let flowObservedExpectation = expectation(description: "probe observed target flow")
        let passedExpectation = expectation(description: "probe emitted assertion passed")
        passedExpectation.assertForOverFulfill = false

        let lock = NSLock()
        var observedTopics = [String]()
        var observedOrigins = [String: String]()
        let cancellable = feed.sink(
            receiveCompletion: { _ in },
            receiveValue: { flowElement in
                lock.lock()
                observedTopics.append(flowElement.topic)
                observedOrigins[flowElement.topic] = flowElement.origin ?? ""
                lock.unlock()

                if flowElement.topic == "contract.assertion.passed" {
                    passedExpectation.fulfill()
                }
                if flowElement.topic == "contract.flow.observed" {
                    flowObservedExpectation.fulfill()
                }
                if flowElement.topic == "contract.run.finished" {
                    finishedExpectation.fulfill()
                }
            }
        )
        defer { cancellable.cancel() }

        _ = try await probe.set(
            keypath: "probe.target",
            value: .string("cell:///ProbeTarget"),
            requester: owner
        )

        let response = try await probe.set(
            keypath: "probe.run",
            value: .object([
                "sampleInputs": .object([
                    "publish": .object(["message": .string("Hello from probe")])
                ])
            ]),
            requester: owner
        )

        let report: ContractProbeReport = try decode(response)
        XCTAssertEqual(report.status, .completed)
        XCTAssertEqual(report.failedCount, 0)
        XCTAssertGreaterThan(report.passedCount, 0)
        XCTAssertTrue(report.assertions.contains(where: { $0.phase == "permissions.set" && $0.status == .passed }))
        XCTAssertTrue(report.assertions.contains(where: { $0.phase == "behavior.invalidInput" && $0.status == .passed }))
        XCTAssertTrue(report.assertions.contains(where: { $0.phase == "flow.publish.completed" && $0.status == .passed }))

        let lastReportValue = try await probe.get(keypath: "probe.lastReport", requester: owner)
        let lastReport: ContractProbeReport = try decode(lastReportValue)
        XCTAssertEqual(lastReport.id, report.id)

        await fulfillment(of: [passedExpectation, flowObservedExpectation, finishedExpectation], timeout: 1.0)

        let topics = lock.withValue { observedTopics }
        XCTAssertTrue(topics.contains("contract.run.started"))
        XCTAssertTrue(topics.contains("contract.assertion.passed"))
        XCTAssertTrue(topics.contains("contract.flow.observed"))
        XCTAssertTrue(topics.contains("contract.run.finished"))
        let origins = lock.withValue { observedOrigins }
        XCTAssertEqual(origins["contract.run.started"], probe.uuid)
        XCTAssertEqual(origins["contract.flow.observed"], probe.uuid)
        XCTAssertEqual(origins["contract.run.finished"], probe.uuid)
    }

    func testProbeReportsExpectedContractMismatch() async throws {
        let vault = MockIdentityVault()
        let resolver = MockCellResolver()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver

        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let target = await makeProbeTarget(owner: owner)
        try await resolver.registerNamedEmitCell(name: "ProbeMismatchTarget", emitCell: target, scope: .template, identity: owner)

        let probe = await ContractProbeCell(owner: owner)
        _ = try await probe.set(keypath: "probe.target", value: .string("cell:///ProbeMismatchTarget"), requester: owner)

        let mismatchedContract = ExploreContract.keyContract(
            key: "publish",
            method: .set,
            input: ExploreContract.objectSchema(
                properties: ["message": ExploreContract.schema(type: "string")],
                requiredKeys: ["message"]
            ),
            returns: ExploreContract.objectSchema(
                properties: ["status": ExploreContract.schema(type: "integer")],
                requiredKeys: ["status"]
            ),
            permissions: ["-w--"],
            required: true,
            summary: "Wrong expected return type"
        )

        _ = try await probe.set(
            keypath: "probe.contract",
            value: .list([mismatchedContract]),
            requester: owner
        )

        let response = try await probe.set(
            keypath: "probe.run",
            value: .object([
                "sampleInputs": .object([
                    "publish": .object(["message": .string("Mismatch")])
                ])
            ]),
            requester: owner
        )

        let report: ContractProbeReport = try decode(response)
        XCTAssertEqual(report.status, .failed)
        XCTAssertGreaterThan(report.failedCount, 0)
        XCTAssertTrue(report.usedExpectedContracts)
        XCTAssertTrue(
            report.assertions.contains(where: {
                $0.phase == "contract.expectedEquality" && $0.status == .failed && $0.key == "publish"
            })
        )
    }

    func testProbeTargetAcceptsCellConfigurationPayload() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault

        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let probe = await ContractProbeCell(owner: owner)

        var configuration = CellConfiguration(name: "Probe target config")
        configuration.cellReferences = [CellReference(endpoint: "cell:///ConfigTarget", label: "config-target")]

        let encodedConfiguration = try encode(configuration)
        let response = try await probe.set(
            keypath: "probe.target",
            value: encodedConfiguration,
            requester: owner
        )

        guard case let .object(object)? = response else {
            XCTFail("Expected object response")
            return
        }
        XCTAssertEqual(object["status"], .string("ok"))

        let currentValue = try await probe.get(keypath: "probe.target.current", requester: owner)
        guard case let .object(currentObject) = currentValue,
              case let .bool(configured)? = currentObject["configured"],
              configured,
              let targetValue = currentObject["target"] else {
            XCTFail("Expected configured target payload")
            return
        }

        let target: ContractProbeTarget = try decode(targetValue)
        XCTAssertEqual(target.endpoint, "cell:///ConfigTarget")
        XCTAssertEqual(target.label, "config-target")
    }

    func testProbeTargetSelectsDiscoveryEndpointFromNestedCellReferences() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault

        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let probe = await ContractProbeCell(owner: owner)

        var configuration = CellConfiguration(name: "Probe nested target config")
        configuration.discovery = CellConfigurationDiscovery(
            sourceCellEndpoint: "cell:///NestedTarget",
            sourceCellName: "nested-target"
        )
        let nestedTarget = CellReference(endpoint: "cell:///NestedTarget", label: "nested-target")
        let parent = CellReference(
            endpoint: "cell:///Parent",
            label: "parent",
            subscriptions: [nestedTarget]
        )
        let sibling = CellReference(endpoint: "cell:///Sibling", label: "sibling")
        configuration.cellReferences = [parent, sibling]

        let response = try await probe.set(
            keypath: "probe.target",
            value: try encode(configuration),
            requester: owner
        )

        guard case let .object(object)? = response else {
            XCTFail("Expected object response")
            return
        }
        XCTAssertEqual(object["status"], .string("ok"))

        let currentValue = try await probe.get(keypath: "probe.target.current", requester: owner)
        let current: ValueType = currentValue
        let target: ContractProbeTarget = try decode((ExploreContract.object(from: current)?["target"]))
        XCTAssertEqual(target.endpoint, "cell:///NestedTarget")
        XCTAssertEqual(target.label, "nested-target")
    }

    func testProbeTargetRejectsAmbiguousCellConfiguration() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault

        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let probe = await ContractProbeCell(owner: owner)

        var configuration = CellConfiguration(name: "Ambiguous probe target config")
        configuration.cellReferences = [
            CellReference(endpoint: "cell:///First", label: "first"),
            CellReference(endpoint: "cell:///Second", label: "second")
        ]

        let response = try await probe.set(
            keypath: "probe.target",
            value: try encode(configuration),
            requester: owner
        )

        guard case let .object(object)? = response else {
            XCTFail("Expected object response")
            return
        }
        XCTAssertEqual(object["status"], .string("error"))
        XCTAssertTrue((ExploreContract.string(from: object["message"]) ?? "").contains("multiple cellReferences"))
    }

    func testProbeIgnoresForeignOriginFlowEvents() async throws {
        let vault = MockIdentityVault()
        let resolver = MockCellResolver()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver

        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let target = await makeProbeTarget(owner: owner, emitTargetOrigin: true, emitForeignOriginNoise: true)
        try await resolver.registerNamedEmitCell(name: "ProbeTargetForeignNoise", emitCell: target, scope: .template, identity: owner)

        let probe = await ContractProbeCell(owner: owner)
        _ = try await probe.set(keypath: "probe.target", value: .string("cell:///ProbeTargetForeignNoise"), requester: owner)

        let response = try await probe.set(
            keypath: "probe.run",
            value: .object([
                "sampleInputs": .object([
                    "publish": .object(["message": .string("Hello with noise")])
                ])
            ]),
            requester: owner
        )

        let report: ContractProbeReport = try decode(response)
        XCTAssertEqual(report.status, .completed)
        XCTAssertTrue(
            report.assertions.contains(where: {
                $0.phase == "flow.publish.completed" &&
                $0.status == .passed &&
                $0.message.contains("ignored 0 event(s) without origin plus 1 foreign-origin event")
            })
        )
    }

    func testProbeFailsFlowCheckWhenOriginIsMissing() async throws {
        let vault = MockIdentityVault()
        let resolver = MockCellResolver()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver

        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let target = await makeProbeTarget(owner: owner, emitTargetOrigin: false)
        try await resolver.registerNamedEmitCell(name: "ProbeTargetMissingOrigin", emitCell: target, scope: .template, identity: owner)

        let probe = await ContractProbeCell(owner: owner)
        _ = try await probe.set(keypath: "probe.target", value: .string("cell:///ProbeTargetMissingOrigin"), requester: owner)

        let response = try await probe.set(
            keypath: "probe.run",
            value: .object([
                "sampleInputs": .object([
                    "publish": .object(["message": .string("Hello without origin")])
                ])
            ]),
            requester: owner
        )

        let report: ContractProbeReport = try decode(response)
        XCTAssertEqual(report.status, .failed)
        XCTAssertTrue(
            report.assertions.contains(where: {
                $0.phase == "flow.publish.completed" &&
                $0.status == .failed &&
                $0.message.contains("without origin")
            })
        )
    }

    func testProbeUsesCausationKeyToIgnoreSameOriginWrongInvocationEvents() async throws {
        let vault = MockIdentityVault()
        let resolver = MockCellResolver()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver

        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let target = await makeProbeTarget(
            owner: owner,
            emitTargetOrigin: true,
            causationKey: "causation_id",
            emitForeignCausationNoise: true
        )
        try await resolver.registerNamedEmitCell(name: "ProbeTargetCausationNoise", emitCell: target, scope: .template, identity: owner)

        let probe = await ContractProbeCell(owner: owner)
        _ = try await probe.set(keypath: "probe.target", value: .string("cell:///ProbeTargetCausationNoise"), requester: owner)

        let response = try await probe.set(
            keypath: "probe.run",
            value: .object([
                "sampleInputs": .object([
                    "publish": .object(["message": .string("Hello with causation")])
                ])
            ]),
            requester: owner
        )

        let report: ContractProbeReport = try decode(response)
        XCTAssertEqual(report.status, .completed)
        XCTAssertTrue(
            report.assertions.contains(where: {
                $0.phase == "flow.publish.completed" &&
                $0.status == .passed &&
                $0.message.contains("`causation_id`") &&
                $0.message.contains("different `causation_id`")
            })
        )
    }

    func testProbeFailsFlowCheckWhenCausationIDIsMissing() async throws {
        let vault = MockIdentityVault()
        let resolver = MockCellResolver()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver

        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let target = await makeProbeTarget(
            owner: owner,
            emitTargetOrigin: true,
            causationKey: "causation_id",
            includeCausationInFlowPayload: false
        )
        try await resolver.registerNamedEmitCell(name: "ProbeTargetMissingCausation", emitCell: target, scope: .template, identity: owner)

        let probe = await ContractProbeCell(owner: owner)
        _ = try await probe.set(keypath: "probe.target", value: .string("cell:///ProbeTargetMissingCausation"), requester: owner)

        let response = try await probe.set(
            keypath: "probe.run",
            value: .object([
                "sampleInputs": .object([
                    "publish": .object(["message": .string("Hello missing causation")])
                ])
            ]),
            requester: owner
        )

        let report: ContractProbeReport = try decode(response)
        XCTAssertEqual(report.status, .failed)
        XCTAssertTrue(
            report.assertions.contains(where: {
                $0.phase == "flow.publish.completed" &&
                $0.status == .failed &&
                $0.message.contains("without `causation_id`")
            })
        )
    }

    private func makeProbeTarget(
        owner: Identity,
        emitTargetOrigin: Bool = true,
        emitForeignOriginNoise: Bool = false,
        causationKey: String? = nil,
        includeCausationInFlowPayload: Bool = true,
        emitForeignCausationNoise: Bool = false
    ) async -> GeneralCell {
        let cell = await GeneralCell(owner: owner)

        await cell.addInterceptForGet(requester: owner, key: "state") { _, _ in
            .object(["status": .string("ok")])
        }
        await cell.registerExploreContract(
            requester: owner,
            key: "state",
            method: .get,
            input: .null,
            returns: ExploreContract.objectSchema(
                properties: ["status": ExploreContract.schema(type: "string")],
                requiredKeys: ["status"]
            ),
            permissions: ["r---"],
            description: .string("Returns probe target state.")
        )

        await cell.addInterceptForSet(requester: owner, key: "publish") { [weak cell] _, value, requester in
            guard case let .object(object) = value,
                  case .string? = object["message"] else {
                return .object([
                    "status": .string("error"),
                    "message": .string("Expected object payload with string `message`.")
                ])
            }
            if emitForeignOriginNoise, let cell {
                var foreignFlowElement = FlowElement(
                    id: UUID().uuidString,
                    title: "publish foreign",
                    content: .object(["echo": value]),
                    properties: FlowElement.Properties(type: .event, contentType: .object)
                )
                foreignFlowElement.topic = "publish.completed"
                foreignFlowElement.origin = "\(cell.uuid)-foreign"
                cell.pushFlowElement(foreignFlowElement, requester: requester)
            }
            let causationID: String?
            if let causationKey,
               case let .string(id)? = object[causationKey],
               !id.isEmpty {
                causationID = id
            } else {
                causationID = nil
            }
            if emitForeignCausationNoise, let cell, let causationKey, let causationID {
                var wrongCausationPayload: Object = ["echo": value]
                wrongCausationPayload[causationKey] = .string("\(causationID)-other")
                var wrongCausationFlowElement = FlowElement(
                    id: UUID().uuidString,
                    title: "publish wrong causation",
                    content: .object(wrongCausationPayload),
                    properties: FlowElement.Properties(type: .event, contentType: .object)
                )
                wrongCausationFlowElement.topic = "publish.completed"
                wrongCausationFlowElement.origin = cell.uuid
                cell.pushFlowElement(wrongCausationFlowElement, requester: requester)
            }
            var payload: Object = ["echo": value]
            if includeCausationInFlowPayload, let causationKey, let causationID {
                payload[causationKey] = .string(causationID)
            }
            var flowElement = FlowElement(
                id: UUID().uuidString,
                title: "publish",
                content: .object(payload),
                properties: FlowElement.Properties(type: .event, contentType: .object)
            )
            flowElement.topic = "publish.completed"
            if emitTargetOrigin {
                flowElement.origin = cell?.uuid
            }
            cell?.pushFlowElement(flowElement, requester: requester)
            return .object(["status": .string("ok")])
        }
        await cell.registerExploreContract(
            requester: owner,
            key: "publish",
            method: .set,
            input: ExploreContract.objectSchema(
                properties: ["message": ExploreContract.schema(type: "string")],
                requiredKeys: ["message"]
            ),
            returns: ExploreContract.objectSchema(
                properties: ["status": ExploreContract.schema(type: "string")],
                requiredKeys: ["status"]
            ),
            permissions: ["-w--"],
            required: true,
            flowEffects: [
                ExploreContract.flowEffect(
                    trigger: .set,
                    topic: "publish.completed",
                    contentType: "object",
                    minimumCount: 1,
                    causationKey: causationKey
                )
            ],
            description: .string("Publishes a message.")
        )

        return cell
    }

    private func decode<T: Decodable>(_ value: ValueType?, as type: T.Type = T.self) throws -> T {
        guard let value else {
            throw NSError(domain: "ContractProbeCellTests", code: 1)
        }
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T) throws -> ValueType {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(ValueType.self, from: data)
    }
}

private extension NSLock {
    func withValue<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
