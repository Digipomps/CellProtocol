// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

public final class ChatCell: GeneralCell {
    private enum ChatInvitationArtifactInspectionState: String, Codable {
        case notFound
        case notIssued
        case issued
        case expired
        case consumed
        case revoked
        case declined
        case superseded

        var acceptanceAllowed: Bool {
            self == .issued
        }
    }

    private enum ChatAudienceMode: String, Codable {
        case contextMembers
        case invitedIdentities
        case hybrid

        var label: String {
            switch self {
            case .contextMembers:
                return "Context members"
            case .invitedIdentities:
                return "Invited identities"
            case .hybrid:
                return "Hybrid"
            }
        }

        var summary: String {
            switch self {
            case .contextMembers:
                return "Bruk kjente deltakere og kontekstmedlemmer som mottakere."
            case .invitedIdentities:
                return "Bruk bare eksplisitt inviterte identities som mottakere."
            case .hybrid:
                return "Bruk både kontekstmedlemmer og eksplisitt inviterte identities."
            }
        }
    }

    private enum ChatInvitationStatus: String, Codable {
        case pending
        case accepted
        case declined
        case revoked

        var label: String {
            switch self {
            case .pending:
                return "Pending"
            case .accepted:
                return "Accepted"
            case .declined:
                return "Declined"
            case .revoked:
                return "Revoked"
            }
        }

        var isResolvedRecipient: Bool {
            self == .accepted
        }
    }

    private enum ChatEncryptedPersistenceMode: String, Codable {
        case draftCacheOnly
        case draftAndSentArchive

        var label: String {
            switch self {
            case .draftCacheOnly:
                return "Draft cache only"
            case .draftAndSentArchive:
                return "Draft + sent archive"
            }
        }

        var summary: String {
            switch self {
            case .draftCacheOnly:
                return "Behold bare requester-scopet draft-envelope-cache. Sendte meldinger lagres som vanlig plaintext historikk."
            case .draftAndSentArchive:
                return "Behold draft-envelope-cache og arkiver krypterte companion-envelopes for sendte composed meldinger lokalt."
            }
        }

        var archivesSentEncryptedCompanions: Bool {
            self == .draftAndSentArchive
        }
    }

    private struct ChatParticipantRecord: Codable {
        var id: String
        var displayName: String
        var joinedAt: String
        var lastSeenAt: String
        var messageCount: Int
        var lastAction: String
        var presence: String

        func objectValue() -> Object {
            [
                "id": .string(id),
                "displayName": .string(displayName),
                "joinedAt": .string(joinedAt),
                "lastSeenAt": .string(lastSeenAt),
                "messageCount": .integer(messageCount),
                "lastAction": .string(lastAction),
                "presence": .string(presence),
                "initials": .string(ChatPresentation.initials(from: displayName)),
                "presenceLabel": .string(ChatPresentation.presenceLabel(for: presence, lastAction: lastAction)),
                "joinedDisplay": .string(ChatPresentation.absoluteTimestamp(from: joinedAt)),
                "lastSeenDisplay": .string(ChatPresentation.absoluteTimestamp(from: lastSeenAt)),
                "lastSeenRelative": .string(ChatPresentation.relativeTimestamp(from: lastSeenAt)),
                "messageCountLabel": .string(ChatPresentation.messageCountLabel(messageCount)),
                "activitySummary": .string(ChatPresentation.activitySummary(messageCount: messageCount, lastSeenAt: lastSeenAt))
            ]
        }
    }

    private struct ChatComposerDraft: Codable {
        var body: String
        var contentType: String

        static var empty: ChatComposerDraft {
            ChatComposerDraft(body: "", contentType: ChatCell.defaultContentType)
        }

        func objectValue() -> Object {
            [
                "body": .string(body),
                "contentType": .string(contentType)
            ]
        }
    }

    private struct ChatInvitationRecord: Codable {
        var identity: Identity
        var status: ChatInvitationStatus
        var source: String
        var createdAt: String
        var updatedAt: String
        var artifact: ChatInvitationArtifact?
        var acceptance: ChatInvitationAcceptance?

        func objectValue() -> Object {
            [
                "identityUUID": .string(identity.uuid),
                "displayName": .string(identity.displayName),
                "status": .string(status.rawValue),
                "statusLabel": .string(status.label),
                "source": .string(source),
                "createdAt": .string(createdAt),
                "updatedAt": .string(updatedAt),
                "isResolvedRecipient": .bool(status.isResolvedRecipient),
                "hasKeyAgreementKey": .bool(identity.publicKeyAgreementSecureKey != nil),
                "hasSigningKey": .bool(identity.publicSecureKey != nil),
                "artifactAvailable": .bool(artifact != nil),
                "artifactInvitationID": artifact.map { .string($0.invitationID) } ?? .null,
                "artifactIssuedAt": artifact.map { .string($0.createdAt) } ?? .null,
                "artifactExpiresAt": artifact.map { .string($0.expiresAt) } ?? .null,
                "artifactState": .string(artifactState),
                "artifactAcceptanceAllowed": .bool(artifactAcceptanceAllowed),
                "artifactConsumedAt": acceptance.map { .string($0.createdAt) } ?? .null,
                "proofBackedAcceptance": .bool(acceptance != nil),
                "acceptanceAvailable": .bool(acceptance != nil),
                "acceptanceID": acceptance.map { .string($0.acceptanceID) } ?? .null,
                "acceptanceCreatedAt": acceptance.map { .string($0.createdAt) } ?? .null
            ]
        }

        private var artifactState: String {
            if status == .revoked {
                return "revoked"
            }
            if status == .declined {
                return "declined"
            }
            guard let artifact else {
                return "notIssued"
            }
            if acceptance != nil {
                return "consumed"
            }
            if ChatInvitationProofUtility.isExpired(artifact.expiresAt) {
                return "expired"
            }
            return "issued"
        }

        private var artifactAcceptanceAllowed: Bool {
            artifactState == "issued"
        }
    }

    private struct ChatInvitationConsumptionRecord: Codable {
        var invitationID: String
        var acceptanceID: String
        var inviteeIdentityUUID: String
        var artifactHash: Data
        var consumedAt: String

        func matches(artifact: ChatInvitationArtifact, acceptance: ChatInvitationAcceptance, artifactHash: Data) -> Bool {
            invitationID == artifact.invitationID &&
            acceptanceID == acceptance.acceptanceID &&
            inviteeIdentityUUID == artifact.invitedIdentity.uuid &&
            self.artifactHash == artifactHash
        }
    }

    private struct ChatInvitationArtifactLedgerRecord: Codable {
        var invitationID: String
        var invitedIdentityUUID: String
        var artifactHash: Data
        var createdAt: String
        var expiresAt: String
        var state: ChatInvitationArtifactInspectionState
        var recordStatus: ChatInvitationStatus?
        var acceptanceID: String?
        var consumedAt: String?
        var supersededByInvitationID: String?
        var supersededAt: String?
        var lastUpdatedAt: String
    }

    private struct PreparedEnvelopeDraftRecord: Codable {
        var senderIdentityUUID: String
        var senderDisplayName: String
        var contentType: String
        var recipients: [IdentityRolePublicKeyDescriptor]
        var envelope: EncryptedContentEnvelope
        var updatedAt: String
    }

    private struct ChatMembershipFingerprintDescriptor: Codable {
        var audienceMode: String
        var persistenceMode: String
        var preferredSuiteID: String
        var recipientIdentityUUIDs: [String]
    }

    private struct ChatRekeyCheckpointRecord: Codable {
        var membershipVersion: Int
        var fingerprint: String
        var recipientIdentityUUIDs: [String]
        var audienceMode: String
        var suiteID: String
        var persistenceMode: String
        var envelopeGeneration: Int
        var updatedAt: String
        var reason: String

        private enum CodingKeys: String, CodingKey {
            case membershipVersion
            case fingerprint
            case recipientIdentityUUIDs
            case audienceMode
            case suiteID
            case persistenceMode
            case envelopeGeneration
            case updatedAt
            case reason
        }

        init(
            membershipVersion: Int,
            fingerprint: String,
            recipientIdentityUUIDs: [String],
            audienceMode: String,
            suiteID: String,
            persistenceMode: String,
            envelopeGeneration: Int,
            updatedAt: String,
            reason: String
        ) {
            self.membershipVersion = membershipVersion
            self.fingerprint = fingerprint
            self.recipientIdentityUUIDs = recipientIdentityUUIDs
            self.audienceMode = audienceMode
            self.suiteID = suiteID
            self.persistenceMode = persistenceMode
            self.envelopeGeneration = envelopeGeneration
            self.updatedAt = updatedAt
            self.reason = reason
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            membershipVersion = try container.decode(Int.self, forKey: .membershipVersion)
            fingerprint = try container.decode(String.self, forKey: .fingerprint)
            recipientIdentityUUIDs = try container.decode([String].self, forKey: .recipientIdentityUUIDs)
            audienceMode = try container.decode(String.self, forKey: .audienceMode)
            suiteID = try container.decode(String.self, forKey: .suiteID)
            persistenceMode = try container.decode(String.self, forKey: .persistenceMode)
            envelopeGeneration = try container.decodeIfPresent(Int.self, forKey: .envelopeGeneration) ?? 1
            updatedAt = try container.decode(String.self, forKey: .updatedAt)
            reason = try container.decode(String.self, forKey: .reason)
        }

        func objectValue() -> Object {
            [
                "membershipVersion": .integer(membershipVersion),
                "fingerprint": .string(fingerprint),
                "recipientIdentityUUIDs": .list(recipientIdentityUUIDs.map(ValueType.string)),
                "recipientCount": .integer(recipientIdentityUUIDs.count),
                "audienceMode": .string(audienceMode),
                "suiteID": .string(suiteID),
                "persistenceMode": .string(persistenceMode),
                "envelopeGeneration": .integer(envelopeGeneration),
                "updatedAt": .string(updatedAt),
                "reason": .string(reason)
            ]
        }
    }

    private struct PersistedEncryptedMessageRecord: Codable {
        var messageID: String
        var senderIdentityUUID: String
        var senderDisplayName: String
        var contentType: String
        var topic: String
        var recipients: [IdentityRolePublicKeyDescriptor]
        var envelope: EncryptedContentEnvelope
        var source: String
        var persistedAt: String
        var openStatus: String
        var lastOpenedAt: String?
        var lastOpenRecipientUUID: String?
        var lastSenderVerified: Bool?
        var lastOpenError: String?
    }

    private struct ParticipantUpdate {
        var record: ChatParticipantRecord
        var shouldPublish: Bool
    }

    private static let defaultContentType = "text/plain"
    private static let markdownContentType = "text/markdown"
    private static let supportedContentCryptoSuites: [ContentCryptoSuite] = [
        .chatMessageV1
    ]
    private static let contentCryptoPolicy = ContentCryptoPolicy.chatDefault
    private static let availableFormats: [Object] = [
        [
            "id": .string("plain"),
            "label": .string("Plain text"),
            "contentType": .string(defaultContentType),
            "description": .string("Vanlig tekst uten formattering.")
        ],
        [
            "id": .string("markdown"),
            "label": .string("Markdown"),
            "contentType": .string(markdownContentType),
            "description": .string("Tekst med enkel formattering som andre klienter kan rendre.")
        ]
    ]
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private var chatMessageHistory = [ChatMessage]()
    private var participantRecords = [String: ChatParticipantRecord]()
    private var participantIdentitiesByUUID = [String: Identity]()
    private var audienceMode: ChatAudienceMode = .hybrid
    private var invitedIdentitiesByUUID = [String: Identity]()
    private var invitationRecordsByIdentityUUID = [String: ChatInvitationRecord]()
    private var invitationConsumptionRecordsByInvitationID = [String: ChatInvitationConsumptionRecord]()
    private var invitationArtifactLedgerByInvitationID = [String: ChatInvitationArtifactLedgerRecord]()
    private var composerDraftsByRequester = [String: ChatComposerDraft]()
    private var preparedEnvelopeDraftsByRequester = [String: PreparedEnvelopeDraftRecord]()
    private var encryptedPersistenceMode: ChatEncryptedPersistenceMode = .draftCacheOnly
    private var encryptedMessageRecordsByMessageID = [String: PersistedEncryptedMessageRecord]()
    private var membershipVersion = 1
    private var currentMembershipFingerprint: String?
    private var currentEnvelopeGeneration = 1
    private var lastMembershipChangeAt: String?
    private var lastMembershipChangeReason: String?
    private var lastRekeyCheckpoint: ChatRekeyCheckpointRecord?
    private var messagesLimit = 200
    private var topic = "chat"
    private var running = false
    private var emitterTask: Task<Void, Never>?

    enum CodingKeys: String, CodingKey {
        case chatMessageHistory
        case participantRecords
        case audienceMode
        case invitedIdentitiesByUUID
        case invitationRecordsByIdentityUUID
        case invitationConsumptionRecordsByInvitationID
        case invitationArtifactLedgerByInvitationID
        case composerDraftsByRequester
        case preparedEnvelopeDraftsByRequester
        case encryptedPersistenceMode
        case encryptedMessageRecordsByMessageID
        case membershipVersion
        case currentMembershipFingerprint
        case currentEnvelopeGeneration
        case lastMembershipChangeAt
        case lastMembershipChangeReason
        case lastRekeyCheckpoint
        case messagesLimit
        case topic
        case running
        case generalCell
    }

    public required init(owner: Identity) async {
        await super.init(owner: owner)
        initializeMembershipTrackingIfNeeded(reason: "initialized")
        await setupPermissions(owner: owner)
        await setupKeys(owner: owner)
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.chatMessageHistory = try container.decodeIfPresent([ChatMessage].self, forKey: .chatMessageHistory) ?? []
        self.participantRecords = try container.decodeIfPresent([String: ChatParticipantRecord].self, forKey: .participantRecords) ?? [:]
        self.audienceMode = try container.decodeIfPresent(ChatAudienceMode.self, forKey: .audienceMode) ?? .hybrid
        let legacyInvitedIdentities = try container.decodeIfPresent([String: Identity].self, forKey: .invitedIdentitiesByUUID) ?? [:]
        self.invitedIdentitiesByUUID = legacyInvitedIdentities
        self.invitationRecordsByIdentityUUID = try container.decodeIfPresent([String: ChatInvitationRecord].self, forKey: .invitationRecordsByIdentityUUID) ?? legacyInvitedIdentities.reduce(into: [:]) { partialResult, item in
            partialResult[item.key] = ChatInvitationRecord(
                identity: item.value,
                status: .accepted,
                source: "legacyAccepted",
                createdAt: Self.timestampString(),
                updatedAt: Self.timestampString(),
                artifact: nil,
                acceptance: nil
            )
        }
        self.invitationConsumptionRecordsByInvitationID = try container.decodeIfPresent([String: ChatInvitationConsumptionRecord].self, forKey: .invitationConsumptionRecordsByInvitationID) ?? [:]
        self.invitationArtifactLedgerByInvitationID = try container.decodeIfPresent([String: ChatInvitationArtifactLedgerRecord].self, forKey: .invitationArtifactLedgerByInvitationID) ?? [:]
        self.composerDraftsByRequester = try container.decodeIfPresent([String: ChatComposerDraft].self, forKey: .composerDraftsByRequester) ?? [:]
        self.preparedEnvelopeDraftsByRequester = try container.decodeIfPresent([String: PreparedEnvelopeDraftRecord].self, forKey: .preparedEnvelopeDraftsByRequester) ?? [:]
        self.encryptedPersistenceMode = try container.decodeIfPresent(ChatEncryptedPersistenceMode.self, forKey: .encryptedPersistenceMode) ?? .draftCacheOnly
        self.encryptedMessageRecordsByMessageID = try container.decodeIfPresent([String: PersistedEncryptedMessageRecord].self, forKey: .encryptedMessageRecordsByMessageID) ?? [:]
        self.membershipVersion = try container.decodeIfPresent(Int.self, forKey: .membershipVersion) ?? 1
        self.currentMembershipFingerprint = try container.decodeIfPresent(String.self, forKey: .currentMembershipFingerprint)
        self.lastMembershipChangeAt = try container.decodeIfPresent(String.self, forKey: .lastMembershipChangeAt)
        self.lastMembershipChangeReason = try container.decodeIfPresent(String.self, forKey: .lastMembershipChangeReason)
        self.lastRekeyCheckpoint = try container.decodeIfPresent(ChatRekeyCheckpointRecord.self, forKey: .lastRekeyCheckpoint)
        self.currentEnvelopeGeneration = try container.decodeIfPresent(Int.self, forKey: .currentEnvelopeGeneration)
            ?? self.lastRekeyCheckpoint?.envelopeGeneration
            ?? 1
        self.messagesLimit = try container.decodeIfPresent(Int.self, forKey: .messagesLimit) ?? 200
        self.topic = try container.decodeIfPresent(String.self, forKey: .topic) ?? "chat"
        self.running = try container.decodeIfPresent(Bool.self, forKey: .running) ?? false
        try super.init(from: decoder)
        normalizeInvitationArtifactLedger()
        initializeMembershipTrackingIfNeeded(reason: "decoded")

        Task {
            await setupPermissions(owner: self.owner)
            await setupKeys(owner: self.owner)
            if self.running {
                await self.resumeEmitterIfNeeded()
            }
        }
    }

    deinit {
        emitterTask?.cancel()
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chatMessageHistory, forKey: .chatMessageHistory)
        try container.encode(participantRecords, forKey: .participantRecords)
        try container.encode(audienceMode, forKey: .audienceMode)
        try container.encode(invitedIdentitiesByUUID, forKey: .invitedIdentitiesByUUID)
        try container.encode(invitationRecordsByIdentityUUID, forKey: .invitationRecordsByIdentityUUID)
        try container.encode(invitationConsumptionRecordsByInvitationID, forKey: .invitationConsumptionRecordsByInvitationID)
        try container.encode(invitationArtifactLedgerByInvitationID, forKey: .invitationArtifactLedgerByInvitationID)
        try container.encode(composerDraftsByRequester, forKey: .composerDraftsByRequester)
        try container.encode(preparedEnvelopeDraftsByRequester, forKey: .preparedEnvelopeDraftsByRequester)
        try container.encode(encryptedPersistenceMode, forKey: .encryptedPersistenceMode)
        try container.encode(encryptedMessageRecordsByMessageID, forKey: .encryptedMessageRecordsByMessageID)
        try container.encode(membershipVersion, forKey: .membershipVersion)
        try container.encode(currentMembershipFingerprint, forKey: .currentMembershipFingerprint)
        try container.encode(currentEnvelopeGeneration, forKey: .currentEnvelopeGeneration)
        try container.encode(lastMembershipChangeAt, forKey: .lastMembershipChangeAt)
        try container.encode(lastMembershipChangeReason, forKey: .lastMembershipChangeReason)
        try container.encode(lastRekeyCheckpoint, forKey: .lastRekeyCheckpoint)
        try container.encode(messagesLimit, forKey: .messagesLimit)
        try container.encode(topic, forKey: .topic)
        try container.encode(running, forKey: .running)
    }

    public override func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, Error> {
        let update = observeParticipant(requester: requester, action: "subscribed")
        if update.shouldPublish {
            publishParticipantEvent(update.record, requester: requester)
            publishStatusEvent(requester: requester)
        }
        return try await super.flow(requester: requester)
    }

    private func setupPermissions(owner: Identity) async {
        agreementTemplate.addGrant("r---", for: "feed")
        agreementTemplate.addGrant("rw--", for: "chat")
        agreementTemplate.addGrant("rw--", for: "status")
        agreementTemplate.addGrant("rw--", for: "state")
        agreementTemplate.addGrant("rw--", for: "messages")
        agreementTemplate.addGrant("rw--", for: "participants")
        agreementTemplate.addGrant("rw--", for: "members")
        agreementTemplate.addGrant("rw--", for: "audience")
        agreementTemplate.addGrant("rw--", for: "audience.mode")
        agreementTemplate.addGrant("r---", for: "audience.inheritedRecipients")
        agreementTemplate.addGrant("r---", for: "audience.invitedRecipients")
        agreementTemplate.addGrant("r---", for: "audience.resolvedRecipients")
        agreementTemplate.addGrant("r---", for: "audience.invitations")
        agreementTemplate.addGrant("r---", for: "audience.invitationLedger")
        agreementTemplate.addGrant("r---", for: "audience.invitationArtifacts")
        agreementTemplate.addGrant("r---", for: "audience.inspectInvitationArtifact")
        agreementTemplate.addGrant("rw--", for: "audience.inviteIdentities")
        agreementTemplate.addGrant("rw--", for: "audience.generateInvitationArtifacts")
        agreementTemplate.addGrant("rw--", for: "audience.generateInvitationAcceptance")
        agreementTemplate.addGrant("rw--", for: "audience.acceptInvitationArtifact")
        agreementTemplate.addGrant("rw--", for: "audience.acceptInvites")
        agreementTemplate.addGrant("rw--", for: "audience.declineInvites")
        agreementTemplate.addGrant("rw--", for: "audience.revokeInvites")
        agreementTemplate.addGrant("rw--", for: "audience.removeContextMembers")
        agreementTemplate.addGrant("rw--", for: "audience.clearInvites")
        agreementTemplate.addGrant("rw--", for: "compose")
        agreementTemplate.addGrant("rw--", for: "compose.state")
        agreementTemplate.addGrant("rw--", for: "compose.previewRows")
        agreementTemplate.addGrant("r---", for: "crypto")
        agreementTemplate.addGrant("r---", for: "crypto.state")
        agreementTemplate.addGrant("r---", for: "crypto.policy")
        agreementTemplate.addGrant("r---", for: "crypto.supportedSuites")
        agreementTemplate.addGrant("r---", for: "crypto.recipients")
        agreementTemplate.addGrant("r---", for: "crypto.membership")
        agreementTemplate.addGrant("r---", for: "crypto.rekeyStatus")
        agreementTemplate.addGrant("r---", for: "crypto.persistencePolicy")
        agreementTemplate.addGrant("r---", for: "crypto.persistenceMode")
        agreementTemplate.addGrant("r---", for: "crypto.encryptedMessages")
        agreementTemplate.addGrant("r---", for: "crypto.draftEnvelope")
        agreementTemplate.addGrant("rw--", for: "crypto.persistenceMode")
        agreementTemplate.addGrant("rw--", for: "crypto.requestRekey")
        agreementTemplate.addGrant("rw--", for: "crypto.prepareDraftEnvelope")
        agreementTemplate.addGrant("rw--", for: "crypto.openEnvelope")
        agreementTemplate.addGrant("rw--", for: "crypto.clearDraftEnvelope")
        agreementTemplate.addGrant("rw--", for: "crypto.clearEncryptedMessages")
        agreementTemplate.addGrant("rw--", for: "sendMessage")
        agreementTemplate.addGrant("rw--", for: "sendComposedMessage")
        agreementTemplate.addGrant("rw--", for: "clearComposer")
        agreementTemplate.addGrant("rw--", for: "addMessage")
        agreementTemplate.addGrant("rw--", for: "start")
        agreementTemplate.addGrant("rw--", for: "stop")
    }

    private func setupKeys(owner: Identity) async {
        await registerGet(key: "status", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "status") else { return .string("denied") }
            let update = self.observeParticipant(requester: requester, action: "status")
            if update.shouldPublish {
                self.publishParticipantEvent(update.record, requester: requester)
                self.publishStatusEvent(requester: requester)
            }
            return .string(self.statusSummary())
        }

        await registerGet(key: "state", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "state") else { return .string("denied") }
            let update = self.observeParticipant(requester: requester, action: "state")
            if update.shouldPublish {
                self.publishParticipantEvent(update.record, requester: requester)
                self.publishStatusEvent(requester: requester)
            }
            return .object(self.statePayload(for: requester))
        }

        await registerGet(key: "messages", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "messages") else { return .string("denied") }
            let update = self.observeParticipant(requester: requester, action: "messages")
            if update.shouldPublish {
                self.publishParticipantEvent(update.record, requester: requester)
            }
            return self.messagesPayload()
        }

        await registerGet(key: "participants", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "participants") else { return .string("denied") }
            let update = self.observeParticipant(requester: requester, action: "participants")
            if update.shouldPublish {
                self.publishParticipantEvent(update.record, requester: requester)
                self.publishStatusEvent(requester: requester)
            }
            return self.participantsPayload()
        }

        await registerGet(key: "members", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "members") else { return .string("denied") }
            return self.participantsPayload()
        }

        await registerGet(key: "audience", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "audience") else { return .string("denied") }
            return .object(self.audiencePayload())
        }

        await registerGet(key: "audience.mode", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "audience.mode") else { return .string("denied") }
            return .string(self.audienceMode.rawValue)
        }

        await registerSet(key: "audience.mode", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "audience.mode") else { return .string("denied") }
            guard let mode = ChatAudienceMode(rawValue: self.stringValue(payload) ?? "") else {
                return .string("error: unsupported audience mode")
            }
            self.audienceMode = mode
            self.noteAudienceMembershipMutation(reason: "audienceModeChanged")
            self.invalidateAllPreparedEnvelopeDrafts()
            return .object(self.audiencePayload())
        }

        await registerGet(key: "audience.inheritedRecipients", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "audience.inheritedRecipients") else { return .string("denied") }
            return .list(self.contextAudienceRecipientObjects())
        }

        await registerGet(key: "audience.invitedRecipients", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "audience.invitedRecipients") else { return .string("denied") }
            return .list(self.invitedAudienceRecipientObjects())
        }

        await registerGet(key: "audience.resolvedRecipients", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "audience.resolvedRecipients") else { return .string("denied") }
            return .list(self.resolvedAudienceRecipientObjects())
        }

        await registerGet(key: "audience.invitations", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "audience.invitations") else { return .string("denied") }
            return .list(self.invitationObjects())
        }

        await registerGet(key: "audience.invitationLedger", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "audience.invitationLedger") else { return .string("denied") }
            return .list(self.invitationArtifactLedgerObjects())
        }

        await registerGet(key: "audience.invitationArtifacts", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "audience.invitationArtifacts") else { return .string("denied") }
            return .list(self.invitationArtifactObjects())
        }

        await registerSet(key: "audience.inspectInvitationArtifact", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "audience.inspectInvitationArtifact") else { return .string("denied") }
            return self.inspectInvitationArtifact(payload: payload)
        }

        await registerSet(key: "audience.inviteIdentities", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "audience.inviteIdentities") else { return .string("denied") }
            return .object(self.inviteIdentities(from: payload, source: "manual"))
        }

        await registerSet(key: "audience.generateInvitationArtifacts", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "audience.generateInvitationArtifacts") else { return .string("denied") }
            return await self.generateInvitationArtifacts(from: payload, requester: requester)
        }

        await registerSet(key: "audience.generateInvitationAcceptance", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "audience.generateInvitationAcceptance") else { return .string("denied") }
            return await self.generateInvitationAcceptance(payload: payload, requester: requester)
        }

        await registerSet(key: "audience.acceptInvitationArtifact", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "audience.acceptInvitationArtifact") else { return .string("denied") }
            return await self.acceptInvitationArtifact(payload: payload, requester: requester)
        }

        await registerSet(key: "audience.acceptInvites", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "audience.acceptInvites") else { return .string("denied") }
            return .object(self.updateInvitationStatuses(from: payload, to: .accepted))
        }

        await registerSet(key: "audience.declineInvites", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "audience.declineInvites") else { return .string("denied") }
            return .object(self.updateInvitationStatuses(from: payload, to: .declined))
        }

        await registerSet(key: "audience.revokeInvites", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "audience.revokeInvites") else { return .string("denied") }
            return .object(self.updateInvitationStatuses(from: payload, to: .revoked))
        }

        await registerSet(key: "audience.removeContextMembers", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "audience.removeContextMembers") else { return .string("denied") }
            return .object(self.removeContextMembers(from: payload))
        }

        await registerSet(key: "audience.clearInvites", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "audience.clearInvites") else { return .string("denied") }
            _ = payload
            self.persistInvitationArtifactLedgerBeforeClearingInvites()
            self.invitedIdentitiesByUUID.removeAll()
            self.invitationRecordsByIdentityUUID.removeAll()
            self.noteAudienceMembershipMutation(reason: "invitesCleared")
            self.invalidateAllPreparedEnvelopeDrafts()
            return .object(self.audiencePayload())
        }

        await registerGet(key: "compose.body", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "compose.body") else { return .string("denied") }
            let update = self.observeParticipant(requester: requester, action: "compose")
            if update.shouldPublish {
                self.publishParticipantEvent(update.record, requester: requester)
            }
            return .string(self.draft(for: requester).body)
        }

        await registerGet(key: "compose.contentType", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "compose.contentType") else { return .string("denied") }
            return .string(self.draft(for: requester).contentType)
        }

        await registerGet(key: "compose.availableFormats", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "compose.availableFormats") else { return .string("denied") }
            return .list(Self.availableFormats.map(ValueType.object))
        }

        await registerGet(key: "compose.state", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "compose.state") else { return .string("denied") }
            let update = self.observeParticipant(requester: requester, action: "compose")
            if update.shouldPublish {
                self.publishParticipantEvent(update.record, requester: requester)
            }
            return .object(self.composerStatePayload(for: requester))
        }

        await registerGet(key: "compose.previewRows", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "compose.previewRows") else { return .string("denied") }
            return .list([.object(self.composerStatePayload(for: requester))])
        }

        await registerGet(key: "crypto", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "crypto") else { return .string("denied") }
            return .object(self.cryptoStatePayload())
        }

        await registerGet(key: "crypto.state", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "crypto.state") else { return .string("denied") }
            return .object(self.cryptoStatePayload())
        }

        await registerGet(key: "crypto.policy", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "crypto.policy") else { return .string("denied") }
            return .object(Self.contentCryptoPolicyObject())
        }

        await registerGet(key: "crypto.supportedSuites", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "crypto.supportedSuites") else { return .string("denied") }
            return .list(Self.supportedContentCryptoSuites.map { .object(Self.contentCryptoSuiteObject($0)) })
        }

        await registerGet(key: "crypto.recipients", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "crypto.recipients") else { return .string("denied") }
            return .list(await self.cryptoRecipientObjects(for: requester))
        }

        await registerGet(key: "crypto.membership", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "crypto.membership") else { return .string("denied") }
            return .object(self.cryptoMembershipPayload())
        }

        await registerGet(key: "crypto.rekeyStatus", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "crypto.rekeyStatus") else { return .string("denied") }
            return .object(self.cryptoRekeyStatusPayload())
        }

        await registerGet(key: "crypto.persistencePolicy", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "crypto.persistencePolicy") else { return .string("denied") }
            return .object(self.cryptoPersistencePolicyPayload())
        }

        await registerGet(key: "crypto.persistenceMode", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "crypto.persistenceMode") else { return .string("denied") }
            return .string(self.encryptedPersistenceMode.rawValue)
        }

        await registerSet(key: "crypto.persistenceMode", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "crypto.persistenceMode") else { return .string("denied") }
            guard let mode = ChatEncryptedPersistenceMode(rawValue: self.stringValue(payload) ?? "") else {
                return .string("error: unsupported encrypted persistence mode")
            }
            self.encryptedPersistenceMode = mode
            self.noteAudienceMembershipMutation(reason: "persistenceModeChanged")
            self.invalidateAllPreparedEnvelopeDrafts()
            return .object(self.cryptoPersistencePolicyPayload())
        }

        await registerGet(key: "crypto.encryptedMessages", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "crypto.encryptedMessages") else { return .string("denied") }
            return .list(self.persistedEncryptedMessageObjects())
        }

        await registerGet(key: "crypto.draftEnvelope", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canRead(requester, keypath: "crypto.draftEnvelope") else { return .string("denied") }
            return self.preparedEnvelopeDraftValue(for: requester)
        }

        await registerSet(key: "crypto.prepareDraftEnvelope", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "crypto.prepareDraftEnvelope") else { return .string("denied") }
            return await self.prepareDraftEnvelope(payload: payload, requester: requester)
        }

        await registerSet(key: "crypto.requestRekey", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "crypto.requestRekey") else { return .string("denied") }
            return .object(self.requestRekey(payload: payload))
        }

        await registerSet(key: "crypto.openEnvelope", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "crypto.openEnvelope") else { return .string("denied") }
            return await self.openEnvelope(payload: payload, requester: requester)
        }

        await registerSet(key: "crypto.clearDraftEnvelope", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "crypto.clearDraftEnvelope") else { return .string("denied") }
            _ = payload
            self.clearPreparedEnvelopeDraft(for: requester)
            return .null
        }

        await registerSet(key: "crypto.clearEncryptedMessages", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "crypto.clearEncryptedMessages") else { return .string("denied") }
            _ = payload
            self.encryptedMessageRecordsByMessageID.removeAll()
            return .null
        }

        await registerGet(key: "start", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "start") else { return .string("denied") }
            return await self.startEmitter(requester: requester)
        }

        await registerGet(key: "stop", owner: owner) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "stop") else { return .string("denied") }
            return await self.stopEmitter(requester: requester)
        }

        await registerSet(key: "compose.body", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "compose.body") else { return .string("denied") }
            let body = self.stringValue(payload) ?? ""
            self.setDraftBody(body, requester: requester)
            let update = self.observeParticipant(requester: requester, action: "compose")
            if update.shouldPublish {
                self.publishParticipantEvent(update.record, requester: requester)
            }
            return .string(body)
        }

        await registerSet(key: "compose.contentType", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "compose.contentType") else { return .string("denied") }
            let normalized = self.normalizedContentType(from: self.stringValue(payload))
            self.setDraftContentType(normalized, requester: requester)
            return .string(normalized)
        }

        await registerSet(key: "sendMessage", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "sendMessage") else { return .string("denied") }
            return await self.sendMessage(payload: payload, requester: requester)
        }

        await registerSet(key: "addMessage", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "addMessage") else { return .string("denied") }
            return await self.sendMessage(payload: payload, requester: requester)
        }

        await registerSet(key: "sendComposedMessage", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "sendComposedMessage") else { return .string("denied") }
            _ = payload
            return await self.sendComposedMessage(requester: requester)
        }

        await registerSet(key: "clearComposer", owner: owner) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.canWrite(requester, keypath: "clearComposer") else { return .string("denied") }
            _ = payload
            self.clearDraft(for: requester, keepContentType: true)
            return .object(self.draft(for: requester).objectValue())
        }

        await registerContracts(requester: owner)
    }

    private func canRead(_ requester: Identity, keypath: String) async -> Bool {
        let directAccess = await validateAccess("r---", at: keypath, for: requester)
        if directAccess {
            return true
        }
        return await validateAccess("r---", at: "chat", for: requester)
    }

    private func canWrite(_ requester: Identity, keypath: String) async -> Bool {
        let directAccess = await validateAccess("rw--", at: keypath, for: requester)
        if directAccess {
            return true
        }
        return await validateAccess("rw--", at: "chat", for: requester)
    }

    private func messagesPayload() -> ValueType {
        .list(chatMessageHistory.map { .object(messageObject(for: $0)) })
    }

    private func participantsPayload() -> ValueType {
        .list(sortedParticipants().map { .object($0.objectValue()) })
    }

    private func statePayload(for requester: Identity) -> Object {
        [
            "topic": .string(topic),
            "status": .string(statusSummary()),
            "statusDetail": .object(statusPayloadObject()),
            "messages": messagesPayload(),
            "participants": participantsPayload(),
            "members": participantsPayload(),
            "audience": .object(audiencePayload()),
            "messageCount": .integer(chatMessageHistory.count),
            "participantCount": .integer(participantRecords.count),
            "messagesLimit": .integer(messagesLimit),
            "running": .bool(running),
            "composer": .object(composerStatePayload(for: requester)),
            "crypto": .object(cryptoStatePayload()),
            "availableFormats": .list(Self.availableFormats.map(ValueType.object))
        ]
    }

    private func statusPayloadObject() -> Object {
        var payload: Object = [
            "summary": .string(statusSummary()),
            "topic": .string(topic),
            "messageCount": .integer(chatMessageHistory.count),
            "participantCount": .integer(participantRecords.count),
            "messagesLimit": .integer(messagesLimit),
            "running": .bool(running)
        ]

        if let latestMessage = chatMessageHistory.last {
            let preview = ChatPresentation.preview(for: latestMessage.content)
            payload["latestMessageAt"] = .string(latestMessage.createdAt)
            payload["latestMessagePreview"] = .string(preview)
            payload["latestMessageContentType"] = .string(latestMessage.contentType)
            payload["latestMessageDisplayAt"] = .string(ChatPresentation.absoluteTimestamp(from: latestMessage.createdAt))
            payload["latestMessageRelativeAt"] = .string(ChatPresentation.relativeTimestamp(from: latestMessage.createdAt))
        } else {
            payload["latestMessageAt"] = .null
            payload["latestMessagePreview"] = .null
            payload["latestMessageContentType"] = .null
            payload["latestMessageDisplayAt"] = .null
            payload["latestMessageRelativeAt"] = .null
        }

        return payload
    }

    private func statusSummary() -> String {
        "participants: \(participantRecords.count) · messages: \(chatMessageHistory.count) · topic: \(topic)"
    }

    private func preferredContentCryptoSuite() -> ContentCryptoSuite {
        Self.supportedContentCryptoSuites.first {
            $0.id == Self.contentCryptoPolicy.preferredSuiteID
        } ?? .chatMessageV1
    }

    private func currentMembershipRecipientIDs() -> [String] {
        currentRecipientIdentities().map(\.uuid).sorted()
    }

    private func currentMembershipFingerprintDescriptor() -> ChatMembershipFingerprintDescriptor {
        ChatMembershipFingerprintDescriptor(
            audienceMode: audienceMode.rawValue,
            persistenceMode: encryptedPersistenceMode.rawValue,
            preferredSuiteID: preferredContentCryptoSuite().id,
            recipientIdentityUUIDs: currentMembershipRecipientIDs()
        )
    }

    private func membershipFingerprint(for descriptor: ChatMembershipFingerprintDescriptor) -> String {
        guard let canonicalData = try? CanonicalPayloadEncoder.data(for: descriptor) else {
            return descriptor.recipientIdentityUUIDs.joined(separator: "|")
        }
        return Data(SHA256.hash(data: canonicalData)).map { String(format: "%02x", $0) }.joined()
    }

    private func currentMembershipFingerprintValue() -> String {
        membershipFingerprint(for: currentMembershipFingerprintDescriptor())
    }

    private func currentMembershipCheckpoint(reason: String? = nil, updatedAt: String? = nil) -> ChatRekeyCheckpointRecord {
        let descriptor = currentMembershipFingerprintDescriptor()
        return ChatRekeyCheckpointRecord(
            membershipVersion: membershipVersion,
            fingerprint: membershipFingerprint(for: descriptor),
            recipientIdentityUUIDs: descriptor.recipientIdentityUUIDs,
            audienceMode: descriptor.audienceMode,
            suiteID: descriptor.preferredSuiteID,
            persistenceMode: descriptor.persistenceMode,
            envelopeGeneration: currentEnvelopeGeneration,
            updatedAt: updatedAt ?? Self.timestampString(),
            reason: reason ?? lastMembershipChangeReason ?? "baseline"
        )
    }

    private func initializeMembershipTrackingIfNeeded(reason: String) {
        let now = Self.timestampString()
        if membershipVersion < 1 {
            membershipVersion = 1
        }
        if currentEnvelopeGeneration < 1 {
            currentEnvelopeGeneration = 1
        }
        let fingerprint = currentMembershipFingerprintValue()
        if currentMembershipFingerprint == nil {
            currentMembershipFingerprint = fingerprint
        }
        if lastMembershipChangeAt == nil {
            lastMembershipChangeAt = now
        }
        if lastMembershipChangeReason == nil {
            lastMembershipChangeReason = reason
        }
        if let lastRekeyCheckpoint, currentEnvelopeGeneration < lastRekeyCheckpoint.envelopeGeneration {
            currentEnvelopeGeneration = lastRekeyCheckpoint.envelopeGeneration
        }
        if lastRekeyCheckpoint == nil {
            lastRekeyCheckpoint = currentMembershipCheckpoint(reason: reason, updatedAt: now)
        }
    }

    private func noteAudienceMembershipMutation(reason: String) {
        initializeMembershipTrackingIfNeeded(reason: reason)
        let nextFingerprint = currentMembershipFingerprintValue()
        guard nextFingerprint != currentMembershipFingerprint else { return }
        membershipVersion = max(membershipVersion + 1, 1)
        currentMembershipFingerprint = nextFingerprint
        lastMembershipChangeAt = Self.timestampString()
        lastMembershipChangeReason = reason
    }

    private func isRekeyRequired() -> Bool {
        currentMembershipFingerprintValue() != lastRekeyCheckpoint?.fingerprint
    }

    private func cryptoMembershipPayload() -> Object {
        let descriptor = currentMembershipFingerprintDescriptor()
        let fingerprint = membershipFingerprint(for: descriptor)
        return [
            "membershipVersion": .integer(membershipVersion),
            "fingerprint": .string(fingerprint),
            "envelopeGeneration": .integer(currentEnvelopeGeneration),
            "recipientIdentityUUIDs": .list(descriptor.recipientIdentityUUIDs.map(ValueType.string)),
            "recipientCount": .integer(descriptor.recipientIdentityUUIDs.count),
            "audienceMode": .string(descriptor.audienceMode),
            "audienceModeLabel": .string(audienceMode.label),
            "suiteID": .string(descriptor.preferredSuiteID),
            "persistenceMode": .string(descriptor.persistenceMode),
            "lastMembershipChangeAt": lastMembershipChangeAt.map(ValueType.string) ?? .null,
            "lastMembershipChangeReason": lastMembershipChangeReason.map(ValueType.string) ?? .null
        ]
    }

    private func rekeySummary(rekeyRequired: Bool, currentFingerprint: String) -> String {
        guard rekeyRequired else {
            return "Gjeldende mottakersett matcher siste rekey-checkpoint."
        }
        let lastCheckpointVersion = lastRekeyCheckpoint?.membershipVersion ?? 0
        let targetVersion = membershipVersion
        if let lastFingerprint = lastRekeyCheckpoint?.fingerprint, lastFingerprint != currentFingerprint {
            return "Mottakersettet har endret seg siden membership version \(lastCheckpointVersion). Bekreft rekey før dere bruker neste envelope generation som gjeldende."
        }
        return "Mottakersettet er oppdatert til membership version \(targetVersion), men ingen rekey-checkpoint er satt ennå for neste envelope generation."
    }

    private func cryptoRekeyStatusPayload() -> Object {
        let currentFingerprint = currentMembershipFingerprintValue()
        let rekeyRequired = isRekeyRequired()
        return [
            "rekeyRequired": .bool(rekeyRequired),
            "summary": .string(rekeySummary(rekeyRequired: rekeyRequired, currentFingerprint: currentFingerprint)),
            "membershipVersion": .integer(membershipVersion),
            "currentEnvelopeGeneration": .integer(currentEnvelopeGeneration),
            "currentFingerprint": .string(currentFingerprint),
            "lastRekeyFingerprint": lastRekeyCheckpoint.map { .string($0.fingerprint) } ?? .null,
            "lastRekeyAt": lastRekeyCheckpoint.map { .string($0.updatedAt) } ?? .null,
            "lastRekeyReason": lastRekeyCheckpoint.map { .string($0.reason) } ?? .null,
            "lastRekeyMembershipVersion": lastRekeyCheckpoint.map { .integer($0.membershipVersion) } ?? .null,
            "lastRekeyEnvelopeGeneration": lastRekeyCheckpoint.map { .integer($0.envelopeGeneration) } ?? .null,
            "currentMembership": .object(cryptoMembershipPayload()),
            "lastRekeyCheckpoint": lastRekeyCheckpoint.map { .object($0.objectValue()) } ?? .null
        ]
    }

    private func requestRekey(payload: ValueType) -> Object {
        initializeMembershipTrackingIfNeeded(reason: "requestRekey")
        let payloadObject = objectValue(payload) ?? [:]
        let providedReason = stringValue(payloadObject["reason"]) ??
            stringValue(payloadObject["source"]) ??
            stringValue(payload)
        let currentFingerprint = currentMembershipFingerprintValue()
        let alreadyCurrent = currentFingerprint == lastRekeyCheckpoint?.fingerprint
        let reason = providedReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? providedReason!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (alreadyCurrent ? "manualConfirmation" : "membershipChanged")
        if alreadyCurrent == false {
            currentEnvelopeGeneration = max(currentEnvelopeGeneration + 1, 1)
        }
        lastRekeyCheckpoint = currentMembershipCheckpoint(reason: reason)
        invalidateAllPreparedEnvelopeDrafts()
        return [
            "status": .string(alreadyCurrent ? "alreadyCurrent" : "rekeyed"),
            "membershipVersion": .integer(membershipVersion),
            "envelopeGeneration": .integer(currentEnvelopeGeneration),
            "rekeyStatus": .object(cryptoRekeyStatusPayload()),
            "membership": .object(cryptoMembershipPayload())
        ]
    }

    private func cryptoStatePayload() -> Object {
        initializeMembershipTrackingIfNeeded(reason: "cryptoState")
        let preferredSuite = preferredContentCryptoSuite()
        let keyProviderAvailable = activeKeyProvider() != nil
        let recipientCount = currentRecipientIdentities().count
        let rekeyRequired = isRekeyRequired()

        return [
            "status": .string(keyProviderAvailable ? "preview-ready" : "bootstrap"),
            "summary": .string(keyProviderAvailable
                ? "Envelope-forberedelse og åpning er tilgjengelig for løste mottakere, men vanlig send-flyt er fortsatt ukryptert."
                : "Crypto policy and suites are declared, but chat payload encryption is not active yet."
            ),
            "encryptionEnabled": .bool(false),
            "bootstrapOnly": .bool(true),
            "envelopePreparationAvailable": .bool(keyProviderAvailable),
            "envelopeOpenAvailable": .bool(keyProviderAvailable),
            "draftEnvelopeCacheCount": .integer(preparedEnvelopeDraftsByRequester.count),
            "encryptedMessageArchiveCount": .integer(encryptedMessageRecordsByMessageID.count),
            "rekeyRequired": .bool(rekeyRequired),
            "rekeySummary": .string(rekeySummary(rekeyRequired: rekeyRequired, currentFingerprint: currentMembershipFingerprintValue())),
            "membershipVersion": .integer(membershipVersion),
            "currentEnvelopeGeneration": .integer(currentEnvelopeGeneration),
            "lastMembershipChangeAt": lastMembershipChangeAt.map(ValueType.string) ?? .null,
            "lastMembershipChangeReason": lastMembershipChangeReason.map(ValueType.string) ?? .null,
            "lastRekeyAt": lastRekeyCheckpoint.map { .string($0.updatedAt) } ?? .null,
            "preferredSuiteID": .string(Self.contentCryptoPolicy.preferredSuiteID),
            "preferredSuite": .object(Self.contentCryptoSuiteObject(preferredSuite)),
            "policy": .object(Self.contentCryptoPolicyObject()),
            "persistencePolicy": .object(cryptoPersistencePolicyPayload()),
            "membership": .object(cryptoMembershipPayload()),
            "rekeyStatus": .object(cryptoRekeyStatusPayload()),
            "supportedSuites": .list(Self.supportedContentCryptoSuites.map { .object(Self.contentCryptoSuiteObject($0)) }),
            "recipientCount": .integer(recipientCount),
            "audienceMode": .string(audienceMode.rawValue),
            "audienceModeLabel": .string(audienceMode.label),
            "supportsForwardSecrecy": .bool(preferredSuite.supportsForwardSecrecy),
            "requiresSenderSignature": .bool(preferredSuite.requiresSenderSignature)
        ]
    }

    private func cryptoPersistencePolicyPayload() -> Object {
        [
            "mode": .string(encryptedPersistenceMode.rawValue),
            "modeLabel": .string(encryptedPersistenceMode.label),
            "summary": .string(encryptedPersistenceMode.summary),
            "archivesSentEncryptedCompanions": .bool(encryptedPersistenceMode.archivesSentEncryptedCompanions),
            "draftEnvelopeCacheCount": .integer(preparedEnvelopeDraftsByRequester.count),
            "encryptedMessageArchiveCount": .integer(encryptedMessageRecordsByMessageID.count)
        ]
    }

    private func composerStatePayload(for requester: Identity) -> Object {
        let currentDraft = draft(for: requester)
        let body = currentDraft.body
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let characterCount = body.count
        let lineCount: Int = {
            guard body.isEmpty == false else { return 0 }
            return body.components(separatedBy: .newlines).count
        }()
        let contentType = normalizedContentType(from: currentDraft.contentType)
        let isMarkdown = ChatPresentation.isMarkdown(contentType: contentType)
        let previewText = trimmed.isEmpty
            ? "_Start å skrive for å se forhåndsvisning her._"
            : ChatPresentation.richTextContent(from: body, contentType: contentType)

        return [
            "id": .string("compose-\(requester.uuid)"),
            "body": .string(body),
            "contentType": .string(contentType),
            "formatLabel": .string(ChatPresentation.formatLabel(for: contentType)),
            "formatDescription": .string(ChatPresentation.formatDescription(for: contentType)),
            "helperText": .string(ChatPresentation.composerHelperText(for: contentType)),
            "placeholder": .string("Skriv melding. Velg markdown hvis du vil bruke formattering som **fet**, lister eller lenker."),
            "previewRichText": .string(previewText),
            "previewSummary": .string(trimmed.isEmpty ? "Ingen melding ennå" : ChatPresentation.preview(for: body)),
            "characterCount": .integer(characterCount),
            "characterCountLabel": .string(ChatPresentation.characterCountLabel(characterCount)),
            "lineCount": .integer(lineCount),
            "lineCountLabel": .string(ChatPresentation.lineCountLabel(lineCount)),
            "isEmpty": .bool(trimmed.isEmpty),
            "isMarkdown": .bool(isMarkdown),
            "sendHint": .string(ChatPresentation.composerSendHint(isEmpty: trimmed.isEmpty, contentType: contentType))
        ]
    }

    private func draft(for requester: Identity) -> ChatComposerDraft {
        composerDraftsByRequester[requester.uuid] ?? .empty
    }

    private func setDraftBody(_ body: String, requester: Identity) {
        var current = draft(for: requester)
        current.body = body
        composerDraftsByRequester[requester.uuid] = current
        clearPreparedEnvelopeDraft(for: requester)
    }

    private func setDraftContentType(_ contentType: String, requester: Identity) {
        var current = draft(for: requester)
        current.contentType = normalizedContentType(from: contentType)
        composerDraftsByRequester[requester.uuid] = current
        clearPreparedEnvelopeDraft(for: requester)
    }

    private func clearDraft(for requester: Identity, keepContentType: Bool) {
        let current = draft(for: requester)
        composerDraftsByRequester[requester.uuid] = ChatComposerDraft(
            body: "",
            contentType: keepContentType ? current.contentType : Self.defaultContentType
        )
        clearPreparedEnvelopeDraft(for: requester)
    }

    private func observeParticipant(requester: Identity, action: String, incrementMessageCount: Bool = false) -> ParticipantUpdate {
        participantIdentitiesByUUID[requester.uuid] = requester
        let now = Self.timestampString()
        var record = participantRecords[requester.uuid] ?? ChatParticipantRecord(
            id: requester.uuid,
            displayName: requester.displayName,
            joinedAt: now,
            lastSeenAt: now,
            messageCount: 0,
            lastAction: action,
            presence: "present"
        )

        let hadExistingRecord = participantRecords[requester.uuid] != nil
        let displayNameChanged = record.displayName != requester.displayName

        record.displayName = requester.displayName
        record.lastSeenAt = now
        record.lastAction = action
        record.presence = incrementMessageCount ? "messaging" : "present"
        if incrementMessageCount {
            record.messageCount += 1
        }

        participantRecords[requester.uuid] = record
        if hadExistingRecord == false {
            noteAudienceMembershipMutation(reason: "contextMemberJoined")
        }
        return ParticipantUpdate(
            record: record,
            shouldPublish: !hadExistingRecord || incrementMessageCount || displayNameChanged
        )
    }

    private func activeKeyProvider() -> IdentityKeyRoleProviderProtocol? {
        if let provider = owner.identityVault as? IdentityKeyRoleProviderProtocol {
            return provider
        }
        if let provider = CellBase.defaultIdentityVault as? IdentityKeyRoleProviderProtocol {
            return provider
        }
        return nil
    }

    private func audiencePayload() -> Object {
        let inheritedRecipients = contextRecipientIdentities()
        let resolvedRecipients = currentRecipientIdentities()
        let invitationRecords = sortedInvitationRecords()
        let acceptedInviteCount = invitationRecords.filter { $0.status == .accepted }.count
        let pendingInviteCount = invitationRecords.filter { $0.status == .pending }.count
        let declinedInviteCount = invitationRecords.filter { $0.status == .declined }.count
        let revokedInviteCount = invitationRecords.filter { $0.status == .revoked }.count

        return [
            "mode": .string(audienceMode.rawValue),
            "modeLabel": .string(audienceMode.label),
            "summary": .string(audienceMode.summary),
            "inheritedRecipients": .list(contextAudienceRecipientObjects()),
            "invitedRecipients": .list(invitedAudienceRecipientObjects()),
            "resolvedRecipients": .list(resolvedAudienceRecipientObjects()),
            "invitations": .list(invitationObjects()),
            "invitationLedgerCount": .integer(invitationArtifactLedgerByInvitationID.count),
            "inheritedCount": .integer(max(inheritedRecipients.count - 1, 0)),
            "invitedCount": .integer(acceptedInviteCount),
            "resolvedCount": .integer(resolvedRecipients.count),
            "invitationCount": .integer(invitationRecords.count),
            "pendingInviteCount": .integer(pendingInviteCount),
            "acceptedInviteCount": .integer(acceptedInviteCount),
            "declinedInviteCount": .integer(declinedInviteCount),
            "revokedInviteCount": .integer(revokedInviteCount),
            "supportsContextMembers": .bool(true),
            "supportsExplicitInvites": .bool(true),
            "defaultForEmbeddedComponent": .string(ChatAudienceMode.hybrid.rawValue),
            "assistantHint": .string("AI kan foreslå audience.mode og invitees, men brukeren bør bekrefte før invitasjoner sendes eller aksepteres.")
        ]
    }

    private func contextRecipientIdentities() -> [Identity] {
        var ordered: [Identity] = [owner]
        let knownParticipants = participantIdentitiesByUUID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        ordered.append(contentsOf: knownParticipants)
        return deduplicatedIdentities(from: ordered)
    }

    private func invitedRecipientIdentities() -> [Identity] {
        let invited = invitedIdentitiesByUUID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        return deduplicatedIdentities(from: [owner] + invited)
    }

    private func sortedInvitationRecords() -> [ChatInvitationRecord] {
        invitationRecordsByIdentityUUID.values.sorted { lhs, rhs in
            if lhs.status != rhs.status {
                return lhs.status.rawValue < rhs.status.rawValue
            }
            return lhs.identity.displayName.localizedCaseInsensitiveCompare(rhs.identity.displayName) == .orderedAscending
        }
    }

    private func deduplicatedIdentities(from identities: [Identity]) -> [Identity] {
        var deduplicated: [Identity] = []
        var seen = Set<String>()
        for identity in identities where seen.insert(identity.uuid).inserted {
            deduplicated.append(identity)
        }
        return deduplicated
    }

    private func currentRecipientIdentities(preferredIDs: [String]? = nil) -> [Identity] {
        let resolvedRecipients: [Identity]
        switch audienceMode {
        case .contextMembers:
            resolvedRecipients = contextRecipientIdentities()
        case .invitedIdentities:
            resolvedRecipients = invitedRecipientIdentities()
        case .hybrid:
            resolvedRecipients = deduplicatedIdentities(from: contextRecipientIdentities() + invitedRecipientIdentities())
        }

        guard let preferredIDs, preferredIDs.isEmpty == false else {
            return resolvedRecipients
        }

        let filtered = resolvedRecipients.filter { preferredIDs.contains($0.uuid) || $0.uuid == owner.uuid }
        return filtered.isEmpty ? [owner] : filtered
    }

    private func audienceRecipientObject(_ identity: Identity, source: String) -> ValueType {
        .object([
            "identityUUID": .string(identity.uuid),
            "displayName": .string(identity.displayName),
            "source": .string(source),
            "isOwner": .bool(identity.uuid == owner.uuid),
            "hasKeyAgreementKey": .bool(identity.publicKeyAgreementSecureKey != nil),
            "hasSigningKey": .bool(identity.publicSecureKey != nil)
        ])
    }

    private func contextAudienceRecipientObjects() -> [ValueType] {
        contextRecipientIdentities().map { identity in
            audienceRecipientObject(identity, source: identity.uuid == owner.uuid ? "owner" : "context")
        }
    }

    private func invitedAudienceRecipientObjects() -> [ValueType] {
        invitedRecipientIdentities().map { identity in
            audienceRecipientObject(identity, source: identity.uuid == owner.uuid ? "owner" : "invited")
        }
    }

    private func resolvedAudienceRecipientObjects() -> [ValueType] {
        let contextIDs = Set(contextRecipientIdentities().map(\.uuid))
        let invitedIDs = Set(invitedRecipientIdentities().map(\.uuid))
        return currentRecipientIdentities().map { identity in
            let source: String
            if identity.uuid == owner.uuid {
                source = "owner"
            } else if contextIDs.contains(identity.uuid) && invitedIDs.contains(identity.uuid) {
                source = "hybrid"
            } else if invitedIDs.contains(identity.uuid) {
                source = "invited"
            } else {
                source = "context"
            }
            return audienceRecipientObject(identity, source: source)
        }
    }

    private func invitationObjects() -> [ValueType] {
        sortedInvitationRecords().map { .object($0.objectValue()) }
    }

    private func invitationArtifactLedgerObjects() -> [ValueType] {
        invitationArtifactLedgerByInvitationID.values.sorted { lhs, rhs in
            if lhs.lastUpdatedAt != rhs.lastUpdatedAt {
                return lhs.lastUpdatedAt > rhs.lastUpdatedAt
            }
            return lhs.invitationID.localizedCaseInsensitiveCompare(rhs.invitationID) == .orderedAscending
        }.map { .object(invitationArtifactLedgerObject($0)) }
    }

    private func invitationArtifactObjects() -> [ValueType] {
        sortedInvitationRecords().compactMap { record in
            guard let artifact = record.artifact,
                  invitationArtifactInspectionState(for: artifact, currentRecord: record) == .issued else {
                return nil
            }
            return .object(Self.invitationArtifactObject(artifact))
        }
    }

    private func inspectInvitationArtifact(payload: ValueType) -> ValueType {
        guard let artifact = invitationArtifactValue(from: payload) else {
            return .string("error: invalid invitation artifact payload")
        }
        return .object(invitationArtifactInspectionObject(for: artifact))
    }

    private func preparedEnvelopeDraftValue(for requester: Identity) -> ValueType {
        guard let record = preparedEnvelopeDraftsByRequester[requester.uuid] else {
            return .null
        }
        return .object(Self.preparedEnvelopeDraftObject(record))
    }

    private func persistedEncryptedMessageObjects() -> [ValueType] {
        sortedPersistedEncryptedMessageRecords().map { .object(Self.persistedEncryptedMessageObject($0)) }
    }

    private func storePreparedEnvelopeDraft(
        for requester: Identity,
        sender: Identity,
        contentType: String,
        recipients: [IdentityRolePublicKeyDescriptor],
        envelope: EncryptedContentEnvelope
    ) {
        preparedEnvelopeDraftsByRequester[requester.uuid] = PreparedEnvelopeDraftRecord(
            senderIdentityUUID: sender.uuid,
            senderDisplayName: sender.displayName,
            contentType: contentType,
            recipients: recipients,
            envelope: envelope,
            updatedAt: Self.timestampString()
        )
    }

    private func clearPreparedEnvelopeDraft(for requester: Identity) {
        preparedEnvelopeDraftsByRequester.removeValue(forKey: requester.uuid)
    }

    private func invalidateAllPreparedEnvelopeDrafts() {
        preparedEnvelopeDraftsByRequester.removeAll()
    }

    private func sortedPersistedEncryptedMessageRecords() -> [PersistedEncryptedMessageRecord] {
        encryptedMessageRecordsByMessageID.values.sorted { lhs, rhs in
            if lhs.persistedAt != rhs.persistedAt {
                return lhs.persistedAt > rhs.persistedAt
            }
            return lhs.messageID.localizedCaseInsensitiveCompare(rhs.messageID) == .orderedAscending
        }
    }

    private func messageObject(for message: ChatMessage) -> Object {
        var object = message.messageObject()
        if let encryptedRecord = encryptedMessageRecordsByMessageID[message.id] {
            object["cryptoState"] = .string("encryptedCompanionAvailable")
            object["encryptedCompanionAvailable"] = .bool(true)
            object["crypto"] = .object(Self.persistedEncryptedMessageSummaryObject(encryptedRecord))
        } else {
            object["cryptoState"] = .string("plaintextOnly")
            object["encryptedCompanionAvailable"] = .bool(false)
            object["crypto"] = .object([
                "state": .string("plaintextOnly"),
                "openStatus": .string("notApplicable"),
                "recipientCount": .integer(0),
                "source": .null,
                "persistedAt": .null,
                "lastOpenedAt": .null,
                "lastOpenRecipientUUID": .null,
                "senderVerified": .null,
                "lastOpenError": .null
            ])
        }
        return object
    }

    private func cryptoRecipientObjects(for requester: Identity) async -> [ValueType] {
        guard let provider = activeKeyProvider() else { return [] }
        let recipients = currentRecipientIdentities(preferredIDs: [requester.uuid] + currentRecipientIdentities().map(\.uuid))
        guard let descriptors = try? await ContentCryptoEnvelopeUtility.recipientDescriptors(
            for: recipients,
            provider: provider
        ) else {
            return []
        }
        return descriptors.map { .object(Self.recipientDescriptorObject($0)) }
    }

    private func prepareDraftEnvelope(payload: ValueType, requester: Identity) async -> ValueType? {
        guard let provider = activeKeyProvider() else {
            return .string("error: crypto key provider unavailable")
        }
        initializeMembershipTrackingIfNeeded(reason: "prepareDraftEnvelope")

        let requestedBody = stringValue(objectValue(payload)?["content"]) ??
            stringValue(objectValue(payload)?["body"]) ??
            stringValue(objectValue(payload)?["text"])
        let contentTypeOverride = normalizedContentType(
            from: stringValue(objectValue(payload)?["contentType"]) ?? stringValue(objectValue(payload)?["format"])
        )
        let recipientIDs = stringListValue(objectValue(payload)?["recipientIDs"])

        let draftBody = requestedBody ?? draft(for: requester).body
        let trimmedBody = draftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedBody.isEmpty == false else {
            return .string("error: empty composer body")
        }

        let contentType = requestedBody == nil ? normalizedContentType(from: draft(for: requester).contentType) : contentTypeOverride
        let recipients = currentRecipientIdentities(preferredIDs: recipientIDs)
        let suite = Self.supportedContentCryptoSuites.first ?? .chatMessageV1

        do {
            let envelope = try await ContentCryptoEnvelopeUtility.seal(
                plaintext: Data(trimmedBody.utf8),
                sender: requester,
                recipients: recipients,
                provider: provider,
                suite: suite,
                associatedDataContext: "chat:\(topic):\(contentType)",
                envelopeGeneration: currentEnvelopeGeneration
            )

            let recipientDescriptors = try await ContentCryptoEnvelopeUtility.recipientDescriptors(
                for: recipients,
                provider: provider
            )
            storePreparedEnvelopeDraft(
                for: requester,
                sender: requester,
                contentType: contentType,
                recipients: recipientDescriptors,
                envelope: envelope
            )

            return .object([
                "status": .string("prepared"),
                "senderIdentityUUID": .string(requester.uuid),
                "senderDisplayName": .string(requester.displayName),
                "contentType": .string(contentType),
                "recipientCount": .integer(recipients.count),
                "recipients": .list(recipientDescriptors.map { .object(Self.recipientDescriptorObject($0)) }),
                "envelopeGeneration": envelope.header.envelopeGeneration.map(ValueType.integer) ?? .null,
                "header": .object(Self.encryptedEnvelopeHeaderObject(envelope.header)),
                "combinedCiphertextBase64": .string(envelope.combinedCiphertext.base64EncodedString()),
                "senderSignatureBase64": envelope.senderSignature.map { .string($0.base64EncodedString()) } ?? .null,
                "updatedAt": .string(Self.timestampString())
            ])
        } catch {
            return .string("error: \(error)")
        }
    }

    private func openEnvelope(payload: ValueType, requester: Identity) async -> ValueType? {
        guard let provider = activeKeyProvider() else {
            return .string("error: crypto key provider unavailable")
        }
        guard let envelope = envelopeValue(from: payload) else {
            return .string("error: invalid encrypted envelope payload")
        }

        let payloadObject = objectValue(payload) ?? [:]
        let messageID = stringValue(payloadObject["messageID"])
        let recipient = resolveIdentity(
            directValue: payloadObject["recipientIdentity"],
            explicitUUID: stringValue(payloadObject["recipientIdentityUUID"]),
            fallback: requester
        )
        let sender = identityValue(payloadObject["senderIdentity"]) ??
            stringValue(payloadObject["senderIdentityUUID"]).flatMap { resolveIdentity(explicitUUID: $0) }

        do {
            let opened = try await ContentCryptoEnvelopeUtility.open(
                envelope: envelope,
                recipient: recipient,
                sender: sender,
                provider: provider
            )
            let plaintextString = String(data: opened.plaintext, encoding: .utf8)
            let parsedContext = parsedAssociatedDataContext(opened.associatedDataContext)
            var response: Object = [
                "status": .string("opened"),
                "recipientIdentityUUID": .string(opened.recipientIdentityUUID),
                "recipientKeyID": .string(opened.recipientKeyID),
                "senderVerified": .bool(opened.senderVerified),
                "suiteID": .string(opened.suiteID),
                "envelopeGeneration": opened.envelopeGeneration.map(ValueType.integer) ?? .null,
                "plaintextBase64": .string(opened.plaintext.base64EncodedString())
            ]
            response["senderIdentityUUID"] = sender.map { ValueType.string($0.uuid) } ?? .null
            response["associatedDataContext"] = opened.associatedDataContext.map(ValueType.string) ?? .null
            response["contentType"] = parsedContext.contentType.map(ValueType.string) ?? .null
            response["topic"] = parsedContext.topic.map(ValueType.string) ?? .null
            response["plaintext"] = plaintextString.map(ValueType.string) ?? .null
            if let messageID {
                markEncryptedMessageOpenSuccess(
                    messageID: messageID,
                    recipientUUID: opened.recipientIdentityUUID,
                    senderVerified: opened.senderVerified
                )
            }
            return .object(response)
        } catch {
            if let messageID {
                markEncryptedMessageOpenFailure(messageID: messageID, recipientUUID: recipient.uuid, error: error)
            }
            return .string("error: \(error)")
        }
    }

    private func generateInvitationArtifacts(from payload: ValueType, requester: Identity) async -> ValueType? {
        _ = requester
        let targetUUIDs = invitationTargetUUIDs(from: payload)
        let idsToGenerate = targetUUIDs.isEmpty ? Set(invitationRecordsByIdentityUUID.keys) : targetUUIDs
        let createdAt = Self.timestampString()
        let expiresAt = Self.timestampString(Date().addingTimeInterval(60 * 60 * 24 * 7))
        var artifacts = [ValueType]()

        for id in idsToGenerate {
            guard var record = invitationRecordsByIdentityUUID[id], record.status != .revoked else { continue }
            if let artifact = record.artifact,
               invitationArtifactInspectionState(for: artifact, currentRecord: record) == .issued {
                syncInvitationArtifactLedger(for: artifact, record: record, stateOverride: .issued, at: record.updatedAt)
                artifacts.append(.object(Self.invitationArtifactObject(artifact)))
                continue
            }

            if record.status == .declined {
                record.status = .pending
            }

            let priorArtifact = record.artifact
            let priorInvitationID = priorArtifact?.invitationID
            do {
                let artifact = try await ChatInvitationProofUtility.generateInvitationArtifact(
                    chatCellUUID: uuid,
                    topic: topic,
                    audienceMode: audienceMode.rawValue,
                    suiteID: Self.contentCryptoPolicy.preferredSuiteID,
                    persistenceMode: encryptedPersistenceMode.rawValue,
                    inviter: owner,
                    invited: record.identity,
                    invitationID: UUID().uuidString,
                    createdAt: createdAt,
                    expiresAt: expiresAt
                )
                record.artifact = artifact
                record.acceptance = nil
                record.updatedAt = createdAt
                invitationRecordsByIdentityUUID[id] = record
                if let priorInvitationID {
                    invitationConsumptionRecordsByInvitationID.removeValue(forKey: priorInvitationID)
                }
                if let priorArtifact {
                    syncInvitationArtifactLedger(
                        for: priorArtifact,
                        record: record,
                        stateOverride: .superseded,
                        at: createdAt,
                        supersededByInvitationID: artifact.invitationID
                    )
                }
                syncInvitationArtifactLedger(for: artifact, record: record, stateOverride: .issued, at: createdAt)
                artifacts.append(.object(Self.invitationArtifactObject(artifact)))
            } catch {
                return .string("error: \(error)")
            }
        }

        return .list(artifacts)
    }

    private func generateInvitationAcceptance(payload: ValueType, requester: Identity) async -> ValueType? {
        guard let artifact = invitationArtifactValue(from: payload) else {
            return .string("error: invalid invitation artifact payload")
        }
        guard artifact.invitedIdentity.uuid == requester.uuid else {
            return .string("error: requester does not match invited identity")
        }

        do {
            let acceptance = try await ChatInvitationProofUtility.generateAcceptance(
                for: artifact,
                invitee: requester,
                createdAt: Self.timestampString()
            )
            return .object(Self.invitationAcceptanceObject(acceptance))
        } catch {
            return .string("error: \(error)")
        }
    }

    private func acceptInvitationArtifact(payload: ValueType, requester: Identity) async -> ValueType? {
        _ = requester
        let object = objectValue(payload) ?? [:]
        guard let artifact = invitationArtifactValue(from: object["artifact"] ?? payload),
              let acceptance = invitationAcceptanceValue(from: object["acceptance"]) else {
            return .string("error: invalid invitation artifact acceptance payload")
        }

        do {
            _ = try await ChatInvitationProofUtility.verifyInvitationArtifact(
                artifact,
                expectedChatCellUUID: uuid,
                expectedInviterUUID: owner.uuid
            )
            _ = try await ChatInvitationProofUtility.verifyAcceptance(
                acceptance,
                for: artifact,
                expectedChatCellUUID: uuid
            )

            let inviteeIdentity = resolveInvitationIdentity(from: artifact.invitedIdentity)
            let now = Self.timestampString()
            guard var record = invitationRecordsByIdentityUUID[inviteeIdentity.uuid] else {
                return .string("error: invitation record not found for artifact")
            }

            guard let currentArtifact = record.artifact else {
                return .string("error: invitation artifact is no longer active")
            }

            let artifactHash = try ChatInvitationProofUtility.invitationHash(for: artifact)
            let currentArtifactHash = try ChatInvitationProofUtility.invitationHash(for: currentArtifact)

            guard currentArtifact.invitationID == artifact.invitationID,
                  currentArtifactHash == artifactHash else {
                return .string("error: invitation artifact has been superseded")
            }

            if record.status == .revoked {
                return .string("error: invitation artifact has been revoked")
            }

            if record.status == .declined {
                return .string("error: invitation artifact has been declined")
            }

            if invitationArtifactInspectionState(for: artifact, currentRecord: record) == .expired {
                return .string("error: invitation artifact has expired")
            }

            if let existingConsumption = invitationConsumptionRecordsByInvitationID[artifact.invitationID] {
                if existingConsumption.matches(artifact: artifact, acceptance: acceptance, artifactHash: artifactHash) {
                    record.identity = inviteeIdentity
                    record.status = .accepted
                    record.source = "artifactAccepted"
                    record.updatedAt = now
                    record.artifact = artifact
                    record.acceptance = acceptance
                    invitationRecordsByIdentityUUID[inviteeIdentity.uuid] = record
                    syncInvitationArtifactLedger(for: artifact, record: record, stateOverride: .consumed, at: now)
                    syncAcceptedInvitedIdentitiesFromInvitationRecords()
                    noteAudienceMembershipMutation(reason: "artifactAccepted")
                    invalidateAllPreparedEnvelopeDrafts()
                    return .object([
                        "status": .string("accepted"),
                        "idempotent": .bool(true),
                        "invitationID": .string(artifact.invitationID),
                        "acceptanceID": .string(acceptance.acceptanceID),
                        "audience": .object(audiencePayload()),
                        "invitation": .object(record.objectValue())
                    ])
                }
                return .string("error: invitation artifact already consumed")
            }

            if invitationConsumptionRecordsByInvitationID.values.contains(where: { $0.acceptanceID == acceptance.acceptanceID }) {
                return .string("error: acceptance proof already consumed")
            }

            record.identity = inviteeIdentity
            record.status = .accepted
            record.source = "artifactAccepted"
            record.updatedAt = now
            record.artifact = artifact
            record.acceptance = acceptance
            invitationRecordsByIdentityUUID[inviteeIdentity.uuid] = record
            invitationConsumptionRecordsByInvitationID[artifact.invitationID] = ChatInvitationConsumptionRecord(
                invitationID: artifact.invitationID,
                acceptanceID: acceptance.acceptanceID,
                inviteeIdentityUUID: inviteeIdentity.uuid,
                artifactHash: artifactHash,
                consumedAt: now
            )
            syncInvitationArtifactLedger(for: artifact, record: record, stateOverride: .consumed, at: now)

            syncAcceptedInvitedIdentitiesFromInvitationRecords()
            noteAudienceMembershipMutation(reason: "artifactAccepted")
            invalidateAllPreparedEnvelopeDrafts()

            return .object([
                "status": .string("accepted"),
                "idempotent": .bool(false),
                "invitationID": .string(artifact.invitationID),
                "acceptanceID": .string(acceptance.acceptanceID),
                "audience": .object(audiencePayload()),
                "invitation": .object(record.objectValue())
            ])
        } catch {
            return .string("error: \(error)")
        }
    }

    private func inviteIdentities(from payload: ValueType, source: String) -> Object {
        let newIdentities = identities(from: payload)
        let resolvedFromIDs = stringListValue(payload)?.compactMap { resolveIdentity(explicitUUID: $0) } ?? []
        let allIdentities = deduplicatedIdentities(from: newIdentities + resolvedFromIDs)
        let timestamp = Self.timestampString()

        for identity in allIdentities where identity.uuid != owner.uuid {
            if var existing = invitationRecordsByIdentityUUID[identity.uuid] {
                existing.identity = identity
                if existing.status != .accepted {
                    existing.status = .pending
                }
                existing.source = source
                existing.updatedAt = timestamp
                existing.acceptance = nil
                invitationRecordsByIdentityUUID[identity.uuid] = existing
                if let artifact = existing.artifact {
                    syncInvitationArtifactLedger(for: artifact, record: existing, at: timestamp)
                }
            } else {
                invitationRecordsByIdentityUUID[identity.uuid] = ChatInvitationRecord(
                    identity: identity,
                    status: .pending,
                    source: source,
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    artifact: nil,
                    acceptance: nil
                )
            }
        }

        syncAcceptedInvitedIdentitiesFromInvitationRecords()
        noteAudienceMembershipMutation(reason: "inviteesUpdated")
        invalidateAllPreparedEnvelopeDrafts()
        return audiencePayload()
    }

    private func updateInvitationStatuses(from payload: ValueType, to status: ChatInvitationStatus) -> Object {
        let targetUUIDs = invitationTargetUUIDs(from: payload)
        let idsToUpdate = targetUUIDs.isEmpty ? Set(invitationRecordsByIdentityUUID.keys) : targetUUIDs
        let timestamp = Self.timestampString()

        for id in idsToUpdate {
            guard var existing = invitationRecordsByIdentityUUID[id] else { continue }
            existing.status = status
            existing.updatedAt = timestamp
            invitationRecordsByIdentityUUID[id] = existing
            if let artifact = existing.artifact {
                syncInvitationArtifactLedger(for: artifact, record: existing, at: timestamp)
            }
        }

        syncAcceptedInvitedIdentitiesFromInvitationRecords()
        noteAudienceMembershipMutation(reason: "invitationStatusChanged:\(status.rawValue)")
        invalidateAllPreparedEnvelopeDrafts()
        return audiencePayload()
    }

    private func removeContextMembers(from payload: ValueType) -> Object {
        let targetUUIDs = invitationTargetUUIDs(from: payload)
        let idsToRemove = targetUUIDs.isEmpty
            ? Set(participantRecords.keys.filter { $0 != owner.uuid })
            : targetUUIDs.subtracting([owner.uuid])

        var removedAny = false
        for id in idsToRemove {
            let removedRecord = participantRecords.removeValue(forKey: id)
            let removedIdentity = participantIdentitiesByUUID.removeValue(forKey: id)
            if removedRecord != nil || removedIdentity != nil {
                removedAny = true
            }
        }

        if removedAny {
            noteAudienceMembershipMutation(reason: "contextMembersRemoved")
            invalidateAllPreparedEnvelopeDrafts()
        }

        return audiencePayload()
    }

    private func invitationTargetUUIDs(from payload: ValueType) -> Set<String> {
        let directIDs = Set((stringListValue(payload) ?? []).compactMap { resolveIdentity(explicitUUID: $0)?.uuid ?? $0 })
        let identityIDs = Set(identities(from: payload).map(\.uuid))
        return directIDs.union(identityIDs)
    }

    private func syncAcceptedInvitedIdentitiesFromInvitationRecords() {
        invitedIdentitiesByUUID = invitationRecordsByIdentityUUID.reduce(into: [:]) { partialResult, item in
            guard item.value.status == .accepted else { return }
            partialResult[item.key] = item.value.identity
        }
    }

    private func normalizeInvitationArtifactLedger() {
        if invitationArtifactLedgerByInvitationID.isEmpty == false {
            for record in invitationRecordsByIdentityUUID.values {
                guard let artifact = record.artifact else { continue }
                syncInvitationArtifactLedger(for: artifact, record: record, at: record.updatedAt)
            }
            return
        }

        for record in invitationRecordsByIdentityUUID.values {
            guard let artifact = record.artifact else { continue }
            syncInvitationArtifactLedger(for: artifact, record: record, at: record.updatedAt)
        }
    }

    private func syncInvitationArtifactLedger(
        for artifact: ChatInvitationArtifact,
        record: ChatInvitationRecord,
        stateOverride: ChatInvitationArtifactInspectionState? = nil,
        at timestamp: String,
        supersededByInvitationID: String? = nil
    ) {
        guard let artifactHash = try? ChatInvitationProofUtility.invitationHash(for: artifact) else { return }
        var ledgerRecord = invitationArtifactLedgerByInvitationID[artifact.invitationID] ?? ChatInvitationArtifactLedgerRecord(
            invitationID: artifact.invitationID,
            invitedIdentityUUID: record.identity.uuid,
            artifactHash: artifactHash,
            createdAt: artifact.createdAt,
            expiresAt: artifact.expiresAt,
            state: .issued,
            recordStatus: record.status,
            acceptanceID: nil,
            consumedAt: nil,
            supersededByInvitationID: nil,
            supersededAt: nil,
            lastUpdatedAt: timestamp
        )

        ledgerRecord.invitedIdentityUUID = record.identity.uuid
        ledgerRecord.artifactHash = artifactHash
        ledgerRecord.createdAt = artifact.createdAt
        ledgerRecord.expiresAt = artifact.expiresAt
        ledgerRecord.state = stateOverride ?? invitationArtifactInspectionStateFromCurrentRecord(for: artifact, currentRecord: record)
        ledgerRecord.recordStatus = record.status
        ledgerRecord.acceptanceID = record.acceptance?.acceptanceID
        ledgerRecord.consumedAt = record.acceptance?.createdAt
        ledgerRecord.lastUpdatedAt = timestamp

        if let supersededByInvitationID {
            ledgerRecord.supersededByInvitationID = supersededByInvitationID
            ledgerRecord.supersededAt = timestamp
        } else if ledgerRecord.state != .superseded {
            ledgerRecord.supersededByInvitationID = nil
            ledgerRecord.supersededAt = nil
        }

        invitationArtifactLedgerByInvitationID[artifact.invitationID] = ledgerRecord
    }

    private func markInvitationArtifactLedgerState(
        invitationID: String,
        state: ChatInvitationArtifactInspectionState,
        recordStatus: ChatInvitationStatus?,
        at timestamp: String,
        supersededByInvitationID: String? = nil
    ) {
        guard var ledgerRecord = invitationArtifactLedgerByInvitationID[invitationID] else { return }
        ledgerRecord.state = state
        ledgerRecord.recordStatus = recordStatus
        ledgerRecord.lastUpdatedAt = timestamp
        if let supersededByInvitationID {
            ledgerRecord.supersededByInvitationID = supersededByInvitationID
            ledgerRecord.supersededAt = timestamp
        }
        invitationArtifactLedgerByInvitationID[invitationID] = ledgerRecord
    }

    private func persistInvitationArtifactLedgerBeforeClearingInvites() {
        let timestamp = Self.timestampString()
        for record in invitationRecordsByIdentityUUID.values {
            guard let artifact = record.artifact else { continue }
            let currentState = invitationArtifactInspectionStateFromCurrentRecord(for: artifact, currentRecord: record)
            let stateToPersist: ChatInvitationArtifactInspectionState
            switch currentState {
            case .issued, .notIssued:
                stateToPersist = .revoked
            default:
                stateToPersist = currentState
            }
            syncInvitationArtifactLedger(for: artifact, record: record, stateOverride: stateToPersist, at: timestamp)
        }
    }

    private func sortedParticipants() -> [ChatParticipantRecord] {
        participantRecords.values.sorted { lhs, rhs in
            if lhs.messageCount != rhs.messageCount {
                return lhs.messageCount > rhs.messageCount
            }
            if lhs.lastSeenAt != rhs.lastSeenAt {
                return lhs.lastSeenAt > rhs.lastSeenAt
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func sendMessage(payload: ValueType, requester: Identity) async -> ValueType? {
        guard let message = message(from: payload, requester: requester) else {
            return .string("error: invalid chat payload")
        }
        return storeMessage(message, requester: requester)
    }

    private func sendComposedMessage(requester: Identity) async -> ValueType? {
        let currentDraft = draft(for: requester)
        let trimmed = currentDraft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return .string("error: empty composer body")
        }

        let message = ChatMessage(
            owner: requester,
            content: trimmed,
            contentType: normalizedContentType(from: currentDraft.contentType),
            topic: topic
        )
        let preparedEnvelopeRecord = preparedEnvelopeDraftsByRequester[requester.uuid]
        clearDraft(for: requester, keepContentType: true)
        return storeMessage(message, requester: requester, encryptedDraftRecord: preparedEnvelopeRecord)
    }

    private func storeMessage(
        _ message: ChatMessage,
        requester: Identity,
        encryptedDraftRecord: PreparedEnvelopeDraftRecord? = nil
    ) -> ValueType {
        chatMessageHistory.append(message)
        if chatMessageHistory.count > messagesLimit {
            chatMessageHistory.removeFirst(chatMessageHistory.count - messagesLimit)
        }
        archiveEncryptedCompanionIfNeeded(for: message, draftRecord: encryptedDraftRecord)

        let participantUpdate = observeParticipant(requester: requester, action: "sentMessage", incrementMessageCount: true)
        publishMessageEvent(message, requester: requester)
        publishParticipantEvent(participantUpdate.record, requester: requester)
        publishStatusEvent(requester: requester)

        return .object([
            "status": .string("sent"),
            "message": .object(messageObject(for: message)),
            "messageCount": .integer(chatMessageHistory.count),
            "participantCount": .integer(participantRecords.count)
        ])
    }

    private func archiveEncryptedCompanionIfNeeded(for message: ChatMessage, draftRecord: PreparedEnvelopeDraftRecord?) {
        guard encryptedPersistenceMode.archivesSentEncryptedCompanions,
              let draftRecord else {
            return
        }

        encryptedMessageRecordsByMessageID[message.id] = PersistedEncryptedMessageRecord(
            messageID: message.id,
            senderIdentityUUID: draftRecord.senderIdentityUUID,
            senderDisplayName: draftRecord.senderDisplayName,
            contentType: draftRecord.contentType,
            topic: message.topic,
            recipients: draftRecord.recipients,
            envelope: draftRecord.envelope,
            source: "sendComposedMessage",
            persistedAt: Self.timestampString(),
            openStatus: "notOpened",
            lastOpenedAt: nil,
            lastOpenRecipientUUID: nil,
            lastSenderVerified: nil,
            lastOpenError: nil
        )
    }

    private func markEncryptedMessageOpenSuccess(messageID: String, recipientUUID: String, senderVerified: Bool) {
        guard var existing = encryptedMessageRecordsByMessageID[messageID] else { return }
        existing.openStatus = "opened"
        existing.lastOpenedAt = Self.timestampString()
        existing.lastOpenRecipientUUID = recipientUUID
        existing.lastSenderVerified = senderVerified
        existing.lastOpenError = nil
        encryptedMessageRecordsByMessageID[messageID] = existing
    }

    private func markEncryptedMessageOpenFailure(messageID: String, recipientUUID: String, error: Error) {
        guard var existing = encryptedMessageRecordsByMessageID[messageID] else { return }
        existing.openStatus = "failed"
        existing.lastOpenedAt = Self.timestampString()
        existing.lastOpenRecipientUUID = recipientUUID
        existing.lastSenderVerified = nil
        existing.lastOpenError = String(describing: error)
        encryptedMessageRecordsByMessageID[messageID] = existing
    }

    private func message(from payload: ValueType, requester: Identity) -> ChatMessage? {
        switch payload {
        case .string(let content):
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return nil }
            return ChatMessage(
                owner: requester,
                content: trimmed,
                contentType: draft(for: requester).contentType,
                topic: topic
            )
        case .object(let object):
            let body = stringValue(object["content"]) ?? stringValue(object["body"]) ?? stringValue(object["text"])
            guard let body else { return nil }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return nil }
            let requestedTopic = stringValue(object["topic"]) ?? topic
            let contentType = normalizedContentType(
                from: stringValue(object["contentType"]) ?? stringValue(object["format"]) ?? draft(for: requester).contentType
            )
            return ChatMessage(
                owner: requester,
                content: trimmed,
                contentType: contentType,
                topic: requestedTopic
            )
        default:
            return nil
        }
    }

    private func stringValue(_ value: ValueType?) -> String? {
        switch value {
        case .string(let string):
            return string
        case .integer(let integer):
            return String(integer)
        case .number(let number):
            return String(number)
        case .float(let float):
            return String(float)
        case .bool(let bool):
            return bool ? "true" : "false"
        default:
            return nil
        }
    }

    private func objectValue(_ value: ValueType?) -> Object? {
        if case let .object(object) = value {
            return object
        }
        return nil
    }

    private func identityValue(_ value: ValueType?) -> Identity? {
        switch value {
        case .identity(let identity):
            return identity
        case .object(let object):
            guard let data = try? JSONEncoder().encode(object),
                  let identity = try? JSONDecoder().decode(Identity.self, from: data) else {
                return nil
            }
            return identity
        default:
            return nil
        }
    }

    private func invitationArtifactValue(from value: ValueType?) -> ChatInvitationArtifact? {
        guard case let .object(object) = value,
              let data = try? JSONEncoder().encode(object) else {
            return nil
        }
        return try? JSONDecoder().decode(ChatInvitationArtifact.self, from: data)
    }

    private func invitationAcceptanceValue(from value: ValueType?) -> ChatInvitationAcceptance? {
        guard case let .object(object) = value,
              let data = try? JSONEncoder().encode(object) else {
            return nil
        }
        return try? JSONDecoder().decode(ChatInvitationAcceptance.self, from: data)
    }

    private func invitationArtifactInspectionState(
        for artifact: ChatInvitationArtifact,
        currentRecord: ChatInvitationRecord? = nil
    ) -> ChatInvitationArtifactInspectionState {
        if let ledgerRecord = invitationArtifactLedgerRecord(for: artifact) {
            return effectiveInvitationArtifactInspectionState(for: ledgerRecord)
        }
        return invitationArtifactInspectionStateFromCurrentRecord(for: artifact, currentRecord: currentRecord)
    }

    private func invitationArtifactInspectionStateFromCurrentRecord(
        for artifact: ChatInvitationArtifact,
        currentRecord: ChatInvitationRecord? = nil
    ) -> ChatInvitationArtifactInspectionState {
        guard let record = currentRecord ?? invitationRecordsByIdentityUUID[artifact.invitedIdentity.uuid] else {
            return .notFound
        }
        guard let currentArtifact = record.artifact else {
            return .notIssued
        }
        guard let currentArtifactHash = try? ChatInvitationProofUtility.invitationHash(for: currentArtifact),
              let artifactHash = try? ChatInvitationProofUtility.invitationHash(for: artifact) else {
            return .notFound
        }

        guard currentArtifact.invitationID == artifact.invitationID,
              currentArtifactHash == artifactHash else {
            return .superseded
        }

        if record.status == .revoked {
            return .revoked
        }
        if record.status == .declined {
            return .declined
        }
        if record.acceptance != nil {
            return .consumed
        }
        if ChatInvitationProofUtility.isExpired(artifact.expiresAt) {
            return .expired
        }
        return .issued
    }

    private func invitationArtifactLedgerRecord(for artifact: ChatInvitationArtifact) -> ChatInvitationArtifactLedgerRecord? {
        guard let artifactHash = try? ChatInvitationProofUtility.invitationHash(for: artifact),
              let ledgerRecord = invitationArtifactLedgerByInvitationID[artifact.invitationID],
              ledgerRecord.artifactHash == artifactHash else {
            return nil
        }
        return ledgerRecord
    }

    private func effectiveInvitationArtifactInspectionState(for ledgerRecord: ChatInvitationArtifactLedgerRecord) -> ChatInvitationArtifactInspectionState {
        if ledgerRecord.state == .issued && ChatInvitationProofUtility.isExpired(ledgerRecord.expiresAt) {
            return .expired
        }
        return ledgerRecord.state
    }

    private func invitationArtifactInspectionObject(for artifact: ChatInvitationArtifact) -> Object {
        let record = invitationRecordsByIdentityUUID[artifact.invitedIdentity.uuid]
        let ledgerRecord = invitationArtifactLedgerRecord(for: artifact)
        let state = ledgerRecord.map(effectiveInvitationArtifactInspectionState(for:)) ?? invitationArtifactInspectionStateFromCurrentRecord(for: artifact, currentRecord: record)
        let currentArtifact = record?.artifact

        return [
            "state": .string(state.rawValue),
            "acceptanceAllowed": .bool(state.acceptanceAllowed),
            "invitationID": .string(artifact.invitationID),
            "chatCellUUID": .string(artifact.chatCellUUID),
            "invitedIdentityUUID": .string(artifact.invitedIdentity.uuid),
            "recordFound": .bool(record != nil),
            "recordStatus": record.map { .string($0.status.rawValue) } ?? ledgerRecord?.recordStatus.map { .string($0.rawValue) } ?? .null,
            "currentInvitationID": currentArtifact.map { .string($0.invitationID) } ?? .null,
            "currentArtifactIssuedAt": currentArtifact.map { .string($0.createdAt) } ?? .null,
            "currentArtifactExpiresAt": currentArtifact.map { .string($0.expiresAt) } ?? .null,
            "consumedAt": record?.acceptance.map { .string($0.createdAt) } ?? ledgerRecord?.consumedAt.map { .string($0) } ?? .null,
            "acceptanceID": record?.acceptance.map { .string($0.acceptanceID) } ?? ledgerRecord?.acceptanceID.map { .string($0) } ?? .null,
            "reason": .string(invitationArtifactInspectionReason(for: state))
        ]
    }

    private func invitationArtifactLedgerObject(_ record: ChatInvitationArtifactLedgerRecord) -> Object {
        let effectiveState = effectiveInvitationArtifactInspectionState(for: record)
        return [
            "invitationID": .string(record.invitationID),
            "invitedIdentityUUID": .string(record.invitedIdentityUUID),
            "artifactHash": .data(record.artifactHash),
            "createdAt": .string(record.createdAt),
            "expiresAt": .string(record.expiresAt),
            "state": .string(effectiveState.rawValue),
            "acceptanceAllowed": .bool(effectiveState.acceptanceAllowed),
            "recordStatus": record.recordStatus.map { .string($0.rawValue) } ?? .null,
            "acceptanceID": record.acceptanceID.map { .string($0) } ?? .null,
            "consumedAt": record.consumedAt.map { .string($0) } ?? .null,
            "supersededByInvitationID": record.supersededByInvitationID.map { .string($0) } ?? .null,
            "supersededAt": record.supersededAt.map { .string($0) } ?? .null,
            "lastUpdatedAt": .string(record.lastUpdatedAt),
            "reason": .string(invitationArtifactInspectionReason(for: effectiveState))
        ]
    }

    private func invitationArtifactInspectionReason(for state: ChatInvitationArtifactInspectionState) -> String {
        switch state {
        case .notFound:
            return "Ingen invitasjonsrecord finnes for artifactets invited identity."
        case .notIssued:
            return "Invitasjonsrecord finnes, men har ikke et aktivt artifact akkurat nå."
        case .issued:
            return "Artifactet er gjeldende og kan aksepteres."
        case .expired:
            return "Artifactet er gjeldende for recorden, men er utløpt."
        case .consumed:
            return "Artifactet er allerede konsumert av en tidligere aksept."
        case .revoked:
            return "Artifactet tilhører en invitasjon som er tilbakekalt."
        case .declined:
            return "Artifactet tilhører en invitasjon som er avslått og må re-utstedes før ny aksept."
        case .superseded:
            return "Artifactet matcher ikke lenger gjeldende utstedte artifact for denne invitasjonsrecorden."
        }
    }

    private func resolveInvitationIdentity(from descriptor: IdentityPublicKeyDescriptor) -> Identity {
        if let resolved = resolveIdentity(explicitUUID: descriptor.uuid) {
            return resolved
        }
        return ChatInvitationProofUtility.identity(
            from: descriptor,
            identityVault: CellBase.defaultIdentityVault
        )
    }

    private func stringListValue(_ value: ValueType?) -> [String]? {
        guard case let .list(values) = value else { return nil }
        let strings = values.compactMap { stringValue($0) }
        return strings.isEmpty ? nil : strings
    }

    private func identities(from payload: ValueType) -> [Identity] {
        guard case let .list(values) = payload else { return [] }
        return values.compactMap { item in
            if let identity = identityValue(item) {
                return identity
            }
            if let uuid = stringValue(item) {
                return resolveIdentity(explicitUUID: uuid)
            }
            return nil
        }
    }

    private func resolveIdentity(
        directValue: ValueType? = nil,
        explicitUUID: String? = nil,
        fallback: Identity? = nil
    ) -> Identity {
        if let identity = identityValue(directValue) {
            return identity
        }
        if let explicitUUID, let resolved = resolveIdentity(explicitUUID: explicitUUID) {
            return resolved
        }
        return fallback ?? owner
    }

    private func resolveIdentity(explicitUUID: String) -> Identity? {
        if explicitUUID == owner.uuid {
            return owner
        }
        if let participant = participantIdentitiesByUUID[explicitUUID] {
            return participant
        }
        if let invitationIdentity = invitationRecordsByIdentityUUID[explicitUUID]?.identity {
            return invitationIdentity
        }
        if let invited = invitedIdentitiesByUUID[explicitUUID] {
            return invited
        }
        return nil
    }

    private func envelopeValue(from payload: ValueType) -> EncryptedContentEnvelope? {
        let object = objectValue(payload) ?? [:]
        let envelopeObject = objectValue(object["envelope"]) ?? object

        guard let headerObject = objectValue(envelopeObject["header"]),
              let header = encryptedEnvelopeHeader(from: headerObject),
              let combinedCiphertextBase64 = stringValue(envelopeObject["combinedCiphertextBase64"]),
              let combinedCiphertext = Data(base64Encoded: combinedCiphertextBase64) else {
            return nil
        }

        let senderSignature: Data?
        if let senderSignatureBase64 = stringValue(envelopeObject["senderSignatureBase64"]) {
            senderSignature = Data(base64Encoded: senderSignatureBase64)
        } else {
            senderSignature = nil
        }

        return EncryptedContentEnvelope(
            header: header,
            combinedCiphertext: combinedCiphertext,
            senderSignature: senderSignature
        )
    }

    private func encryptedEnvelopeHeader(from object: Object) -> EncryptedContentEnvelopeHeader? {
        guard let suiteID = stringValue(object["suiteID"]),
              let contentAlgorithmRaw = stringValue(object["contentAlgorithm"]),
              let contentAlgorithm = ContentEncryptionAlgorithm(rawValue: contentAlgorithmRaw),
              let keyWrappingRaw = stringValue(object["keyWrappingAlgorithm"]),
              let keyWrappingAlgorithm = ContentKeyWrappingAlgorithm(rawValue: keyWrappingRaw),
              let createdAt = stringValue(object["createdAt"]),
              case let .list(recipientValues)? = object["recipientKeys"] else {
            return nil
        }

        let recipientKeys = recipientValues.compactMap { item -> WrappedContentKeyDescriptor? in
            guard let descriptorObject = objectValue(item),
                  let recipientKeyID = stringValue(descriptorObject["recipientKeyID"]),
                  let algorithmRaw = stringValue(descriptorObject["algorithm"]),
                  let algorithm = ContentKeyWrappingAlgorithm(rawValue: algorithmRaw),
                  let wrappedKeyMaterialBase64 = stringValue(descriptorObject["wrappedKeyMaterialBase64"]),
                  let wrappedKeyMaterial = Data(base64Encoded: wrappedKeyMaterialBase64) else {
                return nil
            }

            let recipientCurveType = stringValue(descriptorObject["recipientCurveType"]).flatMap(CurveType.init(rawValue:))
            let recipientAlgorithm = stringValue(descriptorObject["recipientAlgorithm"]).flatMap(CurveAlgorithm.init(rawValue:))
            let ephemeralPublicKey = stringValue(descriptorObject["ephemeralPublicKeyBase64"]).flatMap { Data(base64Encoded: $0) }

            return WrappedContentKeyDescriptor(
                recipientIdentityUUID: stringValue(descriptorObject["recipientIdentityUUID"]),
                recipientKeyID: recipientKeyID,
                algorithm: algorithm,
                wrappedKeyMaterial: wrappedKeyMaterial,
                recipientCurveType: recipientCurveType,
                recipientAlgorithm: recipientAlgorithm,
                ephemeralPublicKey: ephemeralPublicKey
            )
        }

        guard recipientKeys.count == recipientValues.count else {
            return nil
        }

        return EncryptedContentEnvelopeHeader(
            version: integerValue(object["version"]) ?? 1,
            suiteID: suiteID,
            contentAlgorithm: contentAlgorithm,
            keyWrappingAlgorithm: keyWrappingAlgorithm,
            senderKeyID: stringValue(object["senderKeyID"]),
            recipientKeys: recipientKeys,
            createdAt: createdAt,
            keyID: stringValue(object["keyID"]),
            envelopeGeneration: integerValue(object["envelopeGeneration"]),
            associatedDataContext: stringValue(object["associatedDataContext"])
        )
    }

    private func integerValue(_ value: ValueType?) -> Int? {
        switch value {
        case .integer(let integer):
            return integer
        case .number(let number):
            return number
        case .float(let float):
            return Int(float)
        case .string(let string):
            return Int(string)
        default:
            return nil
        }
    }

    private func parsedAssociatedDataContext(_ value: String?) -> (topic: String?, contentType: String?) {
        guard let value, value.hasPrefix("chat:") else {
            return (nil, nil)
        }
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count >= 3 else {
            return (nil, nil)
        }
        let topic = String(components[1])
        let contentType = components.dropFirst(2).joined(separator: ":")
        return (topic.isEmpty ? nil : topic, contentType.isEmpty ? nil : contentType)
    }

    private func normalizedContentType(from rawValue: String?) -> String {
        guard let rawValue else { return Self.defaultContentType }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "", "plain", "plaintext", "text", "text/plain":
            return Self.defaultContentType
        case "markdown", "md", "text/markdown":
            return Self.markdownContentType
        default:
            return normalized.contains("/") ? normalized : Self.defaultContentType
        }
    }

    private func publishMessageEvent(_ message: ChatMessage, requester: Identity) {
        var flowElement = FlowElement(
            id: message.id,
            title: "Chat message",
            content: .object(messageObject(for: message)),
            properties: FlowElement.Properties(type: .event, contentType: .object)
        )
        flowElement.topic = "chat.message"
        flowElement.origin = uuid
        pushFlowElement(flowElement, requester: requester)
    }

    private func publishParticipantEvent(_ participant: ChatParticipantRecord, requester: Identity) {
        var flowElement = FlowElement(
            id: participant.id,
            title: "Chat participant",
            content: .object(participant.objectValue()),
            properties: FlowElement.Properties(type: .event, contentType: .object)
        )
        flowElement.topic = "chat.participant"
        flowElement.origin = uuid
        pushFlowElement(flowElement, requester: requester)
    }

    private func publishStatusEvent(requester: Identity) {
        var flowElement = FlowElement(
            id: UUID().uuidString,
            title: "Chat status",
            content: .object(statusPayloadObject()),
            properties: FlowElement.Properties(type: .event, contentType: .object)
        )
        flowElement.topic = "chat.status"
        flowElement.origin = uuid
        pushFlowElement(flowElement, requester: requester)
    }

    private func startEmitter(requester: Identity) async -> ValueType {
        if running {
            publishStatusEvent(requester: requester)
            return .string("already running")
        }
        running = true
        await resumeEmitterIfNeeded()
        publishStatusEvent(requester: requester)
        return .string("ok")
    }

    private func stopEmitter(requester: Identity) async -> ValueType {
        running = false
        emitterTask?.cancel()
        emitterTask = nil
        publishStatusEvent(requester: requester)
        return .string("ok")
    }

    private func resumeEmitterIfNeeded() async {
        emitterTask?.cancel()
        emitterTask = Task { [weak self] in
            guard let self else { return }
            while self.running, Task.isCancelled == false {
                let seconds = Double.random(in: 2.0 ... 4.0)
                let nanoseconds = UInt64(seconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                if Task.isCancelled || self.running == false {
                    break
                }
                let generated = ChatMessage.generate(owner: self.owner)
                _ = self.storeMessage(generated, requester: self.owner)
            }
        }
    }

    private static func timestampString(_ date: Date = Date()) -> String {
        timestampFormatter.string(from: date)
    }

    private func registerContracts(requester: Identity) async {
        await registerExploreContract(
            requester: requester,
            key: "status",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [Self.statusDetailSchema(), ExploreContract.schema(type: "string")],
                description: "Returns a structured chat status object or a denial/failure string."
            ),
            permissions: ["r---"],
            required: false,
            flowEffects: [Self.flowEffect(topic: "chat.status")],
            description: .string("Returns the current chat summary including message and participant counts.")
        )

        await registerExploreContract(
            requester: requester,
            key: "state",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [Self.chatStateSchema(), ExploreContract.schema(type: "string")],
                description: "Returns the current chat state or a denial/failure string."
            ),
            permissions: ["r---"],
            required: false,
            flowEffects: [Self.flowEffect(topic: "chat.status")],
            description: .string("Returns the full chat state including participants, messages, composer state, and format metadata.")
        )

        for key in ["crypto", "crypto.state"] {
            await registerExploreContract(
                requester: requester,
                key: key,
                method: .get,
                input: .null,
                returns: ExploreContract.oneOfSchema(
                    options: [Self.cryptoStateSchema(), ExploreContract.schema(type: "string")],
                    description: "Returns the declared chat crypto bootstrap state or a denial/failure string."
                ),
                permissions: ["r---"],
                required: false,
                description: .string("Returns declared chat crypto policy and suite metadata. This is bootstrap state only; payload encryption is not active yet.")
            )
        }

        await registerExploreContract(
            requester: requester,
            key: "crypto.policy",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [Self.cryptoPolicySchema(), ExploreContract.schema(type: "string")],
                description: "Returns the preferred and accepted chat crypto policy or a denial/failure string."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Returns the declared crypto policy that future encrypted chat envelopes should follow.")
        )

        await registerExploreContract(
            requester: requester,
            key: "crypto.supportedSuites",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [ExploreContract.listSchema(item: Self.cryptoSuiteSchema()), ExploreContract.schema(type: "string")],
                description: "Returns the list of supported chat crypto suites or a denial/failure string."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Lists the content-crypto suites that this chat cell knows how to negotiate.")
        )

        await registerExploreContract(
            requester: requester,
            key: "crypto.recipients",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [ExploreContract.listSchema(item: Self.recipientDescriptorSchema()), ExploreContract.schema(type: "string")],
                description: "Returns the currently known encryption recipients or a denial/failure string."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Lists the currently known recipient identities and their key-agreement public keys for envelope preparation.")
        )

        await registerExploreContract(
            requester: requester,
            key: "crypto.membership",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [Self.cryptoMembershipSchema(), ExploreContract.schema(type: "string")],
                description: "Returns the current resolved membership fingerprint/version state or a denial/failure string."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Returns the current resolved chat membership snapshot that future encrypted envelopes should target.")
        )

        await registerExploreContract(
            requester: requester,
            key: "crypto.rekeyStatus",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [Self.cryptoRekeyStatusSchema(), ExploreContract.schema(type: "string")],
                description: "Returns whether resolved membership has drifted from the latest acknowledged rekey checkpoint."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Returns the current rekey advisory state, including the latest acknowledged checkpoint and whether membership has changed since then.")
        )

        await registerExploreContract(
            requester: requester,
            key: "crypto.persistencePolicy",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [Self.cryptoPersistencePolicySchema(), ExploreContract.schema(type: "string")],
                description: "Returns the encrypted draft/message persistence policy or a denial/failure string."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Describes whether encrypted envelopes are kept only as draft cache or also archived as encrypted companions for sent composed messages.")
        )

        await registerExploreContract(
            requester: requester,
            key: "crypto.persistenceMode",
            method: .get,
            input: .null,
            returns: ExploreContract.schema(type: "string", description: "Current encrypted persistence mode."),
            permissions: ["r---"],
            required: false,
            description: .string("Returns the current encrypted persistence mode.")
        )

        await registerExploreContract(
            requester: requester,
            key: "crypto.persistenceMode",
            method: .set,
            input: ExploreContract.schema(type: "string", description: "One of `draftCacheOnly` or `draftAndSentArchive`."),
            returns: ExploreContract.oneOfSchema(
                options: [Self.cryptoPersistencePolicySchema(), ExploreContract.schema(type: "string")],
                description: "Returns the updated encrypted persistence policy or a denial/failure string."
            ),
            permissions: ["-w--"],
            required: false,
            description: .string("Changes whether encrypted envelopes are kept only as requester draft cache or also archived for sent composed messages.")
        )

        await registerExploreContract(
            requester: requester,
            key: "crypto.encryptedMessages",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [ExploreContract.listSchema(item: Self.persistedEncryptedMessageSchema()), ExploreContract.schema(type: "string")],
                description: "Returns locally persisted encrypted companion envelopes or a denial/failure string."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Returns the encrypted companion-envelope archive that belongs to sent composed messages when the persistence policy allows it.")
        )

        await registerExploreContract(
            requester: requester,
            key: "crypto.draftEnvelope",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [Self.preparedEnvelopeSchema(), .null, ExploreContract.schema(type: "string")],
                description: "Returns the requester-scoped prepared envelope draft cache, null, or a denial/failure string."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Returns the last prepared encrypted draft envelope for the requester, if one has been cached.")
        )

        await registerExploreContract(
            requester: requester,
            key: "crypto.prepareDraftEnvelope",
            method: .set,
            input: ExploreContract.oneOfSchema(
                options: [
                    .null,
                    ExploreContract.schema(type: "string", description: "Optional plaintext override."),
                    ExploreContract.objectSchema(
                        properties: [
                            "content": ExploreContract.schema(type: "string"),
                            "body": ExploreContract.schema(type: "string"),
                            "text": ExploreContract.schema(type: "string"),
                            "contentType": ExploreContract.schema(type: "string"),
                            "format": ExploreContract.schema(type: "string"),
                            "recipientIDs": ExploreContract.listSchema(item: ExploreContract.schema(type: "string"))
                        ],
                        description: "Optional envelope preparation overrides."
                    )
                ],
                description: "Uses the current composer draft by default and can optionally override body, content type, or recipient selection."
            ),
            returns: ExploreContract.oneOfSchema(
                options: [Self.preparedEnvelopeSchema(), ExploreContract.schema(type: "string")],
                description: "Returns a prepared encrypted content envelope preview or a denial/failure string."
            ),
            permissions: ["-w--"],
            required: false,
            description: .string("Prepares a signed encrypted envelope preview for the current draft and known recipients without changing normal send behavior.")
        )

        await registerExploreContract(
            requester: requester,
            key: "crypto.requestRekey",
            method: .set,
            input: ExploreContract.oneOfSchema(
                options: [
                    .null,
                    ExploreContract.schema(type: "string", description: "Optional human-readable reason."),
                    ExploreContract.objectSchema(
                        properties: [
                            "reason": ExploreContract.schema(type: "string"),
                            "source": ExploreContract.schema(type: "string")
                        ],
                        description: "Optional reason/source metadata for acknowledging the current membership as the new rekey checkpoint."
                    )
                ],
                description: "Optional metadata describing why the current membership is being acknowledged as the next rekey checkpoint."
            ),
            returns: ExploreContract.oneOfSchema(
                options: [
                    ExploreContract.objectSchema(
                        properties: [
                            "status": ExploreContract.schema(type: "string"),
                            "membershipVersion": ExploreContract.schema(type: "integer"),
                            "envelopeGeneration": ExploreContract.schema(type: "integer"),
                            "rekeyStatus": Self.cryptoRekeyStatusSchema(),
                            "membership": Self.cryptoMembershipSchema()
                        ],
                        requiredKeys: ["status", "membershipVersion", "envelopeGeneration", "rekeyStatus", "membership"],
                        description: "Acknowledged rekey checkpoint response."
                    ),
                    ExploreContract.schema(type: "string")
                ],
                description: "Returns the updated rekey checkpoint state or a denial/failure string."
            ),
            permissions: ["-w--"],
            required: false,
            description: .string("Acknowledges the current resolved membership as the next crypto rekey checkpoint without changing the admission or signing model.")
        )

        await registerExploreContract(
            requester: requester,
            key: "crypto.openEnvelope",
            method: .set,
            input: ExploreContract.objectSchema(
                properties: [
                    "messageID": ExploreContract.schema(type: "string"),
                    "senderIdentityUUID": ExploreContract.schema(type: "string"),
                    "recipientIdentityUUID": ExploreContract.schema(type: "string"),
                    "header": Self.encryptedEnvelopeHeaderSchema(),
                    "combinedCiphertextBase64": ExploreContract.schema(type: "string"),
                    "senderSignatureBase64": ExploreContract.schema(type: "string")
                ],
                requiredKeys: ["header", "combinedCiphertextBase64"],
                description: "Encrypted envelope payload to open for the current or specified recipient."
            ),
            returns: ExploreContract.oneOfSchema(
                options: [Self.openedEnvelopeSchema(), ExploreContract.schema(type: "string")],
                description: "Returns opened plaintext metadata or a denial/failure string."
            ),
            permissions: ["-w--"],
            required: false,
            description: .string("Opens and verifies a prepared encrypted envelope for the requester or another explicitly selected recipient identity.")
        )

        await registerExploreContract(
            requester: requester,
            key: "crypto.clearDraftEnvelope",
            method: .set,
            input: ExploreContract.oneOfSchema(
                options: [.null, ExploreContract.schema(type: "bool"), ExploreContract.schema(type: "object")],
                description: "Payload is ignored; any value clears the requester-scoped draft envelope cache."
            ),
            returns: .null,
            permissions: ["-w--"],
            required: false,
            description: .string("Clears the requester-scoped encrypted draft-envelope cache.")
        )

        await registerExploreContract(
            requester: requester,
            key: "crypto.clearEncryptedMessages",
            method: .set,
            input: ExploreContract.oneOfSchema(
                options: [.null, ExploreContract.schema(type: "bool"), ExploreContract.schema(type: "object")],
                description: "Payload is ignored; any value clears the encrypted companion-message archive."
            ),
            returns: .null,
            permissions: ["-w--"],
            required: false,
            description: .string("Clears the locally persisted encrypted companion-envelope archive.")
        )

        await registerExploreContract(
            requester: requester,
            key: "audience",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [Self.audienceStateSchema(), ExploreContract.schema(type: "string")],
                description: "Returns the chat audience strategy or a denial/failure string."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Describes how the chat resolves recipients: from context, explicit invites, or both.")
        )

        await registerExploreContract(
            requester: requester,
            key: "audience.mode",
            method: .get,
            input: .null,
            returns: ExploreContract.schema(type: "string", description: "Current audience mode."),
            permissions: ["r---"],
            required: false,
            description: .string("Returns the current chat audience mode.")
        )

        await registerExploreContract(
            requester: requester,
            key: "audience.mode",
            method: .set,
            input: ExploreContract.schema(type: "string", description: "One of `contextMembers`, `invitedIdentities`, or `hybrid`."),
            returns: ExploreContract.oneOfSchema(
                options: [Self.audienceStateSchema(), ExploreContract.schema(type: "string")],
                description: "Returns the updated audience state or a denial/failure string."
            ),
            permissions: ["-w--"],
            required: false,
            description: .string("Changes whether the chat inherits recipients from context, explicit invites, or both.")
        )

        for key in ["audience.inheritedRecipients", "audience.invitedRecipients", "audience.resolvedRecipients"] {
            await registerExploreContract(
                requester: requester,
                key: key,
                method: .get,
                input: .null,
                returns: ExploreContract.oneOfSchema(
                    options: [ExploreContract.listSchema(item: Self.audienceRecipientSchema()), ExploreContract.schema(type: "string")],
                    description: "Returns the requested audience recipient list or a denial/failure string."
                ),
                permissions: ["r---"],
                required: false,
                description: .string("Returns display-ready audience recipients for the selected audience source.")
            )
        }

        await registerExploreContract(
            requester: requester,
            key: "audience.invitations",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [ExploreContract.listSchema(item: Self.invitationSchema()), ExploreContract.schema(type: "string")],
                description: "Returns invitation lifecycle records or a denial/failure string."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Returns explicit invitation records with lifecycle status such as pending, accepted, declined, or revoked.")
        )

        await registerExploreContract(
            requester: requester,
            key: "audience.invitationLedger",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [ExploreContract.listSchema(item: Self.invitationArtifactLedgerSchema()), ExploreContract.schema(type: "string")],
                description: "Returns the durable invitation artifact inspection ledger or a denial/failure string."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Returns persisted issue/consumption records for invitation artifacts so clients can inspect superseded, revoked, declined, expired, and consumed artifacts across restarts.")
        )

        await registerExploreContract(
            requester: requester,
            key: "audience.invitationArtifacts",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [ExploreContract.listSchema(item: Self.invitationArtifactSchema()), ExploreContract.schema(type: "string")],
                description: "Returns signed invitation artifacts or a denial/failure string."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Returns signed chat invitation artifacts that can be transferred to invitees for proof-based acceptance.")
        )

        await registerExploreContract(
            requester: requester,
            key: "audience.inspectInvitationArtifact",
            method: .set,
            input: Self.invitationArtifactSchema(),
            returns: ExploreContract.oneOfSchema(
                options: [Self.invitationArtifactInspectionSchema(), ExploreContract.schema(type: "string")],
                description: "Returns the current lifecycle/inspection state for a provided invitation artifact or a denial/failure string."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Inspects whether a provided invitation artifact is still current, expired, consumed, revoked, declined, superseded, or unknown to this chat cell.")
        )

        await registerExploreContract(
            requester: requester,
            key: "audience.inviteIdentities",
            method: .set,
            input: ExploreContract.listSchema(
                item: ExploreContract.oneOfSchema(
                    options: [
                        ExploreContract.schema(type: "string", description: "Known identity UUID."),
                        ExploreContract.schema(type: "object", description: "Identity snapshot with public keys.")
                    ],
                    description: "Invitee reference."
                ),
                description: "List of identities or known UUIDs to invite."
            ),
            returns: ExploreContract.oneOfSchema(
                options: [Self.audienceStateSchema(), ExploreContract.schema(type: "string")],
                description: "Returns the updated audience state or a denial/failure string."
            ),
            permissions: ["-w--"],
            required: false,
            description: .string("Creates pending invitation records for explicit identities. Accepted invitations become resolved recipients when the audience mode allows it.")
        )

        await registerExploreContract(
            requester: requester,
            key: "audience.generateInvitationArtifacts",
            method: .set,
            input: ExploreContract.oneOfSchema(
                options: [
                    .null,
                    ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                    ExploreContract.listSchema(item: ExploreContract.schema(type: "object"))
                ],
                description: "Optional list of identity UUIDs or identity objects. Empty input generates artifacts for all non-revoked invitation records."
            ),
            returns: ExploreContract.oneOfSchema(
                options: [ExploreContract.listSchema(item: Self.invitationArtifactSchema()), ExploreContract.schema(type: "string")],
                description: "Returns generated signed invitation artifacts or a denial/failure string."
            ),
            permissions: ["-w--"],
            required: false,
            description: .string("Generates signed invitation artifacts for pending or existing invitation records without auto-accepting anyone.")
        )

        await registerExploreContract(
            requester: requester,
            key: "audience.generateInvitationAcceptance",
            method: .set,
            input: Self.invitationArtifactSchema(),
            returns: ExploreContract.oneOfSchema(
                options: [Self.invitationAcceptanceSchema(), ExploreContract.schema(type: "string")],
                description: "Returns a signed invitation acceptance proof or a denial/failure string."
            ),
            permissions: ["-w--"],
            required: false,
            description: .string("Lets the invited identity sign acceptance for a chat invitation artifact. This is intended for same-app or local proof generation before transport.")
        )

        await registerExploreContract(
            requester: requester,
            key: "audience.acceptInvitationArtifact",
            method: .set,
            input: ExploreContract.objectSchema(
                properties: [
                    "artifact": Self.invitationArtifactSchema(),
                    "acceptance": Self.invitationAcceptanceSchema()
                ],
                requiredKeys: ["artifact", "acceptance"],
                description: "A signed invitation artifact paired with a signed acceptance proof from the invited identity."
            ),
            returns: ExploreContract.oneOfSchema(
                options: [
                    ExploreContract.objectSchema(
                        properties: [
                            "status": ExploreContract.schema(type: "string"),
                            "idempotent": ExploreContract.schema(type: "bool"),
                            "invitationID": ExploreContract.schema(type: "string"),
                            "acceptanceID": ExploreContract.schema(type: "string"),
                            "audience": Self.audienceStateSchema(),
                            "invitation": Self.invitationSchema()
                        ],
                        requiredKeys: ["status", "idempotent", "invitationID", "acceptanceID", "audience", "invitation"],
                        description: "Successful proof-based invitation acceptance response."
                    ),
                    ExploreContract.schema(type: "string")
                ],
                description: "Returns the updated invitation state or a denial/failure string."
            ),
            permissions: ["-w--"],
            required: false,
            description: .string("Verifies inviter and invitee signatures for an invitation artifact + acceptance pair, then marks the invitation accepted.")
        )

        for (key, statusDescription) in [
            ("audience.acceptInvites", "Marks invitation records as accepted and resolves them as explicit recipients."),
            ("audience.declineInvites", "Marks invitation records as declined so they are excluded from resolved recipients."),
            ("audience.revokeInvites", "Marks invitation records as revoked and removes them from resolved recipients.")
        ] {
            await registerExploreContract(
                requester: requester,
                key: key,
                method: .set,
                input: ExploreContract.oneOfSchema(
                    options: [
                        .null,
                        ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                        ExploreContract.listSchema(item: ExploreContract.schema(type: "object"))
                    ],
                    description: "Optional list of identity UUIDs or identity objects. Empty input applies to all invitation records."
                ),
                returns: ExploreContract.oneOfSchema(
                    options: [Self.audienceStateSchema(), ExploreContract.schema(type: "string")],
                    description: "Returns the updated audience state or a denial/failure string."
                ),
                permissions: ["-w--"],
                required: false,
                description: .string(statusDescription)
            )
        }

        await registerExploreContract(
            requester: requester,
            key: "audience.removeContextMembers",
            method: .set,
            input: ExploreContract.oneOfSchema(
                options: [
                    .null,
                    ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                    ExploreContract.listSchema(item: ExploreContract.schema(type: "object"))
                ],
                description: "Optional list of identity UUIDs or identity objects. Empty input removes every non-owner context member."
            ),
            returns: ExploreContract.oneOfSchema(
                options: [Self.audienceStateSchema(), ExploreContract.schema(type: "string")],
                description: "Returns the updated audience state or a denial/failure string."
            ),
            permissions: ["-w--"],
            required: false,
            description: .string("Removes non-owner context members from the inherited audience set without changing explicit invitation records.")
        )

        await registerExploreContract(
            requester: requester,
            key: "audience.clearInvites",
            method: .set,
            input: ExploreContract.oneOfSchema(
                options: [.null, ExploreContract.schema(type: "bool"), ExploreContract.schema(type: "object")],
                description: "Payload is ignored; any value clears explicit invitees."
            ),
            returns: ExploreContract.oneOfSchema(
                options: [Self.audienceStateSchema(), ExploreContract.schema(type: "string")],
                description: "Returns the updated audience state or a denial/failure string."
            ),
            permissions: ["-w--"],
            required: false,
            description: .string("Clears explicit invitees while leaving the audience mode unchanged.")
        )

        for key in ["messages", "participants", "members"] {
            await registerExploreContract(
                requester: requester,
                key: key,
                method: .get,
                input: .null,
                returns: ExploreContract.oneOfSchema(
                    options: [
                        key == "messages"
                            ? ExploreContract.listSchema(item: Self.messageSchema())
                            : ExploreContract.listSchema(item: Self.participantSchema()),
                        ExploreContract.schema(type: "string")
                    ],
                    description: "Returns the requested chat collection or a denial/failure string."
                ),
                permissions: ["r---"],
                required: false,
                description: .string(
                    key == "messages"
                        ? "Lists persisted chat messages in display-ready form."
                        : "Lists chat participants in display-ready form."
                )
            )
        }

        await registerExploreContract(
            requester: requester,
            key: "compose.body",
            method: .get,
            input: .null,
            returns: ExploreContract.schema(type: "string", description: "Current draft body for the requester."),
            permissions: ["r---"],
            required: false,
            description: .string("Returns the current composer body for the requester-scoped draft.")
        )

        await registerExploreContract(
            requester: requester,
            key: "compose.body",
            method: .set,
            input: ExploreContract.schema(type: "string", description: "Draft body text."),
            returns: ExploreContract.schema(type: "string", description: "Stored draft body."),
            permissions: ["-w--"],
            required: true,
            description: .string("Updates the requester-scoped draft body.")
        )

        await registerExploreContract(
            requester: requester,
            key: "compose.contentType",
            method: .get,
            input: .null,
            returns: ExploreContract.schema(type: "string", description: "Current draft content type."),
            permissions: ["r---"],
            required: false,
            description: .string("Returns the current composer content type for the requester-scoped draft.")
        )

        await registerExploreContract(
            requester: requester,
            key: "compose.contentType",
            method: .set,
            input: ExploreContract.schema(type: "string", description: "Requested format alias or MIME type."),
            returns: ExploreContract.schema(type: "string", description: "Normalized content type."),
            permissions: ["-w--"],
            required: true,
            description: .string("Normalizes and stores the draft content type for the requester.")
        )

        await registerExploreContract(
            requester: requester,
            key: "compose.availableFormats",
            method: .get,
            input: .null,
            returns: ExploreContract.listSchema(item: Self.formatSchema(), description: "Available composer formats."),
            permissions: ["r---"],
            required: false,
            description: .string("Lists the available composer formats and their labels.")
        )

        await registerExploreContract(
            requester: requester,
            key: "compose.state",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [Self.composerStateSchema(), ExploreContract.schema(type: "string")],
                description: "Returns the current composer state or a denial/failure string."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Returns detailed composer metadata including preview text, counts, and send hints.")
        )

        await registerExploreContract(
            requester: requester,
            key: "compose.previewRows",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [ExploreContract.listSchema(item: Self.composerStateSchema()), ExploreContract.schema(type: "string")],
                description: "Returns a single-row preview list or a denial/failure string."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Returns composer preview rows suitable for skeleton/list rendering.")
        )

        for key in ["start", "stop"] {
            await registerExploreContract(
                requester: requester,
                key: key,
                method: .get,
                input: .null,
                returns: ExploreContract.schema(type: "string", description: "Operation status such as `ok` or `already running`."),
                permissions: ["-w--"],
                required: false,
                flowEffects: [Self.flowEffect(topic: "chat.status")],
                description: .string(key == "start" ? "Starts background chat event generation." : "Stops background chat event generation.")
            )
        }

        let sendResponse = ExploreContract.oneOfSchema(
            options: [Self.sendResponseSchema(), ExploreContract.schema(type: "string")],
            description: "Returns a sent message envelope or a string error/denial."
        )

        await registerExploreContract(
            requester: requester,
            key: "sendMessage",
            method: .set,
            input: Self.sendMessageInputSchema(),
            returns: sendResponse,
            permissions: ["-w--"],
            required: true,
            flowEffects: Self.messageFlowEffects(),
            description: .string("Creates and publishes a chat message from a string or object payload.")
        )

        await registerExploreContract(
            requester: requester,
            key: "addMessage",
            method: .set,
            input: Self.sendMessageInputSchema(),
            returns: sendResponse,
            permissions: ["-w--"],
            required: true,
            flowEffects: Self.messageFlowEffects(),
            description: .string("Alias for `sendMessage` that stores and publishes a chat message.")
        )

        await registerExploreContract(
            requester: requester,
            key: "sendComposedMessage",
            method: .set,
            input: ExploreContract.oneOfSchema(
                options: [.null, ExploreContract.schema(type: "bool"), ExploreContract.schema(type: "object")],
                description: "Payload is ignored; any value can trigger the composed send."
            ),
            returns: sendResponse,
            permissions: ["-w--"],
            required: false,
            flowEffects: Self.messageFlowEffects(),
            description: .string("Sends the requester-scoped draft message and clears the body on success.")
        )

        await registerExploreContract(
            requester: requester,
            key: "clearComposer",
            method: .set,
            input: ExploreContract.oneOfSchema(
                options: [.null, ExploreContract.schema(type: "bool"), ExploreContract.schema(type: "object")],
                description: "Payload is ignored; any value clears the composer."
            ),
            returns: ExploreContract.oneOfSchema(
                options: [Self.draftSchema(), ExploreContract.schema(type: "string")],
                description: "Returns the cleared draft or a denial/failure string."
            ),
            permissions: ["-w--"],
            required: false,
            description: .string("Clears the requester-scoped draft body while preserving the chosen content type.")
        )
    }

    private static func flowEffect(topic: String) -> ValueType {
        ExploreContract.flowEffect(trigger: .set, topic: topic, contentType: "object")
    }

    private static func messageFlowEffects() -> [ValueType] {
        [
            flowEffect(topic: "chat.message"),
            flowEffect(topic: "chat.participant"),
            flowEffect(topic: "chat.status")
        ]
    }

    private static func messageSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "id": ExploreContract.schema(type: "string"),
                "topic": ExploreContract.schema(type: "string"),
                "createdAt": ExploreContract.schema(type: "string"),
                "ownerUUID": ExploreContract.schema(type: "string"),
                "ownerDisplayName": ExploreContract.schema(type: "string"),
                "ownerInitials": ExploreContract.schema(type: "string"),
                "content": ExploreContract.schema(type: "string"),
                "contentType": ExploreContract.schema(type: "string"),
                "preview": ExploreContract.schema(type: "string"),
                "formatLabel": ExploreContract.schema(type: "string"),
                "isMarkdown": ExploreContract.schema(type: "bool"),
                "cryptoState": ExploreContract.schema(type: "string"),
                "encryptedCompanionAvailable": ExploreContract.schema(type: "bool"),
                "crypto": messageCryptoSchema()
            ],
            requiredKeys: ["id", "content", "contentType", "ownerUUID", "createdAt"],
            description: "Display-ready chat message payload."
        )
    }

    private static func messageCryptoSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "state": ExploreContract.schema(type: "string"),
                "openStatus": ExploreContract.schema(type: "string"),
                "recipientCount": ExploreContract.schema(type: "integer"),
                "source": ExploreContract.schema(type: "string"),
                "persistedAt": ExploreContract.schema(type: "string"),
                "lastOpenedAt": ExploreContract.schema(type: "string"),
                "lastOpenRecipientUUID": ExploreContract.schema(type: "string"),
                "senderVerified": ExploreContract.schema(type: "bool"),
                "lastOpenError": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["state", "openStatus", "recipientCount"],
            description: "Per-message crypto rendering metadata."
        )
    }

    private static func participantSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "id": ExploreContract.schema(type: "string"),
                "displayName": ExploreContract.schema(type: "string"),
                "joinedAt": ExploreContract.schema(type: "string"),
                "lastSeenAt": ExploreContract.schema(type: "string"),
                "messageCount": ExploreContract.schema(type: "integer"),
                "lastAction": ExploreContract.schema(type: "string"),
                "presence": ExploreContract.schema(type: "string"),
                "initials": ExploreContract.schema(type: "string"),
                "presenceLabel": ExploreContract.schema(type: "string"),
                "messageCountLabel": ExploreContract.schema(type: "string"),
                "activitySummary": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["id", "displayName", "messageCount", "presence"],
            description: "Display-ready participant presence record."
        )
    }

    private static func formatSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "id": ExploreContract.schema(type: "string"),
                "label": ExploreContract.schema(type: "string"),
                "contentType": ExploreContract.schema(type: "string"),
                "description": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["id", "label", "contentType"],
            description: "Supported composer format option."
        )
    }

    private static func draftSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "body": ExploreContract.schema(type: "string"),
                "contentType": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["body", "contentType"],
            description: "Requester-scoped chat draft payload."
        )
    }

    private static func composerStateSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "id": ExploreContract.schema(type: "string"),
                "body": ExploreContract.schema(type: "string"),
                "contentType": ExploreContract.schema(type: "string"),
                "formatLabel": ExploreContract.schema(type: "string"),
                "formatDescription": ExploreContract.schema(type: "string"),
                "helperText": ExploreContract.schema(type: "string"),
                "placeholder": ExploreContract.schema(type: "string"),
                "previewRichText": ExploreContract.schema(type: "string"),
                "previewSummary": ExploreContract.schema(type: "string"),
                "characterCount": ExploreContract.schema(type: "integer"),
                "characterCountLabel": ExploreContract.schema(type: "string"),
                "lineCount": ExploreContract.schema(type: "integer"),
                "lineCountLabel": ExploreContract.schema(type: "string"),
                "isEmpty": ExploreContract.schema(type: "bool"),
                "isMarkdown": ExploreContract.schema(type: "bool"),
                "sendHint": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["id", "body", "contentType", "characterCount", "lineCount", "isEmpty"],
            description: "Detailed requester-scoped composer state."
        )
    }

    private static func statusDetailSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "summary": ExploreContract.schema(type: "string"),
                "topic": ExploreContract.schema(type: "string"),
                "messageCount": ExploreContract.schema(type: "integer"),
                "participantCount": ExploreContract.schema(type: "integer"),
                "messagesLimit": ExploreContract.schema(type: "integer"),
                "running": ExploreContract.schema(type: "bool"),
                "latestMessageAt": ExploreContract.schema(type: "string"),
                "latestMessagePreview": ExploreContract.schema(type: "string"),
                "latestMessageContentType": ExploreContract.schema(type: "string"),
                "latestMessageDisplayAt": ExploreContract.schema(type: "string"),
                "latestMessageRelativeAt": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["summary", "topic", "messageCount", "participantCount", "running"],
            description: "High-level chat status summary."
        )
    }

    private static func cryptoSuiteSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "id": ExploreContract.schema(type: "string"),
                "version": ExploreContract.schema(type: "integer"),
                "purpose": ExploreContract.schema(type: "string"),
                "contentAlgorithm": ExploreContract.schema(type: "string"),
                "keyAgreementAlgorithm": ExploreContract.schema(type: "string"),
                "keyWrappingAlgorithm": ExploreContract.schema(type: "string"),
                "signatureAlgorithm": ExploreContract.schema(type: "string"),
                "curveType": ExploreContract.schema(type: "string"),
                "requiresSenderSignature": ExploreContract.schema(type: "bool"),
                "supportsForwardSecrecy": ExploreContract.schema(type: "bool")
            ],
            requiredKeys: ["id", "version", "purpose", "contentAlgorithm", "keyWrappingAlgorithm", "requiresSenderSignature", "supportsForwardSecrecy"],
            description: "Versioned content-crypto suite description for chat payloads."
        )
    }

    private static func cryptoPolicySchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "version": ExploreContract.schema(type: "integer"),
                "preferredSuiteID": ExploreContract.schema(type: "string"),
                "acceptedSuiteIDs": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "allowLegacyFallback": ExploreContract.schema(type: "bool"),
                "minimumRecipientCountForWrappedKeys": ExploreContract.schema(type: "integer")
            ],
            requiredKeys: ["version", "preferredSuiteID", "acceptedSuiteIDs", "allowLegacyFallback", "minimumRecipientCountForWrappedKeys"],
            description: "Declared chat crypto policy."
        )
    }

    private static func cryptoPersistencePolicySchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "mode": ExploreContract.schema(type: "string"),
                "modeLabel": ExploreContract.schema(type: "string"),
                "summary": ExploreContract.schema(type: "string"),
                "archivesSentEncryptedCompanions": ExploreContract.schema(type: "bool"),
                "draftEnvelopeCacheCount": ExploreContract.schema(type: "integer"),
                "encryptedMessageArchiveCount": ExploreContract.schema(type: "integer")
            ],
            requiredKeys: ["mode", "modeLabel", "summary", "archivesSentEncryptedCompanions", "draftEnvelopeCacheCount", "encryptedMessageArchiveCount"],
            description: "Policy describing how encrypted draft and sent-message envelopes are persisted."
        )
    }

    private static func cryptoMembershipSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "membershipVersion": ExploreContract.schema(type: "integer"),
                "fingerprint": ExploreContract.schema(type: "string"),
                "envelopeGeneration": ExploreContract.schema(type: "integer"),
                "recipientIdentityUUIDs": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "recipientCount": ExploreContract.schema(type: "integer"),
                "audienceMode": ExploreContract.schema(type: "string"),
                "audienceModeLabel": ExploreContract.schema(type: "string"),
                "suiteID": ExploreContract.schema(type: "string"),
                "persistenceMode": ExploreContract.schema(type: "string"),
                "lastMembershipChangeAt": ExploreContract.schema(type: "string"),
                "lastMembershipChangeReason": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["membershipVersion", "fingerprint", "envelopeGeneration", "recipientIdentityUUIDs", "recipientCount", "audienceMode", "suiteID", "persistenceMode"],
            description: "Current resolved membership snapshot that envelope preparation should target."
        )
    }

    private static func rekeyCheckpointSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "membershipVersion": ExploreContract.schema(type: "integer"),
                "fingerprint": ExploreContract.schema(type: "string"),
                "recipientIdentityUUIDs": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "recipientCount": ExploreContract.schema(type: "integer"),
                "audienceMode": ExploreContract.schema(type: "string"),
                "suiteID": ExploreContract.schema(type: "string"),
                "persistenceMode": ExploreContract.schema(type: "string"),
                "envelopeGeneration": ExploreContract.schema(type: "integer"),
                "updatedAt": ExploreContract.schema(type: "string"),
                "reason": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["membershipVersion", "fingerprint", "recipientIdentityUUIDs", "recipientCount", "audienceMode", "suiteID", "persistenceMode", "envelopeGeneration", "updatedAt", "reason"],
            description: "Last acknowledged rekey checkpoint for chat membership."
        )
    }

    private static func cryptoRekeyStatusSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "rekeyRequired": ExploreContract.schema(type: "bool"),
                "summary": ExploreContract.schema(type: "string"),
                "membershipVersion": ExploreContract.schema(type: "integer"),
                "currentEnvelopeGeneration": ExploreContract.schema(type: "integer"),
                "currentFingerprint": ExploreContract.schema(type: "string"),
                "lastRekeyFingerprint": ExploreContract.schema(type: "string"),
                "lastRekeyAt": ExploreContract.schema(type: "string"),
                "lastRekeyReason": ExploreContract.schema(type: "string"),
                "lastRekeyMembershipVersion": ExploreContract.schema(type: "integer"),
                "lastRekeyEnvelopeGeneration": ExploreContract.schema(type: "integer"),
                "currentMembership": cryptoMembershipSchema(),
                "lastRekeyCheckpoint": rekeyCheckpointSchema()
            ],
            requiredKeys: ["rekeyRequired", "summary", "membershipVersion", "currentEnvelopeGeneration", "currentFingerprint", "currentMembership"],
            description: "Advisory status indicating whether membership changed since the latest acknowledged rekey checkpoint."
        )
    }

    private static func cryptoStateSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "summary": ExploreContract.schema(type: "string"),
                "encryptionEnabled": ExploreContract.schema(type: "bool"),
                "bootstrapOnly": ExploreContract.schema(type: "bool"),
                "envelopePreparationAvailable": ExploreContract.schema(type: "bool"),
                "envelopeOpenAvailable": ExploreContract.schema(type: "bool"),
                "draftEnvelopeCacheCount": ExploreContract.schema(type: "integer"),
                "encryptedMessageArchiveCount": ExploreContract.schema(type: "integer"),
                "rekeyRequired": ExploreContract.schema(type: "bool"),
                "rekeySummary": ExploreContract.schema(type: "string"),
                "membershipVersion": ExploreContract.schema(type: "integer"),
                "currentEnvelopeGeneration": ExploreContract.schema(type: "integer"),
                "lastMembershipChangeAt": ExploreContract.schema(type: "string"),
                "lastMembershipChangeReason": ExploreContract.schema(type: "string"),
                "lastRekeyAt": ExploreContract.schema(type: "string"),
                "preferredSuiteID": ExploreContract.schema(type: "string"),
                "preferredSuite": cryptoSuiteSchema(),
                "policy": cryptoPolicySchema(),
                "persistencePolicy": cryptoPersistencePolicySchema(),
                "membership": cryptoMembershipSchema(),
                "rekeyStatus": cryptoRekeyStatusSchema(),
                "supportedSuites": ExploreContract.listSchema(item: cryptoSuiteSchema()),
                "recipientCount": ExploreContract.schema(type: "integer"),
                "audienceMode": ExploreContract.schema(type: "string"),
                "audienceModeLabel": ExploreContract.schema(type: "string"),
                "supportsForwardSecrecy": ExploreContract.schema(type: "bool"),
                "requiresSenderSignature": ExploreContract.schema(type: "bool")
            ],
            requiredKeys: ["status", "summary", "encryptionEnabled", "bootstrapOnly", "preferredSuiteID", "policy", "supportedSuites"],
            description: "Current chat content-crypto bootstrap state."
        )
    }

    private static func audienceRecipientSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "identityUUID": ExploreContract.schema(type: "string"),
                "displayName": ExploreContract.schema(type: "string"),
                "source": ExploreContract.schema(type: "string"),
                "isOwner": ExploreContract.schema(type: "bool"),
                "hasKeyAgreementKey": ExploreContract.schema(type: "bool"),
                "hasSigningKey": ExploreContract.schema(type: "bool")
            ],
            requiredKeys: ["identityUUID", "displayName", "source", "isOwner", "hasKeyAgreementKey", "hasSigningKey"],
            description: "Resolved audience recipient and how it entered the chat audience."
        )
    }

    private static func invitationSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "identityUUID": ExploreContract.schema(type: "string"),
                "displayName": ExploreContract.schema(type: "string"),
                "status": ExploreContract.schema(type: "string"),
                "statusLabel": ExploreContract.schema(type: "string"),
                "source": ExploreContract.schema(type: "string"),
                "createdAt": ExploreContract.schema(type: "string"),
                "updatedAt": ExploreContract.schema(type: "string"),
                "isResolvedRecipient": ExploreContract.schema(type: "bool"),
                "hasKeyAgreementKey": ExploreContract.schema(type: "bool"),
                "hasSigningKey": ExploreContract.schema(type: "bool"),
                "artifactAvailable": ExploreContract.schema(type: "bool"),
                "artifactInvitationID": ExploreContract.schema(type: "string"),
                "artifactIssuedAt": ExploreContract.schema(type: "string"),
                "artifactExpiresAt": ExploreContract.schema(type: "string"),
                "artifactState": ExploreContract.schema(type: "string"),
                "artifactAcceptanceAllowed": ExploreContract.schema(type: "bool"),
                "artifactConsumedAt": ExploreContract.schema(type: "string"),
                "proofBackedAcceptance": ExploreContract.schema(type: "bool"),
                "acceptanceAvailable": ExploreContract.schema(type: "bool"),
                "acceptanceID": ExploreContract.schema(type: "string"),
                "acceptanceCreatedAt": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["identityUUID", "displayName", "status", "source", "createdAt", "updatedAt", "isResolvedRecipient"],
            description: "Explicit chat invitation record with lifecycle status."
        )
    }

    private static func invitationArtifactProofSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "type": ExploreContract.schema(type: "string"),
                "byIdentityUUID": ExploreContract.schema(type: "string"),
                "algorithm": ExploreContract.schema(type: "string"),
                "curveType": ExploreContract.schema(type: "string"),
                "signature": ExploreContract.schema(type: "data")
            ],
            requiredKeys: ["type", "byIdentityUUID", "algorithm", "curveType"],
            description: "Signature proof over a chat invitation artifact."
        )
    }

    private static func invitationArtifactSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "version": ExploreContract.schema(type: "integer"),
                "invitationID": ExploreContract.schema(type: "string"),
                "purpose": ExploreContract.schema(type: "string"),
                "chatCellUUID": ExploreContract.schema(type: "string"),
                "topic": ExploreContract.schema(type: "string"),
                "audienceMode": ExploreContract.schema(type: "string"),
                "suiteID": ExploreContract.schema(type: "string"),
                "persistenceMode": ExploreContract.schema(type: "string"),
                "inviterIdentity": identityPublicKeyDescriptorSchema(),
                "invitedIdentity": identityPublicKeyDescriptorSchema(),
                "createdAt": ExploreContract.schema(type: "string"),
                "expiresAt": ExploreContract.schema(type: "string"),
                "nonce": ExploreContract.schema(type: "data"),
                "proof": invitationArtifactProofSchema()
            ],
            requiredKeys: ["version", "invitationID", "purpose", "chatCellUUID", "topic", "audienceMode", "suiteID", "persistenceMode", "inviterIdentity", "invitedIdentity", "createdAt", "expiresAt", "nonce"],
            description: "Signed artifact representing a transfer-ready chat invitation."
        )
    }

    private static func invitationArtifactInspectionSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "state": ExploreContract.schema(type: "string"),
                "acceptanceAllowed": ExploreContract.schema(type: "bool"),
                "invitationID": ExploreContract.schema(type: "string"),
                "chatCellUUID": ExploreContract.schema(type: "string"),
                "invitedIdentityUUID": ExploreContract.schema(type: "string"),
                "recordFound": ExploreContract.schema(type: "bool"),
                "recordStatus": ExploreContract.schema(type: "string"),
                "currentInvitationID": ExploreContract.schema(type: "string"),
                "currentArtifactIssuedAt": ExploreContract.schema(type: "string"),
                "currentArtifactExpiresAt": ExploreContract.schema(type: "string"),
                "consumedAt": ExploreContract.schema(type: "string"),
                "acceptanceID": ExploreContract.schema(type: "string"),
                "reason": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["state", "acceptanceAllowed", "invitationID", "chatCellUUID", "invitedIdentityUUID", "recordFound", "reason"],
            description: "Inspection result for whether a chat invitation artifact is still current, usable, or superseded."
        )
    }

    private static func invitationArtifactLedgerSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "invitationID": ExploreContract.schema(type: "string"),
                "invitedIdentityUUID": ExploreContract.schema(type: "string"),
                "artifactHash": ExploreContract.schema(type: "data"),
                "createdAt": ExploreContract.schema(type: "string"),
                "expiresAt": ExploreContract.schema(type: "string"),
                "state": ExploreContract.schema(type: "string"),
                "acceptanceAllowed": ExploreContract.schema(type: "bool"),
                "recordStatus": ExploreContract.schema(type: "string"),
                "acceptanceID": ExploreContract.schema(type: "string"),
                "consumedAt": ExploreContract.schema(type: "string"),
                "supersededByInvitationID": ExploreContract.schema(type: "string"),
                "supersededAt": ExploreContract.schema(type: "string"),
                "lastUpdatedAt": ExploreContract.schema(type: "string"),
                "reason": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["invitationID", "invitedIdentityUUID", "artifactHash", "createdAt", "expiresAt", "state", "acceptanceAllowed", "lastUpdatedAt", "reason"],
            description: "Durable invitation artifact inspection record persisted by the chat cell."
        )
    }

    private static func invitationAcceptanceProofSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "type": ExploreContract.schema(type: "string"),
                "byIdentityUUID": ExploreContract.schema(type: "string"),
                "algorithm": ExploreContract.schema(type: "string"),
                "curveType": ExploreContract.schema(type: "string"),
                "signature": ExploreContract.schema(type: "data")
            ],
            requiredKeys: ["type", "byIdentityUUID", "algorithm", "curveType"],
            description: "Signature proof over chat invitation acceptance."
        )
    }

    private static func invitationAcceptanceSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "version": ExploreContract.schema(type: "integer"),
                "acceptanceID": ExploreContract.schema(type: "string"),
                "purpose": ExploreContract.schema(type: "string"),
                "invitationID": ExploreContract.schema(type: "string"),
                "invitationHash": ExploreContract.schema(type: "data"),
                "chatCellUUID": ExploreContract.schema(type: "string"),
                "inviterIdentityUUID": ExploreContract.schema(type: "string"),
                "inviteeIdentity": identityPublicKeyDescriptorSchema(),
                "createdAt": ExploreContract.schema(type: "string"),
                "nonce": ExploreContract.schema(type: "data"),
                "proof": invitationAcceptanceProofSchema()
            ],
            requiredKeys: ["version", "acceptanceID", "purpose", "invitationID", "invitationHash", "chatCellUUID", "inviterIdentityUUID", "inviteeIdentity", "createdAt", "nonce"],
            description: "Signed acceptance for a chat invitation artifact."
        )
    }

    private static func audienceStateSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "mode": ExploreContract.schema(type: "string"),
                "modeLabel": ExploreContract.schema(type: "string"),
                "summary": ExploreContract.schema(type: "string"),
                "inheritedRecipients": ExploreContract.listSchema(item: audienceRecipientSchema()),
                "invitedRecipients": ExploreContract.listSchema(item: audienceRecipientSchema()),
                "resolvedRecipients": ExploreContract.listSchema(item: audienceRecipientSchema()),
                "invitations": ExploreContract.listSchema(item: invitationSchema()),
                "invitationLedgerCount": ExploreContract.schema(type: "integer"),
                "inheritedCount": ExploreContract.schema(type: "integer"),
                "invitedCount": ExploreContract.schema(type: "integer"),
                "resolvedCount": ExploreContract.schema(type: "integer"),
                "invitationCount": ExploreContract.schema(type: "integer"),
                "pendingInviteCount": ExploreContract.schema(type: "integer"),
                "acceptedInviteCount": ExploreContract.schema(type: "integer"),
                "declinedInviteCount": ExploreContract.schema(type: "integer"),
                "revokedInviteCount": ExploreContract.schema(type: "integer"),
                "supportsContextMembers": ExploreContract.schema(type: "bool"),
                "supportsExplicitInvites": ExploreContract.schema(type: "bool"),
                "defaultForEmbeddedComponent": ExploreContract.schema(type: "string"),
                "assistantHint": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["mode", "modeLabel", "summary", "resolvedRecipients", "resolvedCount"],
            description: "Current audience strategy for resolving chat recipients."
        )
    }

    private static func chatStateSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "topic": ExploreContract.schema(type: "string"),
                "status": ExploreContract.schema(type: "string"),
                "statusDetail": statusDetailSchema(),
                "messages": ExploreContract.listSchema(item: messageSchema()),
                "participants": ExploreContract.listSchema(item: participantSchema()),
                "members": ExploreContract.listSchema(item: participantSchema()),
                "audience": audienceStateSchema(),
                "messageCount": ExploreContract.schema(type: "integer"),
                "participantCount": ExploreContract.schema(type: "integer"),
                "messagesLimit": ExploreContract.schema(type: "integer"),
                "running": ExploreContract.schema(type: "bool"),
                "composer": composerStateSchema(),
                "crypto": cryptoStateSchema(),
                "availableFormats": ExploreContract.listSchema(item: formatSchema())
            ],
            requiredKeys: ["topic", "status", "messages", "participants", "composer"],
            description: "Full chat cell state snapshot."
        )
    }

    private static func recipientDescriptorSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "identityUUID": ExploreContract.schema(type: "string"),
                "displayName": ExploreContract.schema(type: "string"),
                "role": ExploreContract.schema(type: "string"),
                "keyID": ExploreContract.schema(type: "string"),
                "algorithm": ExploreContract.schema(type: "string"),
                "curveType": ExploreContract.schema(type: "string"),
                "publicKeyBase64": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["identityUUID", "displayName", "role", "keyID", "algorithm", "curveType", "publicKeyBase64"],
            description: "Recipient encryption key descriptor."
        )
    }

    private static func identityPublicKeyDescriptorSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "uuid": ExploreContract.schema(type: "string"),
                "displayName": ExploreContract.schema(type: "string"),
                "publicKey": ExploreContract.schema(type: "data"),
                "algorithm": ExploreContract.schema(type: "string"),
                "curveType": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["uuid", "publicKey", "algorithm", "curveType"],
            description: "Public signing key descriptor for an identity."
        )
    }

    private static func wrappedRecipientSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "recipientIdentityUUID": ExploreContract.schema(type: "string"),
                "recipientKeyID": ExploreContract.schema(type: "string"),
                "algorithm": ExploreContract.schema(type: "string"),
                "recipientCurveType": ExploreContract.schema(type: "string"),
                "recipientAlgorithm": ExploreContract.schema(type: "string"),
                "wrappedKeyMaterialBase64": ExploreContract.schema(type: "string"),
                "ephemeralPublicKeyBase64": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["recipientKeyID", "algorithm", "wrappedKeyMaterialBase64"],
            description: "Wrapped content-key descriptor for one recipient."
        )
    }

    private static func encryptedEnvelopeHeaderSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "version": ExploreContract.schema(type: "integer"),
                "suiteID": ExploreContract.schema(type: "string"),
                "contentAlgorithm": ExploreContract.schema(type: "string"),
                "keyWrappingAlgorithm": ExploreContract.schema(type: "string"),
                "senderKeyID": ExploreContract.schema(type: "string"),
                "createdAt": ExploreContract.schema(type: "string"),
                "keyID": ExploreContract.schema(type: "string"),
                "envelopeGeneration": ExploreContract.schema(type: "integer"),
                "associatedDataContext": ExploreContract.schema(type: "string"),
                "recipientKeys": ExploreContract.listSchema(item: wrappedRecipientSchema())
            ],
            requiredKeys: ["version", "suiteID", "contentAlgorithm", "keyWrappingAlgorithm", "createdAt", "recipientKeys"],
            description: "Encrypted content envelope header."
        )
    }

    private static func preparedEnvelopeSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "senderIdentityUUID": ExploreContract.schema(type: "string"),
                "senderDisplayName": ExploreContract.schema(type: "string"),
                "contentType": ExploreContract.schema(type: "string"),
                "recipientCount": ExploreContract.schema(type: "integer"),
                "recipients": ExploreContract.listSchema(item: recipientDescriptorSchema()),
                "envelopeGeneration": ExploreContract.schema(type: "integer"),
                "header": encryptedEnvelopeHeaderSchema(),
                "combinedCiphertextBase64": ExploreContract.schema(type: "string"),
                "senderSignatureBase64": ExploreContract.schema(type: "string"),
                "updatedAt": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["status", "senderIdentityUUID", "contentType", "recipientCount", "recipients", "header", "combinedCiphertextBase64"],
            description: "Prepared encrypted content envelope preview."
        )
    }

    private static func persistedEncryptedMessageSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "messageID": ExploreContract.schema(type: "string"),
                "senderIdentityUUID": ExploreContract.schema(type: "string"),
                "senderDisplayName": ExploreContract.schema(type: "string"),
                "contentType": ExploreContract.schema(type: "string"),
                "topic": ExploreContract.schema(type: "string"),
                "recipientCount": ExploreContract.schema(type: "integer"),
                "recipients": ExploreContract.listSchema(item: recipientDescriptorSchema()),
                "envelopeGeneration": ExploreContract.schema(type: "integer"),
                "header": encryptedEnvelopeHeaderSchema(),
                "combinedCiphertextBase64": ExploreContract.schema(type: "string"),
                "senderSignatureBase64": ExploreContract.schema(type: "string"),
                "source": ExploreContract.schema(type: "string"),
                "persistedAt": ExploreContract.schema(type: "string"),
                "openStatus": ExploreContract.schema(type: "string"),
                "lastOpenedAt": ExploreContract.schema(type: "string"),
                "lastOpenRecipientUUID": ExploreContract.schema(type: "string"),
                "senderVerified": ExploreContract.schema(type: "bool"),
                "lastOpenError": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["messageID", "senderIdentityUUID", "contentType", "recipientCount", "recipients", "header", "combinedCiphertextBase64", "source", "persistedAt", "openStatus"],
            description: "Persisted encrypted companion-envelope record for a sent chat message."
        )
    }

    private static func openedEnvelopeSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "recipientIdentityUUID": ExploreContract.schema(type: "string"),
                "recipientKeyID": ExploreContract.schema(type: "string"),
                "senderIdentityUUID": ExploreContract.schema(type: "string"),
                "senderVerified": ExploreContract.schema(type: "bool"),
                "suiteID": ExploreContract.schema(type: "string"),
                "envelopeGeneration": ExploreContract.schema(type: "integer"),
                "associatedDataContext": ExploreContract.schema(type: "string"),
                "contentType": ExploreContract.schema(type: "string"),
                "topic": ExploreContract.schema(type: "string"),
                "plaintext": ExploreContract.schema(type: "string"),
                "plaintextBase64": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["status", "recipientIdentityUUID", "recipientKeyID", "senderVerified", "suiteID", "plaintextBase64"],
            description: "Opened and verified encrypted envelope payload."
        )
    }

    private static func sendMessageInputSchema() -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                ExploreContract.schema(type: "string", description: "Shortcut body text."),
                ExploreContract.objectSchema(
                    properties: [
                        "content": ExploreContract.schema(type: "string"),
                        "body": ExploreContract.schema(type: "string"),
                        "text": ExploreContract.schema(type: "string"),
                        "topic": ExploreContract.schema(type: "string"),
                        "contentType": ExploreContract.schema(type: "string"),
                        "format": ExploreContract.schema(type: "string")
                    ],
                    description: "Message payload object."
                )
            ],
            description: "Accepts either a raw message string or a message object."
        )
    }

    private static func sendResponseSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "message": messageSchema(),
                "messageCount": ExploreContract.schema(type: "integer"),
                "participantCount": ExploreContract.schema(type: "integer")
            ],
            requiredKeys: ["status", "message", "messageCount", "participantCount"],
            description: "Successful chat send response."
        )
    }

    private static func contentCryptoSuiteObject(_ suite: ContentCryptoSuite) -> Object {
        var object: Object = [
            "id": .string(suite.id),
            "version": .integer(suite.version),
            "purpose": .string(suite.purpose.rawValue),
            "contentAlgorithm": .string(suite.contentAlgorithm.rawValue),
            "keyWrappingAlgorithm": .string(suite.keyWrappingAlgorithm.rawValue),
            "requiresSenderSignature": .bool(suite.requiresSenderSignature),
            "supportsForwardSecrecy": .bool(suite.supportsForwardSecrecy)
        ]

        object["keyAgreementAlgorithm"] = suite.keyAgreementAlgorithm.map { .string($0.rawValue) } ?? .null
        object["signatureAlgorithm"] = suite.signatureAlgorithm.map { .string($0.rawValue) } ?? .null
        object["curveType"] = suite.curveType.map { .string($0.rawValue) } ?? .null
        return object
    }

    private static func contentCryptoPolicyObject() -> Object {
        [
            "version": .integer(contentCryptoPolicy.version),
            "preferredSuiteID": .string(contentCryptoPolicy.preferredSuiteID),
            "acceptedSuiteIDs": .list(contentCryptoPolicy.acceptedSuiteIDs.map(ValueType.string)),
            "allowLegacyFallback": .bool(contentCryptoPolicy.allowLegacyFallback),
            "minimumRecipientCountForWrappedKeys": .integer(contentCryptoPolicy.minimumRecipientCountForWrappedKeys)
        ]
    }

    private static func recipientDescriptorObject(_ descriptor: IdentityRolePublicKeyDescriptor) -> Object {
        [
            "identityUUID": .string(descriptor.identityUUID),
            "displayName": .string(descriptor.displayName),
            "role": .string(descriptor.role.rawValue),
            "keyID": .string(descriptor.keyID),
            "algorithm": .string(descriptor.algorithm.rawValue),
            "curveType": .string(descriptor.curveType.rawValue),
            "publicKeyBase64": .string(descriptor.publicKey.base64EncodedString())
        ]
    }

    private static func identityPublicKeyDescriptorObject(_ descriptor: IdentityPublicKeyDescriptor) -> Object {
        [
            "uuid": .string(descriptor.uuid),
            "displayName": descriptor.displayName.map(ValueType.string) ?? .null,
            "publicKey": .data(descriptor.publicKey),
            "algorithm": .string(descriptor.algorithm.rawValue),
            "curveType": .string(descriptor.curveType.rawValue)
        ]
    }

    private static func invitationArtifactObject(_ artifact: ChatInvitationArtifact) -> Object {
        [
            "version": .integer(artifact.version),
            "invitationID": .string(artifact.invitationID),
            "purpose": .string(artifact.purpose),
            "chatCellUUID": .string(artifact.chatCellUUID),
            "topic": .string(artifact.topic),
            "audienceMode": .string(artifact.audienceMode),
            "suiteID": .string(artifact.suiteID),
            "persistenceMode": .string(artifact.persistenceMode),
            "inviterIdentity": .object(Self.identityPublicKeyDescriptorObject(artifact.inviterIdentity)),
            "invitedIdentity": .object(Self.identityPublicKeyDescriptorObject(artifact.invitedIdentity)),
            "createdAt": .string(artifact.createdAt),
            "expiresAt": .string(artifact.expiresAt),
            "nonce": .data(artifact.nonce),
            "proof": artifact.proof.map { proof in
                .object([
                    "type": .string(proof.type),
                    "byIdentityUUID": .string(proof.byIdentityUUID),
                    "algorithm": .string(proof.algorithm.rawValue),
                    "curveType": .string(proof.curveType.rawValue),
                    "signature": proof.signature.map(ValueType.data) ?? .null
                ])
            } ?? .null
        ]
    }

    private static func invitationAcceptanceObject(_ acceptance: ChatInvitationAcceptance) -> Object {
        [
            "version": .integer(acceptance.version),
            "acceptanceID": .string(acceptance.acceptanceID),
            "purpose": .string(acceptance.purpose),
            "invitationID": .string(acceptance.invitationID),
            "invitationHash": .data(acceptance.invitationHash),
            "chatCellUUID": .string(acceptance.chatCellUUID),
            "inviterIdentityUUID": .string(acceptance.inviterIdentityUUID),
            "inviteeIdentity": .object(Self.identityPublicKeyDescriptorObject(acceptance.inviteeIdentity)),
            "createdAt": .string(acceptance.createdAt),
            "nonce": .data(acceptance.nonce),
            "proof": acceptance.proof.map { proof in
                .object([
                    "type": .string(proof.type),
                    "byIdentityUUID": .string(proof.byIdentityUUID),
                    "algorithm": .string(proof.algorithm.rawValue),
                    "curveType": .string(proof.curveType.rawValue),
                    "signature": proof.signature.map(ValueType.data) ?? .null
                ])
            } ?? .null
        ]
    }

    private static func encryptedEnvelopeHeaderObject(_ header: EncryptedContentEnvelopeHeader) -> Object {
        [
            "version": .integer(header.version),
            "suiteID": .string(header.suiteID),
            "contentAlgorithm": .string(header.contentAlgorithm.rawValue),
            "keyWrappingAlgorithm": .string(header.keyWrappingAlgorithm.rawValue),
            "senderKeyID": header.senderKeyID.map(ValueType.string) ?? .null,
            "createdAt": .string(header.createdAt),
            "keyID": header.keyID.map(ValueType.string) ?? .null,
            "envelopeGeneration": header.envelopeGeneration.map(ValueType.integer) ?? .null,
            "associatedDataContext": header.associatedDataContext.map(ValueType.string) ?? .null,
            "recipientKeys": .list(header.recipientKeys.map { descriptor in
                .object([
                    "recipientIdentityUUID": descriptor.recipientIdentityUUID.map(ValueType.string) ?? .null,
                    "recipientKeyID": .string(descriptor.recipientKeyID),
                    "algorithm": .string(descriptor.algorithm.rawValue),
                    "recipientCurveType": descriptor.recipientCurveType.map { .string($0.rawValue) } ?? .null,
                    "recipientAlgorithm": descriptor.recipientAlgorithm.map { .string($0.rawValue) } ?? .null,
                    "wrappedKeyMaterialBase64": .string(descriptor.wrappedKeyMaterial.base64EncodedString()),
                    "ephemeralPublicKeyBase64": descriptor.ephemeralPublicKey.map { .string($0.base64EncodedString()) } ?? .null
                ])
            })
        ]
    }

    private static func preparedEnvelopeDraftObject(_ record: PreparedEnvelopeDraftRecord) -> Object {
        [
            "status": .string("prepared"),
            "senderIdentityUUID": .string(record.senderIdentityUUID),
            "senderDisplayName": .string(record.senderDisplayName),
            "contentType": .string(record.contentType),
            "recipientCount": .integer(record.recipients.count),
            "recipients": .list(record.recipients.map { .object(Self.recipientDescriptorObject($0)) }),
            "envelopeGeneration": record.envelope.header.envelopeGeneration.map(ValueType.integer) ?? .null,
            "header": .object(Self.encryptedEnvelopeHeaderObject(record.envelope.header)),
            "combinedCiphertextBase64": .string(record.envelope.combinedCiphertext.base64EncodedString()),
            "senderSignatureBase64": record.envelope.senderSignature.map { .string($0.base64EncodedString()) } ?? .null,
            "updatedAt": .string(record.updatedAt)
        ]
    }

    private static func persistedEncryptedMessageSummaryObject(_ record: PersistedEncryptedMessageRecord) -> Object {
        [
            "state": .string("encryptedCompanionAvailable"),
            "openStatus": .string(record.openStatus),
            "recipientCount": .integer(record.recipients.count),
            "envelopeGeneration": record.envelope.header.envelopeGeneration.map(ValueType.integer) ?? .null,
            "source": .string(record.source),
            "persistedAt": .string(record.persistedAt),
            "lastOpenedAt": record.lastOpenedAt.map(ValueType.string) ?? .null,
            "lastOpenRecipientUUID": record.lastOpenRecipientUUID.map(ValueType.string) ?? .null,
            "senderVerified": record.lastSenderVerified.map(ValueType.bool) ?? .null,
            "lastOpenError": record.lastOpenError.map(ValueType.string) ?? .null
        ]
    }

    private static func persistedEncryptedMessageObject(_ record: PersistedEncryptedMessageRecord) -> Object {
        [
            "messageID": .string(record.messageID),
            "senderIdentityUUID": .string(record.senderIdentityUUID),
            "senderDisplayName": .string(record.senderDisplayName),
            "contentType": .string(record.contentType),
            "topic": .string(record.topic),
            "recipientCount": .integer(record.recipients.count),
            "recipients": .list(record.recipients.map { .object(Self.recipientDescriptorObject($0)) }),
            "envelopeGeneration": record.envelope.header.envelopeGeneration.map(ValueType.integer) ?? .null,
            "header": .object(Self.encryptedEnvelopeHeaderObject(record.envelope.header)),
            "combinedCiphertextBase64": .string(record.envelope.combinedCiphertext.base64EncodedString()),
            "senderSignatureBase64": record.envelope.senderSignature.map { .string($0.base64EncodedString()) } ?? .null,
            "source": .string(record.source),
            "persistedAt": .string(record.persistedAt),
            "openStatus": .string(record.openStatus),
            "lastOpenedAt": record.lastOpenedAt.map(ValueType.string) ?? .null,
            "lastOpenRecipientUUID": record.lastOpenRecipientUUID.map(ValueType.string) ?? .null,
            "senderVerified": record.lastSenderVerified.map(ValueType.bool) ?? .null,
            "lastOpenError": record.lastOpenError.map(ValueType.string) ?? .null
        ]
    }
}
