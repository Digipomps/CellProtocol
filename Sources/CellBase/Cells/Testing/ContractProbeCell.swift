// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

/// Target cell reference used by ``ContractProbeCell``.
public struct ContractProbeTarget: Codable, Hashable {
    public var endpoint: String
    public var label: String?

    public init(endpoint: String, label: String? = nil) {
        self.endpoint = endpoint
        self.label = label
    }
}

/// High-level execution state for a contract probe run.
public enum ContractProbeRunState: String, Codable {
    case idle
    case running
    case completed
    case failed
}

/// Per-assertion outcome emitted by a probe run.
public enum ContractProbeAssertionStatus: String, Codable {
    case passed
    case failed
    case skipped
}

/// Runtime options accepted by `probe.run`.
public struct ContractProbeRunOptions: Codable {
    public var keys: [String]?
    public var sampleInputs: Object
    public var includeBehaviorChecks: Bool
    public var includePermissionChecks: Bool
    public var includeInvalidInputChecks: Bool
    public var includeFlowChecks: Bool
    public var timeoutSeconds: Int

    public init(
        keys: [String]? = nil,
        sampleInputs: Object = [:],
        includeBehaviorChecks: Bool = true,
        includePermissionChecks: Bool = true,
        includeInvalidInputChecks: Bool = true,
        includeFlowChecks: Bool = true,
        timeoutSeconds: Int = 1
    ) {
        self.keys = keys
        self.sampleInputs = sampleInputs
        self.includeBehaviorChecks = includeBehaviorChecks
        self.includePermissionChecks = includePermissionChecks
        self.includeInvalidInputChecks = includeInvalidInputChecks
        self.includeFlowChecks = includeFlowChecks
        self.timeoutSeconds = max(1, timeoutSeconds)
    }

    enum CodingKeys: String, CodingKey {
        case keys
        case sampleInputs
        case includeBehaviorChecks
        case includePermissionChecks
        case includeInvalidInputChecks
        case includeFlowChecks
        case timeoutSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.keys = try container.decodeIfPresent([String].self, forKey: .keys)
        self.sampleInputs = try container.decodeIfPresent(Object.self, forKey: .sampleInputs) ?? [:]
        self.includeBehaviorChecks = try container.decodeIfPresent(Bool.self, forKey: .includeBehaviorChecks) ?? true
        self.includePermissionChecks = try container.decodeIfPresent(Bool.self, forKey: .includePermissionChecks) ?? true
        self.includeInvalidInputChecks = try container.decodeIfPresent(Bool.self, forKey: .includeInvalidInputChecks) ?? true
        self.includeFlowChecks = try container.decodeIfPresent(Bool.self, forKey: .includeFlowChecks) ?? true
        self.timeoutSeconds = max(1, try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 1)
    }
}

/// One structured assertion in a `ContractProbeReport`.
public struct ContractProbeAssertionResult: Codable {
    public var key: String
    public var phase: String
    public var status: ContractProbeAssertionStatus
    public var message: String
    public var expected: ValueType?
    public var observed: ValueType?

    public init(
        key: String,
        phase: String,
        status: ContractProbeAssertionStatus,
        message: String,
        expected: ValueType? = nil,
        observed: ValueType? = nil
    ) {
        self.key = key
        self.phase = phase
        self.status = status
        self.message = message
        self.expected = expected
        self.observed = observed
    }
}

/// Stored and returned result from a `ContractProbeCell` run.
public struct ContractProbeReport: Codable {
    public var id: String
    public var targetCell: String
    public var startedAt: String
    public var finishedAt: String?
    public var status: ContractProbeRunState
    public var usedExpectedContracts: Bool
    public var options: ContractProbeRunOptions
    public var passedCount: Int
    public var failedCount: Int
    public var skippedCount: Int
    public var assertions: [ContractProbeAssertionResult]
    public var errorMessage: String?

    public init(
        id: String = UUID().uuidString,
        targetCell: String,
        startedAt: String,
        finishedAt: String? = nil,
        status: ContractProbeRunState,
        usedExpectedContracts: Bool,
        options: ContractProbeRunOptions,
        passedCount: Int = 0,
        failedCount: Int = 0,
        skippedCount: Int = 0,
        assertions: [ContractProbeAssertionResult] = [],
        errorMessage: String? = nil
    ) {
        self.id = id
        self.targetCell = targetCell
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.usedExpectedContracts = usedExpectedContracts
        self.options = options
        self.passedCount = passedCount
        self.failedCount = failedCount
        self.skippedCount = skippedCount
        self.assertions = assertions
        self.errorMessage = errorMessage
    }
}

/// Runtime cell that probes another cell through its public `CellProtocol`
/// surface and records a structured report.
public final class ContractProbeCell: GeneralCell {
    private static let reportHistoryLimit = 20

    private var configuredTarget: ContractProbeTarget?
    private var expectedContracts = Object()
    private var currentStatus: ContractProbeRunState = .idle
    private var reportHistory = [ContractProbeReport]()
    private var lastReport: ContractProbeReport?

    private enum CodingKeys: String, CodingKey {
        case configuredTarget
        case expectedContracts
        case currentStatus
        case reportHistory
        case lastReport
        case generalCell
    }

    public required init(owner: Identity) async {
        await super.init(owner: owner)
        await setupPermissions(owner: owner)
        await setupKeys(owner: owner)
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.configuredTarget = try container.decodeIfPresent(ContractProbeTarget.self, forKey: .configuredTarget)
        self.expectedContracts = try container.decodeIfPresent(Object.self, forKey: .expectedContracts) ?? [:]
        self.currentStatus = try container.decodeIfPresent(ContractProbeRunState.self, forKey: .currentStatus) ?? .idle
        self.reportHistory = try container.decodeIfPresent([ContractProbeReport].self, forKey: .reportHistory) ?? []
        self.lastReport = try container.decodeIfPresent(ContractProbeReport.self, forKey: .lastReport)
        try super.init(from: decoder)

        Task {
            await setupPermissions(owner: self.owner)
            await setupKeys(owner: self.owner)
        }
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(configuredTarget, forKey: .configuredTarget)
        try container.encode(expectedContracts, forKey: .expectedContracts)
        try container.encode(currentStatus, forKey: .currentStatus)
        try container.encode(reportHistory, forKey: .reportHistory)
        try container.encodeIfPresent(lastReport, forKey: .lastReport)
    }

    private func setupPermissions(owner: Identity) async {
        agreementTemplate.addGrant("rw--", for: "probe")
    }

    private func setupKeys(owner: Identity) async {
        await addInterceptForGet(requester: owner, key: "probe.status") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "probe", for: requester) else { return .string("denied") }
            return self.statusPayload()
        }

        await addInterceptForGet(requester: owner, key: "probe.target.current") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "probe", for: requester) else { return .string("denied") }
            return self.targetPayload()
        }

        await addInterceptForGet(requester: owner, key: "probe.contract.current") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "probe", for: requester) else { return .string("denied") }
            return self.contractPayload()
        }

        await addInterceptForGet(requester: owner, key: "probe.lastReport") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "probe", for: requester) else { return .string("denied") }
            return self.lastReportPayload()
        }

        await addInterceptForGet(requester: owner, key: "probe.reports") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "probe", for: requester) else { return .string("denied") }
            return self.reportsPayload()
        }

        await addInterceptForSet(requester: owner, key: "probe.target") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "probe", for: requester) else { return .string("denied") }
            return self.configureTarget(value: value)
        }

        await addInterceptForSet(requester: owner, key: "probe.contract") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "probe", for: requester) else { return .string("denied") }
            return self.configureContracts(value: value)
        }

        await addInterceptForSet(requester: owner, key: "probe.run") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "probe", for: requester) else { return .string("denied") }
            return await self.runProbe(value: value, requester: requester)
        }

        await registerContracts(requester: owner)
    }

    private func registerContracts(requester: Identity) async {
        await registerExploreContract(
            requester: requester,
            key: "probe.status",
            method: .get,
            input: .null,
            returns: Self.statusSchema(),
            permissions: ["r---"],
            required: false,
            description: .string("Returns current probe state, configured target, stored contract count, and report counters.")
        )

        await registerExploreContract(
            requester: requester,
            key: "probe.target.current",
            method: .get,
            input: .null,
            returns: Self.targetCurrentSchema(),
            permissions: ["r---"],
            required: false,
            description: .string("Returns the currently configured target endpoint for the probe.")
        )

        await registerExploreContract(
            requester: requester,
            key: "probe.contract.current",
            method: .get,
            input: .null,
            returns: Self.contractCurrentSchema(),
            permissions: ["r---"],
            required: false,
            description: .string("Returns the currently stored expected contracts used for strict probe comparisons.")
        )

        await registerExploreContract(
            requester: requester,
            key: "probe.lastReport",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [
                    .null,
                    Self.reportSchema()
                ],
                description: "Returns `null` before the first run, otherwise the latest probe report."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Returns the latest completed probe report.")
        )

        await registerExploreContract(
            requester: requester,
            key: "probe.reports",
            method: .get,
            input: .null,
            returns: Self.reportsSchema(),
            permissions: ["r---"],
            required: false,
            description: .string("Returns recent probe reports, newest first.")
        )

        await registerExploreContract(
            requester: requester,
            key: "probe.target",
            method: .set,
            input: Self.targetInputSchema(),
            returns: ExploreContract.oneOfSchema(
                options: [
                    Self.targetConfigureSuccessSchema(),
                    Self.errorSchema(operation: "probe.target")
                ],
                description: "Returns success on accepted target configuration or a structured error."
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Configures the target cell to be probed. Supports endpoint strings, target objects, and CellConfiguration payloads.")
        )

        await registerExploreContract(
            requester: requester,
            key: "probe.contract",
            method: .set,
            input: Self.contractInputSchema(),
            returns: ExploreContract.oneOfSchema(
                options: [
                    Self.contractConfigureSuccessSchema(),
                    Self.errorSchema(operation: "probe.contract")
                ],
                description: "Returns success on accepted contract configuration or a structured error."
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Stores an expected contract bundle. If omitted, `probe.run` uses the target cell's own `Explore` contract as baseline.")
        )

        await registerExploreContract(
            requester: requester,
            key: "probe.run",
            method: .set,
            input: Self.runOptionsSchema(),
            returns: ExploreContract.oneOfSchema(
                options: [
                    Self.reportSchema(),
                    Self.errorSchema(operation: "probe.run")
                ],
                description: "Returns a probe report or a structured configuration error."
            ),
            permissions: ["-w--"],
            required: false,
            flowEffects: [
                ExploreContract.flowEffect(trigger: .set, topic: "contract.run.started", contentType: "object", minimumCount: 1),
                ExploreContract.flowEffect(trigger: .set, topic: "contract.run.finished", contentType: "object", minimumCount: 1)
            ],
            description: .string("Runs the configured probe against the target cell, validates contract/behavior/permissions/flows, stores a report, and emits flow events.")
        )
    }

    private func configureTarget(value: ValueType) -> ValueType {
        do {
            let target = try Self.parseTarget(from: value)
            configuredTarget = target
            return .object([
                "status": .string("ok"),
                "message": .string("Configured contract probe target"),
                "target": try ContractProbeCellCodec.encode(target)
            ])
        } catch {
            return Self.errorValue(error, operation: "probe.target")
        }
    }

    private func configureContracts(value: ValueType) -> ValueType {
        do {
            expectedContracts = try Self.parseExpectedContracts(from: value)
            return .object([
                "status": .string("ok"),
                "message": .string("Configured expected contracts"),
                "count": .integer(expectedContracts.count),
                "items": .list(Self.expectedContractItems(expectedContracts))
            ])
        } catch {
            return Self.errorValue(error, operation: "probe.contract")
        }
    }

    private func runProbe(value: ValueType, requester: Identity) async -> ValueType {
        let options: ContractProbeRunOptions
        do {
            options = try Self.parseRunOptions(from: value)
        } catch {
            return Self.errorValue(error, operation: "probe.run")
        }

        guard let configuredTarget else {
            return Self.errorValue(ContractProbeError.targetNotConfigured, operation: "probe.run")
        }

        let reportID = UUID().uuidString
        currentStatus = .running
        emitProbeEvent(
            topic: "contract.run.started",
            title: "Contract probe started",
            payload: [
                "report_id": .string(reportID),
                "target_cell": .string(configuredTarget.endpoint)
            ]
        )

        var report = ContractProbeReport(
            id: reportID,
            targetCell: configuredTarget.endpoint,
            startedAt: Self.timestamp(),
            status: .running,
            usedExpectedContracts: !expectedContracts.isEmpty,
            options: options
        )

        do {
            let targetCell = try await resolveTarget(endpoint: configuredTarget.endpoint, requester: requester)
            let advertisedKeys = try await targetCell.keys(requester: requester).sorted()
            let selectedKeys = options.keys?.isEmpty == false ? advertisedKeys.filter { options.keys?.contains($0) == true } : advertisedKeys

            if !expectedContracts.isEmpty {
                let selectedKeySet = Set(selectedKeys)
                for expectedKey in expectedContracts.keys.sorted() where !selectedKeySet.contains(expectedKey) {
                    appendAssertion(
                        ContractProbeAssertionResult(
                            key: expectedKey,
                            phase: "contract.expectedCoverage",
                            status: .failed,
                            message: "Expected contract is configured for a key that the target does not advertise.",
                            expected: expectedContracts[expectedKey],
                            observed: nil
                        ),
                        to: &report,
                        emitEvent: true
                    )
                }
            }

            for key in selectedKeys {
                do {
                    let declaredContract = try await targetCell.typeForKey(key: key, requester: requester)
                    let normalizedDeclared = ExploreContract.normalizeSchema(key: key, schema: declaredContract)
                    let contractObject = ExploreContract.object(from: normalizedDeclared) ?? [:]

                    appendAssertion(
                        Self.validateDeclaredContract(key: key, contract: contractObject),
                        to: &report,
                        emitEvent: true
                    )

                    if let expectedContract = expectedContracts[key] {
                        let normalizedExpected = ExploreContract.normalizeSchema(key: key, schema: expectedContract)
                        let equal = ContractProbeSchema.deepEqual(normalizedExpected, normalizedDeclared)
                        appendAssertion(
                            ContractProbeAssertionResult(
                                key: key,
                                phase: "contract.expectedEquality",
                                status: equal ? .passed : .failed,
                                message: equal
                                    ? "Declared contract matches the configured expected contract."
                                    : "Declared contract differs from the configured expected contract.",
                                expected: normalizedExpected,
                                observed: normalizedDeclared
                            ),
                            to: &report,
                            emitEvent: true
                        )
                    } else if !expectedContracts.isEmpty {
                        appendAssertion(
                            ContractProbeAssertionResult(
                                key: key,
                                phase: "contract.expectedCoverage",
                                status: .failed,
                                message: "Target advertises a key that is missing from the configured expected contract bundle.",
                                expected: nil,
                                observed: normalizedDeclared
                            ),
                            to: &report,
                            emitEvent: true
                        )
                    }

                    let method = ExploreContract.string(from: contractObject[ExploreContract.Field.method]) ?? "unknown"
                    let inputSchema = contractObject[ExploreContract.Field.input] ?? .null
                    let returnSchema = contractObject[ExploreContract.Field.returns] ?? ExploreContract.unknownSchema()

                    if method == ExploreContractMethod.get.rawValue {
                        if options.includeBehaviorChecks {
                            let result = try await targetCell.get(keypath: key, requester: requester)
                            appendAssertion(
                                Self.behaviorAssertion(
                                    key: key,
                                    phase: "behavior.get",
                                    expectedSchema: returnSchema,
                                    observedValue: result
                                ),
                                to: &report,
                                emitEvent: true
                            )
                        }

                        if options.includePermissionChecks,
                           !(ExploreContract.list(from: contractObject[ExploreContract.Field.permissions])?.isEmpty ?? true) {
                            let denied = await Self.isDeniedGet(on: targetCell, key: key)
                            appendAssertion(
                                ContractProbeAssertionResult(
                                    key: key,
                                    phase: "permissions.get",
                                    status: denied ? .passed : .failed,
                                    message: denied
                                        ? "Unsigned probe identity was denied access as expected."
                                        : "Unsigned probe identity was not denied access.",
                                    expected: .string("denied"),
                                    observed: denied ? .string("denied") : .string("allowed")
                                ),
                                to: &report,
                                emitEvent: true
                            )
                        }
                        continue
                    }

                    guard method == ExploreContractMethod.set.rawValue else {
                        appendAssertion(
                            ContractProbeAssertionResult(
                                key: key,
                                phase: "contract.method",
                                status: .skipped,
                                message: "Unsupported contract method `\(method)`."
                            ),
                            to: &report,
                            emitEvent: false
                        )
                        continue
                    }

                    let sampleInput = options.sampleInputs[key] ?? ContractProbeSchema.defaultSample(for: inputSchema)

                    if options.includeBehaviorChecks {
                        if let sampleInput {
                            let flowEffects = ExploreContract.flowEffects(from: .object(contractObject))
                            let execution = try await executeSetProbe(
                                on: targetCell,
                                key: key,
                                input: sampleInput,
                                requester: requester,
                                expectedFlowEffects: options.includeFlowChecks ? flowEffects : [],
                                timeoutSeconds: options.timeoutSeconds,
                                reportID: report.id
                            )

                            appendAssertion(
                                Self.behaviorAssertion(
                                    key: key,
                                    phase: "behavior.set",
                                    expectedSchema: returnSchema,
                                    observedValue: execution.response
                                ),
                                to: &report,
                                emitEvent: true
                            )

                            for flowAssertion in execution.flowAssertions {
                                appendAssertion(flowAssertion, to: &report, emitEvent: true)
                            }
                        } else {
                            appendAssertion(
                                ContractProbeAssertionResult(
                                    key: key,
                                    phase: "behavior.set",
                                    status: .skipped,
                                    message: "No sample input was supplied or derivable from the declared input schema.",
                                    expected: inputSchema,
                                    observed: nil
                                ),
                                to: &report,
                                emitEvent: false
                            )
                        }
                    }

                    if options.includePermissionChecks,
                       let sampleInput,
                       !(ExploreContract.list(from: contractObject[ExploreContract.Field.permissions])?.isEmpty ?? true) {
                        let denied = await Self.isDeniedSet(on: targetCell, key: key, input: sampleInput)
                        appendAssertion(
                            ContractProbeAssertionResult(
                                key: key,
                                phase: "permissions.set",
                                status: denied ? .passed : .failed,
                                message: denied
                                    ? "Unsigned probe identity was denied access as expected."
                                    : "Unsigned probe identity was not denied access.",
                                expected: .string("denied"),
                                observed: denied ? .string("denied") : .string("allowed")
                            ),
                            to: &report,
                            emitEvent: true
                        )
                    }

                    if options.includeInvalidInputChecks {
                        guard let invalidInput = ContractProbeSchema.invalidInput(for: inputSchema) else {
                            appendAssertion(
                                ContractProbeAssertionResult(
                                    key: key,
                                    phase: "behavior.invalidInput",
                                    status: .skipped,
                                    message: "Could not derive an invalid input candidate from the declared input schema.",
                                    expected: inputSchema,
                                    observed: nil
                                ),
                                to: &report,
                                emitEvent: false
                            )
                            continue
                        }

                        let rejected = await Self.isInvalidInputRejected(
                            on: targetCell,
                            key: key,
                            input: invalidInput,
                            requester: requester
                        )

                        appendAssertion(
                            ContractProbeAssertionResult(
                                key: key,
                                phase: "behavior.invalidInput",
                                status: rejected ? .passed : .failed,
                                message: rejected
                                    ? "Derived invalid input was rejected."
                                    : "Derived invalid input was accepted.",
                                expected: .string("rejected"),
                                observed: rejected ? .string("rejected") : .string("accepted")
                            ),
                            to: &report,
                            emitEvent: true
                        )
                    }
                } catch {
                    appendAssertion(
                        ContractProbeAssertionResult(
                            key: key,
                            phase: "probe.execution",
                            status: .failed,
                            message: "Probe failed with error: \(error.localizedDescription)",
                            expected: nil,
                            observed: .string(error.localizedDescription)
                        ),
                        to: &report,
                        emitEvent: true
                    )
                }
            }
        } catch {
            report.status = .failed
            report.errorMessage = error.localizedDescription
            appendAssertion(
                ContractProbeAssertionResult(
                    key: configuredTarget.endpoint,
                    phase: "probe.targetResolution",
                    status: .failed,
                    message: "Failed to resolve target: \(error.localizedDescription)"
                ),
                to: &report,
                emitEvent: true
            )
        }

        if report.status != .failed {
            report.status = report.failedCount == 0 ? .completed : .failed
        }
        report.finishedAt = Self.timestamp()
        currentStatus = report.status
        lastReport = report
        reportHistory.append(report)
        if reportHistory.count > Self.reportHistoryLimit {
            reportHistory.removeFirst(reportHistory.count - Self.reportHistoryLimit)
        }

        emitProbeEvent(
            topic: "contract.run.finished",
            title: "Contract probe finished",
            payload: [
                "report_id": .string(report.id),
                "target_cell": .string(report.targetCell),
                "status": .string(report.status.rawValue),
                "passed_count": .integer(report.passedCount),
                "failed_count": .integer(report.failedCount),
                "skipped_count": .integer(report.skippedCount)
            ]
        )

        return (try? ContractProbeCellCodec.encode(report)) ?? Self.errorValue(ContractProbeError.reportEncodingFailed, operation: "probe.run")
    }

    private func resolveTarget(endpoint: String, requester: Identity) async throws -> any CellProtocol {
        guard let resolver = CellBase.defaultCellResolver else {
            throw ContractProbeError.resolverUnavailable
        }
        let emit = try await resolver.cellAtEndpoint(endpoint: endpoint, requester: requester)
        guard let cell = emit as? CellProtocol else {
            throw ContractProbeError.targetDoesNotConformToCellProtocol(endpoint)
        }
        return cell
    }

    private func executeSetProbe(
        on cell: any CellProtocol,
        key: String,
        input: ValueType,
        requester: Identity,
        expectedFlowEffects: [Object],
        timeoutSeconds: Int,
        reportID: String
    ) async throws -> (response: ValueType?, flowAssertions: [ContractProbeAssertionResult]) {
        guard !expectedFlowEffects.isEmpty else {
            let response = try await cell.set(keypath: key, value: input, requester: requester)
            return (response, [])
        }

        let feed = try await cell.flow(requester: requester)
        let expectedTopics = expectedFlowEffects.compactMap { ExploreContract.string(from: $0[ExploreContract.Field.topic]) }
        let expectedOrigin = cell.uuid
        let flowPreparation = try Self.prepareFlowCorrelationInput(input: input, key: key, expectedFlowEffects: expectedFlowEffects)
        let minimumCounts = Dictionary(uniqueKeysWithValues: expectedFlowEffects.compactMap { effect -> (String, Int)? in
            guard let topic = ExploreContract.string(from: effect[ExploreContract.Field.topic]) else {
                return nil
            }
            return (topic, max(1, ExploreContract.int(from: effect[ExploreContract.Field.minimumCount]) ?? 1))
        })

        let observationQueue = DispatchQueue(label: "ContractProbeCell.executeSetProbe")
        var observedCounts = [String: (matched: Int, missingOrigin: Int, foreignOrigin: Int, missingCausation: Int, foreignCausation: Int)]()
        let cancellable = feed.sink(
            receiveCompletion: { _ in },
            receiveValue: { [weak self] flowElement in
                guard expectedTopics.contains(flowElement.topic) else {
                    return
                }

                let observation = observationQueue.sync { () -> (count: Int, originStatus: String, causationStatus: String?, observedCausationID: String?) in
                    var counts = observedCounts[flowElement.topic, default: (matched: 0, missingOrigin: 0, foreignOrigin: 0, missingCausation: 0, foreignCausation: 0)]
                    let originStatus: String
                    var causationStatus: String?
                    var observedCausationID: String?
                    if let origin = flowElement.origin {
                        if origin == expectedOrigin {
                            originStatus = "matched"
                            if let causationKey = flowPreparation.causationKeysByTopic[flowElement.topic],
                               let expectedCausationID = flowPreparation.causationID {
                                observedCausationID = Self.flowCausationID(from: flowElement, key: causationKey)
                                if observedCausationID == expectedCausationID {
                                    counts.matched += 1
                                    causationStatus = "matched"
                                } else if observedCausationID == nil {
                                    counts.missingCausation += 1
                                    causationStatus = "missing"
                                } else {
                                    counts.foreignCausation += 1
                                    causationStatus = "foreign"
                                }
                            } else {
                                counts.matched += 1
                            }
                        } else {
                            counts.foreignOrigin += 1
                            originStatus = "foreign"
                        }
                    } else {
                        counts.missingOrigin += 1
                        originStatus = "missing"
                    }
                    observedCounts[flowElement.topic] = counts
                    return (counts.matched, originStatus, causationStatus, observedCausationID)
                }

                var payload: Object = [
                    "report_id": .string(reportID),
                    "key": .string(key),
                    "topic": .string(flowElement.topic),
                    "count": .integer(observation.count),
                    "observed_origin": .string(flowElement.origin ?? ""),
                    "expected_origin": .string(expectedOrigin),
                    "origin_status": .string(observation.originStatus)
                ]
                if let causationKey = flowPreparation.causationKeysByTopic[flowElement.topic],
                   let expectedCausationID = flowPreparation.causationID {
                    payload["causation_key"] = .string(causationKey)
                    payload["expected_causation_id"] = .string(expectedCausationID)
                    payload["observed_causation_id"] = .string(observation.observedCausationID ?? "")
                    payload["causation_status"] = .string(observation.causationStatus ?? "not_configured")
                }

                self?.emitProbeEvent(
                    topic: "contract.flow.observed",
                    title: "Contract probe observed flow",
                    payload: payload
                )
            }
        )
        defer { cancellable.cancel() }

        let response = try await cell.set(keypath: key, value: flowPreparation.input, requester: requester)

        let timeoutNs = UInt64(max(1, timeoutSeconds)) * 1_000_000_000
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNs {
            let satisfied = observationQueue.sync {
                minimumCounts.allSatisfy { topic, minimum in
                    observedCounts[topic, default: (matched: 0, missingOrigin: 0, foreignOrigin: 0, missingCausation: 0, foreignCausation: 0)].matched >= minimum
                }
            }
            if satisfied {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        var assertions = [ContractProbeAssertionResult]()
        for topic in expectedTopics {
            let minimum = minimumCounts[topic] ?? 1
            let observed = observationQueue.sync {
                observedCounts[topic, default: (matched: 0, missingOrigin: 0, foreignOrigin: 0, missingCausation: 0, foreignCausation: 0)]
            }
            let causationKey = flowPreparation.causationKeysByTopic[topic]
            let expectationDescription: String
            if let causationKey, let causationID = flowPreparation.causationID {
                expectationDescription = "from target origin `\(expectedOrigin)` with `\(causationKey)` = `\(causationID)`"
            } else {
                expectationDescription = "from target origin `\(expectedOrigin)`"
            }

            let status: ContractProbeAssertionStatus
            let message: String
            if observed.matched >= minimum {
                status = .passed
                let ignored = Self.ignoredFlowObservationSummary(
                    missingOrigin: observed.missingOrigin,
                    foreignOrigin: observed.foreignOrigin,
                    missingCausation: observed.missingCausation,
                    foreignCausation: observed.foreignCausation,
                    causationKey: causationKey
                )
                if let ignored, !ignored.isEmpty {
                    message = "Observed flow topic `\(topic)` \(observed.matched) time(s) \(expectationDescription) and ignored \(ignored)."
                } else {
                    message = "Observed flow topic `\(topic)` \(observed.matched) time(s) \(expectationDescription)."
                }
            } else if observed.missingOrigin > 0 || observed.foreignOrigin > 0 || observed.missingCausation > 0 || observed.foreignCausation > 0 {
                status = .failed
                let ignored = Self.ignoredFlowObservationSummary(
                    missingOrigin: observed.missingOrigin,
                    foreignOrigin: observed.foreignOrigin,
                    missingCausation: observed.missingCausation,
                    foreignCausation: observed.foreignCausation,
                    causationKey: causationKey
                ) ?? "no qualifying events"
                message = "Expected flow topic `\(topic)` at least \(minimum) time(s) \(expectationDescription), observed \(observed.matched). Ignored \(ignored)."
            } else {
                status = .failed
                message = "Expected flow topic `\(topic)` at least \(minimum) time(s) \(expectationDescription), observed 0."
            }

            assertions.append(
                ContractProbeAssertionResult(
                    key: key,
                    phase: "flow.\(topic)",
                    status: status,
                    message: message,
                    expected: .integer(minimum),
                    observed: .integer(observed.matched)
                )
            )
        }

        return (response, assertions)
    }

    private func appendAssertion(
        _ assertion: ContractProbeAssertionResult,
        to report: inout ContractProbeReport,
        emitEvent: Bool
    ) {
        report.assertions.append(assertion)
        switch assertion.status {
        case .passed:
            report.passedCount += 1
            if emitEvent {
                emitAssertionEvent(topic: "contract.assertion.passed", assertion: assertion, reportID: report.id)
            }
        case .failed:
            report.failedCount += 1
            if emitEvent {
                emitAssertionEvent(topic: "contract.assertion.failed", assertion: assertion, reportID: report.id)
            }
        case .skipped:
            report.skippedCount += 1
        }
    }

    private func emitAssertionEvent(topic: String, assertion: ContractProbeAssertionResult, reportID: String) {
        var payload: Object = [
            "report_id": .string(reportID),
            "key": .string(assertion.key),
            "phase": .string(assertion.phase),
            "status": .string(assertion.status.rawValue),
            "message": .string(assertion.message)
        ]
        if let expected = assertion.expected {
            payload["expected"] = expected
        }
        if let observed = assertion.observed {
            payload["observed"] = observed
        }
        emitProbeEvent(topic: topic, title: "Contract assertion \(assertion.status.rawValue)", payload: payload)
    }

    private func emitProbeEvent(topic: String, title: String, payload: Object) {
        var flowElement = FlowElement(
            id: UUID().uuidString,
            title: title,
            content: .object(payload),
            properties: FlowElement.Properties(type: .event, contentType: .object)
        )
        flowElement.topic = topic
        flowElement.origin = self.uuid
        pushFlowElement(flowElement, requester: owner)
    }

    private func statusPayload() -> ValueType {
        .object([
            "status": .string("ok"),
            "probe_state": .string(currentStatus.rawValue),
            "target_configured": .bool(configuredTarget != nil),
            "target_endpoint": .string(configuredTarget?.endpoint ?? ""),
            "expected_contract_count": .integer(expectedContracts.count),
            "report_count": .integer(reportHistory.count),
            "has_last_report": .bool(lastReport != nil)
        ])
    }

    private func targetPayload() -> ValueType {
        .object([
            "status": .string("ok"),
            "configured": .bool(configuredTarget != nil),
            "target": (try? ContractProbeCellCodec.encode(configuredTarget)) ?? .null
        ])
    }

    private func contractPayload() -> ValueType {
        .object([
            "status": .string("ok"),
            "count": .integer(expectedContracts.count),
            "items": .list(Self.expectedContractItems(expectedContracts))
        ])
    }

    private func lastReportPayload() -> ValueType {
        if let lastReport, let encoded = try? ContractProbeCellCodec.encode(lastReport) {
            return encoded
        }
        return .null
    }

    private func reportsPayload() -> ValueType {
        .object([
            "status": .string("ok"),
            "count": .integer(reportHistory.count),
            "items": .list(reportHistory.reversed().compactMap { try? ContractProbeCellCodec.encode($0) })
        ])
    }

    private static func expectedContractItems(_ contracts: Object) -> ValueTypeList {
        contracts.keys.sorted().compactMap { contracts[$0] }
    }

    private static func validateDeclaredContract(key: String, contract: Object) -> ContractProbeAssertionResult {
        let requiredFields = [
            ExploreContract.Field.contractVersion,
            ExploreContract.Field.key,
            ExploreContract.Field.method,
            ExploreContract.Field.input,
            ExploreContract.Field.returns,
            ExploreContract.Field.permissions,
            ExploreContract.Field.required,
            ExploreContract.Field.flowEffects,
            ExploreContract.Field.summary
        ]
        let missing = requiredFields.filter { contract[$0] == nil }

        return ContractProbeAssertionResult(
            key: key,
            phase: "contract.shape",
            status: missing.isEmpty ? .passed : .failed,
            message: missing.isEmpty
                ? "Declared contract is structurally complete."
                : "Declared contract is missing required fields: \(missing.joined(separator: ", ")).",
            expected: .list(requiredFields.map(ValueType.string)),
            observed: .list(contract.keys.sorted().map(ValueType.string))
        )
    }

    private static func behaviorAssertion(
        key: String,
        phase: String,
        expectedSchema: ValueType,
        observedValue: ValueType?
    ) -> ContractProbeAssertionResult {
        let matches = ContractProbeSchema.matches(value: observedValue, schema: expectedSchema)
        let runtimeError = Self.isRuntimeErrorValue(observedValue)
        let status: ContractProbeAssertionStatus = matches && !runtimeError ? .passed : .failed
        let message: String
        if runtimeError {
            message = "Operation returned a runtime error payload."
        } else if matches {
            message = "Observed value matches the declared return schema."
        } else {
            message = "Observed value does not match the declared return schema."
        }

        return ContractProbeAssertionResult(
            key: key,
            phase: phase,
            status: status,
            message: message,
            expected: expectedSchema,
            observed: observedValue
        )
    }

    private static func parseTarget(from value: ValueType) throws -> ContractProbeTarget {
        if case .null = value {
            throw ContractProbeError.invalidTarget("Expected endpoint string, target object, or CellConfiguration payload.")
        }

        if let endpoint = ContractProbeCellCodec.string(from: value) {
            return ContractProbeTarget(endpoint: endpoint)
        }

        if let target: ContractProbeTarget = try? ContractProbeCellCodec.decode(value) {
            return target
        }

        if let configuration: CellConfiguration = try? ContractProbeCellCodec.decode(value) {
            return try parseTarget(from: configuration)
        }

        if case let .object(object) = value,
           let nested = object["cellConfiguration"],
           let configuration: CellConfiguration = try? ContractProbeCellCodec.decode(nested) {
            return try parseTarget(from: configuration)
        }

        throw ContractProbeError.invalidTarget("Expected endpoint string, target object, or CellConfiguration payload.")
    }

    private static func parseTarget(from configuration: CellConfiguration) throws -> ContractProbeTarget {
        let references = flattenedReferences(from: configuration.cellReferences ?? [])

        if let endpoint = nonEmpty(configuration.discovery?.sourceCellEndpoint) {
            let endpointMatches = references.filter { $0.endpoint == endpoint }
            if endpointMatches.count == 1 {
                return ContractProbeTarget(endpoint: endpointMatches[0].endpoint, label: endpointMatches[0].label)
            }
            if endpointMatches.count > 1, let label = nonEmpty(configuration.discovery?.sourceCellName) {
                let labelMatches = endpointMatches.filter { $0.label == label }
                if labelMatches.count == 1 {
                    return ContractProbeTarget(endpoint: labelMatches[0].endpoint, label: labelMatches[0].label)
                }
            }
            if endpointMatches.count > 1 {
                throw ContractProbeError.invalidTarget("CellConfiguration contains multiple cellReferences matching discovery.sourceCellEndpoint `\(endpoint)`. Provide a unique discovery.sourceCellName or reduce the reference set.")
            }
            return ContractProbeTarget(endpoint: endpoint, label: nonEmpty(configuration.discovery?.sourceCellName))
        }

        if let label = nonEmpty(configuration.discovery?.sourceCellName) {
            let labelMatches = references.filter { $0.label == label }
            if labelMatches.count == 1 {
                return ContractProbeTarget(endpoint: labelMatches[0].endpoint, label: labelMatches[0].label)
            }
            if labelMatches.count > 1 {
                throw ContractProbeError.invalidTarget("CellConfiguration contains multiple cellReferences matching discovery.sourceCellName `\(label)`. Provide discovery.sourceCellEndpoint to select one.")
            }
        }

        guard !references.isEmpty else {
            throw ContractProbeError.invalidTarget("CellConfiguration does not contain any cellReferences or discovery.sourceCellEndpoint.")
        }

        guard references.count == 1 else {
            throw ContractProbeError.invalidTarget("CellConfiguration contains multiple cellReferences. Provide discovery.sourceCellEndpoint or discovery.sourceCellName to select one target.")
        }

        return ContractProbeTarget(endpoint: references[0].endpoint, label: references[0].label)
    }

    private static func flattenedReferences(from references: [CellReference]) -> [CellReference] {
        var flattened = [CellReference]()
        for reference in references {
            flattened.append(reference)
            flattened.append(contentsOf: flattenedReferences(from: reference.subscriptions))
        }
        return flattened
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func prepareFlowCorrelationInput(
        input: ValueType,
        key: String,
        expectedFlowEffects: [Object]
    ) throws -> (input: ValueType, causationID: String?, causationKeysByTopic: [String: String]) {
        let causationKeysByTopic = Dictionary(uniqueKeysWithValues: expectedFlowEffects.compactMap { effect -> (String, String)? in
            guard let topic = ExploreContract.string(from: effect[ExploreContract.Field.topic]),
                  let causationKey = nonEmpty(ExploreContract.string(from: effect[ExploreContract.Field.causationKey])) else {
                return nil
            }
            return (topic, causationKey)
        })

        let uniqueCausationKeys = Array(Set(causationKeysByTopic.values)).sorted()
        guard uniqueCausationKeys.count <= 1 else {
            throw ContractProbeError.invalidFlowExpectation("Flow effects for key `\(key)` declare multiple causation keys: \(uniqueCausationKeys.joined(separator: ", ")). Use one shared causation key per set operation.")
        }

        guard let causationKey = uniqueCausationKeys.first else {
            return (input, nil, causationKeysByTopic)
        }

        guard case let .object(object) = input else {
            throw ContractProbeError.invalidFlowExpectation("Flow effects for key `\(key)` declare causationKey `\(causationKey)`, but the sample input must be an object so the probe can attach a causation identifier.")
        }

        if let existing = object[causationKey] {
            guard let existingID = nonEmpty(ContractProbeCellCodec.string(from: existing)) else {
                throw ContractProbeError.invalidFlowExpectation("Flow effects for key `\(key)` declare causationKey `\(causationKey)`, but the supplied sample input must carry it as a non-empty string when present.")
            }
            return (input, existingID, causationKeysByTopic)
        }

        var mutated = object
        let generatedID = UUID().uuidString
        mutated[causationKey] = .string(generatedID)
        return (.object(mutated), generatedID, causationKeysByTopic)
    }

    private static func flowCausationID(from flowElement: FlowElement, key: String) -> String? {
        guard case let .object(contentObject) = flowElement.content else {
            return nil
        }
        return nonEmpty(ContractProbeCellCodec.string(from: contentObject[key]))
    }

    private static func ignoredFlowObservationSummary(
        missingOrigin: Int,
        foreignOrigin: Int,
        missingCausation: Int,
        foreignCausation: Int,
        causationKey: String?
    ) -> String? {
        var parts = [String]()
        if missingOrigin > 0 || foreignOrigin > 0 {
            parts.append("\(missingOrigin) event(s) without origin")
        }
        if foreignOrigin > 0 {
            parts.append("\(foreignOrigin) foreign-origin event(s)")
        }
        if let causationKey {
            if missingCausation > 0 {
                parts.append("\(missingCausation) event(s) without `\(causationKey)`")
            }
            if foreignCausation > 0 {
                parts.append("\(foreignCausation) event(s) with a different `\(causationKey)`")
            }
        }
        guard !parts.isEmpty else {
            return nil
        }
        return parts.joined(separator: " plus ")
    }

    private static func parseExpectedContracts(from value: ValueType) throws -> Object {
        if case .null = value {
            return [:]
        }

        let items: ValueTypeList
        if case let .list(list) = value {
            items = list
        } else if case let .object(object) = value,
                  let nested = ExploreContract.list(from: object["items"]) {
            items = nested
        } else if case let .object(object) = value,
                  ExploreContract.string(from: object[ExploreContract.Field.key]) != nil {
            items = [value]
        } else {
            throw ContractProbeError.invalidContractBundle("Expected a contract object, a list of contract objects, or an object with `items`.")
        }

        var contracts = Object()
        for item in items {
            guard let contractObject = ExploreContract.object(from: item),
                  let key = ExploreContract.string(from: contractObject[ExploreContract.Field.key]),
                  !key.isEmpty else {
                throw ContractProbeError.invalidContractBundle("Each configured contract must be an object with a non-empty `key`.")
            }
            contracts[key] = ExploreContract.normalizeSchema(key: key, schema: item)
        }
        return contracts
    }

    private static func parseRunOptions(from value: ValueType) throws -> ContractProbeRunOptions {
        if case .null = value {
            return ContractProbeRunOptions()
        }

        if case let .object(object) = value, object.isEmpty {
            return ContractProbeRunOptions()
        }

        return try ContractProbeCellCodec.decode(value, as: ContractProbeRunOptions.self)
    }

    private static func isRuntimeErrorValue(_ value: ValueType?) -> Bool {
        guard case let .object(object)? = value else {
            return false
        }
        return ExploreContract.string(from: object["status"]) == "error"
    }

    private static func isDeniedValue(_ value: ValueType?) -> Bool {
        switch value {
        case .string("denied")?:
            return true
        case let .object(object)?:
            let status = ExploreContract.string(from: object["status"])
            let message = ExploreContract.string(from: object["message"])?.lowercased() ?? ""
            return status == "error" && message.contains("denied")
        default:
            return false
        }
    }

    private static func isDeniedGet(on cell: any CellProtocol, key: String) async -> Bool {
        let outsider = Identity()
        do {
            let response = try await cell.get(keypath: key, requester: outsider)
            return isDeniedValue(response)
        } catch {
            return true
        }
    }

    private static func isDeniedSet(on cell: any CellProtocol, key: String, input: ValueType) async -> Bool {
        let outsider = Identity()
        do {
            let response = try await cell.set(keypath: key, value: input, requester: outsider)
            return isDeniedValue(response)
        } catch {
            return true
        }
    }

    private static func isInvalidInputRejected(
        on cell: any CellProtocol,
        key: String,
        input: ValueType,
        requester: Identity
    ) async -> Bool {
        do {
            let response = try await cell.set(keypath: key, value: input, requester: requester)
            if isRuntimeErrorValue(response) {
                return true
            }
            return false
        } catch {
            return true
        }
    }

    fileprivate static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

private enum ContractProbeError: LocalizedError {
    case resolverUnavailable
    case targetNotConfigured
    case targetDoesNotConformToCellProtocol(String)
    case invalidTarget(String)
    case invalidContractBundle(String)
    case invalidFlowExpectation(String)
    case reportEncodingFailed

    var errorDescription: String? {
        switch self {
        case .resolverUnavailable:
            return "CellBase.defaultCellResolver is not configured."
        case .targetNotConfigured:
            return "No target cell has been configured for this probe."
        case .targetDoesNotConformToCellProtocol(let endpoint):
            return "Resolved target at `\(endpoint)` does not conform to CellProtocol."
        case .invalidTarget(let message):
            return message
        case .invalidContractBundle(let message):
            return message
        case .invalidFlowExpectation(let message):
            return message
        case .reportEncodingFailed:
            return "Failed to encode the contract probe report."
        }
    }
}

private enum ContractProbeCellCodec {
    static func decode<T: Decodable>(_ value: ValueType, as type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func encode<T: Encodable>(_ value: T?) throws -> ValueType {
        guard let value else {
            return .null
        }
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(ValueType.self, from: data)
    }

    static func string(from value: ValueType?) -> String? {
        guard let value else { return nil }

        switch value {
        case let .string(string):
            return string
        case let .integer(number):
            return String(number)
        case let .number(number):
            return String(number)
        default:
            return nil
        }
    }
}

private enum ContractProbeSchema {
    static func matches(value: ValueType?, schema: ValueType?) -> Bool {
        guard let schema else {
            return true
        }

        switch schema {
        case .null:
            if value == nil { return true }
            guard case .null? = value else { return false }
            return true
        case let .string(typeName):
            return matches(value: value, schema: ExploreContract.schema(type: typeName))
        case let .object(object):
            if let options = ExploreContract.list(from: object[ExploreContract.Field.oneOf]) {
                return options.contains { option in
                    matches(value: value, schema: option)
                }
            }

            let schemaType = ExploreContract.schemaType(from: .object(object)) ?? "object"
            switch schemaType {
            case "unknown":
                return true
            case "null":
                if value == nil { return true }
                guard case .null? = value else { return false }
                return true
            case "bool":
                return value?.contractTypeName == "bool"
            case "integer":
                return value?.contractTypeName == "integer"
            case "float":
                if case .float? = value { return true }
                return false
            case "string":
                return value?.contractTypeName == "string"
            case "data":
                return value?.contractTypeName == "data"
            case "list":
                guard case let .list(list)? = value else {
                    return false
                }
                let itemSchema = object[ExploreContract.Field.item]
                return list.allSatisfy { item in
                    matches(value: item, schema: itemSchema)
                }
            case "object":
                guard case let .object(actualObject)? = value else {
                    return false
                }

                let propertySchemas = ExploreContract.object(from: object[ExploreContract.Field.properties]) ?? [:]
                let requiredKeys = ExploreContract.list(from: object[ExploreContract.Field.requiredKeys])?.compactMap {
                    ExploreContract.string(from: $0)
                } ?? []

                for key in requiredKeys where actualObject[key] == nil {
                    return false
                }

                for (propertyKey, propertySchema) in propertySchemas {
                    guard let actualValue = actualObject[propertyKey] else {
                        continue
                    }
                    if !matches(value: actualValue, schema: propertySchema) {
                        return false
                    }
                }
                return true
            default:
                return value?.contractTypeName == schemaType
            }
        default:
            return value?.contractTypeName == schema.contractTypeName
        }
    }

    static func defaultSample(for schema: ValueType?) -> ValueType? {
        guard let schema else {
            return nil
        }

        switch schema {
        case .null:
            return .null
        case let .string(typeName):
            return defaultSample(for: ExploreContract.schema(type: typeName))
        case let .object(object):
            if let options = ExploreContract.list(from: object[ExploreContract.Field.oneOf]) {
                for option in options {
                    if let sample = defaultSample(for: option) {
                        return sample
                    }
                }
                return nil
            }

            let schemaType = ExploreContract.schemaType(from: .object(object)) ?? "object"
            switch schemaType {
            case "unknown":
                return nil
            case "null":
                return .null
            case "bool":
                return .bool(true)
            case "integer":
                return .integer(1)
            case "float":
                return .float(1.0)
            case "string":
                return .string("sample")
            case "data":
                return .data(Data("sample".utf8))
            case "list":
                if let itemSchema = object[ExploreContract.Field.item],
                   let item = defaultSample(for: itemSchema) {
                    return .list([item])
                }
                return .list([])
            case "object":
                let propertySchemas = ExploreContract.object(from: object[ExploreContract.Field.properties]) ?? [:]
                let requiredKeys = ExploreContract.list(from: object[ExploreContract.Field.requiredKeys])?.compactMap {
                    ExploreContract.string(from: $0)
                } ?? Array(propertySchemas.keys)

                var sampleObject = Object()
                for key in requiredKeys {
                    let propertySchema = propertySchemas[key]
                    if let sample = defaultSample(for: propertySchema) {
                        sampleObject[key] = sample
                    } else {
                        sampleObject[key] = .string("sample")
                    }
                }
                return .object(sampleObject)
            default:
                return .string("sample")
            }
        default:
            switch schema.contractTypeName {
            case "bool":
                return .bool(true)
            case "integer":
                return .integer(1)
            case "float":
                return .float(1.0)
            case "string":
                return .string("sample")
            case "list":
                return .list([])
            case "object":
                return .object([:])
            default:
                return nil
            }
        }
    }

    static func invalidInput(for schema: ValueType?) -> ValueType? {
        guard let schema else {
            return nil
        }

        let candidates: [ValueType] = [
            .string("invalid"),
            .object(["invalid": .bool(true)]),
            .list([.string("invalid")]),
            .integer(-1),
            .bool(false),
            .null
        ]

        for candidate in candidates where !matches(value: candidate, schema: schema) {
            return candidate
        }
        return nil
    }

    static func deepEqual(_ lhs: ValueType?, _ rhs: ValueType?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (nil, _), (_, nil):
            return false
        case (.null?, .null?):
            return true
        case let (.string(left)?, .string(right)?):
            return left == right
        case let (.bool(left)?, .bool(right)?):
            return left == right
        case let (.number(left)?, .number(right)?):
            return left == right
        case let (.integer(left)?, .integer(right)?):
            return left == right
        case let (.float(left)?, .float(right)?):
            return abs(left - right) < 0.000_001
        case let (.object(left)?, .object(right)?):
            guard Set(left.keys) == Set(right.keys) else {
                return false
            }
            for key in left.keys where !deepEqual(left[key], right[key]) {
                return false
            }
            return true
        case let (.list(left)?, .list(right)?):
            guard left.count == right.count else {
                return false
            }
            for (leftItem, rightItem) in zip(left, right) where !deepEqual(leftItem, rightItem) {
                return false
            }
            return true
        default:
            return false
        }
    }
}

private extension ContractProbeCell {
    static func errorValue(_ error: Error, operation: String) -> ValueType {
        .object([
            "status": .string("error"),
            "operation": .string(operation),
            "message": .string((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        ])
    }

    static func statusSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "probe_state": ExploreContract.schema(type: "string"),
                "target_configured": ExploreContract.schema(type: "bool"),
                "target_endpoint": ExploreContract.schema(type: "string"),
                "expected_contract_count": ExploreContract.schema(type: "integer"),
                "report_count": ExploreContract.schema(type: "integer"),
                "has_last_report": ExploreContract.schema(type: "bool")
            ],
            requiredKeys: [
                "status",
                "probe_state",
                "target_configured",
                "target_endpoint",
                "expected_contract_count",
                "report_count",
                "has_last_report"
            ],
            description: "Contract probe status payload."
        )
    }

    static func targetCurrentSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "configured": ExploreContract.schema(type: "bool"),
                "target": ExploreContract.oneOfSchema(
                    options: [
                        .null,
                        ExploreContract.objectSchema(
                            properties: [
                                "endpoint": ExploreContract.schema(type: "string"),
                                "label": ExploreContract.schema(type: "string")
                            ],
                            requiredKeys: ["endpoint"]
                        )
                    ]
                )
            ],
            requiredKeys: ["status", "configured", "target"],
            description: "Currently configured probe target."
        )
    }

    static func contractCurrentSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "count": ExploreContract.schema(type: "integer"),
                "items": ExploreContract.listSchema(item: ExploreContract.schema(type: "object"))
            ],
            requiredKeys: ["status", "count", "items"],
            description: "Currently configured expected contracts."
        )
    }

    static func targetInputSchema() -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                ExploreContract.schema(type: "string", description: "Target cell endpoint."),
                ExploreContract.objectSchema(
                    properties: [
                        "endpoint": ExploreContract.schema(type: "string"),
                        "label": ExploreContract.schema(type: "string")
                    ],
                    requiredKeys: ["endpoint"],
                    description: "Explicit target object."
                ),
                ExploreContract.schema(type: "cellConfiguration", description: "CellConfiguration whose first cell reference defines the target endpoint.")
            ],
            description: "Target endpoint, explicit target object, or CellConfiguration."
        )
    }

    static func targetConfigureSuccessSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "message": ExploreContract.schema(type: "string"),
                "target": ExploreContract.objectSchema(
                    properties: [
                        "endpoint": ExploreContract.schema(type: "string"),
                        "label": ExploreContract.schema(type: "string")
                    ],
                    requiredKeys: ["endpoint"]
                )
            ],
            requiredKeys: ["status", "message", "target"],
            description: "Successful target configuration response."
        )
    }

    static func contractInputSchema() -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                .null,
                ExploreContract.objectSchema(
                    properties: [
                        ExploreContract.Field.key: ExploreContract.schema(type: "string")
                    ],
                    requiredKeys: [ExploreContract.Field.key],
                    description: "Single expected contract object."
                ),
                ExploreContract.listSchema(item: ExploreContract.schema(type: "object"), description: "List of expected contract objects."),
                ExploreContract.objectSchema(
                    properties: [
                        "items": ExploreContract.listSchema(item: ExploreContract.schema(type: "object"))
                    ],
                    requiredKeys: ["items"],
                    description: "Object containing expected contract items."
                )
            ],
            description: "Expected contract bundle or `null` to clear."
        )
    }

    static func contractConfigureSuccessSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "message": ExploreContract.schema(type: "string"),
                "count": ExploreContract.schema(type: "integer"),
                "items": ExploreContract.listSchema(item: ExploreContract.schema(type: "object"))
            ],
            requiredKeys: ["status", "message", "count", "items"],
            description: "Successful expected-contract configuration response."
        )
    }

    static func runOptionsSchema() -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                .null,
                ExploreContract.objectSchema(
                    properties: [
                        "keys": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                        "sampleInputs": ExploreContract.schema(type: "object", description: "Map of key -> sample input ValueType."),
                        "includeBehaviorChecks": ExploreContract.schema(type: "bool"),
                        "includePermissionChecks": ExploreContract.schema(type: "bool"),
                        "includeInvalidInputChecks": ExploreContract.schema(type: "bool"),
                        "includeFlowChecks": ExploreContract.schema(type: "bool"),
                        "timeoutSeconds": ExploreContract.schema(type: "integer")
                    ],
                    description: "Contract probe run options."
                )
            ],
            description: "Run options or `null` for defaults."
        )
    }

    static func reportSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "id": ExploreContract.schema(type: "string"),
                "targetCell": ExploreContract.schema(type: "string"),
                "startedAt": ExploreContract.schema(type: "string"),
                "finishedAt": ExploreContract.schema(type: "string"),
                "status": ExploreContract.schema(type: "string"),
                "usedExpectedContracts": ExploreContract.schema(type: "bool"),
                "options": runOptionsSchema(),
                "passedCount": ExploreContract.schema(type: "integer"),
                "failedCount": ExploreContract.schema(type: "integer"),
                "skippedCount": ExploreContract.schema(type: "integer"),
                "assertions": ExploreContract.listSchema(item: assertionSchema()),
                "errorMessage": ExploreContract.schema(type: "string")
            ],
            requiredKeys: [
                "id",
                "targetCell",
                "startedAt",
                "status",
                "usedExpectedContracts",
                "options",
                "passedCount",
                "failedCount",
                "skippedCount",
                "assertions"
            ],
            description: "Contract probe report."
        )
    }

    static func reportsSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "count": ExploreContract.schema(type: "integer"),
                "items": ExploreContract.listSchema(item: reportSchema())
            ],
            requiredKeys: ["status", "count", "items"],
            description: "Recent contract probe reports."
        )
    }

    static func assertionSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "key": ExploreContract.schema(type: "string"),
                "phase": ExploreContract.schema(type: "string"),
                "status": ExploreContract.schema(type: "string"),
                "message": ExploreContract.schema(type: "string"),
                "expected": ExploreContract.schema(type: "unknown"),
                "observed": ExploreContract.schema(type: "unknown")
            ],
            requiredKeys: ["key", "phase", "status", "message"],
            description: "Single contract probe assertion result."
        )
    }

    static func errorSchema(operation: String) -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "operation": ExploreContract.schema(type: "string", description: operation),
                "message": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["status", "operation", "message"],
            description: "Structured contract probe error response."
        )
    }
}

private extension NSLock {
    func withValue<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
