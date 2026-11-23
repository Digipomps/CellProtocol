// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// purpose://candidate.informasjonssystemer-gruppeentitet.vault
//
// The vault is a notary, not a board member. It holds the organization key,
// never exports it, and signs exactly one thing per accepted ApprovalBundle:
// the payload whose hash the owners approved. Before signing it checks, in
// this order and failing closed: the proposal is for this organization, the
// nonce is unused, the payload matches the approved hash, the summary the
// owners saw is the one the vault derives from the payload, and the
// GovernancePolicyEvaluator accepts the bundle under the policy in force.
// Every signature is written to a hash-chained journal.

/// Where the organization key lives. Only this differs per platform.
public protocol OrganizationKeyCustodian: Sendable {
    func publicKey() async throws -> IdentityPublicKeyDescriptor
    func sign(_ data: Data) async throws -> Data
    /// Must be false in production. A software key on staging is true and is
    /// shown as a test key (Kjetil 2026-11-18, spørsmål 5).
    var keyIsExportable: Bool { get }
    /// The identity whose key signs, for VC proofs.
    func signingIdentity() async throws -> Identity
}

/// Software key held by an IdentityVault identity. Staging and tests only.
public struct SoftwareOrganizationKeyCustodian: OrganizationKeyCustodian {
    private let identity: Identity
    public let keyIsExportable = true

    public init(identity: Identity) {
        self.identity = identity
    }

    public func publicKey() async throws -> IdentityPublicKeyDescriptor {
        try IdentityLinkProtocolService.descriptor(for: identity)
    }

    public func sign(_ data: Data) async throws -> Data {
        guard let signature = try await identity.sign(data: data) else { throw IdentityVaultError.signingFailed }
        return signature
    }

    public func signingIdentity() async throws -> Identity { identity }
}

public enum OrganizationVaultError: Error, Equatable, Sendable {
    case custodianKeyMismatch
    case proposalForOtherOrganization
    case nonceAlreadyUsed
    case payloadDoesNotMatchApprovedHash
    case summaryDoesNotMatchPayload
    case actionClassMismatch(expected: String, found: String)
    case refused(GovernanceEvaluationError)
    case amendment(GovernancePolicyChainError)
    case unknownCredential(String)
    case snapshotRefused(OrganizationVaultSnapshotError)
}

/// Why a stored vault state was not adopted. Restoring fails closed: a vault
/// that cannot account for every signature it has made does not start.
public enum OrganizationVaultSnapshotError: Error, Equatable, Sendable {
    case unsupportedSchema(String)
    case journalBroken
    case journalDoesNotStartAtGenesis
    case amendmentsDoNotMatchJournal
    case statusListMissing
    case statusListNotSignedByCustodian
    case statusListDoesNotMatchJournal
    case credentialNotSignedByCustodian(String)
    case credentialsDoNotMatchJournal
    case noncesDoNotMatchJournal
}

/// Everything a vault must remember across a restart, except the key. The
/// key stays with the custodian. Store the snapshot after every signing call
/// and hand the latest one to `OrganizationVault(restoring:custodian:)`.
///
/// The snapshot is checked for consistency when it is restored, and the
/// status list and every credential must carry the custodian's signature. It
/// is not itself signed, so it does not protect against a storage owner who
/// replaces it with an older, complete snapshot. Nodes that mirror the status
/// list refuse a lower sequence, which is what exposes such a rollback.
public struct OrganizationVaultSnapshot: Codable, @unchecked Sendable {
    public static let currentSchema = "haven.organization-vault-snapshot.v1"

    public var schema: String
    public var seal: OrganizationGenesisSeal
    public var initialPolicy: GovernancePolicy
    public var credentialType: String
    public var amendments: [GovernancePolicyAmendment]
    public var journal: [OrganizationJournalEntry]
    /// Issued credentials, ordered by id.
    public var issued: [VCClaim]
    public var statusList: OrganizationRoleStatusList?
    /// Nonces of every bundle the vault has acted on, ordered.
    public var usedNonces: [Data]

    public init(
        schema: String = OrganizationVaultSnapshot.currentSchema,
        seal: OrganizationGenesisSeal,
        initialPolicy: GovernancePolicy,
        credentialType: String,
        amendments: [GovernancePolicyAmendment],
        journal: [OrganizationJournalEntry],
        issued: [VCClaim],
        statusList: OrganizationRoleStatusList?,
        usedNonces: [Data]
    ) {
        self.schema = schema
        self.seal = seal
        self.initialPolicy = initialPolicy
        self.credentialType = credentialType
        self.amendments = amendments
        self.journal = journal
        self.issued = issued
        self.statusList = statusList
        self.usedNonces = usedNonces
    }
}

public struct OrganizationJournalEntry: Codable, Equatable, Sendable, CanonicalPayloadSignable {
    public var sequence: Int
    public var previousEntryHash: Data?
    public var recordedAt: String
    public var actionClass: String
    public var proposalHash: Data
    public var payloadHash: Data
    public var payloadSummary: String
    public var policyVersion: Int
    public var ruleID: String
    public var approverUUIDs: [String]
    public var signatureHash: Data

    public func canonicalPayloadData() throws -> Data {
        try CanonicalPayloadEncoder.data(for: self)
    }

    public func entryHash() throws -> Data {
        OrganizationHashing.sha256(try canonicalPayloadData())
    }
}

public actor OrganizationVault {
    public let seal: OrganizationGenesisSeal
    public let displayName: String
    public let credentialType: String
    private let custodian: OrganizationKeyCustodian
    private let initialPolicy: GovernancePolicy
    public private(set) var amendments: [GovernancePolicyAmendment] = []
    public private(set) var policy: GovernancePolicy
    public private(set) var journal: [OrganizationJournalEntry] = []
    public private(set) var issued: [String: VCClaim] = [:]
    public private(set) var statusList: OrganizationRoleStatusList?
    private var usedNonces = Set<Data>()

    public init(
        seal: OrganizationGenesisSeal,
        initialPolicy: GovernancePolicy,
        custodian: OrganizationKeyCustodian,
        credentialType: String
    ) async throws {
        try seal.verify(initialPolicy: initialPolicy)
        guard try await custodian.publicKey() == seal.custodianKey else {
            throw OrganizationVaultError.custodianKeyMismatch
        }
        self.seal = seal
        self.displayName = seal.displayName
        self.initialPolicy = initialPolicy
        self.policy = initialPolicy
        self.custodian = custodian
        self.credentialType = credentialType
        // An empty first status list, so a node can mirror the organization from
        // the start. It revokes nothing and grants nothing, so it is the one
        // signature made without an approval; it is journaled as such.
        var first = OrganizationRoleStatusList(
            organizationAnchorID: seal.anchorID,
            issuerDID: try IdentityLinkProtocolService.did(for: seal.custodianKey),
            sequence: 1,
            issuedAt: seal.sealedAt,
            revokedCredentialIDs: [])
        first.signature = try await custodian.sign(try first.canonicalPayloadData())
        statusList = first
        journal = [OrganizationJournalEntry(
            sequence: 1, previousEntryHash: nil, recordedAt: seal.sealedAt,
            actionClass: OrganizationActionClass.roleStatusPublish, proposalHash: try seal.sealHash(),
            payloadHash: try first.payloadHash(), payloadSummary: "Tom statusliste ved opprettelsen",
            policyVersion: initialPolicy.version, ruleID: "genesis",
            approverUUIDs: seal.founders.map(\.uuid).sorted(),
            signatureHash: OrganizationHashing.sha256(first.signature ?? Data()))]
    }

    /// Starts the vault from a stored snapshot instead of from genesis, so
    /// issued roles, the status list sequence and the used nonces survive a
    /// restart. Nothing is signed here.
    public init(restoring snapshot: OrganizationVaultSnapshot, custodian: OrganizationKeyCustodian) async throws {
        typealias Refusal = OrganizationVaultSnapshotError
        guard snapshot.schema == OrganizationVaultSnapshot.currentSchema else {
            throw OrganizationVaultError.snapshotRefused(.unsupportedSchema(snapshot.schema))
        }
        let seal = snapshot.seal
        try seal.verify(initialPolicy: snapshot.initialPolicy)
        guard try await custodian.publicKey() == seal.custodianKey else {
            throw OrganizationVaultError.custodianKeyMismatch
        }
        let current: GovernancePolicy
        do {
            current = try GovernancePolicyChain.verify(
                seal: seal, initialPolicy: snapshot.initialPolicy, amendments: snapshot.amendments)
        } catch let error as GovernancePolicyChainError {
            throw OrganizationVaultError.amendment(error)
        }
        let issuerDID = try IdentityLinkProtocolService.did(for: seal.custodianKey)

        // The journal is the account of every signature. It must be an
        // unbroken chain that starts with the genesis status list.
        var previous: Data?
        for (index, entry) in snapshot.journal.enumerated() {
            guard entry.sequence == index + 1, entry.previousEntryHash == previous else {
                throw OrganizationVaultError.snapshotRefused(.journalBroken)
            }
            previous = try entry.entryHash()
        }
        guard let first = snapshot.journal.first, first.ruleID == "genesis",
              first.actionClass == OrganizationActionClass.roleStatusPublish,
              first.proposalHash == (try seal.sealHash()) else {
            throw OrganizationVaultError.snapshotRefused(.journalDoesNotStartAtGenesis)
        }

        // One journal entry per adopted policy version, in order.
        let amended = snapshot.journal.filter { $0.actionClass == OrganizationActionClass.policyAmend }
        guard amended.count == snapshot.amendments.count else {
            throw OrganizationVaultError.snapshotRefused(.amendmentsDoNotMatchJournal)
        }
        for (entry, amendment) in zip(amended, snapshot.amendments) {
            guard entry.payloadHash == (try amendment.policy.policyHash()),
                  entry.proposalHash == (try amendment.bundle.proposal.proposalHash()) else {
                throw OrganizationVaultError.snapshotRefused(.amendmentsDoNotMatchJournal)
            }
        }

        // The status list is the latest one the journal knows, signed by the
        // custodian key. Its sequence counts the lists the vault has signed.
        guard let list = snapshot.statusList else {
            throw OrganizationVaultError.snapshotRefused(.statusListMissing)
        }
        guard list.organizationAnchorID == seal.anchorID, list.issuerDID == issuerDID, list.signatureIsValid() else {
            throw OrganizationVaultError.snapshotRefused(.statusListNotSignedByCustodian)
        }
        let lists = snapshot.journal.filter {
            $0.actionClass == OrganizationActionClass.roleStatusPublish || $0.actionClass == OrganizationActionClass.roleRevoke
        }
        guard lists.count == list.sequence, let latest = lists.last,
              latest.payloadHash == (try list.payloadHash()),
              latest.signatureHash == OrganizationHashing.sha256(list.signature ?? Data()) else {
            throw OrganizationVaultError.snapshotRefused(.statusListDoesNotMatchJournal)
        }

        // Every credential is one the journal says was signed, and verifies.
        let issuedEntries = snapshot.journal.filter { $0.actionClass == OrganizationActionClass.roleIssue }
        var issued: [String: VCClaim] = [:]
        var accounted = Set<Int>()
        for claim in snapshot.issued {
            let payloadHash = try OrganizationRoleCredential.payloadHash(of: claim)
            let signatureHash = OrganizationHashing.sha256(claim.proof.signatureData)
            guard issued[claim.id] == nil,
                  let entry = issuedEntries.first(where: {
                      $0.payloadHash == payloadHash && $0.signatureHash == signatureHash && accounted.contains($0.sequence) == false
                  }) else {
                throw OrganizationVaultError.snapshotRefused(.credentialsDoNotMatchJournal)
            }
            guard Self.issuerDID(of: claim) == issuerDID, (try? await claim.verify()) == true else {
                throw OrganizationVaultError.snapshotRefused(.credentialNotSignedByCustodian(claim.id))
            }
            accounted.insert(entry.sequence)
            issued[claim.id] = claim
        }
        guard issued.count == issuedEntries.count else {
            throw OrganizationVaultError.snapshotRefused(.credentialsDoNotMatchJournal)
        }

        // One nonce per bundle acted on. A snapshot that has lost one would
        // let that bundle be replayed.
        let nonces = Set(snapshot.usedNonces)
        guard nonces.count == snapshot.usedNonces.count, nonces.count == snapshot.journal.count - 1,
              snapshot.amendments.allSatisfy({ nonces.contains($0.bundle.proposal.nonce) }) else {
            throw OrganizationVaultError.snapshotRefused(.noncesDoNotMatchJournal)
        }

        self.seal = seal
        self.displayName = seal.displayName
        self.initialPolicy = snapshot.initialPolicy
        self.policy = current
        self.custodian = custodian
        self.credentialType = snapshot.credentialType
        self.amendments = snapshot.amendments
        self.journal = snapshot.journal
        self.issued = issued
        self.statusList = list
        self.usedNonces = nonces
    }

    private static func issuerDID(of claim: VCClaim) -> String? {
        switch claim.issuer {
        case .reference(let did):
            return did
        case .embedded(let object):
            if case .string(let did)? = object["id"] { return did }
            return nil
        }
    }

    /// The state to store. Take it after every call that signs or amends.
    public func snapshot() -> OrganizationVaultSnapshot {
        OrganizationVaultSnapshot(
            seal: seal, initialPolicy: initialPolicy, credentialType: credentialType,
            amendments: amendments, journal: journal,
            issued: issued.values.sorted { $0.id < $1.id },
            statusList: statusList,
            usedNonces: usedNonces.sorted { $0.lexicographicallyPrecedes($1) })
    }

    public var keyIsExportable: Bool { custodian.keyIsExportable }

    public func issuerDID() throws -> String {
        try IdentityLinkProtocolService.did(for: seal.custodianKey)
    }

    // MARK: Proposals (built here so the summary always comes from the payload)

    public func proposeRole(
        subject: IdentityPublicKeyDescriptor,
        role: String,
        cohort: String?,
        validUntil: String,
        proposer: IdentityPublicKeyDescriptor,
        now: Date = Date(),
        lifetime: TimeInterval = 7 * 86_400
    ) throws -> (proposal: OrganizationActionProposal, credential: VCClaim) {
        let credential = try OrganizationRoleCredential.unsigned(
            organizationAnchorID: seal.anchorID, credentialType: credentialType, custodian: seal.custodianKey,
            subject: subject, role: role, cohort: cohort, validUntil: validUntil,
            policyHash: try policy.policyHash(), issuedAt: now)
        let proposal = OrganizationActionProposal(
            organizationAnchorID: seal.anchorID, policyHash: try policy.policyHash(),
            actionClass: OrganizationActionClass.roleIssue,
            payloadHash: try OrganizationRoleCredential.payloadHash(of: credential),
            payloadSummary: OrganizationRoleCredential.summary(of: credential, displayName: displayName),
            audience: seal.anchorID, createdAt: IdentityLinkProtocolService.iso8601(now),
            expiresAt: IdentityLinkProtocolService.iso8601(now.addingTimeInterval(lifetime)),
            nonce: Data(UUID().uuidString.utf8), proposer: proposer)
        return (proposal, credential)
    }

    public func proposeRevocation(
        credentialIDs: [String],
        proposer: IdentityPublicKeyDescriptor,
        now: Date = Date(),
        lifetime: TimeInterval = 7 * 86_400
    ) throws -> (proposal: OrganizationActionProposal, list: OrganizationRoleStatusList) {
        for id in credentialIDs where issued[id] == nil { throw OrganizationVaultError.unknownCredential(id) }
        let list = try nextStatusList(adding: credentialIDs, now: now)
        let newly = credentialIDs.filter { statusList?.revokedCredentialIDs.contains($0) != true }
        let proposal = OrganizationActionProposal(
            organizationAnchorID: seal.anchorID, policyHash: try policy.policyHash(),
            actionClass: OrganizationActionClass.roleRevoke, payloadHash: try list.payloadHash(),
            payloadSummary: list.summary(displayName: displayName, newlyRevoked: newly),
            audience: seal.anchorID, createdAt: IdentityLinkProtocolService.iso8601(now),
            expiresAt: IdentityLinkProtocolService.iso8601(now.addingTimeInterval(lifetime)),
            nonce: Data(UUID().uuidString.utf8), proposer: proposer)
        return (proposal, list)
    }

    public func proposeAmendment(
        next: GovernancePolicy,
        proposer: IdentityPublicKeyDescriptor,
        now: Date = Date(),
        lifetime: TimeInterval = 7 * 86_400
    ) throws -> OrganizationActionProposal {
        try GovernancePolicyAmendment.proposal(
            replacing: policy, with: next, organizationAnchorID: seal.anchorID, proposer: proposer,
            createdAt: IdentityLinkProtocolService.iso8601(now),
            expiresAt: IdentityLinkProtocolService.iso8601(now.addingTimeInterval(lifetime)),
            nonce: Data(UUID().uuidString.utf8))
    }

    // MARK: Signing

    /// Signs the role credential if the bundle binds the organization.
    public func issueRole(credential: VCClaim, bundle: ApprovalBundle, now: Date = Date()) async throws -> VCClaim {
        let payloadHash = try OrganizationRoleCredential.payloadHash(of: credential)
        let summary = OrganizationRoleCredential.summary(of: credential, displayName: displayName)
        let evaluation = try admit(bundle, actionClass: OrganizationActionClass.roleIssue,
                                   payloadHash: payloadHash, summary: summary, now: now)
        var signed = credential
        try await signed.generateProof(issuerIdentity: try await custodian.signingIdentity())
        try record(bundle: bundle, evaluation: evaluation, payloadHash: payloadHash, signature: signed.proof.signatureData, now: now)
        issued[signed.id] = signed
        return signed
    }

    /// Signs the next status list if the bundle binds the organization.
    public func revoke(list: OrganizationRoleStatusList, bundle: ApprovalBundle, now: Date = Date()) async throws -> OrganizationRoleStatusList {
        let previous = Set(statusList?.revokedCredentialIDs ?? [])
        let newly = list.revokedCredentialIDs.filter { previous.contains($0) == false }
        let expected = try nextStatusList(adding: list.revokedCredentialIDs, now: now)
        guard list.sequence == expected.sequence, list.issuerDID == expected.issuerDID,
              list.organizationAnchorID == seal.anchorID,
              previous.isSubset(of: Set(list.revokedCredentialIDs)) else {
            throw OrganizationVaultError.payloadDoesNotMatchApprovedHash
        }
        let evaluation = try admit(bundle, actionClass: OrganizationActionClass.roleRevoke,
                                   payloadHash: try list.payloadHash(),
                                   summary: list.summary(displayName: displayName, newlyRevoked: newly), now: now)
        var signed = list
        signed.signature = try await custodian.sign(try list.canonicalPayloadData())
        try record(bundle: bundle, evaluation: evaluation, payloadHash: try list.payloadHash(), signature: signed.signature ?? Data(), now: now)
        statusList = signed
        return signed
    }

    /// Adopts the next policy version if the bundle satisfies the amendment rule.
    public func amend(to next: GovernancePolicy, bundle: ApprovalBundle, now: Date = Date()) throws {
        let amendment = GovernancePolicyAmendment(policy: next, bundle: bundle)
        do {
            try GovernancePolicyChain.verify(step: amendment, replacing: policy, organizationAnchorID: seal.anchorID)
        } catch let error as GovernancePolicyChainError {
            throw OrganizationVaultError.amendment(error)
        }
        let evaluation = try admit(bundle, actionClass: OrganizationActionClass.policyAmend,
                                   payloadHash: try next.policyHash(),
                                   summary: GovernancePolicyAmendment.summary(replacing: policy, with: next), now: now)
        try record(bundle: bundle, evaluation: evaluation, payloadHash: try next.policyHash(), signature: Data(), now: now)
        amendments.append(amendment)
        policy = next
    }

    /// The whole chain still verifies from genesis.
    public func verifyChain() throws -> GovernancePolicy {
        try GovernancePolicyChain.verify(seal: seal, initialPolicy: initialPolicy, amendments: amendments)
    }

    /// Every entry points at the hash of the one before it.
    public func journalIsIntact() -> Bool {
        var previous: Data?
        for (index, entry) in journal.enumerated() {
            guard entry.sequence == index + 1, entry.previousEntryHash == previous,
                  let hash = try? entry.entryHash() else { return false }
            previous = hash
        }
        return true
    }

    // MARK: Internals

    private func admit(
        _ bundle: ApprovalBundle,
        actionClass: String,
        payloadHash: Data,
        summary: String,
        now: Date
    ) throws -> GovernanceEvaluation {
        let proposal = bundle.proposal
        guard proposal.organizationAnchorID == seal.anchorID else { throw OrganizationVaultError.proposalForOtherOrganization }
        guard proposal.actionClass == actionClass else {
            throw OrganizationVaultError.actionClassMismatch(expected: actionClass, found: proposal.actionClass)
        }
        guard usedNonces.contains(proposal.nonce) == false else { throw OrganizationVaultError.nonceAlreadyUsed }
        guard proposal.payloadHash == payloadHash else { throw OrganizationVaultError.payloadDoesNotMatchApprovedHash }
        guard proposal.payloadSummary == summary else { throw OrganizationVaultError.summaryDoesNotMatchPayload }
        do {
            return try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: bundle, now: now)
        } catch let error as GovernanceEvaluationError {
            throw OrganizationVaultError.refused(error)
        }
    }

    private func record(bundle: ApprovalBundle, evaluation: GovernanceEvaluation, payloadHash: Data, signature: Data, now: Date) throws {
        usedNonces.insert(bundle.proposal.nonce)
        let entry = OrganizationJournalEntry(
            sequence: journal.count + 1,
            previousEntryHash: try journal.last?.entryHash(),
            recordedAt: IdentityLinkProtocolService.iso8601(now),
            actionClass: bundle.proposal.actionClass,
            proposalHash: try bundle.proposal.proposalHash(),
            payloadHash: payloadHash,
            payloadSummary: bundle.proposal.payloadSummary,
            policyVersion: policy.version,
            ruleID: evaluation.ruleID,
            approverUUIDs: evaluation.approverUUIDs,
            signatureHash: OrganizationHashing.sha256(signature)
        )
        journal.append(entry)
    }

    private func nextStatusList(adding ids: [String], now: Date) throws -> OrganizationRoleStatusList {
        OrganizationRoleStatusList(
            organizationAnchorID: seal.anchorID,
            issuerDID: try issuerDID(),
            sequence: (statusList?.sequence ?? 0) + 1,
            issuedAt: IdentityLinkProtocolService.iso8601(now),
            revokedCredentialIDs: (statusList?.revokedCredentialIDs ?? []) + ids
        )
    }
}
