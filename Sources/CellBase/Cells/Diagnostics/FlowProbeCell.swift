// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

public struct FlowProbeTarget: Codable, Hashable {
    public var endpoint: String
    public var label: String?

    public init(endpoint: String, label: String? = nil) {
        self.endpoint = endpoint
        self.label = label
    }
}

public struct FlowProbeFilter: Codable, Hashable {
    public var topics: [String]?
    public var origin: String?
    public var titleContains: String?
    public var limit: Int

    public init(
        topics: [String]? = nil,
        origin: String? = nil,
        titleContains: String? = nil,
        limit: Int = 50
    ) {
        self.topics = topics?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.origin = origin?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.titleContains = titleContains?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.limit = max(1, limit)
    }
}

public enum FlowProbeRunState: String, Codable {
    case idle
    case running
    case stopped
    case failed
}

public struct FlowProbeObservation: Codable {
    public var receivedAt: String
    public var flowElement: FlowElement

    public init(receivedAt: String, flowElement: FlowElement) {
        self.receivedAt = receivedAt
        self.flowElement = flowElement
    }
}

public struct FlowProbeTrace: Codable {
    public var id: String
    public var targetCell: String
    public var startedAt: String
    public var stoppedAt: String?
    public var status: FlowProbeRunState
    public var filter: FlowProbeFilter
    public var matchedCount: Int
    public var droppedCount: Int
    public var observations: [FlowProbeObservation]
    public var errorMessage: String?

    public init(
        id: String = UUID().uuidString,
        targetCell: String,
        startedAt: String,
        stoppedAt: String? = nil,
        status: FlowProbeRunState,
        filter: FlowProbeFilter,
        matchedCount: Int = 0,
        droppedCount: Int = 0,
        observations: [FlowProbeObservation] = [],
        errorMessage: String? = nil
    ) {
        self.id = id
        self.targetCell = targetCell
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.status = status
        self.filter = filter
        self.matchedCount = matchedCount
        self.droppedCount = droppedCount
        self.observations = observations
        self.errorMessage = errorMessage
    }
}

public final class FlowProbeCell: GeneralCell {
    private static let traceHistoryLimit = 20

    private var configuredTarget: FlowProbeTarget?
    private var configuredFilter = FlowProbeFilter()
    private var currentStatus: FlowProbeRunState = .idle
    private var currentTrace: FlowProbeTrace?
    private var traceHistory = [FlowProbeTrace]()

    private let stateQueue = DispatchQueue(label: "FlowProbeCell.State")
    private var feedCancellable: AnyCancellable?

    private enum CodingKeys: String, CodingKey {
        case configuredTarget
        case configuredFilter
        case currentStatus
        case currentTrace
        case traceHistory
        case generalCell
    }

    public required init(owner: Identity) async {
        await super.init(owner: owner)
        await setupPermissions(owner: owner)
        await setupKeys(owner: owner)
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.configuredTarget = try container.decodeIfPresent(FlowProbeTarget.self, forKey: .configuredTarget)
        self.configuredFilter = try container.decodeIfPresent(FlowProbeFilter.self, forKey: .configuredFilter) ?? FlowProbeFilter()
        self.currentStatus = try container.decodeIfPresent(FlowProbeRunState.self, forKey: .currentStatus) ?? .idle
        self.currentTrace = try container.decodeIfPresent(FlowProbeTrace.self, forKey: .currentTrace)
        self.traceHistory = try container.decodeIfPresent([FlowProbeTrace].self, forKey: .traceHistory) ?? []
        try super.init(from: decoder)

        Task {
            await setupPermissions(owner: self.owner)
            await setupKeys(owner: self.owner)
        }
    }

    deinit {
        feedCancellable?.cancel()
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        let snapshot = stateQueue.sync {
            (
                target: configuredTarget,
                filter: configuredFilter,
                status: currentStatus,
                currentTrace: currentTrace,
                history: traceHistory
            )
        }
        try container.encodeIfPresent(snapshot.target, forKey: .configuredTarget)
        try container.encode(snapshot.filter, forKey: .configuredFilter)
        try container.encode(snapshot.status, forKey: .currentStatus)
        try container.encodeIfPresent(snapshot.currentTrace, forKey: .currentTrace)
        try container.encode(snapshot.history, forKey: .traceHistory)
    }

    private func setupPermissions(owner: Identity) async {
        agreementTemplate.addGrant("rw--", for: "flowProbe")
    }

    private func setupKeys(owner: Identity) async {
        await addInterceptForGet(requester: owner, key: "flowProbe.status") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "flowProbe", for: requester) else { return .string("denied") }
            return self.statusPayload()
        }

        await addInterceptForGet(requester: owner, key: "flowProbe.target.current") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "flowProbe", for: requester) else { return .string("denied") }
            return self.targetPayload()
        }

        await addInterceptForGet(requester: owner, key: "flowProbe.filters.current") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "flowProbe", for: requester) else { return .string("denied") }
            return self.filterPayload()
        }

        await addInterceptForGet(requester: owner, key: "flowProbe.trace.current") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "flowProbe", for: requester) else { return .string("denied") }
            return self.currentTracePayload()
        }

        await addInterceptForGet(requester: owner, key: "flowProbe.traces") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "flowProbe", for: requester) else { return .string("denied") }
            return self.traceHistoryPayload()
        }

        await addInterceptForSet(requester: owner, key: "flowProbe.target") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "flowProbe", for: requester) else { return .string("denied") }
            return self.configureTarget(value: value)
        }

        await addInterceptForSet(requester: owner, key: "flowProbe.filters") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "flowProbe", for: requester) else { return .string("denied") }
            return self.configureFilter(value: value)
        }

        await addInterceptForSet(requester: owner, key: "flowProbe.start") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "flowProbe", for: requester) else { return .string("denied") }
            return await self.startProbe(value: value, requester: requester)
        }

        await addInterceptForSet(requester: owner, key: "flowProbe.stop") { [weak self] _, _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "flowProbe", for: requester) else { return .string("denied") }
            return self.finishTrace(status: .stopped, errorMessage: nil, emitEvent: true)
        }

        await addInterceptForSet(requester: owner, key: "flowProbe.clear") { [weak self] _, _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "flowProbe", for: requester) else { return .string("denied") }
            return self.clearProbe()
        }
    }

    private func configureTarget(value: ValueType) -> ValueType {
        do {
            let target = try parseTarget(from: value)
            stateQueue.sync {
                configuredTarget = target
            }
            return targetPayload()
        } catch {
            return .object([
                "status": .string("error"),
                "message": .string(error.localizedDescription)
            ])
        }
    }

    private func configureFilter(value: ValueType) -> ValueType {
        do {
            let filter = try parseFilter(from: value)
            stateQueue.sync {
                configuredFilter = filter
            }
            return filterPayload()
        } catch {
            return .object([
                "status": .string("error"),
                "message": .string(error.localizedDescription)
            ])
        }
    }

    private func startProbe(value: ValueType, requester: Identity) async -> ValueType {
        do {
            try applyInlineConfiguration(from: value)
            guard let target = stateQueue.sync(execute: { configuredTarget }) else {
                return .object([
                    "status": .string("error"),
                    "message": .string("Configure flowProbe.target before starting.")
                ])
            }
            guard let resolver = CellBase.defaultCellResolver else {
                return .object([
                    "status": .string("error"),
                    "message": .string("No default cell resolver is configured.")
                ])
            }

            let emitCell = try await resolver.cellAtEndpoint(endpoint: target.endpoint, requester: requester)
            let feed = try await emitCell.flow(requester: requester)

            let newTrace = FlowProbeTrace(
                targetCell: target.endpoint,
                startedAt: Self.isoTimestamp(),
                status: .running,
                filter: stateQueue.sync(execute: { configuredFilter })
            )

            stateQueue.sync {
                feedCancellable?.cancel()
                feedCancellable = nil
                currentTrace = newTrace
                currentStatus = .running
            }

            let cancellable = feed.sink(
                receiveCompletion: { [weak self] completion in
                    switch completion {
                    case .finished:
                        self?.finishTrace(status: .stopped, errorMessage: nil, emitEvent: true)
                    case let .failure(error):
                        self?.finishTrace(status: .failed, errorMessage: error.localizedDescription, emitEvent: true)
                    }
                },
                receiveValue: { [weak self] flowElement in
                    self?.record(flowElement: flowElement)
                }
            )

            stateQueue.sync {
                feedCancellable = cancellable
            }

            emitEvent(
                topic: "flowProbe.started",
                title: "Flow probe started",
                payload: [
                    "target": (try? DiagnosticProbeCodec.encode(target)) ?? .null,
                    "trace_id": .string(newTrace.id)
                ]
            )
            return currentTracePayload()
        } catch {
            return .object([
                "status": .string("error"),
                "message": .string(error.localizedDescription)
            ])
        }
    }

    @discardableResult
    private func finishTrace(status: FlowProbeRunState, errorMessage: String?, emitEvent shouldEmitEvent: Bool) -> ValueType {
        let finalizedTrace: FlowProbeTrace? = stateQueue.sync {
            guard currentStatus == .running, var trace = currentTrace else {
                return currentTrace
            }

            feedCancellable?.cancel()
            feedCancellable = nil

            trace.status = status
            trace.stoppedAt = Self.isoTimestamp()
            trace.errorMessage = errorMessage
            currentTrace = trace
            currentStatus = status
            appendTraceToHistory(trace)
            return trace
        }

        if shouldEmitEvent, let finalizedTrace {
            emitEvent(
                topic: status == .failed ? "flowProbe.failed" : "flowProbe.stopped",
                title: status == .failed ? "Flow probe failed" : "Flow probe stopped",
                payload: [
                    "trace_id": .string(finalizedTrace.id),
                    "status": .string(finalizedTrace.status.rawValue),
                    "error": errorMessage.map(ValueType.string) ?? .string("")
                ]
            )
        }
        return currentTracePayload()
    }

    private func clearProbe() -> ValueType {
        stateQueue.sync {
            feedCancellable?.cancel()
            feedCancellable = nil
            currentTrace = nil
            traceHistory.removeAll()
            currentStatus = .idle
        }
        return statusPayload()
    }

    private func record(flowElement: FlowElement) {
        let traceID: String? = stateQueue.sync {
            guard currentStatus == .running,
                  var trace = currentTrace,
                  matches(flowElement: flowElement, filter: trace.filter) else {
                return nil
            }

            trace.matchedCount += 1
            trace.observations.append(
                FlowProbeObservation(receivedAt: Self.isoTimestamp(), flowElement: flowElement)
            )
            if trace.observations.count > trace.filter.limit {
                let overflow = trace.observations.count - trace.filter.limit
                trace.observations.removeFirst(overflow)
                trace.droppedCount += overflow
            }
            currentTrace = trace
            return trace.id
        }

        guard let traceID else { return }
        emitEvent(
            topic: "flowProbe.observed",
            title: "Flow probe observed flow",
            payload: [
                "trace_id": .string(traceID),
                "topic": .string(flowElement.topic),
                "title": .string(flowElement.title),
                "origin": flowElement.origin.map(ValueType.string) ?? .string("")
            ]
        )
    }

    private func matches(flowElement: FlowElement, filter: FlowProbeFilter) -> Bool {
        if let topics = filter.topics, !topics.isEmpty, !topics.contains(flowElement.topic) {
            return false
        }
        if let origin = filter.origin, flowElement.origin != origin {
            return false
        }
        if let titleContains = filter.titleContains,
           !titleContains.isEmpty,
           !flowElement.title.localizedCaseInsensitiveContains(titleContains) {
            return false
        }
        return true
    }

    private func statusPayload() -> ValueType {
        let snapshot = stateQueue.sync {
            (
                status: currentStatus,
                target: configuredTarget,
                filter: configuredFilter,
                currentTraceID: currentTrace?.id,
                traceCount: traceHistory.count
            )
        }
        var object: Object = [
            "status": .string(snapshot.status.rawValue),
            "traceCount": .integer(snapshot.traceCount)
        ]
        object["filter"] = (try? DiagnosticProbeCodec.encode(snapshot.filter)) ?? .null
        object["currentTraceID"] = snapshot.currentTraceID.map(ValueType.string) ?? .string("")
        object["target"] = (try? DiagnosticProbeCodec.encode(snapshot.target)) ?? .null
        return .object(object)
    }

    private func targetPayload() -> ValueType {
        let target = stateQueue.sync { configuredTarget }
        return .object([
            "configured": .bool(target != nil),
            "target": (try? DiagnosticProbeCodec.encode(target)) ?? .null
        ])
    }

    private func filterPayload() -> ValueType {
        let filter = stateQueue.sync { configuredFilter }
        return .object([
            "configured": .bool(true),
            "filter": (try? DiagnosticProbeCodec.encode(filter)) ?? .null
        ])
    }

    private func currentTracePayload() -> ValueType {
        let trace = stateQueue.sync { currentTrace }
        return .object([
            "configured": .bool(trace != nil),
            "trace": (try? DiagnosticProbeCodec.encode(trace)) ?? .null
        ])
    }

    private func traceHistoryPayload() -> ValueType {
        let history = stateQueue.sync { traceHistory }
        return .object([
            "items": (try? DiagnosticProbeCodec.encode(history)) ?? .list([])
        ])
    }

    private func parseTarget(from value: ValueType) throws -> FlowProbeTarget {
        if let endpoint = DiagnosticProbeCodec.string(from: value) {
            return FlowProbeTarget(endpoint: endpoint)
        }
        if let target = try? DiagnosticProbeCodec.decode(value, as: FlowProbeTarget.self) {
            return target
        }
        if let configuration = try? DiagnosticProbeCodec.decode(value, as: CellConfiguration.self),
           let target = Self.target(from: configuration) {
            return target
        }
        guard let object = DiagnosticProbeCodec.object(from: value),
              let endpoint = DiagnosticProbeCodec.string(from: object["endpoint"] ?? object["cell"] ?? object["target"]) else {
            throw NSError(domain: "FlowProbeCell", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Expected a target endpoint string or object payload."
            ])
        }
        let label = DiagnosticProbeCodec.string(from: object["label"])
        return FlowProbeTarget(endpoint: endpoint, label: label)
    }

    private func parseFilter(from value: ValueType) throws -> FlowProbeFilter {
        if case .null = value {
            return FlowProbeFilter()
        }
        if let filter = try? DiagnosticProbeCodec.decode(value, as: FlowProbeFilter.self) {
            return filter
        }
        guard let object = DiagnosticProbeCodec.object(from: value) else {
            throw NSError(domain: "FlowProbeCell", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Expected an object payload for flowProbe.filters."
            ])
        }
        let topics = DiagnosticProbeCodec.list(from: object["topics"] ?? object["topic"])?.compactMap {
            DiagnosticProbeCodec.string(from: $0)
        }
        let singleTopic = DiagnosticProbeCodec.string(from: object["topic"])
        let filterTopics = (topics?.isEmpty == false) ? topics : (singleTopic.map { [$0] })
        let origin = DiagnosticProbeCodec.string(from: object["origin"])
        let titleContains = DiagnosticProbeCodec.string(from: object["titleContains"])
        let limit = DiagnosticProbeCodec.int(from: object["limit"]) ?? 50
        return FlowProbeFilter(topics: filterTopics, origin: origin, titleContains: titleContains, limit: limit)
    }

    private func applyInlineConfiguration(from value: ValueType) throws {
        switch value {
        case .null:
            return
        case .string:
            let target = try parseTarget(from: value)
            stateQueue.sync {
                configuredTarget = target
            }
        case let .object(object):
            if let targetValue = object["target"] ?? object["endpoint"] {
                let target = try parseTarget(from: targetValue)
                stateQueue.sync {
                    configuredTarget = target
                }
            }
            if let filterValue = object["filter"] {
                let filter = try parseFilter(from: filterValue)
                stateQueue.sync {
                    configuredFilter = filter
                }
            } else if object["topics"] != nil || object["topic"] != nil || object["origin"] != nil || object["titleContains"] != nil || object["limit"] != nil {
                let filter = try parseFilter(from: value)
                stateQueue.sync {
                    configuredFilter = filter
                }
            }
        default:
            throw NSError(domain: "FlowProbeCell", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported inline configuration for flowProbe.start."
            ])
        }
    }

    private static func target(from configuration: CellConfiguration) -> FlowProbeTarget? {
        if let source = configuration.discovery?.sourceCellEndpoint, !source.isEmpty {
            return FlowProbeTarget(endpoint: source, label: configuration.discovery?.sourceCellName)
        }
        if let firstReference = configuration.cellReferences?.first {
            return FlowProbeTarget(endpoint: firstReference.endpoint, label: firstReference.label)
        }
        return nil
    }

    private static func isoTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func appendTraceToHistory(_ trace: FlowProbeTrace) {
        traceHistory.removeAll(where: { $0.id == trace.id })
        traceHistory.insert(trace, at: 0)
        if traceHistory.count > Self.traceHistoryLimit {
            traceHistory.removeLast(traceHistory.count - Self.traceHistoryLimit)
        }
    }

    private func emitEvent(topic: String, title: String, payload: Object) {
        var flowElement = FlowElement(
            title: title,
            content: .object(payload),
            properties: FlowElement.Properties(type: .event, contentType: .object)
        )
        flowElement.topic = topic
        flowElement.origin = uuid
        pushFlowElement(flowElement, requester: owner)
    }
}
