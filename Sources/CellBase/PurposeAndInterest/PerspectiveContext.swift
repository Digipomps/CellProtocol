// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Semantic source state. A source owns sensing and interpretation of its labels.
public struct ContextObservation: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var revision: Int
    public var observedAt: Date
    public var validUntil: Date
    public var transition: String
    public var labels: [String]
    public var configurationRevision: Int
    public init(revision: Int, observedAt: Date, validUntil: Date, transition: String, labels: [String], configurationRevision: Int = 0) {
        self.schemaVersion = 1; self.revision = revision; self.observedAt = observedAt
        self.validUntil = validUntil; self.transition = transition; self.labels = labels
        self.configurationRevision = configurationRevision
    }
    public func validate(now: Date) throws {
        guard schemaVersion == 1, revision >= 0, configurationRevision >= 0,
              validUntil > observedAt, observedAt <= now.addingTimeInterval(30),
              ["snapshot", "entered", "left", "configurationChanged"].contains(transition),
              labels.count <= 128, Set(labels).count == labels.count,
              labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
            throw ContextError.invalidObservation
        }
    }
}

public struct ContextSource: Codable, Equatable, Sendable {
    public var sourceID: String
    public var endpoint: String
    public var enabled: Bool
    public var snapshotKey: String
    public init(sourceID: String, endpoint: String, snapshotKey: String = "context.observation", enabled: Bool = true) {
        self.sourceID = sourceID; self.endpoint = endpoint; self.snapshotKey = snapshotKey; self.enabled = enabled
    }
}
public struct ContextRule: Codable, Sendable {
    public var id: String
    public var priority: Int
    public var definition: GoalDefinition
    public var label: String
    public var purposeWeights: [String: Double]
    public init(id: String, priority: Int = 0, definition: GoalDefinition, label: String, purposeWeights: [String: Double] = [:]) {
        self.id = id; self.priority = priority; self.definition = definition; self.label = label; self.purposeWeights = purposeWeights
    }
}
public struct ContextConfiguration: Codable, Sendable {
    public var sources: [ContextSource]
    public var rules: [ContextRule]
    public init(sources: [ContextSource] = [], rules: [ContextRule] = []) { self.sources = sources; self.rules = rules }
    public func validate() throws {
        guard sources.count <= 128, rules.count <= 256,
              Set(sources.map(\.sourceID)).count == sources.count,
              Set(rules.map(\.id)).count == rules.count,
              sources.allSatisfy({ !$0.sourceID.isEmpty && !$0.endpoint.isEmpty && !$0.snapshotKey.isEmpty }) else { throw ContextError.invalidConfiguration }
        let ids = Set(sources.map(\.sourceID))
        for rule in rules {
            guard !rule.id.isEmpty, !rule.label.isEmpty,
                  rule.purposeWeights.values.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  Set(rule.definition.evidenceSources.map(\.sourceID)).count == rule.definition.evidenceSources.count,
                  rule.definition.evidenceSources.allSatisfy({ ids.contains($0.sourceID) }) else { throw ContextError.invalidConfiguration }
        }
    }
}
public enum ContextError: Error { case invalidObservation, invalidConfiguration, unknownSource, conflictingRevision }
public struct ContextDecision: Codable, Equatable, Sendable {
    public var revision: Int
    public var validUntil: Date?
    public var labels: [String]
    public var activeRules: [String]
    public var purposeWeights: [String: Double]
    public var purposeRules: [String: String]
    public var sourceRevisions: [String: Int]
    public var unknownSources: [String]
}

extension ContextDecision {
    public func validate() throws {
        guard revision >= 0, labels.count <= 256, Set(labels).count == labels.count,
              labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              Set(activeRules).count == activeRules.count,
              purposeWeights.values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              sourceRevisions.values.allSatisfy({ $0 >= 0 }),
              (validUntil != nil || (labels.isEmpty && activeRules.isEmpty && purposeWeights.isEmpty)) else {
            throw ContextError.invalidObservation
        }
    }
}

/// Pure, persistable state machine. Runtime serializes access and controls source admission.
public struct PerspectiveContextState: Codable, Sendable {
    public private(set) var revision: Int = 0
    public var configuration: ContextConfiguration
    public private(set) var observations: [String: ContextObservation]
    public private(set) var eventIDs: [String: String]
    // Runtime confirmation is intentionally not persisted.
    public private(set) var confirmed: Set<String> = []
    private enum CodingKeys: String, CodingKey { case revision, configuration, observations, eventIDs }
    public init(configuration: ContextConfiguration = .init()) { self.configuration = configuration; observations = [:]; eventIDs = [:] }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        configuration = try c.decode(ContextConfiguration.self, forKey: .configuration)
        observations = try c.decode([String: ContextObservation].self, forKey: .observations)
        eventIDs = try c.decode([String: String].self, forKey: .eventIDs)
        try configuration.validate()
    }
    public mutating func configure(_ configuration: ContextConfiguration) throws {
        try configuration.validate()
        // Changing a binding invalidates observations and revision history for that binding.
        for source in self.configuration.sources where !configuration.sources.contains(where: { $0.sourceID == source.sourceID && $0.endpoint == source.endpoint && $0.snapshotKey == source.snapshotKey }) {
            observations.removeValue(forKey: source.sourceID); eventIDs.removeValue(forKey: source.sourceID); confirmed.remove(source.sourceID)
        }
        for source in configuration.sources where !source.enabled { confirmed.remove(source.sourceID) }
        self.configuration = configuration
        revision += 1
    }
    @discardableResult public mutating func ingest(_ observation: ContextObservation, sourceID: String, eventID: String, snapshot: Bool, now: Date) throws -> Bool {
        guard configuration.sources.contains(where: { $0.sourceID == sourceID && $0.enabled }) else { throw ContextError.unknownSource }
        try observation.validate(now: now)
        if let old = observations[sourceID] {
            if observation.revision < old.revision { return false }
            if observation.revision == old.revision {
                guard observation == old else { throw ContextError.conflictingRevision }
                if snapshot && observation.validUntil > now { let changed = confirmed.insert(sourceID).inserted; if changed { revision += 1 }; return changed }
                return false
            }
            if eventIDs[sourceID] == eventID { throw ContextError.conflictingRevision }
        }
        revision += 1
        observations[sourceID] = observation; eventIDs[sourceID] = eventID; if observation.validUntil > now { confirmed.insert(sourceID) } else { confirmed.remove(sourceID) }
        return true
    }
    public mutating func disconnect(_ sourceID: String) { if confirmed.remove(sourceID) != nil { revision += 1 } }
    @discardableResult public mutating func expire(now: Date) -> Bool {
        let expired = confirmed.filter { (observations[$0]?.validUntil ?? .distantPast) <= now }
        guard !expired.isEmpty else { return false }
        confirmed.subtract(expired); revision += 1; return true
    }
    public func decision(now: Date) -> ContextDecision {
        let fmt = ISO8601DateFormatter()
        let observations = configuration.sources.compactMap { source -> GoalObservation? in
            guard confirmed.contains(source.sourceID), let event = self.observations[source.sourceID] else { return nil }
            return GoalObservation(sourceID: source.sourceID, status: event.validUntil > now ? .fresh : .stale,
                                   observedAt: fmt.string(from: event.observedAt), labels: event.labels)
        }
        var active = [ContextRule]()
        for rule in configuration.rules {
            let required = Set(rule.definition.evidenceSources.map(\.sourceID))
            let result = GoalEvaluationEngine.evaluate(definition: rule.definition, observations: observations.filter { required.contains($0.sourceID) }, evaluatedAt: fmt.string(from: now))
            if result.status == .satisfied { active.append(rule) }
        }
        active.sort { $0.priority == $1.priority ? $0.id < $1.id : $0.priority > $1.priority }
        var weights = [String: Double](), reasons = [String: String]()
        for rule in active { for (ref, weight) in rule.purposeWeights where weights[ref] == nil { weights[ref] = weight; reasons[ref] = rule.id } }
        return ContextDecision(revision: revision, validUntil: self.observations.filter { confirmed.contains($0.key) && $0.value.validUntil > now }.values.map(\.validUntil).min(), labels: Set(active.map(\.label)).sorted(), activeRules: active.map(\.id), purposeWeights: weights, purposeRules: reasons,
                               sourceRevisions: self.observations.mapValues(\.revision),
                               unknownSources: configuration.sources.filter { source in !confirmed.contains(source.sourceID) || (self.observations[source.sourceID]?.validUntil ?? .distantPast) <= now }.map(\.sourceID).sorted())
    }
}
public enum ContextCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> ValueType {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(ValueType.self, from: e.encode(value))
    }
    public static func decode<T: Decodable>(_ value: ValueType, as type: T.Type) throws -> T {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(type, from: JSONEncoder().encode(value))
    }
    public static func error(_ error: Error) -> ValueType { .object(["status": .string("error"), "message": .string(String(describing: error))]) }
}
/// Serializes whole async transactions, including storage and emission, across actor suspension.
public actor ContextTransactionGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init() {}
    public func enter() async {
        if !held { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    public func leave() { if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() } }
}

/// A startup dependency cycle must fail before waiting on a Cell's connection gate.
public enum ContextConnectionScope {
    @TaskLocal public static var cells: Set<String> = []
    private static let startupGate = ContextTransactionGate()
    /// Serialize independent roots; nested connections share their root's scope.
    /// This prevents two startup Tasks taking opposite per-Cell gate orders.
    public static func perform<T>(_ cellID: String, operation: () async throws -> T) async throws -> T {
        guard !cells.contains(cellID) else { throw ContextError.invalidConfiguration }
        let root = cells.isEmpty
        if root { await startupGate.enter() }
        do {
            let result = try await $cells.withValue(cells.union([cellID]), operation: operation)
            if root { await startupGate.leave() }
            return result
        } catch {
            if root { await startupGate.leave() }
            throw error
        }
    }
}
