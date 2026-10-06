// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  HavenInvitePushPlannerTests.swift
//  PDD_testmatrise-og-apns-chat WP3 / T5.3 — only who was invited is pushed.
//  purpose://candidate.testmatrise.apns.only-who-was-invited-is-pushed
//

import Foundation
import XCTest
@testable import CellBase

final class HavenInvitePushPlannerTests: XCTestCase {

    private let token = String(repeating: "ab12cd34", count: 8)

    private struct World {
        let issuer: SimulatedEntity
        let audience: SimulatedEntity
        let stranger: SimulatedEntity
        let ticket: HavenInviteTicket
        var registry: HavenPushRegistry
    }

    private func publication(
        issuer: SimulatedEntity,
        audienceEntity: String?,
        ttl: Int = HavenInviteTicket.defaultTimeToLive,
        now: Date = Date()
    ) async throws -> (HavenInvitePublication, HavenInviteTicket) {
        let descriptor = try XCTUnwrap(IdentityPublicKeySignatureVerifier.descriptor(for: issuer.owner))
        let createdAt = Int(now.timeIntervalSince1970)
        var ticket = HavenInviteTicket(
            ticketID: "inv-" + UUID().uuidString.lowercased(),
            issuer: descriptor,
            issuerDisplayName: "Kjetil",
            issuerContactEndpoint: "ep-1",
            audienceToken: "aud-vegar",
            audienceKind: "email",
            humanCode: "ABC234",
            greetingName: "Vegar",
            identityDomain: "private",
            basis: [],
            createdAt: createdAt,
            expiresAt: createdAt + ttl,
            nonce: Data(repeating: 7, count: 12)
        )
        ticket.proof = try await HavenInviteSigning.proof(over: try ticket.canonicalPayloadData(), by: issuer.owner)
        var publication = HavenInvitePublication(
            ticketID: ticket.ticketID,
            humanCode: ticket.humanCode,
            ticketToken: try HavenInviteLink.encode(ticket),
            audienceToken: ticket.audienceToken,
            issuerIdentityUUID: ticket.issuer.uuid,
            expiresAt: ticket.expiresAt,
            publishedAt: createdAt,
            statusKey: HavenInvitePublication.makeStatusKey(),
            audienceEntity: audienceEntity
        )
        publication.proof = try await HavenInviteSigning.proof(over: try publication.canonicalPayloadData(), by: issuer.owner)
        return (publication, ticket)
    }

    private func world(registerAudience: Bool = true, now: Date = Date()) async throws -> (World, HavenInvitePublication) {
        let issuer = await SimulatedEntity.make("kjetil")
        let audience = await SimulatedEntity.make("vegar")
        let stranger = await SimulatedEntity.make("stranger")
        let (publication, ticket) = try await publication(issuer: issuer, audienceEntity: audience.owner.uuid, now: now)
        var registry = HavenPushRegistry()
        if registerAudience {
            try registry.register(try await HavenPushRegistration.make(
                entity: audience.owner, environment: .sandbox, bundleId: "org.digipomps.haven", token: token, now: now
            ), now: now)
        }
        return (World(issuer: issuer, audience: audience, stranger: stranger, ticket: ticket, registry: registry), publication)
    }

    func testNamedAndRegisteredAudienceIsPushed() async throws {
        let (w, pub) = try await world()
        let plan = HavenInvitePushPlanner.plan(publication: pub, registry: w.registry)
        XCTAssertNil(plan.skip)
        XCTAssertEqual(plan.targets.count, 1)
        XCTAssertEqual(plan.targets.first?.token, token)
        XCTAssertEqual(plan.ticketID, w.ticket.ticketID)
        XCTAssertEqual(plan.ticketExpiresAt, w.ticket.expiresAt)
    }

    func testOnlyTheNamedEntitysDevicesAreTargets() async throws {
        var (w, pub) = try await world()
        try w.registry.register(try await HavenPushRegistration.make(
            entity: w.stranger.owner, environment: .sandbox, bundleId: "org.digipomps.haven", token: String(repeating: "ef56ab78", count: 8)
        ))
        let plan = HavenInvitePushPlanner.plan(publication: pub, registry: w.registry)
        XCTAssertEqual(plan.targets.map(\.token), [token])
    }

    func testNoAudienceEntityMeansNoPush() async throws {
        let issuer = await SimulatedEntity.make("kjetil")
        let (pub, _) = try await publication(issuer: issuer, audienceEntity: nil)
        let plan = HavenInvitePushPlanner.plan(publication: pub, registry: HavenPushRegistry())
        XCTAssertEqual(plan.skip, .noAudienceEntity)
        XCTAssertTrue(plan.targets.isEmpty)
    }

    func testNamedButNeverRegisteredMeansNoRegistration() async throws {
        let (w, pub) = try await world(registerAudience: false)
        XCTAssertEqual(HavenInvitePushPlanner.plan(publication: pub, registry: w.registry).skip, .noRegistration)
    }

    func testRevokedTokenMeansTokenRevoked() async throws {
        var (w, pub) = try await world()
        let registration = try await HavenPushRegistration.make(
            entity: w.audience.owner, environment: .sandbox, bundleId: "org.digipomps.haven", token: token
        )
        try w.registry.revoke(try await HavenPushRevocation.make(registrationID: registration.registrationID, by: w.audience.owner))
        XCTAssertEqual(HavenInvitePushPlanner.plan(publication: pub, registry: w.registry).skip, .tokenRevoked)
    }

    func testIssuerNamingThemselvesIsWrongAudience() async throws {
        let issuer = await SimulatedEntity.make("kjetil")
        let (pub, _) = try await publication(issuer: issuer, audienceEntity: issuer.owner.uuid)
        XCTAssertEqual(HavenInvitePushPlanner.plan(publication: pub, registry: HavenPushRegistry()).skip, .wrongAudience)
    }

    func testMalformedAudienceEntityIsWrongAudience() async throws {
        let issuer = await SimulatedEntity.make("kjetil")
        let (pub, _) = try await publication(issuer: issuer, audienceEntity: "vegar@example.com")
        XCTAssertEqual(HavenInvitePushPlanner.plan(publication: pub, registry: HavenPushRegistry()).skip, .wrongAudience)
    }

    func testExpiredTicketIsNotPushed() async throws {
        let (w, pub) = try await world()
        let later = Date().addingTimeInterval(TimeInterval(HavenInviteTicket.defaultTimeToLive + 3_600))
        XCTAssertEqual(HavenInvitePushPlanner.plan(publication: pub, registry: w.registry, now: later).skip, .ticketExpired)
    }

    func testRevokedTicketIsNotPushed() async throws {
        let (w, pub) = try await world()
        let plan = HavenInvitePushPlanner.plan(publication: pub, revokedTicketIDs: [w.ticket.ticketID], registry: w.registry)
        XCTAssertEqual(plan.skip, .ticketRevoked)
    }

    func testTombstoneFromTheSameIssuerToTheSameAudienceBlocksPush() async throws {
        let (w, pub) = try await world()
        let reply = try await HavenInviteReply.make(to: w.ticket, decision: .never, by: w.audience.owner)
        var ledger = HavenInviteTombstoneLedger()
        ledger.record(try HavenInviteTombstone.make(from: reply, forTicket: w.ticket))
        let plan = HavenInvitePushPlanner.plan(publication: pub, tombstones: ledger, registry: w.registry)
        XCTAssertEqual(plan.skip, .tombstoned)
    }

    func testTamperedPublicationIsNotPushed() async throws {
        var (w, pub) = try await world()
        pub.audienceEntity = w.stranger.owner.uuid       // swap the audience after signing
        let plan = HavenInvitePushPlanner.plan(publication: pub, registry: w.registry)
        XCTAssertEqual(plan.skip, .ticketInvalid)
        XCTAssertTrue(plan.targets.isEmpty)
    }

    func testAudienceEntityIsSignedButNotInTheTicket() async throws {
        let (w, pub) = try await world()
        let text = String(decoding: try JSONEncoder().encode(w.ticket), as: UTF8.self)
        XCTAssertFalse(text.lowercased().contains(w.audience.owner.uuid.lowercased()), "the link must not name the audience entity")
        let withEntity = try pub.canonicalPayloadData()
        var without = pub; without.audienceEntity = nil
        XCTAssertNotEqual(withEntity, try without.canonicalPayloadData(), "audienceEntity is covered by the signature")
    }

    func testPublicationWithoutAudienceEntityKeepsItsOldCanonicalBytes() async throws {
        let issuer = await SimulatedEntity.make("kjetil")
        let (pub, _) = try await publication(issuer: issuer, audienceEntity: nil)
        let text = String(decoding: try pub.canonicalPayloadData(), as: UTF8.self)
        XCTAssertFalse(text.contains("audienceEntity"), "additive field is only coded when set")
    }

    func testSenderViewHasNoVocabularyForPushOutcomes() async throws {
        let (_, pub) = try await world()
        let report = HavenInviteStatusReport(ticketID: pub.ticketID, state: .published).projectedForSender()
        let text = String(decoding: try JSONEncoder().encode(report), as: UTF8.self).lowercased()
        for word in ["push", "apns", "sent", "delivered", "token", "registration"] {
            XCTAssertFalse(text.contains(word), "sender view must not mention \(word)")
        }
    }
}
