// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  InteropFixturesV1Tests.swift
//  PDD_studentoppsett-invitasjon-chat, WP4 (test.interop.fixtures).
//
//  Golden fixtures for the three flows that must work between Swift, Python
//  and Go scaffolds: entity extension, invitation and chat. Each case holds
//  the wire JSON, the exact canonical bytes the signature covers, the signer's
//  public key, the signature, and the verdict Swift reaches.
//
//  Regenerate (Linux, where swift-crypto's Ed25519 is deterministic):
//    HAVEN_WRITE_INTEROP_FIXTURES=1 swift test --filter InteropFixturesV1Tests
//  Verify (any platform, always runs):
//    swift test --filter InteropFixturesV1Tests
//

import Foundation
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import CellBase

final class InteropFixturesV1Tests: XCTestCase {

    // MARK: - Fixed inputs

    /// 2026-10-27T12:00:00Z. Every verdict is computed at this moment.
    static let verifyAt = Date(timeIntervalSince1970: 1_793_102_400)
    static let verifyAtISO = "2026-10-27T12:00:00Z"

    struct Party {
        let name: String
        let uuid: String
        let key: Curve25519.Signing.PrivateKey
        var descriptor: IdentityPublicKeyDescriptor {
            IdentityPublicKeyDescriptor(
                uuid: uuid,
                displayName: name,
                publicKey: key.publicKey.rawRepresentation,
                algorithm: .EdDSA,
                curveType: .Curve25519
            )
        }
        var identity: Identity { ChatInvitationProofUtility.identity(from: descriptor) }
        func sign(_ data: Data) throws -> Data { try key.signature(for: data) }
    }

    static func party(_ name: String, uuid: String) -> Party {
        let seed = Data(SHA256.hash(data: Data("haven-interop-v1/\(name)".utf8)))
        return Party(name: name, uuid: uuid, key: try! Curve25519.Signing.PrivateKey(rawRepresentation: seed))
    }

    static let alice = party("alice", uuid: "6F1C2B0A-0000-4000-8000-00000000A11C")
    static let bob = party("bob", uuid: "6F1C2B0A-0000-4000-8000-000000000B0B")
    static let mallory = party("mallory", uuid: "6F1C2B0A-0000-4000-8000-0000000BAD00")

    static func bytes(_ label: String, count: Int = 32) -> Data {
        var out = Data()
        var counter = 0
        while out.count < count {
            out.append(contentsOf: SHA256.hash(data: Data("haven-interop-v1/\(label)/\(counter)".utf8)))
            counter += 1
        }
        return out.prefix(count)
    }

    /// Strings that break naive encoders: slash, quotes, backslash, control
    /// characters, non-ASCII letters, an astral-plane emoji and HTML-ish text.
    static let stressText = "Hei/hallo \"Ærlig\" \\ sti: a/b?c=d&e<f>\nlinje\tTab æøå ÆØÅ 🙂 é"

    // MARK: - Fixture record

    struct Case {
        var id: String
        var flow: String
        var type: String
        var description: String
        var excludedTopLevelKeys: [String]
        var encoded: Data
        var canonical: Data
        var signer: IdentityPublicKeyDescriptor?
        var signature: Data?
        var signatureValid: Bool
        var verdict: String
        var related: [String: String] = [:]
    }

    static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func verifies(_ signature: Data?, _ payload: Data, _ descriptor: IdentityPublicKeyDescriptor?) -> Bool {
        guard let signature, let descriptor else { return false }
        return IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: payload, descriptor: descriptor)
    }

    static func code(_ error: Error) -> String {
        if let failure = error as? HavenInvitePublicationVerifier.Failure { return failure.code }
        return String(describing: error)
    }

    // MARK: - Builders, one per signed type

    static func enrollmentRequest(signedBy signer: Party = bob, newIdentity: Party = bob) throws -> IdentityEnrollmentRequest {
        var request = IdentityEnrollmentRequest(
            requestID: "req-interop-0001",
            entityBinding: EntityBindingDescriptor(mode: .localEntityAnchor, entityAnchorReference: "cell:///EntityAnchor", bindingID: "bind-0001", audience: "staging.haven.digipomps.org"),
            newIdentity: newIdentity.descriptor,
            requestedDomains: ["private", "scaffold"],
            requestedIdentityContexts: ["default"],
            requestedScopes: ["chat.read", "chat.write"],
            audience: "staging.haven.digipomps.org",
            origin: "https://staging.haven.digipomps.org/link",
            createdAt: "2026-10-27T11:59:00Z",
            expiresAt: "2026-10-27T12:09:00Z",
            nonce: bytes("request-nonce"),
            platform: "python",
            deviceLabel: "Studentens bærbare",
            proof: IdentityEnrollmentRequestProof(byIdentityUUID: signer.uuid, algorithm: .EdDSA, curveType: .Curve25519)
        )
        let requestPayload = try request.canonicalPayloadData()
        request.proof?.signature = try signer.sign(requestPayload)
        return request
    }

    static func enrollmentApproval(for request: IdentityEnrollmentRequest, signedBy signer: Party = alice) throws -> IdentityEnrollmentApproval {
        var approval = IdentityEnrollmentApproval(
            approvalID: "apr-interop-0001",
            requestHash: Data(SHA256.hash(data: try request.canonicalPayloadData())),
            entityBinding: request.entityBinding!,
            subjectIdentity: request.newIdentity,
            approvedDomains: ["private"],
            approvedIdentityContexts: ["default"],
            approvedScopes: ["chat.read", "chat.write"],
            issuerIdentityUUID: alice.uuid,
            issuerType: .existingDevice,
            audience: request.audience,
            origin: request.origin,
            createdAt: "2026-10-27T11:59:30Z",
            expiresAt: "2026-10-27T12:04:30Z",
            jti: "jti-interop-0001",
            freshAuthRequired: true,
            freshAuthMethod: "webauthn",
            freshAuthPerformedAt: "2026-10-27T11:59:25Z",
            freshAuthEvidence: IdentityLinkFreshAuthEvidence(
                method: "webauthn",
                challenge: Data(SHA256.hash(data: try request.canonicalPayloadData())),
                performedAt: "2026-10-27T11:59:25Z",
                credentialID: bytes("credential", count: 16)
            ),
            proof: IdentityEnrollmentApprovalProof(issuerIdentityUUID: signer.uuid, issuerType: .existingDevice, algorithm: .EdDSA, curveType: .Curve25519)
        )
        let approvalPayload = try approval.canonicalPayloadData()
        approval.proof?.signature = try signer.sign(approvalPayload)
        return approval
    }

    static func linkRevocation() throws -> IdentityLinkRevocation {
        var revocation = IdentityLinkRevocation(
            linkID: "apr-interop-0001",
            reason: "Enheten er mistet / stjålet",
            revokedAt: "2026-10-27T11:59:50Z",
            revokedByIdentityUUID: alice.uuid,
            issuerType: .existingDevice,
            proof: IdentityEnrollmentApprovalProof(issuerIdentityUUID: alice.uuid, issuerType: .existingDevice, algorithm: .EdDSA, curveType: .Curve25519)
        )
        let revocationPayload = try revocation.canonicalPayloadData()
        revocation.proof?.signature = try alice.sign(revocationPayload)
        return revocation
    }

    static func ticket(note: String? = "Velkommen til masterprosjektet.", expiresAt: Int = 1_794_312_000, createdAt: Int = 1_793_102_000, signedBy signer: Party = alice) throws -> HavenInviteTicket {
        var ticket = HavenInviteTicket(
            ticketID: "inv-interop-0001",
            issuer: alice.descriptor,
            issuerDisplayName: "Alice",
            issuerContactEndpoint: "ep-interop-1",
            issuerEntityRef: "cell:///EntityAnchor",
            audienceToken: "aud-0c5d1e",
            audienceKind: "email",
            humanCode: "ABC234",
            greetingName: "Bob",
            note: note,
            identityDomain: "private",
            basis: [HavenInviteBasisField(key: "name", value: "Bob Testesen", origin: "Boklisten, 12. sep.")],
            createdAt: createdAt,
            expiresAt: expiresAt,
            nonce: bytes("ticket-nonce", count: 16)
        )
        let payload = try ticket.canonicalPayloadData()
        ticket.proof = HavenSignatureProof(byIdentityUUID: signer.uuid, algorithm: .EdDSA, curveType: .Curve25519, signature: try signer.sign(payload))
        return ticket
    }

    static func publication(for ticket: HavenInviteTicket) throws -> HavenInvitePublication {
        var publication = HavenInvitePublication(
            ticketID: ticket.ticketID,
            humanCode: ticket.humanCode,
            ticketToken: try HavenInviteLink.encode(ticket),
            audienceToken: ticket.audienceToken,
            issuerIdentityUUID: alice.uuid,
            expiresAt: ticket.expiresAt,
            publishedAt: 1_793_102_100,
            statusKey: HavenInviteLink.base64URL(bytes("status-key"))
        )
        publication.proof = HavenSignatureProof(byIdentityUUID: alice.uuid, algorithm: .EdDSA, curveType: .Curve25519, signature: try alice.sign(try publication.canonicalPayloadData()))
        return publication
    }

    static func reply(to ticket: HavenInviteTicket, decision: HavenInviteDecision) throws -> HavenInviteReply {
        var reply = HavenInviteReply(
            replyID: "rp-interop-\(decision.rawValue)",
            ticketID: ticket.ticketID,
            audienceToken: ticket.audienceToken,
            decision: decision,
            replier: bob.descriptor,
            replierKeyAgreementKey: decision == .yes ? bytes("bob-x25519") : nil,
            createdAt: 1_793_102_300,
            nonce: bytes("reply-nonce-\(decision.rawValue)", count: 12)
        )
        reply.proof = HavenSignatureProof(byIdentityUUID: bob.uuid, algorithm: .EdDSA, curveType: .Curve25519, signature: try bob.sign(try reply.canonicalPayloadData()))
        return reply
    }

    static func revocationNotice(for ticket: HavenInviteTicket) throws -> HavenInviteRevocationNotice {
        var notice = HavenInviteRevocationNotice(
            ticketID: ticket.ticketID,
            reason: "Sendt til feil adresse",
            revokedAt: 1_793_102_350,
            issuerIdentityUUID: alice.uuid
        )
        notice.proof = HavenSignatureProof(byIdentityUUID: alice.uuid, algorithm: .EdDSA, curveType: .Curve25519, signature: try alice.sign(try notice.canonicalPayloadData()))
        return notice
    }

    static func contactRequest(for ticket: HavenInviteTicket) throws -> HavenInviteContactRequest {
        var request = HavenInviteContactRequest(
            requestID: "cr-interop-0001",
            ticketID: ticket.ticketID,
            issuerEndpointID: ticket.issuerContactEndpoint!,
            sender: bob.descriptor,
            senderDisplayName: "Bob",
            message: "Takk for invitasjonen!",
            senderKeyAgreementKey: bytes("bob-x25519"),
            createdAt: 1_793_102_310,
            expiresAt: 1_793_707_110,
            nonce: bytes("contact-nonce", count: 16)
        )
        request.proof = HavenSignatureProof(byIdentityUUID: bob.uuid, algorithm: .EdDSA, curveType: .Curve25519, signature: try bob.sign(try request.canonicalPayloadData()))
        return request
    }

    static func chatArtifact(topic: String = "Masterprosjekt HAVEN", expiresAt: String = "2036-10-27T12:00:00Z") throws -> ChatInvitationArtifact {
        var artifact = ChatInvitationArtifact(
            invitationID: "chatinv-interop-0001",
            chatCellUUID: "C4A7C311-0000-4000-8000-00000000C4A7",
            topic: topic,
            audienceMode: "invited",
            suiteID: "haven.chat.v1",
            persistenceMode: "persistent",
            inviterIdentity: alice.descriptor,
            invitedIdentity: bob.descriptor,
            createdAt: "2026-10-27T11:58:00.000Z",
            expiresAt: expiresAt,
            nonce: bytes("chat-invitation-nonce"),
            proof: ChatInvitationArtifactProof(byIdentityUUID: alice.uuid, algorithm: .EdDSA, curveType: .Curve25519)
        )
        let artifactPayload = try artifact.canonicalPayloadData()
        artifact.proof?.signature = try alice.sign(artifactPayload)
        return artifact
    }

    static func chatAcceptance(for artifact: ChatInvitationArtifact, signedBy signer: Party = bob) throws -> ChatInvitationAcceptance {
        var acceptance = ChatInvitationAcceptance(
            acceptanceID: "chatacc-interop-0001",
            invitationID: artifact.invitationID,
            invitationHash: try ChatInvitationProofUtility.invitationHash(for: artifact),
            chatCellUUID: artifact.chatCellUUID,
            inviterIdentityUUID: alice.uuid,
            inviteeIdentity: bob.descriptor,
            inviteeKeyAgreementKey: bytes("bob-x25519"),
            createdAt: "2026-10-27T11:59:10.000Z",
            nonce: bytes("chat-acceptance-nonce"),
            proof: ChatInvitationAcceptanceProof(byIdentityUUID: bob.uuid, algorithm: .EdDSA, curveType: .Curve25519)
        )
        let acceptancePayload = try acceptance.canonicalPayloadData()
        acceptance.proof?.signature = try signer.sign(acceptancePayload)
        return acceptance
    }

    static func signingChallenge(issuedAt: Date = Date(timeIntervalSince1970: 1_793_102_390), validity: TimeInterval = 60) -> IdentitySigningChallenge {
        IdentitySigningChallenge(
            identityUUID: bob.uuid,
            publicKeyFingerprint: bob.identity.signingPublicKeyFingerprint,
            domain: "private",
            resource: "cell:///EntityScaffoldExtension",
            action: "bridge.open",
            audience: "wss://staging.haven.digipomps.org/bridgehead",
            nonce: bytes("challenge-nonce"),
            issuedAt: issuedAt,
            validity: validity
        )
    }

    // MARK: - Case assembly

    static func record<T: Encodable>(
        _ id: String, flow: String, type: String, description: String,
        value: T, excluded: [String], canonical: Data,
        signer: IdentityPublicKeyDescriptor?, signature: Data?, verdict: String,
        related: [String: String] = [:]
    ) throws -> Case {
        Case(
            id: id, flow: flow, type: type, description: description,
            excludedTopLevelKeys: excluded,
            encoded: try jsonEncoder().encode(value),
            canonical: canonical,
            signer: signer, signature: signature,
            signatureValid: verifies(signature, canonical, signer),
            verdict: verdict, related: related
        )
    }

    static func ticketVerdict(_ ticket: HavenInviteTicket) -> String {
        HavenInviteVerifier.verify(ticket: ticket, now: verifyAt).code
    }

    static func verdict(_ body: () throws -> Void) -> String {
        do { try body(); return "valid" } catch { return code(error) }
    }

    static func asyncVerdict(_ body: () async throws -> Bool) async -> String {
        do { return try await body() ? "valid" : "invalid" } catch { return code(error) }
    }

    static func buildCases() async throws -> [Case] {
        var cases: [Case] = []

        // Entity extension
        let request = try enrollmentRequest()
        let approval = try enrollmentApproval(for: request)
        let requestHash = Data(SHA256.hash(data: try request.canonicalPayloadData())).base64EncodedString()
        cases.append(try record("extend.request.valid", flow: "extend", type: "IdentityEnrollmentRequest",
            description: "Ny nøkkel (Bob) ber om å bli lenket til entiteten. Signert av den nye nøkkelen.",
            value: request, excluded: ["proof"], canonical: try request.canonicalPayloadData(),
            signer: request.newIdentity, signature: request.proof?.signature, verdict: "valid",
            related: [
                "requestHashBase64": requestHash,
                // Binding's EntityScaffoldExtensionCell binds its approval to this
                // instead: the UTF-8 of the hex SHA-256 of the base64 canonical request.
                "bindingRequestHashBase64": Data(HavenInviteLink.sha256Hex(try request.canonicalPayloadData().base64EncodedString()).utf8).base64EncodedString(),
                "humanCode": HavenInviteLink.humanCode(from: request.requestID + request.audience)
            ]))

        var tamperedRequest = request
        tamperedRequest.requestedScopes.append("admin")
        cases.append(try record("extend.request.tampered", flow: "extend", type: "IdentityEnrollmentRequest",
            description: "Et omfang er lagt til etter signering. Signaturen skal ikke holde.",
            value: tamperedRequest, excluded: ["proof"], canonical: try tamperedRequest.canonicalPayloadData(),
            signer: tamperedRequest.newIdentity, signature: tamperedRequest.proof?.signature, verdict: "bad_signature"))

        let foreignSigned = try enrollmentRequest(signedBy: mallory)
        cases.append(try record("extend.request.wrong-key", flow: "extend", type: "IdentityEnrollmentRequest",
            description: "Signert av en annen nøkkel enn den som står i newIdentity.",
            value: foreignSigned, excluded: ["proof"], canonical: try foreignSigned.canonicalPayloadData(),
            signer: foreignSigned.newIdentity, signature: foreignSigned.proof?.signature, verdict: "bad_signature"))

        cases.append(try record("extend.approval.valid", flow: "extend", type: "IdentityEnrollmentApproval",
            description: "Eksisterende enhet (Alice) godkjenner. requestHash = SHA-256 av forespørselens kanoniske bytes.",
            value: approval, excluded: ["proof"], canonical: try approval.canonicalPayloadData(),
            signer: alice.descriptor, signature: approval.proof?.signature, verdict: "valid",
            related: ["request": "extend.request.valid", "requestHashBase64": requestHash]))

        let approvalByMallory = try enrollmentApproval(for: request, signedBy: mallory)
        cases.append(try record("extend.approval.wrong-key", flow: "extend", type: "IdentityEnrollmentApproval",
            description: "Godkjenning signert av en nøkkel som ikke er utstederen.",
            value: approvalByMallory, excluded: ["proof"], canonical: try approvalByMallory.canonicalPayloadData(),
            signer: alice.descriptor, signature: approvalByMallory.proof?.signature, verdict: "bad_signature"))

        let revocation = try linkRevocation()
        cases.append(try record("extend.revocation.valid", flow: "extend", type: "IdentityLinkRevocation",
            description: "Alice trekker lenken tilbake. Begrunnelsen inneholder skråstrek og æøå.",
            value: revocation, excluded: ["proof"], canonical: try revocation.canonicalPayloadData(),
            signer: alice.descriptor, signature: revocation.proof?.signature, verdict: "valid"))

        // Invitation
        let ticket = try ticket()
        cases.append(try record("invite.ticket.valid", flow: "invite", type: "HavenInviteTicket",
            description: "Signert invitasjon. Kodede nøkler er korte (v, t, is, ...). pf er utelatt fra signerte bytes.",
            value: ticket, excluded: ["pf"], canonical: try ticket.canonicalPayloadData(),
            signer: ticket.issuer, signature: ticket.proof?.signature, verdict: ticketVerdict(ticket),
            related: ["ticketToken": try HavenInviteLink.encode(ticket)]))

        let stressTicket = try self.ticket(note: stressText)
        cases.append(try record("invite.ticket.stress-text", flow: "invite", type: "HavenInviteTicket",
            description: "Notatet har skråstrek, anførselstegn, bakstrek, linjeskift, tab, æøå og emoji.",
            value: stressTicket, excluded: ["pf"], canonical: try stressTicket.canonicalPayloadData(),
            signer: stressTicket.issuer, signature: stressTicket.proof?.signature, verdict: ticketVerdict(stressTicket)))

        var tamperedTicket = ticket
        tamperedTicket.issuerDisplayName = "Alice (admin)"
        cases.append(try record("invite.ticket.tampered", flow: "invite", type: "HavenInviteTicket",
            description: "Avsendernavnet er endret etter signering.",
            value: tamperedTicket, excluded: ["pf"], canonical: try tamperedTicket.canonicalPayloadData(),
            signer: tamperedTicket.issuer, signature: tamperedTicket.proof?.signature, verdict: ticketVerdict(tamperedTicket)))

        let expiredTicket = try self.ticket(expiresAt: 1_793_100_000, createdAt: 1_792_000_000)
        cases.append(try record("invite.ticket.expired", flow: "invite", type: "HavenInviteTicket",
            description: "Gyldig signatur, men utløpt ved verifyAt.",
            value: expiredTicket, excluded: ["pf"], canonical: try expiredTicket.canonicalPayloadData(),
            signer: expiredTicket.issuer, signature: expiredTicket.proof?.signature, verdict: ticketVerdict(expiredTicket)))

        let tooLong = try self.ticket(expiresAt: 1_793_102_000 + 91 * 86_400)
        cases.append(try record("invite.ticket.ttl-too-long", flow: "invite", type: "HavenInviteTicket",
            description: "Gyldig signatur, men påstår å leve over 90 dager.",
            value: tooLong, excluded: ["pf"], canonical: try tooLong.canonicalPayloadData(),
            signer: tooLong.issuer, signature: tooLong.proof?.signature, verdict: ticketVerdict(tooLong)))

        let ticketByMallory = try self.ticket(signedBy: mallory)
        cases.append(try record("invite.ticket.wrong-key", flow: "invite", type: "HavenInviteTicket",
            description: "Beviset oppgir Mallory, men utstederen i billetten er Alice.",
            value: ticketByMallory, excluded: ["pf"], canonical: try ticketByMallory.canonicalPayloadData(),
            signer: ticketByMallory.issuer, signature: ticketByMallory.proof?.signature, verdict: ticketVerdict(ticketByMallory)))

        let publication = try publication(for: ticket)
        cases.append(try record("invite.publication.valid", flow: "invite", type: "HavenInvitePublication",
            description: "Alice publiserer billetten til noden. ticketToken er base64url av billetten (JSONEncoder, sortedKeys).",
            value: publication, excluded: ["proof"], canonical: try publication.canonicalPayloadData(),
            signer: alice.descriptor, signature: publication.proof?.signature,
            verdict: verdict { _ = try HavenInvitePublicationVerifier.verifyPublication(publication, now: verifyAt) },
            related: ["ticket": "invite.ticket.valid"]))

        var hijacked = publication
        hijacked.humanCode = "ZZZ999"
        cases.append(try record("invite.publication.code-swapped", flow: "invite", type: "HavenInvitePublication",
            description: "Noen har byttet kortkoden. Skal avvises før signaturen sjekkes.",
            value: hijacked, excluded: ["proof"], canonical: try hijacked.canonicalPayloadData(),
            signer: alice.descriptor, signature: hijacked.proof?.signature,
            verdict: verdict { _ = try HavenInvitePublicationVerifier.verifyPublication(hijacked, now: verifyAt) },
            related: ["ticket": "invite.ticket.valid"]))

        for decision in [HavenInviteDecision.yes, .notNow, .never] {
            let reply = try reply(to: ticket, decision: decision)
            cases.append(try record("invite.reply.\(decision.rawValue)", flow: "invite", type: "HavenInviteReply",
                description: "Bobs svar: \(decision.rawValue).",
                value: reply, excluded: ["proof"], canonical: try reply.canonicalPayloadData(),
                signer: bob.descriptor, signature: reply.proof?.signature,
                verdict: verdict { try HavenInvitePublicationVerifier.verifyReply(reply, forTicket: ticket, now: verifyAt) },
                related: ["ticket": "invite.ticket.valid"]))
        }

        var liftedReply = try reply(to: ticket, decision: .never)
        liftedReply.audienceToken = "aud-someone-else"
        cases.append(try record("invite.reply.wrong-audience", flow: "invite", type: "HavenInviteReply",
            description: "Et svar flyttet over på en annen mottaker.",
            value: liftedReply, excluded: ["proof"], canonical: try liftedReply.canonicalPayloadData(),
            signer: bob.descriptor, signature: liftedReply.proof?.signature,
            verdict: verdict { try HavenInvitePublicationVerifier.verifyReply(liftedReply, forTicket: ticket, now: verifyAt) },
            related: ["ticket": "invite.ticket.valid"]))

        let notice = try revocationNotice(for: ticket)
        cases.append(try record("invite.revocation.valid", flow: "invite", type: "HavenInviteRevocationNotice",
            description: "Alice trekker invitasjonen tilbake.",
            value: notice, excluded: ["proof"], canonical: try notice.canonicalPayloadData(),
            signer: alice.descriptor, signature: notice.proof?.signature,
            verdict: verdict { try HavenInvitePublicationVerifier.verifyRevocation(notice, againstIssuerOf: ticket) },
            related: ["ticket": "invite.ticket.valid"]))

        var forgedNotice = notice
        let forgedNoticePayload = try notice.canonicalPayloadData()
        forgedNotice.proof?.signature = try mallory.sign(forgedNoticePayload)
        cases.append(try record("invite.revocation.forged", flow: "invite", type: "HavenInviteRevocationNotice",
            description: "Tilbaketrekking signert av Mallory i Alices navn.",
            value: forgedNotice, excluded: ["proof"], canonical: try forgedNotice.canonicalPayloadData(),
            signer: alice.descriptor, signature: forgedNotice.proof?.signature,
            verdict: verdict { try HavenInvitePublicationVerifier.verifyRevocation(forgedNotice, againstIssuerOf: ticket) },
            related: ["ticket": "invite.ticket.valid"]))

        let contact = try contactRequest(for: ticket)
        cases.append(try record("invite.contact-request.valid", flow: "invite", type: "HavenInviteContactRequest",
            description: "Bob ber om kontakt via endepunktet i billetten.",
            value: contact, excluded: ["proof"], canonical: try contact.canonicalPayloadData(),
            signer: bob.descriptor, signature: contact.proof?.signature,
            verdict: verdict { try HavenInvitePublicationVerifier.verifyContactRequest(contact, forTicket: ticket, now: verifyAt) },
            related: ["ticket": "invite.ticket.valid"]))

        // Chat
        let artifact = try chatArtifact()
        let invitationHash = try ChatInvitationProofUtility.invitationHash(for: artifact).base64EncodedString()
        cases.append(try record("chat.invitation.valid", flow: "chat", type: "ChatInvitationArtifact",
            description: "Alice inviterer Bob til en ChatCell. invitationHash = SHA-256 av de kanoniske bytene.",
            value: artifact, excluded: ["proof"], canonical: try artifact.canonicalPayloadData(),
            signer: alice.descriptor, signature: artifact.proof?.signature,
            verdict: await asyncVerdict { try await ChatInvitationProofUtility.verifyInvitationArtifact(artifact) },
            related: ["invitationHashBase64": invitationHash]))

        let stressArtifact = try chatArtifact(topic: stressText)
        cases.append(try record("chat.invitation.stress-text", flow: "chat", type: "ChatInvitationArtifact",
            description: "Emnet har skråstrek, anførselstegn, bakstrek, linjeskift, tab, æøå og emoji.",
            value: stressArtifact, excluded: ["proof"], canonical: try stressArtifact.canonicalPayloadData(),
            signer: alice.descriptor, signature: stressArtifact.proof?.signature,
            verdict: await asyncVerdict { try await ChatInvitationProofUtility.verifyInvitationArtifact(stressArtifact) }))

        var tamperedArtifact = artifact
        tamperedArtifact.persistenceMode = "ephemeral"
        cases.append(try record("chat.invitation.tampered", flow: "chat", type: "ChatInvitationArtifact",
            description: "Lagringsmodus endret etter signering.",
            value: tamperedArtifact, excluded: ["proof"], canonical: try tamperedArtifact.canonicalPayloadData(),
            signer: alice.descriptor, signature: tamperedArtifact.proof?.signature,
            verdict: await asyncVerdict { try await ChatInvitationProofUtility.verifyInvitationArtifact(tamperedArtifact) }))

        let acceptance = try chatAcceptance(for: artifact)
        cases.append(try record("chat.acceptance.valid", flow: "chat", type: "ChatInvitationAcceptance",
            description: "Bob aksepterer. Bærer Bobs nøkkel for nøkkelavtale.",
            value: acceptance, excluded: ["proof"], canonical: try acceptance.canonicalPayloadData(),
            signer: bob.descriptor, signature: acceptance.proof?.signature,
            verdict: await asyncVerdict { try await ChatInvitationProofUtility.verifyAcceptance(acceptance, for: artifact) },
            related: ["invitation": "chat.invitation.valid", "invitationHashBase64": invitationHash]))

        let acceptanceByMallory = try chatAcceptance(for: artifact, signedBy: mallory)
        cases.append(try record("chat.acceptance.wrong-key", flow: "chat", type: "ChatInvitationAcceptance",
            description: "Aksept signert av en annen enn den inviterte.",
            value: acceptanceByMallory, excluded: ["proof"], canonical: try acceptanceByMallory.canonicalPayloadData(),
            signer: bob.descriptor, signature: acceptanceByMallory.proof?.signature,
            verdict: await asyncVerdict { try await ChatInvitationProofUtility.verifyAcceptance(acceptanceByMallory, for: artifact) },
            related: ["invitation": "chat.invitation.valid"]))

        // Bridge identity proof
        for (suffix, challenge, description) in [
            ("valid", signingChallenge(), "Bob beviser kontroll over nøkkelen før broen åpnes."),
            ("expired", signingChallenge(issuedAt: Date(timeIntervalSince1970: 1_793_102_000)), "Utløpt ved verifyAt."),
            ("too-long", signingChallenge(validity: 600), "Gyldighet over 60 sekunder."),
        ] {
            let data = try jsonEncoder().encode(challenge)
            let signature = try bob.sign(data)
            cases.append(try record("bridge.signing-challenge.\(suffix)", flow: "bridge", type: "IdentitySigningChallenge",
                description: description + " De signerte bytene er JSONEncoder med sortedKeys, ikke JSONSerialization.",
                value: challenge, excluded: [], canonical: data,
                signer: bob.descriptor, signature: signature,
                verdict: verdict { _ = try IdentitySigningChallenge.validateSigningData(data, for: bob.identity, now: verifyAt) }))
        }

        // Bridge channel admission (org.haven.bridge-channel.v1), the four WS auth
        // messages. Values that are random in production are fixed here.
        cases.append(contentsOf: try bridgeChannelCases())

        // Entity extension completion: same-entity credential, holder-bound
        // presentation and the envelope EntityAnchor's identityLinks.completeEnrollment takes.
        cases.append(contentsOf: try await extendCompletionCases(request: request, approval: approval))
        cases.append(contentsOf: try genesisCases())

        return cases
    }

    // MARK: - Entity extension completion (VC chain)

    static let presentationChallenge = bytes("presentation-challenge")
    static let presentationDomain = "staging.haven.digipomps.org"

    static func rfc3339(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    /// VCClaim signs JSONEncoder(.withoutEscapingSlashes, .sortedKeys) of itself
    /// with userInfo["skipProof"] = true (VCClaim.canonicalUnsignedClaimData).
    static func unsignedClaimData(_ claim: VCClaim) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        encoder.userInfo[CodingUserInfoKey(rawValue: "skipProof")!] = true
        return try encoder.encode(claim)
    }

    static func sameEntityCredential(request: IdentityEnrollmentRequest, approval: IdentityEnrollmentApproval, issuer: Party = alice) async throws -> VCClaim {
        let subject = SameEntityIdentityLinkCredentialSubject(
            id: try IdentityLinkProtocolService.did(for: request.newIdentity),
            entityBinding: approval.entityBinding,
            linkedIdentity: request.newIdentity,
            approvedDomains: approval.approvedDomains,
            approvedIdentityContexts: approval.approvedIdentityContexts,
            approvedScopes: approval.approvedScopes,
            enrollmentRequestHash: try IdentityLinkProtocolService.requestHash(for: request),
            assuranceSource: "fresh_auth_and_possession",
            assuranceLevel: "high",
            validUntil: approval.expiresAt,
            revocationReference: "cell:///EntityAnchor/identityLinks/revocations/apr-interop-0001")
        var claim = try await VCClaim(
            type: "SameEntityIdentityLinkCredential",
            issuerIdentity: issuer.identity,
            subjectIdentity: IdentityLinkProtocolService.identity(from: request.newIdentity),
            credentialSubject: try IdentityLinkProtocolService.object(from: subject))
        claim.id = "cell:///identity/\(request.newIdentity.uuid)/claims/C1A10000-0000-4000-8000-000000000001"
        claim.issuanceDate = rfc3339("2026-10-27T11:59:30Z")
        claim.proof.created = rfc3339("2026-10-27T11:59:30Z")
        claim.proof.signatureData = try issuer.sign(try unsignedClaimData(claim))
        return claim
    }

    static func presentation(of credential: VCClaim, holder: Party = bob, challenge: Data = presentationChallenge, domain: String = presentationDomain) async throws -> VCPresentation {
        var presentation = try await VCPresentation(
            type: "SameEntityIdentityLinkPresentation",
            holderIdentity: holder.identity, subjectIdentity: holder.identity,
            verifiableCredentials: [credential])
        presentation.id = "cell:///identity/\(holder.uuid)/claims/9E5E0000-0000-4000-8000-000000000001"
        presentation.holder = .reference(try holder.identity.did())
        presentation.challenge = challenge
        presentation.domain = domain
        presentation.holderBinding = holder.descriptor
        presentation.proof = VCProof(proofPurpose: .authentication, issuerIdentity: holder.identity)
        presentation.proof.created = rfc3339("2026-10-27T11:59:40Z")
        presentation.proof.signatureData = try holder.sign(try presentation.canonicalPayloadData())
        return presentation
    }

    /// enrollmentApproval with changes, re-signed by `issuer`.
    static func approvalVariant(for request: IdentityEnrollmentRequest, issuer: Party = alice, _ change: (inout IdentityEnrollmentApproval) -> Void) throws -> IdentityEnrollmentApproval {
        var approval = try enrollmentApproval(for: request)
        change(&approval)
        approval.issuerIdentityUUID = issuer.uuid
        approval.proof = IdentityEnrollmentApprovalProof(issuerIdentityUUID: issuer.uuid, issuerType: approval.issuerType, algorithm: .EdDSA, curveType: .Curve25519)
        let payload = try approval.canonicalPayloadData()
        approval.proof?.signature = try issuer.sign(payload)
        return approval
    }

    static func completionEnvelope(request: IdentityEnrollmentRequest, approval: IdentityEnrollmentApproval, credential: VCClaim, presentation: VCPresentation, issuer: Party = alice, expectedChallenge: Data = presentationChallenge) -> IdentityLinkCompletionEnvelope {
        IdentityLinkCompletionEnvelope(
            request: request, approval: approval,
            sameEntityCredential: credential, presentation: presentation,
            issuerIdentity: issuer.descriptor,
            expectedAudience: request.audience, expectedOrigin: request.origin,
            expectedPresentationChallenge: expectedChallenge,
            expectedPresentationDomain: presentationDomain)
    }

    /// IdentityLinkCompletionError case name without its associated values.
    static func linkCode(_ error: Error) -> String {
        String(String(describing: error).prefix { $0 != "(" })
    }

    static func completionVerdict(_ envelope: IdentityLinkCompletionEnvelope) async -> (String, IdentityLinkRecord?) {
        do {
            let result = try await IdentityLinkProtocolService.verifyCompletion(envelope, now: verifyAt)
            return ("valid", result.record)
        } catch {
            return (linkCode(error), nil)
        }
    }

    // MARK: - Genesis seal

    static let genesisAnchorID = "A0C40000-0000-4000-8000-0000000000A1"

    static func genesisRecord(for initiator: Party, sealedAt: String) -> IdentityLinkRecord {
        IdentityLinkRecord(
            linkID: EntityGenesisService.genesisLinkID(anchorID: genesisAnchorID),
            entityBinding: EntityBindingDescriptor(mode: .localEntityAnchor, entityAnchorReference: EntityGenesisService.anchorReference),
            linkedIdentity: initiator.descriptor,
            approvedDomains: ["private"],
            approvedIdentityContexts: [],
            approvedScopes: EntityGenesisService.initiatorScopes,
            issuerIdentityUUID: initiator.uuid,
            issuerType: .existingDevice,
            status: .active,
            linkedAt: sealedAt
        )
    }

    static func genesisVerdict(_ seal: EntityGenesisSeal, _ record: IdentityLinkRecord) -> String {
        do { try EntityGenesisService.verify(seal: seal, record: record); return "valid" } catch {
            return String(String(describing: error).prefix { $0 != "(" })
        }
    }

    /// The seal EntityAnchor writes at identityLinks.genesis, built the way
    /// EntityGenesisService.seal builds it, with Alice as the initiator.
    static func genesisCases() throws -> [Case] {
        let sealedAt = IdentityLinkProtocolService.iso8601(Date(timeIntervalSince1970: 1_793_102_300))
        let link = genesisRecord(for: alice, sealedAt: sealedAt)
        var seal = EntityGenesisSeal(
            anchorID: genesisAnchorID, sealedAt: sealedAt, trigger: .onboarding,
            linkID: link.linkID, initiatorIdentityUUID: alice.uuid
        )
        let payload = try seal.canonicalPayloadData()
        seal.proof = IdentityEnrollmentApprovalProof(
            issuerIdentityUUID: alice.uuid, issuerType: .existingDevice,
            algorithm: .EdDSA, curveType: .Curve25519, signature: try alice.sign(payload)
        )
        let recordBase64 = try jsonEncoder().encode(link).base64EncodedString()
        var cases: [Case] = []
        cases.append(try record("extend.genesis.valid", flow: "extend", type: "EntityGenesisSeal",
            description: "Ankeret forsegles til Alice, som startet entiteten. Signert av Alice, og peker på genesis-lenken.",
            value: seal, excluded: ["proof"], canonical: payload,
            signer: alice.descriptor, signature: seal.proof?.signature,
            verdict: genesisVerdict(seal, link),
            related: ["recordBase64": recordBase64, "recordKeypath": EntityGenesisService.recordKeypath(linkID: link.linkID)]))

        var tampered = seal
        tampered.trigger = .firstPersist
        cases.append(try record("extend.genesis.tampered", flow: "extend", type: "EntityGenesisSeal",
            description: "Utløseren er endret etter signering. Forseglingen skal ikke holde.",
            value: tampered, excluded: ["proof"], canonical: try tampered.canonicalPayloadData(),
            signer: alice.descriptor, signature: tampered.proof?.signature,
            verdict: genesisVerdict(tampered, link),
            related: ["recordBase64": recordBase64]))

        let bobRecord = genesisRecord(for: bob, sealedAt: sealedAt)
        cases.append(try record("extend.genesis.wrong-record", flow: "extend", type: "EntityGenesisSeal",
            description: "Riktig forsegling, men lenken den leses sammen med gjelder Bob. Den skal avvises.",
            value: seal, excluded: ["proof"], canonical: payload,
            signer: alice.descriptor, signature: seal.proof?.signature,
            verdict: genesisVerdict(seal, bobRecord),
            related: ["recordBase64": try jsonEncoder().encode(bobRecord).base64EncodedString()]))
        return cases
    }

    static func extendCompletionCases(request: IdentityEnrollmentRequest, approval: IdentityEnrollmentApproval) async throws -> [Case] {
        var cases: [Case] = []
        let credential = try await sameEntityCredential(request: request, approval: approval)
        let presentation = try await presentation(of: credential)
        let dids = [
            "issuerDID": try IdentityLinkProtocolService.did(for: alice.descriptor),
            "holderDID": try IdentityLinkProtocolService.did(for: bob.descriptor),
        ]

        cases.append(try record("extend.credential.valid", flow: "extend", type: "VCClaim",
            description: "Alice utsteder et SameEntityIdentityLinkCredential til Bobs nye nøkkel. Signert over JSONEncoder(sortedKeys, withoutEscapingSlashes) uten proof; uuid kodes ikke.",
            value: credential, excluded: ["proof"], canonical: try unsignedClaimData(credential),
            signer: alice.descriptor, signature: credential.proof.signatureData,
            verdict: await asyncVerdict { try await credential.verify(issuer: alice.identity) },
            related: dids))

        var tamperedCredential = try await sameEntityCredential(request: request, approval: approval)
        tamperedCredential.credentialSubject["assuranceLevel"] = .string("highest")
        cases.append(try record("extend.credential.tampered", flow: "extend", type: "VCClaim",
            description: "credentialSubject er endret etter signering.",
            value: tamperedCredential, excluded: ["proof"], canonical: try unsignedClaimData(tamperedCredential),
            signer: alice.descriptor, signature: tamperedCredential.proof.signatureData,
            verdict: await asyncVerdict { try await tamperedCredential.verify(issuer: alice.identity) }))

        cases.append(try record("extend.presentation.valid", flow: "extend", type: "VCPresentation",
            description: "Bob viser fram credentialet, bundet til tjenerens utfordring og domene. Signert over JSONEncoder(sortedKeys, withoutEscapingSlashes) uten proof; verifiableCredential har med sine proof.",
            value: presentation, excluded: ["proof"], canonical: try presentation.canonicalPayloadData(),
            signer: bob.descriptor, signature: presentation.proof.signatureData,
            verdict: await asyncVerdict { try await presentation.verifyHolderProof(expectedChallenge: presentationChallenge, expectedDomain: presentationDomain) },
            related: dids))

        let otherDomain = try await self.presentation(of: credential, domain: "evil.example")
        cases.append(try record("extend.presentation.wrong-domain", flow: "extend", type: "VCPresentation",
            description: "Presentasjonen er laget for et annet domene enn tjeneren venter.",
            value: otherDomain, excluded: ["proof"], canonical: try otherDomain.canonicalPayloadData(),
            signer: bob.descriptor, signature: otherDomain.proof.signatureData,
            verdict: await asyncVerdict { try await otherDomain.verifyHolderProof(expectedChallenge: presentationChallenge, expectedDomain: presentationDomain) }))

        func completion(_ id: String, _ description: String, _ envelope: IdentityLinkCompletionEnvelope) async throws -> Case {
            let (verdict, linkRecord) = await completionVerdict(envelope)
            var related: [String: String] = ["linkID": envelope.approval.approvalID]
            if let linkRecord {
                related["recordBase64"] = try jsonEncoder().encode(linkRecord).base64EncodedString()
            }
            return try record("extend.completion.\(id)", flow: "extend", type: "IdentityLinkCompletionEnvelope",
                description: description + " Verdikt fra IdentityLinkProtocolService.verifyCompletion uten brukte jti. Kanoniske bytes er presentasjonens.",
                value: envelope, excluded: [], canonical: try envelope.presentation.canonicalPayloadData(),
                signer: envelope.presentation.holderBinding, signature: envelope.presentation.proof.signatureData,
                verdict: verdict, related: related)
        }

        cases.append(try await completion("valid", "Hele kjeden: forespørsel, godkjenning, credential og presentasjon.",
            completionEnvelope(request: request, approval: approval, credential: credential, presentation: presentation)))

        let escalated = try approvalVariant(for: request) { $0.approvedScopes = ["chat.read", "admin"] }
        let escalatedCredential = try await sameEntityCredential(request: request, approval: escalated)
        cases.append(try await completion("scope-escalation", "Godkjenningen gir et omfang som ikke ble bedt om.",
            completionEnvelope(request: request, approval: escalated, credential: escalatedCredential,
                presentation: try await self.presentation(of: escalatedCredential))))

        let sameKey = try approvalVariant(for: request, issuer: bob) { _ in }
        let sameKeyCredential = try await sameEntityCredential(request: request, approval: sameKey, issuer: bob)
        cases.append(try await completion("same-key", "Den nye nøkkelen godkjenner seg selv.",
            completionEnvelope(request: request, approval: sameKey, credential: sameKeyCredential,
                presentation: try await self.presentation(of: sameKeyCredential), issuer: bob)))

        let expired = try approvalVariant(for: request) { $0.expiresAt = "2026-10-27T11:59:59Z" }
        let expiredCredential = try await sameEntityCredential(request: request, approval: expired)
        cases.append(try await completion("expired-approval", "Godkjenningen gikk ut før tjeneren så den.",
            completionEnvelope(request: request, approval: expired, credential: expiredCredential,
                presentation: try await self.presentation(of: expiredCredential))))

        cases.append(try await completion("tampered-credential", "Credentialet er endret etter signering.",
            completionEnvelope(request: request, approval: approval, credential: tamperedCredential,
                presentation: try await self.presentation(of: tamperedCredential))))

        cases.append(try await completion("holder-mismatch", "Mallory viser fram Bobs credential.",
            completionEnvelope(request: request, approval: approval, credential: credential,
                presentation: try await self.presentation(of: credential, holder: mallory))))

        cases.append(try await completion("wrong-challenge", "Presentasjonen er bundet til en annen utfordring enn tjeneren ga.",
            completionEnvelope(request: request, approval: approval, credential: credential,
                presentation: presentation, expectedChallenge: bytes("other-challenge"))))

        return cases
    }

    typealias ChannelAuth = BridgeChannelAuthentication

    static func channelEnvelope<T: Encodable>(_ name: String, _ value: T) throws -> Data {
        let command = BridgeCommand(cmd: name, payload: .string(String(decoding: try ChannelAuth.encode(value), as: UTF8.self)), cid: 0)
        return try ChannelAuth.encode(command)
    }

    static func channelHello(_ party: Party) throws -> ChannelAuth.Hello {
        let object: [String: Any] = [
            "profile": ChannelAuth.profile,
            "identity": ["uuid": party.uuid, "algorithm": "EdDSA", "curve": "Curve25519",
                         "publicKey": party.key.publicKey.rawRepresentation.base64EncodedString()],
            "clientNonce": bytes("channel-client-nonce").base64EncodedString(),
        ]
        return try JSONDecoder().decode(ChannelAuth.Hello.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func bridgeChannelCases() throws -> [Case] {
        var cases: [Case] = []
        let endpoint = try ChannelAuth.Endpoint(
            url: URL(string: "wss://staging.haven.digipomps.org/bridgehead/6F1C2B0A-0000-4000-8000-00000000A11C/EntityScaffoldExtension")!,
            domain: "bridge")
        for (suffix, issuedMs, signer, description) in [
            ("valid", Int64(1_793_102_399_123), bob, "Bob åpner en autentisert bro. issuedAt har millisekunder, så de signerte bytene har desimaltall."),
            ("whole-second", Int64(1_793_102_399_000), bob, "Samme, med hele sekunder."),
            ("wrong-key", Int64(1_793_102_399_123), mallory, "Beviset er signert av en annen nøkkel enn den i hello."),
        ] {
            let hello = try channelHello(bob)
            let transcript = ChannelAuth.Transcript(
                profile: ChannelAuth.profile, endpoint: endpoint, identity: hello.identity,
                clientNonce: hello.clientNonce, serverNonce: bytes("channel-server-nonce"),
                sessionID: "5E55A1D0-0000-4000-8000-000000000001", generation: "6E4E0000-0000-4000-8000-000000000002",
                direction: "client-to-server", issuedAtMilliseconds: issuedMs,
                channelExpiresAtMilliseconds: issuedMs + Int64(ChannelAuth.channelLifetime * 1000))
            let signingData = try ChannelAuth.signingData(transcript)
            let challenge = ChannelAuth.Challenge(transcript: transcript, signingData: signingData)
            let signature = try signer.sign(signingData)
            let proof = ChannelAuth.Proof(sessionID: transcript.sessionID, generation: transcript.generation, signature: signature)
            let digest = ChannelAuth.digest(try ChannelAuth.encode(transcript))
            let accepted = ChannelAuth.Authenticated(sessionID: transcript.sessionID, generation: transcript.generation, transcriptDigest: digest)
            let signatureValid = verifies(signature, signingData, try decodeDescriptor(hello.identity))
            let challengeVerdict = verdict {
                _ = try IdentitySigningChallenge.validateSigningData(signingData, for: hello.identity.makeIdentity(),
                    now: Date(timeIntervalSince1970: Double(issuedMs) / 1000 + 1))
            }
            var item = Case(
                id: "bridge.channel-auth.\(suffix)", flow: "bridge", type: "BridgeChannelAuthV1",
                description: description + " Meldingene er JSONEncoder med sortedKeys og withoutEscapingSlashes; de signerte bytene er IdentitySigningChallenge (med skråstrek-escaping).",
                excludedTopLevelKeys: [],
                encoded: try ChannelAuth.encode(transcript),
                canonical: signingData,
                signer: try decodeDescriptor(hello.identity), signature: signature,
                signatureValid: signatureValid,
                verdict: signatureValid ? challengeVerdict : "invalidProof")
            item.related = [
                "helloEnvelopeBase64": try channelEnvelope("channelAuthHello", hello).base64EncodedString(),
                "challengeEnvelopeBase64": try channelEnvelope("channelAuthChallenge", challenge).base64EncodedString(),
                "proofEnvelopeBase64": try channelEnvelope("channelAuthProof", proof).base64EncodedString(),
                "acceptedEnvelopeBase64": try channelEnvelope("channelAuthAccepted", accepted).base64EncodedString(),
                "transcriptDigestHex": digest,
                "endpointAudience": endpoint.audience,
            ]
            cases.append(item)
        }
        return cases
    }

    static func decodeDescriptor(_ identity: ChannelAuth.PublicIdentity) throws -> IdentityPublicKeyDescriptor {
        IdentityPublicKeyDescriptor(uuid: identity.uuid, publicKey: identity.publicKey, algorithm: identity.algorithm, curveType: identity.curve)
    }

    // MARK: - Files

    static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/interop/v1", isDirectory: true)
    }

    static func descriptorObject(_ descriptor: IdentityPublicKeyDescriptor) throws -> Any {
        try JSONSerialization.jsonObject(with: try jsonEncoder().encode(descriptor))
    }

    static func fileObject(_ item: Case) throws -> [String: Any] {
        var object: [String: Any] = [
            "id": item.id,
            "flow": item.flow,
            "type": item.type,
            "description": item.description,
            "excludedTopLevelKeys": item.excludedTopLevelKeys,
            "encodedBase64": item.encoded.base64EncodedString(),
            "object": try JSONSerialization.jsonObject(with: item.encoded),
            "canonicalBase64": item.canonical.base64EncodedString(),
            "canonicalSHA256Hex": SHA256.hash(data: item.canonical).map { String(format: "%02x", $0) }.joined(),
            "expect": ["signatureValid": item.signatureValid, "verdict": item.verdict],
        ]
        if let signer = item.signer { object["signer"] = try descriptorObject(signer) }
        if let signature = item.signature { object["signatureBase64"] = signature.base64EncodedString() }
        if !item.related.isEmpty { object["related"] = item.related }
        return object
    }

    static func manifest(_ cases: [Case]) throws -> [String: Any] {
        [
            "schema": "haven.interop.fixtures.v1",
            "verifyAt": verifyAtISO,
            "verifyAtEpoch": Int(verifyAt.timeIntervalSince1970),
            "generator": "Tests/CellBaseTests/InteropFixturesV1Tests.swift",
            "canonicalRule": "JSONEncoder() default strategies, then JSONSerialization.data(withJSONObject:options:[.sortedKeys]) after removing excludedTopLevelKeys. IdentitySigningChallenge signs JSONEncoder(.sortedKeys) output directly.",
            "signature": "Ed25519 (RFC 8032) over the canonical bytes. Keys are derived from SHA-256(\"haven-interop-v1/<name>\") and are public test keys.",
            "parties": try [alice, bob, mallory].map { party -> [String: Any] in
                ["name": party.name, "seedHex": party.key.rawRepresentation.map { String(format: "%02x", $0) }.joined(), "descriptor": try descriptorObject(party.descriptor)]
            },
            "cases": cases.map { ["id": $0.id, "file": "\($0.id).json", "flow": $0.flow, "type": $0.type] },
        ]
    }

    static func write(_ object: Any, to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Tests

    func testWriteInteropFixturesV1() async throws {
        guard ProcessInfo.processInfo.environment["HAVEN_WRITE_INTEROP_FIXTURES"] == "1" else {
            throw XCTSkip("Set HAVEN_WRITE_INTEROP_FIXTURES=1 to regenerate fixtures/interop/v1.")
        }
        let cases = try await Self.buildCases()
        let directory = Self.fixtureDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for item in cases {
            try Self.write(try Self.fileObject(item), to: directory.appendingPathComponent("\(item.id).json"))
        }
        try Self.write(try Self.manifest(cases), to: directory.appendingPathComponent("manifest.json"))
    }

    /// The committed fixtures are the contract. This test decodes each case
    /// with the Swift types, recomputes the canonical bytes on this platform,
    /// and checks the signature and verdict. A platform whose Foundation
    /// encodes differently fails here, by case id.
    func testInteropFixturesV1MatchThisPlatform() async throws {
        let directory = Self.fixtureDirectory
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return XCTFail("Missing \(manifestURL.path). Generate with HAVEN_WRITE_INTEROP_FIXTURES=1.")
        }
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let entries = try XCTUnwrap(manifest["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(entries.count, 46)

        // Freshly built cases must agree with the files on everything that is
        // deterministic on every platform: canonical bytes and verdicts.
        let fresh = Dictionary(uniqueKeysWithValues: try await Self.buildCases().map { ($0.id, $0) })

        for entry in entries {
            let id = try XCTUnwrap(entry["id"] as? String)
            let file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("\(id).json"))) as? [String: Any])
            let encoded = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(file["encodedBase64"] as? String)))
            let canonical = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(file["canonicalBase64"] as? String)))
            let type = try XCTUnwrap(file["type"] as? String)
            let recomputed = try Self.canonical(type: type, encoded: encoded)
            XCTAssertEqual(recomputed, canonical, "\(id): canonical bytes differ on this platform:\n\(String(decoding: recomputed, as: UTF8.self))\nvs fixture:\n\(String(decoding: canonical, as: UTF8.self))")

            let expect = try XCTUnwrap(file["expect"] as? [String: Any])
            let signer = try file["signer"].map { try JSONDecoder().decode(IdentityPublicKeyDescriptor.self, from: JSONSerialization.data(withJSONObject: $0)) }
            let signature = (file["signatureBase64"] as? String).flatMap { Data(base64Encoded: $0) }
            XCTAssertEqual(Self.verifies(signature, canonical, signer), expect["signatureValid"] as? Bool, "\(id): signature verdict")

            let freshCase = try XCTUnwrap(fresh[id], "\(id): no longer produced by buildCases()")
            XCTAssertEqual(freshCase.canonical, canonical, "\(id): builder output drifted from the fixture")
            XCTAssertEqual(freshCase.verdict, expect["verdict"] as? String, "\(id): verdict drifted")
        }
    }

    /// Decode with the Swift type, then produce the bytes the signature covers.
    static func canonical(type: String, encoded: Data) throws -> Data {
        let decoder = JSONDecoder()
        switch type {
        case "IdentityEnrollmentRequest": return try decoder.decode(IdentityEnrollmentRequest.self, from: encoded).canonicalPayloadData()
        case "IdentityEnrollmentApproval": return try decoder.decode(IdentityEnrollmentApproval.self, from: encoded).canonicalPayloadData()
        case "IdentityLinkRevocation": return try decoder.decode(IdentityLinkRevocation.self, from: encoded).canonicalPayloadData()
        case "HavenInviteTicket": return try decoder.decode(HavenInviteTicket.self, from: encoded).canonicalPayloadData()
        case "HavenInvitePublication": return try decoder.decode(HavenInvitePublication.self, from: encoded).canonicalPayloadData()
        case "HavenInviteReply": return try decoder.decode(HavenInviteReply.self, from: encoded).canonicalPayloadData()
        case "HavenInviteRevocationNotice": return try decoder.decode(HavenInviteRevocationNotice.self, from: encoded).canonicalPayloadData()
        case "HavenInviteContactRequest": return try decoder.decode(HavenInviteContactRequest.self, from: encoded).canonicalPayloadData()
        case "ChatInvitationArtifact": return try decoder.decode(ChatInvitationArtifact.self, from: encoded).canonicalPayloadData()
        case "ChatInvitationAcceptance": return try decoder.decode(ChatInvitationAcceptance.self, from: encoded).canonicalPayloadData()
        case "IdentitySigningChallenge": return try jsonEncoder().encode(try decoder.decode(IdentitySigningChallenge.self, from: encoded))
        case "VCClaim": return try unsignedClaimData(try decoder.decode(VCClaim.self, from: encoded))
        case "VCPresentation": return try decoder.decode(VCPresentation.self, from: encoded).canonicalPayloadData()
        case "EntityGenesisSeal": return try decoder.decode(EntityGenesisSeal.self, from: encoded).canonicalPayloadData()
        case "IdentityLinkCompletionEnvelope": return try decoder.decode(IdentityLinkCompletionEnvelope.self, from: encoded).presentation.canonicalPayloadData()
        case "BridgeChannelAuthV1": return try BridgeChannelAuthentication.signingData(try BridgeChannelAuthentication.decode(BridgeChannelAuthentication.Transcript.self, from: encoded))
        default: throw NSError(domain: "InteropFixturesV1", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown type \(type)"])
        }
    }
}
