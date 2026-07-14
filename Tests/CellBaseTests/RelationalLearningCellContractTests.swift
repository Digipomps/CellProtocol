// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@_spi(HAVENRuntime) @testable import CellBase
@testable import CellApple

final class RelationalLearningCellContractTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousExploreMode: CellBase.ExploreContractEnforcementMode = .permissive

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousExploreMode = CellBase.exploreContractEnforcementMode
        CellBase.exploreContractEnforcementMode = .strict
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.exploreContractEnforcementMode = previousExploreMode
        super.tearDown()
    }

    func testStrictContractsAndExactGrantsSurviveDecodeAndConcurrentReadiness() async throws {
        let (vault, owner) = await makeOwner()
        CellBase.defaultIdentityVault = vault
        let cell = await RelationalLearningCell(owner: owner)

        try await assertContracts(on: cell, requester: owner)
        cell.agreementTemplate.addGrant("rw--", for: "purposeStarted")
        cell.agreementTemplate.addGrant("rw--", for: "replay")
        cell.agreementTemplate.addGrant("rw--", for: "edges")

        let decoded = try JSONDecoder().decode(
            RelationalLearningCell.self,
            from: JSONEncoder().encode(cell)
        )
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    try? await decoded.ensureRuntimeReady()
                }
            }
        }

        try await assertContracts(on: decoded, requester: owner)
        let actionKeys = [
            "purposeStarted", "purposeSucceeded", "purposeFailed", "contextTransition",
            "policyUpdate", "userPreference", "scorePurposes", "replay"
        ]
        for key in actionKeys {
            XCTAssertEqual(
                decoded.agreementTemplate.grants
                    .filter { $0.keypath == key }
                    .map(\.permission.permissionString),
                ["-w--"],
                "Expected one exact action grant for \(key)"
            )
        }
        for key in ["edges", "state"] {
            XCTAssertEqual(
                decoded.agreementTemplate.grants
                    .filter { $0.keypath == key }
                    .map(\.permission.permissionString),
                ["r---"],
                "Expected one exact read grant for \(key)"
            )
        }
    }

    func testRoundTripImmediateReadScoreAndActionPreserveJournaledLearning() async throws {
        let (vault, owner) = await makeOwner()
        CellBase.defaultIdentityVault = vault
        let cell = await RelationalLearningCell(owner: owner)

        _ = try await cell.set(
            keypath: "purposeStarted",
            value: lifecyclePayload(
                eventID: "roundtrip-start",
                timestamp: 100,
                purposeID: "purpose://quality",
                activeInterest: "interest://determinism"
            ),
            requester: owner
        )
        _ = try await cell.set(
            keypath: "purposeSucceeded",
            value: lifecyclePayload(
                eventID: "roundtrip-success",
                timestamp: 110,
                purposeID: "purpose://quality",
                activeInterest: "interest://determinism"
            ),
            requester: owner
        )

        let stateBefore = try await cell.get(keypath: "state", requester: owner)
        let edgesBefore = try await cell.get(keypath: "edges", requester: owner)
        let scoreInput: ValueType = .object([
            "timestamp": .float(120),
            "activeInterestRefs": .list([.string("interest://determinism")]),
            "explainTopN": .integer(5)
        ])
        let scoreBefore = try await cell.set(
            keypath: "scorePurposes",
            value: scoreInput,
            requester: owner
        )

        let decoded = try JSONDecoder().decode(
            RelationalLearningCell.self,
            from: JSONEncoder().encode(cell)
        )
        let stateAfter = try await decoded.get(keypath: "state", requester: owner)
        let edgesAfter = try await decoded.get(keypath: "edges", requester: owner)
        let scoreAfter = try await decoded.set(
            keypath: "scorePurposes",
            value: scoreInput,
            requester: owner
        )
        CellContractHarness.assertValueTypeEqual(stateAfter, stateBefore)
        CellContractHarness.assertValueTypeEqual(edgesAfter, edgesBefore)
        CellContractHarness.assertValueTypeEqual(scoreAfter, scoreBefore)

        let immediateResult = try await decoded.set(
            keypath: "contextTransition",
            value: .object([
                "eventId": .string("decoded-first-action"),
                "timestamp": .float(130),
                "domain": .string("location"),
                "toBlockId": .string("office"),
                "confidence": .float(0.9)
            ]),
            requester: owner
        )
        XCTAssertEqual(responseBool(immediateResult, key: "applied"), true)
        let immediateState = try await decoded.get(keypath: "state", requester: owner)
        XCTAssertEqual(stateInteger(immediateState, key: "journalRecordCount"), 3)
    }

    func testMalformedReplayPolicyAndDuplicateEventAreAtomicAndNonMutating() async throws {
        let (vault, owner) = await makeOwner()
        CellBase.defaultIdentityVault = vault
        let cell = await RelationalLearningCell(owner: owner)
        let start = lifecyclePayload(
            eventID: "atomic-start",
            timestamp: 200,
            purposeID: "purpose://atomic",
            activeInterest: "interest://integrity"
        )
        _ = try await cell.set(keypath: "purposeStarted", value: start, requester: owner)
        let baselineState = try await cell.get(keypath: "state", requester: owner)
        let baselineEdges = try await cell.get(keypath: "edges", requester: owner)

        try await assertErrorResponse(
            from: cell,
            key: "replay",
            value: .bool(true),
            requester: owner
        )
        try await assertErrorResponse(
            from: cell,
            key: "policyUpdate",
            value: .object([
                "eventId": .string("invalid-policy"),
                "emittedAt": .float(201),
                "policy": .object(["kind": .string("not-a-policy")])
            ]),
            requester: owner
        )
        let mismatchedPreference = RelationalExplicitPreferenceEvent(
            eventId: "invalid-preference-shape",
            timestamp: 201.5,
            purposeId: "purpose://atomic",
            relationType: .purposeInterest,
            targetNode: RelationalNode(type: .entityRepresentation, id: "entity://wrong-shape"),
            preferenceWeight: 0.8
        )
        try await assertErrorResponse(
            from: cell,
            key: "userPreference",
            value: .object(try RelationalLearningCodec.encodeObject(mismatchedPreference)),
            requester: owner
        )

        let validContext = try RelationalLearningCodec.encodeObject(
            RelationalLearningEventEnvelope.from(
                RelationalContextTransitionEvent(
                    eventId: "valid-before-invalid",
                    timestamp: 202,
                    domain: "location",
                    toBlockId: "home",
                    confidence: 0.9
                )
            )
        )
        var invalidContext = validContext
        invalidContext["schemaVersion"] = .string("99")
        try await assertErrorResponse(
            from: cell,
            key: "replay",
            value: .object([
                "events": .list([.object(validContext), .object(invalidContext)]),
                "resetFirst": .bool(true)
            ]),
            requester: owner
        )

        let invalidWeightUpdate = RelationalWeightUpdateEvent(
            eventId: "invalid-weight-shape",
            emittedAt: 203,
            sourceEventId: nil,
            outcome: .success,
            edge: RelationalEdge(
                fromNode: RelationalNode(type: .interest, id: "interest://not-a-purpose"),
                relationType: .purposeInterest,
                toNode: RelationalNode(type: .interest, id: "interest://integrity"),
                weightStored: 0.5,
                lastReinforcedAt: 203,
                decayProfileId: "noa",
                decayParamsVersion: 1
            ),
            previousWeightStored: 0.4,
            newWeightStored: 0.5,
            learningRate: 0.1,
            eligibility: 1,
            reason: "invalid source node"
        )
        let invalidWeightEnvelope = try RelationalLearningEventEnvelope.from(invalidWeightUpdate)
        try await assertErrorResponse(
            from: cell,
            key: "replay",
            value: .object([
                "events": .list([
                    .object(try RelationalLearningCodec.encodeObject(invalidWeightEnvelope))
                ]),
                "resetFirst": .bool(true)
            ]),
            requester: owner
        )

        let duplicateResult = try await cell.set(
            keypath: "purposeStarted",
            value: start,
            requester: owner
        )
        XCTAssertEqual(responseBool(duplicateResult, key: "applied"), false)
        CellContractHarness.assertValueTypeEqual(
            try await cell.get(keypath: "state", requester: owner),
            baselineState
        )
        CellContractHarness.assertValueTypeEqual(
            try await cell.get(keypath: "edges", requester: owner),
            baselineEdges
        )
    }

    func testSuccessfulReplayResetToFewerAndEmptyEventsPersistsReplacementJournal() async throws {
        let (vault, owner) = await makeOwner()
        CellBase.defaultIdentityVault = vault
        let cell = await RelationalLearningCell(owner: owner)

        _ = try await cell.set(
            keypath: "purposeStarted",
            value: lifecyclePayload(
                eventID: "reset-old-start",
                timestamp: 250,
                purposeID: "purpose://old",
                activeInterest: "interest://old"
            ),
            requester: owner
        )
        _ = try await cell.set(
            keypath: "purposeSucceeded",
            value: lifecyclePayload(
                eventID: "reset-old-success",
                timestamp: 251,
                purposeID: "purpose://old",
                activeInterest: "interest://old"
            ),
            requester: owner
        )

        let replacement = try RelationalLearningEventEnvelope.from(
            RelationalContextTransitionEvent(
                eventId: "reset-replacement",
                timestamp: 252,
                domain: "location",
                toBlockId: "home",
                confidence: 1
            )
        )
        let replayResult = try await cell.set(
            keypath: "replay",
            value: .object([
                "events": .list([
                    .object(try RelationalLearningCodec.encodeObject(replacement))
                ]),
                "resetFirst": .bool(true)
            ]),
            requester: owner
        )
        XCTAssertEqual(stateInteger(replayResult ?? .null, key: "applied"), 1)

        let replacementState = try await cell.get(keypath: "state", requester: owner)
        XCTAssertEqual(stateInteger(replacementState, key: "journalRecordCount"), 1)
        XCTAssertEqual(stateInteger(replacementState, key: "edgeCount"), 0)
        XCTAssertEqual(stateInteger(replacementState, key: "activeContextBlockCount"), 1)
        XCTAssertEqual(try persistedJournalEventIDs(cell), ["reset-replacement"])

        let decoded = try JSONDecoder().decode(
            RelationalLearningCell.self,
            from: JSONEncoder().encode(cell)
        )
        CellContractHarness.assertValueTypeEqual(
            try await decoded.get(keypath: "state", requester: owner),
            replacementState
        )
        let decodedEdges = try await decoded.get(keypath: "edges", requester: owner)
        XCTAssertTrue(try decodeEdges(decodedEdges).isEmpty)
        XCTAssertEqual(try persistedJournalEventIDs(decoded), ["reset-replacement"])

        _ = try await decoded.set(
            keypath: "contextTransition",
            value: contextPayload(eventID: "after-reset", timestamp: 253),
            requester: owner
        )
        let afterResetState = try await decoded.get(keypath: "state", requester: owner)
        XCTAssertEqual(stateInteger(afterResetState, key: "journalRecordCount"), 2)
        XCTAssertEqual(
            try persistedJournalEventIDs(decoded),
            ["reset-replacement", "after-reset"]
        )

        let emptyReset = try await decoded.set(
            keypath: "replay",
            value: .object([
                "events": .list([]),
                "resetFirst": .bool(true)
            ]),
            requester: owner
        )
        XCTAssertEqual(stateInteger(emptyReset ?? .null, key: "applied"), 0)
        let emptyState = try await decoded.get(keypath: "state", requester: owner)
        XCTAssertEqual(stateInteger(emptyState, key: "journalRecordCount"), 0)
        XCTAssertEqual(stateInteger(emptyState, key: "edgeCount"), 0)
        XCTAssertEqual(stateInteger(emptyState, key: "activeContextBlockCount"), 0)
        XCTAssertTrue(try persistedJournalEventIDs(decoded).isEmpty)

        let emptyDecoded = try JSONDecoder().decode(
            RelationalLearningCell.self,
            from: JSONEncoder().encode(decoded)
        )
        CellContractHarness.assertValueTypeEqual(
            try await emptyDecoded.get(keypath: "state", requester: owner),
            emptyState
        )
        XCTAssertTrue(try persistedJournalEventIDs(emptyDecoded).isEmpty)
    }

    func testConcurrentReinforcementHasNoLostUpdatesAndGeneratedIDsAreDeterministic() async throws {
        let (vault, owner) = await makeOwner()
        CellBase.defaultIdentityVault = vault
        let cell = await RelationalLearningCell(owner: owner)
        let count = 32

        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< count {
                group.addTask {
                    _ = try? await cell.set(
                        keypath: "purposeSucceeded",
                        value: self.lifecyclePayload(
                            eventID: "concurrent-success-\(index)",
                            timestamp: 300 + Double(index),
                            purposeID: "purpose://concurrency",
                            activeInterest: "interest://atomicity"
                        ),
                        requester: owner
                    )
                }
            }
        }

        let concurrentEdges = try await cell.get(keypath: "edges", requester: owner)
        let edge = try XCTUnwrap(try decodeEdges(concurrentEdges).first)
        let expected = 1 - (1 - RelationalLearningDefaults.unknownWeight)
            * pow(1 - RelationalLearningDefaults.alphaSuccess, Double(count))
        XCTAssertEqual(edge.weightStored, expected, accuracy: 1e-12)
        let concurrentState = try await cell.get(keypath: "state", requester: owner)
        XCTAssertEqual(stateInteger(concurrentState, key: "journalRecordCount"), count)

        let replayed = try JSONDecoder().decode(
            RelationalLearningCell.self,
            from: JSONEncoder().encode(cell)
        )
        let restoredEdges = try await replayed.get(keypath: "edges", requester: owner)
        let restoredEdge = try XCTUnwrap(try decodeEdges(restoredEdges).first)
        XCTAssertEqual(restoredEdge.weightStored, edge.weightStored, accuracy: 1e-12)
        XCTAssertEqual(restoredEdge.metadata["sourceLifecycleEventId"], edge.metadata["sourceLifecycleEventId"])
    }

    func testConcurrentMixedActionsPublishSourceFlowsInPersistedJournalOrder() async throws {
        let (vault, owner) = await makeOwner()
        CellBase.defaultIdentityVault = vault
        let cell = await RelationalLearningCell(owner: owner)
        let recorder = RelationalFlowIDRecorder()
        let feed = try await cell.flow(requester: owner)
        let cancellable = feed.sink(
            receiveCompletion: { _ in },
            receiveValue: { element in
                guard [
                    "relational.learning.contextTransition",
                    "relational.learning.explicitPreference"
                ].contains(element.topic),
                case let .object(object) = element.content,
                let envelope = try? RelationalLearningCodec.decode(
                    RelationalLearningEventEnvelope.self,
                    from: object
                ),
                case let .string(eventID)? = envelope.payload["eventId"] else {
                    return
                }
                recorder.append(eventID)
            }
        )
        defer { cancellable.cancel() }

        let count = 32
        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< count {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        _ = try? await cell.set(
                            keypath: "contextTransition",
                            value: self.contextPayload(
                                eventID: "mixed-context-\(index)",
                                timestamp: 500 + Double(index)
                            ),
                            requester: owner
                        )
                    } else {
                        let event = RelationalExplicitPreferenceEvent(
                            eventId: "mixed-preference-\(index)",
                            timestamp: 500 + Double(index),
                            purposeId: "purpose://mixed",
                            relationType: .purposeInterest,
                            targetNode: RelationalNode(
                                type: .interest,
                                id: "interest://\(index)"
                            ),
                            preferenceWeight: 0.7
                        )
                        if let payload = try? RelationalLearningCodec.encodeObject(event) {
                            _ = try? await cell.set(
                                keypath: "userPreference",
                                value: .object(payload),
                                requester: owner
                            )
                        }
                    }
                }
            }
        }

        let observedIDs = recorder.snapshot()
        XCTAssertEqual(observedIDs.count, count)
        XCTAssertEqual(observedIDs, try persistedJournalEventIDs(cell))
        let state = try await cell.get(keypath: "state", requester: owner)
        XCTAssertEqual(stateInteger(state, key: "journalRecordCount"), count)
    }

    func testContractedActionCallerTriggersCellOwnedFlowWithoutFeedInjectionAuthority() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let ownerCandidate = await vault.identity(for: "relational-owner", makeNewIfNotFound: true)
        let memberCandidate = await vault.identity(for: "relational-member", makeNewIfNotFound: true)
        let outsiderCandidate = await vault.identity(for: "relational-outsider", makeNewIfNotFound: true)
        let wrongKeyOwnerCandidate = await vault.identity(for: "relational-wrong-key", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(ownerCandidate)
        let member = try XCTUnwrap(memberCandidate)
        let outsider = try XCTUnwrap(outsiderCandidate)
        let wrongKeyOwner = try XCTUnwrap(wrongKeyOwnerCandidate)
        let sameUUIDWrongKey = Identity(owner.uuid, displayName: "same UUID wrong key", identityVault: vault)
        sameUUIDWrongKey.publicSecureKey = wrongKeyOwner.publicSecureKey
        let cell = await RelationalLearningCell(owner: owner)

        let agreement = Agreement(owner: owner)
        agreement.addGrant("-w--", for: "purposeStarted")
        agreement.signatories.append(member)
        let agreementState = await cell.addAgreement(
            agreement,
            for: member,
            authorizedBy: owner
        )
        XCTAssertEqual(agreementState, .signed)
        let canStart = await cell.validateAccess("-w--", at: "purposeStarted", for: member)
        let canInjectFeed = await cell.validateAccess("-w--", at: "feed", for: member)
        let unauthorizedOwnedEmitter = await cell.makeCellOwnedFlowEmitterForRuntimeBinding(
            requester: member
        )
        let outsiderOwnedEmitter = await cell.makeCellOwnedFlowEmitterForRuntimeBinding(
            requester: outsider
        )
        let wrongKeyOwnedEmitter = await cell.makeCellOwnedFlowEmitterForRuntimeBinding(
            requester: sameUUIDWrongKey
        )
        XCTAssertTrue(canStart)
        XCTAssertFalse(canInjectFeed)
        XCTAssertNil(unauthorizedOwnedEmitter)
        XCTAssertNil(outsiderOwnedEmitter)
        XCTAssertNil(wrongKeyOwnedEmitter)

        let feed = try await cell.flow(requester: owner)
        let lifecycleObserved = expectation(description: "Cell-owned lifecycle flow is delivered")
        let injectedObserved = expectation(description: "Unauthorized feed injection is not delivered")
        injectedObserved.isInverted = true
        let cancellable = feed.sink(
            receiveCompletion: { _ in },
            receiveValue: { element in
                if element.topic == "relational.learning.lifecycle" {
                    lifecycleObserved.fulfill()
                }
                if element.topic == "attacker.injected" {
                    injectedObserved.fulfill()
                }
            }
        )
        defer { cancellable.cancel() }

        let response = try await cell.set(
            keypath: "purposeStarted",
            value: lifecyclePayload(
                eventID: "member-start",
                timestamp: 400,
                purposeID: "purpose://authorized-action",
                activeInterest: "interest://least-authority"
            ),
            requester: member
        )
        XCTAssertEqual(responseBool(response, key: "applied"), true)
        await fulfillment(of: [lifecycleObserved], timeout: 1)

        var injected = FlowElement(
            title: "Injected",
            content: .string("must not publish"),
            properties: FlowElement.Properties(type: .event, contentType: .string)
        )
        injected.topic = "attacker.injected"
        cell.pushFlowElement(injected, requester: member)
        await fulfillment(of: [injectedObserved], timeout: 0.2)

        for deniedRequester in [outsider, sameUUIDWrongKey] {
            try await CellContractHarness.assertSetDenied(
                on: cell,
                key: "purposeStarted",
                input: lifecyclePayload(
                    eventID: "denied-\(deniedRequester.displayName)",
                    timestamp: 401,
                    purposeID: "purpose://denied",
                    activeInterest: "interest://security"
                ),
                requester: deniedRequester
            )
        }
    }

    private func assertContracts(on cell: RelationalLearningCell, requester: Identity) async throws {
        let actionKeys = [
            "purposeStarted", "purposeSucceeded", "purposeFailed", "contextTransition",
            "policyUpdate", "userPreference", "scorePurposes", "replay"
        ]
        let expectedFlowTopics: [String: Set<String>] = [
            "purposeStarted": ["relational.learning.lifecycle"],
            "purposeSucceeded": ["relational.learning.lifecycle"],
            "purposeFailed": ["relational.learning.lifecycle"],
            "contextTransition": ["relational.learning.contextTransition"],
            "policyUpdate": ["relational.learning.policyUpdated"],
            "userPreference": [
                "relational.learning.explicitPreference",
                "relational.learning.weightUpdate"
            ],
            "scorePurposes": [],
            "replay": []
        ]
        for key in actionKeys {
            try await CellContractHarness.assertAdvertisedKey(
                on: cell,
                key: key,
                requester: requester,
                expectedMethod: .set,
                expectedInputType: "object",
                expectedReturnType: "object"
            )
            try await CellContractHarness.assertPermissions(
                on: cell,
                key: key,
                requester: requester,
                expected: ["-w--"]
            )
            let contract = try await CellContractHarness.contractObject(
                on: cell,
                key: key,
                requester: requester
            )
            let actualTopics = Set(
                ExploreContract.flowEffects(from: .object(contract)).compactMap {
                    ExploreContract.string(from: $0[ExploreContract.Field.topic])
                }
            )
            XCTAssertEqual(actualTopics, expectedFlowTopics[key] ?? [])
        }
        for key in ["edges", "state"] {
            try await CellContractHarness.assertAdvertisedKey(
                on: cell,
                key: key,
                requester: requester,
                expectedMethod: .get,
                expectedInputType: "null",
                expectedReturnType: "object"
            )
            try await CellContractHarness.assertPermissions(
                on: cell,
                key: key,
                requester: requester,
                expected: ["r---"]
            )
        }
    }

    private func lifecyclePayload(
        eventID: String,
        timestamp: Double,
        purposeID: String,
        activeInterest: String
    ) -> ValueType {
        .object([
            "eventId": .string(eventID),
            "timestamp": .float(timestamp),
            "purposeId": .string(purposeID),
            "activeInterestRefs": .list([.string(activeInterest)]),
            "contextConfidence": .float(1)
        ])
    }

    private func contextPayload(eventID: String, timestamp: Double) -> ValueType {
        .object([
            "eventId": .string(eventID),
            "timestamp": .float(timestamp),
            "domain": .string("location"),
            "toBlockId": .string("block-\(eventID)"),
            "confidence": .float(1)
        ])
    }

    private func assertErrorResponse(
        from cell: RelationalLearningCell,
        key: String,
        value: ValueType,
        requester: Identity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            let response = try await cell.set(
                keypath: key,
                value: value,
                requester: requester
            )
            guard case let .object(object)? = response else {
                XCTFail("Expected structured error response, got \(String(describing: response))", file: file, line: line)
                return
            }
            XCTAssertEqual(ExploreContract.string(from: object["status"]), "error", file: file, line: line)
        } catch SetValueError.paramErr {
            // Strict contract dispatch may reject before the handler.
        }
    }

    private func decodeEdges(_ response: ValueType) throws -> [RelationalEdge] {
        guard case let .object(object) = response,
              case let .list(values)? = object["edges"] else {
            throw SetValueError.paramErr
        }
        return try values.map { try RelationalLearningCodec.decode(RelationalEdge.self, from: $0) }
    }

    private func responseBool(_ response: ValueType?, key: String) -> Bool? {
        guard case let .object(object)? = response,
              case let .bool(value)? = object[key] else {
            return nil
        }
        return value
    }

    private func stateInteger(_ response: ValueType, key: String) -> Int? {
        guard case let .object(object) = response else { return nil }
        switch object[key] {
        case let .integer(value)?: return value
        case let .number(value)?: return value
        default: return nil
        }
    }

    private func persistedJournalEventIDs(_ cell: RelationalLearningCell) throws -> [String] {
        let data = try JSONEncoder().encode(cell)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let journal = root["persistedJournal"] as? [String: Any],
              let records = journal["records"] as? [[String: Any]] else {
            throw RelationalLearningError.invalidJournal("missing encoded journal")
        }
        return try records.map { record in
            guard let envelope = record["envelope"] as? [String: Any],
                  let payload = envelope["payload"] as? [String: Any],
                  let eventID = payload["eventId"] as? String else {
                throw RelationalLearningError.invalidJournal("missing encoded eventId")
            }
            return eventID
        }
    }

    private func makeOwner() async -> (MockIdentityVault, Identity) {
        let vault = MockIdentityVault()
        let owner = await vault.identity(for: "relational-owner", makeNewIfNotFound: true)!
        return (vault, owner)
    }
}

private final class RelationalFlowIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [String]()

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
