// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  HavenInviteRoundATests.swift
//  PDD_invitasjon-tillit runde A, WP1–WP5.
//
//  Every test here is a boundary: what the ticket carries under its
//  signature, when the verifier says no, what the sender may see, and what
//  never leaves. Two simulated entities per test (own vault, random UUIDs).
//

import Foundation
import XCTest
@testable import CellBase

final class HavenInviteRoundATests: XCTestCase {

    // The one string that must never appear anywhere a message can go.
    private let sentinel = "PRIVAT-NOTAT-SENTINEL-7f3a9c"

    // MARK: - Fixtures

    private struct Issued {
        let issuer: SimulatedEntity
        let ticket: HavenInviteTicket
    }

    private func basis() -> HavenContactBasisV1 {
        HavenContactBasisV1(
            fields: [
                .init(key: "name", value: "Vegar Testesen",
                      origin: .init(file: "Boklisten", date: "12. sep.", column: "Navn")),
                .init(key: "email", value: "vegar@example.test",
                      origin: .init(file: "Boklisten", date: "12. sep.", column: "Epost"))
            ],
            privateNotes: "Møtte ham på seminaret. \(sentinel)"
        )
    }

    private func issue(
        domain: String = "private",
        basis: HavenContactBasisV1? = nil,
        ttl: Int = HavenInviteTicket.defaultTimeToLive,
        now: Date = Date(),
        endpoint: String? = "ep-1"
    ) async throws -> Issued {
        let issuer = await SimulatedEntity.make("kjetil", domain: domain)
        let descriptor = try XCTUnwrap(IdentityPublicKeySignatureVerifier.descriptor(for: issuer.owner))
        let createdAt = Int(now.timeIntervalSince1970)
        var ticket = HavenInviteTicket(
            ticketID: "inv-" + UUID().uuidString.lowercased(),
            issuer: descriptor,
            issuerDisplayName: "Kjetil",
            issuerContactEndpoint: endpoint,
            audienceToken: "aud-vegar",
            audienceKind: "email",
            humanCode: "ABC234",
            greetingName: "Vegar",
            identityDomain: domain,
            basis: (basis ?? self.basis()).basisFields(),
            createdAt: createdAt,
            expiresAt: createdAt + ttl,
            nonce: Data(repeating: 7, count: 12)
        )
        ticket.proof = try await HavenInviteSigning.proof(over: try ticket.canonicalPayloadData(), by: issuer.owner)
        return Issued(issuer: issuer, ticket: ticket)
    }

    private func publication(for issued: Issued, now: Date = Date()) async throws -> HavenInvitePublication {
        var publication = HavenInvitePublication(
            ticketID: issued.ticket.ticketID,
            humanCode: issued.ticket.humanCode,
            ticketToken: try HavenInviteLink.encode(issued.ticket),
            audienceToken: issued.ticket.audienceToken,
            issuerIdentityUUID: issued.ticket.issuer.uuid,
            expiresAt: issued.ticket.expiresAt,
            publishedAt: Int(now.timeIntervalSince1970),
            statusKey: HavenInvitePublication.makeStatusKey()
        )
        publication.proof = try await HavenInviteSigning.proof(over: try publication.canonicalPayloadData(), by: issued.issuer.owner)
        return publication
    }

    private func contactRequest(
        from invitee: SimulatedEntity,
        to issued: Issued,
        message: String? = nil,
        now: Date = Date()
    ) async throws -> HavenInviteContactRequest {
        let descriptor = try XCTUnwrap(IdentityPublicKeySignatureVerifier.descriptor(for: invitee.owner))
        let createdAt = Int(now.timeIntervalSince1970)
        var request = HavenInviteContactRequest(
            requestID: "req-" + UUID().uuidString.lowercased(),
            ticketID: issued.ticket.ticketID,
            issuerEndpointID: issued.ticket.issuerContactEndpoint ?? "",
            sender: descriptor,
            senderDisplayName: "Vegar",
            message: message,
            senderKeyAgreementKey: invitee.owner.publicKeyAgreementSecureKey?.compressedKey,
            createdAt: createdAt,
            expiresAt: createdAt + 3_600,
            nonce: Data(repeating: 9, count: 12)
        )
        request.proof = try await HavenInviteSigning.proof(over: try request.canonicalPayloadData(), by: invitee.owner)
        return request
    }

    private func failureCode(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let failure as HavenInvitePublicationVerifier.Failure { return failure.code } catch { return "other:\(error)" }
    }

    // MARK: - WP1  M: the sender is the domain identity

    func testTicketCarriesIdentityDomainUnderSignature() async throws {
        let issued = try await issue(domain: "work")
        XCTAssertEqual(issued.ticket.identityDomain, "work")
        XCTAssertEqual(HavenInviteVerifier.verify(ticket: issued.ticket).code, "valid")

        // Round trip through the link keeps it.
        let decoded = try HavenInviteLink.decode(try HavenInviteLink.encode(issued.ticket))
        XCTAssertEqual(decoded.identityDomain, "work")
        XCTAssertEqual(HavenInviteVerifier.verify(ticket: decoded).code, "valid")

        // Swapping the domain after signing breaks the signature.
        var tampered = issued.ticket
        tampered.identityDomain = "private"
        XCTAssertEqual(HavenInviteVerifier.verify(ticket: tampered).code, "bad_signature")
    }

    func testTicketWithoutDomainOrBasisStillEncodesAndDecodesAsBefore() async throws {
        // A ticket issued by an app from before 26.09 has neither "id" nor "bs".
        let issued = try await issue()
        var old = issued.ticket
        old.identityDomain = nil
        old.basis = []
        old.proof = try await HavenInviteSigning.proof(over: try old.canonicalPayloadData(), by: issued.issuer.owner)
        let token = try HavenInviteLink.encode(old)
        let json = String(decoding: try XCTUnwrap(HavenInviteLink.dataFromBase64URL(token)), as: UTF8.self)
        XCTAssertFalse(json.contains("\"id\""))
        XCTAssertFalse(json.contains("\"bs\""))
        let decoded = try HavenInviteLink.decode(token)
        XCTAssertNil(decoded.identityDomain)
        XCTAssertEqual(decoded.basis, [])
        XCTAssertEqual(HavenInviteVerifier.verify(ticket: decoded).code, "valid")
    }

    // MARK: - WP2  O: expires by itself

    func testDefaultLifeIsFourteenDaysAndMaximumNinety() async throws {
        let issued = try await issue()
        XCTAssertEqual(issued.ticket.timeToLive, 14 * 86_400)
        XCTAssertEqual(HavenInviteTicket.maximumTimeToLive, 90 * 86_400)
        XCTAssertFalse(issued.ticket.claimsTooLongALife)
    }

    func testTicketClaimingMoreThanNinetyDaysIsRefusedEvenWhenWellSigned() async throws {
        let issued = try await issue(ttl: 91 * 86_400)
        let verdict = HavenInviteVerifier.verify(ticket: issued.ticket)
        XCTAssertTrue(verdict.signatureValid)
        XCTAssertFalse(verdict.isValid)
        XCTAssertEqual(verdict.code, "ttl_too_long")

        let publication = try await publication(for: issued)
        XCTAssertEqual(failureCode { _ = try HavenInvitePublicationVerifier.verifyPublication(publication) }, "ticket_invalid:ttl_too_long")
    }

    func testExpiredTicketIsDeadOnPublicationReplyAndContactRequest() async throws {
        let past = Date().addingTimeInterval(-30 * 86_400)
        let issued = try await issue(ttl: 14 * 86_400, now: past)
        XCTAssertTrue(issued.ticket.isExpired())
        XCTAssertEqual(HavenInviteVerifier.verify(ticket: issued.ticket).code, "expired")

        let publication = try await publication(for: issued)
        XCTAssertEqual(failureCode { _ = try HavenInvitePublicationVerifier.verifyPublication(publication) }, "ticket_expired")

        let vegar = await SimulatedEntity.make("vegar")
        let request = try await contactRequest(from: vegar, to: issued)
        XCTAssertEqual(failureCode { try HavenInvitePublicationVerifier.verifyContactRequest(request, forTicket: issued.ticket) }, "ticket_expired")

        let reply = try await HavenInviteReply.make(to: issued.ticket, decision: .yes, by: vegar.owner)
        XCTAssertEqual(failureCode { try HavenInvitePublicationVerifier.verifyReply(reply, forTicket: issued.ticket) }, "ticket_expired")
    }

    func testPublicationMustAgreeWithTicketOnExpiry() async throws {
        let issued = try await issue()
        var publication = try await publication(for: issued)
        publication.expiresAt += 86_400
        publication.proof = try await HavenInviteSigning.proof(over: try publication.canonicalPayloadData(), by: issued.issuer.owner)
        XCTAssertEqual(failureCode { _ = try HavenInvitePublicationVerifier.verifyPublication(publication) }, "ticket_mismatch")
    }

    // MARK: - WP3  C + D: the basis is a claim with an origin, and only the basis

    func testBasisRejectsFreeTextAndUnknownKeys() throws {
        var good = basis()
        XCTAssertNoThrow(try good.validate())

        var unknownKey = good
        unknownKey.fields.append(.init(key: "notes", value: "husk å ringe"))
        XCTAssertThrowsError(try unknownKey.validate()) { error in
            XCTAssertEqual(error as? HavenContactBasisV1.ValidationError, .unknownKey("notes"))
        }

        var freeText = good
        freeText.fields[0].value = "Vegar, som jeg møtte på seminaret i fjor og som sa han var interessert i det vi driver med, kanskje"
        XCTAssertThrowsError(try freeText.validate()) { error in
            XCTAssertEqual(error as? HavenContactBasisV1.ValidationError, .freeText("name"))
        }

        var multiline = good
        multiline.fields[1].value = "vegar@example.test\nring før 10"
        XCTAssertThrowsError(try multiline.validate()) { error in
            XCTAssertEqual(error as? HavenContactBasisV1.ValidationError, .freeText("email"))
        }

        good.fields[0].status = .confirmed
        XCTAssertNoThrow(try good.validate())
    }

    func testBasisFieldsAreMarkedUnconfirmedWithOrigin() throws {
        let held = basis()
        XCTAssertTrue(held.fields.allSatisfy { $0.status == .unconfirmed })
        let shown = held.basisFields()
        XCTAssertEqual(shown.count, 2)
        XCTAssertEqual(shown[1].origin, "Boklisten, 12. sep., kolonne Epost")
        // The person can confirm or erase a claim; the rest stands.
        XCTAssertEqual(held.confirming("email").fields[1].status, .confirmed)
        XCTAssertEqual(held.confirming("email").fields[0].status, .unconfirmed)
        XCTAssertEqual(held.erasing("email").fields.map(\.key), ["name"])
    }

    // MARK: - WP4  G + R: shown equals held; private notes never leave

    func testTicketCarriesExactlyTheBasisAndNothingFromPrivateNotes() async throws {
        let held = basis()
        let issued = try await issue(basis: held)
        XCTAssertTrue(held.shownEqualsHeld(issued.ticket.basis))
        XCTAssertEqual(HavenInviteVerifier.verify(ticket: issued.ticket).code, "valid")

        // A basis edited after signing is a different ticket.
        var tampered = issued.ticket
        tampered.basis[0].value = "Someone Else"
        XCTAssertEqual(HavenInviteVerifier.verify(ticket: tampered).code, "bad_signature")

        // The sentinel from privateNotes is in none of the things that travel.
        let token = try HavenInviteLink.encode(issued.ticket)
        XCTAssertFalse(token.contains(sentinel))
        XCTAssertFalse(try HavenInviteLink.decode(token).basis.contains { $0.value.contains(sentinel) || ($0.origin ?? "").contains(sentinel) })

        let publication = try await publication(for: issued)
        let publicationJSON = String(decoding: try JSONEncoder().encode(publication), as: UTF8.self)
        XCTAssertFalse(publicationJSON.contains(sentinel))

        let vegar = await SimulatedEntity.make("vegar")
        let request = try await contactRequest(from: vegar, to: issued, message: "Hei!")
        let requestJSON = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertFalse(requestJSON.contains(sentinel))
        let endpointPayload = try JSONEncoder().encode(request.contactEndpointPayload())
        XCTAssertFalse(String(decoding: endpointPayload, as: UTF8.self).contains(sentinel))

        let message = HavenInviteCopy.compose(
            ticket: issued.ticket,
            recipientDisplayName: "Vegar Testesen",
            recipientEndpoint: "vegar@example.test",
            link: "https://example.test/i/ABC234",
            channel: "email",
            senderNote: nil
        )
        XCTAssertFalse(message.body.contains(sentinel))
        XCTAssertFalse((message.handoffURL ?? "").contains(sentinel))
    }

    func testShownEqualsHeldComparesAgainstTheBasisNotTheWholeRecord() throws {
        let held = basis()
        // Same fields, different order: still equal.
        XCTAssertTrue(held.shownEqualsHeld(held.basisFields().reversed()))
        // One field fewer than held: not equal — the person would see less than is held.
        XCTAssertFalse(held.shownEqualsHeld(Array(held.basisFields().dropLast())))
        // One field more: not equal — the invitation claims more than is held.
        XCTAssertFalse(held.shownEqualsHeld(held.basisFields() + [HavenInviteBasisField(key: "phone", value: "+4700000000")]))
    }

    // MARK: - WP5  E + F: one message, a tombstone, "besvart — ikke nå"

    func testNeverLeavesAVerifiableTombstoneThatBlocksTheNextTicket() async throws {
        let issued = try await issue()
        let vegar = await SimulatedEntity.make("vegar")
        let never = try await HavenInviteReply.make(to: issued.ticket, decision: .never, by: vegar.owner)
        XCTAssertNil(never.replierKeyAgreementKey, "A refusal carries no key to seal to.")

        let tombstone = try HavenInviteTombstone.make(from: never, forTicket: issued.ticket)
        XCTAssertNoThrow(try tombstone.verify(forTicket: issued.ticket))

        var ledger = HavenInviteTombstoneLedger()
        ledger.record(tombstone)
        ledger.record(tombstone)
        XCTAssertEqual(ledger.tombstones.count, 1)

        // A second ticket from the same issuer to the same audience is refused.
        let descriptor = try XCTUnwrap(IdentityPublicKeySignatureVerifier.descriptor(for: issued.issuer.owner))
        let now = Int(Date().timeIntervalSince1970)
        let again = HavenInviteTicket(
            ticketID: "inv-again", issuer: descriptor, issuerDisplayName: "Kjetil",
            audienceToken: issued.ticket.audienceToken, audienceKind: "email", humanCode: "DEF567",
            createdAt: now, expiresAt: now + 86_400, nonce: Data(repeating: 1, count: 12)
        )
        XCTAssertTrue(ledger.refuses(again))

        // …but not one to someone else, and not one from another issuer.
        var other = again
        other.audienceToken = "aud-someone-else"
        XCTAssertFalse(ledger.refuses(other))
        let otherIssuer = await SimulatedEntity.make("victoria")
        var fromOther = again
        fromOther.issuer = try XCTUnwrap(IdentityPublicKeySignatureVerifier.descriptor(for: otherIssuer.owner))
        XCTAssertFalse(ledger.refuses(fromOther))

        // The tombstone survives the ticket's own expiry: it is judged at reply time.
        let expiredCopy = issued.ticket
        XCTAssertNoThrow(try tombstone.verify(forTicket: expiredCopy))
        let ledgerJSON = try JSONEncoder().encode(ledger)
        let reloaded = try JSONDecoder().decode(HavenInviteTombstoneLedger.self, from: ledgerJSON)
        XCTAssertTrue(reloaded.refuses(again))
        XCTAssertNoThrow(try reloaded.tombstones[0].verify(forTicket: issued.ticket))
    }

    func testForgedOrMisdirectedNeverIsNotATombstone() async throws {
        let issued = try await issue()
        let vegar = await SimulatedEntity.make("vegar")

        // The issuer cannot say "never" on the invitee's behalf.
        let byIssuer = try await HavenInviteReply.make(to: issued.ticket, decision: .never, by: issued.issuer.owner)
        XCTAssertEqual(failureCode { _ = try HavenInviteTombstone.make(from: byIssuer, forTicket: issued.ticket) }, "issuer_mismatch")

        // A reply edited after signing does not verify.
        var edited = try await HavenInviteReply.make(to: issued.ticket, decision: .notNow, by: vegar.owner)
        edited.decision = .never
        XCTAssertEqual(failureCode { _ = try HavenInviteTombstone.make(from: edited, forTicket: issued.ticket) }, "bad_signature")

        // A "never" for another audience cannot be lifted onto this ticket.
        var lifted = try await HavenInviteReply.make(to: issued.ticket, decision: .never, by: vegar.owner)
        lifted.audienceToken = "aud-someone-else"
        XCTAssertEqual(failureCode { _ = try HavenInviteTombstone.make(from: lifted, forTicket: issued.ticket) }, "ticket_mismatch")

        // "Not now" is an answer, not a tombstone.
        let notNow = try await HavenInviteReply.make(to: issued.ticket, decision: .notNow, by: vegar.owner)
        XCTAssertNoThrow(try HavenInvitePublicationVerifier.verifyReply(notNow, forTicket: issued.ticket))
        XCTAssertEqual(failureCode { _ = try HavenInviteTombstone.make(from: notNow, forTicket: issued.ticket) }, "wrong_decision")
        XCTAssertEqual(notNow.decision.lifecycle, .declined)
    }

    func testSenderSeesAnsweredOnlyAndNeverOpened() throws {
        XCTAssertEqual(HavenInviteSenderView(.published), .published)
        XCTAssertEqual(HavenInviteSenderView(.opened), .published, "Opened is not something the sender learns.")
        XCTAssertEqual(HavenInviteSenderView(.accepted), .answered)
        XCTAssertEqual(HavenInviteSenderView(.declined), .answered)
        XCTAssertEqual(HavenInviteSenderView(.expired), .expired)
        XCTAssertEqual(HavenInviteSenderView(.revoked), .revoked)

        let declined = HavenInviteStatusReport(
            ticketID: "inv-1", state: .declined, firstOpenedAt: 1_700_000_000, openCount: 3, respondedAt: 1_700_000_500
        ).projectedForSender()
        let neverAnswered = HavenInviteStatusReport(
            ticketID: "inv-1", state: .declined, firstOpenedAt: 1_700_000_000, openCount: 1, respondedAt: 1_700_000_500
        ).projectedForSender()
        XCTAssertEqual(declined, neverAnswered, "Not now and never look the same to the sender.")
        XCTAssertEqual(declined.displayText, "Besvart — ikke nå")

        let accepted = HavenInviteStatusReport(
            ticketID: "inv-1", state: .accepted, openCount: 5, respondedAt: 1_700_000_500, contactRequestCount: 1
        ).projectedForSender()
        XCTAssertEqual(accepted.view, .answered)
        XCTAssertEqual(accepted.displayText, "Besvart")

        let opened = HavenInviteStatusReport(ticketID: "inv-1", state: .opened, firstOpenedAt: 1_700_000_000, openCount: 2).projectedForSender()
        XCTAssertEqual(opened.view, .published)
        XCTAssertNil(opened.respondedAt)
        let json = String(decoding: try JSONEncoder().encode(opened), as: UTF8.self)
        XCTAssertFalse(json.contains("openCount"))
        XCTAssertFalse(json.contains("firstOpenedAt"))
    }

    // MARK: - T (first half): the acceptance carries the key to seal to

    func testChatAcceptanceCarriesInviteeKeyAgreementKeyUnderSignature() async throws {
        let kjetil = await SimulatedEntity.make("kjetil")
        let vegar = await SimulatedEntity.make("vegar")
        XCTAssertNotNil(vegar.owner.publicKeyAgreementSecureKey, "A simulated entity can be sealed to.")

        let artifact = try await ChatInvitationProofUtility.generateInvitationArtifact(
            chatCellUUID: "chat-cell",
            topic: "general",
            audienceMode: "invited",
            suiteID: "suite",
            persistenceMode: "local",
            inviter: kjetil.owner,
            invited: vegar.owner,
            invitationID: "invitation-1",
            createdAt: "2026-01-01T00:00:00Z",
            expiresAt: "2999-01-01T00:00:00Z",
            nonce: Data(repeating: 0x11, count: 64)
        )
        let acceptance = try await ChatInvitationProofUtility.generateAcceptance(
            for: artifact,
            invitee: vegar.owner,
            acceptanceID: "acceptance-1",
            createdAt: "2026-01-01T00:00:01Z",
            nonce: Data(repeating: 0x12, count: 64)
        )
        XCTAssertEqual(acceptance.inviteeKeyAgreementKey, vegar.owner.publicKeyAgreementSecureKey?.compressedKey)
        let verified = try await ChatInvitationProofUtility.verifyAcceptance(acceptance, for: artifact, expectedChatCellUUID: "chat-cell", identityVault: kjetil.vault)
        XCTAssertTrue(verified)

        // Swapping the key after signing is caught: an attacker cannot make the
        // inviter seal to a key of their choosing.
        var swapped = acceptance
        swapped.inviteeKeyAgreementKey = Data(repeating: 0xEE, count: 32)
        do {
            _ = try await ChatInvitationProofUtility.verifyAcceptance(swapped, for: artifact, expectedChatCellUUID: "chat-cell", identityVault: kjetil.vault)
            XCTFail("A swapped key-agreement key must not verify.")
        } catch {
            // expected
        }

        // On the inviter's side, the identity built from the acceptance can be sealed to.
        let rebuilt = ChatInvitationProofUtility.identity(from: acceptance.inviteeIdentity, keyAgreementKey: acceptance.inviteeKeyAgreementKey)
        XCTAssertEqual(rebuilt.publicKeyAgreementSecureKey?.compressedKey, vegar.owner.publicKeyAgreementSecureKey?.compressedKey)
        XCTAssertEqual(rebuilt.publicKeyAgreementSecureKey?.use, .keyAgreement)

        // And an acceptance from an older app (no key) still verifies — it just cannot be sealed to.
        var legacy = acceptance
        legacy.inviteeKeyAgreementKey = nil
        XCTAssertNil(ChatInvitationProofUtility.identity(from: legacy.inviteeIdentity, keyAgreementKey: legacy.inviteeKeyAgreementKey).publicKeyAgreementSecureKey)
    }

    func testContactRequestCarriesSenderKeyAgreementKeyIntoTheEndpointPayload() async throws {
        let issued = try await issue()
        let vegar = await SimulatedEntity.make("vegar")
        let request = try await contactRequest(from: vegar, to: issued)
        XCTAssertNoThrow(try HavenInvitePublicationVerifier.verifyContactRequest(request, forTicket: issued.ticket))
        XCTAssertEqual(request.senderKeyAgreementKey, vegar.owner.publicKeyAgreementSecureKey?.compressedKey)

        let payload = request.contactEndpointPayload()
        guard case let .object(inner)? = payload["payload"], case let .string(key)? = inner["introKeyAgreementKey"] else {
            return XCTFail("The endpoint payload must carry the key.")
        }
        XCTAssertEqual(Data(base64Encoded: key), vegar.owner.publicKeyAgreementSecureKey?.compressedKey)

        var swapped = request
        swapped.senderKeyAgreementKey = Data(repeating: 0xEE, count: 32)
        XCTAssertEqual(failureCode { try HavenInvitePublicationVerifier.verifyContactRequest(swapped, forTicket: issued.ticket) }, "bad_signature")
    }
}
