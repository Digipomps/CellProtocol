// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Rules both EntityAnchor implementations (CellVapor and CellApple) apply to
/// everything below `identityLinks`. A record there makes another key act as
/// the entity, so it is authority, not data.
///
/// 1. A link is only minted by `identityLinks.genesis` or by
///    `identityLinks.approveEnrollment` + `identityLinks.completeEnrollment`.
///    The batch route and the direct flow write never touch `identityLinks`.
/// 2. A raw write below `identityLinks` is refused unless the requester proved
///    the owner key itself, and it is always refused where the host demands
///    fresh authentication evidence for links, and for the replay ledger.
/// 3. An enrollment is approved and issued by the entity: the owner key or a
///    key that already holds a whole same-entity link in this anchor. Only the
///    owner key itself, on a host without the fresh-authentication demand, may
///    complete a link someone else issued.
public enum EntityAnchorLinkGuardError: Error, Equatable, CustomStringConvertible {
    case identityLinksAreNotEntityData(String)
    case rawLinkWriteRequiresOwnerProof(String)
    case rawLinkWriteRequiresFreshAuthentication(String)
    case rawLinkWriteNotAllowed(String)
    case approverIsNotTheEntity(String)
    case issuerIsNotTheEntity(String)

    public var description: String {
        switch self {
        case .identityLinksAreNotEntityData(let keypath):
            return "identity_links_not_entity_data: \(keypath) is only written through identityLinks.genesis, approveEnrollment, completeEnrollment and revoke"
        case .rawLinkWriteRequiresOwnerProof(let keypath):
            return "raw_link_write_requires_owner_proof: \(keypath)"
        case .rawLinkWriteRequiresFreshAuthentication(let keypath):
            return "raw_link_write_requires_fresh_authentication: \(keypath) must go through approveEnrollment and completeEnrollment on this host"
        case .rawLinkWriteNotAllowed(let keypath):
            return "raw_link_write_not_allowed: \(keypath)"
        case .approverIsNotTheEntity(let uuid):
            return "approver_is_not_the_entity: \(uuid) is neither the owner nor a whole same-entity link"
        case .issuerIsNotTheEntity(let uuid):
            return "issuer_is_not_the_entity: \(uuid) is neither the owner nor a whole same-entity link"
        }
    }
}

public enum EntityAnchorLinkGuard {
    public static let root = "identityLinks"
    static let replayLedgerKeypath = "identityLinks.usedApprovalJTIs"
    static let approvalsKeypath = "identityLinks.approvals"

    /// True when the first segment of `keypath` is `identityLinks`, however the
    /// rest is written (`identityLinks`, `identityLinks.records.x`, `identityLinks[0]`).
    public static func isIdentityLinkKeypath(_ keypath: String) -> Bool {
        let trimmed = keypath.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutLeadingDots = trimmed.drop(while: { $0 == "." })
        let firstSegment = withoutLeadingDots.prefix(while: { $0 != "." && $0 != "[" })
        return firstSegment.trimmingCharacters(in: .whitespacesAndNewlines) == root
    }

    /// For the routes that write entity data in bulk: the batch envelope and
    /// the direct flow write. Neither is a link ceremony.
    public static func rejectEntityDataMutation(to keypath: String) throws {
        if isIdentityLinkKeypath(keypath) {
            throw EntityAnchorLinkGuardError.identityLinksAreNotEntityData(keypath)
        }
    }

    public static func rejectEntityDataMutations(to keypaths: [String]) throws {
        for keypath in keypaths {
            try rejectEntityDataMutation(to: keypath)
        }
    }

    /// For a `set` below `identityLinks` that is none of the four named actions.
    public static func rejectRawLinkWrite(
        to keypath: String,
        requesterProvesOwnership: Bool,
        freshAuthenticationRequired: Bool
    ) throws {
        let trimmed = keypath.trimmingCharacters(in: .whitespacesAndNewlines)
        // Replacing the whole tree, the whole record set, the approvals or the
        // replay ledger is never a single link decision.
        if trimmed == root
            || trimmed == EntityGenesisService.recordsKeypath
            || trimmed == approvalsKeypath || trimmed.hasPrefix(approvalsKeypath + ".")
            || trimmed == replayLedgerKeypath || trimmed.hasPrefix(replayLedgerKeypath + ".")
            || trimmed.hasPrefix(EntityGenesisService.recordsKeypath + ".") == false {
            throw EntityAnchorLinkGuardError.rawLinkWriteNotAllowed(keypath)
        }
        // One whole record, never a field inside one: a link is not edited into
        // another key, another scope or back from revoked piece by piece.
        let recordKey = trimmed.dropFirst(EntityGenesisService.recordsKeypath.count + 1)
        guard recordKey.isEmpty == false,
              recordKey.contains(where: { $0 == "." || $0 == "[" || $0 == "]" || $0.isWhitespace }) == false else {
            throw EntityAnchorLinkGuardError.rawLinkWriteNotAllowed(keypath)
        }
        guard freshAuthenticationRequired == false else {
            throw EntityAnchorLinkGuardError.rawLinkWriteRequiresFreshAuthentication(keypath)
        }
        guard requesterProvesOwnership else {
            throw EntityAnchorLinkGuardError.rawLinkWriteRequiresOwnerProof(keypath)
        }
    }

    /// The key that signs an approval must already be the entity here.
    public static func belongsToEntity(
        _ candidate: IdentityPublicKeyDescriptor,
        owner: Identity,
        identityDomain: String,
        registry: IdentityLinkRegistry = .shared
    ) async -> Bool {
        guard candidate.uuid.isEmpty == false, candidate.publicKey.isEmpty == false else {
            return false
        }
        if let ownerDescriptor = try? IdentityLinkProtocolService.descriptor(for: owner),
           ownerDescriptor.uuid == candidate.uuid,
           ownerDescriptor.publicKey == candidate.publicKey,
           ownerDescriptor.algorithm == candidate.algorithm,
           ownerDescriptor.curveType == candidate.curveType {
            return true
        }
        guard let link = await registry.sameEntityLink(
            ownerUUID: owner.uuid,
            requesterUUID: candidate.uuid,
            requesterSigningKey: candidate.publicKey,
            domain: identityDomain
        ) else {
            return false
        }
        return link.linkedIdentity.algorithm == candidate.algorithm
            && link.linkedIdentity.curveType == candidate.curveType
    }

    public static func requireApprover(
        _ requester: Identity,
        owner: Identity,
        identityDomain: String,
        registry: IdentityLinkRegistry = .shared
    ) async throws {
        guard let descriptor = try? IdentityLinkProtocolService.descriptor(for: requester),
              await belongsToEntity(descriptor, owner: owner, identityDomain: identityDomain, registry: registry) else {
            throw EntityAnchorLinkGuardError.approverIsNotTheEntity(requester.uuid)
        }
    }

    /// The issuer of a completed enrollment is the entity. One exception, the
    /// same as for a raw record: on a host that does not demand fresh
    /// authentication evidence (a personal scaffold), the owner key itself may
    /// accept a link another party issued. A linked identity never may.
    public static func requireIssuer(
        _ issuer: IdentityPublicKeyDescriptor,
        owner: Identity,
        identityDomain: String,
        requesterProvesOwnership: Bool,
        freshAuthenticationRequired: Bool,
        registry: IdentityLinkRegistry = .shared
    ) async throws {
        if await belongsToEntity(issuer, owner: owner, identityDomain: identityDomain, registry: registry) {
            return
        }
        if requesterProvesOwnership && freshAuthenticationRequired == false {
            return
        }
        throw EntityAnchorLinkGuardError.issuerIsNotTheEntity(issuer.uuid)
    }
}
