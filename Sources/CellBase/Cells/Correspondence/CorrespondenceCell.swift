// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum CorrespondenceDenialReason: String, Codable, Sendable {
    case plaintextRejected
    case membershipFingerprintMismatch
    case purposeNotAllowed
    case retentionOutOfPolicy
    case grantNotHeld
    case delegationRevoked
    case cellClosed
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

/// A relationship-scoped, envelope-only message Cell for correspondence-domain
/// identities. Plaintext is accepted only by the client-side envelope utility.
public final class CorrespondenceCell: GeneralCell, MeddleOperationAuthorizationRequirementProviding {
    public static let flowTopic = "haven.correspondence"
    public static let envelopePurposeRef = "purpose://correspondence.envelope"
    public static let identityDomainName = "correspondence"

    private var storedEnvelopesByMessageID = [String: CorrespondenceStoredEnvelope]()
    private var memberIdentityUUIDs = [String]()
    private var invitationLedger = [CorrespondenceInvitationLedgerRecord]()
    private var membershipVersion = 1
    private var membershipFingerprint = ""
    private var attachmentCells: [String: CorrespondenceAttachmentCell] = [:]
    private var attachmentRoot: URL?
    private var attachmentReservations: Set<String> = []
    private var nextSequence = 0
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
            [String: CorrespondenceStoredEnvelope].self,
            forKey: .storedEnvelopesByMessageID
        ) ?? [:]
        memberIdentityUUIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .memberIdentityUUIDs
        ) ?? []
        invitationLedger = try container.decodeIfPresent(
            [CorrespondenceInvitationLedgerRecord].self,
            forKey: .invitationLedger
        ) ?? []
        membershipVersion = try container.decodeIfPresent(Int.self, forKey: .membershipVersion) ?? 1
        membershipFingerprint = try container.decodeIfPresent(String.self, forKey: .membershipFingerprint) ?? ""
        nextSequence = try container.decodeIfPresent(Int.self, forKey: .nextSequence) ?? 0
        retentionPolicy = try container.decodeIfPresent(
            CorrespondenceRetentionPolicy.self,
            forKey: .retentionPolicy
        ) ?? .relationshipDefault
        attachmentCells = try container.decodeIfPresent(
            [String: CorrespondenceAttachmentCell].self, forKey: .attachmentCells) ?? [:]
        attachmentRoot = try container.decodeIfPresent(URL.self, forKey: .attachmentRoot)
        try super.init(from: CorrespondenceIdentityStateCodec.decoderRestoringIdentityFallbacks(decoder))
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
        try container.encodeIfPresent(attachmentRoot, forKey: .attachmentRoot)
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

    public func meddleAuthorizationRequirement(
        for method: ExploreContractMethod,
        keypath: String
    ) async throws -> String? {
        if method == .set, CorrespondenceAgreementTemplates.attachmentGrantSpecifications.contains(where: { $0.keypath == keypath }) {
            return "-w--"
        }
        switch (method, keypath) {
        case (.get, "inbox"):
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
                return self.inviteIdentities(payload: payload, requester: requester)
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
        emit(event: "message.read", fields: [
            "messageID": .string(messageID),
            "requesterIdentityUUID": .string(requester.uuid)
        ])
        return (try? CorrespondenceCellCodec.encode(stored)) ?? .null
    }

    private func sendMessage(payload: ValueType, requester: Identity) async -> ValueType {
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
              !attachmentReservations.contains(messageID) else { return denial(.grantNotHeld) }
        if let attachment = request.attachmentRequest {
            guard attachment.messageID == messageID, attachment.senderIdentityUUID == requester.uuid,
                  let sourceCell = attachmentCells[requester.uuid] else { return denial(.grantNotHeld) }
            attachmentReservations.insert(messageID)
            defer { attachmentReservations.remove(messageID) }
            do {
                try await authorizeAttachment(attachment, action: "attachments.prepare", requester: requester)
                try await sourceCell.storage.publish(attachment,
                    expiresAt: now.addingTimeInterval(TimeInterval(retentionSeconds)), now: now)
            } catch { return .object(["status": .string("denied"), "denialReason": .string(String(describing: error))]) }
        }
        var outer = CorrespondenceOuterEnvelope(
            messageID: messageID,
            sequence: nextSequence,
            cellID: uuid,
            senderIdentityUUID: requester.uuid,
            purposeRef: Self.envelopePurposeRef,
            createdAt: Self.timestamp(now),
            expiresAt: Self.timestamp(now.addingTimeInterval(TimeInterval(retentionSeconds))),
            membershipFingerprint: membershipFingerprint,
            ciphertextSize: request.envelope.combinedCiphertext.count
        )
        outer.attachmentAgreementID = request.attachmentRequest?.agreementID
        nextSequence += 1
        storedEnvelopesByMessageID[messageID] = CorrespondenceStoredEnvelope(
            outer: outer,
            innerCiphertext: request.envelope
        )
        emit(event: "message.stored", fields: [
            "messageID": .string(messageID),
            "sequence": .integer(outer.sequence),
            "senderIdentityUUID": .string(requester.uuid),
            "purposeRef": .string(request.purposeRef),
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
        storedEnvelopesByMessageID[messageID] = stored
        emit(event: "message.receipt", fields: [
            "messageID": .string(messageID),
            "requesterIdentityUUID": .string(requester.uuid)
        ])
        return .object([
            "status": .string("acknowledged"),
            "messageID": .string(messageID)
        ])
    }

    private func inviteIdentities(payload: ValueType, requester: Identity) -> ValueType {
        let requestedUUIDs = identityUUIDs(from: payload)
        guard requestedUUIDs.isEmpty == false else {
            return .object([
                "status": .string("error"),
                "message": .string("At least one identity UUID is required.")
            ])
        }
        let now = Self.timestamp(nowProvider())
        var changed = false
        for identityUUID in requestedUUIDs where memberIdentityUUIDs.contains(identityUUID) == false {
            memberIdentityUUIDs.append(identityUUID)
            invitationLedger.append(
                CorrespondenceInvitationLedgerRecord(
                    identityUUID: identityUUID,
                    status: "accepted",
                    invitedAt: now
                )
            )
            changed = true
        }
        if changed {
            memberIdentityUUIDs.sort()
            membershipVersion += 1
            membershipFingerprint = calculateMembershipFingerprint()
            emit(event: "membership.changed", fields: [
                "membershipVersion": .integer(membershipVersion),
                "membershipFingerprint": .string(membershipFingerprint),
                "memberCount": .integer(memberIdentityUUIDs.count),
                "requesterIdentityUUID": .string(requester.uuid)
            ])
        }
        return .object([
            "status": .string(changed ? "invited" : "unchanged"),
            "membershipVersion": .integer(membershipVersion),
            "membershipFingerprint": .string(membershipFingerprint),
            "memberIdentityUUIDs": .list(memberIdentityUUIDs.map(ValueType.string))
        ])
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
        storedEnvelopesByMessageID.removeValue(forKey: messageID)
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
        guard decision.allowed, attachmentCells.isEmpty else { throw CorrespondenceAttachmentError.wrongSender }
        attachmentRoot = root
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
        if let existing = attachmentCells[sender.uuid] { return existing }
        attachmentCells[sender.uuid] = cell
        return cell
    }

    private func authorizeAttachment(_ request: CorrespondenceAttachmentRequest,
                                     action: String, requester: Identity) async throws {
        guard memberIdentityUUIDs.contains(requester.uuid),
              memberIdentityUUIDs.contains(request.senderIdentityUUID) else {
            throw CorrespondenceAttachmentError.wrongRecipient
        }
        let decision = await authorizationDecision(requestedAccess: "-w--", at: action, for: requester)
        guard decision.allowed else { throw CorrespondenceAttachmentError.wrongRecipient }
        let senderActions: Set<String> = ["attachments.prepare", "attachments.upload", "attachments.revoke", "attachments.transfer"]
        if senderActions.contains(action) {
            let agreements = await contractsForIdentity(requester)
            guard agreements.contains(where: { $0.uuid == request.agreementID && $0.checkGrant(requestedGrant: Grant(keypath: action, permission: "-w--")) }) else {
                throw CorrespondenceAttachmentError.contextMismatch
            }
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
                        return .object(["status": .string("error"), "message": .string(error.localizedDescription)])
                    }
                })
        }
    }

    private func performAttachment(_ action: String, request: CorrespondenceAttachmentRequest,
                                   requester: Identity) async throws -> ValueType {
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
            guard let id = request.sourceID else { throw CorrespondenceAttachmentError.unavailable }
            if request.confirmation == "reference-reachable" {
                result = try CorrespondenceCellCodec.encode(await source.storage.probe(sourceID: id, recipientKey: key, now: now))
            } else {
                result = try CorrespondenceCellCodec.encode(await source.storage.sourceDescriptor(sourceID: id))
            }
        case "attachments.prepare":
            guard UUID(uuidString: request.messageID) != nil else { throw CorrespondenceAttachmentError.contextMismatch }
            // Recipient keys are taken from admitted, signed Agreements.
            let agreements = await contractsForIdentity(requester)
            guard let agreement = agreements.first(where: { $0.uuid == request.agreementID }) else {
                throw CorrespondenceAttachmentError.contextMismatch
            }
            let keys = Set(agreement.signatories.filter { $0.uuid != requester.uuid }
                .compactMap(\.signingPublicKeyFingerprint))
            guard !keys.isEmpty else { throw CorrespondenceAttachmentError.wrongRecipient }
            result = try CorrespondenceCellCodec.encode(await source.storage.prepare(request, recipientKeys: keys,
                reference: "cell:///\(uuid)/attachments.fetch?source=\(request.sourceID ?? "")", now: now))
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
            "attachmentID": .string(request.attachmentID ?? ""), "requesterIdentityUUID": .string(requester.uuid)])
        return result
    }
}
