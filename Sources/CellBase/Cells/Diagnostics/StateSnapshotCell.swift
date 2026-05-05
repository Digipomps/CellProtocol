// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct StateSnapshotTarget: Codable, Hashable {
    public var endpoint: String
    public var label: String?

    public init(endpoint: String, label: String? = nil) {
        self.endpoint = endpoint
        self.label = label
    }
}

public enum StateSnapshotItemStatus: String, Codable {
    case ok
    case error
}

public struct StateSnapshotItem: Codable {
    public var key: String
    public var status: StateSnapshotItemStatus
    public var value: ValueType?
    public var errorMessage: String?

    public init(
        key: String,
        status: StateSnapshotItemStatus,
        value: ValueType? = nil,
        errorMessage: String? = nil
    ) {
        self.key = key
        self.status = status
        self.value = value
        self.errorMessage = errorMessage
    }
}

public struct StateSnapshotRecord: Codable {
    public var id: String
    public var targetCell: String
    public var createdAt: String
    public var requestedKeys: [String]
    public var items: [StateSnapshotItem]

    public init(
        id: String = UUID().uuidString,
        targetCell: String,
        createdAt: String,
        requestedKeys: [String],
        items: [StateSnapshotItem]
    ) {
        self.id = id
        self.targetCell = targetCell
        self.createdAt = createdAt
        self.requestedKeys = requestedKeys
        self.items = items
    }
}

public enum StateSnapshotDiffKind: String, Codable {
    case added
    case removed
    case changed
}

public struct StateSnapshotDiffEntry: Codable {
    public var key: String
    public var kind: StateSnapshotDiffKind
    public var left: StateSnapshotItem?
    public var right: StateSnapshotItem?

    public init(key: String, kind: StateSnapshotDiffKind, left: StateSnapshotItem?, right: StateSnapshotItem?) {
        self.key = key
        self.kind = kind
        self.left = left
        self.right = right
    }
}

public struct StateSnapshotDiffRecord: Codable {
    public var id: String
    public var leftSnapshotID: String
    public var rightSnapshotID: String
    public var createdAt: String
    public var changeCount: Int
    public var entries: [StateSnapshotDiffEntry]

    public init(
        id: String = UUID().uuidString,
        leftSnapshotID: String,
        rightSnapshotID: String,
        createdAt: String,
        changeCount: Int,
        entries: [StateSnapshotDiffEntry]
    ) {
        self.id = id
        self.leftSnapshotID = leftSnapshotID
        self.rightSnapshotID = rightSnapshotID
        self.createdAt = createdAt
        self.changeCount = changeCount
        self.entries = entries
    }
}

public final class StateSnapshotCell: GeneralCell {
    private static let snapshotHistoryLimit = 20
    private static let diffHistoryLimit = 20

    private var configuredTarget: StateSnapshotTarget?
    private var configuredKeys = [String]()
    private var snapshotHistory = [StateSnapshotRecord]()
    private var diffHistory = [StateSnapshotDiffRecord]()
    private var lastSnapshot: StateSnapshotRecord?
    private var lastDiff: StateSnapshotDiffRecord?

    private let stateQueue = DispatchQueue(label: "StateSnapshotCell.State")

    private enum CodingKeys: String, CodingKey {
        case configuredTarget
        case configuredKeys
        case snapshotHistory
        case diffHistory
        case lastSnapshot
        case lastDiff
        case generalCell
    }

    public required init(owner: Identity) async {
        await super.init(owner: owner)
        await setupPermissions(owner: owner)
        await setupKeys(owner: owner)
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.configuredTarget = try container.decodeIfPresent(StateSnapshotTarget.self, forKey: .configuredTarget)
        self.configuredKeys = try container.decodeIfPresent([String].self, forKey: .configuredKeys) ?? []
        self.snapshotHistory = try container.decodeIfPresent([StateSnapshotRecord].self, forKey: .snapshotHistory) ?? []
        self.diffHistory = try container.decodeIfPresent([StateSnapshotDiffRecord].self, forKey: .diffHistory) ?? []
        self.lastSnapshot = try container.decodeIfPresent(StateSnapshotRecord.self, forKey: .lastSnapshot)
        self.lastDiff = try container.decodeIfPresent(StateSnapshotDiffRecord.self, forKey: .lastDiff)
        try super.init(from: decoder)

        Task {
            await setupPermissions(owner: self.owner)
            await setupKeys(owner: self.owner)
        }
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        let snapshot = stateQueue.sync {
            (
                target: configuredTarget,
                keys: configuredKeys,
                history: snapshotHistory,
                diffs: diffHistory,
                lastSnapshot: lastSnapshot,
                lastDiff: lastDiff
            )
        }
        try container.encodeIfPresent(snapshot.target, forKey: .configuredTarget)
        try container.encode(snapshot.keys, forKey: .configuredKeys)
        try container.encode(snapshot.history, forKey: .snapshotHistory)
        try container.encode(snapshot.diffs, forKey: .diffHistory)
        try container.encodeIfPresent(snapshot.lastSnapshot, forKey: .lastSnapshot)
        try container.encodeIfPresent(snapshot.lastDiff, forKey: .lastDiff)
    }

    private func setupPermissions(owner: Identity) async {
        agreementTemplate.addGrant("rw--", for: "stateSnapshot")
    }

    private func setupKeys(owner: Identity) async {
        await addInterceptForGet(requester: owner, key: "stateSnapshot.status") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "stateSnapshot", for: requester) else { return .string("denied") }
            return self.statusPayload()
        }

        await addInterceptForGet(requester: owner, key: "stateSnapshot.target.current") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "stateSnapshot", for: requester) else { return .string("denied") }
            return self.targetPayload()
        }

        await addInterceptForGet(requester: owner, key: "stateSnapshot.keys.current") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "stateSnapshot", for: requester) else { return .string("denied") }
            return self.keysPayload()
        }

        await addInterceptForGet(requester: owner, key: "stateSnapshot.current") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "stateSnapshot", for: requester) else { return .string("denied") }
            return self.currentSnapshotPayload()
        }

        await addInterceptForGet(requester: owner, key: "stateSnapshot.history") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "stateSnapshot", for: requester) else { return .string("denied") }
            return self.snapshotHistoryPayload()
        }

        await addInterceptForGet(requester: owner, key: "stateSnapshot.diff.current") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "stateSnapshot", for: requester) else { return .string("denied") }
            return self.currentDiffPayload()
        }

        await addInterceptForGet(requester: owner, key: "stateSnapshot.diffs") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "stateSnapshot", for: requester) else { return .string("denied") }
            return self.diffHistoryPayload()
        }

        await addInterceptForSet(requester: owner, key: "stateSnapshot.target") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "stateSnapshot", for: requester) else { return .string("denied") }
            return self.configureTarget(value: value)
        }

        await addInterceptForSet(requester: owner, key: "stateSnapshot.keys") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "stateSnapshot", for: requester) else { return .string("denied") }
            return self.configureKeys(value: value)
        }

        await addInterceptForSet(requester: owner, key: "stateSnapshot.capture") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "stateSnapshot", for: requester) else { return .string("denied") }
            return await self.captureSnapshot(value: value, requester: requester)
        }

        await addInterceptForSet(requester: owner, key: "stateSnapshot.diff") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "stateSnapshot", for: requester) else { return .string("denied") }
            return self.diffSnapshots(value: value)
        }

        await addInterceptForSet(requester: owner, key: "stateSnapshot.clear") { [weak self] _, _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "stateSnapshot", for: requester) else { return .string("denied") }
            return self.clearSnapshots()
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

    private func configureKeys(value: ValueType) -> ValueType {
        do {
            let keys = try parseKeys(from: value)
            stateQueue.sync {
                configuredKeys = keys
            }
            return keysPayload()
        } catch {
            return .object([
                "status": .string("error"),
                "message": .string(error.localizedDescription)
            ])
        }
    }

    private func captureSnapshot(value: ValueType, requester: Identity) async -> ValueType {
        do {
            try applyInlineConfiguration(from: value)
            guard let target = stateQueue.sync(execute: { configuredTarget }) else {
                return .object([
                    "status": .string("error"),
                    "message": .string("Configure stateSnapshot.target before capture.")
                ])
            }
            guard let resolver = CellBase.defaultCellResolver else {
                return .object([
                    "status": .string("error"),
                    "message": .string("No default cell resolver is configured.")
                ])
            }

            let emitCell = try await resolver.cellAtEndpoint(endpoint: target.endpoint, requester: requester)
            guard let cell = emitCell as? (any Emit & Meddle & Explore) else {
                return .object([
                    "status": .string("error"),
                    "message": .string("Target cell does not expose get/keys/explore surfaces.")
                ])
            }

            var keys = stateQueue.sync(execute: { configuredKeys })
            if keys.isEmpty {
                keys = try await cell.keys(requester: requester).sorted()
            }

            let items = await keys.asyncMap { key -> StateSnapshotItem in
                do {
                    let value = try await cell.get(keypath: key, requester: requester)
                    return StateSnapshotItem(key: key, status: .ok, value: value, errorMessage: nil)
                } catch {
                    return StateSnapshotItem(key: key, status: .error, value: nil, errorMessage: error.localizedDescription)
                }
            }

            let snapshot = StateSnapshotRecord(
                targetCell: target.endpoint,
                createdAt: Self.isoTimestamp(),
                requestedKeys: keys,
                items: items
            )

            stateQueue.sync {
                lastSnapshot = snapshot
                snapshotHistory.removeAll(where: { $0.id == snapshot.id })
                snapshotHistory.insert(snapshot, at: 0)
                if snapshotHistory.count > Self.snapshotHistoryLimit {
                    snapshotHistory.removeLast(snapshotHistory.count - Self.snapshotHistoryLimit)
                }
            }

            emitEvent(
                topic: "stateSnapshot.captured",
                title: "State snapshot captured",
                payload: [
                    "snapshot_id": .string(snapshot.id),
                    "target": (try? DiagnosticProbeCodec.encode(target)) ?? .null,
                    "item_count": .integer(snapshot.items.count)
                ]
            )
            return currentSnapshotPayload()
        } catch {
            return .object([
                "status": .string("error"),
                "message": .string(error.localizedDescription)
            ])
        }
    }

    private func diffSnapshots(value: ValueType) -> ValueType {
        do {
            let (left, right) = try resolveSnapshotsForDiff(from: value)
            let diff = makeDiff(left: left, right: right)
            stateQueue.sync {
                lastDiff = diff
                diffHistory.removeAll(where: { $0.id == diff.id })
                diffHistory.insert(diff, at: 0)
                if diffHistory.count > Self.diffHistoryLimit {
                    diffHistory.removeLast(diffHistory.count - Self.diffHistoryLimit)
                }
            }

            emitEvent(
                topic: "stateSnapshot.diffed",
                title: "State snapshot diffed",
                payload: [
                    "diff_id": .string(diff.id),
                    "left_snapshot_id": .string(diff.leftSnapshotID),
                    "right_snapshot_id": .string(diff.rightSnapshotID),
                    "change_count": .integer(diff.changeCount)
                ]
            )
            return currentDiffPayload()
        } catch {
            return .object([
                "status": .string("error"),
                "message": .string(error.localizedDescription)
            ])
        }
    }

    private func clearSnapshots() -> ValueType {
        stateQueue.sync {
            snapshotHistory.removeAll()
            diffHistory.removeAll()
            lastSnapshot = nil
            lastDiff = nil
        }
        return statusPayload()
    }

    private func statusPayload() -> ValueType {
        let snapshot = stateQueue.sync {
            (
                target: configuredTarget,
                keys: configuredKeys,
                snapshotCount: snapshotHistory.count,
                diffCount: diffHistory.count,
                currentSnapshotID: lastSnapshot?.id,
                currentDiffID: lastDiff?.id
            )
        }
        return .object([
            "target": (try? DiagnosticProbeCodec.encode(snapshot.target)) ?? .null,
            "keys": .list(snapshot.keys.map(ValueType.string)),
            "snapshotCount": .integer(snapshot.snapshotCount),
            "diffCount": .integer(snapshot.diffCount),
            "currentSnapshotID": snapshot.currentSnapshotID.map(ValueType.string) ?? .string(""),
            "currentDiffID": snapshot.currentDiffID.map(ValueType.string) ?? .string("")
        ])
    }

    private func targetPayload() -> ValueType {
        let target = stateQueue.sync { configuredTarget }
        return .object([
            "configured": .bool(target != nil),
            "target": (try? DiagnosticProbeCodec.encode(target)) ?? .null
        ])
    }

    private func keysPayload() -> ValueType {
        let keys = stateQueue.sync { configuredKeys }
        return .object([
            "configured": .bool(!keys.isEmpty),
            "keys": .list(keys.map(ValueType.string))
        ])
    }

    private func currentSnapshotPayload() -> ValueType {
        let snapshot = stateQueue.sync { lastSnapshot }
        return .object([
            "configured": .bool(snapshot != nil),
            "snapshot": (try? DiagnosticProbeCodec.encode(snapshot)) ?? .null
        ])
    }

    private func snapshotHistoryPayload() -> ValueType {
        let history = stateQueue.sync { snapshotHistory }
        return .object([
            "items": (try? DiagnosticProbeCodec.encode(history)) ?? .list([])
        ])
    }

    private func currentDiffPayload() -> ValueType {
        let diff = stateQueue.sync { lastDiff }
        return .object([
            "configured": .bool(diff != nil),
            "diff": (try? DiagnosticProbeCodec.encode(diff)) ?? .null
        ])
    }

    private func diffHistoryPayload() -> ValueType {
        let history = stateQueue.sync { diffHistory }
        return .object([
            "items": (try? DiagnosticProbeCodec.encode(history)) ?? .list([])
        ])
    }

    private func resolveSnapshotsForDiff(from value: ValueType) throws -> (StateSnapshotRecord, StateSnapshotRecord) {
        let history = stateQueue.sync { snapshotHistory }
        guard history.count >= 2 else {
            throw NSError(domain: "StateSnapshotCell", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Capture at least two snapshots before diffing."
            ])
        }

        guard case let .object(object) = value else {
            return (history[1], history[0])
        }

        if let leftID = DiagnosticProbeCodec.string(from: object["leftSnapshotID"]),
           let rightID = DiagnosticProbeCodec.string(from: object["rightSnapshotID"]) {
            guard let left = history.first(where: { $0.id == leftID }),
                  let right = history.first(where: { $0.id == rightID }) else {
                throw NSError(domain: "StateSnapshotCell", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Could not find both snapshots for diff."
                ])
            }
            return (left, right)
        }
        return (history[1], history[0])
    }

    private func makeDiff(left: StateSnapshotRecord, right: StateSnapshotRecord) -> StateSnapshotDiffRecord {
        let leftMap = Dictionary(uniqueKeysWithValues: left.items.map { ($0.key, $0) })
        let rightMap = Dictionary(uniqueKeysWithValues: right.items.map { ($0.key, $0) })
        let allKeys = Set(leftMap.keys).union(rightMap.keys).sorted()

        let entries = allKeys.compactMap { key -> StateSnapshotDiffEntry? in
            let leftItem = leftMap[key]
            let rightItem = rightMap[key]
            switch (leftItem, rightItem) {
            case let (nil, rightItem?):
                return StateSnapshotDiffEntry(key: key, kind: .added, left: nil, right: rightItem)
            case let (leftItem?, nil):
                return StateSnapshotDiffEntry(key: key, kind: .removed, left: leftItem, right: nil)
            case let (leftItem?, rightItem?):
                if leftItem.status != rightItem.status || leftItem.value != rightItem.value || leftItem.errorMessage != rightItem.errorMessage {
                    return StateSnapshotDiffEntry(key: key, kind: .changed, left: leftItem, right: rightItem)
                }
                return nil
            case (nil, nil):
                return nil
            }
        }

        return StateSnapshotDiffRecord(
            leftSnapshotID: left.id,
            rightSnapshotID: right.id,
            createdAt: Self.isoTimestamp(),
            changeCount: entries.count,
            entries: entries
        )
    }

    private func parseTarget(from value: ValueType) throws -> StateSnapshotTarget {
        if let endpoint = DiagnosticProbeCodec.string(from: value) {
            return StateSnapshotTarget(endpoint: endpoint)
        }
        if let target = try? DiagnosticProbeCodec.decode(value, as: StateSnapshotTarget.self) {
            return target
        }
        if let configuration = try? DiagnosticProbeCodec.decode(value, as: CellConfiguration.self),
           let target = Self.target(from: configuration) {
            return target
        }
        guard let object = DiagnosticProbeCodec.object(from: value),
              let endpoint = DiagnosticProbeCodec.string(from: object["endpoint"] ?? object["cell"] ?? object["target"]) else {
            throw NSError(domain: "StateSnapshotCell", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Expected a target endpoint string or object payload."
            ])
        }
        let label = DiagnosticProbeCodec.string(from: object["label"])
        return StateSnapshotTarget(endpoint: endpoint, label: label)
    }

    private func parseKeys(from value: ValueType) throws -> [String] {
        switch value {
        case let .string(key):
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        case let .list(list):
            return list.compactMap { DiagnosticProbeCodec.string(from: $0) }.sorted()
        case let .object(object):
            if let keys = DiagnosticProbeCodec.list(from: object["keys"]) {
                return keys.compactMap { DiagnosticProbeCodec.string(from: $0) }.sorted()
            }
            return []
        case .null:
            return []
        default:
            throw NSError(domain: "StateSnapshotCell", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Expected a string or list payload for stateSnapshot.keys."
            ])
        }
    }

    private func applyInlineConfiguration(from value: ValueType) throws {
        switch value {
        case .null:
            return
        case .string, .cellConfiguration:
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
            if let keysValue = object["keys"] {
                let keys = try parseKeys(from: keysValue)
                stateQueue.sync {
                    configuredKeys = keys
                }
            }
        default:
            throw NSError(domain: "StateSnapshotCell", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported inline configuration for stateSnapshot.capture."
            ])
        }
    }

    private static func target(from configuration: CellConfiguration) -> StateSnapshotTarget? {
        if let source = configuration.discovery?.sourceCellEndpoint, !source.isEmpty {
            return StateSnapshotTarget(endpoint: source, label: configuration.discovery?.sourceCellName)
        }
        if let firstReference = configuration.cellReferences?.first {
            return StateSnapshotTarget(endpoint: firstReference.endpoint, label: firstReference.label)
        }
        return nil
    }

    private static func isoTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
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

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results = [T]()
        results.reserveCapacity(count)
        for element in self {
            try await results.append(transform(element))
        }
        return results
    }
}
