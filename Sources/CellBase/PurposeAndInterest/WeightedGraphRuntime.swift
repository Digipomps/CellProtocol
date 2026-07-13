// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum WeightedGraphNodeKind: String, Codable, Equatable {
    case purpose
    case interest
    case entityRepresentation
    case unknown
}

public enum WeightedGraphRuntimeError: Error {
    case unresolvedWeightedNode(reference: String?)
}

public enum WeightedGraphRevisitPolicy: String, Codable {
    case never
    case oncePerPath
}

public struct WeightedGraphNodeRef: Codable, Equatable {
    public var kind: WeightedGraphNodeKind
    public var reference: String
    public var name: String

    public init(kind: WeightedGraphNodeKind, reference: String, name: String) {
        self.kind = kind
        self.reference = reference
        self.name = name
    }

    public var stableKey: String {
        "\(kind.rawValue):\(reference)"
    }
}

public struct MatchEvidence: Codable, Equatable {
    public var relationship: PerspectiveRelationship
    public var from: WeightedGraphNodeRef
    public var to: WeightedGraphNodeRef
    public var edgeWeight: Double
    public var requestedWeight: Double
    public var tolerance: Double
    public var contribution: Double
    public var accumulatedScore: Double
    public var depth: Int

    public init(
        relationship: PerspectiveRelationship,
        from: WeightedGraphNodeRef,
        to: WeightedGraphNodeRef,
        edgeWeight: Double,
        requestedWeight: Double,
        tolerance: Double,
        contribution: Double,
        accumulatedScore: Double,
        depth: Int
    ) {
        self.relationship = relationship
        self.from = from
        self.to = to
        self.edgeWeight = edgeWeight
        self.requestedWeight = requestedWeight
        self.tolerance = tolerance
        self.contribution = contribution
        self.accumulatedScore = accumulatedScore
        self.depth = depth
    }
}

public struct MatchHit: Codable, Equatable {
    public var ref: String
    public var node: WeightedGraphNodeRef
    public var score: Double
    public var depth: Int
    public var path: [WeightedGraphNodeRef]
    public var evidence: [MatchEvidence]

    public init(
        ref: String,
        node: WeightedGraphNodeRef,
        score: Double,
        depth: Int,
        path: [WeightedGraphNodeRef],
        evidence: [MatchEvidence]
    ) {
        self.ref = ref
        self.node = node
        self.score = score
        self.depth = depth
        self.path = path
        self.evidence = evidence
    }
}

public struct MatchDiagnostics: Codable, Equatable, Sendable {
    public var framesEnqueued: Int
    public var framesDequeued: Int
    public var maxQueueLength: Int
    public var edgesExamined: Int
    public var edgesWithinTolerance: Int
    public var hitsRecorded: Int
    public var collectorRecords: Int
    public var skippedByTolerance: Int
    public var skippedByPathCycle: Int
    public var skippedByCondition: Int
    public var skippedByMinScore: Int
    public var skippedByMaxHops: Int
    public var skippedByRevisitPolicy: Int
    public var uniqueVisitedCount: Int
    public var uniqueHitCount: Int

    public init(
        framesEnqueued: Int = 0,
        framesDequeued: Int = 0,
        maxQueueLength: Int = 0,
        edgesExamined: Int = 0,
        edgesWithinTolerance: Int = 0,
        hitsRecorded: Int = 0,
        collectorRecords: Int = 0,
        skippedByTolerance: Int = 0,
        skippedByPathCycle: Int = 0,
        skippedByCondition: Int = 0,
        skippedByMinScore: Int = 0,
        skippedByMaxHops: Int = 0,
        skippedByRevisitPolicy: Int = 0,
        uniqueVisitedCount: Int = 0,
        uniqueHitCount: Int = 0
    ) {
        self.framesEnqueued = framesEnqueued
        self.framesDequeued = framesDequeued
        self.maxQueueLength = maxQueueLength
        self.edgesExamined = edgesExamined
        self.edgesWithinTolerance = edgesWithinTolerance
        self.hitsRecorded = hitsRecorded
        self.collectorRecords = collectorRecords
        self.skippedByTolerance = skippedByTolerance
        self.skippedByPathCycle = skippedByPathCycle
        self.skippedByCondition = skippedByCondition
        self.skippedByMinScore = skippedByMinScore
        self.skippedByMaxHops = skippedByMaxHops
        self.skippedByRevisitPolicy = skippedByRevisitPolicy
        self.uniqueVisitedCount = uniqueVisitedCount
        self.uniqueHitCount = uniqueHitCount
    }
}

public struct MatchResult: Codable, Equatable {
    public var token: String
    public var hits: [MatchHit]
    public var visitedRefs: [String]
    public var accumulatedEvidence: [MatchEvidence]
    public var localVariables: Object
    public var elapsedSeconds: Double
    public var expired: Bool
    public var maxDepthReached: Int
    public var diagnostics: MatchDiagnostics

    public init(
        token: String,
        hits: [MatchHit],
        visitedRefs: [String],
        accumulatedEvidence: [MatchEvidence],
        localVariables: Object = [:],
        elapsedSeconds: Double,
        expired: Bool,
        maxDepthReached: Int,
        diagnostics: MatchDiagnostics = MatchDiagnostics()
    ) {
        self.token = token
        self.hits = hits
        self.visitedRefs = visitedRefs
        self.accumulatedEvidence = accumulatedEvidence
        self.localVariables = localVariables
        self.elapsedSeconds = elapsedSeconds
        self.expired = expired
        self.maxDepthReached = maxDepthReached
        self.diagnostics = diagnostics
    }

    public static func == (lhs: MatchResult, rhs: MatchResult) -> Bool {
        lhs.token == rhs.token &&
            lhs.hits == rhs.hits &&
            lhs.visitedRefs == rhs.visitedRefs &&
            lhs.accumulatedEvidence == rhs.accumulatedEvidence &&
            encodedLocalVariables(lhs.localVariables) == encodedLocalVariables(rhs.localVariables) &&
            lhs.elapsedSeconds == rhs.elapsedSeconds &&
            lhs.expired == rhs.expired &&
            lhs.maxDepthReached == rhs.maxDepthReached &&
            lhs.diagnostics == rhs.diagnostics
    }

    private enum CodingKeys: String, CodingKey {
        case token
        case hits
        case visitedRefs
        case accumulatedEvidence
        case localVariables
        case elapsedSeconds
        case expired
        case maxDepthReached
        case diagnostics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.token = try container.decode(String.self, forKey: .token)
        self.hits = try container.decode([MatchHit].self, forKey: .hits)
        self.visitedRefs = try container.decode([String].self, forKey: .visitedRefs)
        self.accumulatedEvidence = try container.decode([MatchEvidence].self, forKey: .accumulatedEvidence)
        self.localVariables = try container.decodeIfPresent(Object.self, forKey: .localVariables) ?? [:]
        self.elapsedSeconds = try container.decode(Double.self, forKey: .elapsedSeconds)
        self.expired = try container.decode(Bool.self, forKey: .expired)
        self.maxDepthReached = try container.decode(Int.self, forKey: .maxDepthReached)
        self.diagnostics = try container.decodeIfPresent(MatchDiagnostics.self, forKey: .diagnostics) ?? MatchDiagnostics()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(hits, forKey: .hits)
        try container.encode(visitedRefs, forKey: .visitedRefs)
        try container.encode(accumulatedEvidence, forKey: .accumulatedEvidence)
        try container.encode(localVariables, forKey: .localVariables)
        try container.encode(elapsedSeconds, forKey: .elapsedSeconds)
        try container.encode(expired, forKey: .expired)
        try container.encode(maxDepthReached, forKey: .maxDepthReached)
        try container.encode(diagnostics, forKey: .diagnostics)
    }

    private static func encodedLocalVariables(_ value: Object) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct WeightedGraphRuntimeConfiguration {
    public var relationships: [PerspectiveRelationship]
    public var maxHops: Int
    public var ttl: TimeInterval
    public var maxHits: Int
    public var minScore: Double
    public var revisitPolicy: WeightedGraphRevisitPolicy
    public var localVariables: Object
    public var conditionContext: InterestConditionContext?

    public init(
        relationships: [PerspectiveRelationship],
        maxHops: Int,
        ttl: TimeInterval,
        maxHits: Int = Int.max,
        minScore: Double = 0.0,
        revisitPolicy: WeightedGraphRevisitPolicy = .never,
        localVariables: Object = [:],
        conditionContext: InterestConditionContext? = nil
    ) {
        self.relationships = relationships
        self.maxHops = max(0, maxHops)
        self.ttl = max(0.0, ttl)
        self.maxHits = max(1, maxHits)
        self.minScore = minScore
        self.revisitPolicy = revisitPolicy
        self.localVariables = localVariables
        self.conditionContext = conditionContext
    }

    public init(signal: Signal) {
        self.init(
            relationships: [signal.relationship],
            maxHops: signal.hops,
            ttl: signal.ttl,
            localVariables: signal.localVariables
        )
    }
}

public struct SignalRunState {
    public let token: String
    public let startedAt: Date
    public let deadline: Date
    public private(set) var visitedRefs: Set<String>
    public private(set) var path: [WeightedGraphNodeRef]
    public private(set) var accumulatedEvidence: [MatchEvidence]
    public private(set) var accumulatedScore: Double
    public private(set) var localVariables: Object
    public private(set) var remainingHops: Int
    public private(set) var expired: Bool
    public private(set) var maxDepthReached: Int
    public private(set) var diagnostics: MatchDiagnostics

    private var hitsByRef: [String: MatchHit]

    public init(signal: Signal, configuration: WeightedGraphRuntimeConfiguration, start: WeightedGraphNodeRef) {
        self.token = signal.token
        self.startedAt = Date()
        self.deadline = startedAt.addingTimeInterval(configuration.ttl)
        self.visitedRefs = [start.stableKey]
        self.path = [start]
        self.accumulatedEvidence = []
        self.accumulatedScore = 1.0
        self.localVariables = configuration.localVariables
        self.remainingHops = configuration.maxHops
        self.expired = false
        self.maxDepthReached = 0
        self.diagnostics = MatchDiagnostics(framesEnqueued: 1, maxQueueLength: 1)
        self.hitsByRef = [:]
    }

    public var hits: [MatchHit] {
        hitsByRef.values.sorted {
            if $0.score == $1.score {
                if $0.depth == $1.depth {
                    return $0.ref < $1.ref
                }
                return $0.depth < $1.depth
            }
            return $0.score > $1.score
        }
    }

    mutating func markExpired() {
        expired = true
    }

    mutating func visit(_ node: WeightedGraphNodeRef) {
        visitedRefs.insert(node.stableKey)
    }

    func hasVisited(_ node: WeightedGraphNodeRef) -> Bool {
        visitedRefs.contains(node.stableKey)
    }

    mutating func record(_ hit: MatchHit) {
        accumulatedEvidence.append(contentsOf: hit.evidence)
        accumulatedScore = max(accumulatedScore, hit.score)
        remainingHops = max(0, remainingHops - 1)
        maxDepthReached = max(maxDepthReached, hit.depth)
        diagnostics.hitsRecorded += 1

        if let existing = hitsByRef[hit.ref] {
            if hit.score > existing.score || (hit.score == existing.score && hit.depth < existing.depth) {
                hitsByRef[hit.ref] = hit
            }
        } else {
            hitsByRef[hit.ref] = hit
        }
    }

    mutating func recordFrameDequeued() {
        diagnostics.framesDequeued += 1
    }

    mutating func recordFrameEnqueued(queueLength: Int) {
        diagnostics.framesEnqueued += 1
        diagnostics.maxQueueLength = max(diagnostics.maxQueueLength, queueLength)
    }

    mutating func recordEdgeExamined() {
        diagnostics.edgesExamined += 1
    }

    mutating func recordEdgeWithinTolerance() {
        diagnostics.edgesWithinTolerance += 1
    }

    mutating func recordCollectorRecord() {
        diagnostics.collectorRecords += 1
    }

    mutating func recordSkippedByTolerance() {
        diagnostics.skippedByTolerance += 1
    }

    mutating func recordSkippedByPathCycle() {
        diagnostics.skippedByPathCycle += 1
    }

    mutating func recordSkippedByCondition() {
        diagnostics.skippedByCondition += 1
    }

    mutating func recordSkippedByMinScore() {
        diagnostics.skippedByMinScore += 1
    }

    mutating func recordSkippedByMaxHops() {
        diagnostics.skippedByMaxHops += 1
    }

    mutating func recordSkippedByRevisitPolicy() {
        diagnostics.skippedByRevisitPolicy += 1
    }

    func result(maxHits: Int) -> MatchResult {
        var resultDiagnostics = diagnostics
        resultDiagnostics.uniqueVisitedCount = visitedRefs.count
        resultDiagnostics.uniqueHitCount = hits.count
        return MatchResult(
            token: token,
            hits: Array(hits.prefix(maxHits)),
            visitedRefs: visitedRefs.sorted(),
            accumulatedEvidence: accumulatedEvidence,
            localVariables: localVariables,
            elapsedSeconds: Date().timeIntervalSince(startedAt),
            expired: expired,
            maxDepthReached: maxDepthReached,
            diagnostics: resultDiagnostics
        )
    }
}

public struct WeightedGraphRuntime {
    public init() {}

    public func match(
        start: any PerspectiveNode,
        signal: Signal,
        configuration explicitConfiguration: WeightedGraphRuntimeConfiguration? = nil
    ) async throws -> MatchResult {
        let configuration = explicitConfiguration ?? WeightedGraphRuntimeConfiguration(signal: signal)
        let startRef = Self.nodeRef(start)
        var state = SignalRunState(signal: signal, configuration: configuration, start: startRef)
        var queue = [
            TraversalFrame(
                node: start,
                nodeRef: startRef,
                path: [startRef],
                evidence: [],
                accumulatedScore: 1.0,
                depth: 0
            )
        ]

        var queueCursor = 0
        while queueCursor < queue.count {
            if Date() > state.deadline {
                state.markExpired()
                break
            }

            let frame = queue[queueCursor]
            queueCursor += 1
            state.recordFrameDequeued()
            guard frame.depth < configuration.maxHops else {
                state.recordSkippedByMaxHops()
                continue
            }

            for relationship in configuration.relationships {
                let edges = Self.weightedEdges(from: frame.node, relationship: relationship)
                for weighted in edges {
                    state.recordEdgeExamined()
                    guard Self.isSignalMatch(weighted.weight, signal: signal) else {
                        state.recordSkippedByTolerance()
                        continue
                    }
                    state.recordEdgeWithinTolerance()
                    let target = try await Self.resolve(weighted)
                    let targetRef = Self.nodeRef(target)
                    guard !frame.path.contains(targetRef) else {
                        state.recordSkippedByPathCycle()
                        continue
                    }
                    guard Self.conditionsAllow(target, context: configuration.conditionContext) else {
                        state.recordSkippedByCondition()
                        continue
                    }

                    let targetAlreadyVisited = state.hasVisited(targetRef)
                    let contribution = Self.scoreContribution(edgeWeight: weighted.weight, signal: signal)
                    let accumulatedScore = frame.accumulatedScore * contribution
                    guard accumulatedScore >= configuration.minScore else {
                        state.recordSkippedByMinScore()
                        continue
                    }
                    state.visit(targetRef)

                    let evidence = MatchEvidence(
                        relationship: relationship,
                        from: frame.nodeRef,
                        to: targetRef,
                        edgeWeight: weighted.weight,
                        requestedWeight: signal.weight,
                        tolerance: signal.tolerance,
                        contribution: contribution,
                        accumulatedScore: accumulatedScore,
                        depth: frame.depth + 1
                    )
                    let path = frame.path + [targetRef]
                    let hit = MatchHit(
                        ref: targetRef.reference,
                        node: targetRef,
                        score: accumulatedScore,
                        depth: frame.depth + 1,
                        path: path,
                        evidence: frame.evidence + [evidence]
                    )
                    state.record(hit)
                    if let collector = signal.collector {
                        await collector.record(hit)
                        state.recordCollectorRecord()
                    }

                    guard frame.depth + 1 < configuration.maxHops else {
                        state.recordSkippedByMaxHops()
                        continue
                    }
                    switch configuration.revisitPolicy {
                    case .never:
                        guard !targetAlreadyVisited else {
                            state.recordSkippedByRevisitPolicy()
                            continue
                        }
                    case .oncePerPath:
                        break
                    }

                    queue.append(
                        TraversalFrame(
                            node: target,
                            nodeRef: targetRef,
                            path: path,
                            evidence: hit.evidence,
                            accumulatedScore: accumulatedScore,
                            depth: frame.depth + 1
                        )
                    )
                    state.recordFrameEnqueued(queueLength: queue.count - queueCursor)
                }
            }
        }

        return state.result(maxHits: configuration.maxHits)
    }

    private struct TraversalFrame {
        var node: any PerspectiveNode
        var nodeRef: WeightedGraphNodeRef
        var path: [WeightedGraphNodeRef]
        var evidence: [MatchEvidence]
        var accumulatedScore: Double
        var depth: Int
    }

    private static func weightedEdges(from node: any PerspectiveNode, relationship: PerspectiveRelationship) -> [Weighted] {
        switch relationship {
        case .purposes:
            return node.purposes
        case .interests:
            return node.interests
        case .entities:
            return node.entities
        case .states:
            return node.states
        case .types:
            return node.types
        case .parts:
            return node.parts
        case .partOf:
            return node.partOf
        case .subTypes:
            return node.subTypes
        }
    }

    private static func resolve(_ weighted: Weighted) async throws -> any PerspectiveNode {
        if let weightedInterest = weighted as? Weight<Interest> {
            return try await weightedInterest.node
        }
        if let weightedPurpose = weighted as? Weight<Purpose> {
            return try await weightedPurpose.node
        }
        if let weightedEntity = weighted as? Weight<EntityRepresentation> {
            return try await weightedEntity.node
        }
        if let value = weighted.value {
            return value
        }
        throw WeightedGraphRuntimeError.unresolvedWeightedNode(reference: weighted.reference)
    }

    private static func conditionsAllow(_ node: any PerspectiveNode, context: InterestConditionContext?) -> Bool {
        guard let interest = node as? Interest else {
            return true
        }
        return interest.conditionSatisfied(in: context)
    }

    private static func isSignalMatch(_ edgeWeight: Double, signal: Signal) -> Bool {
        let delta = abs(edgeWeight - signal.weight)
        if signal.tolerance <= 0 {
            return delta == 0
        }
        return delta <= signal.tolerance
    }

    private static func scoreContribution(edgeWeight: Double, signal: Signal) -> Double {
        let delta = abs(edgeWeight - signal.weight)
        if signal.tolerance <= 0 {
            return delta == 0 ? 1.0 : 0.0
        }
        return max(0.0, 1.0 - (delta / signal.tolerance))
    }

    private static func nodeRef(_ node: any PerspectiveNode) -> WeightedGraphNodeRef {
        WeightedGraphNodeRef(
            kind: nodeKind(node),
            reference: node.reference,
            name: node.name
        )
    }

    private static func nodeKind(_ node: any PerspectiveNode) -> WeightedGraphNodeKind {
        if node is Purpose {
            return .purpose
        }
        if node is Interest {
            return .interest
        }
        if node is EntityRepresentation {
            return .entityRepresentation
        }
        return .unknown
    }
}

public extension PerspectiveRelationship {
    var stringValue: String {
        switch self {
        case .purposes:
            return "purposes"
        case .interests:
            return "interests"
        case .entities:
            return "entities"
        case .states:
            return "states"
        case .types:
            return "types"
        case .parts:
            return "parts"
        case .partOf:
            return "partOf"
        case .subTypes:
            return "subTypes"
        }
    }

    init?(stringValue: String) {
        switch stringValue {
        case "purposes":
            self = .purposes
        case "interests":
            self = .interests
        case "entities":
            self = .entities
        case "states":
            self = .states
        case "types":
            self = .types
        case "parts":
            self = .parts
        case "partOf":
            self = .partOf
        case "subTypes":
            self = .subTypes
        default:
            return nil
        }
    }
}

extension PerspectiveRelationship: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let relationship = PerspectiveRelationship(stringValue: value) else {
            throw Swift.DecodingError.dataCorrupted(
                Swift.DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown perspective relationship: \(value)")
            )
        }
        self = relationship
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}
