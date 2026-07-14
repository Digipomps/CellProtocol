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
    private var appliedSourceEventKeys: Set<String>
    private var persistedJournal: RelationalLearningPersistedJournal

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
        self.appliedSourceEventKeys = []
        self.persistedJournal = .empty
    }

    public func journalSnapshot() -> RelationalLearningPersistedJournal {
        persistedJournal
    }

    public func restore(from journal: RelationalLearningPersistedJournal) throws {
        try journal.validateShapeAndSize()
        for record in journal.records {
            try Self.validateEnvelope(record.envelope)
        }

        reset(keepPolicies: false)
        for record in journal.records {
            let result = try applyEnvelopeTransaction(record.envelope)
            guard result.applied, result.sequence == record.sequence else {
                throw RelationalLearningError.invalidJournal(
                    "record \(record.sequence) did not restore exactly once"
                )
            }
        }
        guard persistedJournal.revision == journal.revision else {
            throw RelationalLearningError.invalidJournal("restored revision mismatch")
        }
    }

    public func applyEnvelopeTransaction(
        _ envelope: RelationalLearningEventEnvelope
    ) throws -> RelationalLearningTransactionResult {
        try Self.validateEnvelope(envelope)
        let eventID = try Self.validatedEventIdentifier(for: envelope)
        let sourceKey = "\(envelope.eventType.rawValue)|\(eventID)"
        guard !appliedSourceEventKeys.contains(sourceKey) else {
            return RelationalLearningTransactionResult(applied: false, sequence: nil)
        }

        try ensureJournalCapacity(adding: [envelope], resetFirst: false)

        let weightUpdates: [RelationalWeightUpdateEvent]
        let applied: Bool
        switch envelope.eventType {
        case .purposeLifecycle:
            let event = try RelationalLearningCodec.decode(
                RelationalPurposeLifecycleEvent.self,
                from: envelope.payload
            )
            weightUpdates = ingestPurposeLifecycleEvent(event)
            for update in weightUpdates {
                _ = applyWeightUpdateEvent(update)
            }
            applied = true
        case .weightUpdate:
            let event = try RelationalLearningCodec.decode(
                RelationalWeightUpdateEvent.self,
                from: envelope.payload
            )
            weightUpdates = []
            applied = applyWeightUpdateEvent(event)
        case .decayPolicyUpdated:
            let event = try RelationalLearningCodec.decode(
                RelationalDecayPolicyUpdatedEvent.self,
                from: envelope.payload
            )
            weightUpdates = []
            applied = applyDecayPolicyUpdatedEvent(event)
        case .contextTransition:
            let event = try RelationalLearningCodec.decode(
                RelationalContextTransitionEvent.self,
                from: envelope.payload
            )
            _ = observeContextTransitionEvent(event)
            weightUpdates = []
            applied = true
        case .explicitPreference:
            let event = try RelationalLearningCodec.decode(
                RelationalExplicitPreferenceEvent.self,
                from: envelope.payload
            )
            let update = deriveExplicitPreferenceWeightUpdate(event)
            weightUpdates = [update]
            applied = applyWeightUpdateEvent(update)
        }

        guard applied else {
            return RelationalLearningTransactionResult(applied: false, sequence: nil)
        }

        appliedSourceEventKeys.insert(sourceKey)
        let sequence = persistedJournal.revision + 1
        persistedJournal.records.append(
            RelationalLearningJournalRecord(sequence: sequence, envelope: envelope)
        )
        persistedJournal.revision = sequence
        return RelationalLearningTransactionResult(
            applied: true,
            sequence: sequence,
            weightUpdates: weightUpdates
        )
    }

    public func replayTransaction(
        events: [RelationalLearningEventEnvelope],
        resetFirst: Bool
    ) throws -> RelationalLearningReplayResult {
        for envelope in events {
            try Self.validateEnvelope(envelope)
        }
        let sorted = sortedReplayEvents(events)
        try ensureJournalCapacity(adding: sorted, resetFirst: resetFirst)

        if resetFirst {
            reset(keepPolicies: false)
        }

        var appliedCount = 0
        for envelope in sorted {
            if try applyEnvelopeTransaction(envelope).applied {
                appliedCount += 1
            }
        }
        return RelationalLearningReplayResult(
            appliedCount: appliedCount,
            journal: persistedJournal
        )
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
                    eventId: deterministicWeightUpdateEventID(
                        sourceEventID: event.eventId,
                        outcome: outcome,
                        edge: edge
                    ),
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
            eventId: deterministicWeightUpdateEventID(
                sourceEventID: event.eventId,
                outcome: .explicitPreference,
                edge: edge
            ),
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
        appliedSourceEventKeys = []
        persistedJournal = .empty

        if keepPolicies {
            // keep existing policies
        } else {
            policiesByProfile = [RelationalDecayPolicy.defaultNoa.profileId: [RelationalDecayPolicy.defaultNoa]]
        }
    }

    @discardableResult
    public func replay(events: [RelationalLearningEventEnvelope], resetFirst: Bool = true) -> Int {
        (try? replayTransaction(events: events, resetFirst: resetFirst).appliedCount) ?? 0
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

    private func deterministicWeightUpdateEventID(
        sourceEventID: String,
        outcome: RelationalLearningOutcome,
        edge: RelationalEdge
    ) -> String {
        let identity: Object = [
            "schema": .string("relational-weight-event-id-v1"),
            "sourceEventId": .string(sourceEventID),
            "outcome": .string(outcome.rawValue),
            "fromNodeType": .string(edge.fromNode.type.rawValue),
            "fromNodeId": .string(edge.fromNode.id),
            "relationType": .string(edge.relationType.rawValue),
            "toNodeType": .string(edge.toNode.type.rawValue),
            "toNodeId": .string(edge.toNode.id)
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(identity)) ?? Data()
        return "relational-weight-v1-\(FlowHasher.sha256Hex(data))"
    }

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

    private func ensureJournalCapacity(
        adding envelopes: [RelationalLearningEventEnvelope],
        resetFirst: Bool
    ) throws {
        var candidate = resetFirst ? RelationalLearningPersistedJournal.empty : persistedJournal
        for envelope in envelopes {
            let sequence = candidate.revision + 1
            candidate.records.append(
                RelationalLearningJournalRecord(sequence: sequence, envelope: envelope)
            )
            candidate.revision = sequence
        }
        try candidate.validateShapeAndSize()
    }

    private func sortedReplayEvents(
        _ events: [RelationalLearningEventEnvelope]
    ) -> [RelationalLearningEventEnvelope] {
        events.sorted {
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
    }

    private static func validateEnvelope(_ envelope: RelationalLearningEventEnvelope) throws {
        guard envelope.schemaVersion == "1.0" else {
            throw RelationalLearningError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        guard envelope.emittedAt.isFinite else {
            throw RelationalLearningError.invalidEvent("envelope timestamp must be finite")
        }
        _ = try validatedEventIdentifier(for: envelope)

        switch envelope.eventType {
        case .purposeLifecycle:
            let event = try RelationalLearningCodec.decode(
                RelationalPurposeLifecycleEvent.self,
                from: envelope.payload
            )
            guard event.timestamp.isFinite,
                  event.timestamp == envelope.emittedAt,
                  !event.purposeId.isEmpty else {
                throw RelationalLearningError.invalidEvent("invalid lifecycle timestamp or purposeId")
            }
            try validateUnitInterval(event.contextConfidence, field: "contextConfidence")
            guard (event.activeInterestRefs + event.passiveInterestRefs
                   + event.activeEntityRefs + event.passiveEntityRefs).allSatisfy({ !$0.isEmpty }) else {
                throw RelationalLearningError.invalidEvent("lifecycle references must not be empty")
            }
            for block in event.activeContextBlocks {
                guard !block.domain.isEmpty, !block.blockId.isEmpty else {
                    throw RelationalLearningError.invalidEvent("context block identity must not be empty")
                }
                try validateUnitInterval(block.confidence, field: "context block confidence")
            }
        case .weightUpdate:
            let event = try RelationalLearningCodec.decode(
                RelationalWeightUpdateEvent.self,
                from: envelope.payload
            )
            guard event.emittedAt.isFinite,
                  event.emittedAt == envelope.emittedAt,
                  !event.edge.fromNode.id.isEmpty,
                  !event.edge.toNode.id.isEmpty,
                  event.edge.lastReinforcedAt.isFinite,
                  event.learningRate.isFinite,
                  event.learningRate >= 0 else {
                throw RelationalLearningError.invalidEvent("invalid weight update")
            }
            try validateEdgeShape(
                relationType: event.edge.relationType,
                fromNode: event.edge.fromNode,
                toNode: event.edge.toNode
            )
            try validateUnitInterval(event.edge.weightStored, field: "edge.weightStored")
            try validateUnitInterval(event.previousWeightStored, field: "previousWeightStored")
            try validateUnitInterval(event.newWeightStored, field: "newWeightStored")
            try validateUnitInterval(event.eligibility, field: "eligibility")
        case .decayPolicyUpdated:
            let event = try RelationalLearningCodec.decode(
                RelationalDecayPolicyUpdatedEvent.self,
                from: envelope.payload
            )
            guard event.emittedAt.isFinite,
                  event.emittedAt == envelope.emittedAt,
                  !event.policy.profileId.isEmpty,
                  event.policy.version > 0,
                  event.policy.effectiveFromTimestamp.isFinite else {
                throw RelationalLearningError.invalidEvent("invalid decay policy")
            }
            if event.policy.kind == .noaDoubleSigmoid {
                guard let parameters = event.policy.noaParameters,
                      parameters.t1Seconds.isFinite,
                      parameters.t1Seconds > 0,
                      parameters.t2Seconds.isFinite,
                      parameters.t2Seconds > 0,
                      parameters.k1.isFinite,
                      parameters.k1 > 0,
                      parameters.k2.isFinite,
                      parameters.k2 > 0 else {
                    throw RelationalLearningError.invalidEvent("invalid Noa decay parameters")
                }
                try validateUnitInterval(parameters.rMin, field: "rMin")
            }
        case .contextTransition:
            let event = try RelationalLearningCodec.decode(
                RelationalContextTransitionEvent.self,
                from: envelope.payload
            )
            guard event.timestamp.isFinite,
                  event.timestamp == envelope.emittedAt,
                  !event.domain.isEmpty,
                  !event.toBlockId.isEmpty else {
                throw RelationalLearningError.invalidEvent("invalid context transition")
            }
            try validateUnitInterval(event.confidence, field: "confidence")
        case .explicitPreference:
            let event = try RelationalLearningCodec.decode(
                RelationalExplicitPreferenceEvent.self,
                from: envelope.payload
            )
            guard event.timestamp.isFinite,
                  event.timestamp == envelope.emittedAt,
                  !event.purposeId.isEmpty,
                  !event.targetNode.id.isEmpty else {
                throw RelationalLearningError.invalidEvent("invalid explicit preference")
            }
            try validateEdgeShape(
                relationType: event.relationType,
                fromNode: RelationalNode(type: .purpose, id: event.purposeId),
                toNode: event.targetNode
            )
            try validateUnitInterval(event.preferenceWeight, field: "preferenceWeight")
        }
    }

    private static func validateEdgeShape(
        relationType: RelationalEdgeRelationType,
        fromNode: RelationalNode,
        toNode: RelationalNode
    ) throws {
        guard fromNode.type == .purpose else {
            throw RelationalLearningError.invalidEvent(
                "relational edges must originate at a purpose node"
            )
        }

        let expectedTargetType: RelationalNodeType
        switch relationType {
        case .purposeInterest:
            expectedTargetType = .interest
        case .purposeEntity:
            expectedTargetType = .entityRepresentation
        case .purposeContextBlock:
            expectedTargetType = .contextBlock
        case .purposePurpose:
            expectedTargetType = .purpose
        }
        guard toNode.type == expectedTargetType else {
            throw RelationalLearningError.invalidEvent(
                "relation \(relationType.rawValue) requires target node type \(expectedTargetType.rawValue)"
            )
        }
    }

    private static func validatedEventIdentifier(
        for envelope: RelationalLearningEventEnvelope
    ) throws -> String {
        guard case let .string(eventID)? = envelope.payload["eventId"],
              !eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RelationalLearningError.invalidEvent("eventId must be a non-empty string")
        }
        return eventID
    }

    private static func validateUnitInterval(_ value: Double?, field: String) throws {
        guard let value else { return }
        guard value.isFinite, (0.0 ... 1.0).contains(value) else {
            throw RelationalLearningError.invalidEvent("\(field) must be finite and within 0...1")
        }
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
