// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  HavenInviteReply.swift
//  CellProtocol
//
//  The invitee's answer, and what a "never" leaves behind.
//
//  Three answers exist: yes, not now, never. The sender learns only that the
//  invitation was answered (purpose://candidate.invite.decline-without-account, §6.5).
//  A "never" is different in one way: it closes the door for good. The
//  scaffold keeps a tombstone — signed by the person who said never — and
//  refuses to publish a new invitation from that issuer to that audience
//  (purpose://candidate.invite.no-automatic-reminders).
//
//  Nothing here is stored under the invitee's name on the sender's side. The
//  tombstone names an audience token, not a person.
//

import Foundation

// MARK: - Decision

public enum HavenInviteDecision: String, Codable, Equatable, Sendable {
    case yes
    case notNow
    case never

    /// What the scaffold records. Both refusals read as "declined": the
    /// difference between them lives in the tombstone, not in the status.
    public var lifecycle: HavenInviteLifecycle {
        switch self {
        case .yes: return .accepted
        case .notNow, .never: return .declined
        }
    }
}

// MARK: - Reply

/// Signed by the replier's own identity — for a "yes", the brand-new one the
/// landing page just minted; for a refusal, an ephemeral one is enough. The
/// signature is what stops a third party from declining on someone's behalf,
/// and what makes a tombstone something the issuer can check rather than a
/// note the scaffold wrote to itself.
public struct HavenInviteReply: Codable, Equatable, Sendable, CanonicalPayloadSignable {

    public static let schema = "haven.invite.reply.v1"

    public var schema: String
    public var replyID: String
    public var ticketID: String
    /// Bound to the ticket's audience, so a reply cannot be lifted onto
    /// another invitation to someone else.
    public var audienceToken: String
    public var decision: HavenInviteDecision
    public var replier: IdentityPublicKeyDescriptor
    /// Public key-agreement key of the replier, only meaningful on a "yes"
    /// (purpose://candidate.invite.acceptance-carries-the-key-to-seal-to).
    public var replierKeyAgreementKey: Data?
    public var createdAt: Int
    public var nonce: Data
    public var proof: HavenSignatureProof?

    public init(
        schema: String = HavenInviteReply.schema,
        replyID: String,
        ticketID: String,
        audienceToken: String,
        decision: HavenInviteDecision,
        replier: IdentityPublicKeyDescriptor,
        replierKeyAgreementKey: Data? = nil,
        createdAt: Int,
        nonce: Data,
        proof: HavenSignatureProof? = nil
    ) {
        self.schema = schema
        self.replyID = replyID
        self.ticketID = ticketID
        self.audienceToken = audienceToken
        self.decision = decision
        self.replier = replier
        self.replierKeyAgreementKey = replierKeyAgreementKey
        self.createdAt = createdAt
        self.nonce = nonce
        self.proof = proof
    }

    public func canonicalPayloadData() throws -> Data {
        try CanonicalPayloadEncoder.data(for: self, excludingTopLevelKeys: ["proof"])
    }

    /// Builds and signs a reply to `ticket` with `replier`'s vault key.
    public static func make(
        to ticket: HavenInviteTicket,
        decision: HavenInviteDecision,
        by replier: Identity,
        now: Date = Date(),
        nonce: Data? = nil
    ) async throws -> HavenInviteReply {
        guard let descriptor = IdentityPublicKeySignatureVerifier.descriptor(for: replier) else {
            throw IdentityVaultError.signingFailed
        }
        var randomNonce = Data(count: 12)
        for index in randomNonce.indices { randomNonce[index] = UInt8.random(in: 0...255) }
        var reply = HavenInviteReply(
            replyID: "rp-" + UUID().uuidString.lowercased(),
            ticketID: ticket.ticketID,
            audienceToken: ticket.audienceToken,
            decision: decision,
            replier: descriptor,
            replierKeyAgreementKey: decision == .yes ? replier.publicKeyAgreementSecureKey?.compressedKey : nil,
            createdAt: Int(now.timeIntervalSince1970),
            nonce: nonce ?? randomNonce
        )
        reply.proof = try await HavenInviteSigning.proof(over: try reply.canonicalPayloadData(), by: replier)
        return reply
    }
}

// MARK: - Tombstone

/// What a "never" leaves on the scaffold. It carries the signed reply, so
/// the refusal can be re-verified by anyone who holds the ticket, and it
/// names the issuer and the audience token it closes.
///
/// The scaffold consults it at *publish* time: a new ticket from the same
/// issuer to the same audience is refused before it exists anywhere. The
/// issuer's app sees only "Besvart"; the tombstone is not a status.
public struct HavenInviteTombstone: Codable, Equatable, Sendable {

    public static let schema = "haven.invite.tombstone.v1"

    public var schema: String
    public var issuerIdentityUUID: String
    public var audienceToken: String
    public var reply: HavenInviteReply
    public var createdAt: Int

    public init(
        schema: String = HavenInviteTombstone.schema,
        issuerIdentityUUID: String,
        audienceToken: String,
        reply: HavenInviteReply,
        createdAt: Int
    ) {
        self.schema = schema
        self.issuerIdentityUUID = issuerIdentityUUID
        self.audienceToken = audienceToken
        self.reply = reply
        self.createdAt = createdAt
    }

    /// Only a verified "never" becomes a tombstone. A "not now" does not:
    /// the door stays open — that answer is about *this* invitation, not all
    /// future ones (purpose://candidate.invite.decline-without-account).
    public static func make(
        from reply: HavenInviteReply,
        forTicket ticket: HavenInviteTicket,
        now: Date = Date()
    ) throws -> HavenInviteTombstone {
        guard reply.decision == .never else {
            throw HavenInvitePublicationVerifier.Failure.wrongDecision
        }
        try HavenInvitePublicationVerifier.verifyReply(reply, forTicket: ticket, now: now)
        return HavenInviteTombstone(
            issuerIdentityUUID: ticket.issuer.uuid,
            audienceToken: ticket.audienceToken,
            reply: reply,
            createdAt: Int(now.timeIntervalSince1970)
        )
    }

    /// Re-checks the enclosed reply against the ticket it answered. The
    /// ticket may since have expired; the reply is judged at its own time.
    public func verify(forTicket ticket: HavenInviteTicket) throws {
        guard reply.decision == .never else {
            throw HavenInvitePublicationVerifier.Failure.wrongDecision
        }
        guard issuerIdentityUUID == ticket.issuer.uuid else {
            throw HavenInvitePublicationVerifier.Failure.issuerMismatch
        }
        guard audienceToken == ticket.audienceToken else {
            throw HavenInvitePublicationVerifier.Failure.ticketMismatch("audienceToken")
        }
        try HavenInvitePublicationVerifier.verifyReply(
            reply,
            forTicket: ticket,
            now: Date(timeIntervalSince1970: TimeInterval(reply.createdAt))
        )
    }

    public func blocks(issuerIdentityUUID issuer: String, audienceToken token: String) -> Bool {
        issuerIdentityUUID == issuer && audienceToken == token
    }

    /// Does this tombstone close the door on `ticket`?
    public func blocks(_ ticket: HavenInviteTicket) -> Bool {
        blocks(issuerIdentityUUID: ticket.issuer.uuid, audienceToken: ticket.audienceToken)
    }
}

/// The scaffold's set of closed doors. In memory here; the scaffold persists
/// it under its own key and rebuilds it on start.
public struct HavenInviteTombstoneLedger: Codable, Equatable, Sendable {

    public private(set) var tombstones: [HavenInviteTombstone]

    public init(tombstones: [HavenInviteTombstone] = []) {
        self.tombstones = tombstones
    }

    /// Records a tombstone. A second "never" for the same door is a no-op.
    public mutating func record(_ tombstone: HavenInviteTombstone) {
        guard !isClosed(issuerIdentityUUID: tombstone.issuerIdentityUUID, audienceToken: tombstone.audienceToken) else {
            return
        }
        tombstones.append(tombstone)
    }

    public func isClosed(issuerIdentityUUID: String, audienceToken: String) -> Bool {
        tombstones.contains { $0.blocks(issuerIdentityUUID: issuerIdentityUUID, audienceToken: audienceToken) }
    }

    /// What the scaffold asks before it publishes anything.
    public func refuses(_ ticket: HavenInviteTicket) -> Bool {
        tombstones.contains { $0.blocks(ticket) }
    }
}
