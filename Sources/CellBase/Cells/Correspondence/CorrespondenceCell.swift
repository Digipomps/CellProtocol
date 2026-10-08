// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

public enum CorrespondenceDenialReason: String, Codable, Sendable {
    case plaintextRejected
    case membershipFingerprintMismatch
    case purposeNotAllowed
    case retentionOutOfPolicy
    case grantNotHeld
    case delegationRevoked
    case cellClosed
    case attachmentUnavailable
    case messageExpired
}

public struct CorrespondenceRetentionPolicy: Codable, Equatable, Sendable {
    public var defaultSecondsByPurpose: [String: Int]
    public var maximumSeconds: Int

    public init(defaultSecondsByPurpose: [String: Int], maximumSeconds: Int) {
        self.defaultSecondsByPurpose = defaultSecondsByPurpose
        self.maximumSeconds = maximumSeconds
    }

    public static let relationshipDefault = CorrespondenceRetentionPolicy(
        defaultSecondsByPurpose: [
            "purpose://contact.communication": 60 * 60 * 24 * 30,
            "purpose://digital-work.coordinate": 60 * 60 * 24 * 30
        ],
        maximumSeconds: 60 * 60 * 24 * 90
    )
}

private struct CorrespondenceInvitationLedgerRecord: Codable, Equatable, Sendable {
    var identityUUID: String
    var status: String
    var invitedAt: String
}

private enum CorrespondenceCellRuntimeError: Error {
    case flowEmitterUnavailable
}

/// Snapshotting and expiry can run concurrently with incoming client operations.
/// Keep dictionary mutations, sequence allocation and expiry comparisons atomic.
private final class CorrespondenceEnvelopeStore: Codable {
    private let lock = NSLock()
    private var entries: [String: CorrespondenceStoredEnvelope] = [:]
    private var sequence = 0
    init() {}
    required init(from decoder: Decoder) throws {
        entries = try decoder.singleValueContainer().decode([String: CorrespondenceStoredEnvelope].self)
    }
    func encode(to encoder: Encoder) throws {
        let snapshot = lock.withLock { entries }
        var container = encoder.singleValueContainer()
        try container.encode(snapshot)
    }
    var values: [CorrespondenceStoredEnvelope] { lock.withLock { Array(entries.values) } }
    subscript(id: String) -> CorrespondenceStoredEnvelope? { lock.withLock { entries[id] } }
    var nextSequence: Int {
        get { lock.withLock { sequence } }
        set { lock.withLock { sequence = newValue } }
    }
    func reserveSequence() -> Int {
        lock.withLock { let result = sequence; sequence += 1; return result }
    }
    func insert(_ record: CorrespondenceStoredEnvelope) -> Bool {
        lock.withLock {
            guard entries[record.outer.messageID] == nil else { return false }
            entries[record.outer.messageID] = record
            return true
        }
    }
    func update(_ record: CorrespondenceStoredEnvelope) -> Bool {
        lock.withLock {
            guard entries[record.outer.messageID]?.outer.sequence == record.outer.sequence else { return false }
            entries[record.outer.messageID] = record
            return true
        }
    }
    func remove(_ id: String, matchingSequence sequence: Int) -> Bool {
        lock.withLock {
            guard entries[id]?.outer.sequence == sequence else { return false }
            entries.removeValue(forKey: id)
            return true
        }
    }
}

/// A relationship-scoped, envelope-only message Cell for correspondence-domain
/// identities. Plaintext is accepted only by the client-side envelope utility.
public final class CorrespondenceCell: GeneralCell, MeddleOperationAuthorizationRequirementProviding {
    public static let flowTopic = "haven.correspondence"
    public static let envelopePurposeRef = "purpose://correspondence.envelope"
    public static let identityDomainName = "correspondence"

    private var storedEnvelopesByMessageID = CorrespondenceEnvelopeStore()
    private let membershipLock = NSRecursiveLock()
    private var appliedAuthorizationRevision = -1
    private var membershipRefreshTicket = 0
    private var appliedRefreshTicket = -1
    private var membershipIDs = [String]()
    private var memberIdentityUUIDs: [String] {
        get { membershipLock.withLock { membershipIDs } }
        set { membershipLock.withLock { membershipIDs = newValue } }
    }
    private var joins = CorrespondenceJoinLedger()
    private var invitationLedger = [CorrespondenceInvitationLedgerRecord]()
    private var version = 1
    private var fingerprint = ""
    private var membershipVersion: Int {
        get { membershipLock.withLock { version } }
        set { membershipLock.withLock { version = newValue } }
    }
    private var membershipFingerprint: String {
        get { membershipLock.withLock { fingerprint } }
        set { membershipLock.withLock { fingerprint = newValue } }
    }
    private var attachmentCellValues: [String: CorrespondenceAttachmentCell] = [:]
    private var attachmentCells: [String: CorrespondenceAttachmentCell] {
        get { membershipLock.withLock { attachmentCellValues } }
        set { membershipLock.withLock { attachmentCellValues = newValue } }
    }
    private var membershipTestHook: (() async -> Void)?
    private var joinDecisionTestHook: (() async -> Void)?
    var beforeJoinDecisionCommitForTesting: (() async -> Void)? {
        get { membershipLock.withLock { joinDecisionTestHook } }
        set { membershipLock.withLock { joinDecisionTestHook = newValue } }
    }
    private var sendTestHook: (() async -> Void)?
    private var attachmentTestHook: (() async -> Void)?
    var beforeMembershipApplyForTesting: (() async -> Void)? {
        get { membershipLock.withLock { membershipTestHook } }
        set { membershipLock.withLock { membershipTestHook = newValue } }
    }
    var beforeSendCommitForTesting: (() async -> Void)? {
        get { membershipLock.withLock { sendTestHook } }
        set { membershipLock.withLock { sendTestHook = newValue } }
    }
    var beforeAttachmentCommitForTesting: (() async -> Void)? {
        get { membershipLock.withLock { attachmentTestHook } }
        set { membershipLock.withLock { attachmentTestHook = newValue } }
    }
    private var attachmentRoot: URL?
    private var attachmentProvisioningRequired = false
    private var attachmentReservations: Set<String> = []
    private var nextSequence: Int {
        get { storedEnvelopesByMessageID.nextSequence }
        set { storedEnvelopesByMessageID.nextSequence = newValue }
    }
    private var retentionPolicy = CorrespondenceRetentionPolicy.relationshipDefault
    private var nowProvider: () -> Date = Date.init
    private var cellOwnedFlowEmitter: ((FlowElement) -> Void)?

    private enum CodingKeys: String, CodingKey {
        case storedEnvelopesByMessageID
        case memberIdentityUUIDs
        case invitationLedger
        case membershipVersion
        case membershipFingerprint
        case nextSequence
        case retentionPolicy
        case attachmentCells
        case attachmentRoot
        case joins
    }

    public required init(owner: Identity) async {
        await super.init(owner: owner)
        configureFixedPolicy(owner: owner)
        establishInitialMembership(ownerUUID: owner.uuid)
        try? await ensureRuntimeReady()
    }

    init(
        owner: Identity,
        retentionPolicy: CorrespondenceRetentionPolicy = .relationshipDefault,
        nowProvider: @escaping () -> Date
    ) async {
        self.retentionPolicy = retentionPolicy
        self.nowProvider = nowProvider
        await super.init(owner: owner)
        configureFixedPolicy(owner: owner)
        establishInitialMembership(ownerUUID: owner.uuid)
        try? await ensureRuntimeReady()
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storedEnvelopesByMessageID = try container.decodeIfPresent(
            CorrespondenceEnvelopeStore.self,
            forKey: .storedEnvelopesByMessageID
        ) ?? CorrespondenceEnvelopeStore()
        membershipIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .memberIdentityUUIDs
        ) ?? []
        invitationLedger = try container.decodeIfPresent(
            [CorrespondenceInvitationLedgerRecord].self,
            forKey: .invitationLedger
        ) ?? []
        version = try container.decodeIfPresent(Int.self, forKey: .membershipVersion) ?? 1
        fingerprint = try container.decodeIfPresent(String.self, forKey: .membershipFingerprint) ?? ""
        let restoredSequence = try container.decodeIfPresent(Int.self, forKey: .nextSequence) ?? 0
        retentionPolicy = try container.decodeIfPresent(
            CorrespondenceRetentionPolicy.self,
            forKey: .retentionPolicy
        ) ?? .relationshipDefault
        attachmentCellValues = try container.decodeIfPresent(
            [String: CorrespondenceAttachmentCell].self, forKey: .attachmentCells) ?? [:]
        joins = try container.decodeIfPresent(CorrespondenceJoinLedger.self, forKey: .joins) ?? CorrespondenceJoinLedger()
        attachmentRoot = nil
        attachmentProvisioningRequired = !attachmentCellValues.isEmpty
        try super.init(from: CorrespondenceIdentityStateCodec.decoderRestoringIdentityFallbacks(decoder))
        nextSequence = restoredSequence
        configureFixedPolicy(owner: owner)
        establishInitialMembership(ownerUUID: owner.uuid)
    }

    public override func encode(to encoder: Encoder) throws {
        let baseData = try JSONEncoder().encode(
            CorrespondenceIdentityStateCodec.BaseState(encodeValue: encodeInheritedState)
        )
        let baseObject = try JSONSerialization.jsonObject(with: baseData)
        let compactData = try JSONSerialization.data(
            withJSONObject: CorrespondenceIdentityStateCodec.compact(baseObject), options: [.sortedKeys]
        )
        try JSONDecoder().decode(ValueType.self, from: compactData).encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(storedEnvelopesByMessageID, forKey: .storedEnvelopesByMessageID)
        try container.encode(memberIdentityUUIDs, forKey: .memberIdentityUUIDs)
        try container.encode(invitationLedger, forKey: .invitationLedger)
        try container.encode(membershipVersion, forKey: .membershipVersion)
        try container.encode(membershipFingerprint, forKey: .membershipFingerprint)
        try container.encode(nextSequence, forKey: .nextSequence)
        try container.encode(retentionPolicy, forKey: .retentionPolicy)
        try container.encode(attachmentCells, forKey: .attachmentCells)
        try container.encode(joins, forKey: .joins)

    }

    private func encodeInheritedState(to encoder: Encoder) throws {
        try super.encode(to: encoder)
    }

    public override func installCellRuntimeBindingsForAccess() async throws {
        agreementTemplate = CorrespondenceAgreementTemplates.withAttachments(owner: owner)
        agreementAdmissionPolicy = .ownerApprovalRequired
        guard let emitter = await makeCellOwnedFlowEmitterForRuntimeBinding(requester: owner) else {
            throw CorrespondenceCellRuntimeError.flowEmitterUnavailable
        }
        cellOwnedFlowEmitter = emitter
        await registerOperations(owner: owner)
        for record in storedEnvelopesByMessageID.values {
            if let expiry = Self.date(from: record.outer.expiresAt) {
                scheduleEnvelopeExpiry(messageID: record.outer.messageID, sequence: record.outer.sequence,
                    after: expiry.timeIntervalSince(nowProvider()))
            }
        }
    }

    public override func authorizationDecision(
        requestedAccess: String,
        at keypath: String,
        for identity: Identity
    ) async -> CellAuthorizationDecision {
        var decision = await super.authorizationDecision(
            requestedAccess: requestedAccess,
            at: keypath,
            for: identity
        )
        if decision.allowed == false, decision.path == .deniedNoGrant {
            decision.reasonCode = CorrespondenceDenialReason.grantNotHeld.rawValue
            decision.userMessage = "The requester does not hold the exact correspondence grant."
            decision.requiredAction = "request_correspondence_agreement"
            decision.developerHint = "Correspondence does not consult umbrella or parent keypaths."
        }
        return decision
    }

    public override func validateCellSpecificAccess(_ requestedAccess: String, at keypath: String, for identity: Identity) async -> Bool {
        if keypath == "join.pending" || keypath.hasPrefix("join.result.") || keypath == "join.request" || keypath == "join.decide" {
            guard !CellBase.debugValidateAccessForEverything else { return false }
            if keypath == "join.pending" || keypath == "join.decide" { return await checkIdentityOrigin(identity, against: owner) }
            return await verifyRequesterIdentityControl(identity)
        }
        guard !CellBase.debugValidateAccessForEverything, requestedAccess == "-w--",
              keypath == "agreement.accept" || keypath == "agreement.revoke" else { return false }
        // Permission to submit a signed command is not membership or signing authority.
        // The command handler verifies the owner's signature and all bindings.
        return await verifyRequesterIdentityControl(identity)
    }

    public func meddleAuthorizationRequirement(
        for method: ExploreContractMethod,
        keypath: String
    ) async throws -> String? {
        if method == .set, CorrespondenceAgreementTemplates.attachmentGrantSpecifications.contains(where: { $0.keypath == keypath }) {
            return "-w--"
        }
        switch (method, keypath) {
        case (.get, "inbox"), (.get, "state"):
            return "r---"
        case (.set, "readMessage"),
             (.set, "sendMessage"),
             (.set, "ackMessage"),
             (.set, "audience.inviteIdentities"):
            return "-w--"
        default:
            return nil
        }
    }

    var membershipFingerprintSnapshot: String {
        membershipFingerprint
    }

    public override func acceptExternallySignedAgreement(_ contract: Contract, for identity: Identity) async -> AgreementState {
        guard let bytes = try? JSONEncoder().encode(contract),
              let frozen = try? JSONDecoder().decode(Contract.self, from: bytes),
              frozen.subject.publicKeyAgreementSecureKey != nil,
              frozen.issuer.publicKeyAgreementSecureKey != nil else { return .rejected }
        guard let subjectSigner = frozen.agreement.signatories.first(where: {
                  $0.uuid == frozen.subject.uuid && $0.signingPublicKeyFingerprint == frozen.subject.signingPublicKeyFingerprint
              }),
              let subjectKey = frozen.subject.publicKeyAgreementSecureKey,
              subjectKey.privateKey == false, subjectKey.use == .keyAgreement,
              subjectKey.algorithm == .X25519, subjectKey.compressedKey != nil,
              subjectKey.compressedKey == subjectSigner.publicKeyAgreementSecureKey?.compressedKey,
              (identity.publicKeyAgreementSecureKey == nil ||
               identity.publicKeyAgreementSecureKey?.compressedKey == subjectKey.compressedKey),
              let ownerKey = owner.publicKeyAgreementSecureKey?.compressedKey,
              frozen.issuer.publicKeyAgreementSecureKey?.compressedKey == ownerKey,
              frozen.agreement.owner.publicKeyAgreementSecureKey?.compressedKey == ownerKey else { return .rejected }
        let expected = CorrespondenceAgreementTemplates.withAttachments(owner: owner).grants
        let key: (Grant) -> String = { "\($0.keypath):\($0.permission.fullPermissionString)" }
        guard frozen.agreement.grants.count == expected.count,
              Set(frozen.agreement.grants.map(key)) == Set(expected.map(key)) else { return .rejected }
        let result = await super.acceptExternallySignedAgreement(frozen, for: identity)
        if result == .signed { await refreshAuthorizedMembership() }
        return result
    }

    public override func acceptExternallySignedRevocation(_ revocation: ContractRevocation) async -> Bool {
        let accepted = await super.acceptExternallySignedRevocation(revocation)
        if accepted { await refreshAuthorizedMembership() }
        return accepted
    }

    override func didChangeAuthorizationMembership() async { await refreshAuthorizedMembership() }

    private func refreshAuthorizedMembership() async {
        let ticket = membershipLock.withLock { membershipRefreshTicket += 1; return membershipRefreshTicket }
        let snapshot = await currentAuthorizationSnapshot()
        await beforeMembershipApplyForTesting?()
        applyAuthorizedMembership(snapshot, ticket: ticket)
    }

    private func applyAuthorizedMembership(_ snapshot: GeneralAuditor.AuthorizationSnapshot, ticket: Int) {
        let now = authorizationClock()
        let active = snapshot.contracts.filter {
            $0.temporalStatus(now: now) == .active && $0.expiresAt > now.timeIntervalSince1970 &&
            $0.issuedAt > (snapshot.revokedBefore[$0.subject.uuid] ?? -.infinity) &&
            ($0.targetCellUUID == nil || $0.targetCellUUID == uuid)
        }
        let ids = Array(Set(active.map { $0.subject.uuid } + [owner.uuid])).sorted()
        membershipLock.withLock {
            guard snapshot.revision >= appliedAuthorizationRevision,
                  snapshot.revision > appliedAuthorizationRevision || ticket >= appliedRefreshTicket else { return }
            appliedAuthorizationRevision = snapshot.revision
            appliedRefreshTicket = ticket
            if ids != membershipIDs {
                membershipIDs = ids
                version += 1
                fingerprint = calculateMembershipFingerprint()
            }
        }
    }

    /// These transport commands carry their own owner signature and subject proof.
    /// They grant no authority merely by reaching a registered handler.
    public override func set(keypath: String, value: ValueType, requester: Identity) async throws -> ValueType {
        if keypath == "join.request" || keypath == "join.decide" {
            return try await handleJoin(keypath: keypath, value: value, requester: requester)
        }
        if keypath == "agreement.accept" {
            let contract = try CorrespondenceCellCodec.decode(value, as: Contract.self)
            let status = await acceptExternallySignedAgreement(contract, for: requester)
            return .object(["status": .string(status == .signed ? "accepted" : "rejected")])
        }
        if keypath == "agreement.revoke" {
            let revocation = try CorrespondenceCellCodec.decode(value, as: ContractRevocation.self)
            let accepted = await acceptExternallySignedRevocation(revocation)
            return .object(["status": .string(accepted ? "revoked" : "rejected")])
        }
        return try await super.set(keypath: keypath, value: value, requester: requester) ?? .null
    }

    public override func get(keypath: String, requester: Identity) async throws -> ValueType {
        if keypath == "join.pending" {
            guard await checkIdentityOrigin(requester, against: owner) else { throw KeyValueErrors.denied }
            return try CorrespondenceCellCodec.encode(joins.pending(now: Date()))
        }
        if keypath.hasPrefix("join.result.") {
            guard await verifyRequesterIdentityControl(requester),
                  let result = joins.result(id: String(keypath.dropFirst("join.result.".count)), requester: requester, now: Date()) else { return .null }
            return try CorrespondenceCellCodec.encode(result)
        }
        return try await super.get(keypath: keypath, requester: requester)
    }

    public override func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, Error> {
        let upstream = try await super.flow(requester: requester)
        return upstream.filter { element in
            guard case .object(let fields) = element.content,
                  case .string(let event)? = fields["event"], event.hasPrefix("join.") else { return true }
            return fields["recipientIdentityUUID"] == .string(requester.uuid) &&
                fields["recipientSigningFingerprint"] == .string(requester.signingPublicKeyFingerprint ?? "")
        }.eraseToAnyPublisher()
    }

    private func registerJoinOperations(owner: Identity) async {
        for command in ["join.request", "join.decide"] {
            await registerSet(key: command, owner: owner,
                input: ExploreContract.schema(type: "object"), returns: ExploreContract.schema(type: "object"),
                permissions: ["-w--"], required: true,
                flowEffects: [Self.flowEffect()],
                description: .string("Signed join request or owner decision; does not itself admit a member."),
                handler: { [weak self] requester, value in
                    guard let self else { return .null }
                    return try? await self.handleJoin(keypath: command, value: value, requester: requester)
                })
        }
        for command in ["join.pending", "join.result"] {
            await registerGet(key: command, owner: owner, returns: ExploreContract.schema(type: "object"),
                permissions: ["r---"], required: true,
                description: .string("Owner pending list; result uses join.result.<requestID> and same-key proof."),
                handler: { [weak self] requester in
                    guard let self else { return .null }
                    return (try? await self.get(keypath: command, requester: requester)) ?? .null
                })
        }
    }

    private func handleJoin(keypath: String, value: ValueType, requester: Identity) async throws -> ValueType {
        try await ensureRuntimeReady()
        if keypath == "join.request" {
            let request = try CorrespondenceCellCodec.decode(value, as: CorrespondenceJoinRequest.self)
            let validation = await request.validate(cellUUID: uuid, owner: owner, requester: requester)
            guard validation == nil, await verifyRequesterIdentityControl(requester) else {
                return .object(["status": .string("rejected"), "code": .string(validation ?? "join.proof.invalid")])
            }
            let result = joins.insert(request, now: Date())
            if result.status == "pending" {
                emit(event: "join.requested", fields: ["requestID": .string(result.requestID), "recipientIdentityUUID": .string(owner.uuid),
                    "recipientSigningFingerprint": .string(owner.signingPublicKeyFingerprint ?? "")])
            }
            return try CorrespondenceCellCodec.encode(result)
        }
        guard await checkIdentityOrigin(requester, against: owner) else { throw KeyValueErrors.denied }
        let decision = try CorrespondenceCellCodec.decode(value, as: CorrespondenceJoinDecision.self)
        if let contract = decision.contract {
            guard let bytes = try? JSONEncoder().encode(contract),
                  let raw = try? JSONSerialization.jsonObject(with: bytes),
                  (try? CorrespondenceIdentityStateCodec.compact(raw)) != nil else { return .object(["status": .string("rejected")]) }
        }
        guard let pending = joins.record(id: decision.requestID),
              pending.status == "pending" || pending.status == "approved" else { return .null }
        let renewing = pending.status == "approved"
        guard !renewing || decision.approve else { return .object(["status": .string("rejected")]) }
        if decision.approve {
            let template = CorrespondenceAgreementTemplates.withAttachments(owner: owner)
            let expectedGrants = template.grants
            let grantKey: (Grant) -> String = { "\($0.keypath):\($0.permission.fullPermissionString)" }
            guard let contract = decision.contract,
                  UUID(uuidString: contract.uuid) != nil, UUID(uuidString: contract.agreement.uuid) != nil,
                  contract.agreement.name == template.name,
                  contract.agreement.conditions.isEmpty, contract.agreement.authorizationPolicyBinding == nil,
                  contract.agreement.signatories.count == 2,
                  Set(contract.agreement.signatories.map { $0.uuid }) == Set([owner.uuid, pending.request.identityUUID]),
                  contract.agreement.grants.allSatisfy({ grant in
                      UUID(uuidString: grant.uuid) != nil && expectedGrants.contains(where: { $0.keypath == grant.keypath && $0.name == grant.name })
                  }),
                  contract.issuedAt <= authorizationClock().timeIntervalSince1970 + 5,
                  contract.agreement.grants.count == expectedGrants.count,
                  Set(contract.agreement.grants.map(grantKey)) == Set(expectedGrants.map(grantKey)),
                  contract.agreement.signatories.contains(where: { $0.uuid == pending.request.identityUUID && $0.publicKeyAgreementSecureKey?.compressedKey == pending.request.agreementPublicKey }),
                  contract.targetCellUUID == uuid,
                  contract.signaturePurpose == "haven.contract.admission.v2",
                  contract.issuedAt >= pending.receivedAt - 5,
                  contract.subject.publicKeyAgreementSecureKey?.compressedKey == pending.request.agreementPublicKey,
                  contract.issuer.publicKeyAgreementSecureKey?.compressedKey == owner.publicKeyAgreementSecureKey?.compressedKey,
                  [contract.issuer, contract.subject, contract.agreement.owner] .allSatisfy({ $0.displayName == $0.uuid }),
                  contract.agreement.signatories.allSatisfy({ $0.displayName == $0.uuid }),
                  await contract.verifyAuthorizationBinding(expectedIssuer: owner, expectedSubject: pending.request.identity,
                    expectedDomain: identityDomain, now: authorizationClock()) else { return .object(["status": .string("rejected")]) }
            if renewing {
                guard let previous = pending.contract,
                      contract.agreement.uuid == previous.agreement.uuid,
                      contract.agreement.owner.publicKeyAgreementSecureKey?.compressedKey == previous.agreement.owner.publicKeyAgreementSecureKey?.compressedKey,
                      contract.agreement.signatories.allSatisfy({ signer in
                          previous.agreement.signatories.contains(where: {
                              $0.uuid == signer.uuid && $0.signingPublicKeyFingerprint == signer.signingPublicKeyFingerprint &&
                              $0.publicKeyAgreementSecureKey?.compressedKey == signer.publicKeyAgreementSecureKey?.compressedKey
                          })
                      }) else { return .object(["status": .string("rejected")]) }
            }
        } else if decision.contract != nil { return .object(["status": .string("rejected")]) }
        // Serialize the revocation check and result replacement with authorization
        // mutations. Expiry permits renewal; a recorded revocation does not.
        await beforeJoinDecisionCommitForTesting?()
        let result = await withCurrentAuthorizationSnapshot { snapshot in
            // A pending decision validated before another approval must not turn
            // into a renewal after that approval (or its subsequent revocation).
            guard joins.record(id: decision.requestID)?.status == pending.status else { return nil as CorrespondenceJoinResult? }
            guard !renewing || snapshot.revokedBefore[pending.request.identityUUID] == nil else { return nil as CorrespondenceJoinResult? }
            return joins.decide(decision, now: authorizationClock())
        }
        guard let result else { return .object(["status": .string("rejected")]) }
        emit(event: "join.decided", fields: ["requestID": .string(result.requestID), "status": .string(result.status),
            "recipientIdentityUUID": .string(pending.request.identityUUID),
            "recipientSigningFingerprint": .string(pending.request.identity.signingPublicKeyFingerprint ?? "")])
        return try CorrespondenceCellCodec.encode(result)
    }

    public override func state(requester: Identity) async throws -> ValueType {
        try await ensureRuntimeReady()
        guard await validateAccess("r---", at: "state", for: requester) else {
            throw KeyValueErrors.denied
        }
        await refreshAuthorizedMembership()
        return inbox(requester: requester)
    }

    private func configureFixedPolicy(owner: Identity) {
        identityDomain = Self.identityDomainName
        persistancy = .persistant
        agreementTemplate = CorrespondenceAgreementTemplates.withAttachments(owner: owner)
        agreementAdmissionPolicy = .ownerApprovalRequired
    }

    private func establishInitialMembership(ownerUUID: String) {
        if memberIdentityUUIDs.contains(ownerUUID) == false {
            memberIdentityUUIDs.append(ownerUUID)
            memberIdentityUUIDs.sort()
        }
        membershipFingerprint = calculateMembershipFingerprint()
    }

    private func registerOperations(owner: Identity) async {
        await registerGet(key: "state", owner: owner, returns: Self.inboxSchema,
            permissions: ["r---"], required: true,
            description: .string("Member-only envelope history."),
            handler: { [weak self] requester in
                guard let self else { return .null }
                return (try? await self.state(requester: requester)) ?? .null
            })
        for command in ["agreement.accept", "agreement.revoke"] {
            await registerSet(key: command, owner: owner,
                input: ExploreContract.schema(type: "object"), returns: ExploreContract.schema(type: "object"),
                permissions: ["-w--"], required: true,
                description: .string("Owner-signed command; admission additionally proves the subject key."),
                handler: { [weak self] requester, value in
                    guard let self else { return .null }
                    return try? await self.set(keypath: command, value: value, requester: requester)
                })
        }
        await registerJoinOperations(owner: owner)
        await registerAttachmentOperations(owner: owner)
        await registerGet(
            key: "inbox",
            owner: owner,
            returns: Self.inboxSchema,
            permissions: ["r---"],
            required: true,
            description: .string("Returns envelope metadata only; subject and content never appear."),
            handler: { [weak self] requester in
                guard let self else { return .null }
                await self.refreshAuthorizedMembership()
                return self.inbox(requester: requester)
            }
        )

        await registerSet(
            key: "readMessage",
            owner: owner,
            input: Self.messageIdentifierSchema,
            returns: Self.readMessageResultSchema,
            permissions: ["-w--"],
            required: true,
            flowEffects: [Self.flowEffect()],
            description: .string("Returns one encrypted envelope and records the deliberate read."),
            handler: { [weak self] requester, payload in
                guard let self else { return .null }
                return self.readMessage(payload: payload, requester: requester)
            }
        )

        await registerSet(
            key: "sendMessage",
            owner: owner,
            input: Self.sendMessageInputSchema,
            returns: Self.actionResultSchema,
            permissions: ["-w--"],
            required: true,
            flowEffects: [Self.flowEffect()],
            description: .string("Stores a prepared ciphertext envelope for the current membership."),
            handler: { [weak self] requester, payload in
                guard let self else { return .null }
                return await self.sendMessage(payload: payload, requester: requester)
            }
        )

        await registerSet(
            key: "ackMessage",
            owner: owner,
            input: Self.messageIdentifierSchema,
            returns: Self.actionResultSchema,
            permissions: ["-w--"],
            required: true,
            flowEffects: [Self.flowEffect()],
            description: .string("Records the pilot's server-visible receipt bit."),
            handler: { [weak self] requester, payload in
                guard let self else { return .null }
                return self.ackMessage(payload: payload, requester: requester)
            }
        )

        await registerSet(
            key: "audience.inviteIdentities",
            owner: owner,
            input: Self.inviteInputSchema,
            returns: Self.inviteResultSchema,
            permissions: ["-w--"],
            required: true,
            flowEffects: [Self.flowEffect()],
            description: .string("Owner-only membership action; stores correspondence identity UUIDs only."),
            handler: { [weak self] requester, payload in
                guard let self else { return .null }
                return await self.inviteIdentities(payload: payload, requester: requester)
            }
        )
    }

    private func inbox(requester: Identity) -> ValueType {
        purgeExpiredMessages(at: nowProvider())
        guard memberIdentityUUIDs.contains(requester.uuid) else {
            return denial(.grantNotHeld)
        }
        let messages = storedEnvelopesByMessageID.values
            .map(\.outer)
            .sorted { lhs, rhs in lhs.sequence < rhs.sequence }
            .compactMap { try? CorrespondenceCellCodec.encode($0) }
        return .object([
            "schema": .string("haven.correspondence.inbox.v0"),
            "cellID": .string(uuid),
            "membershipFingerprint": .string(membershipFingerprint),
            "messages": .list(messages)
        ])
    }

    private func readMessage(payload: ValueType, requester: Identity) -> ValueType {
        guard memberIdentityUUIDs.contains(requester.uuid) else {
            return denial(.grantNotHeld)
        }
        guard let messageID = messageIdentifier(from: payload),
              let stored = storedEnvelopesByMessageID[messageID] else {
            purgeExpiredMessages(at: nowProvider())
            return denial(.messageExpired)
        }
        if isExpired(stored.outer, at: nowProvider()) {
            removeExpiredMessage(messageID, record: stored)
            return denial(.messageExpired)
        }
        emit(event: "message.read", fields: ["messageID": .string(messageID)])
        return (try? CorrespondenceCellCodec.encode(stored)) ?? .null
    }

    private func sendMessage(payload: ValueType, requester: Identity) async -> ValueType {
        await refreshAuthorizedMembership()
        purgeExpiredMessages(at: nowProvider())
        guard memberIdentityUUIDs.contains(requester.uuid) else {
            return denial(.grantNotHeld)
        }
        guard containsPlaintextField(payload) == false,
              let request = try? CorrespondenceCellCodec.decode(payload, as: CorrespondenceSendRequest.self) else {
            return denial(.plaintextRejected)
        }
        guard request.senderIdentityUUID == requester.uuid else {
            return denial(.grantNotHeld)
        }
        guard request.membershipFingerprint == membershipFingerprint else {
            return denial(.membershipFingerprintMismatch)
        }
        let expectedContext = CorrespondenceEnvelopeUtility.associatedDataContext(
            cellID: uuid,
            membershipFingerprint: membershipFingerprint,
            messageID: request.attachmentRequest == nil ? nil : request.messageID,
            agreementID: request.attachmentRequest?.agreementID
        )
        guard request.envelope.header.associatedDataContext == expectedContext,
              request.envelope.header.suiteID == CorrespondenceEnvelopeUtility.suite.id,
              envelopeRecipientsMatchCurrentMembership(request.envelope) else {
            return denial(.membershipFingerprintMismatch)
        }
        guard await CorrespondenceEnvelopeUtility.verifyTransportSignature(
            envelope: request.envelope,
            sender: requester
        ) else {
            return denial(.grantNotHeld)
        }
        guard let defaultRetention = retentionPolicy.defaultSecondsByPurpose[request.purposeRef] else {
            return denial(.purposeNotAllowed)
        }
        let retentionSeconds = request.retentionSeconds ?? defaultRetention
        guard retentionSeconds > 0, retentionSeconds <= retentionPolicy.maximumSeconds else {
            return denial(.retentionOutOfPolicy)
        }

        let now = nowProvider()
        let messageID = request.messageID ?? UUID().uuidString
        guard UUID(uuidString: messageID) != nil, storedEnvelopesByMessageID[messageID] == nil,
              !membershipLock.withLock({ attachmentReservations.contains(messageID) }) else { return denial(.grantNotHeld) }
        if let attachment = request.attachmentRequest {
            guard attachment.messageID == messageID, attachment.senderIdentityUUID == requester.uuid,
                  let sourceCell = attachmentCells[requester.uuid] else { return denial(.grantNotHeld) }
            let reserved = membershipLock.withLock { attachmentReservations.insert(messageID).inserted }
            guard reserved else { return denial(.grantNotHeld) }
            defer { _ = membershipLock.withLock { attachmentReservations.remove(messageID) } }
            do {
                try await authorizeAttachment(attachment, action: "attachments.prepare", requester: requester)
                try await sourceCell.storage.publish(attachment,
                    expiresAt: now.addingTimeInterval(TimeInterval(retentionSeconds)), now: now)
            } catch { return denial(.attachmentUnavailable) }
        }
        await beforeSendCommitForTesting?()
        await refreshAuthorizedMembership()
        guard memberIdentityUUIDs.contains(requester.uuid),
              request.membershipFingerprint == membershipFingerprint,
              envelopeRecipientsMatchCurrentMembership(request.envelope) else {
            return denial(.membershipFingerprintMismatch)
        }
        var outer = CorrespondenceOuterEnvelope(
            messageID: messageID,
            sequence: storedEnvelopesByMessageID.reserveSequence(),
            cellID: uuid,
            senderIdentityUUID: requester.uuid,
            purposeRef: Self.envelopePurposeRef,
            createdAt: Self.timestamp(now),
            expiresAt: Self.timestamp(now.addingTimeInterval(TimeInterval(retentionSeconds))),
            membershipFingerprint: membershipFingerprint,
            ciphertextSize: request.envelope.combinedCiphertext.count
        )
        outer.attachmentAgreementID = request.attachmentRequest?.agreementID
        let inserted = await withCurrentAuthorizationSnapshot { snapshot in
            membershipLock.withLock {
                membershipRefreshTicket += 1
                applyAuthorizedMembership(snapshot, ticket: membershipRefreshTicket)
                guard memberIdentityUUIDs.contains(requester.uuid), request.membershipFingerprint == fingerprint,
                      Set(request.envelope.header.recipientKeys.compactMap(\.recipientIdentityUUID)) == Set(membershipIDs) else { return false }
                return storedEnvelopesByMessageID.insert(CorrespondenceStoredEnvelope(outer: outer, innerCiphertext: request.envelope))
            }
        }
        guard inserted else { return denial(.membershipFingerprintMismatch) }
        scheduleEnvelopeExpiry(messageID: messageID, sequence: outer.sequence, after: TimeInterval(retentionSeconds))
        emit(event: "message.stored", fields: [
            "envelope": (try? CorrespondenceCellCodec.encode(CorrespondenceStoredEnvelope(outer: outer, innerCiphertext: request.envelope))) ?? .null,
            "messageID": .string(messageID),
            "sequence": .integer(outer.sequence),
            "senderIdentityUUID": .string(requester.uuid),
            "purposeRef": .string(Self.envelopePurposeRef),
            "expiresAt": .string(outer.expiresAt),
            "ciphertextSize": .integer(outer.ciphertextSize)
        ])
        return .object([
            "status": .string("stored"),
            "messageID": .string(messageID),
            "sequence": .integer(outer.sequence),
            "expiresAt": .string(outer.expiresAt)
        ])
    }

    private func ackMessage(payload: ValueType, requester: Identity) -> ValueType {
        guard memberIdentityUUIDs.contains(requester.uuid) else {
            return denial(.grantNotHeld)
        }
        guard let messageID = messageIdentifier(from: payload),
              var stored = storedEnvelopesByMessageID[messageID] else {
            purgeExpiredMessages(at: nowProvider())
            return denial(.messageExpired)
        }
        if isExpired(stored.outer, at: nowProvider()) {
            removeExpiredMessage(messageID, record: stored)
            return denial(.messageExpired)
        }
        stored.outer.receiptState = "acknowledged"
        guard storedEnvelopesByMessageID.update(stored) else { return denial(.messageExpired) }
        emit(event: "message.receipt", fields: [
            "messageID": .string(messageID),
            "receiptState": .string("acknowledged")
        ])
        return .object([
            "status": .string("acknowledged"),
            "messageID": .string(messageID)
        ])
    }

    private func inviteIdentities(payload: ValueType, requester: Identity) async -> ValueType {
        let ownerProven = await checkIdentityOrigin(requester, against: owner)
        if !ownerProven {
            // Resolver-verified, separately owner-signed authority is not membership.
            // Keep the exact owner template; a single invite grant is insufficient.
            let expected = CorrespondenceAgreementTemplates.owner(owner: owner)
            let agreements = await contractsForIdentity(requester)
            guard agreements.contains(where: {
                $0.name == expected.name && $0.conditions.isEmpty &&
                $0.authorizationPolicyBinding == expected.authorizationPolicyBinding &&
                $0.grants.count == expected.grants.count &&
                Set($0.grants.map { "\($0.keypath):\($0.permission.fullPermissionString)" }) ==
                    Set(expected.grants.map { "\($0.keypath):\($0.permission.fullPermissionString)" })
            }) else { return denial(.grantNotHeld) }
            // A delegate can repeat the existing owner operation, but cannot
            // sign an admission as the cell owner. Reject the entire batch first.
            guard identityUUIDs(from: payload).allSatisfy(memberIdentityUUIDs.contains) else {
                return denial(.grantNotHeld)
            }
        }
        var changed = false
        for id in identityUUIDs(from: payload) where !memberIdentityUUIDs.contains(id) {
            guard let vault = CellBase.defaultIdentityVault,
                  let identity = await vault.identity(forUUID: id) else { return denial(.grantNotHeld) }
            let agreement = CorrespondenceAgreementTemplates.withAttachments(owner: owner)
            agreement.state = .signed
            agreement.signatories = [owner.publicIdentitySnapshot(), identity.publicIdentitySnapshot()]
            guard let contract = try? await Contract.signed(agreement: agreement, issuer: requester,
                subject: identity.publicIdentitySnapshot(), domain: identityDomain, targetCellUUID: uuid),
                await acceptExternallySignedAgreement(contract, for: identity) == .signed else { return denial(.grantNotHeld) }
            changed = true
        }
        if changed { emit(event: "membership.changed", fields: ["membershipFingerprint": .string(membershipFingerprint)]) }
        return .object(["status": .string(changed ? "invited" : "unchanged"),
            "membershipVersion": .integer(membershipVersion), "membershipFingerprint": .string(membershipFingerprint),
            "memberIdentityUUIDs": .list(memberIdentityUUIDs.map(ValueType.string))])
    }

    private func scheduleEnvelopeExpiry(messageID: String, sequence: Int, after seconds: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard let self, let record = self.storedEnvelopesByMessageID[messageID], record.outer.sequence == sequence else { return }
            self.removeExpiredMessage(messageID, record: record)
        }
    }

    private func purgeExpiredMessages(at date: Date) {
        let expired = storedEnvelopesByMessageID.values
            .filter { isExpired($0.outer, at: date) }
            .sorted { lhs, rhs in lhs.outer.sequence < rhs.outer.sequence }
        for record in expired {
            removeExpiredMessage(record.outer.messageID, record: record)
        }
    }

    private func removeExpiredMessage(_ messageID: String, record: CorrespondenceStoredEnvelope) {
        guard storedEnvelopesByMessageID.remove(messageID, matchingSequence: record.outer.sequence) else { return }
        emit(event: "message.expired", fields: [
            "messageID": .string(messageID),
            "sequence": .integer(record.outer.sequence)
        ])
    }

    private func isExpired(_ outer: CorrespondenceOuterEnvelope, at date: Date) -> Bool {
        guard let expiresAt = Self.date(from: outer.expiresAt) else {
            return true
        }
        return expiresAt <= date
    }

    private func envelopeRecipientsMatchCurrentMembership(_ envelope: EncryptedContentEnvelope) -> Bool {
        let recipientUUIDs = envelope.header.recipientKeys.compactMap(\.recipientIdentityUUID)
        return recipientUUIDs.count == Set(recipientUUIDs).count
            && Set(recipientUUIDs) == Set(memberIdentityUUIDs)
    }

    private func calculateMembershipFingerprint() -> String {
        let material = "correspondence-membership-v1|\(uuid)|\(membershipVersion)|\(memberIdentityUUIDs.sorted().joined(separator: "|"))"
        return FlowHasher.sha256Hex(Data(material.utf8))
    }

    private func emit(event: String, fields: Object) {
        var content = fields
        content["event"] = .string(event)
        var element = FlowElement(
            title: event,
            content: .object(content),
            properties: FlowElement.Properties(type: .event, contentType: .object)
        )
        element.topic = Self.flowTopic
        cellOwnedFlowEmitter?(element)
    }

    private func denial(_ reason: CorrespondenceDenialReason) -> ValueType {
        .object([
            "status": .string("denied"),
            "denialReason": .string(reason.rawValue)
        ])
    }

    private func messageIdentifier(from value: ValueType) -> String? {
        guard case let .object(object) = value,
              case let .string(messageID)? = object["messageID"],
              messageID.isEmpty == false else {
            return nil
        }
        return messageID
    }

    private func identityUUIDs(from value: ValueType) -> [String] {
        func uuid(from candidate: ValueType) -> String? {
            switch candidate {
            case .string(let uuid):
                return uuid.isEmpty ? nil : uuid
            case .identity(let identity):
                return identity.uuid
            case .object(let object):
                if case let .string(uuid)? = object["identityUUID"] {
                    return uuid.isEmpty ? nil : uuid
                }
                if case let .string(uuid)? = object["uuid"] {
                    return uuid.isEmpty ? nil : uuid
                }
                return nil
            default:
                return nil
            }
        }

        switch value {
        case .identity, .string:
            return uuid(from: value).map { [$0] } ?? []
        case .list(let values):
            return Array(Set(values.compactMap(uuid(from:)))).sorted()
        case .object(let object):
            if let identity = object["identity"], let identityUUID = uuid(from: identity) {
                return [identityUUID]
            }
            if let identityUUID = uuid(from: .object(object)) {
                return [identityUUID]
            }
            if case let .list(values)? = object["identityUUIDs"] {
                return Array(Set(values.compactMap(uuid(from:)))).sorted()
            }
            if case let .list(values)? = object["identities"] {
                return Array(Set(values.compactMap(uuid(from:)))).sorted()
            }
            return []
        default:
            return []
        }
    }

    private func containsPlaintextField(_ value: ValueType) -> Bool {
        switch value {
        case .object(let object):
            let forbidden = Set(["subject", "content", "body", "text", "plaintext"])
            for (key, nestedValue) in object {
                if forbidden.contains(key.lowercased()) || containsPlaintextField(nestedValue) {
                    return true
                }
            }
            return false
        case .list(let values):
            return values.contains(where: containsPlaintextField)
        default:
            return false
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func date(from timestamp: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: timestamp) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: timestamp)
    }

    private static var scalarStringSchema: ValueType {
        ExploreContract.schema(type: "string")
    }

    private static var outerEnvelopeSchema: ValueType {
        ExploreContract.objectSchema(
            properties: [
                "messageID": scalarStringSchema,
                "sequence": ExploreContract.schema(type: "integer"),
                "cellID": scalarStringSchema,
                "senderIdentityUUID": scalarStringSchema,
                "purposeRef": scalarStringSchema,
                "createdAt": scalarStringSchema,
                "expiresAt": scalarStringSchema,
                "membershipFingerprint": scalarStringSchema,
                "ciphertextSize": ExploreContract.schema(type: "integer"),
                "receiptState": scalarStringSchema
            ],
            requiredKeys: [
                "messageID", "sequence", "cellID", "senderIdentityUUID", "purposeRef",
                "createdAt", "expiresAt", "membershipFingerprint", "ciphertextSize", "receiptState"
            ]
        )
    }

    private static var inboxSchema: ValueType {
        ExploreContract.objectSchema(
            properties: [
                "schema": scalarStringSchema,
                "cellID": scalarStringSchema,
                "membershipFingerprint": scalarStringSchema,
                "messages": ExploreContract.listSchema(item: outerEnvelopeSchema)
            ],
            requiredKeys: ["schema", "cellID", "membershipFingerprint", "messages"]
        )
    }

    private static var messageIdentifierSchema: ValueType {
        ExploreContract.objectSchema(
            properties: ["messageID": scalarStringSchema],
            requiredKeys: ["messageID"]
        )
    }

    private static var encryptedEnvelopeSchema: ValueType {
        ExploreContract.objectSchema(
            properties: [
                "header": ExploreContract.schema(type: "object"),
                "combinedCiphertext": ExploreContract.schema(type: "data"),
                "senderSignature": ExploreContract.schema(type: "data")
            ],
            requiredKeys: ["header", "combinedCiphertext", "senderSignature"]
        )
    }

    private static var sendMessageInputSchema: ValueType {
        ExploreContract.objectSchema(
            properties: [
                "envelope": encryptedEnvelopeSchema,
                "senderIdentityUUID": scalarStringSchema,
                "membershipFingerprint": scalarStringSchema,
                "purposeRef": scalarStringSchema,
                "retentionSeconds": ExploreContract.schema(type: "integer"),
                "messageID": scalarStringSchema,
                "attachmentRequest": ExploreContract.schema(type: "object")
            ],
            requiredKeys: ["envelope", "senderIdentityUUID", "membershipFingerprint", "purposeRef"]
        )
    }

    private static var storedEnvelopeSchema: ValueType {
        ExploreContract.objectSchema(
            properties: [
                "outer": outerEnvelopeSchema,
                "innerCiphertext": encryptedEnvelopeSchema
            ],
            requiredKeys: ["outer", "innerCiphertext"]
        )
    }

    private static var denialSchema: ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": scalarStringSchema,
                "denialReason": scalarStringSchema
            ],
            requiredKeys: ["status", "denialReason"]
        )
    }

    private static var readMessageResultSchema: ValueType {
        ExploreContract.oneOfSchema(options: [storedEnvelopeSchema, denialSchema])
    }

    private static var actionResultSchema: ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": scalarStringSchema,
                "messageID": scalarStringSchema,
                "sequence": ExploreContract.schema(type: "integer"),
                "expiresAt": scalarStringSchema,
                "denialReason": scalarStringSchema
            ],
            requiredKeys: ["status"]
        )
    }

    private static var inviteInputSchema: ValueType {
        ExploreContract.objectSchema(
            properties: [
                "identityUUID": scalarStringSchema,
                "identityUUIDs": ExploreContract.listSchema(item: scalarStringSchema)
            ]
        )
    }

    private static var inviteResultSchema: ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": scalarStringSchema,
                "membershipVersion": ExploreContract.schema(type: "integer"),
                "membershipFingerprint": scalarStringSchema,
                "memberIdentityUUIDs": ExploreContract.listSchema(item: scalarStringSchema)
            ],
            requiredKeys: ["status"]
        )
    }

    private static func flowEffect() -> ValueType {
        ExploreContract.flowEffect(
            trigger: .set,
            topic: flowTopic,
            contentType: "object",
            minimumCount: 1
        )
    }
}


extension CorrespondenceCell {
    /// Host provisioning: the proven sender chooses its Cell's storage root.
    /// This local integration API never accepts a path from an MCP peer.
    public func configureAttachmentStorage(root: URL, requester: Identity) async throws {
        let decision = await authorizationDecision(requestedAccess: "-w--", at: "attachments.prepare", for: requester)
        guard decision.allowed, attachmentCells.isEmpty || attachmentProvisioningRequired else { throw CorrespondenceAttachmentError.wrongSender }
        for (id, cell) in attachmentCells {
            let key = FlowHasher.sha256Hex(Data((id + (cell.owner.signingPublicKeyFingerprint ?? "")).utf8))
            await cell.provisionStorage(root: root.appendingPathComponent(key))
        }
        attachmentRoot = root
        attachmentProvisioningRequired = false
    }

    /// Trusted process-local host binding. Never exposed as an operation or a grant.
    public func configureTrustedHostAttachmentStorage(root: URL) async {
        for (id, cell) in attachmentCells {
            let key = FlowHasher.sha256Hex(Data((id + (cell.owner.signingPublicKeyFingerprint ?? "")).utf8))
            await cell.provisionStorage(root: root.appendingPathComponent(key))
        }
        attachmentRoot = root
        attachmentProvisioningRequired = false
    }

    public func registerAttachmentSource(id: String, file: URL,
        metadata: CorrespondenceAttachmentMetadata, retainsStorage: Bool = true, sharedReference: URL? = nil,
        requester: Identity) async throws {
        let decision = await authorizationDecision(requestedAccess: "-w--", at: "attachments.prepare", for: requester)
        guard decision.allowed, memberIdentityUUIDs.contains(requester.uuid) else {
            throw CorrespondenceAttachmentError.wrongSender
        }
        let cell = await senderAttachmentCell(requester)
        try await cell.storage.registerSource(id: id, file: file, metadata: metadata,
            retainsStorage: retainsStorage, referenceURL: sharedReference)
    }

    private func senderAttachmentCell(_ sender: Identity) async -> CorrespondenceAttachmentCell {
        if let cell = attachmentCells[sender.uuid] { return cell }
        let base = attachmentRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HAVEN/CorrespondenceAttachments/" + uuid)
        let key = FlowHasher.sha256Hex(Data((sender.uuid + (sender.signingPublicKeyFingerprint ?? "")).utf8))
        let cell = await CorrespondenceAttachmentCell(owner: sender.publicIdentitySnapshot(),
            root: base.appendingPathComponent(key))
        return membershipLock.withLock {
            if let existing = attachmentCellValues[sender.uuid] { return existing }
            attachmentCellValues[sender.uuid] = cell
            return cell
        }
    }

    private func authorizeAttachment(_ request: CorrespondenceAttachmentRequest,
                                     action: String, requester: Identity) async throws {
        await refreshAuthorizedMembership()
        guard memberIdentityUUIDs.contains(requester.uuid) else {
            throw CorrespondenceAttachmentError.wrongRecipient
        }
        let decision = await authorizationDecision(requestedAccess: "-w--", at: action, for: requester)
        guard decision.allowed else { throw CorrespondenceAttachmentError.wrongRecipient }
        let senderActions: Set<String> = ["attachments.prepare", "attachments.upload", "attachments.revoke", "attachments.transfer"]
        if senderActions.contains(action), requester.uuid != owner.uuid {
            let agreements = await contractsForIdentity(requester)
            guard agreements.contains(where: { $0.uuid == request.agreementID && $0.checkGrant(requestedGrant: Grant(keypath: action, permission: "-w--")) }) else {
                throw CorrespondenceAttachmentError.contextMismatch
            }
        }
        if senderActions.contains(action), requester.uuid == owner.uuid, request.agreementID != uuid {
            throw CorrespondenceAttachmentError.contextMismatch
        }
        // Recipient authority was checked by the Resolver above. The storage
        // entry additionally checks the original sender's Agreement ID, signed
        // into the envelope AAD and inner attachment manifest.

    }

    private func registerAttachmentOperations(owner: Identity) async {
        for (key, _) in CorrespondenceAgreementTemplates.attachmentGrantSpecifications {
            await registerSet(key: key, owner: owner,
                input: ExploreContract.schema(type: "object"),
                returns: ExploreContract.schema(type: "object"), permissions: ["-w--"], required: true,
                flowEffects: [Self.flowEffect()],
                description: .string("Agreement-bound attachment action; no execution, installation or implicit ownership transfer."),
                handler: { [weak self] requester, value in
                    guard let self else { return .null }
                    do {
                        let request = try CorrespondenceCellCodec.decode(value, as: CorrespondenceAttachmentRequest.self)
                        return try await self.performAttachment(key, request: request, requester: requester)
                    } catch {
                        return .object(["status": .string("error"), "message": .string("attachmentUnavailable")])
                    }
                })
        }
    }

    private func performAttachment(_ action: String, request: CorrespondenceAttachmentRequest,
                                   requester: Identity) async throws -> ValueType {
        guard !attachmentProvisioningRequired else { throw CorrespondenceAttachmentError.unavailable }
        try await authorizeAttachment(request, action: action, requester: requester)
        let senderActions: Set<String> = ["attachments.prepare", "attachments.upload", "attachments.revoke", "attachments.transfer"]
        if senderActions.contains(action), requester.uuid != request.senderIdentityUUID {
            throw CorrespondenceAttachmentError.wrongSender
        }
        let recipientActions: Set<String> = ["attachments.fetch", "attachments.receipt", "attachments.acceptTransfer", "attachments.probe"]
        if recipientActions.contains(action), requester.uuid == request.senderIdentityUUID {
            throw CorrespondenceAttachmentError.wrongRecipient
        }
        let source: CorrespondenceAttachmentCell
        if action == "attachments.prepare" { source = await senderAttachmentCell(requester) }
        else if let existing = attachmentCells[request.senderIdentityUUID] { source = existing }
        else { throw CorrespondenceAttachmentError.unavailable }
        let now = nowProvider()
        let key = requester.signingPublicKeyFingerprint ?? ""
        guard !key.isEmpty else { throw CorrespondenceAttachmentError.wrongRecipient }
        var result: ValueType = .object(["status": .string("ok")])
        switch action {
        case "attachments.probe":
            // Source IDs are local sender capabilities, never peer discovery.
            throw CorrespondenceAttachmentError.unavailable
        case "attachments.prepare":
            guard request.sourceID == nil, UUID(uuidString: request.messageID) != nil else { throw CorrespondenceAttachmentError.contextMismatch }
            // Every admitted member is a recipient, including the owner.
            await refreshAuthorizedMembership()
            let capturedFingerprint = membershipFingerprint
            let snapshot = await currentAuthorizationSnapshot()
            let members = snapshot.contracts.filter { $0.temporalStatus(now: authorizationClock()) == .active &&
                $0.issuedAt > (snapshot.revokedBefore[$0.subject.uuid] ?? -.infinity) }.map(\.subject) + [owner]
            let keys = Set(members.filter { $0.uuid != requester.uuid }
                .compactMap(\.signingPublicKeyFingerprint))
            guard !keys.isEmpty else { throw CorrespondenceAttachmentError.wrongRecipient }
            var plan = try await source.storage.prepare(request, recipientKeys: keys,
                reference: "cell:///\(uuid)/attachments.fetch", now: now)
            plan.metadata.name = ""
            plan.reference = nil
            result = try CorrespondenceCellCodec.encode(plan)
            await beforeAttachmentCommitForTesting?()
            await refreshAuthorizedMembership()
            guard capturedFingerprint == membershipFingerprint, memberIdentityUUIDs.contains(requester.uuid) else {
                throw CorrespondenceAttachmentError.contextMismatch
            }
        case "attachments.upload": try await source.storage.upload(request, now: now)
        case "attachments.metadata": result = try CorrespondenceCellCodec.encode(await source.storage.metadata(request, now: now))
        case "attachments.fetch": result = try CorrespondenceCellCodec.encode(await source.storage.fetch(request, recipientKey: key, now: now))
        case "attachments.receipt": try await source.storage.receipt(request, recipientKey: key, now: now)
        case "attachments.revoke": try await source.storage.revoke(request, now: now)
        case "attachments.transfer": try await source.storage.transfer(request, now: now)
        case "attachments.acceptTransfer": try await source.storage.acceptTransfer(request, recipientKey: key, now: now)
        case "attachments.status":
            let status = try await source.storage.status(request, now: now)
            result = .object(["transferOffered": .bool(status.0), "transferred": .bool(status.1)])
        default: throw CorrespondenceAttachmentError.unavailable
        }
        emit(event: action, fields: ["messageID": .string(request.messageID),
            "senderIdentityUUID": .string(request.senderIdentityUUID)])
        return result
    }
}
