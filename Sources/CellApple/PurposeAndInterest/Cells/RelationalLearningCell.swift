// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import CellBase
import Foundation

public final class RelationalLearningCell: GeneralCell {
    private let learningEngine: RelationalLearningEngine

    public required init(owner: Identity) async {
        self.learningEngine = RelationalLearningEngine()
        await super.init(owner: owner)

        await setupPermissions(owner: owner)
        await setupKeys(owner: owner)
    }

    private enum CodingKeys: CodingKey {
        case generalCell
    }

    public required init(from decoder: Decoder) throws {
        self.learningEngine = RelationalLearningEngine()
        try super.init(from: decoder)

        Task {
            if let vault = CellBase.defaultIdentityVault,
               let owner = await vault.identity(for: "private", makeNewIfNotFound: true) {
                await setupPermissions(owner: owner)
                await setupKeys(owner: owner)
            }
        }
    }

    private func setupPermissions(owner: Identity) async {
        agreementTemplate.addGrant("rw--", for: "purposeStarted")
        agreementTemplate.addGrant("rw--", for: "purposeSucceeded")
        agreementTemplate.addGrant("rw--", for: "purposeFailed")
        agreementTemplate.addGrant("rw--", for: "contextTransition")
        agreementTemplate.addGrant("rw--", for: "policyUpdate")
        agreementTemplate.addGrant("rw--", for: "userPreference")
        agreementTemplate.addGrant("rw--", for: "scorePurposes")
        agreementTemplate.addGrant("rw--", for: "replay")
        agreementTemplate.addGrant("r---", for: "edges")
        agreementTemplate.addGrant("r---", for: "state")
    }

    private func setupKeys(owner: Identity) async {
        await addIntercept(requester: owner, intercept: { [weak self] flowElement, _ in
            guard let self = self else { return flowElement }
            await self.ingestIncomingFlowElement(flowElement)
            return flowElement
        })

        await addInterceptForSet(requester: owner, key: "purposeStarted", setValueIntercept: { [weak self] _, value, requester in
            guard let self = self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "purposeStarted", for: requester) else { return .string("denied") }
            do {
                let event = try await self.parseLifecycleEvent(status: .started, from: value)
                return try await self.handleLifecycleEvent(event, requester: requester)
            } catch {
                return .object(["status": .string("error"), "message": .string("\(error)")])
            }
        })

        await addInterceptForSet(requester: owner, key: "purposeSucceeded", setValueIntercept: { [weak self] _, value, requester in
            guard let self = self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "purposeSucceeded", for: requester) else { return .string("denied") }
            do {
                let event = try await self.parseLifecycleEvent(status: .succeeded, from: value)
                return try await self.handleLifecycleEvent(event, requester: requester)
            } catch {
                return .object(["status": .string("error"), "message": .string("\(error)")])
            }
        })

        await addInterceptForSet(requester: owner, key: "purposeFailed", setValueIntercept: { [weak self] _, value, requester in
            guard let self = self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "purposeFailed", for: requester) else { return .string("denied") }
            do {
                let event = try await self.parseLifecycleEvent(status: .failed, from: value)
                return try await self.handleLifecycleEvent(event, requester: requester)
            } catch {
                return .object(["status": .string("error"), "message": .string("\(error)")])
            }
        })

        await addInterceptForSet(requester: owner, key: "contextTransition", setValueIntercept: { [weak self] _, value, requester in
            guard let self = self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "contextTransition", for: requester) else { return .string("denied") }
            do {
                let event = try self.parseContextTransitionEvent(from: value)
                _ = await self.learningEngine.observeContextTransitionEvent(event)
                try await self.emitEnvelope(.from(event), topic: "relational.learning.contextTransition", title: "RelationalContextTransition", requester: requester)
                return .object(["status": .string("ok"), "eventId": .string(event.eventId)])
            } catch {
                return .object(["status": .string("error"), "message": .string("\(error)")])
            }
        })

        await addInterceptForSet(requester: owner, key: "policyUpdate", setValueIntercept: { [weak self] _, value, requester in
            guard let self = self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "policyUpdate", for: requester) else { return .string("denied") }
            do {
                let event = try self.parseDecayPolicyUpdateEvent(from: value)
                let applied = await self.learningEngine.applyDecayPolicyUpdatedEvent(event)
                if applied {
                    try await self.emitEnvelope(.from(event), topic: "relational.learning.policyUpdated", title: "RelationalDecayPolicyUpdated", requester: requester)
                }
                return .object([
                    "status": .string("ok"),
                    "eventId": .string(event.eventId),
                    "applied": .bool(applied),
                    "policyVersion": .integer(event.policy.version)
                ])
            } catch {
                return .object(["status": .string("error"), "message": .string("\(error)")])
            }
        })

        await addInterceptForSet(requester: owner, key: "userPreference", setValueIntercept: { [weak self] _, value, requester in
            guard let self = self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "userPreference", for: requester) else { return .string("denied") }
            do {
                let event = try self.parseExplicitPreferenceEvent(from: value)
                let update = await self.learningEngine.deriveExplicitPreferenceWeightUpdate(event)
                try await self.emitEnvelope(.from(event), topic: "relational.learning.explicitPreference", title: "RelationalExplicitPreference", requester: requester)
                try await self.emitWeightUpdates([update], requester: requester)
                return .object([
                    "status": .string("ok"),
                    "eventId": .string(event.eventId),
                    "weightUpdateEventId": .string(update.eventId)
                ])
            } catch {
                return .object(["status": .string("error"), "message": .string("\(error)")])
            }
        })

        await addInterceptForSet(requester: owner, key: "scorePurposes", setValueIntercept: { [weak self] _, value, requester in
            guard let self = self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "scorePurposes", for: requester) else { return .string("denied") }
            do {
                let payload = self.objectValue(value) ?? Object()
                let snapshot = try await self.parseContextSnapshot(from: payload)
                let timestamp = self.doubleValue(payload["timestamp"]) ?? Date().timeIntervalSince1970
                let explainTopN = max(1, self.intValue(payload["explainTopN"]) ?? 5)
                let scores = await self.learningEngine.scorePurposes(contextSnapshot: snapshot,
                                                                     at: timestamp,
                                                                     explainTopN: explainTopN)
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
            } catch {
                return .object(["status": .string("error"), "message": .string("\(error)")])
            }
        })

        await addInterceptForSet(requester: owner, key: "replay", setValueIntercept: { [weak self] _, value, requester in
            guard let self = self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "replay", for: requester) else { return .string("denied") }
            do {
                let payload = self.objectValue(value) ?? Object()
                let resetFirst = self.boolValue(payload["resetFirst"]) ?? true
                let envelopes = try self.parseReplayEvents(from: payload["events"] ?? value)
                let applied = await self.learningEngine.replay(events: envelopes, resetFirst: resetFirst)
                return .object([
                    "status": .string("ok"),
                    "replayed": .integer(envelopes.count),
                    "applied": .integer(applied),
                    "resetFirst": .bool(resetFirst)
                ])
            } catch {
                return .object(["status": .string("error"), "message": .string("\(error)")])
            }
        })

        await addInterceptForGet(requester: owner, key: "edges", getValueIntercept: { [weak self] _, requester in
            guard let self = self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "edges", for: requester) else { return .string("denied") }

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
        })

        await addInterceptForGet(requester: owner, key: "state", getValueIntercept: { [weak self] _, requester in
            guard let self = self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "state", for: requester) else { return .string("denied") }

            let edges = await self.learningEngine.edges()
            let policies = await self.learningEngine.policies()
            let contextBlocks = await self.learningEngine.currentActiveContextBlocks()

            return .object([
                "status": .string("ok"),
                "edgeCount": .integer(edges.count),
                "policyCount": .integer(policies.count),
                "activeContextBlockCount": .integer(contextBlocks.count)
            ])
        })
    }

    private func ingestIncomingFlowElement(_ flowElement: FlowElement) async {
        if let contextEvent = RelationalContextTransitionEvent.fromFlowElement(flowElement) {
            _ = await learningEngine.observeContextTransitionEvent(contextEvent)
        }

        guard case let .object(contentObject) = flowElement.content else {
            return
        }

        guard let envelope = try? RelationalLearningCodec.decode(RelationalLearningEventEnvelope.self, from: contentObject) else {
            return
        }

        switch envelope.eventType {
        case .weightUpdate:
            if let event = try? RelationalLearningCodec.decode(RelationalWeightUpdateEvent.self, from: envelope.payload) {
                _ = await learningEngine.applyWeightUpdateEvent(event)
            }
        case .decayPolicyUpdated:
            if let event = try? RelationalLearningCodec.decode(RelationalDecayPolicyUpdatedEvent.self, from: envelope.payload) {
                _ = await learningEngine.applyDecayPolicyUpdatedEvent(event)
            }
        case .contextTransition:
            if let event = try? RelationalLearningCodec.decode(RelationalContextTransitionEvent.self, from: envelope.payload) {
                _ = await learningEngine.observeContextTransitionEvent(event)
            }
        case .explicitPreference:
            if let event = try? RelationalLearningCodec.decode(RelationalExplicitPreferenceEvent.self, from: envelope.payload) {
                let update = await learningEngine.deriveExplicitPreferenceWeightUpdate(event)
                _ = await learningEngine.applyWeightUpdateEvent(update)
            }
        case .purposeLifecycle:
            // Lifecycle events are causal. Mutating state happens via weight updates.
            break
        }
    }

    private func handleLifecycleEvent(_ event: RelationalPurposeLifecycleEvent,
                                      requester: Identity) async throws -> ValueType {
        try await emitEnvelope(.from(event),
                               topic: "relational.learning.lifecycle",
                               title: "RelationalPurposeLifecycle",
                               requester: requester)

        let updates = await learningEngine.ingestPurposeLifecycleEvent(event)
        try await emitWeightUpdates(updates, requester: requester)

        return .object([
            "status": .string("ok"),
            "eventId": .string(event.eventId),
            "statusType": .string(event.status.rawValue),
            "weightUpdates": .integer(updates.count)
        ])
    }

    private func emitWeightUpdates(_ updates: [RelationalWeightUpdateEvent],
                                   requester: Identity) async throws {
        for update in updates {
            try await emitEnvelope(.from(update),
                                   topic: "relational.learning.weightUpdate",
                                   title: "RelationalWeightUpdate",
                                   requester: requester)
            _ = await learningEngine.applyWeightUpdateEvent(update)
        }
    }

    private func emitEnvelope(_ envelopeFactory: @autoclosure () throws -> RelationalLearningEventEnvelope,
                              topic: String,
                              title: String,
                              requester: Identity) async throws {
        let envelope = try envelopeFactory()
        let payload = try RelationalLearningCodec.encodeObject(envelope)
        var flowElement = FlowElement(
            title: title,
            content: .object(payload),
            properties: FlowElement.Properties(type: .event, contentType: .object)
        )
        flowElement.topic = topic
        flowElement.origin = self.uuid
        pushFlowElement(flowElement, requester: requester)
    }

    // MARK: Parsing helpers

    private func parseLifecycleEvent(status: RelationalPurposeLifecycleStatus,
                                     from value: ValueType) async throws -> RelationalPurposeLifecycleEvent {
        let payload = objectValue(value) ?? ["purposeId": value]

        let purposeId =
            stringValue(payload["purposeId"]) ??
            stringValue(payload["purposeRef"]) ??
            stringValue(payload["reference"]) ??
            stringValue(payload["purposeName"]) ??
            ""

        guard !purposeId.isEmpty else {
            throw SetValueError.paramErr
        }

        let timestamp =
            doubleValue(payload["timestamp"]) ??
            doubleValue(payload["date"]) ??
            Date().timeIntervalSince1970

        var activeContextBlocks = parseContextBlocks(payload["activeContextBlocks"])
        if activeContextBlocks.isEmpty {
            activeContextBlocks = await learningEngine.currentActiveContextBlocks()
        }

        return RelationalPurposeLifecycleEvent(
            eventId: stringValue(payload["eventId"]) ?? UUID().uuidString,
            timestamp: timestamp,
            status: status,
            purposeId: purposeId,
            activeInterestRefs: parseReferenceList(payload["activeInterests"]),
            passiveInterestRefs: parseReferenceList(payload["passiveInterests"]),
            activeEntityRefs: parseReferenceList(payload["activeEntities"]),
            passiveEntityRefs: parseReferenceList(payload["passiveEntities"]),
            activeContextBlocks: activeContextBlocks,
            contextConfidence: doubleValue(payload["contextConfidence"]) ?? doubleValue(payload["confidence"]),
            metadata: parseMetadata(payload["metadata"])
        )
    }

    private func parseContextTransitionEvent(from value: ValueType) throws -> RelationalContextTransitionEvent {
        let payload = objectValue(value) ?? Object()

        if let envelope = try? RelationalLearningCodec.decode(RelationalLearningEventEnvelope.self, from: payload),
           envelope.eventType == .contextTransition {
            return try RelationalLearningCodec.decode(RelationalContextTransitionEvent.self, from: envelope.payload)
        }

        if let decoded = try? RelationalLearningCodec.decode(RelationalContextTransitionEvent.self, from: payload) {
            return decoded
        }

        let domain = stringValue(payload["domain"]) ?? "context"
        let toBlockId =
            stringValue(payload["toBlockId"]) ??
            stringValue(payload["to"]) ??
            stringValue(payload["symbol"]) ??
            stringValue(payload["type"]) ??
            ""
        guard !toBlockId.isEmpty else {
            throw SetValueError.paramErr
        }

        return RelationalContextTransitionEvent(
            eventId: stringValue(payload["eventId"]) ?? UUID().uuidString,
            timestamp: doubleValue(payload["timestamp"]) ?? doubleValue(payload["date"]) ?? Date().timeIntervalSince1970,
            domain: domain,
            fromBlockId: stringValue(payload["fromBlockId"]) ?? stringValue(payload["from"]),
            toBlockId: toBlockId,
            confidence: doubleValue(payload["confidence"]) ?? 1.0,
            metadata: parseMetadata(payload["metadata"])
        )
    }

    private func parseDecayPolicyUpdateEvent(from value: ValueType) throws -> RelationalDecayPolicyUpdatedEvent {
        let payload = objectValue(value) ?? Object()

        if let decoded = try? RelationalLearningCodec.decode(RelationalDecayPolicyUpdatedEvent.self, from: payload) {
            return decoded
        }

        let policyObject = objectValue(payload["policy"]) ?? payload

        let kindRaw = stringValue(policyObject["kind"]) ?? RelationalDecayProfileKind.noaDoubleSigmoid.rawValue
        let kind = RelationalDecayProfileKind(rawValue: kindRaw) ?? .noaDoubleSigmoid

        let noaParams = RelationalNoaDecayParameters(
            t1Seconds: doubleValue(policyObject["t1Seconds"]) ?? 7.0 * 24.0 * 3600.0,
            t2Seconds: doubleValue(policyObject["t2Seconds"]) ?? 30.0 * 24.0 * 3600.0,
            k1: doubleValue(policyObject["k1"]) ?? 1.2,
            k2: doubleValue(policyObject["k2"]) ?? 0.6,
            rMin: doubleValue(policyObject["rMin"]) ?? 0.05
        )

        let policy = RelationalDecayPolicy(
            profileId: stringValue(policyObject["profileId"]) ?? RelationalDecayPolicy.defaultNoa.profileId,
            version: intValue(policyObject["version"]) ?? 1,
            effectiveFromTimestamp: doubleValue(policyObject["effectiveFromTimestamp"]) ?? Date().timeIntervalSince1970,
            kind: kind,
            noaParameters: kind == .noaDoubleSigmoid ? noaParams : nil
        )

        return RelationalDecayPolicyUpdatedEvent(
            eventId: stringValue(payload["eventId"]) ?? UUID().uuidString,
            emittedAt: doubleValue(payload["emittedAt"]) ?? Date().timeIntervalSince1970,
            policy: policy
        )
    }

    private func parseExplicitPreferenceEvent(from value: ValueType) throws -> RelationalExplicitPreferenceEvent {
        let payload = objectValue(value) ?? Object()

        if let decoded = try? RelationalLearningCodec.decode(RelationalExplicitPreferenceEvent.self, from: payload) {
            return decoded
        }

        let purposeId =
            stringValue(payload["purposeId"]) ??
            stringValue(payload["purposeRef"]) ??
            stringValue(payload["reference"]) ??
            ""
        guard !purposeId.isEmpty else {
            throw SetValueError.paramErr
        }

        let targetTypeRaw = stringValue(payload["targetType"]) ?? RelationalNodeType.interest.rawValue
        let targetType = RelationalNodeType(rawValue: targetTypeRaw) ?? .interest
        let targetId =
            stringValue(payload["targetId"]) ??
            stringValue(payload["targetRef"]) ??
            stringValue(payload["reference"]) ??
            ""

        guard !targetId.isEmpty else {
            throw SetValueError.paramErr
        }

        let relationType =
            RelationalEdgeRelationType(rawValue: stringValue(payload["relationType"]) ?? "") ??
            defaultRelationType(for: targetType)

        return RelationalExplicitPreferenceEvent(
            eventId: stringValue(payload["eventId"]) ?? UUID().uuidString,
            timestamp: doubleValue(payload["timestamp"]) ?? Date().timeIntervalSince1970,
            purposeId: purposeId,
            relationType: relationType,
            targetNode: RelationalNode(type: targetType, id: targetId),
            preferenceWeight: doubleValue(payload["preferenceWeight"]) ?? RelationalLearningDefaults.explicitPreferenceWeight,
            metadata: parseMetadata(payload["metadata"])
        )
    }

    private func parseContextSnapshot(from payload: Object) async throws -> RelationalContextSnapshot {
        var contextBlocks = parseContextBlocks(payload["activeContextBlocks"])
        if contextBlocks.isEmpty {
            contextBlocks = await learningEngine.currentActiveContextBlocks()
        }

        return RelationalContextSnapshot(
            activeInterestRefs: parseReferenceList(payload["activeInterests"]),
            passiveInterestRefs: parseReferenceList(payload["passiveInterests"]),
            activeEntityRefs: parseReferenceList(payload["activeEntities"]),
            passiveEntityRefs: parseReferenceList(payload["passiveEntities"]),
            activeContextBlocks: contextBlocks
        )
    }

    private func parseReplayEvents(from value: ValueType) throws -> [RelationalLearningEventEnvelope] {
        let values: ValueTypeList
        if case let .list(list) = value {
            values = list
        } else if case let .object(object) = value, object["eventType"] != nil {
            values = [.object(object)]
        } else {
            values = []
        }

        var envelopes = [RelationalLearningEventEnvelope]()
        for item in values {
            guard let object = objectValue(item) else { continue }
            if let envelope = try? RelationalLearningCodec.decode(RelationalLearningEventEnvelope.self, from: object) {
                envelopes.append(envelope)
            }
        }
        return envelopes
    }

    private func parseContextBlocks(_ value: ValueType?) -> [RelationalContextBlockSignal] {
        guard let value, case let .list(list) = value else { return [] }

        var blocks = [RelationalContextBlockSignal]()
        for item in list {
            if let object = objectValue(item),
               let decoded = try? RelationalLearningCodec.decode(RelationalContextBlockSignal.self, from: object) {
                blocks.append(decoded)
                continue
            }

            if case let .string(blockId) = item {
                blocks.append(RelationalContextBlockSignal(domain: "context", blockId: blockId, confidence: 1.0))
                continue
            }

            if let object = objectValue(item) {
                let domain = stringValue(object["domain"]) ?? "context"
                let blockId = stringValue(object["blockId"]) ?? stringValue(object["toBlockId"]) ?? ""
                if !blockId.isEmpty {
                    let confidence = doubleValue(object["confidence"]) ?? 1.0
                    blocks.append(RelationalContextBlockSignal(domain: domain, blockId: blockId, confidence: confidence))
                }
            }
        }
        return blocks
    }

    private func parseReferenceList(_ value: ValueType?) -> [String] {
        guard let value, case let .list(list) = value else { return [] }

        var refs = [String]()
        refs.reserveCapacity(list.count)

        for item in list {
            if case let .string(string) = item {
                if !string.isEmpty { refs.append(string) }
                continue
            }

            guard let object = objectValue(item) else { continue }
            let reference =
                stringValue(object["reference"]) ??
                stringValue(object["interestRef"]) ??
                stringValue(object["entityRef"]) ??
                stringValue(object["purposeRef"]) ??
                stringValue(object["id"]) ??
                stringValue(object["name"]) ??
                ""
            if !reference.isEmpty {
                refs.append(reference)
            }
        }

        return refs
    }

    private func parseMetadata(_ value: ValueType?) -> [String: String] {
        guard let value, case let .object(object) = value else { return [:] }
        var metadata = [String: String]()
        for (key, currentValue) in object {
            if let asString = stringValue(currentValue) {
                metadata[key] = asString
            }
        }
        return metadata
    }

    private func defaultRelationType(for nodeType: RelationalNodeType) -> RelationalEdgeRelationType {
        switch nodeType {
        case .interest:
            return .purposeInterest
        case .entityRepresentation:
            return .purposeEntity
        case .contextBlock:
            return .purposeContextBlock
        case .purpose:
            return .purposePurpose
        }
    }

    private func objectValue(_ value: ValueType?) -> Object? {
        guard let value else { return nil }
        if case let .object(object) = value {
            return object
        }
        return nil
    }

    private func stringValue(_ value: ValueType?) -> String? {
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

    private func doubleValue(_ value: ValueType?) -> Double? {
        guard let value else { return nil }
        switch value {
        case .float(let double): return double
        case .integer(let integer): return Double(integer)
        case .number(let number): return Double(number)
        case .string(let string): return Double(string)
        default: return nil
        }
    }

    private func intValue(_ value: ValueType?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .integer(let integer): return integer
        case .number(let number): return number
        case .float(let double): return Int(double)
        case .string(let string): return Int(string)
        default: return nil
        }
    }

    private func boolValue(_ value: ValueType?) -> Bool? {
        guard let value else { return nil }
        switch value {
        case .bool(let bool): return bool
        case .integer(let integer): return integer != 0
        case .number(let number): return number != 0
        case .string(let string):
            let normalized = string.lowercased()
            return normalized == "true" || normalized == "1" || normalized == "yes" || normalized == "on"
        default:
            return nil
        }
    }
}
