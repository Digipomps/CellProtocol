// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// purpose://candidate.entitetsdata.organization-acts-through-mandated-persons
//
// A person entity is sealed to the identity that started it (EntityGenesis).
// An organization entity is sealed to a signed GovernancePolicy instead: who the
// members are, which roles they hold, and which combinations of roles may bind
// the organization for which actions. The policy mirrors the legal structure
// ("styrets leder alene, eller to styremedlemmer i fellesskap") as data, so a
// board change is a new policy version, never a new organization key.
//
// Design: Docs/Organization_Entities_and_Group_Signing_NO.md

public enum EntityKind: String, Codable, Sendable {
    case person
    case organization
}

/// Open set of roles so a policy can carry roles this build does not know.
/// Unknown roles never satisfy a clause; they are only carried.
public struct OrganizationRole: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let owner = OrganizationRole(rawValue: "owner")
    public static let chair = OrganizationRole(rawValue: "chair")
    public static let boardMember = OrganizationRole(rawValue: "boardMember")
    public static let ceo = OrganizationRole(rawValue: "ceo")
    public static let procurist = OrganizationRole(rawValue: "procurist")
}

public struct OrganizationMember: Codable, Equatable, Sendable {
    /// The person's domain-scoped identity, never the person's whole entity.
    public var identity: IdentityPublicKeyDescriptor
    public var roles: [OrganizationRole]
    public var validFrom: String
    public var validUntil: String?

    public init(
        identity: IdentityPublicKeyDescriptor,
        roles: [OrganizationRole],
        validFrom: String,
        validUntil: String? = nil
    ) {
        self.identity = identity
        self.roles = roles
        self.validFrom = validFrom
        self.validUntil = validUntil
    }
}

public struct MonetaryAmount: Codable, Equatable, Sendable {
    /// Minor units (øre, cents) so no floating point reaches a signing rule.
    public var minorUnits: Int
    public var currency: String

    public init(minorUnits: Int, currency: String) {
        self.minorUnits = minorUnits
        self.currency = currency
    }
}

public struct ActionLimits: Codable, Equatable, Sendable {
    public var maxAmount: MonetaryAmount?

    public init(maxAmount: MonetaryAmount? = nil) {
        self.maxAmount = maxAmount
    }
}

/// "At least `minimum` distinct members holding `role`."
public struct RoleCount: Codable, Equatable, Sendable {
    public var role: OrganizationRole
    public var minimum: Int

    public init(role: OrganizationRole, minimum: Int) {
        self.role = role
        self.minimum = minimum
    }
}

/// All requirements must hold. With `distinctPersons`, one member can satisfy
/// at most one requirement, so a chair who is also a board member does not
/// satisfy "chair and one board member" alone.
public struct ApprovalClause: Codable, Equatable, Sendable {
    public var requirements: [RoleCount]
    public var distinctPersons: Bool

    public init(requirements: [RoleCount], distinctPersons: Bool = true) {
        self.requirements = requirements
        self.distinctPersons = distinctPersons
    }
}

public struct SigningRule: Codable, Equatable, Sendable {
    public var ruleID: String
    /// One clause is enough.
    public var anyOf: [ApprovalClause]
    public var actionClasses: [String]
    public var excludedActions: [String]
    public var limits: ActionLimits?
    public var requiresFreshAuth: Bool

    public init(
        ruleID: String,
        anyOf: [ApprovalClause],
        actionClasses: [String],
        excludedActions: [String] = [],
        limits: ActionLimits? = nil,
        requiresFreshAuth: Bool = false
    ) {
        self.ruleID = ruleID
        self.anyOf = anyOf
        self.actionClasses = actionClasses
        self.excludedActions = excludedActions
        self.limits = limits
        self.requiresFreshAuth = requiresFreshAuth
    }
}

public struct PolicyEvidenceReference: Codable, Equatable, Sendable {
    public var kind: String
    public var reference: String

    public init(kind: String, reference: String) {
        self.kind = kind
        self.reference = reference
    }
}

public struct GovernancePolicy: Codable, Equatable, Sendable, CanonicalPayloadSignable {
    public var policyID: String
    public var version: Int
    public var previousPolicyHash: Data?
    public var members: [OrganizationMember]
    public var rules: [SigningRule]
    /// The rule an amendment of this policy must satisfy.
    public var amendmentRuleID: String
    public var evidence: [PolicyEvidenceReference]
    public var validFrom: String

    public init(
        policyID: String,
        version: Int,
        previousPolicyHash: Data? = nil,
        members: [OrganizationMember],
        rules: [SigningRule],
        amendmentRuleID: String,
        evidence: [PolicyEvidenceReference] = [],
        validFrom: String
    ) {
        self.policyID = policyID
        self.version = version
        self.previousPolicyHash = previousPolicyHash
        self.members = members
        self.rules = rules
        self.amendmentRuleID = amendmentRuleID
        self.evidence = evidence
        self.validFrom = validFrom
    }

    public func canonicalPayloadData() throws -> Data {
        try CanonicalPayloadEncoder.data(for: self)
    }

    public func policyHash() throws -> Data {
        OrganizationHashing.sha256(try canonicalPayloadData())
    }

    public func rule(id: String) -> SigningRule? {
        rules.first { $0.ruleID == id }
    }
}

public extension GovernancePolicy {
    /// Enkeltpersonforetak: the owner alone binds the organization.
    static func soleProprietorship(
        policyID: String,
        owner: IdentityPublicKeyDescriptor,
        validFrom: String
    ) -> GovernancePolicy {
        GovernancePolicy(
            policyID: policyID,
            version: 1,
            members: [OrganizationMember(identity: owner, roles: [.owner], validFrom: validFrom)],
            rules: [
                SigningRule(
                    ruleID: "signatur",
                    anyOf: [ApprovalClause(requirements: [RoleCount(role: .owner, minimum: 1)])],
                    actionClasses: ["*"]
                )
            ],
            amendmentRuleID: "signatur",
            validFrom: validFrom
        )
    }
}
