import XCTest
@testable import CellBase

final class EntityRelationAdmissionSecurityTests: XCTestCase {
    func testOrdinaryChronicleAppendsPreserveLegacyPayloadsAndReservedEvents() throws {
        let event = EntityRelationInteractionEvent(id: "one", relationID: "synthetic", kind: .messageSent,
            at: Date(timeIntervalSince1970: 1), sourceCell: "test")
        let path = EntityRelationRecordV1.chronicleKeypath(relationID: event.relationID, eventID: event.id)
        var storage: Object = [:]
        try storage.set(keypath: path, setValue: EntityRelationCodec.value(event))
        let first: ValueType = .object(["id": .string("conference-registration-one"), "kind": .string("participant_registration_bound")])
        let second: ValueType = .object(["type": .string("contact.endpoint.published")])
        let envelope = EntityBatchPersistEnvelope(schema: "conference.participant.registration.updated.v1", mutations: [
            .init(keypath: "person.conference.registration", value: .object(["participantId": .string("synthetic")])),
            .init(keypath: "chronicle[+]", value: first),
            .init(keypath: "chronicle[+]", value: second)
        ])
        try EntityRelationRecordV1.validatePersistenceEnvelope(envelope)
        for mutation in envelope.mutations {
            try EntityRelationRecordV1.rejectDirectMutation(to: mutation.keypath, value: mutation.value)
            try storage.set(keypath: mutation.keypath, setValue: mutation.value)
        }
        XCTAssertTrue(ExploreContractValidator.deepEqual(try storage.get(keypath: path), EntityRelationCodec.value(event)))
        XCTAssertTrue(ExploreContractValidator.deepEqual(try storage.get(keypath: "chronicle"), .list([EntityRelationCodec.value(event), first, second])))
        XCTAssertNoThrow(try EntityRelationRecordV1.rejectDirectMutation(to: ".chronicle[+]", value: first))
    }

    func testOrdinaryChronicleAddressesCannotSmuggleReservedOrMismatchedIDs() throws {
        let event = EntityRelationInteractionEvent(id: "one", relationID: "synthetic", kind: .messageSent,
            at: Date(timeIntervalSince1970: 1), sourceCell: "test")
        for path in ["chronicle[+]", ".chronicle[+]", "chronicle[id=ordinary]", ".chronicle[id=ordinary]"] {
            for value in [EntityRelationCodec.value(event),
                          .object(["id": .string("relation-event-synthetic-one")]),
                          .object(["id": .string("ordinary"), "schema": .string("haven.relation-interaction-event.v1")]),
                          .object(["schema": .string("haven.relation-interaction-event.v2")]),
                          .object(["id": .integer(1)]), .list([])] as [ValueType] {
                XCTAssertThrowsError(try EntityRelationRecordV1.rejectDirectMutation(to: path, value: value), path)
                for schema in ["legacy", EntityRelationRecordV1.envelopeSchema] {
                    XCTAssertThrowsError(try EntityRelationRecordV1.validatePersistenceEnvelope(.init(schema: schema, mutations: [.init(keypath: path, value: value)])), path)
                }
            }
        }
        let mismatched: ValueType = .object(["id": .string("someone-else")])
        XCTAssertThrowsError(try EntityRelationRecordV1.rejectDirectMutation(to: "chronicle[id=ordinary]", value: mismatched))
        let matching: ValueType = .object(["id": .string("ordinary"), "kind": .string("owner-note")])
        XCTAssertNoThrow(try EntityRelationRecordV1.rejectDirectMutation(to: "chronicle[id=ordinary]", value: matching))
        XCTAssertNoThrow(try EntityRelationRecordV1.rejectDirectMutation(to: "chronicle[id=ordinary]", value: .null))
        XCTAssertThrowsError(try EntityRelationRecordV1.rejectDirectMutation(to: "chronicle[+]", value: .null))
    }

    func testV2GoldenWireAndLegacyV1ReadCompatibility() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/EntityRelationEventV2.json")
        let data = try Data(contentsOf: url)
        let event = try EntityRelationCodec.decoder().decode(EntityRelationInteractionEvent.self, from: data)
        XCTAssertEqual(event.id, "y")
        XCTAssertEqual(event.relationID, "x")
        let value = try EntityRelationCodec.decoder().decode(ValueType.self, from: data)
        XCTAssertTrue(ExploreContractValidator.deepEqual(EntityRelationCodec.value(event), value))
        guard case var .object(legacy) = value else { return XCTFail("fixture") }
        legacy["id"] = .string("y")
        legacy.removeValue(forKey: "eventID")
        legacy["schema"] = .string("haven.relation-interaction-event.v1")
        let decodedLegacy = try XCTUnwrap(EntityRelationCodec.decode(EntityRelationInteractionEvent.self, from: .object(legacy)))
        XCTAssertEqual(decodedLegacy.id, "y")
        XCTAssertTrue(ExploreContractValidator.deepEqual(EntityRelationCodec.value(decodedLegacy), .object(legacy)))
        XCTAssertThrowsError(try EntityRelationRecordV1.validate(decodedLegacy))
    }

    func testProtectedAncestorsSelectorsAndNestedDeletesCannotBypassAdmission() throws {
        for path in [".relations", "relations[id=x]", "relations", "relations.records", "relations.records[id=x]", "relations.records.x.subject", "chronicle", ".chronicle[id=relation-event-x-y]", "chronicle[0]", "chronicle[+]", "chronicle[kind=message.sent]", "chronicle[id=relation-event-x-y]"] {
            XCTAssertThrowsError(try EntityRelationRecordV1.rejectDirectMutation(to: path), path)
            let envelope = EntityBatchPersistEnvelope(schema: "legacy", mutations: [.init(keypath: path, value: .null)])
            XCTAssertThrowsError(try EntityRelationRecordV1.validatePersistenceEnvelope(envelope), path)
        }
        for path in ["relations.records.x.subject", "relations.records.x.", "relations.records[id=x]"] {
            let envelope = EntityBatchPersistEnvelope(schema: EntityRelationRecordV1.envelopeSchema, mutations: [.init(keypath: path, value: .null)])
            XCTAssertThrowsError(try EntityRelationRecordV1.validatePersistenceEnvelope(envelope), path)
        }
        XCTAssertNoThrow(try EntityRelationRecordV1.validatePersistenceEnvelope(.init(schema: EntityRelationRecordV1.envelopeSchema, mutations: [.init(keypath: "relations.records.x", value: .null)])))
        XCTAssertNoThrow(try EntityRelationRecordV1.rejectDirectMutation(to: "relations.entities.x"))
    }

    func testUnknownNestedFieldsAreRejectedInsteadOfPersistedAfterLenientDecode() throws {
        let record = EntityRelationRecord(relationID: "x", subject: .init(displayName: "Synthetic"), origin: .init(kind: .manual, at: Date(timeIntervalSince1970: 1), sourceLabel: "test"), createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
        guard case var .object(value) = EntityRelationCodec.value(record), case var .object(subject) = value["subject"] else { return XCTFail("fixture") }
        subject["email"] = .string("synthetic@example.invalid")
        value["subject"] = .object(subject)
        XCTAssertThrowsError(try EntityRelationRecordV1.validatePersistenceEnvelope(.init(schema: EntityRelationRecordV1.envelopeSchema, mutations: [.init(keypath: "relations.records.x", value: .object(value))])))
    }

    func testOffNeverStoresAnEventAndBlockedStandingCannotBeClearedByAnEvent() throws {
        let event = EntityRelationInteractionEvent(id: "y", relationID: "x", kind: .inviteJoined, at: Date(timeIntervalSince1970: 1), contentMode: .off, sourceCell: "test")
        XCTAssertThrowsError(try EntityRelationRecordV1.validate(event))
        var record = EntityRelationRecord(relationID: "x", subject: .init(displayName: "Synthetic"), origin: .init(kind: .manual, at: event.at, sourceLabel: "test"), createdAt: event.at, updatedAt: event.at)
        record.standing.trust = .blocked
        XCTAssertEqual(record.applying(event, chronicleRef: nil).standing.trust, .blocked)
    }

    func testFullEventNeedsAnExistingExplicitPolicyAndCannotAuthorizeItself() throws {
        let event = EntityRelationInteractionEvent(id: "y", relationID: "x", kind: .messageSent, at: Date(timeIntervalSince1970: 1), contentMode: .full, summary: "Synthetic content", sourceCell: "test")
        let envelope = EntityBatchPersistEnvelope(schema: EntityRelationRecordV1.envelopeSchema, mutations: [.init(keypath: EntityRelationRecordV1.chronicleKeypath(relationID: "x", eventID: "y"), value: EntityRelationCodec.value(event))])
        XCTAssertThrowsError(try EntityRelationRecordV1.validatePersistenceEnvelope(envelope))
        XCTAssertThrowsError(try EntityRelationRecordV1.validatePersistenceEnvelope(envelope, interactionPolicy: .off))
        XCTAssertNoThrow(try EntityRelationRecordV1.validatePersistenceEnvelope(envelope, interactionPolicy: .full))
        XCTAssertEqual(EntityRelationRecordV1.interactionPolicy(from: nil), .metadata)
        XCTAssertEqual(EntityRelationRecordV1.interactionPolicy(from: .null), .off)
        XCTAssertEqual(EntityRelationRecordV1.interactionPolicy(from: .string("invalid")), .off)
    }

    func testLegacyChronicleAddressCollisionDoesNotAllowReplacement() throws {
        XCTAssertEqual(EntityRelationRecordV1.chronicleID(relationID: "a-b", eventID: "c"), EntityRelationRecordV1.chronicleID(relationID: "a", eventID: "b-c"))
        let first = EntityRelationInteractionEvent(id: "c", relationID: "a-b", kind: .messageSent, at: Date(timeIntervalSince1970: 1), sourceCell: "test")
        let second = EntityRelationInteractionEvent(id: "b-c", relationID: "a", kind: .messageSent, at: first.at, sourceCell: "test")
        XCTAssertNoThrow(try EntityRelationRecordV1.validateExistingEvent(nil, proposed: EntityRelationCodec.value(first)))
        XCTAssertNoThrow(try EntityRelationRecordV1.validateExistingEvent(EntityRelationCodec.value(first), proposed: EntityRelationCodec.value(first)))
        XCTAssertThrowsError(try EntityRelationRecordV1.validateExistingEvent(EntityRelationCodec.value(first), proposed: EntityRelationCodec.value(second)))
    }
}
