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
    /// The credential is not of this vault's type, or does not name the
    /// policy in force.
    case credentialNotForThisVault
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
    /// The entry with this sequence does not carry the custodian's signature.
    case journalEntryNotSignedByCustodian(sequence: Int)
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
/// verifies from it, the journal is an unbroken chain from genesis in which
/// the custodian key has signed every entry, and every entry after genesis is
/// re-derived from the owners' signed approvals under the policy in force at
/// the time. The status list and every credential must verify under the
/// custodian key and be the ones the journal records.
///
/// What it cannot check: whoever controls the storage can hand back an older
/// complete snapshot. Each entry is signed together with the hash of the one
/// before it, so entries cannot be changed, reordered or taken out of the
/// middle, but the latest ones can be cut off. A node that mirrors the status
/// list refuses a lower sequence, which exposes a rollback of a revocation
/// until the vault signs that sequence again. Keep the storage with someone
/// the owners trust not to roll it back.
public struct OrganizationVaultSnapshot: Codable, @unchecked Sendable {
    public static let currentSchema = "haven.organization-vault-snapshot.v1"

    public var schema: String
    public var seal: OrganizationGenesisSeal
    public var initialPolicy: GovernancePolicy
    public var credentialType: String
    public var amendments: [GovernancePolicyAmendment]
    public var journal: [OrganizationJournalEntry]
    /// The custodian's signature over each journal entry, in order.
    public var journalSignatures: [Data]
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
        journalSignatures: [Data],
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
        self.journalSignatures = journalSignatures
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
    /// Everything that changes. A signing call builds the next state, has it
    /// stored, and only then adopts it, so nothing can be read from the vault
    /// that the storage does not hold.
    private struct State {
        var amendments: [GovernancePolicyAmendment] = []
        var policy: GovernancePolicy
        var journal: [OrganizationJournalEntry] = []
        var journalSignatures: [Data] = []
        var bundles: [ApprovalBundle] = []
        var issued: [String: VCClaim] = [:]
        var statusList: OrganizationRoleStatusList?
    }
    private var state: State
    private var usedNonces = Set<Data>()

    public var amendments: [GovernancePolicyAmendment] { state.amendments }
    public var policy: GovernancePolicy { state.policy }
    public var journal: [OrganizationJournalEntry] { state.journal }
    public var issued: [String: VCClaim] { state.issued.mapValues { $0.detached() } }
    public var statusList: OrganizationRoleStatusList? { state.statusList }
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
        let entry = OrganizationJournalEntry(
            sequence: 1, previousEntryHash: nil, recordedAt: seal.sealedAt,
            actionClass: OrganizationActionClass.roleStatusPublish, proposalHash: try seal.sealHash(),
            payloadHash: try first.payloadHash(), payloadSummary: Self.genesisSummary,
            policyVersion: initialPolicy.version, ruleID: Self.genesisRuleID,
            approverUUIDs: seal.founders.map(\.uuid).sorted(),
            signatureHash: OrganizationHashing.sha256(first.signature ?? Data()))
        let genesis = State(
            policy: initialPolicy, journal: [entry],
            journalSignatures: [try await custodian.sign(try Self.journalSigningData(entry))],
            statusList: first)
        self.state = genesis
        try await store?(Self.snapshot(of: genesis, seal: seal, initialPolicy: initialPolicy, credentialType: credentialType))
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
        // The custodian signed every entry together with the hash of the one
        // before it. Without the key the chain cannot be rewritten.
        for (index, entry) in snapshot.journal.enumerated() {
            guard index < snapshot.journalSignatures.count,
                  IdentityPublicKeySignatureVerifier.verify(
                      signature: snapshot.journalSignatures[index],
                      messageData: try Self.journalSigningData(entry),
                      descriptor: seal.custodianKey) else {
                throw refuse(.journalEntryNotSignedByCustodian(sequence: entry.sequence))
            }
        }
        guard snapshot.journalSignatures.count == snapshot.journal.count else {
            throw refuse(.journalEntryNotSignedByCustodian(sequence: snapshot.journal.count + 1))
        }
        let firstList = OrganizationRoleStatusList(
            organizationAnchorID: seal.anchorID, issuerDID: issuerDID, sequence: 1,
            issuedAt: seal.sealedAt, revokedCredentialIDs: [])
        guard let first = snapshot.journal.first, first.ruleID == Self.genesisRuleID,
              first.actionClass == OrganizationActionClass.roleStatusPublish,
              first.proposalHash == (try seal.sealHash()),
              first.policyVersion == snapshot.initialPolicy.version,
              first.recordedAt == seal.sealedAt,
              first.payloadSummary == Self.genesisSummary,
              first.approverUUIDs == seal.founders.map(\.uuid).sorted(),
              first.payloadHash == (try firstList.payloadHash()) else {
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
                      entry.payloadHash == (try amendment.policy.policyHash()),
                      entry.signatureHash == OrganizationHashing.sha256(Data()) else {
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
        for stored in snapshot.issued {
            // A proof object of the vault's own: the caller keeps the one in
            // the snapshot and could change it later.
            let claim = stored.detached()
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
        self.custodian = custodian
        self.credentialType = credentialType
        self.store = store
        self.state = State(
            amendments: snapshot.amendments, policy: current, journal: snapshot.journal,
            journalSignatures: snapshot.journalSignatures, bundles: snapshot.bundles,
            issued: issued, statusList: list)
        self.usedNonces = nonces
    }

    /// The state to store. With a `store` the vault hands it over itself.
    public func snapshot() -> OrganizationVaultSnapshot {
        Self.snapshot(of: state, seal: seal, initialPolicy: initialPolicy, credentialType: credentialType)
    }

    private static func snapshot(
        of state: State, seal: OrganizationGenesisSeal, initialPolicy: GovernancePolicy, credentialType: String
    ) -> OrganizationVaultSnapshot {
        OrganizationVaultSnapshot(
            seal: seal, initialPolicy: initialPolicy, credentialType: credentialType,
            amendments: state.amendments, journal: state.journal, journalSignatures: state.journalSignatures,
            bundles: state.bundles,
            issued: state.issued.values.map { $0.detached() }.sorted { $0.id < $1.id },
            statusList: state.statusList)
    }

    /// What the custodian signs for a journal entry. The tag keeps the
    /// signature from being taken for one over a status list or a credential.
    static func journalSigningData(_ entry: OrganizationJournalEntry) throws -> Data {
        Data("haven.organization.journal-entry.v1\n".utf8) + (try entry.canonicalPayloadData())
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
        for id in credentialIDs where state.issued[id] == nil { throw OrganizationVaultError.unknownCredential(id) }
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

    /// Signs the role credential if the bundle binds the organization. The
    /// credential passed in is left unsigned; the signed one is the result.
    public func issueRole(credential: VCClaim, bundle: ApprovalBundle, now: Date = Date()) async throws -> VCClaim {
        try begin()
        defer { busy = false }
        let payloadHash = try OrganizationRoleCredential.payloadHash(of: credential)
        let summary = OrganizationRoleCredential.summary(of: credential, displayName: displayName)
        let evaluation = try admit(bundle, actionClass: OrganizationActionClass.roleIssue,
                                   payloadHash: payloadHash, summary: summary, now: now)
        // A fresh approval of a credential that is already signed would put a
        // second signature behind one id.
        guard state.issued[credential.id] == nil else { throw OrganizationVaultError.credentialAlreadyIssued(credential.id) }
        // The summary the owners saw shows neither of these, and a vault that
        // signed such a credential could not be restored afterwards.
        guard credential.type.contains(credentialType),
              case .string(let named)? = credential.credentialSubject[OrganizationRoleCredential.Field.policyHash],
              named == (try state.policy.policyHash().base64EncodedString()) else {
            throw OrganizationVaultError.credentialNotForThisVault
        }
        var signed = credential.detached()
        try await signed.generateProof(issuerIdentity: try await custodian.signingIdentity())
        var next = state
        try await record(in: &next, bundle: bundle, evaluation: evaluation, payloadHash: payloadHash,
                         signature: signed.proof.signatureData, now: now)
        next.issued[signed.id] = signed
        try await commit(next, nonce: bundle.proposal.nonce)
        return signed.detached()
    }

    /// Signs the next status list if the bundle binds the organization.
    public func revoke(list: OrganizationRoleStatusList, bundle: ApprovalBundle, now: Date = Date()) async throws -> OrganizationRoleStatusList {
        try begin()
        defer { busy = false }
        let previous = Set(state.statusList?.revokedCredentialIDs ?? [])
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
        var next = state
        try await record(in: &next, bundle: bundle, evaluation: evaluation, payloadHash: try list.payloadHash(),
                         signature: signed.signature ?? Data(), now: now)
        next.statusList = signed
        try await commit(next, nonce: bundle.proposal.nonce)
        return signed
    }

    /// Adopts the next policy version if the bundle satisfies the amendment rule.
    public func amend(to next: GovernancePolicy, bundle: ApprovalBundle, now: Date = Date()) async throws {
        try begin()
        defer { busy = false }
        let amendment = GovernancePolicyAmendment(policy: next, bundle: bundle)
        do {
            try GovernancePolicyChain.verify(step: amendment, replacing: state.policy, organizationAnchorID: seal.anchorID)
        } catch let error as GovernancePolicyChainError {
            throw OrganizationVaultError.amendment(error)
        }
        let evaluation = try admit(bundle, actionClass: OrganizationActionClass.policyAmend,
                                   payloadHash: try next.policyHash(),
                                   summary: GovernancePolicyAmendment.summary(replacing: state.policy, with: next), now: now)
        // Nothing but the journal entry is signed here. That signature is what
        // says the vault accepted the amendment, and when.
        var adopted = state
        try await record(in: &adopted, bundle: bundle, evaluation: evaluation, payloadHash: try next.policyHash(),
                         signature: Data(), now: now)
        adopted.amendments.append(amendment)
        adopted.policy = next
        try await commit(adopted, nonce: bundle.proposal.nonce)
    }

    /// The whole chain still verifies from genesis.
    public func verifyChain() throws -> GovernancePolicy {
        try GovernancePolicyChain.verify(seal: seal, initialPolicy: initialPolicy, amendments: state.amendments)
    }

    /// Every entry points at the hash of the one before it.
    public func journalIsIntact() -> Bool {
        var previous: Data?
        for (index, entry) in state.journal.enumerated() {
            guard entry.sequence == index + 1, entry.previousEntryHash == previous,
                  let hash = try? entry.entryHash() else { return false }
            previous = hash
        }
        return true
    }

    // MARK: Internals

    private static let genesisRuleID = "genesis"
    private static let genesisSummary = "Tom statusliste ved opprettelsen"
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

    /// Has the next state stored and then adopts it. If the store fails the
    /// vault keeps the state it had, which is the last one stored, and signs
    /// nothing more: a signature exists that the storage may or may not hold.
    private func commit(_ next: State, nonce: Data) async throws {
        if let store {
            do {
                try await store(Self.snapshot(of: next, seal: seal, initialPolicy: initialPolicy, credentialType: credentialType))
            } catch {
                storeFailed = true
                throw error
            }
        }
        state = next
        usedNonces.insert(nonce)
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
            return try GovernancePolicyEvaluator.evaluate(policy: state.policy, bundle: bundle, now: now)
        } catch let error as GovernanceEvaluationError {
            throw OrganizationVaultError.refused(error)
        }
    }

    /// Appends the journal entry for a signature to the next state, signed by
    /// the custodian together with the hash of the entry before it.
    private func record(
        in next: inout State, bundle: ApprovalBundle, evaluation: GovernanceEvaluation,
        payloadHash: Data, signature: Data, now: Date
    ) async throws {
        let entry = OrganizationJournalEntry(
            sequence: next.journal.count + 1,
            previousEntryHash: try next.journal.last?.entryHash(),
            recordedAt: IdentityLinkProtocolService.iso8601(now),
            actionClass: bundle.proposal.actionClass,
            proposalHash: try bundle.proposal.proposalHash(),
            payloadHash: payloadHash,
            payloadSummary: bundle.proposal.payloadSummary,
            policyVersion: next.policy.version,
            ruleID: evaluation.ruleID,
            approverUUIDs: evaluation.approverUUIDs,
            signatureHash: OrganizationHashing.sha256(signature)
        )
        let entrySignature = try await custodian.sign(try Self.journalSigningData(entry))
        next.journal.append(entry)
        next.journalSignatures.append(entrySignature)
        next.bundles.append(bundle)
    }

    private func nextStatusList(adding ids: [String], now: Date) throws -> OrganizationRoleStatusList {
        OrganizationRoleStatusList(
            organizationAnchorID: seal.anchorID,
            issuerDID: try issuerDID(),
            sequence: (state.statusList?.sequence ?? 0) + 1,
            issuedAt: IdentityLinkProtocolService.iso8601(now),
            revokedCredentialIDs: (state.statusList?.revokedCredentialIDs ?? []) + ids
        )
    }
}
