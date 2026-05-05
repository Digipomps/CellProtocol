// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

private struct RelationalPurposeSession: Sendable {
    var eventId: String
    var startedAt: TimeInterval
    var purposeId: String
    var activeInterestRefs: Set<String>
    var passiveInterestRefs: Set<String>
    var activeEntityRefs: Set<String>
    var passiveEntityRefs: Set<String>
    var activeContextBlocks: [String: RelationalContextBlockSignal]
    var contextConfidence: Double?

    init(from event: RelationalPurposeLifecycleEvent) {
        self.eventId = event.eventId
        self.startedAt = event.timestamp
        self.purposeId = event.purposeId
        self.activeInterestRefs = Set(event.activeInterestRefs)
        self.passiveInterestRefs = Set(event.passiveInterestRefs)
        self.activeEntityRefs = Set(event.activeEntityRefs)
        self.passiveEntityRefs = Set(event.passiveEntityRefs)
        self.activeContextBlocks = Dictionary(uniqueKeysWithValues: event.activeContextBlocks.map { ($0.node.id, $0) })
        self.contextConfidence = event.contextConfidence
    }

    mutating func merge(with event: RelationalPurposeLifecycleEvent) {
        activeInterestRefs.formUnion(event.activeInterestRefs)
        passiveInterestRefs.formUnion(event.passiveInterestRefs)
        activeEntityRefs.formUnion(event.activeEntityRefs)
        passiveEntityRefs.formUnion(event.passiveEntityRefs)
        for block in event.activeContextBlocks {
            activeContextBlocks[block.node.id] = block
        }
        if let confidence = event.contextConfidence {
            contextConfidence = confidence
        }
    }
}

private struct RelationalEligibilityTrace: Sendable {
    var relationType: RelationalEdgeRelationType
    var toNode: RelationalNode
    var eligibility: Double
    var reason: String
}

public actor RelationalLearningEngine {
    private let config: RelationalLearningConfig
    private var edgesByKey: [RelationalEdgeKey: RelationalEdge]
    private var sessionsByPurpose: [String: RelationalPurposeSession]
    private var activeContextByDomain: [String: RelationalContextBlockSignal]
    private var policiesByProfile: [String: [RelationalDecayPolicy]]
    private var appliedWeightUpdateEventIDs: Set<String>
    private var appliedDecayPolicyEventIDs: Set<String>

    public init(config: RelationalLearningConfig = .default) {
        self.config = config
        self.edgesByKey = [:]
        self.sessionsByPurpose = [:]
        self.activeContextByDomain = [:]
        self.policiesByProfile = [
            RelationalDecayPolicy.defaultNoa.profileId: [RelationalDecayPolicy.defaultNoa]
        ]
        self.appliedWeightUpdateEventIDs = []
        self.appliedDecayPolicyEventIDs = []
    }

    // MARK: Event ingestion

    @discardableResult
    public func applyDecayPolicyUpdatedEvent(_ event: RelationalDecayPolicyUpdatedEvent) -> Bool {
        if appliedDecayPolicyEventIDs.contains(event.eventId) {
            return false
        }

        appliedDecayPolicyEventIDs.insert(event.eventId)
        var policies = policiesByProfile[event.policy.profileId] ?? []

        if let existingIndex = policies.firstIndex(where: { $0.version == event.policy.version }) {
            policies[existingIndex] = event.policy
        } else {
            policies.append(event.policy)
        }

        policies.sort {
            if $0.effectiveFromTimestamp == $1.effectiveFromTimestamp {
                return $0.version < $1.version
            }
            return $0.effectiveFromTimestamp < $1.effectiveFromTimestamp
        }
        policiesByProfile[event.policy.profileId] = policies
        return true
    }

    @discardableResult
    public func observeContextTransitionEvent(_ event: RelationalContextTransitionEvent) -> RelationalContextBlockSignal {
        let signal = event.signal
        activeContextByDomain[event.domain] = signal
        return signal
    }

    public func currentActiveContextBlocks() -> [RelationalContextBlockSignal] {
        activeContextByDomain
            .values
            .sorted(by: { $0.node.id < $1.node.id })
    }

    public func ingestPurposeLifecycleEvent(_ event: RelationalPurposeLifecycleEvent) -> [RelationalWeightUpdateEvent] {
        switch event.status {
        case .started:
            var session = RelationalPurposeSession(from: event)
            for (_, contextSignal) in activeContextByDomain {
                session.activeContextBlocks[contextSignal.node.id] = contextSignal
            }
            sessionsByPurpose[event.purposeId] = session
            return []

        case .succeeded, .failed:
            var session = sessionsByPurpose.removeValue(forKey: event.purposeId) ?? RelationalPurposeSession(from: event)
            session.merge(with: event)
            for (_, contextSignal) in activeContextByDomain {
                session.activeContextBlocks[contextSignal.node.id] = contextSignal
            }

            let confidence = session.contextConfidence ?? 1.0
            guard confidence >= config.contextConfidenceGate else {
                return []
            }

            let traces = buildEligibilityTraces(from: session)
            let policyAtEvent = resolvePolicy(profileId: RelationalDecayPolicy.defaultNoa.profileId,
                                              at: event.timestamp,
                                              fallbackVersion: RelationalDecayPolicy.defaultNoa.version)
            let outcome: RelationalLearningOutcome = event.status == .succeeded ? .success : .failure
            let learningRate = event.status == .succeeded ? config.alphaSuccess : config.alphaFail

            let sortedTraces = traces.sorted {
                if $0.relationType.rawValue == $1.relationType.rawValue {
                    return $0.toNode.id < $1.toNode.id
                }
                return $0.relationType.rawValue < $1.relationType.rawValue
            }

            var updates = [RelationalWeightUpdateEvent]()
            updates.reserveCapacity(sortedTraces.count)

            for trace in sortedTraces {
                let key = RelationalEdgeKey(
                    fromNode: event.purposeNode,
                    relationType: trace.relationType,
                    toNode: trace.toNode
                )

                let existingEdge = edgesByKey[key] ?? RelationalEdge(
                    fromNode: event.purposeNode,
                    relationType: trace.relationType,
                    toNode: trace.toNode,
                    weightStored: config.unknownWeight,
                    lastReinforcedAt: event.timestamp,
                    decayProfileId: policyAtEvent.profileId,
                    decayParamsVersion: policyAtEvent.version,
                    metadata: [:]
                )

                let previousWeight = existingEdge.weightStored
                let nextWeight = reinforcedWeight(previous: previousWeight,
                                                  eligibility: trace.eligibility,
                                                  learningRate: learningRate,
                                                  outcome: outcome)

                let edge = RelationalEdge(
                    fromNode: existingEdge.fromNode,
                    relationType: existingEdge.relationType,
                    toNode: existingEdge.toNode,
                    weightStored: nextWeight,
                    lastReinforcedAt: event.timestamp,
                    decayProfileId: policyAtEvent.profileId,
                    decayParamsVersion: policyAtEvent.version,
                    metadata: [
                        "reason": trace.reason,
                        "sourceLifecycleEventId": event.eventId
                    ]
                )

                let updateEvent = RelationalWeightUpdateEvent(
                    emittedAt: event.timestamp,
                    sourceEventId: event.eventId,
                    outcome: outcome,
                    edge: edge,
                    previousWeightStored: previousWeight,
                    newWeightStored: nextWeight,
                    learningRate: learningRate,
                    eligibility: trace.eligibility,
                    reason: trace.reason
                )
                updates.append(updateEvent)
            }
            return updates
        }
    }

    public func deriveExplicitPreferenceWeightUpdate(_ event: RelationalExplicitPreferenceEvent) -> RelationalWeightUpdateEvent {
        let policyAtEvent = resolvePolicy(profileId: RelationalDecayPolicy.defaultNoa.profileId,
                                          at: event.timestamp,
                                          fallbackVersion: RelationalDecayPolicy.defaultNoa.version)

        let key = RelationalEdgeKey(
            fromNode: RelationalNode(type: .purpose, id: event.purposeId),
            relationType: event.relationType,
            toNode: event.targetNode
        )

        let existingEdge = edgesByKey[key] ?? RelationalEdge(
            fromNode: key.fromNode,
            relationType: key.relationType,
            toNode: key.toNode,
            weightStored: config.unknownWeight,
            lastReinforcedAt: event.timestamp,
            decayProfileId: policyAtEvent.profileId,
            decayParamsVersion: policyAtEvent.version,
            metadata: [:]
        )

        let edge = RelationalEdge(
            fromNode: existingEdge.fromNode,
            relationType: existingEdge.relationType,
            toNode: existingEdge.toNode,
            weightStored: event.preferenceWeight,
            lastReinforcedAt: event.timestamp,
            decayProfileId: policyAtEvent.profileId,
            decayParamsVersion: policyAtEvent.version,
            metadata: [
                "reason": "explicit_preference",
                "sourcePreferenceEventId": event.eventId
            ]
        )

        return RelationalWeightUpdateEvent(
            emittedAt: event.timestamp,
            sourceEventId: event.eventId,
            outcome: .explicitPreference,
            edge: edge,
            previousWeightStored: existingEdge.weightStored,
            newWeightStored: event.preferenceWeight,
            learningRate: 1.0,
            eligibility: 1.0,
            reason: "explicit_preference"
        )
    }

    @discardableResult
    public func applyWeightUpdateEvent(_ event: RelationalWeightUpdateEvent) -> Bool {
        if appliedWeightUpdateEventIDs.contains(event.eventId) {
            return false
        }

        appliedWeightUpdateEventIDs.insert(event.eventId)

        var edge = event.edge
        edge.weightStored = RelationalMath.clamp01(event.newWeightStored)
        edgesByKey[edge.key] = edge
        return true
    }

    public func reset(keepPolicies: Bool = true) {
        edgesByKey = [:]
        sessionsByPurpose = [:]
        activeContextByDomain = [:]
        appliedWeightUpdateEventIDs = []
        appliedDecayPolicyEventIDs = []

        if keepPolicies {
            // keep existing policies
        } else {
            policiesByProfile = [RelationalDecayPolicy.defaultNoa.profileId: [RelationalDecayPolicy.defaultNoa]]
        }
    }

    @discardableResult
    public func replay(events: [RelationalLearningEventEnvelope], resetFirst: Bool = true) -> Int {
        if resetFirst {
            reset(keepPolicies: false)
        }

        var appliedCount = 0
        let sorted = events.sorted {
            if $0.emittedAt != $1.emittedAt {
                return $0.emittedAt < $1.emittedAt
            }
            if $0.eventType.rawValue != $1.eventType.rawValue {
                return $0.eventType.rawValue < $1.eventType.rawValue
            }

            let lhsEventID = eventIdentifier(for: $0)
            let rhsEventID = eventIdentifier(for: $1)
            if lhsEventID != rhsEventID {
                return lhsEventID < rhsEventID
            }

            return canonicalPayloadString($0.payload) < canonicalPayloadString($1.payload)
        }

        for envelope in sorted {
            do {
                switch envelope.eventType {
                case .decayPolicyUpdated:
                    let event = try RelationalLearningCodec.decode(RelationalDecayPolicyUpdatedEvent.self, from: envelope.payload)
                    if applyDecayPolicyUpdatedEvent(event) {
                        appliedCount += 1
                    }
                case .contextTransition:
                    let event = try RelationalLearningCodec.decode(RelationalContextTransitionEvent.self, from: envelope.payload)
                    _ = observeContextTransitionEvent(event)
                    appliedCount += 1
                case .purposeLifecycle:
                    let event = try RelationalLearningCodec.decode(RelationalPurposeLifecycleEvent.self, from: envelope.payload)
                    let updates = ingestPurposeLifecycleEvent(event)
                    for update in updates where applyWeightUpdateEvent(update) {
                        appliedCount += 1
                    }
                case .explicitPreference:
                    let event = try RelationalLearningCodec.decode(RelationalExplicitPreferenceEvent.self, from: envelope.payload)
                    let update = deriveExplicitPreferenceWeightUpdate(event)
                    if applyWeightUpdateEvent(update) {
                        appliedCount += 1
                    }
                case .weightUpdate:
                    let event = try RelationalLearningCodec.decode(RelationalWeightUpdateEvent.self, from: envelope.payload)
                    if applyWeightUpdateEvent(event) {
                        appliedCount += 1
                    }
                }
            } catch {
                continue
            }
        }
        return appliedCount
    }

    // MARK: Scoring

    public func scorePurposes(contextSnapshot: RelationalContextSnapshot,
                              at timestamp: TimeInterval = Date().timeIntervalSince1970,
                              explainTopN: Int = 5) -> [RelationalPurposeScore] {
        var groupedByPurpose = [String: [RelationalEdge]]()

        for edge in edgesByKey.values where edge.fromNode.type == .purpose {
            groupedByPurpose[edge.fromNode.id, default: []].append(edge)
        }

        let activeInterestSet = Set(contextSnapshot.activeInterestRefs)
        let passiveInterestSet = Set(contextSnapshot.passiveInterestRefs)
        let activeEntitySet = Set(contextSnapshot.activeEntityRefs)
        let passiveEntitySet = Set(contextSnapshot.passiveEntityRefs)
        let activeContextMap = Dictionary(uniqueKeysWithValues: contextSnapshot.activeContextBlocks.map { ($0.node.id, $0) })

        var scored = [RelationalPurposeScore]()
        scored.reserveCapacity(groupedByPurpose.count)

        for purposeId in groupedByPurpose.keys.sorted() {
            let edges = (groupedByPurpose[purposeId] ?? []).sorted(by: sortEdgesForScoring)
            var rawScore = 0.0
            var contributions = [RelationalEdgeContributionExplain]()

            for edge in edges {
                let eligibility = eligibilityForEdge(edge,
                                                    activeInterestSet: activeInterestSet,
                                                    passiveInterestSet: passiveInterestSet,
                                                    activeEntitySet: activeEntitySet,
                                                    passiveEntitySet: passiveEntitySet,
                                                    activeContextMap: activeContextMap)
                guard eligibility > 0.0 else { continue }

                let policy = resolvePolicy(profileId: edge.decayProfileId,
                                           at: timestamp,
                                           fallbackVersion: edge.decayParamsVersion)
                let retention = RelationalDecay.retention(policy: policy,
                                                          now: timestamp,
                                                          lastReinforcedAt: edge.lastReinforcedAt)
                let effectiveWeight = RelationalMath.clamp01(edge.weightStored * retention)
                let contribution = effectiveWeight * eligibility
                rawScore += contribution

                let explain = RelationalEdgeContributionExplain(
                    edge: edge,
                    effectiveWeight: effectiveWeight,
                    contribution: contribution,
                    decayProfileId: policy.profileId,
                    decayParamsVersion: policy.version,
                    decayParams: policy.noaParameters
                )
                contributions.append(explain)
            }

            contributions.sort(by: sortContributionsForExplain)
            let topContributions = Array(contributions.prefix(max(1, explainTopN)))
            let normalized = RelationalMath.normalizedScore(from: rawScore)

            let explain = RelationalPurposeScoreExplain(
                evaluatedAt: timestamp,
                rawScore: rawScore,
                normalizedScore: normalized,
                topEdges: topContributions
            )
            scored.append(RelationalPurposeScore(purposeId: purposeId,
                                                 score: normalized,
                                                 explain: explain))
        }

        scored.sort {
            if $0.score == $1.score {
                return $0.purposeId < $1.purposeId
            }
            return $0.score > $1.score
        }
        return scored
    }

    public func edges() -> [RelationalEdge] {
        edgesByKey
            .values
            .sorted {
                if $0.fromNode.id == $1.fromNode.id {
                    if $0.relationType.rawValue == $1.relationType.rawValue {
                        return $0.toNode.id < $1.toNode.id
                    }
                    return $0.relationType.rawValue < $1.relationType.rawValue
                }
                return $0.fromNode.id < $1.fromNode.id
            }
    }

    public func policies(profileId: String? = nil) -> [RelationalDecayPolicy] {
        if let profileId {
            return (policiesByProfile[profileId] ?? []).sorted(by: sortPolicies)
        }

        return policiesByProfile
            .values
            .flatMap { $0 }
            .sorted(by: sortPolicies)
    }

    // MARK: Internals

    private func buildEligibilityTraces(from session: RelationalPurposeSession) -> [RelationalEligibilityTrace] {
        var traceMap = [String: RelationalEligibilityTrace]()

        for interestRef in session.activeInterestRefs.sorted() where !interestRef.isEmpty {
            upsertTrace(traceMap: &traceMap,
                        trace: RelationalEligibilityTrace(
                            relationType: .purposeInterest,
                            toNode: RelationalNode(type: .interest, id: interestRef),
                            eligibility: config.eligibilityActive,
                            reason: "active_interest"
                        ))
        }

        for interestRef in session.passiveInterestRefs.sorted() where !interestRef.isEmpty {
            upsertTrace(traceMap: &traceMap,
                        trace: RelationalEligibilityTrace(
                            relationType: .purposeInterest,
                            toNode: RelationalNode(type: .interest, id: interestRef),
                            eligibility: config.eligibilityPassive,
                            reason: "passive_interest"
                        ))
        }

        for entityRef in session.activeEntityRefs.sorted() where !entityRef.isEmpty {
            upsertTrace(traceMap: &traceMap,
                        trace: RelationalEligibilityTrace(
                            relationType: .purposeEntity,
                            toNode: RelationalNode(type: .entityRepresentation, id: entityRef),
                            eligibility: config.eligibilityActive,
                            reason: "active_entity"
                        ))
        }

        for entityRef in session.passiveEntityRefs.sorted() where !entityRef.isEmpty {
            upsertTrace(traceMap: &traceMap,
                        trace: RelationalEligibilityTrace(
                            relationType: .purposeEntity,
                            toNode: RelationalNode(type: .entityRepresentation, id: entityRef),
                            eligibility: config.eligibilityPassive,
                            reason: "passive_entity"
                        ))
        }

        let sortedContext = session.activeContextBlocks.values.sorted(by: { $0.node.id < $1.node.id })
        for contextSignal in sortedContext where contextSignal.confidence >= config.contextConfidenceGate {
            let scaledEligibility = config.eligibilityContextBlock * contextSignal.confidence
            upsertTrace(traceMap: &traceMap,
                        trace: RelationalEligibilityTrace(
                            relationType: .purposeContextBlock,
                            toNode: contextSignal.node,
                            eligibility: scaledEligibility,
                            reason: "active_context_block"
                        ))
        }

        return traceMap.values.map {
            RelationalEligibilityTrace(relationType: $0.relationType,
                                      toNode: $0.toNode,
                                      eligibility: RelationalMath.clamp01($0.eligibility),
                                      reason: $0.reason)
        }
    }

    private func upsertTrace(traceMap: inout [String: RelationalEligibilityTrace],
                             trace: RelationalEligibilityTrace) {
        let key = "\(trace.relationType.rawValue)|\(trace.toNode.id)"
        if let existing = traceMap[key] {
            if trace.eligibility > existing.eligibility {
                traceMap[key] = trace
            }
            return
        }
        traceMap[key] = trace
    }

    private func reinforcedWeight(previous: Double,
                                  eligibility: Double,
                                  learningRate: Double,
                                  outcome: RelationalLearningOutcome) -> Double {
        let previousClamped = RelationalMath.clamp01(previous)
        let eligibilityClamped = RelationalMath.clamp01(eligibility)
        let rate = max(0.0, learningRate)

        switch outcome {
        case .success:
            let delta = rate * eligibilityClamped * (1.0 - previousClamped)
            return RelationalMath.clamp01(previousClamped + delta)
        case .failure:
            let delta = rate * eligibilityClamped * previousClamped
            return RelationalMath.clamp01(previousClamped - delta)
        case .explicitPreference:
            return previousClamped
        }
    }

    private func eligibilityForEdge(_ edge: RelationalEdge,
                                    activeInterestSet: Set<String>,
                                    passiveInterestSet: Set<String>,
                                    activeEntitySet: Set<String>,
                                    passiveEntitySet: Set<String>,
                                    activeContextMap: [String: RelationalContextBlockSignal]) -> Double {
        switch edge.relationType {
        case .purposeInterest:
            if activeInterestSet.contains(edge.toNode.id) {
                return config.eligibilityActive
            }
            if passiveInterestSet.contains(edge.toNode.id) {
                return config.eligibilityPassive
            }
            return 0.0

        case .purposeEntity:
            if activeEntitySet.contains(edge.toNode.id) {
                return config.eligibilityActive
            }
            if passiveEntitySet.contains(edge.toNode.id) {
                return config.eligibilityPassive
            }
            return 0.0

        case .purposeContextBlock:
            guard let signal = activeContextMap[edge.toNode.id],
                  signal.confidence >= config.contextConfidenceGate else {
                return 0.0
            }
            return RelationalMath.clamp01(config.eligibilityContextBlock * signal.confidence)

        case .purposePurpose:
            return 0.0
        }
    }

    private func resolvePolicy(profileId: String,
                               at timestamp: TimeInterval,
                               fallbackVersion: Int) -> RelationalDecayPolicy {
        let candidates = (policiesByProfile[profileId] ?? []).sorted(by: sortPolicies)

        if let effective = candidates.last(where: { $0.effectiveFromTimestamp <= timestamp }) {
            return effective
        }

        if let fallback = candidates.first(where: { $0.version == fallbackVersion }) {
            return fallback
        }

        if let latest = candidates.last {
            return latest
        }

        return RelationalDecayPolicy.defaultNoa
    }

    private func sortPolicies(_ lhs: RelationalDecayPolicy, _ rhs: RelationalDecayPolicy) -> Bool {
        if lhs.profileId == rhs.profileId {
            if lhs.effectiveFromTimestamp == rhs.effectiveFromTimestamp {
                return lhs.version < rhs.version
            }
            return lhs.effectiveFromTimestamp < rhs.effectiveFromTimestamp
        }
        return lhs.profileId < rhs.profileId
    }

    private func sortEdgesForScoring(_ lhs: RelationalEdge, _ rhs: RelationalEdge) -> Bool {
        if lhs.relationType.rawValue != rhs.relationType.rawValue {
            return lhs.relationType.rawValue < rhs.relationType.rawValue
        }
        if lhs.toNode.type.rawValue != rhs.toNode.type.rawValue {
            return lhs.toNode.type.rawValue < rhs.toNode.type.rawValue
        }
        if lhs.toNode.id != rhs.toNode.id {
            return lhs.toNode.id < rhs.toNode.id
        }
        return lhs.lastReinforcedAt < rhs.lastReinforcedAt
    }

    private func sortContributionsForExplain(_ lhs: RelationalEdgeContributionExplain,
                                             _ rhs: RelationalEdgeContributionExplain) -> Bool {
        if lhs.contribution != rhs.contribution {
            return lhs.contribution > rhs.contribution
        }
        if lhs.edge.relationType.rawValue != rhs.edge.relationType.rawValue {
            return lhs.edge.relationType.rawValue < rhs.edge.relationType.rawValue
        }
        if lhs.edge.toNode.type.rawValue != rhs.edge.toNode.type.rawValue {
            return lhs.edge.toNode.type.rawValue < rhs.edge.toNode.type.rawValue
        }
        if lhs.edge.toNode.id != rhs.edge.toNode.id {
            return lhs.edge.toNode.id < rhs.edge.toNode.id
        }
        if lhs.effectiveWeight != rhs.effectiveWeight {
            return lhs.effectiveWeight > rhs.effectiveWeight
        }
        return lhs.edge.lastReinforcedAt > rhs.edge.lastReinforcedAt
    }

    private func eventIdentifier(for envelope: RelationalLearningEventEnvelope) -> String {
        guard let value = envelope.payload["eventId"] else {
            return ""
        }
        switch value {
        case .string(let string): return string
        case .integer(let integer): return String(integer)
        case .number(let number): return String(number)
        case .float(let double): return String(double)
        case .bool(let bool): return bool ? "true" : "false"
        default: return ""
        }
    }

    private func canonicalPayloadString(_ payload: Object) -> String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(payload)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
