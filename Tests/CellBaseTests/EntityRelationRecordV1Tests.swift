// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

/// A relation lives in my entity as the tie itself — origin, roles, channels,
/// evidence, a running interaction summary — and the address stays behind
/// in the validated contact record. These tests hold the two invariants that
/// make that safe: the record admits no raw address, and the chronicle
/// admits no content under a metadata policy.
final class EntityRelationRecordV1Tests: XCTestCase {

    // MARK: Round trip and admission

    func testARelationRecordSurvivesTheTripThroughTheEntity() async throws {
        let owner = try await makeOwner("relation-record")
        let record = Self.vegar()
        let envelope = EntityBatchPersistEnvelope(
            schema: EntityRelationRecordV1.envelopeSchema,
            mutations: [
                EntityBatchPersistMutation(
                    keypath: EntityRelationRecordV1.keypath(relationID: record.relationID),
                    value: EntityRelationCodec.value(record)
                )
            ]
        )
        XCTAssertNoThrow(try EntityRelationRecordV1.validatePersistenceEnvelope(envelope))

        let committed = try await EntityAuthorityJournalDocument().appending(
            envelope: envelope.withSignedCommit(owner: owner, mutationID: "relation-vegar-1"),
            to: ["relations": .object([:])],
            requester: owner,
            authority: owner,
            authorityCellUUID: "relation-entity-anchor",
            committedAtEpochMilliseconds: 1_786_300_000_000
        )
        let stored = try committed.snapshot.get(keypath: EntityRelationRecordV1.keypath(relationID: record.relationID))
        let decoded = try XCTUnwrap(EntityRelationCodec.decode(EntityRelationRecord.self, from: stored))
        XCTAssertEqual(decoded.subject.displayName, "Vegar Hansen")
        XCTAssertEqual(decoded.origin.kind, .fileImport)
        XCTAssertEqual(decoded.roles.first?.group, "KI og tillit")
        XCTAssertEqual(decoded.interests.declared, ["KI og tillit"])
        XCTAssertEqual(decoded.interests.inferred, ["ledelse og forretningsutvikling"])
    }

    func testTheRecordNamespaceRefusesGenericAndMisboundWrites() throws {
        let record = Self.vegar()
        let value = EntityRelationCodec.value(record)
        let keypath = EntityRelationRecordV1.keypath(relationID: record.relationID)

        XCTAssertThrowsError(try EntityRelationRecordV1.rejectDirectMutation(to: keypath))
        XCTAssertNoThrow(try EntityRelationRecordV1.rejectDirectMutation(to: "relations.validatedContacts.x"))

        let legacy = EntityBatchPersistEnvelope(
            schema: "legacy.entity.batch.v1",
            mutations: [EntityBatchPersistMutation(keypath: keypath, value: value)]
        )
        XCTAssertThrowsError(try EntityRelationRecordV1.validatePersistenceEnvelope(legacy)) { error in
            XCTAssertEqual(error as? EntityRelationRecordErrorV1, .protectedKeypathRequiresRelationSchema)
        }

        let misbound = EntityBatchPersistEnvelope(
            schema: EntityRelationRecordV1.envelopeSchema,
            mutations: [EntityBatchPersistMutation(
                keypath: EntityRelationRecordV1.keypath(relationID: "someone-else"),
                value: value
            )]
        )
        XCTAssertThrowsError(try EntityRelationRecordV1.validatePersistenceEnvelope(misbound)) { error in
            XCTAssertEqual(error as? EntityRelationRecordErrorV1, .relationBindingMismatch)
        }

        let unrelated = EntityBatchPersistEnvelope(
            schema: "anything.else",
            mutations: [EntityBatchPersistMutation(keypath: "person.displayName", value: .string("Kjetil"))]
        )
        XCTAssertNoThrow(try EntityRelationRecordV1.validatePersistenceEnvelope(unrelated))
    }

    /// The whole point of splitting the tie from the address: a relation
    /// record must be safe to carry to any surface.
    func testARelationRecordNeverCarriesARawAddress() throws {
        for leaked in ["vegar@kommunen.no", "+4790000000", "90 00 00 00", "004790000000"] {
            var record = Self.vegar()
            record.channels = [EntityRelationChannel(kind: .email, ref: leaked)]
            XCTAssertThrowsError(try EntityRelationRecordV1.validate(record), leaked) { error in
                XCTAssertEqual(error as? EntityRelationRecordErrorV1, .rawContactValueNotAllowed)
            }
        }
        for opaque in ["ep-3f9a1c", "peer-7c1e", "e-1b2c3d4e", "cell:///Relations#vegar"] {
            var record = Self.vegar()
            record.channels = [EntityRelationChannel(kind: .email, ref: opaque)]
            XCTAssertNoThrow(try EntityRelationRecordV1.validate(record), opaque)
        }
    }

    // MARK: Interactions

    func testAnInteractionUpdatesTheSummaryAndTheChannelItUsed() throws {
        let record = Self.vegar()
        let first = Date(timeIntervalSince1970: 1_786_300_000)
        let sent = EntityRelationInteractionEvent(
            id: "ev-1", relationID: record.relationID, kind: .inviteSent, at: first,
            channel: .email, direction: .outbound, sourceCell: "BindingInvitationCell"
        )
        let afterSend = record.applying(sent, chronicleRef: "chronicle[id=relation-event-vegar-ev-1]")
        XCTAssertEqual(afterSend.interactions.count, 1)
        XCTAssertEqual(afterSend.interactions.firstAt, first)
        XCTAssertEqual(afterSend.interactions.lastKind, "invite.sent")
        XCTAssertEqual(afterSend.interactions.byChannel["email"], 1)
        XCTAssertEqual(afterSend.standing.trust, .invited)
        XCTAssertEqual(afterSend.standing.lastInviteAt, first)
        XCTAssertEqual(afterSend.revision, record.revision + 1)

        let later = first.addingTimeInterval(3_600)
        let received = EntityRelationInteractionEvent(
            id: "ev-2", relationID: record.relationID, kind: .messageReceived, at: later,
            channel: .havenCorrespondence, direction: .inbound, sourceCell: "AssistantCorrespondenceCell"
        )
        let afterReply = afterSend.applying(received, chronicleRef: "chronicle[id=relation-event-vegar-ev-2]")
        XCTAssertEqual(afterReply.interactions.count, 2)
        XCTAssertEqual(afterReply.interactions.lastAt, later)
        XCTAssertEqual(afterReply.interactions.lastChannel, "haven-correspondence")
        let correspondence = try XCTUnwrap(afterReply.channels.first { $0.kind == .havenCorrespondence })
        XCTAssertTrue(correspondence.confirmed, "an inbound message proves the channel works")
        XCTAssertEqual(correspondence.lastUsedAt, later)
    }

    func testEvidenceOfContactRaisesTrustToVerified() {
        let record = Self.vegar()
        let presented = EntityRelationInteractionEvent(
            id: "ev-3", relationID: record.relationID, kind: .vcPresented,
            at: Date(timeIntervalSince1970: 1_786_400_000),
            channel: .havenCorrespondence, direction: .inbound,
            evidenceID: "vc-abc", sourceCell: "AssistantCorrespondenceCell"
        )
        XCTAssertEqual(record.applying(presented, chronicleRef: nil).standing.trust, .verified)

        var blocked = record
        blocked.standing.trust = .blocked
        XCTAssertEqual(blocked.applying(presented, chronicleRef: nil).standing.trust, .blocked,
                       "evidence does not unblock someone the owner blocked")
    }

    /// Metadata is the default: that we talked, when and how. Never what.
    func testAMetadataEventDropsContentEvenWhenACallerSuppliesIt() throws {
        let event = EntityRelationInteractionEvent(
            id: "ev-4", relationID: "vegar", kind: .messageSent, at: Date(),
            channel: .havenCorrespondence, direction: .outbound,
            contentMode: .metadata, summary: "Hei Vegar, ...", sourceCell: "AssistantCorrespondenceCell"
        )
        XCTAssertNil(event.summary)
        XCTAssertNoThrow(try EntityRelationRecordV1.validate(event))

        var tampered = event
        tampered.summary = "smuglet inn"
        XCTAssertThrowsError(try EntityRelationRecordV1.validate(tampered)) { error in
            XCTAssertEqual(error as? EntityRelationRecordErrorV1, .contentNotAllowedUnderPolicy)
        }
    }

    func testChronicleEventsAreBoundToTheirRelation() throws {
        let event = EntityRelationInteractionEvent(
            id: "ev-5", relationID: "vegar", kind: .chatStarted, at: Date(),
            channel: .havenChat, direction: .outbound, sourceCell: "BindingPersonalChatHubCell"
        )
        let right = EntityBatchPersistEnvelope(
            schema: EntityRelationRecordV1.envelopeSchema,
            mutations: [EntityBatchPersistMutation(
                keypath: EntityRelationRecordV1.chronicleKeypath(relationID: "vegar", eventID: "ev-5"),
                value: EntityRelationCodec.value(event)
            )]
        )
        XCTAssertNoThrow(try EntityRelationRecordV1.validatePersistenceEnvelope(right))
        XCTAssertEqual(right.mutations[0].keypath, "chronicle[id=relation-event-vegar-ev-5]")

        let wrong = EntityBatchPersistEnvelope(
            schema: EntityRelationRecordV1.envelopeSchema,
            mutations: [EntityBatchPersistMutation(
                keypath: EntityRelationRecordV1.chronicleKeypath(relationID: "victoria", eventID: "ev-5"),
                value: EntityRelationCodec.value(event)
            )]
        )
        XCTAssertThrowsError(try EntityRelationRecordV1.validatePersistenceEnvelope(wrong)) { error in
            XCTAssertEqual(error as? EntityRelationRecordErrorV1, .relationBindingMismatch)
        }
    }

    // MARK: Reach

    func testReachableChannelsPreferAConversationOverAnAddress() {
        var record = Self.vegar()
        record.channels = [
            EntityRelationChannel(kind: .email, ref: "ep-mail", confirmed: true),
            EntityRelationChannel(kind: .havenCorrespondence, ref: "peer-vegar", confirmed: false),
            EntityRelationChannel(kind: .web, ref: "https-linkedin")
        ]
        XCTAssertEqual(record.reachableChannels.map(\.kind), [.havenCorrespondence, .email])

        record.channels[0].preferred = true
        XCTAssertEqual(record.reachableChannels.first?.kind, .email, "an owner's explicit preference wins")
    }

    // MARK: Reach planning

    func testThePlannerOpensAChatWhenTheyHaveAnEntity() {
        var record = Self.vegar()
        record.channels.append(EntityRelationChannel(kind: .havenChat, ref: "entity-vegar", confirmed: true))
        let plan = EntityRelationReachPlanner.plan(for: record)
        XCTAssertEqual(plan.recommended?.action, .openChat)
        XCTAssertEqual(plan.alternatives.map(\.action), [.sendCorrespondence, .sendInvite])
        XCTAssertTrue(plan.blockers.isEmpty)
    }

    func testThePlannerInvitesWhenAllWeHoldIsAnAddress() {
        var record = Self.vegar()
        record.channels = [EntityRelationChannel(kind: .email, ref: "ep-mail")]
        let plan = EntityRelationReachPlanner.plan(for: record)
        XCTAssertEqual(plan.recommended?.action, .sendInvite)
        XCTAssertEqual(plan.recommended?.channel, .email)
    }

    /// Sending a second invitation inside a week is a decision, not a reflex.
    func testARecentUnansweredInviteTurnsSendIntoResend() {
        var record = Self.vegar()
        record.channels = [EntityRelationChannel(kind: .email, ref: "ep-mail")]
        let now = Date(timeIntervalSince1970: 1_786_500_000)
        record.standing.inviteState = "sent"
        record.standing.lastInviteAt = now.addingTimeInterval(-2 * 86_400)
        let plan = EntityRelationReachPlanner.plan(for: record, now: now)
        XCTAssertEqual(plan.recommended?.action, .resendInvite)
        XCTAssertTrue(plan.recommended?.reason.contains("for 2 dager siden") == true)

        record.standing.lastInviteAt = now.addingTimeInterval(-30 * 86_400)
        XCTAssertEqual(EntityRelationReachPlanner.plan(for: record, now: now).recommended?.action, .sendInvite)
    }

    func testABlockedRelationHasNoWayInAndSaysSo() {
        var record = Self.vegar()
        record.standing.trust = .blocked
        let plan = EntityRelationReachPlanner.plan(for: record)
        XCTAssertNil(plan.recommended)
        XCTAssertEqual(plan.blockers.count, 1)
        XCTAssertFalse(plan.canReach)
    }

    func testNoChannelAtAllIsReportedNotGuessed() {
        var record = Self.vegar()
        record.channels = []
        let plan = EntityRelationReachPlanner.plan(for: record)
        XCTAssertNil(plan.recommended)
        XCTAssertTrue(plan.blockers.first?.contains("ingen kanal") == true)
    }

    func testNearbyOnlyCountsWhileItIsFresh() {
        var record = Self.vegar()
        let now = Date(timeIntervalSince1970: 1_786_500_000)
        record.channels = [EntityRelationChannel(kind: .nearby, ref: "radar-7", lastUsedAt: now.addingTimeInterval(-3_600))]
        XCTAssertEqual(EntityRelationReachPlanner.plan(for: record, now: now).recommended?.action, .meetNearby)
        record.channels[0].lastUsedAt = now.addingTimeInterval(-3 * 86_400)
        XCTAssertNil(EntityRelationReachPlanner.plan(for: record, now: now).recommended)
    }

    // MARK: Fixtures

    private static func vegar() -> EntityRelationRecord {
        EntityRelationRecord(
            relationID: "vegar",
            subject: EntityRelationSubject(
                displayName: "Vegar Hansen",
                organization: "Kommunen",
                jobTitle: "Rådgiver",
                validatedContactRef: EntityValidatedContactRecordV1.keypath(relationID: "vegar")
            ),
            origin: EntityRelationOrigin(
                kind: .fileImport,
                at: Date(timeIntervalSince1970: 1_786_200_000),
                sourceLabel: "HAVEN_import_bokprosjekt.xlsx",
                batchID: "b-bok-1",
                locator: "rad 12",
                context: "Bok: Rammebetingelser for innovasjon"
            ),
            roles: [EntityRelationRole(context: "Bok: Rammebetingelser for innovasjon", role: nil, group: "KI og tillit")],
            interests: EntityRelationInterests(declared: ["KI og tillit"], inferred: ["ledelse og forretningsutvikling"]),
            purposeRefs: ["purpose://contact.communication"],
            channels: [
                EntityRelationChannel(kind: .email, ref: "ep-3f9a1c", confirmed: false),
                EntityRelationChannel(kind: .havenCorrespondence, ref: "peer-vegar", confirmed: false)
            ],
            createdAt: Date(timeIntervalSince1970: 1_786_200_000),
            updatedAt: Date(timeIntervalSince1970: 1_786_200_000)
        )
    }

    private func makeOwner(_ domain: String) async throws -> Identity {
        let vault = await EphemeralIdentityVault().initialize()
        let identity = await vault.identity(for: domain, makeNewIfNotFound: true)
        return try XCTUnwrap(identity)
    }
}

private extension EntityBatchPersistEnvelope {
    func withSignedCommit(owner: Identity, mutationID: String) async throws -> EntityBatchPersistEnvelope {
        var copy = self
        copy.commitRequest = try await EntityAuthorityCommitRequest.signed(
            envelope: self,
            mutationID: mutationID,
            epoch: 1,
            expectedRevision: 0,
            expectedPreviousHash: nil,
            requester: owner,
            purposeRef: "purpose://contact.communication"
        )
        return copy
    }
}
