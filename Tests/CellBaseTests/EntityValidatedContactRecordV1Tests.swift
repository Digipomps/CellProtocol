// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class EntityValidatedContactRecordV1Tests: XCTestCase {
    func testOwnerSignedValidatedContactCommitsAndReplays() async throws {
        let owner = try await makeOwner("validated-contact")
        var envelope = validEnvelope()
        envelope.commitRequest = try await EntityAuthorityCommitRequest.signed(
            envelope: envelope,
            mutationID: "validated-contact-vegar-1",
            epoch: 1,
            expectedRevision: 0,
            expectedPreviousHash: nil,
            requester: owner,
            purposeRef: EntityValidatedContactRecordV1.storagePurposeRef
        )

        XCTAssertNoThrow(
            try EntityValidatedContactRecordV1.validatePersistenceEnvelope(envelope)
        )

        let committed = try await EntityAuthorityJournalDocument().appending(
            envelope: envelope,
            to: ["relations": .object([:])],
            requester: owner,
            authority: owner,
            authorityCellUUID: "validated-contact-entity-anchor",
            committedAtEpochMilliseconds: 1_786_300_000_000
        )
        let keypath = EntityValidatedContactRecordV1.keypath(
            relationID: "person-vegar-fixture"
        )
        XCTAssertTrue(
            ExploreContractValidator.deepEqual(
                try committed.snapshot.get(keypath: keypath),
                envelope.mutations[0].value
            )
        )
        XCTAssertTrue(committed.receipt.verifies(with: owner))
        XCTAssertEqual(committed.receipt.replicationState, "local_authority_only")
    }

    func testProtectedContactRejectsLegacyAndDirectWrites() throws {
        let keypath = EntityValidatedContactRecordV1.keypath(
            relationID: "person-vegar-fixture"
        )
        let legacy = EntityBatchPersistEnvelope(
            schema: "legacy.entity.batch.v1",
            mutations: [EntityBatchPersistMutation(keypath: keypath, value: Self.validRecord())]
        )

        XCTAssertThrowsError(
            try EntityValidatedContactRecordV1.validatePersistenceEnvelope(legacy)
        ) { error in
            XCTAssertEqual(
                error as? EntityValidatedContactRecordErrorV1,
                .protectedKeypathRequiresValidatedSchema
            )
        }
        XCTAssertThrowsError(
            try EntityValidatedContactRecordV1.rejectDirectMutation(to: keypath)
        ) { error in
            XCTAssertEqual(
                error as? EntityValidatedContactRecordErrorV1,
                .protectedKeypathRequiresValidatedSchema
            )
        }
    }

    func testValidatedContactRequiresSignedCommitAndExactMetadata() throws {
        let unsigned = validEnvelope()
        XCTAssertThrowsError(
            try EntityValidatedContactRecordV1.validatePersistenceEnvelope(unsigned)
        ) { error in
            XCTAssertEqual(
                error as? EntityValidatedContactRecordErrorV1,
                .ownerSignedCommitRequired
            )
        }

        var wrongMetadata = validEnvelope()
        wrongMetadata.metadata["sendNow"] = .bool(true)
        wrongMetadata.commitRequest = fixtureCommitRequest()
        XCTAssertThrowsError(
            try EntityValidatedContactRecordV1.validatePersistenceEnvelope(wrongMetadata)
        ) { error in
            XCTAssertEqual(
                error as? EntityValidatedContactRecordErrorV1,
                .invalidMetadata
            )
        }
    }

    func testContactRecordRejectsInvalidChannelsAndDisclosureCoupling() throws {
        var invalidEmailRecord = Self.validRecordObject()
        invalidEmailRecord["channels"] = ValueType.object([
            "email": ValueType.string("not-an-email")
        ])
        var invalidEmail = validEnvelope(record: .object(invalidEmailRecord))
        invalidEmail.commitRequest = fixtureCommitRequest()
        XCTAssertThrowsError(
            try EntityValidatedContactRecordV1.validatePersistenceEnvelope(invalidEmail)
        ) { error in
            XCTAssertEqual(error as? EntityValidatedContactRecordErrorV1, .invalidEmail)
        }

        var invalidPhoneRecord = Self.validRecordObject()
        invalidPhoneRecord["channels"] = ValueType.object([
            "phoneE164": ValueType.string("004799602626")
        ])
        var invalidPhone = validEnvelope(record: .object(invalidPhoneRecord))
        invalidPhone.commitRequest = fixtureCommitRequest()
        XCTAssertThrowsError(
            try EntityValidatedContactRecordV1.validatePersistenceEnvelope(invalidPhone)
        ) { error in
            XCTAssertEqual(error as? EntityValidatedContactRecordErrorV1, .invalidPhoneE164)
        }

        var unicodeDigitsRecord = Self.validRecordObject()
        unicodeDigitsRecord["channels"] = ValueType.object([
            "phoneE164": ValueType.string("+٤٧٩٩٦٠٢٦٢٦")
        ])
        var unicodeDigits = validEnvelope(record: .object(unicodeDigitsRecord))
        unicodeDigits.commitRequest = fixtureCommitRequest()
        XCTAssertThrowsError(
            try EntityValidatedContactRecordV1.validatePersistenceEnvelope(unicodeDigits)
        ) { error in
            XCTAssertEqual(error as? EntityValidatedContactRecordErrorV1, .invalidPhoneE164)
        }

        var disclosureRecord = Self.validRecordObject()
        disclosureRecord["retention"] = ValueType.object([
            "storageAuthorized": ValueType.bool(true),
            "disclosureAuthorized": ValueType.bool(true)
        ])
        var disclosure = validEnvelope(record: .object(disclosureRecord))
        disclosure.commitRequest = fixtureCommitRequest()
        XCTAssertThrowsError(
            try EntityValidatedContactRecordV1.validatePersistenceEnvelope(disclosure)
        ) { error in
            XCTAssertEqual(error as? EntityValidatedContactRecordErrorV1, .invalidRetention)
        }
    }

    func testContactRecordRejectsUnknownFieldsAndRelationRebinding() throws {
        var recordWithSecret = Self.validRecordObject()
        recordWithSecret["pushToken"] = ValueType.string("must-not-be-stored-here")
        var unknownField = validEnvelope(record: .object(recordWithSecret))
        unknownField.commitRequest = fixtureCommitRequest()
        XCTAssertThrowsError(
            try EntityValidatedContactRecordV1.validatePersistenceEnvelope(unknownField)
        ) { error in
            XCTAssertEqual(error as? EntityValidatedContactRecordErrorV1, .invalidRecordShape)
        }

        var rebound = validEnvelope(
            keypath: EntityValidatedContactRecordV1.keypath(relationID: "another-person")
        )
        rebound.commitRequest = fixtureCommitRequest()
        XCTAssertThrowsError(
            try EntityValidatedContactRecordV1.validatePersistenceEnvelope(rebound)
        ) { error in
            XCTAssertEqual(error as? EntityValidatedContactRecordErrorV1, .relationBindingMismatch)
        }
    }

    func testSchemaSurfaceContainsNoContactValues() throws {
        let encoded = try JSONEncoder().encode(EntityValidatedContactRecordV1.schemaValue())
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains(EntityValidatedContactRecordV1.recordSchema))
        XCTAssertTrue(text.contains("disclosureImplied"))
        XCTAssertFalse(text.contains("vegar@example.test"))
        XCTAssertFalse(text.contains("+4799602626"))

        let explore = EntityValidatedContactRecordV1.schemaExploreReturn()
        XCTAssertTrue(
            ExploreContractValidator.matches(
                value: EntityValidatedContactRecordV1.schemaValue(),
                schema: explore
            )
        )
    }

    private func validEnvelope(
        keypath: String = EntityValidatedContactRecordV1.keypath(
            relationID: "person-vegar-fixture"
        ),
        record: ValueType? = nil
    ) -> EntityBatchPersistEnvelope {
        EntityBatchPersistEnvelope(
            schema: EntityValidatedContactRecordV1.envelopeSchema,
            mutations: [EntityBatchPersistMutation(
                keypath: keypath,
                value: record ?? Self.validRecord()
            )],
            metadata: [
                "dataAction": .string("entity-storage"),
                "disclosureAuthorized": .bool(false),
                "relationID": .string("person-vegar-fixture")
            ]
        )
    }

    private static func validRecord() -> ValueType {
        .object(validRecordObject())
    }

    private static func validRecordObject() -> Object {
        [
            "schema": .string(EntityValidatedContactRecordV1.recordSchema),
            "relationID": .string("person-vegar-fixture"),
            "displayName": .string("Vegar Fixture"),
            "channels": .object([
                "email": .string("vegar@example.test"),
                "phoneE164": .string("+4799602626")
            ]),
            "provenance": .object([
                "sourceKind": .string("macos-contacts"),
                "sourceLabel": .string("Owner macOS Contacts"),
                "observedAt": .string("2026-08-10T10:00:00Z")
            ]),
            "purposeRefs": .list([
                .string("purpose://contact.communication"),
                .string("purpose://contact.introduction"),
                .string("purpose://access.audit.privacy")
            ]),
            "retention": .object([
                "storageAuthorized": .bool(true),
                "disclosureAuthorized": .bool(false)
            ]),
            "status": .string("owner-accepted")
        ]
    }

    private func fixtureCommitRequest() -> EntityAuthorityCommitRequest {
        EntityAuthorityCommitRequest(
            mutationID: "fixture-validated-contact",
            partitionID: "entity",
            epoch: 1,
            expectedRevision: 0,
            expectedPreviousHash: nil,
            payloadHash: "fixture-payload-hash",
            requesterIdentityUUID: "fixture-owner",
            requesterSigningKeyFingerprint: "fixture-key",
            purposeRef: EntityValidatedContactRecordV1.storagePurposeRef,
            capability: EntityBatchPersistEnvelope.operation,
            faultPolicyID: EntityAuthorityCommitRequest.localAuthorityFaultPolicy,
            requiredReplicaAcks: 0,
            signature: Data("fixture-signature".utf8)
        )
    }

    private func makeOwner(_ domain: String) async throws -> Identity {
        let vault = await EphemeralIdentityVault().initialize()
        let identity = await vault.identity(for: domain, makeNewIfNotFound: true)
        return try XCTUnwrap(identity)
    }
}
