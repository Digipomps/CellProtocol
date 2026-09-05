// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Scopes i en `IdentityLinkRecord` som gjør at den lenkede identiteten handler *som* entiteten.
/// Alt annet feiler lukket i resolveren.
public enum IdentityLinkScope {
    public static let sameEntity = "same_entity"
    /// Navnet tidlige fixtures og Binding brukte; behandles likt med `same_entity`.
    public static let legacyEntityAuth = "entity-auth"

    public static func grantsSameEntity(_ scopes: [String]) -> Bool {
        scopes.contains(sameEntity) || scopes.contains(legacyEntityAuth)
    }
}

/// Runtime-registeret resolveren spør: «er denne identiteten lenket som samme entitet som eieren?»
///
/// Bare EntityAnchor skriver hit — enten med et `IdentityLinkCompletionResult` (som bare finnes
/// etter `IdentityLinkProtocolService.verifyCompletion`) eller ved gjenoppretting fra sitt eget
/// lager. En rå `IdentityLinkRecord` kan ikke registreres utenfra; det er poenget.
/// Runtime-policy et scaffold installerer ved oppstart. EntityAnchor håndhever den ved
/// `identityLinks.completeEnrollment`, så en fullføring som går utenom web-ruten (bridge,
/// direkte set) møter samme krav om passkey-bevis.
public actor IdentityLinkRuntimePolicy {
    public static let shared = IdentityLinkRuntimePolicy()

    public private(set) var requireFreshAuthEvidence: Bool = false
    public private(set) var freshAuthVerifier: IdentityLinkFreshAuthVerifier?

    public init() {}

    public func install(requireFreshAuthEvidence: Bool, freshAuthVerifier: IdentityLinkFreshAuthVerifier?) {
        self.requireFreshAuthEvidence = requireFreshAuthEvidence
        self.freshAuthVerifier = freshAuthVerifier
    }

    public func reset() {
        requireFreshAuthEvidence = false
        freshAuthVerifier = nil
    }
}

public actor IdentityLinkRegistry {
    public static let shared = IdentityLinkRegistry()

    private var linksByOwner: [String: [String: IdentityLinkRecord]] = [:]

    public init() {}

    public func register(ownerUUID: String, completion: IdentityLinkCompletionResult) {
        linksByOwner[ownerUUID, default: [:]][completion.record.linkID] = completion.record
    }

    /// Gjenoppretting fra EntityAnchor sitt persisterte `identityLinks.records`. Erstatter alt for eieren.
    public func restore(ownerUUID: String, records: [IdentityLinkRecord]) {
        var byLinkID: [String: IdentityLinkRecord] = [:]
        for record in records {
            byLinkID[record.linkID] = record
        }
        linksByOwner[ownerUUID] = byLinkID
    }

    public func revoke(ownerUUID: String, linkID: String, revokedAt: String) {
        guard var record = linksByOwner[ownerUUID]?[linkID] else { return }
        record.status = .revoked
        record.revokedAt = revokedAt
        linksByOwner[ownerUUID]?[linkID] = record
    }

    public func clear(ownerUUID: String) {
        linksByOwner[ownerUUID] = nil
    }

    public func activeLinks(ownerUUID: String) -> [IdentityLinkRecord] {
        (linksByOwner[ownerUUID] ?? [:]).values.filter { $0.status == .active }.sorted { $0.linkedAt < $1.linkedAt }
    }

    /// Feiler lukket: status må være aktiv, UUID *og* signeringsnøkkel må matche den lenkede
    /// identiteten, scopet må gi «samme entitet», og domenet må stå eksplisitt i `approvedDomains`.
    /// Resolveren må i tillegg la requesteren bevise kontroll over nøkkelen (`checkIdentityOrigin`).
    public func sameEntityLink(
        ownerUUID: String,
        requesterUUID: String,
        requesterSigningKey: Data?,
        domain: String
    ) -> IdentityLinkRecord? {
        guard let links = linksByOwner[ownerUUID], let signingKey = requesterSigningKey, !signingKey.isEmpty else {
            return nil
        }
        for record in links.values where record.status == .active {
            guard record.linkedIdentity.uuid == requesterUUID,
                  record.linkedIdentity.publicKey == signingKey,
                  IdentityLinkScope.grantsSameEntity(record.approvedScopes),
                  record.approvedDomains.contains(domain) else {
                continue
            }
            return record
        }
        return nil
    }
}
