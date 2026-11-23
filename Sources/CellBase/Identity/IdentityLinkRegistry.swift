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
        // En lenke med avgrensning er aldri hel, selv om den også nevner same_entity.
        (scopes.contains(sameEntity) || scopes.contains(legacyEntityAuth))
            && !ScopedIdentityLinkPolicy.mentionsScope(scopes)
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

/// Process-local observation of one exact active registry record/incarnation.
/// Not Codable and not an authentication, ownership or same-Entity grant. The
/// application must capture it during its existing authenticated admission and
/// retain this original value across awaits, never recapture on a stale result.
public struct IdentityLinkContactRevision: Sendable {
    public let ownerUUID: String
    public let record: IdentityLinkRecord
    fileprivate let registryID: UUID
    fileprivate let generation: UUID

    fileprivate init(ownerUUID: String, record: IdentityLinkRecord, registryID: UUID, generation: UUID) {
        self.ownerUUID = ownerUUID; self.record = record
        self.registryID = registryID; self.generation = generation
    }
}

/// Exact registration ownership, never a serializable or reusable capability.
public struct IdentityLinkContactAttachment: Equatable, Sendable {
    fileprivate let registryID: UUID
    fileprivate let ownerUUID: String
    fileprivate let linkID: String
    fileprivate let generation: UUID
    fileprivate let registrationID: UUID
}

public actor IdentityLinkRegistry {
    public static let shared = IdentityLinkRegistry()
    /// Hard bounds on retained registrations, including expired operations
    /// awaiting explicit owner cleanup. No eviction of another live operation.
    public static let maximumContactOperationsPerLink = 64
    public static let maximumContactRegistrations = 256

    private var linksByOwner: [String: [String: IdentityLinkRecord]] = [:]
    // Derived from a verified seal/record pair, never from a link ID convention
    // or from the linked identity being its own issuer. Keep the record in
    // linksByOwner: sameEntityLink is also the genesis authorization lookup.
    private var verifiedGenesisByOwner: [String: IdentityLinkRecord] = [:]
    // Incarnations/attachments are derived runtime state on this existing
    // registry, not another source of identity/link authority. Every write
    // starts a new incarnation, even a replacement with identical record bytes.
    private let contactRegistryID = UUID()
    private var contactRevisionsByOwner: [String: [String: UUID]] = [:]
    private struct ContactRegistration {
        let lease: ContactOperationLease
        let attachment: IdentityLinkContactAttachment
    }
    private var contactOperationsByOwner: [String: [String: [ObjectIdentifier: ContactRegistration]]] = [:]
    private var contactRegistrationCount = 0
    // purpose://candidate.informasjonssystemer-gruppeentitet.genesis:
    // owners that are organization entities, with the machine identities
    // (vault, server) that may act as them. A person never becomes the same
    // entity as an organization; people act through approvals and mandates.
    private var organizationMachineIdentitiesByOwner: [String: Set<String>] = [:]

    public init() {}

    /// Marks `ownerUUID` as an organization. From now on `sameEntityLink`
    /// returns only links to the listed machine identities for this owner.
    public func markOrganization(ownerUUID: String, machineIdentityUUIDs: Set<String>) {
        organizationMachineIdentitiesByOwner[ownerUUID] = machineIdentityUUIDs
    }

    public func isOrganization(ownerUUID: String) -> Bool {
        organizationMachineIdentitiesByOwner[ownerUUID] != nil
    }

    public func register(ownerUUID: String, completion: IdentityLinkCompletionResult) {
        retireContactOperations(ownerUUID: ownerUUID, linkID: completion.record.linkID)
        contactRevisionsByOwner[ownerUUID, default: [:]][completion.record.linkID] = UUID()
        linksByOwner[ownerUUID, default: [:]][completion.record.linkID] = completion.record
    }

    /// Gjenoppretting fra EntityAnchor sitt validerte lager. Erstatter alt for eieren.
    /// Et seal klassifiserer bare den eksakte recorden det verifiserer som genesis.
    /// Kalleren er fortsatt ansvarlig for å avvise ugyldige records før restore.
    public func restore(ownerUUID: String, records: [IdentityLinkRecord], genesisSeal: EntityGenesisSeal? = nil) {
        var byLinkID: [String: IdentityLinkRecord] = [:]
        for record in records {
            byLinkID[record.linkID] = record
        }
        retireContactOperations(ownerUUID: ownerUUID)
        contactRevisionsByOwner[ownerUUID] = byLinkID.mapValues { _ in UUID() }
        linksByOwner[ownerUUID] = byLinkID
        verifiedGenesisByOwner[ownerUUID] = nil
        if let seal = genesisSeal,
           let record = byLinkID[seal.linkID],
           (try? EntityGenesisService.verify(seal: seal, record: record)) != nil {
            verifiedGenesisByOwner[ownerUUID] = record
        }
    }

    public func revoke(ownerUUID: String, linkID: String, revokedAt: String) {
        guard var record = linksByOwner[ownerUUID]?[linkID] else { return }
        retireContactOperations(ownerUUID: ownerUUID, linkID: linkID)
        contactRevisionsByOwner[ownerUUID, default: [:]][linkID] = UUID()
        record.status = .revoked
        record.revokedAt = revokedAt
        linksByOwner[ownerUUID]?[linkID] = record
    }

    public func clear(ownerUUID: String) {
        retireContactOperations(ownerUUID: ownerUUID)
        linksByOwner[ownerUUID] = nil
        verifiedGenesisByOwner[ownerUUID] = nil
        organizationMachineIdentitiesByOwner[ownerUUID] = nil
    }

    /// Match the COMPLETE record already selected by the authenticated caller,
    /// including key, scope and binding. A UUID-only request cannot substitute
    /// an arbitrary current record. This observation itself grants no access.
    /// Capture FIRST after legitimate cold recovery AND revalidation of the
    /// original authenticated evidence/key/home/install/request binding by its
    /// owner. After this capture retain it; a stale attach cannot be recovered
    /// by recapturing a new revision on the same operation.
    public func contactOperationRevision(ownerUUID: String,
        matching expectedRecord: IdentityLinkRecord) -> IdentityLinkContactRevision? {
        guard expectedRecord.status == .active,
              linksByOwner[ownerUUID]?[expectedRecord.linkID] == expectedRecord,
              let generation = contactRevisionsByOwner[ownerUUID]?[expectedRecord.linkID] else { return nil }
        return IdentityLinkContactRevision(ownerUUID: ownerUUID, record: expectedRecord,
            registryID: contactRegistryID, generation: generation)
    }

    /// Conditional attach of the ORIGINAL operation instance. No await occurs
    /// between revision validation and insertion. A stale/foreign revision
    /// retires only the supplied operation and returns nil; callers must abort
    /// partial multi-owner admission and detach its earlier registrations.
    /// Capacity refusal also retires only the supplied operation (terminal).
    /// Expired registrations consume capacity until exact detach or mutation;
    /// the admitting owner must clean up terminal/cancelled/failed operations.
    public func attachContactOperation(_ lease: ContactOperationLease,
        to revision: IdentityLinkContactRevision) -> IdentityLinkContactAttachment? {
        let owner = revision.ownerUUID, link = revision.record.linkID
        guard revision.registryID == contactRegistryID, revision.record.status == .active,
              contactRevisionsByOwner[owner]?[link] == revision.generation,
              linksByOwner[owner]?[link] == revision.record else {
            lease.retire(.linkChanged)
            return nil
        }
        do {
            let result = try lease.withCurrent { () -> IdentityLinkContactAttachment? in
                let instance = ObjectIdentifier(lease)
                if let existing = contactOperationsByOwner[owner]?[link]?[instance] {
                    return existing.attachment
                }
                guard contactRegistrationCount < Self.maximumContactRegistrations,
                      (contactOperationsByOwner[owner]?[link]?.count ?? 0) < Self.maximumContactOperationsPerLink else {
                    return nil
                }
                let attachment = IdentityLinkContactAttachment(registryID: contactRegistryID,
                    ownerUUID: owner, linkID: link, generation: revision.generation, registrationID: UUID())
                contactOperationsByOwner[owner, default: [:]][link, default: [:]][instance] =
                    ContactRegistration(lease: lease, attachment: attachment)
                contactRegistrationCount += 1
                return attachment
            }
            // Outside withCurrent: retire never reenters the lease lock.
            guard let result else { lease.retire(.terminal); return nil }
            return result
        } catch is CancellationError {
            lease.retire(.cancelled)
            return nil
        } catch {
            lease.retire(.linkChanged)
            return nil
        }
    }

    /// Finish an exact attachment. Retire before detaching so the original
    /// operation cannot continue outside this owner's retirement coverage.
    /// Stale handles or another lease instance cannot detach/retire a successor.
    @discardableResult
    public func detachContactOperation(_ lease: ContactOperationLease,
        attachment: IdentityLinkContactAttachment) -> Bool {
        let owner = attachment.ownerUUID, link = attachment.linkID
        let instance = ObjectIdentifier(lease)
        guard attachment.registryID == contactRegistryID,
              contactRevisionsByOwner[owner]?[link] == attachment.generation,
              let existing = contactOperationsByOwner[owner]?[link]?[instance],
              existing.lease === lease, existing.attachment == attachment else { return false }
        lease.retire(.terminal)
        contactOperationsByOwner[owner]?[link]?[instance] = nil
        contactRegistrationCount -= 1
        if contactOperationsByOwner[owner]?[link]?.isEmpty == true { contactOperationsByOwner[owner]?[link] = nil }
        if contactOperationsByOwner[owner]?.isEmpty == true { contactOperationsByOwner[owner] = nil }
        return true
    }

    /// Called only in the existing registry's synchronous actor mutation turn,
    /// BEFORE replacement authority is published. No arbitrary observer callback
    /// or Task is invoked. Lock order: registry actor -> operation lease; final
    /// signer is lease -> context -> synchronous crypto and must not reenter an
    /// authority owner. An already admitted private call can finish first.
    private func retireContactOperations(ownerUUID: String, linkID: String? = nil) {
        let registrations: [ContactRegistration]
        if let linkID {
            registrations = Array((contactOperationsByOwner[ownerUUID]?[linkID] ?? [:]).values)
            contactOperationsByOwner[ownerUUID]?[linkID] = nil
            contactRevisionsByOwner[ownerUUID]?[linkID] = nil
            if contactOperationsByOwner[ownerUUID]?.isEmpty == true { contactOperationsByOwner[ownerUUID] = nil }
        } else {
            registrations = (contactOperationsByOwner.removeValue(forKey: ownerUUID) ?? [:]).values.flatMap { $0.values }
            contactRevisionsByOwner[ownerUUID] = nil
        }
        contactRegistrationCount -= registrations.count
        for registration in registrations { registration.lease.retire(.linkChanged) }
    }

    /// Aktive innmeldingslenker. Verifisert genesis-eierskap er ikke en innmelding,
    /// men forblir tilgjengelig for autorisasjon gjennom `sameEntityLink`.
    public func activeLinks(ownerUUID: String) -> [IdentityLinkRecord] {
        let genesis = verifiedGenesisByOwner[ownerUUID]
        return (linksByOwner[ownerUUID] ?? [:]).values
            .filter { $0.status == .active && $0 != genesis }
            .sorted { $0.linkedAt < $1.linkedAt }
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
        if let machines = organizationMachineIdentitiesByOwner[ownerUUID], machines.contains(requesterUUID) == false {
            return nil
        }
        for record in links.values where record.status == .active {
            guard record.linkedIdentity.uuid == requesterUUID,
                  record.linkedIdentity.publicKey == signingKey,
                  IdentityLinkScope.grantsSameEntity(record.approvedScopes),
                  record.approvedDomains.contains(domain),
                  // purpose://candidate.entitetsdata.authorization-resolves-entity:
                  // pairwise and blinded bindings prove membership to *others*;
                  // only a link bound to the local anchor opens the entity itself.
                  record.entityBinding.mode == .localEntityAnchor else {
                continue
            }
            return record
        }
        return nil
    }

    /// Avgrenset lenke for denne nøkkelen, uansett status, så kalleren kan svare
    /// `extension_revoked` i stedet for et generelt nei. Gir aldri eiermakt.
    /// Organisasjoner har ingen avgrensede lenker: en persons agent handler ikke for en organisasjon.
    public func scopedLink(
        ownerUUID: String,
        requesterUUID: String,
        requesterSigningKey: Data?,
        domain: String
    ) -> (record: IdentityLinkRecord, policy: ScopedIdentityLinkPolicy)? {
        guard let links = linksByOwner[ownerUUID], let signingKey = requesterSigningKey, !signingKey.isEmpty,
              organizationMachineIdentitiesByOwner[ownerUUID] == nil else {
            return nil
        }
        var revoked: (record: IdentityLinkRecord, policy: ScopedIdentityLinkPolicy)?
        for record in links.values.sorted(by: { $0.linkID < $1.linkID }) {
            guard record.linkedIdentity.uuid == requesterUUID,
                  record.linkedIdentity.publicKey == signingKey,
                  record.approvedDomains.contains(domain),
                  record.entityBinding.mode == .localEntityAnchor,
                  let policy = ScopedIdentityLinkPolicy(approvedScopes: record.approvedScopes) else {
                continue
            }
            if record.status == .active { return (record, policy) }
            revoked = revoked ?? (record, policy)
        }
        return revoked
    }
}
