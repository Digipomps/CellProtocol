// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum GovernanceEvaluationError: Error, Equatable, Sendable {
    case policyHashMismatch
    case proposalNotYetValid
    case proposalExpired
    case malformedTimestamp(String)
    case noRuleCoversAction(String)
    case actionExcluded(ruleID: String)
    case amountExceedsLimit(ruleID: String)
    case approvalForOtherProposal(approver: String)
    case approvalSignatureInvalid(approver: String)
    case approverNotMember(approver: String)
    case approverLacksRole(approver: String, role: String)
    case approverNotValidAt(approver: String)
    case freshAuthRequired(approver: String)
    case rejected(by: String)
    case clauseNotSatisfied(ruleID: String)
}

public struct GovernanceEvaluation: Equatable, Sendable {
    public var ruleID: String
    public var clauseIndex: Int
    /// UUIDs of the members whose approvals satisfied the clause.
    public var approverUUIDs: [String]
}

/// Pure: policy + bundle + clock → the rule and clause that bind the
/// organization, or the first reason they do not. Fails closed. Nonce replay
/// and freshness-evidence verification belong to the vault, not here.
public enum GovernancePolicyEvaluator {
    public static let wildcardActionClass = "*"

    public static func evaluate(
        policy: GovernancePolicy,
        bundle: ApprovalBundle,
        now: Date = Date()
    ) throws -> GovernanceEvaluation {
        let proposal = bundle.proposal
        guard try policy.policyHash() == proposal.policyHash else {
            throw GovernanceEvaluationError.policyHashMismatch
        }
        guard try date(proposal.createdAt) <= now else {
            throw GovernanceEvaluationError.proposalNotYetValid
        }
        guard now <= (try date(proposal.expiresAt)) else {
            throw GovernanceEvaluationError.proposalExpired
        }

        let proposalHash = try proposal.proposalHash()
        var validApprovals: [(member: OrganizationMember, approval: OrganizationApproval)] = []
        for approval in bundle.approvals {
            let who = approval.approver.uuid
            guard approval.proposalHash == proposalHash else {
                throw GovernanceEvaluationError.approvalForOtherProposal(approver: who)
            }
            guard approval.signatureIsValid() else {
                throw GovernanceEvaluationError.approvalSignatureInvalid(approver: who)
            }
            guard let member = policy.members.first(where: { $0.identity == approval.approver }) else {
                throw GovernanceEvaluationError.approverNotMember(approver: who)
            }
            guard member.roles.contains(approval.role) else {
                throw GovernanceEvaluationError.approverLacksRole(approver: who, role: approval.role.rawValue)
            }
            let approvedAt = try date(approval.approvedAt)
            guard try date(member.validFrom) <= approvedAt,
                  try member.validUntil.map({ approvedAt <= (try date($0)) }) ?? true else {
                throw GovernanceEvaluationError.approverNotValidAt(approver: who)
            }
            if approval.decision == .reject {
                throw GovernanceEvaluationError.rejected(by: who)
            }
            validApprovals.append((member, approval))
        }

        let candidates = policy.rules.filter { rule in
            rule.actionClasses.contains(proposal.actionClass) || rule.actionClasses.contains(wildcardActionClass)
        }
        guard candidates.isEmpty == false else {
            throw GovernanceEvaluationError.noRuleCoversAction(proposal.actionClass)
        }

        // Report the most precise reason: a rule whose approvers suffice but
        // whose exclusion, limit or fresh-auth gate blocks the action beats a
        // rule the approvers never met.
        var firstGateFailure: GovernanceEvaluationError?
        var firstFailure: GovernanceEvaluationError?
        for rule in candidates {
            do {
                return try evaluate(rule: rule, proposal: proposal, approvals: validApprovals)
            } catch let error as GovernanceEvaluationError {
                if case .clauseNotSatisfied = error {} else if firstGateFailure == nil { firstGateFailure = error }
                if firstFailure == nil { firstFailure = error }
            }
        }
        throw firstGateFailure ?? firstFailure ?? GovernanceEvaluationError.noRuleCoversAction(proposal.actionClass)
    }

    private static func evaluate(
        rule: SigningRule,
        proposal: OrganizationActionProposal,
        approvals: [(member: OrganizationMember, approval: OrganizationApproval)]
    ) throws -> GovernanceEvaluation {
        // One vote per person per role. A person approving twice counts once.
        var rolesByPerson: [String: Set<OrganizationRole>] = [:]
        for entry in approvals {
            rolesByPerson[entry.member.identity.uuid, default: []].insert(entry.approval.role)
        }

        var match: (index: Int, people: Set<String>)?
        for (index, clause) in rule.anyOf.enumerated() {
            if let people = satisfiers(of: clause, rolesByPerson: rolesByPerson) {
                match = (index, people)
                break
            }
        }
        guard let match else {
            throw GovernanceEvaluationError.clauseNotSatisfied(ruleID: rule.ruleID)
        }

        guard rule.excludedActions.contains(proposal.actionClass) == false else {
            throw GovernanceEvaluationError.actionExcluded(ruleID: rule.ruleID)
        }
        if let max = rule.limits?.maxAmount {
            // A rule with a limit never covers an action without a stated amount.
            guard let amount = proposal.amount,
                  amount.currency == max.currency,
                  amount.minorUnits <= max.minorUnits else {
                throw GovernanceEvaluationError.amountExceedsLimit(ruleID: rule.ruleID)
            }
        }
        if rule.requiresFreshAuth {
            for entry in approvals where entry.approval.freshAuthEvidence == nil {
                throw GovernanceEvaluationError.freshAuthRequired(approver: entry.approval.approver.uuid)
            }
        }
        return GovernanceEvaluation(ruleID: rule.ruleID, clauseIndex: match.index, approverUUIDs: match.people.sorted())
    }

    /// Returns the people used, or nil if the clause cannot be met.
    private static func satisfiers(
        of clause: ApprovalClause,
        rolesByPerson: [String: Set<OrganizationRole>]
    ) -> Set<String>? {
        guard clause.requirements.allSatisfy({ $0.minimum >= 1 }) else { return nil }
        // Expand "role × minimum" into slots and fill them with distinct people
        // by backtracking; policies are small, so this is cheap.
        let slots = clause.requirements.flatMap { Array(repeating: $0.role, count: $0.minimum) }
        var used = Set<String>()
        func fill(_ index: Int) -> Bool {
            if index == slots.count { return true }
            for (person, roles) in rolesByPerson.sorted(by: { $0.key < $1.key }) where roles.contains(slots[index]) {
                if clause.distinctPersons, used.contains(person) { continue }
                let inserted = used.insert(person).inserted
                if fill(index + 1) { return true }
                if inserted { used.remove(person) }
            }
            return false
        }
        return fill(0) ? used : nil
    }

    private static func date(_ text: String) throws -> Date {
        guard let date = ISO8601DateFormatter().date(from: text) else {
            throw GovernanceEvaluationError.malformedTimestamp(text)
        }
        return date
    }
}
