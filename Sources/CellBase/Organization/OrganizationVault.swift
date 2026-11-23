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
    /// The credential id already has a signed credential.
    case credentialAlreadyIssued(String)
    /// The vault signs one thing at a time. Ask again when the call in
    /// progress has returned.
    case signingInProgress
    /// An earlier change could not be stored. The vault signs nothing more;
    /// start a new one from the last stored snapshot.
    case stateNotStored
    case snapshotRefused(OrganizationVaultSnapshotError)
}

/// Why a stored vault state was not adopted. Restoring fails closed: a vault
/// that cannot account for every signature it has made does not start.
public enum OrganizationVaultSnapshotError: Error, Equatable, Sendable {
    case unsupportedSchema(String)
    /// The seal is not the one the caller expects for this organization.
    case sealNotExpected
    case credentialTypeNotExpected(String)
    case journalBroken
    case journalDoesNotStartAtGenesis
    /// The entry with this sequence is not what the owners' signed approvals
    /// say was approved, under the policy in force when it was recorded.
    case journalEntryNotBackedByApprovals(sequence: Int)
    case amendmentsDoNotMatchJournal
    case statusListMissing
    case statusListNotSignedByCustodian
    case statusListDoesNotMatchJournal
    case credentialNotSignedByCustodian(String)
    case credentialsDoNotMatchJournal
    /// The credential names a policy that is not in the chain.
    case credentialUnderUnknownPolicy(String)
}

/// Everything a vault must remember across a restart, except the key. The
/// key stays with the custodian.
///
/// What restoring checks: the seal is the expected one, the policy chain
/// verifies from it, the journal is an unbroken chain from genesis, and every
/// entry after genesis is re-derived from the owners' signed approvals under
/// the policy in force at the time. The status list and every credential must
/// verify under the custodian key and be the ones the journal records.
///
/// What it cannot check: the journal is not signed, so whoever controls the
/// storage can hand back an older complete snapshot, or one where the latest
/// entries, or a role that was issued, have been removed consistently. A node
/// that mirrors the status list refuses a lower sequence, which exposes a
/// rollback of a revocation until the vault signs that sequence again. Keep
/// the storage with someone the owners trust not to roll it back.
public struct OrganizationVaultSnapshot: Codable, @unchecked Sendable {
    public static let currentSchema = "haven.organization-vault-snapshot.v1"

    public var schema: String
    public var seal: OrganizationGenesisSeal
    public var initialPolicy: GovernancePolicy
    public var credentialType: String
    public var amendments: [GovernancePolicyAmendment]
    public var journal: [OrganizationJournalEntry]
    /// The approval bundle behind each journal entry after genesis, in order.
    public var bundles: [ApprovalBundle]
    /// Issued credentials, ordered by id.
    public var issued: [VCClaim]
    public var statusList: OrganizationRoleStatusList?

    public init(
        schema: String = OrganizationVaultSnapshot.currentSchema,
        seal: OrganizationGenesisSeal,
        initialPolicy: GovernancePolicy,
        credentialType: String,
        amendments: [GovernancePolicyAmendment],
        journal: [OrganizationJournalEntry],
        bundles: [ApprovalBundle],
        issued: [VCClaim],
        statusList: OrganizationRoleStatusList?
    ) {
        self.schema = schema
        self.seal = seal
        self.initialPolicy = initialPolicy
        self.credentialType = credentialType
        self.amendments = amendments
        self.journal = journal
        self.bundles = bundles
        self.issued = issued
        self.statusList = statusList
    }
}

/// Stores the vault's state. Called after every change and before the signed
/// result is handed out, so nothing leaves the vault that a restart forgets.
public typealias OrganizationVaultStore = @Sendable (OrganizationVaultSnapshot) async throws -> Void

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
    private let store: OrganizationVaultStore?
    public private(set) var amendments: [GovernancePolicyAmendment] = []
    public private(set) var policy: GovernancePolicy
    public private(set) var journal: [OrganizationJournalEntry] = []
    public private(set) var issued: [String: VCClaim] = [:]
    public private(set) var statusList: OrganizationRoleStatusList?
    private var bundles: [ApprovalBundle] = []
    private var usedNonces = Set<Data>()
    private var busy = false
    private var storeFailed = false

    public init(
        seal: OrganizationGenesisSeal,
        initialPolicy: GovernancePolicy,
        custodian: OrganizationKeyCustodian,
        credentialType: String,
        store: OrganizationVaultStore? = nil
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
        self.store = store
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
            policyVersion: initialPolicy.version, ruleID: Self.genesisRuleID,
            approverUUIDs: seal.founders.map(\.uuid).sorted(),
            signatureHash: OrganizationHashing.sha256(first.signature ?? Data()))]
        try await store?(snapshot())
    }

    /// Starts the vault from a stored snapshot instead of from genesis, so
    /// issued roles, the status list sequence and the used nonces survive a
    /// restart. Nothing is signed here.
    ///
    /// `expectedSealHash` and `credentialType` must come from somewhere other
    /// than the storage the snapshot was read from, such as the deployment's
    /// configuration. They are what ties the stored state to this organization.
    public init(
        restoring snapshot: OrganizationVaultSnapshot,
        expectedSealHash: Data,
        credentialType: String,
        custodian: OrganizationKeyCustodian,
        store: OrganizationVaultStore? = nil
    ) async throws {
        func refuse(_ reason: OrganizationVaultSnapshotError) -> OrganizationVaultError { .snapshotRefused(reason) }
        guard snapshot.schema == OrganizationVaultSnapshot.currentSchema else {
            throw refuse(.unsupportedSchema(snapshot.schema))
        }
        let seal = snapshot.seal
        guard try seal.sealHash() == expectedSealHash else { throw refuse(.sealNotExpected) }
        try seal.verify(initialPolicy: snapshot.initialPolicy)
        guard try await custodian.publicKey() == seal.custodianKey else {
            throw OrganizationVaultError.custodianKeyMismatch
        }
        guard snapshot.credentialType == credentialType else {
            throw refuse(.credentialTypeNotExpected(snapshot.credentialType))
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
                throw refuse(.journalBroken)
            }
            previous = try entry.entryHash()
        }
        guard let first = snapshot.journal.first, first.ruleID == Self.genesisRuleID,
              first.actionClass == OrganizationActionClass.roleStatusPublish,
              first.proposalHash == (try seal.sealHash()),
              first.policyVersion == snapshot.initialPolicy.version else {
            throw refuse(.journalDoesNotStartAtGenesis)
        }

        // Every later entry is re-derived from the owners' signed approvals,
        // under the policy that was in force when it was recorded. The hash
        // chain alone can be recomputed by anyone; the approvals cannot.
        let later = Array(snapshot.journal.dropFirst())
        guard later.count == snapshot.bundles.count else {
            throw refuse(.journalEntryNotBackedByApprovals(sequence: min(later.count, snapshot.bundles.count) + 2))
        }
        var inForce = snapshot.initialPolicy
        var pendingAmendments = snapshot.amendments[...]
        var nonces = Set<Data>()
        for (entry, bundle) in zip(later, snapshot.bundles) {
            let proposal = bundle.proposal
            let unbacked = refuse(.journalEntryNotBackedByApprovals(sequence: entry.sequence))
            guard proposal.organizationAnchorID == seal.anchorID,
                  proposal.actionClass == entry.actionClass,
                  Self.approvedActionClasses.contains(entry.actionClass),
                  (try proposal.proposalHash()) == entry.proposalHash,
                  proposal.payloadHash == entry.payloadHash,
                  proposal.payloadSummary == entry.payloadSummary,
                  entry.policyVersion == inForce.version,
                  proposal.policyHash == (try inForce.policyHash()),
                  nonces.insert(proposal.nonce).inserted,
                  let recordedAt = ISO8601DateFormatter().date(from: entry.recordedAt),
                  let evaluation = try? GovernancePolicyEvaluator.evaluate(policy: inForce, bundle: bundle, now: recordedAt),
                  evaluation.ruleID == entry.ruleID, evaluation.approverUUIDs == entry.approverUUIDs else {
                throw unbacked
            }
            if entry.actionClass == OrganizationActionClass.policyAmend {
                guard let amendment = pendingAmendments.popFirst(), amendment.bundle == bundle,
                      entry.payloadHash == (try amendment.policy.policyHash()) else {
                    throw refuse(.amendmentsDoNotMatchJournal)
                }
                inForce = amendment.policy
            }
        }
        guard pendingAmendments.isEmpty, inForce == current else { throw refuse(.amendmentsDoNotMatchJournal) }

        // The status list is the latest one the journal knows, signed by the
        // custodian key. Its sequence counts the lists the vault has signed.
        guard let list = snapshot.statusList else { throw refuse(.statusListMissing) }
        guard list.organizationAnchorID == seal.anchorID, list.issuerDID == issuerDID, list.signatureIsValid() else {
            throw refuse(.statusListNotSignedByCustodian)
        }
        let lists = snapshot.journal.filter {
            $0.actionClass == OrganizationActionClass.roleStatusPublish || $0.actionClass == OrganizationActionClass.roleRevoke
        }
        guard lists.count == list.sequence, let latest = lists.last,
              latest.payloadHash == (try list.payloadHash()),
              latest.signatureHash == OrganizationHashing.sha256(list.signature ?? Data()) else {
            throw refuse(.statusListDoesNotMatchJournal)
        }

        // Every credential is one the journal says was signed, verifies under
        // the custodian key and names a policy in the chain.
        let policyHashes = Set(try ([snapshot.initialPolicy] + snapshot.amendments.map(\.policy))
            .map { try $0.policyHash().base64EncodedString() })
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
                throw refuse(.credentialsDoNotMatchJournal)
            }
            guard Self.issuerDID(of: claim) == issuerDID, claim.type.contains(credentialType),
                  (try? await claim.verify()) == true else {
                throw refuse(.credentialNotSignedByCustodian(claim.id))
            }
            guard case .string(let named)? = claim.credentialSubject[OrganizationRoleCredential.Field.policyHash],
                  policyHashes.contains(named) else {
                throw refuse(.credentialUnderUnknownPolicy(claim.id))
            }
            accounted.insert(entry.sequence)
            issued[claim.id] = claim
        }
        guard issued.count == issuedEntries.count else { throw refuse(.credentialsDoNotMatchJournal) }

        self.seal = seal
        self.displayName = seal.displayName
        self.initialPolicy = snapshot.initialPolicy
        self.policy = current
        self.custodian = custodian
        self.credentialType = credentialType
        self.store = store
        self.amendments = snapshot.amendments
        self.journal = snapshot.journal
        self.bundles = snapshot.bundles
        self.issued = issued
        self.statusList = list
        self.usedNonces = nonces
    }

    /// The state to store. With a `store` the vault hands it over itself.
    public func snapshot() -> OrganizationVaultSnapshot {
        OrganizationVaultSnapshot(
            seal: seal, initialPolicy: initialPolicy, credentialType: credentialType,
            amendments: amendments, journal: journal, bundles: bundles,
            issued: issued.values.sorted { $0.id < $1.id },
            statusList: statusList)
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
        try begin()
        defer { busy = false }
        let payloadHash = try OrganizationRoleCredential.payloadHash(of: credential)
        let summary = OrganizationRoleCredential.summary(of: credential, displayName: displayName)
        let evaluation = try admit(bundle, actionClass: OrganizationActionClass.roleIssue,
                                   payloadHash: payloadHash, summary: summary, now: now)
        // A fresh approval of a credential that is already signed would put a
        // second signature behind one id.
        guard issued[credential.id] == nil else { throw OrganizationVaultError.credentialAlreadyIssued(credential.id) }
        var signed = credential
        try await signed.generateProof(issuerIdentity: try await custodian.signingIdentity())
        try record(bundle: bundle, evaluation: evaluation, payloadHash: payloadHash, signature: signed.proof.signatureData, now: now)
        issued[signed.id] = signed
        try await persist()
        return signed
    }

    /// Signs the next status list if the bundle binds the organization.
    public func revoke(list: OrganizationRoleStatusList, bundle: ApprovalBundle, now: Date = Date()) async throws -> OrganizationRoleStatusList {
        try begin()
        defer { busy = false }
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
        try await persist()
        return signed
    }

    /// Adopts the next policy version if the bundle satisfies the amendment rule.
    public func amend(to next: GovernancePolicy, bundle: ApprovalBundle, now: Date = Date()) async throws {
        try begin()
        defer { busy = false }
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
        try await persist()
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

    private static let genesisRuleID = "genesis"
    private static let approvedActionClasses: Set<String> = [
        OrganizationActionClass.roleIssue, OrganizationActionClass.roleRevoke, OrganizationActionClass.policyAmend,
    ]

    private static func issuerDID(of claim: VCClaim) -> String? {
        switch claim.issuer {
        case .reference(let did):
            return did
        case .embedded(let object):
            if case .string(let did)? = object["id"] { return did }
            return nil
        }
    }

    /// One signing call at a time. The calls wait on the custodian and the
    /// store, and a second call let in meanwhile would check its nonce and
    /// sequence against a state that is about to change.
    private func begin() throws {
        guard storeFailed == false else { throw OrganizationVaultError.stateNotStored }
        guard busy == false else { throw OrganizationVaultError.signingInProgress }
        busy = true
    }

    private func persist() async throws {
        guard let store else { return }
        do {
            try await store(snapshot())
        } catch {
            storeFailed = true
            throw error
        }
    }

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
        usedNonces.insert(bundle.proposal.nonce)
        journal.append(entry)
        bundles.append(bundle)
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
