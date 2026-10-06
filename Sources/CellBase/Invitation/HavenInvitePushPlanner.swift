// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  HavenInvitePushPlanner.swift
//  CellProtocol
//
//  Decides whether, and to which registered devices, a published invitation is
//  pushed. Pure: no clock of its own, no network, no storage. The scaffold's
//  dispatcher asks, sends what the plan says, and logs the outcome for itself.
//
//  Only an entity that was named in the signed publication (audienceEntity) and
//  that has an active registration is ever pushed
//  (purpose://candidate.testmatrise.apns.only-who-was-invited-is-pushed).
//  The outcome is the scaffold's internal log: it never reaches the sender
//  (HavenInviteSenderView has no case for it, and that is on purpose).
//

import Foundation

public enum HavenInvitePushOutcome: String, Codable, Equatable, Sendable {
    case sent
    case noAudienceEntity = "no_audience_entity"
    case noRegistration = "no_registration"
    case wrongAudience = "wrong_audience"
    case tokenRevoked = "token_revoked"
    case ticketExpired = "ticket_expired"
    case ticketRevoked = "ticket_revoked"
    case ticketInvalid = "ticket_invalid"
    case tombstoned
    case transportRefused = "transport_refused"
}

public struct HavenInvitePushTarget: Codable, Equatable, Sendable {
    public var registrationID: String
    public var environment: HavenPushEnvironment
    public var bundleId: String
    public var token: String
}

public struct HavenInvitePushPlan: Equatable, Sendable {
    public var ticketID: String
    public var ticketExpiresAt: Int
    /// Empty when `outcome` is a skip.
    public var targets: [HavenInvitePushTarget]
    /// `nil` means "go ahead and send to `targets`"; anything else is the reason nothing is sent.
    public var skip: HavenInvitePushOutcome?
}

public enum HavenInvitePushPlanner {

    public static func plan(
        publication: HavenInvitePublication,
        revokedTicketIDs: Set<String> = [],
        tombstones: HavenInviteTombstoneLedger = HavenInviteTombstoneLedger(),
        registry: HavenPushRegistry,
        now: Date = Date()
    ) -> HavenInvitePushPlan {
        func skip(_ outcome: HavenInvitePushOutcome) -> HavenInvitePushPlan {
            HavenInvitePushPlan(ticketID: publication.ticketID, ticketExpiresAt: publication.expiresAt, targets: [], skip: outcome)
        }

        // 1. The publication must be genuine and unexpired. The ticket is read from the publication's own
        //    token, never from anything the phone says.
        let ticket: HavenInviteTicket
        do {
            ticket = try HavenInvitePublicationVerifier.verifyPublication(publication, now: now)
        } catch HavenInvitePublicationVerifier.Failure.ticketExpired {
            return skip(.ticketExpired)
        } catch HavenInvitePublicationVerifier.Failure.ticketMismatch(let detail) where detail == "audienceEntity" {
            return skip(.wrongAudience)
        } catch {
            return skip(.ticketInvalid)
        }

        // 2. Withdrawn.
        if revokedTicketIDs.contains(ticket.ticketID) { return skip(.ticketRevoked) }

        // 3. A "never" from that audience closes the door for good.
        if tombstones.refuses(ticket) { return skip(.tombstoned) }

        // 4. Who is this for? Only the sender-named, signed audienceEntity counts.
        guard let named = publication.audienceEntity, !named.isEmpty else { return skip(.noAudienceEntity) }
        guard HavenPushFormat.isValidEntity(named), named.lowercased() != ticket.issuer.uuid.lowercased() else {
            return skip(.wrongAudience)
        }

        // 5. Does that entity have somewhere to be reached?
        let active = registry.activeRegistrations(entity: named)
        guard !active.isEmpty else {
            return skip(registry.hasOnlyRevoked(entity: named) ? .tokenRevoked : .noRegistration)
        }
        let targets = active.compactMap { record -> HavenInvitePushTarget? in
            guard let token = record.token, let bundle = record.bundleId else { return nil }
            return HavenInvitePushTarget(registrationID: record.registrationID, environment: record.environment, bundleId: bundle, token: token)
        }
        guard !targets.isEmpty else { return skip(.noRegistration) }
        return HavenInvitePushPlan(ticketID: ticket.ticketID, ticketExpiresAt: ticket.expiresAt, targets: targets, skip: nil)
    }
}
