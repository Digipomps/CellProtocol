// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// purpose://candidate.informasjonssystemer-gruppeentitet.ownership-agreement
//
// A group entity owned by a few people (an owner group) needs to say which
// actions one owner may take alone and which need more of them. That is an
// ownership agreement, and it is data: the agreement only builds the signing
// rules of a GovernancePolicy, so changing it is a new policy version approved
// under the rule the current policy names for amendments. No code decides it.

/// The action classes an owner-group policy governs.
public enum OrganizationActionClass {
    /// Issue a role credential (student, researcher, supervisor, …).
    public static let roleIssue = "role.issue"
    /// Revoke an issued role credential.
    public static let roleRevoke = "role.revoke"
    /// Publish a new signed status list for issued roles.
    public static let roleStatusPublish = "role.status.publish"
    /// Replace the governance policy (owners, roles, rules, the agreement itself).
    public static let policyAmend = "policy.amend"

    public static let roleActions = [roleIssue, roleRevoke, roleStatusPublish]
}

/// How many distinct owners an action needs.
public struct OwnerQuorum: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Any one owner.
        case one
        /// Every owner in the policy version that is being acted under.
        case all
        /// At least `minimum` distinct owners.
        case atLeast
    }

    public var kind: Kind
    public var minimum: Int?

    public init(kind: Kind, minimum: Int? = nil) {
        self.kind = kind
        self.minimum = minimum
    }

    public static let one = OwnerQuorum(kind: .one)
    public static let all = OwnerQuorum(kind: .all)
    public static func atLeast(_ minimum: Int) -> OwnerQuorum { OwnerQuorum(kind: .atLeast, minimum: minimum) }

    /// The number of owners this quorum needs among `ownerCount` owners, or nil
    /// when it cannot be met (fails closed instead of silently lowering it).
    public func required(ownerCount: Int) -> Int? {
        guard ownerCount >= 1 else { return nil }
        switch kind {
        case .one:
            return 1
        case .all:
            return ownerCount
        case .atLeast:
            guard let minimum, minimum >= 1, minimum <= ownerCount else { return nil }
            return minimum
        }
    }
}

public enum OwnershipAgreementError: Error, Equatable, Sendable {
    case noOwners
    case duplicateOwner(String)
    case quorumCannotBeMet(rule: String, ownerCount: Int)
}

public struct OwnershipAgreement: Codable, Equatable, Sendable {
    public static let rolesRuleID = "roller"
    public static let governanceRuleID = "styring"
    /// Evidence kind that records which template built a policy version.
    public static let evidenceKind = "ownershipAgreement"

    /// A stable name so surfaces can show which template is in force.
    public var templateID: String
    public var roles: OwnerQuorum
    public var governance: OwnerQuorum

    public init(templateID: String, roles: OwnerQuorum, governance: OwnerQuorum) {
        self.templateID = templateID
        self.roles = roles
        self.governance = governance
    }

    /// Roles: one owner. Governance: all owners. The starting agreement for
    /// Informasjonssystemer (Kjetil 2026-11-18).
    public static let rolesOneGovernanceAll = OwnershipAgreement(templateID: "roles-one-governance-all", roles: .one, governance: .all)
    /// Everything needs two owners.
    public static let allTwo = OwnershipAgreement(templateID: "all-two", roles: .atLeast(2), governance: .atLeast(2))
    /// Any one owner may do anything.
    public static let oneAlone = OwnershipAgreement(templateID: "one-alone", roles: .one, governance: .one)
    /// Two owners for everything; meant for three owners.
    public static let twoOfThree = OwnershipAgreement(templateID: "two-of-three", roles: .atLeast(2), governance: .atLeast(2))

    public static let templates = [rolesOneGovernanceAll, allTwo, oneAlone, twoOfThree]

    /// The two signing rules this agreement stands for, for `ownerCount` owners.
    public func signingRules(ownerCount: Int) throws -> [SigningRule] {
        guard let rolesRequired = roles.required(ownerCount: ownerCount) else {
            throw OwnershipAgreementError.quorumCannotBeMet(rule: Self.rolesRuleID, ownerCount: ownerCount)
        }
        guard let governanceRequired = governance.required(ownerCount: ownerCount) else {
            throw OwnershipAgreementError.quorumCannotBeMet(rule: Self.governanceRuleID, ownerCount: ownerCount)
        }
        return [
            SigningRule(
                ruleID: Self.rolesRuleID,
                anyOf: [ApprovalClause(requirements: [RoleCount(role: .owner, minimum: rolesRequired)])],
                actionClasses: OrganizationActionClass.roleActions
            ),
            SigningRule(
                ruleID: Self.governanceRuleID,
                anyOf: [ApprovalClause(requirements: [RoleCount(role: .owner, minimum: governanceRequired)])],
                actionClasses: [OrganizationActionClass.policyAmend]
            ),
        ]
    }
}

public extension GovernancePolicy {
    /// A policy for a group owned by `owners`, with the signing rules of
    /// `agreement`. Amendments use the governance rule.
    static func ownerGroup(
        policyID: String,
        version: Int = 1,
        previousPolicyHash: Data? = nil,
        owners: [IdentityPublicKeyDescriptor],
        agreement: OwnershipAgreement,
        evidence: [PolicyEvidenceReference] = [],
        validFrom: String,
        ownerValidFrom: [String: String] = [:]
    ) throws -> GovernancePolicy {
        guard owners.isEmpty == false else { throw OwnershipAgreementError.noOwners }
        var seen = Set<String>()
        for owner in owners where seen.insert(owner.uuid).inserted == false {
            throw OwnershipAgreementError.duplicateOwner(owner.uuid)
        }
        return GovernancePolicy(
            policyID: policyID,
            version: version,
            previousPolicyHash: previousPolicyHash,
            members: owners.map {
                OrganizationMember(identity: $0, roles: [.owner], validFrom: ownerValidFrom[$0.uuid] ?? validFrom)
            },
            rules: try agreement.signingRules(ownerCount: owners.count),
            amendmentRuleID: OwnershipAgreement.governanceRuleID,
            evidence: [PolicyEvidenceReference(kind: OwnershipAgreement.evidenceKind, reference: agreement.templateID)] + evidence,
            validFrom: validFrom
        )
    }

    /// Owners in this policy version.
    var owners: [IdentityPublicKeyDescriptor] {
        members.filter { $0.roles.contains(.owner) }.map(\.identity)
    }
}
