// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  HavenInvitePublication.swift
//  CellProtocol
//
//  Everything that has to travel between the issuer's device, the scaffold and
//  the invitee — and the wording that goes on the outside of it.
//
//  Publishing is what makes three otherwise impossible things work:
//  a link short enough to survive an SMS, a reply channel that actually has a
//  receiver, and a real signal for opened/joined instead of the issuer ticking
//  a box by hand. It costs one network call at prepare time. Sending is still
//  something only the person can do.
//
//  Every message here is signed by the identity it claims to come from and
//  carries the public key needed to check that, so no party in the chain has
//  to be trusted with anything except storage.
//

import Foundation

// MARK: - Wording

public enum HavenInviteCopy {

    /// The line that must appear in every invitation, whatever the channel.
    /// It is the honest description of what the link does.
    public static let boundaryLine =
        "Lenken lar deg opprette din egen entitet i HAVEN og sende meg en kontaktforespørsel tilbake. Den gir ingen tilgang til noe av mitt, og den gir meg ingen tilgang til noe av ditt."

    /// Used when the issuer has no reachable contact endpoint yet, so the
    /// reply half of the promise would be false.
    public static let boundaryLineWithoutReply =
        "Lenken lar deg opprette din egen entitet i HAVEN. Den gir ingen tilgang til noe av mitt, og den gir meg ingen tilgang til noe av ditt."

    public static func boundary(for ticket: HavenInviteTicket) -> String {
        ticket.canReceiveContactRequest ? boundaryLine : boundaryLineWithoutReply
    }

    public struct Message: Equatable, Sendable {
        public var subject: String
        public var body: String
        /// A URL the app can open. Never opened automatically.
        public var handoffURL: String?
        public var channel: String

        public init(subject: String, body: String, handoffURL: String?, channel: String) {
            self.subject = subject
            self.body = body
            self.handoffURL = handoffURL
            self.channel = channel
        }
    }

    public static func compose(
        ticket: HavenInviteTicket,
        recipientDisplayName: String,
        recipientEndpoint: String,
        link: String?,
        channel: String,
        senderNote: String?
    ) -> Message {
        let firstName = recipientDisplayName
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init) ?? recipientDisplayName
        let issuer = ticket.issuerDisplayName
        let linkLine = link ?? "(ingen lenke — sett opp et scaffold først)"
        let note = senderNote?.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundary = boundary(for: ticket)

        switch channel {
        case "email":
            var body = "Hei \(firstName),\n\n"
            if let note, !note.isEmpty { body += note + "\n\n" }
            body += "Jeg bruker HAVEN, og vil gjerne ha deg med.\n\n"
            body += linkLine + "\n\n"
            body += boundary + "\n\n"
            body += "Koden er \(ticket.humanCode) hvis du heller vil skrive den inn.\n"
            body += "Invitasjonen varer til \(readable(ticket.expiryDate)).\n\n"
            body += "— \(issuer)"
            return Message(
                subject: "\(issuer) inviterer deg til HAVEN",
                body: body,
                handoffURL: mailto(to: recipientEndpoint, subject: "\(issuer) inviterer deg til HAVEN", body: body),
                channel: channel
            )

        case "sms":
            // Kept deliberately short. The link here must be the published
            // short link; a self-contained ticket does not fit in an SMS and
            // the invitation cell refuses to send one on this channel.
            var body = "Hei \(firstName)! "
            if let note, !note.isEmpty { body += note + " " }
            body += "\(issuer) inviterer deg til HAVEN: \(linkLine) Kode \(ticket.humanCode)."
            return Message(
                subject: "",
                body: body,
                handoffURL: sms(to: recipientEndpoint, body: body),
                channel: channel
            )

        default:
            var body = "\(issuer) inviterer deg til HAVEN.\n\n"
            if let note, !note.isEmpty { body += note + "\n\n" }
            body += linkLine + "\n\nKode \(ticket.humanCode).\n\n" + boundary
            return Message(subject: "Invitasjon til HAVEN", body: body, handoffURL: nil, channel: "share")
        }
    }

    public static func mailto(to: String, subject: String, body: String) -> String {
        "mailto:\(percentEncoded(to))?subject=\(percentEncoded(subject))&body=\(percentEncoded(body))"
    }

    public static func sms(to: String, body: String) -> String {
        // iOS wants `&body=`; the `?body=` form fails on some versions.
        "sms:\(percentEncoded(to))&body=\(percentEncoded(body))"
    }

    public static func percentEncoded(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    public static func readable(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "nb_NO")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Publication

/// What the issuer's device registers with the scaffold when an invitation is
/// prepared. Signed, so the scaffold can prove the publisher is the issuer
/// named inside the ticket without holding any secret of its own.
public struct HavenInvitePublication: Codable, Equatable, Sendable, CanonicalPayloadSignable {

    public static let schema = "haven.invite.publication.v1"

    public var schema: String
    public var ticketID: String
    public var humanCode: String
    /// The full, self-contained ticket as it travels in a long link. The
    /// scaffold stores it verbatim and serves it back on a short-code lookup.
    public var ticketToken: String
    public var audienceToken: String
    public var issuerIdentityUUID: String
    public var expiresAt: Int
    public var publishedAt: Int
    /// Cap on how many contact requests this ticket may collect. A forwarded
    /// link cannot turn into an open inbox.
    public var maxContactRequests: Int
    /// Bearer token for reading this ticket's own status and inbox back from
    /// the scaffold. Random, held only by the issuer's device, and covered by
    /// the signature so it cannot be swapped in transit.
    ///
    /// Without it, `who has opened invitation X` would be answerable by anyone
    /// who could guess a ticket id — a quiet oracle over the issuer's network.
    public var statusKey: String
    public var proof: HavenSignatureProof?

    public init(
        schema: String = HavenInvitePublication.schema,
        ticketID: String,
        humanCode: String,
        ticketToken: String,
        audienceToken: String,
        issuerIdentityUUID: String,
        expiresAt: Int,
        publishedAt: Int,
        maxContactRequests: Int = 3,
        statusKey: String,
        proof: HavenSignatureProof? = nil
    ) {
        self.schema = schema
        self.ticketID = ticketID
        self.humanCode = humanCode
        self.ticketToken = ticketToken
        self.audienceToken = audienceToken
        self.issuerIdentityUUID = issuerIdentityUUID
        self.expiresAt = expiresAt
        self.publishedAt = publishedAt
        self.maxContactRequests = maxContactRequests
        self.statusKey = statusKey
        self.proof = proof
    }

    public func canonicalPayloadData() throws -> Data {
        try CanonicalPayloadEncoder.data(for: self, excludingTopLevelKeys: ["proof"])
    }

    /// 32 random bytes, base64url. Long enough that guessing is not a strategy.
    public static func makeStatusKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return HavenInviteLink.base64URL(Data(bytes))
    }
}

/// Signed withdrawal. Without this the scaffold would accept a revocation from
/// anyone who knows a ticket id.
public struct HavenInviteRevocationNotice: Codable, Equatable, Sendable, CanonicalPayloadSignable {

    public static let schema = "haven.invite.revocation.v1"

    public var schema: String
    public var ticketID: String
    public var reason: String
    public var revokedAt: Int
    public var issuerIdentityUUID: String
    public var proof: HavenSignatureProof?

    public init(
        schema: String = HavenInviteRevocationNotice.schema,
        ticketID: String,
        reason: String,
        revokedAt: Int,
        issuerIdentityUUID: String,
        proof: HavenSignatureProof? = nil
    ) {
        self.schema = schema
        self.ticketID = ticketID
        self.reason = reason
        self.revokedAt = revokedAt
        self.issuerIdentityUUID = issuerIdentityUUID
        self.proof = proof
    }

    public func canonicalPayloadData() throws -> Data {
        try CanonicalPayloadEncoder.data(for: self, excludingTopLevelKeys: ["proof"])
    }
}

// MARK: - Status

public enum HavenInviteLifecycle: String, Codable, Sendable {
    case published
    case opened
    case accepted
    case declined
    case expired
    case revoked

    public var displayText: String {
        switch self {
        case .published: return "Sendt"
        case .opened: return "Åpnet"
        case .accepted: return "Ble med"
        case .declined: return "Takket nei"
        case .expired: return "Utløpt"
        case .revoked: return "Trukket tilbake"
        }
    }
}

/// What the scaffold knows about one ticket. This is the first real signal in
/// the funnel — before publication, every status was self-reported.
public struct HavenInviteStatusReport: Codable, Equatable, Sendable {

    public static let schema = "haven.invite.status.v1"

    public var schema: String
    public var ticketID: String
    public var state: HavenInviteLifecycle
    /// First time the landing page served this ticket. Counted once.
    public var firstOpenedAt: Int?
    public var openCount: Int
    public var respondedAt: Int?
    public var contactRequestCount: Int
    public var resultingEntityRef: String?

    public init(
        schema: String = HavenInviteStatusReport.schema,
        ticketID: String,
        state: HavenInviteLifecycle,
        firstOpenedAt: Int? = nil,
        openCount: Int = 0,
        respondedAt: Int? = nil,
        contactRequestCount: Int = 0,
        resultingEntityRef: String? = nil
    ) {
        self.schema = schema
        self.ticketID = ticketID
        self.state = state
        self.firstOpenedAt = firstOpenedAt
        self.openCount = openCount
        self.respondedAt = respondedAt
        self.contactRequestCount = contactRequestCount
        self.resultingEntityRef = resultingEntityRef
    }
}

// MARK: - Contact request

/// The reply. This is what turns `send_contact_request_to_issuer` from a
/// promise into something with a receiver.
///
/// It is signed by the *invitee's* brand-new identity and carries that
/// identity's public key, so the issuer can verify it offline the moment it
/// arrives — without the scaffold, which only relayed it, being trusted.
public struct HavenInviteContactRequest: Codable, Equatable, Sendable, CanonicalPayloadSignable {

    public static let schema = "haven.invite.contactRequest.v1"

    public var schema: String
    public var requestID: String
    /// Which invitation this is a reply to.
    public var ticketID: String
    /// The endpoint the issuer named in the ticket.
    public var issuerEndpointID: String
    public var sender: IdentityPublicKeyDescriptor
    public var senderDisplayName: String
    public var senderEntityRef: String?
    /// Optional, and only what the sender chose to reveal.
    public var senderEndpoint: String?
    public var message: String?
    public var createdAt: Int
    public var expiresAt: Int
    public var nonce: Data
    public var proof: HavenSignatureProof?

    public init(
        schema: String = HavenInviteContactRequest.schema,
        requestID: String,
        ticketID: String,
        issuerEndpointID: String,
        sender: IdentityPublicKeyDescriptor,
        senderDisplayName: String,
        senderEntityRef: String? = nil,
        senderEndpoint: String? = nil,
        message: String? = nil,
        createdAt: Int,
        expiresAt: Int,
        nonce: Data,
        proof: HavenSignatureProof? = nil
    ) {
        self.schema = schema
        self.requestID = requestID
        self.ticketID = ticketID
        self.issuerEndpointID = issuerEndpointID
        self.sender = sender
        self.senderDisplayName = senderDisplayName
        self.senderEntityRef = senderEntityRef
        self.senderEndpoint = senderEndpoint
        self.message = message
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.nonce = nonce
        self.proof = proof
    }

    public func canonicalPayloadData() throws -> Data {
        try CanonicalPayloadEncoder.data(for: self, excludingTopLevelKeys: ["proof"])
    }

    public func isExpired(at moment: Date = Date()) -> Bool {
        moment.timeIntervalSince1970 > TimeInterval(expiresAt)
    }

    /// Maps onto the contact-request contract the `ContactEndpoint` cell
    /// already speaks, so the issuer's side has one inbox rather than two.
    public func contactEndpointPayload() -> Object {
        var payload: Object = [
            "introKind": .string("invite.acceptance"),
            "introTicketID": .string(ticketID),
            "introDisplayName": .string(senderDisplayName)
        ]
        if let senderEntityRef { payload["introEntityRef"] = .string(senderEntityRef) }
        if let message { payload["introMessage"] = .string(message) }

        return [
            "schema": .string("cellprotocol.contact.request.v1"),
            "endpointId": .string(issuerEndpointID),
            "nonce": .string(nonce.base64EncodedString()),
            "issuedAt": .float(TimeInterval(createdAt)),
            "expiresAt": .float(TimeInterval(expiresAt)),
            "topic": .string("contact.request"),
            "purpose": .string("purpose://contact.introduction"),
            "requestedAction": .string("contact.request.submit"),
            "payload": .object(payload)
        ]
    }
}

// MARK: - Verification of the envelopes

public enum HavenInvitePublicationVerifier {

    public enum Failure: Error, CustomStringConvertible, Sendable {
        case unsigned
        case issuerMismatch
        case badSignature
        case ticketMismatch(String)
        case expired

        public var code: String {
            switch self {
            case .unsigned: return "unsigned"
            case .issuerMismatch: return "issuer_mismatch"
            case .badSignature: return "bad_signature"
            case .ticketMismatch: return "ticket_mismatch"
            case .expired: return "expired"
            }
        }

        public var description: String {
            switch self {
            case .unsigned: return "Meldingen er ikke signert."
            case .issuerMismatch: return "Signaturen tilhører en annen identitet enn den meldingen oppgir."
            case .badSignature: return "Signaturen stemmer ikke."
            case .ticketMismatch(let detail): return "Meldingen passer ikke billetten: \(detail)."
            case .expired: return "Meldingen er utløpt."
            }
        }
    }

    /// A publication is genuine when the enclosed ticket verifies on its own,
    /// the publication describes that exact ticket, and the publication itself
    /// is signed by the same identity that signed the ticket.
    ///
    /// Checking all three is what stops someone who intercepted a link from
    /// re-publishing it under a code they control.
    public static func verifyPublication(
        _ publication: HavenInvitePublication,
        now: Date = Date()
    ) throws -> HavenInviteTicket {
        let ticket = try HavenInviteLink.decode(publication.ticketToken)

        let verdict = HavenInviteVerifier.verify(ticket: ticket, now: now)
        guard verdict.signatureValid else { throw Failure.badSignature }

        guard ticket.ticketID == publication.ticketID else {
            throw Failure.ticketMismatch("ticketID")
        }
        guard ticket.humanCode == publication.humanCode else {
            throw Failure.ticketMismatch("humanCode")
        }
        guard ticket.audienceToken == publication.audienceToken else {
            throw Failure.ticketMismatch("audienceToken")
        }
        guard ticket.issuer.uuid == publication.issuerIdentityUUID else {
            throw Failure.issuerMismatch
        }

        try verifyEnvelope(publication, signedBy: ticket.issuer)
        return ticket
    }

    public static func verifyRevocation(
        _ notice: HavenInviteRevocationNotice,
        againstIssuerOf ticket: HavenInviteTicket
    ) throws {
        guard notice.ticketID == ticket.ticketID else { throw Failure.ticketMismatch("ticketID") }
        guard notice.issuerIdentityUUID == ticket.issuer.uuid else { throw Failure.issuerMismatch }
        try verifyEnvelope(notice, signedBy: ticket.issuer)
    }

    /// The invitee's reply. Verified against the key it carries, and bound to
    /// the ticket it answers.
    public static func verifyContactRequest(
        _ request: HavenInviteContactRequest,
        forTicket ticket: HavenInviteTicket,
        now: Date = Date()
    ) throws {
        guard request.ticketID == ticket.ticketID else { throw Failure.ticketMismatch("ticketID") }
        guard let endpoint = ticket.issuerContactEndpoint, request.issuerEndpointID == endpoint else {
            throw Failure.ticketMismatch("issuerEndpointID")
        }
        guard !request.isExpired(at: now) else { throw Failure.expired }
        guard request.sender.uuid != ticket.issuer.uuid else {
            throw Failure.issuerMismatch
        }
        try verifyEnvelope(request, signedBy: request.sender)
    }

    private static func verifyEnvelope(
        _ envelope: some CanonicalPayloadSignable,
        signedBy descriptor: IdentityPublicKeyDescriptor
    ) throws {
        guard let proof = envelopeProof(envelope), let signature = proof.signature else {
            throw Failure.unsigned
        }
        guard proof.byIdentityUUID == descriptor.uuid else { throw Failure.issuerMismatch }
        let payload = try envelope.canonicalPayloadData()
        guard IdentityPublicKeySignatureVerifier.verify(
            signature: signature,
            messageData: payload,
            descriptor: descriptor
        ) else {
            throw Failure.badSignature
        }
    }

    private static func envelopeProof(_ envelope: some CanonicalPayloadSignable) -> HavenSignatureProof? {
        if let publication = envelope as? HavenInvitePublication { return publication.proof }
        if let notice = envelope as? HavenInviteRevocationNotice { return notice.proof }
        if let request = envelope as? HavenInviteContactRequest { return request.proof }
        return nil
    }
}
