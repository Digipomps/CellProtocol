// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum RelationalNodeType: String, Codable, CaseIterable, Sendable {
    case purpose
    case interest
    case entityRepresentation
    case contextBlock
}

public struct RelationalNode: Codable, Hashable, Sendable {
    public var type: RelationalNodeType
    public var id: String

    public init(type: RelationalNodeType, id: String) {
        self.type = type
        self.id = id
    }
}

public enum RelationalEdgeRelationType: String, Codable, CaseIterable, Sendable {
    case purposeInterest
    case purposeEntity
    case purposeContextBlock
    case purposePurpose
}

public struct RelationalEdgeKey: Codable, Hashable, Sendable {
    public var fromNode: RelationalNode
    public var relationType: RelationalEdgeRelationType
    public var toNode: RelationalNode

    public init(fromNode: RelationalNode,
                relationType: RelationalEdgeRelationType,
                toNode: RelationalNode) {
        self.fromNode = fromNode
        self.relationType = relationType
        self.toNode = toNode
    }
}

public struct RelationalEdge: Codable, Equatable, Sendable {
    public var fromNode: RelationalNode
    public var relationType: RelationalEdgeRelationType
    public var toNode: RelationalNode
    public var weightStored: Double
    public var lastReinforcedAt: TimeInterval
    public var decayProfileId: String
    public var decayParamsVersion: Int
    public var metadata: [String: String]

    public init(fromNode: RelationalNode,
                relationType: RelationalEdgeRelationType,
                toNode: RelationalNode,
                weightStored: Double,
                lastReinforcedAt: TimeInterval,
                decayProfileId: String,
                decayParamsVersion: Int,
                metadata: [String: String] = [:]) {
        self.fromNode = fromNode
        self.relationType = relationType
        self.toNode = toNode
        self.weightStored = RelationalMath.clamp01(weightStored)
        self.lastReinforcedAt = lastReinforcedAt
        self.decayProfileId = decayProfileId
        self.decayParamsVersion = decayParamsVersion
        self.metadata = metadata
    }

    public var key: RelationalEdgeKey {
        RelationalEdgeKey(fromNode: fromNode, relationType: relationType, toNode: toNode)
    }
}

public enum RelationalLearningOutcome: String, Codable, Sendable {
    case success
    case failure
    case explicitPreference
}

public enum RelationalLearningEventType: String, Codable, Sendable {
    case purposeLifecycle
    case weightUpdate
    case decayPolicyUpdated
    case contextTransition
    case explicitPreference
}

public struct RelationalLearningEventEnvelope: Codable, Sendable {
    public var eventType: RelationalLearningEventType
    public var schemaVersion: String
    public var emittedAt: TimeInterval
    public var payload: Object

    public init(eventType: RelationalLearningEventType,
                schemaVersion: String = "1.0",
                emittedAt: TimeInterval,
                payload: Object) {
        self.eventType = eventType
        self.schemaVersion = schemaVersion
        self.emittedAt = emittedAt
        self.payload = payload
    }
}

public enum RelationalPurposeLifecycleStatus: String, Codable, Sendable {
    case started
    case succeeded
    case failed
}

public struct RelationalContextBlockSignal: Codable, Hashable, Sendable {
    public var domain: String
    public var blockId: String
    public var confidence: Double
    public var metadata: [String: String]

    public init(domain: String,
                blockId: String,
                confidence: Double = 1.0,
                metadata: [String: String] = [:]) {
        self.domain = domain
        self.blockId = blockId
        self.confidence = RelationalMath.clamp01(confidence)
        self.metadata = metadata
    }

    public var node: RelationalNode {
        RelationalNode(type: .contextBlock, id: "\(domain):\(blockId)")
    }
}

public struct RelationalPurposeLifecycleEvent: Codable, Sendable {
    public var eventId: String
    public var timestamp: TimeInterval
    public var status: RelationalPurposeLifecycleStatus
    public var purposeId: String
    public var activeInterestRefs: [String]
    public var passiveInterestRefs: [String]
    public var activeEntityRefs: [String]
    public var passiveEntityRefs: [String]
    public var activeContextBlocks: [RelationalContextBlockSignal]
    public var contextConfidence: Double?
    public var metadata: [String: String]

    public init(eventId: String = UUID().uuidString,
                timestamp: TimeInterval,
                status: RelationalPurposeLifecycleStatus,
                purposeId: String,
                activeInterestRefs: [String] = [],
                passiveInterestRefs: [String] = [],
                activeEntityRefs: [String] = [],
                passiveEntityRefs: [String] = [],
                activeContextBlocks: [RelationalContextBlockSignal] = [],
                contextConfidence: Double? = nil,
                metadata: [String: String] = [:]) {
        self.eventId = eventId
        self.timestamp = timestamp
        self.status = status
        self.purposeId = purposeId
        self.activeInterestRefs = activeInterestRefs
        self.passiveInterestRefs = passiveInterestRefs
        self.activeEntityRefs = activeEntityRefs
        self.passiveEntityRefs = passiveEntityRefs
        self.activeContextBlocks = activeContextBlocks
        self.contextConfidence = contextConfidence.map(RelationalMath.clamp01)
        self.metadata = metadata
    }

    public var purposeNode: RelationalNode {
        RelationalNode(type: .purpose, id: purposeId)
    }
}

public struct RelationalExplicitPreferenceEvent: Codable, Sendable {
    public var eventId: String
    public var timestamp: TimeInterval
    public var purposeId: String
    public var relationType: RelationalEdgeRelationType
    public var targetNode: RelationalNode
    public var preferenceWeight: Double
    public var metadata: [String: String]

    public init(eventId: String = UUID().uuidString,
                timestamp: TimeInterval,
                purposeId: String,
                relationType: RelationalEdgeRelationType,
                targetNode: RelationalNode,
                preferenceWeight: Double = RelationalLearningDefaults.explicitPreferenceWeight,
                metadata: [String: String] = [:]) {
        self.eventId = eventId
        self.timestamp = timestamp
        self.purposeId = purposeId
        self.relationType = relationType
        self.targetNode = targetNode
        self.preferenceWeight = RelationalMath.clamp01(preferenceWeight)
        self.metadata = metadata
    }
}

public struct RelationalWeightUpdateEvent: Codable, Sendable {
    public var eventId: String
    public var emittedAt: TimeInterval
    public var sourceEventId: String?
    public var outcome: RelationalLearningOutcome
    public var edge: RelationalEdge
    public var previousWeightStored: Double
    public var newWeightStored: Double
    public var learningRate: Double
    public var eligibility: Double
    public var reason: String

    public init(eventId: String = UUID().uuidString,
                emittedAt: TimeInterval,
                sourceEventId: String?,
                outcome: RelationalLearningOutcome,
                edge: RelationalEdge,
                previousWeightStored: Double,
                newWeightStored: Double,
                learningRate: Double,
                eligibility: Double,
                reason: String) {
        self.eventId = eventId
        self.emittedAt = emittedAt
        self.sourceEventId = sourceEventId
        self.outcome = outcome
        self.edge = edge
        self.previousWeightStored = RelationalMath.clamp01(previousWeightStored)
        self.newWeightStored = RelationalMath.clamp01(newWeightStored)
        self.learningRate = max(0.0, learningRate)
        self.eligibility = RelationalMath.clamp01(eligibility)
        self.reason = reason
    }
}

public struct RelationalContextTransitionEvent: Codable, Sendable {
    public var eventId: String
    public var timestamp: TimeInterval
    public var domain: String
    public var fromBlockId: String?
    public var toBlockId: String
    public var confidence: Double
    public var metadata: [String: String]

    public init(eventId: String = UUID().uuidString,
                timestamp: TimeInterval,
                domain: String,
                fromBlockId: String? = nil,
                toBlockId: String,
                confidence: Double = 1.0,
                metadata: [String: String] = [:]) {
        self.eventId = eventId
        self.timestamp = timestamp
        self.domain = domain
        self.fromBlockId = fromBlockId
        self.toBlockId = toBlockId
        self.confidence = RelationalMath.clamp01(confidence)
        self.metadata = metadata
    }

    public var signal: RelationalContextBlockSignal {
        RelationalContextBlockSignal(domain: domain, blockId: toBlockId, confidence: confidence, metadata: metadata)
    }
}

public struct RelationalContextSnapshot: Codable, Hashable, Sendable {
    public var activeInterestRefs: [String]
    public var passiveInterestRefs: [String]
    public var activeEntityRefs: [String]
    public var passiveEntityRefs: [String]
    public var activeContextBlocks: [RelationalContextBlockSignal]

    public init(activeInterestRefs: [String] = [],
                passiveInterestRefs: [String] = [],
                activeEntityRefs: [String] = [],
                passiveEntityRefs: [String] = [],
                activeContextBlocks: [RelationalContextBlockSignal] = []) {
        self.activeInterestRefs = activeInterestRefs
        self.passiveInterestRefs = passiveInterestRefs
        self.activeEntityRefs = activeEntityRefs
        self.passiveEntityRefs = passiveEntityRefs
        self.activeContextBlocks = activeContextBlocks
    }
}

public struct RelationalEdgeContributionExplain: Codable, Sendable {
    public var edge: RelationalEdge
    public var effectiveWeight: Double
    public var contribution: Double
    public var decayProfileId: String
    public var decayParamsVersion: Int
    public var decayParams: RelationalNoaDecayParameters?

    public init(edge: RelationalEdge,
                effectiveWeight: Double,
                contribution: Double,
                decayProfileId: String,
                decayParamsVersion: Int,
                decayParams: RelationalNoaDecayParameters?) {
        self.edge = edge
        self.effectiveWeight = RelationalMath.clamp01(effectiveWeight)
        self.contribution = max(0.0, contribution)
        self.decayProfileId = decayProfileId
        self.decayParamsVersion = decayParamsVersion
        self.decayParams = decayParams
    }
}

public struct RelationalPurposeScoreExplain: Codable, Sendable {
    public var evaluatedAt: TimeInterval
    public var rawScore: Double
    public var normalizedScore: Double
    public var topEdges: [RelationalEdgeContributionExplain]

    public init(evaluatedAt: TimeInterval,
                rawScore: Double,
                normalizedScore: Double,
                topEdges: [RelationalEdgeContributionExplain]) {
        self.evaluatedAt = evaluatedAt
        self.rawScore = max(0.0, rawScore)
        self.normalizedScore = RelationalMath.clamp01(normalizedScore)
        self.topEdges = topEdges
    }
}

public struct RelationalPurposeScore: Codable, Sendable {
    public var purposeId: String
    public var score: Double
    public var explain: RelationalPurposeScoreExplain

    public init(purposeId: String,
                score: Double,
                explain: RelationalPurposeScoreExplain) {
        self.purposeId = purposeId
        self.score = RelationalMath.clamp01(score)
        self.explain = explain
    }
}

public enum RelationalLearningDefaults {
    public static let unknownWeight: Double = 0.1
    public static let explicitPreferenceWeight: Double = 0.6
    public static let alphaSuccess: Double = 0.08
    public static let alphaFail: Double = 0.05
    public static let eligibilityActive: Double = 1.0
    public static let eligibilityPassive: Double = 0.3
    public static let eligibilityContextBlock: Double = 0.5
    public static let contextConfidenceGate: Double = 0.6
}

public struct RelationalLearningConfig: Codable, Hashable, Sendable {
    public var unknownWeight: Double
    public var explicitPreferenceWeight: Double
    public var alphaSuccess: Double
    public var alphaFail: Double
    public var eligibilityActive: Double
    public var eligibilityPassive: Double
    public var eligibilityContextBlock: Double
    public var contextConfidenceGate: Double

    public init(unknownWeight: Double = RelationalLearningDefaults.unknownWeight,
                explicitPreferenceWeight: Double = RelationalLearningDefaults.explicitPreferenceWeight,
                alphaSuccess: Double = RelationalLearningDefaults.alphaSuccess,
                alphaFail: Double = RelationalLearningDefaults.alphaFail,
                eligibilityActive: Double = RelationalLearningDefaults.eligibilityActive,
                eligibilityPassive: Double = RelationalLearningDefaults.eligibilityPassive,
                eligibilityContextBlock: Double = RelationalLearningDefaults.eligibilityContextBlock,
                contextConfidenceGate: Double = RelationalLearningDefaults.contextConfidenceGate) {
        self.unknownWeight = RelationalMath.clamp01(unknownWeight)
        self.explicitPreferenceWeight = RelationalMath.clamp01(explicitPreferenceWeight)
        self.alphaSuccess = max(0.0, alphaSuccess)
        self.alphaFail = max(0.0, alphaFail)
        self.eligibilityActive = RelationalMath.clamp01(eligibilityActive)
        self.eligibilityPassive = RelationalMath.clamp01(eligibilityPassive)
        self.eligibilityContextBlock = RelationalMath.clamp01(eligibilityContextBlock)
        self.contextConfidenceGate = RelationalMath.clamp01(contextConfidenceGate)
    }

    public static let `default` = RelationalLearningConfig()
}

public enum RelationalLearningCodec {
    public static func encodeObject<T: Encodable>(_ value: T) throws -> Object {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(Object.self, from: data)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from object: Object) throws -> T {
        let data = try JSONEncoder().encode(object)
        return try JSONDecoder().decode(T.self, from: data)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from value: ValueType) throws -> T {
        guard case let .object(object) = value else {
            throw ValueTypeError.unexpectedValueType
        }
        return try decode(type, from: object)
    }
}

public enum RelationalMath {
    public static func clamp01(_ value: Double) -> Double {
        if value < 0.0 { return 0.0 }
        if value > 1.0 { return 1.0 }
        return value
    }

    public static func normalizedScore(from raw: Double) -> Double {
        clamp01(raw)
    }
}

public extension RelationalLearningEventEnvelope {
    static func from(_ event: RelationalPurposeLifecycleEvent) throws -> RelationalLearningEventEnvelope {
        RelationalLearningEventEnvelope(eventType: .purposeLifecycle,
                                        emittedAt: event.timestamp,
                                        payload: try RelationalLearningCodec.encodeObject(event))
    }

    static func from(_ event: RelationalWeightUpdateEvent) throws -> RelationalLearningEventEnvelope {
        RelationalLearningEventEnvelope(eventType: .weightUpdate,
                                        emittedAt: event.emittedAt,
                                        payload: try RelationalLearningCodec.encodeObject(event))
    }

    static func from(_ event: RelationalDecayPolicyUpdatedEvent) throws -> RelationalLearningEventEnvelope {
        RelationalLearningEventEnvelope(eventType: .decayPolicyUpdated,
                                        emittedAt: event.emittedAt,
                                        payload: try RelationalLearningCodec.encodeObject(event))
    }

    static func from(_ event: RelationalContextTransitionEvent) throws -> RelationalLearningEventEnvelope {
        RelationalLearningEventEnvelope(eventType: .contextTransition,
                                        emittedAt: event.timestamp,
                                        payload: try RelationalLearningCodec.encodeObject(event))
    }

    static func from(_ event: RelationalExplicitPreferenceEvent) throws -> RelationalLearningEventEnvelope {
        RelationalLearningEventEnvelope(eventType: .explicitPreference,
                                        emittedAt: event.timestamp,
                                        payload: try RelationalLearningCodec.encodeObject(event))
    }
}

public extension RelationalContextTransitionEvent {
    static func fromFlowElement(_ flowElement: FlowElement,
                                fallbackTimestamp: TimeInterval = Date().timeIntervalSince1970) -> RelationalContextTransitionEvent? {
        guard case let .object(payload) = flowElement.content else {
            return nil
        }

        let topic = flowElement.topic
        let domain = domainFrom(topic: topic, payload: payload)
        guard let domain else { return nil }

        let timestamp =
            doubleValue(payload["occurredAt"]) ??
            doubleValue(payload["date"]) ??
            doubleValue(payload["timestamp"]) ??
            fallbackTimestamp

        let confidence =
            doubleValue(payload["confidence"]) ??
            doubleValue(payload["contextConfidence"]) ??
            doubleValue(payload["transitionConfidence"]) ??
            1.0

        let transition = objectValue(payload["transition"])
        let contextObject = objectValue(payload["context"])

        let fromBlock =
            stringValue(transition?["from"]) ??
            stringValue(payload["from"]) ??
            stringValue(contextObject?["from"]) ??
            nil

        let toBlock =
            stringValue(transition?["to"]) ??
            stringValue(payload["to"]) ??
            stringValue(payload["symbol"]) ??
            stringValue(contextObject?["label"]) ??
            stringValue(contextObject?["blockId"]) ??
            legacyBlockId(domain: domain, payload: payload)

        guard let toBlock, !toBlock.isEmpty else {
            return nil
        }

        var metadata = [String: String]()
        metadata["topic"] = topic
        if let eventKind = stringValue(payload["eventType"]) {
            metadata["eventType"] = eventKind
        }
        if let type = stringValue(payload["type"]) {
            metadata["type"] = type
        }

        return RelationalContextTransitionEvent(
            eventId: stringValue(payload["eventId"]) ?? flowElement.id,
            timestamp: timestamp,
            domain: domain,
            fromBlockId: fromBlock,
            toBlockId: toBlock,
            confidence: confidence,
            metadata: metadata
        )
    }

    private static func domainFrom(topic: String, payload: Object) -> String? {
        if let explicit = stringValue(payload["domain"]), !explicit.isEmpty {
            return explicit
        }

        if topic.hasPrefix("context.location") || topic == "locations" {
            return "location"
        }
        if topic.hasPrefix("context.time") || topic == "times" {
            return "time"
        }
        if topic.hasPrefix("context.entities") || topic == "entities" {
            return "entities"
        }
        return nil
    }

    private static func legacyBlockId(domain: String, payload: Object) -> String? {
        if let symbol = stringValue(payload["symbol"]), !symbol.isEmpty {
            return symbol
        }

        if domain == "location" {
            if let locationObject = objectValue(payload["location"]) ?? objectValue(payload["position"]) {
                if let latitude = doubleValue(locationObject["latitude"]),
                   let longitude = doubleValue(locationObject["longitude"]) {
                    return String(format: "geo:%.3f:%.3f", latitude, longitude)
                }
            }
        }

        if let type = stringValue(payload["type"]), !type.isEmpty {
            return type
        }

        return nil
    }

    private static func objectValue(_ value: ValueType?) -> Object? {
        guard let value else { return nil }
        if case let .object(object) = value {
            return object
        }
        return nil
    }

    private static func stringValue(_ value: ValueType?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let string): return string
        case .integer(let integer): return String(integer)
        case .number(let number): return String(number)
        case .float(let double): return String(double)
        case .bool(let bool): return bool ? "true" : "false"
        default: return nil
        }
    }

    private static func doubleValue(_ value: ValueType?) -> Double? {
        guard let value else { return nil }
        switch value {
        case .float(let double): return double
        case .integer(let integer): return Double(integer)
        case .number(let number): return Double(number)
        case .string(let string): return Double(string)
        default: return nil
        }
    }
}
