// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

@_spi(HAVENRuntime) import CellBase
import Foundation

private actor RelationalLearningOperationGate {
    private var isHeld = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func withExclusiveAccess<T>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }
}

public final class RelationalLearningCell: GeneralCell {
    private let learningEngine: RelationalLearningEngine
    private let operationGate = RelationalLearningOperationGate()
    private let journalLock = NSLock()
    private var persistedJournal: RelationalLearningPersistedJournal
    private var cellOwnedFlowEmitter: ((FlowElement) -> Void)?

    public required init(owner: Identity) async {
        self.learningEngine = RelationalLearningEngine()
        self.persistedJournal = .empty
        await super.init(owner: owner)
        try? await ensureRuntimeReady()
    }

    private enum CodingKeys: CodingKey {
        case persistedJournal
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let journal = try container.decodeIfPresent(
            RelationalLearningPersistedJournal.self,
            forKey: .persistedJournal
        ) ?? .empty
        try journal.validateShapeAndSize()
        self.learningEngine = RelationalLearningEngine()
        self.persistedJournal = journal
        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(journalSnapshot(), forKey: .persistedJournal)
    }

    public override func installCellRuntimeBindingsForAccess() async throws {
        let bindingOwner = storedOwnerIdentity
        try await learningEngine.restore(from: journalSnapshot())
        await setupPermissions(owner: bindingOwner)
        try await setupKeys(owner: bindingOwner)
    }

    private func setupPermissions(owner: Identity) async {
        let actionKeys = [
            "purposeStarted", "purposeSucceeded", "purposeFailed", "contextTransition",
            "policyUpdate", "userPreference", "scorePurposes", "replay"
        ]
        let readKeys = ["edges", "state"]
        agreementTemplate.grants.removeAll { grant in
            if actionKeys.contains(grant.keypath) {
                return grant.permission.permissionString != "-w--"
            }
            if readKeys.contains(grant.keypath) {
                return grant.permission.permissionString != "r---"
            }
            return false
        }
        for key in actionKeys {
            agreementTemplate.ensureGrant("-w--", for: key)
        }
        for key in readKeys {
            agreementTemplate.ensureGrant("r---", for: key)
        }
    }

    private func setupKeys(owner: Identity) async throws {
        guard let cellOwnedFlowEmitter = await makeCellOwnedFlowEmitterForRuntimeBinding(
            requester: owner
        ) else {
            throw FlowError.denied
        }
        self.cellOwnedFlowEmitter = cellOwnedFlowEmitter
        await registerContracts(requester: owner)
        await addIntercept(requester: owner, intercept: { [weak self] flowElement, _ in
            guard let self = self else { return flowElement }
            await self.ingestIncomingFlowElement(flowElement)
            return flowElement
        })

        await addInterceptForSet(requester: owner, key: "purposeStarted", setValueIntercept: { [weak self] _, value, requester in
            guard let self = self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "purposeStarted", for: requester) else { return .string("denied") }
            do {
                return try await self.operationGate.withExclusiveAccess {
                    let event = try await self.parseLifecycleEvent(status: .started, from: value)
                    return try await self.handleLifecycleEvent(event, requester: requester)
                }
            } catch {
                return .object(["status": .string("error"), "message": .string("\(error)")])
            }
        })

        await addInterceptForSet(requester: owner, key: "purposeSucceeded", setValueIntercept: { [weak self] _, value, requester in
            guard let self = self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "purposeSucceeded", for: requester) else { return .string("denied") }
            do {
                return try await self.operationGate.withExclusiveAccess {
                    let event = try await self.parseLifecycleEvent(status: .succeeded, from: value)
                    return try await self.handleLifecycleEvent(event, requester: requester)
                }
            } catch {
                return .object(["status": .string("error"), "message": .string("\(error)")])
            }
        })

        await addInterceptForSet(requester: owner, key: "purposeFailed", setValueIntercept: { [weak self] _, value, requester in
            guard let self = self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "purposeFailed", for: requester) else { return .string("denied") }
            do {
                return try await self.operationGate.withExclusiveAccess {
                    let event = try await self.parseLifecycleEvent(status: .failed, from: value)
                    return try await self.handleLifecycleEvent(event, requester: requester)
                }
            } catch {
                return .object(["status": .string("error"), "message": .string("\(error)")])
            }
        })

        await addInterceptForSet(requester: owner, key: "contextTransition", setValueIntercept: { [weak self] _, value, requester in
            guard let self = self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "contextTransition", for: requester) else { return .string("denied") }
            do {
                return try await self.operationGate.withExclusiveAccess {
                    let event = try self.parseContextTransitionEvent(from: value)
                    let envelope = try RelationalLearningEventEnvelope.from(event)
                    let result = try await self.learningEngine.applyEnvelopeTransaction(envelope)
                    await self.cacheEngineJournal()
                    if result.applied {
                        try await self.emitEnvelope(
                            envelope,
                            topic: "relational.learning.contextTransition",
                            title: "RelationalContextTransition"
                        )
                    }
                    return .object([
                        "status": .string("ok"),
                        "eventId": .string(event.eventId),
                        "applied": .bool(result.applied)
                    ])
                }
            } catch {
                return .object(["status": .string("error"), "message": .string("\(error)")])
            }
        })

        await addInterceptForSet(requester: owner, key: "policyUpdate", setValueIntercept: { [weak self] _, value, requester in
            guard let self = self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "policyUpdate", for: requester) else { return .string("denied") }
            do {
                return try await self.operationGate.withExclusiveAccess {
                    let event = try self.parseDecayPolicyUpdateEvent(from: value)
                    let envelope = try RelationalLearningEventEnvelope.from(event)
                    let result = try await self.learningEngine.applyEnvelopeTransaction(envelope)
                    await self.cacheEngineJournal()
                    if result.applied {
                        try await self.emitEnvelope(
                            envelope,
                            topic: "relational.learning.policyUpdated",
                            title: "RelationalDecayPolicyUpdated"
                        )
                    }
                    return .object([
                        "status": .string("ok"),
                        "eventId": .string(event.eventId),
                        "applied": .bool(result.applied),
                        "policyVersion": .integer(event.policy.version)
                    ])
                }
            } catch {
                return .object(["status": .string("error"), "message": .string("\(error)")])
            }
        })

        await addInterceptForSet(requester: owner, key: "userPreference", setValueIntercept: { [weak self] _, value, requester in
            guard let self = self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "userPreference", for: requester) else { return .string("denied") }
            do {
                return try await self.operationGate.withExclusiveAccess {
                    let event = try self.parseExplicitPreferenceEvent(from: value)
                    let envelope = try RelationalLearningEventEnvelope.from(event)
                    let result = try await self.learningEngine.applyEnvelopeTransaction(envelope)
                    await self.cacheEngineJournal()
                    if result.applied {
                        try await self.emitEnvelope(
                            envelope,
                            topic: "relational.learning.explicitPreference",
                            title: "RelationalExplicitPreference"
                        )
                        try await self.emitWeightUpdates(result.weightUpdates)
                    }
                    var response: Object = [
                        "status": .string("ok"),
                        "eventId": .string(event.eventId),
                        "applied": .bool(result.applied)
                    ]
                    if let update = result.weightUpdates.first {
                        response["weightUpdateEventId"] = .string(update.eventId)
                    }
                    return .object(response)
                }
            } catch {
                return .object(["status": .string("error"), "message": .string("\(error)")])
            }
        })

        await addInterceptForSet(requester: owner, key: "scorePurposes", setValueIntercept: { [weak self] _, value, requester in
            guard let self = self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "scorePurposes", for: requester) else { return .string("denied") }
            do {
                return try await self.operationGate.withExclusiveAccess {
                    let payload = try self.requiredObject(value)
                    let snapshot = try await self.parseContextSnapshot(from: payload)
                    let timestamp = try self.requiredFiniteDouble(payload["timestamp"])
                    let explainTopN = try self.optionalInteger(payload["explainTopN"]) ?? 5
                    guard (1 ... 100).contains(explainTopN) else {
                        throw SetValueError.paramErr
                    }
                    let scores = await self.learningEngine.scorePurposes(
                        contextSnapshot: snapshot,
                        at: timestamp,
                        explainTopN: explainTopN
                    )
                    var scoreList = ValueTypeList()
                    for score in scores {
                        let object = try RelationalLearningCodec.encodeObject(score)
                        scoreList.append(.object(object))
                    }
                    return .object([
                        "status": .string("ok"),
                        "count": .integer(scoreList.count),
                        "scores": .list(scoreList),
                        "evaluatedAt": .float(timestamp)
                    ])
                }
            } catch {
                return .object(["status": .string("error"), "message": .string("\(error)")])
            }
        })

        await addInterceptForSet(requester: owner, key: "replay", setValueIntercept: { [weak self] _, value, requester in
            guard let self = self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "replay", for: requester) else { return .string("denied") }
            do {
                return try await self.operationGate.withExclusiveAccess {
                    let payload = try self.requiredObject(value)
                    guard case let .bool(resetFirst)? = payload["resetFirst"] else {
                        throw SetValueError.paramErr
                    }
                    let envelopes = try self.parseReplayEvents(from: payload["events"])
                    let result = try await self.learningEngine.replayTransaction(
                        events: envelopes,
                        resetFirst: resetFirst
                    )
                    self.storeJournalSnapshot(result.journal)
                    return .object([
                        "status": .string("ok"),
                        "replayed": .integer(envelopes.count),
                        "applied": .integer(result.appliedCount),
                        "resetFirst": .bool(resetFirst)
                    ])
                }
            } catch {
                return .object(["status": .string("error"), "message": .string("\(error)")])
            }
        })

        await addInterceptForGet(requester: owner, key: "edges", getValueIntercept: { [weak self] _, requester in
            guard let self = self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "edges", for: requester) else { return .string("denied") }

            return await self.operationGate.withExclusiveAccess {
                let edges = await self.learningEngine.edges()
                do {
                    var list = ValueTypeList()
                    for edge in edges {
                        list.append(.object(try RelationalLearningCodec.encodeObject(edge)))
                    }
                    return .object([
                        "status": .string("ok"),
                        "count": .integer(list.count),
                        "edges": .list(list)
                    ])
                } catch {
                    return .object(["status": .string("error"), "message": .string("\(error)")])
                }
            }
        })

        await addInterceptForGet(requester: owner, key: "state", getValueIntercept: { [weak self] _, requester in
            guard let self = self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "state", for: requester) else { return .string("denied") }

            return await self.operationGate.withExclusiveAccess {
                let edges = await self.learningEngine.edges()
                let policies = await self.learningEngine.policies()
                let contextBlocks = await self.learningEngine.currentActiveContextBlocks()
                let journal = self.journalSnapshot()

                return .object([
                    "status": .string("ok"),
                    "edgeCount": .integer(edges.count),
                    "policyCount": .integer(policies.count),
                    "activeContextBlockCount": .integer(contextBlocks.count),
                    "journalRecordCount": .integer(journal.records.count),
                    "journalRevision": .string(String(journal.revision))
                ])
            }
        })
    }

    private func ingestIncomingFlowElement(_ flowElement: FlowElement) async {
        await operationGate.withExclusiveAccess {
            do {
                let envelope: RelationalLearningEventEnvelope
                if case let .object(contentObject) = flowElement.content,
                   let decoded = try? RelationalLearningCodec.decode(
                       RelationalLearningEventEnvelope.self,
                       from: contentObject
                   ) {
                    envelope = decoded
                } else if let contextEvent = RelationalContextTransitionEvent.fromFlowElement(flowElement) {
                    envelope = try .from(contextEvent)
                } else {
                    return
                }

                _ = try await learningEngine.applyEnvelopeTransaction(envelope)
                await cacheEngineJournal()
            } catch {
                CellBase.diagnosticLog(
                    "RelationalLearningCell ignored invalid incoming event: \(error)",
                    domain: .flow
                )
            }
        }
    }

    private func handleLifecycleEvent(_ event: RelationalPurposeLifecycleEvent,
                                      requester _: Identity) async throws -> ValueType {
        let envelope = try RelationalLearningEventEnvelope.from(event)
        let result = try await learningEngine.applyEnvelopeTransaction(envelope)
        await cacheEngineJournal()
        if result.applied {
            try await emitEnvelope(
                envelope,
                topic: "relational.learning.lifecycle",
                title: "RelationalPurposeLifecycle"
            )
            try await emitWeightUpdates(result.weightUpdates)
        }

        return .object([
            "status": .string("ok"),
            "eventId": .string(event.eventId),
            "statusType": .string(event.status.rawValue),
            "applied": .bool(result.applied),
            "weightUpdates": .integer(result.weightUpdates.count)
        ])
    }

    private func emitWeightUpdates(_ updates: [RelationalWeightUpdateEvent]) async throws {
        for update in updates {
            try await emitEnvelope(
                .from(update),
                topic: "relational.learning.weightUpdate",
                title: "RelationalWeightUpdate"
            )
        }
    }

    private func emitEnvelope(_ envelopeFactory: @autoclosure () throws -> RelationalLearningEventEnvelope,
                              topic: String,
                              title: String) async throws {
        let envelope = try envelopeFactory()
        let payload = try RelationalLearningCodec.encodeObject(envelope)
        var flowElement = FlowElement(
            title: title,
            content: .object(payload),
            properties: FlowElement.Properties(type: .event, contentType: .object)
        )
        flowElement.topic = topic
        guard let cellOwnedFlowEmitter else {
            throw FlowError.denied
        }
        cellOwnedFlowEmitter(flowElement)
    }

    private func registerContracts(requester: Identity) async {
        let eventProperties: Object = [
            "eventId": ExploreContract.schema(type: "string"),
            "timestamp": ExploreContract.schema(type: "float"),
            "purposeId": ExploreContract.schema(type: "string")
        ]
        let lifecycleInput = ExploreContract.objectSchema(
            properties: eventProperties,
            requiredKeys: ["eventId", "timestamp", "purposeId"],
            description: "Deterministic purpose lifecycle event with an explicit ID and timestamp."
        )
        let objectResponse = ExploreContract.schema(
            type: "object",
            description: "Structured status response."
        )

        await registerExploreContract(
            requester: requester,
            key: "purposeStarted",
            method: .set,
            input: lifecycleInput,
            returns: objectResponse,
            permissions: ["-w--"],
            required: false,
            flowEffects: [
                ExploreContract.flowEffect(
                    trigger: .set,
                    topic: "relational.learning.lifecycle",
                    contentType: "object"
                )
            ],
            description: .string("Applies one deterministic purpose-start event atomically.")
        )
        await registerExploreContract(
            requester: requester,
            key: "purposeSucceeded",
            method: .set,
            input: lifecycleInput,
            returns: objectResponse,
            permissions: ["-w--"],
            required: false,
            flowEffects: [
                ExploreContract.flowEffect(
                    trigger: .set,
                    topic: "relational.learning.lifecycle",
                    contentType: "object"
                )
            ],
            description: .string("Applies one deterministic purpose-success event atomically.")
        )
        await registerExploreContract(
            requester: requester,
            key: "purposeFailed",
            method: .set,
            input: lifecycleInput,
            returns: objectResponse,
            permissions: ["-w--"],
            required: false,
            flowEffects: [
                ExploreContract.flowEffect(
                    trigger: .set,
                    topic: "relational.learning.lifecycle",
                    contentType: "object"
                )
            ],
            description: .string("Applies one deterministic purpose-failure event atomically.")
        )

        await registerExploreContract(
            requester: requester,
            key: "contextTransition",
            method: .set,
            input: ExploreContract.objectSchema(
                properties: [
                    "eventId": ExploreContract.schema(type: "string"),
                    "timestamp": ExploreContract.schema(type: "float"),
                    "domain": ExploreContract.schema(type: "string"),
                    "toBlockId": ExploreContract.schema(type: "string"),
                    "confidence": ExploreContract.schema(type: "float")
                ],
                requiredKeys: ["eventId", "timestamp", "domain", "toBlockId", "confidence"]
            ),
            returns: objectResponse,
            permissions: ["-w--"],
            required: false,
            flowEffects: [
                ExploreContract.flowEffect(
                    trigger: .set,
                    topic: "relational.learning.contextTransition",
                    contentType: "object"
                )
            ],
            description: .string("Applies an explicit context transition.")
        )

        await registerExploreContract(
            requester: requester,
            key: "policyUpdate",
            method: .set,
            input: ExploreContract.objectSchema(
                properties: [
                    "eventId": ExploreContract.schema(type: "string"),
                    "emittedAt": ExploreContract.schema(type: "float"),
                    "policy": ExploreContract.schema(type: "object")
                ],
                requiredKeys: ["eventId", "emittedAt", "policy"]
            ),
            returns: objectResponse,
            permissions: ["-w--"],
            required: false,
            flowEffects: [
                ExploreContract.flowEffect(
                    trigger: .set,
                    topic: "relational.learning.policyUpdated",
                    contentType: "object"
                )
            ],
            description: .string("Applies a complete versioned decay policy without synthesized defaults.")
        )

        await registerExploreContract(
            requester: requester,
            key: "userPreference",
            method: .set,
            input: ExploreContract.objectSchema(
                properties: [
                    "eventId": ExploreContract.schema(type: "string"),
                    "timestamp": ExploreContract.schema(type: "float"),
                    "purposeId": ExploreContract.schema(type: "string"),
                    "relationType": ExploreContract.schema(type: "string"),
                    "targetNode": ExploreContract.schema(type: "object"),
                    "preferenceWeight": ExploreContract.schema(type: "float")
                ],
                requiredKeys: [
                    "eventId", "timestamp", "purposeId", "relationType",
                    "targetNode", "preferenceWeight"
                ]
            ),
            returns: objectResponse,
            permissions: ["-w--"],
            required: false,
            flowEffects: [
                ExploreContract.flowEffect(
                    trigger: .set,
                    topic: "relational.learning.explicitPreference",
                    contentType: "object"
                ),
                ExploreContract.flowEffect(
                    trigger: .set,
                    topic: "relational.learning.weightUpdate",
                    contentType: "object"
                )
            ],
            description: .string("Applies an explicit purpose relation preference atomically.")
        )

        await registerExploreContract(
            requester: requester,
            key: "scorePurposes",
            method: .set,
            input: ExploreContract.objectSchema(
                properties: [
                    "timestamp": ExploreContract.schema(type: "float"),
                    "explainTopN": ExploreContract.schema(type: "integer")
                ],
                requiredKeys: ["timestamp"]
            ),
            returns: objectResponse,
            permissions: ["-w--"],
            required: false,
            description: .string("Scores learned purposes at an explicit evaluation timestamp.")
        )

        await registerExploreContract(
            requester: requester,
            key: "replay",
            method: .set,
            input: ExploreContract.objectSchema(
                properties: [
                    "events": ExploreContract.listSchema(
                        item: ExploreContract.schema(type: "object")
                    ),
                    "resetFirst": ExploreContract.schema(type: "bool")
                ],
                requiredKeys: ["events", "resetFirst"]
            ),
            returns: objectResponse,
            permissions: ["-w--"],
            required: false,
            description: .string("Atomically validates and replays a complete event list.")
        )

        await registerExploreContract(
            requester: requester,
            key: "edges",
            method: .get,
            input: .null,
            returns: objectResponse,
            permissions: ["r---"],
            required: false,
            description: .string("Reads deterministic relational learning edges.")
        )
        await registerExploreContract(
            requester: requester,
            key: "state",
            method: .get,
            input: .null,
            returns: objectResponse,
            permissions: ["r---"],
            required: false,
            description: .string("Reads deterministic relational learning state.")
        )
    }

    // MARK: Parsing helpers

    private func parseLifecycleEvent(status: RelationalPurposeLifecycleStatus,
                                     from value: ValueType) async throws -> RelationalPurposeLifecycleEvent {
        let payload = try requiredObject(value)
        let eventID = try requiredNonEmptyString(payload["eventId"])
        let purposeID = try requiredNonEmptyString(payload["purposeId"])
        let timestamp = try requiredFiniteDouble(payload["timestamp"])

        let activeContextBlocks: [RelationalContextBlockSignal]
        if payload["activeContextBlocks"] == nil {
            activeContextBlocks = await learningEngine.currentActiveContextBlocks()
        } else {
            activeContextBlocks = try parseContextBlocks(payload["activeContextBlocks"])
        }

        return RelationalPurposeLifecycleEvent(
            eventId: eventID,
            timestamp: timestamp,
            status: status,
            purposeId: purposeID,
            activeInterestRefs: try parseReferenceList(
                payload["activeInterestRefs"] ?? payload["activeInterests"]
            ),
            passiveInterestRefs: try parseReferenceList(
                payload["passiveInterestRefs"] ?? payload["passiveInterests"]
            ),
            activeEntityRefs: try parseReferenceList(
                payload["activeEntityRefs"] ?? payload["activeEntities"]
            ),
            passiveEntityRefs: try parseReferenceList(
                payload["passiveEntityRefs"] ?? payload["passiveEntities"]
            ),
            activeContextBlocks: activeContextBlocks,
            contextConfidence: try optionalUnitInterval(
                payload["contextConfidence"] ?? payload["confidence"]
            ),
            metadata: try parseMetadata(payload["metadata"])
        )
    }

    private func parseContextTransitionEvent(from value: ValueType) throws -> RelationalContextTransitionEvent {
        let payload = try requiredObject(value)

        if payload["eventType"] != nil {
            let envelope = try RelationalLearningCodec.decode(
                RelationalLearningEventEnvelope.self,
                from: payload
            )
            guard envelope.eventType == .contextTransition else {
                throw SetValueError.paramErr
            }
            return try RelationalLearningCodec.decode(
                RelationalContextTransitionEvent.self,
                from: envelope.payload
            )
        }

        return RelationalContextTransitionEvent(
            eventId: try requiredNonEmptyString(payload["eventId"]),
            timestamp: try requiredFiniteDouble(payload["timestamp"]),
            domain: try requiredNonEmptyString(payload["domain"]),
            fromBlockId: try optionalNonEmptyString(payload["fromBlockId"]),
            toBlockId: try requiredNonEmptyString(payload["toBlockId"]),
            confidence: try requiredUnitInterval(payload["confidence"]),
            metadata: try parseMetadata(payload["metadata"])
        )
    }

    private func parseDecayPolicyUpdateEvent(from value: ValueType) throws -> RelationalDecayPolicyUpdatedEvent {
        let payload = try requiredObject(value)

        if let decoded = try? RelationalLearningCodec.decode(RelationalDecayPolicyUpdatedEvent.self, from: payload) {
            return decoded
        }

        let policyObject = try requiredObject(payload["policy"])
        let kindRaw = try requiredNonEmptyString(policyObject["kind"])
        guard let kind = RelationalDecayProfileKind(rawValue: kindRaw) else {
            throw SetValueError.paramErr
        }
        let noaParameters: RelationalNoaDecayParameters?
        if kind == .noaDoubleSigmoid {
            let rawParameters = objectValue(policyObject["noaParameters"]) ?? policyObject
            let t1 = try requiredPositiveFiniteDouble(rawParameters["t1Seconds"])
            let t2 = try requiredPositiveFiniteDouble(rawParameters["t2Seconds"])
            let k1 = try requiredPositiveFiniteDouble(rawParameters["k1"])
            let k2 = try requiredPositiveFiniteDouble(rawParameters["k2"])
            let rMin = try requiredUnitInterval(rawParameters["rMin"])
            noaParameters = RelationalNoaDecayParameters(
                t1Seconds: t1,
                t2Seconds: t2,
                k1: k1,
                k2: k2,
                rMin: rMin
            )
        } else {
            noaParameters = nil
        }

        let policy = RelationalDecayPolicy(
            profileId: try requiredNonEmptyString(policyObject["profileId"]),
            version: try requiredPositiveInteger(policyObject["version"]),
            effectiveFromTimestamp: try requiredFiniteDouble(policyObject["effectiveFromTimestamp"]),
            kind: kind,
            noaParameters: noaParameters
        )

        return RelationalDecayPolicyUpdatedEvent(
            eventId: try requiredNonEmptyString(payload["eventId"]),
            emittedAt: try requiredFiniteDouble(payload["emittedAt"]),
            policy: policy
        )
    }

    private func parseExplicitPreferenceEvent(from value: ValueType) throws -> RelationalExplicitPreferenceEvent {
        let payload = try requiredObject(value)

        if let decoded = try? RelationalLearningCodec.decode(RelationalExplicitPreferenceEvent.self, from: payload) {
            return decoded
        }

        let targetTypeRaw = try requiredNonEmptyString(payload["targetType"])
        let relationTypeRaw = try requiredNonEmptyString(payload["relationType"])
        guard let targetType = RelationalNodeType(rawValue: targetTypeRaw),
              let relationType = RelationalEdgeRelationType(rawValue: relationTypeRaw) else {
            throw SetValueError.paramErr
        }

        return RelationalExplicitPreferenceEvent(
            eventId: try requiredNonEmptyString(payload["eventId"]),
            timestamp: try requiredFiniteDouble(payload["timestamp"]),
            purposeId: try requiredNonEmptyString(payload["purposeId"]),
            relationType: relationType,
            targetNode: RelationalNode(
                type: targetType,
                id: try requiredNonEmptyString(payload["targetId"])
            ),
            preferenceWeight: try requiredUnitInterval(payload["preferenceWeight"]),
            metadata: try parseMetadata(payload["metadata"])
        )
    }

    private func parseContextSnapshot(from payload: Object) async throws -> RelationalContextSnapshot {
        let contextBlocks = payload["activeContextBlocks"] == nil
            ? await learningEngine.currentActiveContextBlocks()
            : try parseContextBlocks(payload["activeContextBlocks"])

        return RelationalContextSnapshot(
            activeInterestRefs: try parseReferenceList(
                payload["activeInterestRefs"] ?? payload["activeInterests"]
            ),
            passiveInterestRefs: try parseReferenceList(
                payload["passiveInterestRefs"] ?? payload["passiveInterests"]
            ),
            activeEntityRefs: try parseReferenceList(
                payload["activeEntityRefs"] ?? payload["activeEntities"]
            ),
            passiveEntityRefs: try parseReferenceList(
                payload["passiveEntityRefs"] ?? payload["passiveEntities"]
            ),
            activeContextBlocks: contextBlocks
        )
    }

    private func parseReplayEvents(from value: ValueType?) throws -> [RelationalLearningEventEnvelope] {
        guard case let .list(values)? = value else {
            throw SetValueError.paramErr
        }

        var envelopes = [RelationalLearningEventEnvelope]()
        envelopes.reserveCapacity(values.count)
        for item in values {
            let object = try requiredObject(item)
            envelopes.append(
                try RelationalLearningCodec.decode(RelationalLearningEventEnvelope.self, from: object)
            )
        }
        return envelopes
    }

    private func parseContextBlocks(_ value: ValueType?) throws -> [RelationalContextBlockSignal] {
        guard let value else { return [] }
        guard case let .list(list) = value else {
            throw SetValueError.paramErr
        }

        var blocks = [RelationalContextBlockSignal]()
        blocks.reserveCapacity(list.count)
        for item in list {
            let object = try requiredObject(item)
            let domain = try requiredNonEmptyString(object["domain"])
            let blockID = try requiredNonEmptyString(object["blockId"])
            let confidence = try requiredUnitInterval(object["confidence"])
            blocks.append(
                RelationalContextBlockSignal(
                    domain: domain,
                    blockId: blockID,
                    confidence: confidence,
                    metadata: try parseMetadata(object["metadata"])
                )
            )
        }
        return blocks
    }

    private func parseReferenceList(_ value: ValueType?) throws -> [String] {
        guard let value else { return [] }
        guard case let .list(list) = value else {
            throw SetValueError.paramErr
        }

        var refs = [String]()
        refs.reserveCapacity(list.count)

        for item in list {
            refs.append(try requiredNonEmptyString(item))
        }

        return refs
    }

    private func parseMetadata(_ value: ValueType?) throws -> [String: String] {
        guard let value else { return [:] }
        guard case let .object(object) = value else {
            throw SetValueError.paramErr
        }
        var metadata = [String: String]()
        for (key, currentValue) in object {
            metadata[key] = try requiredNonEmptyString(currentValue)
        }
        return metadata
    }

    private func requiredObject(_ value: ValueType?) throws -> Object {
        guard case let .object(object)? = value else {
            throw SetValueError.paramErr
        }
        return object
    }

    private func objectValue(_ value: ValueType?) -> Object? {
        guard let value else { return nil }
        if case let .object(object) = value {
            return object
        }
        return nil
    }

    private func requiredNonEmptyString(_ value: ValueType?) throws -> String {
        guard case let .string(string)? = value,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SetValueError.paramErr
        }
        return string
    }

    private func optionalNonEmptyString(_ value: ValueType?) throws -> String? {
        guard value != nil else { return nil }
        return try requiredNonEmptyString(value)
    }

    private func numericDouble(_ value: ValueType?) -> Double? {
        switch value {
        case let .float(double)?:
            return double
        case let .integer(integer)?:
            return Double(integer)
        case let .number(number)?:
            return Double(number)
        default: return nil
        }
    }

    private func requiredFiniteDouble(_ value: ValueType?) throws -> Double {
        guard let result = numericDouble(value), result.isFinite else {
            throw SetValueError.paramErr
        }
        return result
    }

    private func requiredPositiveFiniteDouble(_ value: ValueType?) throws -> Double {
        let result = try requiredFiniteDouble(value)
        guard result > 0 else {
            throw SetValueError.paramErr
        }
        return result
    }

    private func requiredUnitInterval(_ value: ValueType?) throws -> Double {
        let result = try requiredFiniteDouble(value)
        guard (0 ... 1).contains(result) else {
            throw SetValueError.paramErr
        }
        return result
    }

    private func optionalUnitInterval(_ value: ValueType?) throws -> Double? {
        guard value != nil else { return nil }
        return try requiredUnitInterval(value)
    }

    private func optionalInteger(_ value: ValueType?) throws -> Int? {
        guard let value else { return nil }
        switch value {
        case let .integer(integer):
            return integer
        case let .number(number):
            return number
        default:
            throw SetValueError.paramErr
        }
    }

    private func requiredPositiveInteger(_ value: ValueType?) throws -> Int {
        guard let integer = try optionalInteger(value), integer > 0 else {
            throw SetValueError.paramErr
        }
        return integer
    }

    private func journalSnapshot() -> RelationalLearningPersistedJournal {
        journalLock.lock()
        defer { journalLock.unlock() }
        return persistedJournal
    }

    private func storeJournalSnapshot(_ journal: RelationalLearningPersistedJournal) {
        journalLock.lock()
        defer { journalLock.unlock() }
        persistedJournal = journal
    }

    private func cacheEngineJournal() async {
        let journal = await learningEngine.journalSnapshot()
        storeJournalSnapshot(journal)
    }
}
