// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// MARK: - What a relation is, in my own entity
//
// `relations.validatedContacts.<id>` (EntityValidatedContactRecordV1) holds the
// one thing that must stay fail-closed: how to reach a person. This record is
// everything else I know about the tie itself — where it came from and when,
// what the person does in which of my contexts, what they care about, how we
// have interacted and through which channels, and what evidence of contact we
// have exchanged. It carries no raw address; channels point at the validated
// contact record or at an opaque endpoint token, so the record can travel with
// the entity to any surface without leaking a contact list on the way.
//
// The two records share `relationID`. That is the join.

public enum EntityRelationOriginKind: String, Codable, CaseIterable, Sendable {
    case fileImport = "file-import"
    case addressBook = "address-book"
    case nearby
    case inviteSent = "invite-sent"
    case inviteReceived = "invite-received"
    case correspondence
    case conference
    case introduction
    case manual
}

/// Where the tie came from, and when it entered my entity. `context` is the
/// human name of the setting («Bok: Rammebetingelser for innovasjon»), not a
/// purpose reference — purposes live in `purposeRefs`.
public struct EntityRelationOrigin: Codable, Equatable, Sendable {
    public var kind: EntityRelationOriginKind
    public var at: Date
    public var sourceLabel: String
    public var batchID: String?
    public var locator: String?
    public var context: String?
    public var introducedByRelationID: String?

    public init(
        kind: EntityRelationOriginKind,
        at: Date,
        sourceLabel: String,
        batchID: String? = nil,
        locator: String? = nil,
        context: String? = nil,
        introducedByRelationID: String? = nil
    ) {
        self.kind = kind
        self.at = at
        self.sourceLabel = sourceLabel
        self.batchID = batchID
        self.locator = locator
        self.context = context
        self.introducedByRelationID = introducedByRelationID
    }
}

/// What the person does *in one of my contexts*. A person can be editor of
/// the book and a panellist at the conference; those are two roles, not one
/// job title. `group` is the sub-community inside the context (a working
/// group, a track, a table).
public struct EntityRelationRole: Codable, Equatable, Sendable {
    public var context: String
    public var role: String?
    public var group: String?

    public init(context: String, role: String? = nil, group: String? = nil) {
        self.context = context
        self.role = role
        self.group = group
    }
}

/// Declared is what the person or a list said. Inferred is what we guessed
/// from a title or an employer. The graph weighs them differently, and a
/// surface must be able to tell the owner which is which.
public struct EntityRelationInterests: Codable, Equatable, Sendable {
    public var declared: [String]
    public var inferred: [String]

    public init(declared: [String] = [], inferred: [String] = []) {
        self.declared = declared
        self.inferred = inferred
    }

    public var isEmpty: Bool { declared.isEmpty && inferred.isEmpty }
}

public enum EntityRelationChannelKind: String, Codable, CaseIterable, Sendable {
    case havenCorrespondence = "haven-correspondence"
    case havenChat = "haven-chat"
    case email
    case sms
    case phone
    case nearby
    case conference
    case web

    /// How much this channel can do on its own. Correspondence and chat carry
    /// a real conversation; an address only carries an invitation.
    public var reachRank: Int {
        switch self {
        case .havenChat: return 6
        case .havenCorrespondence: return 5
        case .nearby: return 4
        case .conference: return 3
        case .email: return 2
        case .sms, .phone: return 1
        case .web: return 0
        }
    }
}

/// A way to reach the person. `ref` is opaque on purpose: a correspondence
/// peer id, an entity reference, or the endpoint token the validated contact
/// record hands out — never the address itself.
public struct EntityRelationChannel: Codable, Equatable, Sendable {
    public var kind: EntityRelationChannelKind
    public var ref: String
    public var label: String?
    public var confirmed: Bool
    public var preferred: Bool
    public var lastUsedAt: Date?

    public init(
        kind: EntityRelationChannelKind,
        ref: String,
        label: String? = nil,
        confirmed: Bool = false,
        preferred: Bool = false,
        lastUsedAt: Date? = nil
    ) {
        self.kind = kind
        self.ref = ref
        self.label = label
        self.confirmed = confirmed
        self.preferred = preferred
        self.lastUsedAt = lastUsedAt
    }
}

public enum EntityRelationTrust: String, Codable, CaseIterable, Sendable {
    case none
    case invited
    case joined
    case verified
    case blocked
}

/// Where we stand: whether they are in HAVEN, whether there is an agreement
/// between our entities, and whether an invitation is in flight.
public struct EntityRelationStanding: Codable, Equatable, Sendable {
    public var trust: EntityRelationTrust
    public var inviteState: String?
    public var joinedAt: Date?
    public var agreementRef: String?
    public var lastInviteAt: Date?
    public var lastInviteTicketID: String?

    public init(
        trust: EntityRelationTrust = .none,
        inviteState: String? = nil,
        joinedAt: Date? = nil,
        agreementRef: String? = nil,
        lastInviteAt: Date? = nil,
        lastInviteTicketID: String? = nil
    ) {
        self.trust = trust
        self.inviteState = inviteState
        self.joinedAt = joinedAt
        self.agreementRef = agreementRef
        self.lastInviteAt = lastInviteAt
        self.lastInviteTicketID = lastInviteTicketID
    }
}

public enum EntityRelationDirection: String, Codable, Sendable {
    case inbound
    case outbound
}

public enum EntityRelationEvidenceKind: String, Codable, CaseIterable, Sendable {
    case vcPresented = "vc-presented"
    case vcIssued = "vc-issued"
    case contactRequest = "contact-request"
    case inviteAccepted = "invite-accepted"
    case messageAcknowledged = "message-acknowledged"
}

/// Proof that contact happened, kept as a reference. `ref` is the credential
/// id or the hash of the presentation; the credential itself lives in
/// `proofs`. `verified` says whether *we* checked the signature, not whether
/// the other side claims it is fine.
public struct EntityRelationEvidence: Codable, Equatable, Sendable {
    public var id: String
    public var kind: EntityRelationEvidenceKind
    public var direction: EntityRelationDirection
    public var at: Date
    public var ref: String
    public var issuerRef: String?
    public var subjectRef: String?
    public var chronicleRef: String?
    public var verified: Bool

    public init(
        id: String,
        kind: EntityRelationEvidenceKind,
        direction: EntityRelationDirection,
        at: Date,
        ref: String,
        issuerRef: String? = nil,
        subjectRef: String? = nil,
        chronicleRef: String? = nil,
        verified: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.direction = direction
        self.at = at
        self.ref = ref
        self.issuerRef = issuerRef
        self.subjectRef = subjectRef
        self.chronicleRef = chronicleRef
        self.verified = verified
    }
}

/// The fast answer to «when did we last talk, and how». Events themselves are
/// chronicle entries; this is the running total a surface can bind without
/// reading the chronicle.
public struct EntityRelationInteractionSummary: Codable, Equatable, Sendable {
    public var firstAt: Date?
    public var lastAt: Date?
    public var count: Int
    public var byChannel: [String: Int]
    public var byKind: [String: Int]
    public var lastKind: String?
    public var lastChannel: String?
    public var lastChronicleRef: String?

    public init(
        firstAt: Date? = nil,
        lastAt: Date? = nil,
        count: Int = 0,
        byChannel: [String: Int] = [:],
        byKind: [String: Int] = [:],
        lastKind: String? = nil,
        lastChannel: String? = nil,
        lastChronicleRef: String? = nil
    ) {
        self.firstAt = firstAt
        self.lastAt = lastAt
        self.count = count
        self.byChannel = byChannel
        self.byKind = byKind
        self.lastKind = lastKind
        self.lastChannel = lastChannel
        self.lastChronicleRef = lastChronicleRef
    }
}

/// Who the person is to me — names and affiliation, plus the three references
/// that tie this record to the rest of my entity: their own entity if they
/// have one, my projection of them in Perspective, and the validated contact
/// record that holds their actual address.
public struct EntityRelationSubject: Codable, Equatable, Sendable {
    public var displayName: String
    public var givenName: String?
    public var familyName: String?
    public var organization: String?
    public var jobTitle: String?
    public var entityRef: String?
    public var perspectiveRef: String?
    public var validatedContactRef: String?

    public init(
        displayName: String,
        givenName: String? = nil,
        familyName: String? = nil,
        organization: String? = nil,
        jobTitle: String? = nil,
        entityRef: String? = nil,
        perspectiveRef: String? = nil,
        validatedContactRef: String? = nil
    ) {
        self.displayName = displayName
        self.givenName = givenName
        self.familyName = familyName
        self.organization = organization
        self.jobTitle = jobTitle
        self.entityRef = entityRef
        self.perspectiveRef = perspectiveRef
        self.validatedContactRef = validatedContactRef
    }
}

public struct EntityRelationRecord: Codable, Equatable, Sendable {
    public var schema: String
    public var relationID: String
    public var subject: EntityRelationSubject
    public var origin: EntityRelationOrigin
    public var roles: [EntityRelationRole]
    public var interests: EntityRelationInterests
    public var purposeRefs: [String]
    public var channels: [EntityRelationChannel]
    public var standing: EntityRelationStanding
    public var evidence: [EntityRelationEvidence]
    public var interactions: EntityRelationInteractionSummary
    public var tags: [String]
    public var notes: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: Int

    public init(
        relationID: String,
        subject: EntityRelationSubject,
        origin: EntityRelationOrigin,
        roles: [EntityRelationRole] = [],
        interests: EntityRelationInterests = EntityRelationInterests(),
        purposeRefs: [String] = [],
        channels: [EntityRelationChannel] = [],
        standing: EntityRelationStanding = EntityRelationStanding(),
        evidence: [EntityRelationEvidence] = [],
        interactions: EntityRelationInteractionSummary = EntityRelationInteractionSummary(),
        tags: [String] = [],
        notes: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        revision: Int = 1
    ) {
        self.schema = EntityRelationRecordV1.recordSchema
        self.relationID = relationID
        self.subject = subject
        self.origin = origin
        self.roles = roles
        self.interests = interests
        self.purposeRefs = purposeRefs
        self.channels = channels
        self.standing = standing
        self.evidence = evidence
        self.interactions = interactions
        self.tags = tags
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
    }

    /// Channels a conversation can actually start on, best first.
    public var reachableChannels: [EntityRelationChannel] {
        channels
            .filter { $0.kind != .web }
            .sorted { lhs, rhs in
                if lhs.preferred != rhs.preferred { return lhs.preferred }
                if lhs.kind.reachRank != rhs.kind.reachRank { return lhs.kind.reachRank > rhs.kind.reachRank }
                if lhs.confirmed != rhs.confirmed { return lhs.confirmed }
                return (lhs.lastUsedAt ?? .distantPast) > (rhs.lastUsedAt ?? .distantPast)
            }
    }

    /// Folds one interaction into the running summary and the channel it
    /// used. Pure, so the same event applied twice is a bug a test can see.
    public func applying(_ event: EntityRelationInteractionEvent, chronicleRef: String?) -> EntityRelationRecord {
        var next = self
        var summary = next.interactions
        summary.count += 1
        summary.firstAt = min(summary.firstAt ?? event.at, event.at)
        summary.lastAt = max(summary.lastAt ?? event.at, event.at)
        summary.byKind[event.kind.rawValue, default: 0] += 1
        if let channel = event.channel {
            summary.byChannel[channel.rawValue, default: 0] += 1
        }
        if summary.lastAt == event.at {
            summary.lastKind = event.kind.rawValue
            summary.lastChannel = event.channel?.rawValue
            summary.lastChronicleRef = chronicleRef
        }
        next.interactions = summary

        if let channel = event.channel,
           let index = next.channels.firstIndex(where: { $0.kind == channel }) {
            next.channels[index].lastUsedAt = max(next.channels[index].lastUsedAt ?? .distantPast, event.at)
            if event.direction == .inbound { next.channels[index].confirmed = true }
        }

        switch event.kind {
        case .inviteSent:
            next.standing.lastInviteAt = event.at
            if next.standing.trust == .none { next.standing.trust = .invited }
        case .inviteJoined:
            if next.standing.trust != .blocked && next.standing.trust != .verified {
                next.standing.trust = .joined
            }
            next.standing.joinedAt = next.standing.joinedAt ?? event.at
        case .vcPresented:
            if next.standing.trust != .blocked { next.standing.trust = .verified }
        default:
            break
        }

        next.updatedAt = max(next.updatedAt, event.at)
        next.revision += 1
        return next
    }
}

// MARK: - Interaction events (chronicle)

public enum EntityRelationInteractionKind: String, Codable, CaseIterable, Sendable {
    case invitePrepared = "invite.prepared"
    case inviteSent = "invite.sent"
    case inviteOpened = "invite.opened"
    case inviteJoined = "invite.joined"
    case messageSent = "message.sent"
    case messageReceived = "message.received"
    case messageAcknowledged = "message.acknowledged"
    case chatStarted = "chat.started"
    case nearbyMet = "nearby.met"
    case vcPresented = "vc.presented"
    case vcIssued = "vc.issued"
    case contactRequestReceived = "contact-request.received"
    case noteAdded = "note.added"
}

public enum EntityRelationInteractionPolicyMode: String, Codable, CaseIterable, Sendable {
    /// Nothing is written.
    case off
    /// That contact happened, when, through which channel and in which
    /// direction. Never what was said.
    case metadata
    /// Metadata plus a short summary of the content. Requires explicit consent.
    case full
}

/// One thing that happened between me and a relation. The entry goes into
/// the chronicle; the relation record keeps only the running summary.
public struct EntityRelationInteractionEvent: Codable, Equatable, Sendable {
    public var id: String
    public var schema: String
    public var relationID: String
    public var kind: EntityRelationInteractionKind
    public var at: Date
    public var channel: EntityRelationChannelKind?
    public var direction: EntityRelationDirection?
    public var contentMode: EntityRelationInteractionPolicyMode
    public var summary: String?
    public var evidenceID: String?
    public var purposeRef: String
    public var sourceCell: String

    public init(
        id: String,
        relationID: String,
        kind: EntityRelationInteractionKind,
        at: Date,
        channel: EntityRelationChannelKind? = nil,
        direction: EntityRelationDirection? = nil,
        contentMode: EntityRelationInteractionPolicyMode = .metadata,
        summary: String? = nil,
        evidenceID: String? = nil,
        purposeRef: String = "purpose://contact.communication",
        sourceCell: String
    ) {
        self.id = id
        self.schema = EntityRelationRecordV1.eventSchema
        self.relationID = relationID
        self.kind = kind
        self.at = at
        self.channel = channel
        self.direction = direction
        self.contentMode = contentMode
        // Content never survives a metadata policy, whatever the caller passed.
        self.summary = contentMode == .full ? summary : nil
        self.evidenceID = evidenceID
        self.purposeRef = purposeRef
        self.sourceCell = sourceCell
    }

    private enum CodingKeys: String, CodingKey {
        case id, eventID, schema, relationID, kind, at, channel, direction
        case contentMode, summary, evidenceID, purposeRef, sourceCell
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(String.self, forKey: .schema)
        relationID = try c.decode(String.self, forKey: .relationID)
        let storedID = try c.decode(String.self, forKey: .id)
        if schema == EntityRelationRecordV1.eventSchema {
            id = try c.decode(String.self, forKey: .eventID)
            guard storedID == EntityRelationRecordV1.chronicleID(relationID: relationID, eventID: id) else {
                throw EntityRelationRecordErrorV1.relationBindingMismatch
            }
        } else {
            // Legacy feature-branch v1 values remain readable. New admission
            // requires v2 so the list selector and stored id actually agree.
            id = storedID
        }
        kind = try c.decode(EntityRelationInteractionKind.self, forKey: .kind)
        at = try c.decode(Date.self, forKey: .at)
        channel = try c.decodeIfPresent(EntityRelationChannelKind.self, forKey: .channel)
        direction = try c.decodeIfPresent(EntityRelationDirection.self, forKey: .direction)
        contentMode = try c.decode(EntityRelationInteractionPolicyMode.self, forKey: .contentMode)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        evidenceID = try c.decodeIfPresent(String.self, forKey: .evidenceID)
        purposeRef = try c.decode(String.self, forKey: .purposeRef)
        sourceCell = try c.decode(String.self, forKey: .sourceCell)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(relationID, forKey: .relationID)
        if schema == EntityRelationRecordV1.eventSchema {
            try c.encode(EntityRelationRecordV1.chronicleID(relationID: relationID, eventID: id), forKey: .id)
            try c.encode(id, forKey: .eventID)
        } else {
            try c.encode(id, forKey: .id)
        }
        try c.encode(kind, forKey: .kind)
        try c.encode(at, forKey: .at)
        try c.encodeIfPresent(channel, forKey: .channel)
        try c.encodeIfPresent(direction, forKey: .direction)
        try c.encode(contentMode, forKey: .contentMode)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(evidenceID, forKey: .evidenceID)
        try c.encode(purposeRef, forKey: .purposeRef)
        try c.encode(sourceCell, forKey: .sourceCell)
    }
}

// MARK: - Keypaths, validation, codec

/// Admission policy and addressing for relation records and their chronicle
/// events below an EntityAnchor. Additive to EntityValidatedContactRecordV1:
/// that namespace keeps its own, stricter rules.
public enum EntityRelationRecordV1 {
    public static let recordSchema = "haven.entity-relation-record.v1"
    public static let eventSchema = "haven.relation-interaction-event.v2"
    public static let envelopeSchema = "haven.entity-relation-batch.v1"
    public static let protectedRoot = "relations.records"
    public static let chronicleIDPrefix = "relation-event-"
    public static let interactionPolicyKeypath = "person.relations.interactionPolicy"
    public static let defaultInteractionPolicy = EntityRelationInteractionPolicyMode.metadata

    public static func keypath(relationID: String) -> String {
        "\(protectedRoot).\(relationID)"
    }

    public static func chronicleID(relationID: String, eventID: String) -> String {
        "\(chronicleIDPrefix)\(relationID)-\(eventID)"
    }

    public static func chronicleKeypath(relationID: String, eventID: String) -> String {
        "chronicle[id=\(chronicleID(relationID: relationID, eventID: eventID))]"
    }

    public static func isProtectedKeypath(_ keypath: String) -> Bool {
        let keypath = String(keypath.drop(while: { $0 == "." }))
        return keypath == "relations" || keypath.hasPrefix("relations[") || keypath == protectedRoot || keypath.hasPrefix(protectedRoot + ".") || keypath.hasPrefix(protectedRoot + "[")
    }

    public static func isRelationChronicleKeypath(_ keypath: String) -> Bool {
        let keypath = String(keypath.drop(while: { $0 == "." }))
        // Appending cannot replace an existing event. The value-aware admission
        // check below still prevents appending a forged reserved event ID.
        if keypath == "chronicle[+]" { return false }
        if keypath == "chronicle" || keypath.hasPrefix("chronicle.") { return true }
        guard keypath.hasPrefix("chronicle[") else { return false }
        // Only an exact, non-reserved id selector can address an unrelated
        // chronicle entry. Indexes, alternate selectors, and descendants can
        // otherwise replace or modify a protected relation event.
        let ordinaryPrefix = "chronicle[id="
        guard keypath.hasPrefix(ordinaryPrefix), keypath.hasSuffix("]") else { return true }
        let id = String(keypath.dropFirst(ordinaryPrefix.count).dropLast())
        return id.hasPrefix(chronicleIDPrefix) || (try? validateIdentifier(id)) == nil
    }

    /// Generic writes may not touch the namespace; the batch path validates.
    public static func rejectDirectMutation(to keypath: String) throws {
        let canonical = String(keypath.drop(while: { $0 == "." }))
        if isProtectedKeypath(keypath) || canonical.hasPrefix("chronicle[") || isRelationChronicleKeypath(keypath) {
            throw EntityRelationRecordErrorV1.protectedKeypathRequiresRelationSchema
        }
    }

    /// Generic chronicle writes require both their address and value to be
    /// checked: an ordinary selector must not smuggle in a reserved wire ID.
    public static func rejectDirectMutation(to keypath: String, value: ValueType) throws {
        if try validateOrdinaryChronicleMutation(to: keypath, value: value) { return }
        try rejectDirectMutation(to: keypath)
    }

    private static func validateOrdinaryChronicleMutation(to keypath: String, value: ValueType) throws -> Bool {
        let canonical = String(keypath.drop(while: { $0 == "." }))
        let isAppend = canonical == "chronicle[+]"
        let isOrdinarySelector = canonical.hasPrefix("chronicle[id=") && !isRelationChronicleKeypath(canonical)
        guard isAppend || isOrdinarySelector else { return false }

        // Null can remove an ordinary selected entry, but cannot be appended.
        if !isAppend, case .null = value { return true }
        guard case let .object(object) = value else {
            throw EntityRelationRecordErrorV1.invalidEventShape
        }
        if let storedID = object["id"] {
            guard case let .string(id) = storedID, !id.hasPrefix(chronicleIDPrefix) else {
                throw EntityRelationRecordErrorV1.relationBindingMismatch
            }
            if isOrdinarySelector {
                let selectedID = String(canonical.dropFirst("chronicle[id=".count).dropLast())
                guard id == selectedID else { throw EntityRelationRecordErrorV1.relationBindingMismatch }
            }
        }
        if case let .string(schema)? = object["schema"], schema.hasPrefix("haven.relation-interaction-event.") {
            throw EntityRelationRecordErrorV1.protectedKeypathRequiresRelationSchema
        }
        return true
    }

    /// Every mutation into `relations.records` must decode as a record whose
    /// `relationID` matches its keypath, and must carry no raw address. Every
    /// relation chronicle mutation must decode as an event and must not carry
    /// content unless it says it does. Batches that touch neither pass
    /// through untouched.
    public static func validatePersistenceEnvelope(
        _ envelope: EntityBatchPersistEnvelope,
        interactionPolicy: EntityRelationInteractionPolicyMode = defaultInteractionPolicy
    ) throws {
        for mutation in envelope.mutations {
            _ = try validateOrdinaryChronicleMutation(to: mutation.keypath, value: mutation.value)
        }
        let recordMutations = envelope.mutations.filter { isProtectedKeypath($0.keypath) }
        let eventMutations = envelope.mutations.filter { isRelationChronicleKeypath($0.keypath) }
        guard !recordMutations.isEmpty || !eventMutations.isEmpty else { return }

        guard envelope.schema == envelopeSchema else {
            throw EntityRelationRecordErrorV1.protectedKeypathRequiresRelationSchema
        }

        for mutation in recordMutations {
            // Forgetting a relation is a null write to its own keypath.
            if case .null = mutation.value {
                guard mutation.keypath.hasPrefix(protectedRoot + ".") else {
                    throw EntityRelationRecordErrorV1.relationBindingMismatch
                }
                try validateIdentifier(String(mutation.keypath.dropFirst(protectedRoot.count + 1)))
                continue
            }
            guard let record = EntityRelationCodec.decode(EntityRelationRecord.self, from: mutation.value) else {
                throw EntityRelationRecordErrorV1.invalidRecordShape
            }
            try validate(record)
            guard ExploreContractValidator.deepEqual(mutation.value, EntityRelationCodec.value(record)) else {
                throw EntityRelationRecordErrorV1.invalidRecordShape
            }
            guard mutation.keypath == keypath(relationID: record.relationID) else {
                throw EntityRelationRecordErrorV1.relationBindingMismatch
            }
        }

        for mutation in eventMutations {
            guard let event = EntityRelationCodec.decode(EntityRelationInteractionEvent.self, from: mutation.value) else {
                throw EntityRelationRecordErrorV1.invalidEventShape
            }
            try validate(event)
            guard interactionPolicy != .off,
                  event.contentMode != .full || interactionPolicy == .full else {
                throw EntityRelationRecordErrorV1.contentNotAllowedUnderPolicy
            }
            guard ExploreContractValidator.deepEqual(mutation.value, EntityRelationCodec.value(event)) else {
                throw EntityRelationRecordErrorV1.invalidEventShape
            }
            guard mutation.keypath == chronicleKeypath(relationID: event.relationID, eventID: event.id) else {
                throw EntityRelationRecordErrorV1.relationBindingMismatch
            }
        }
    }

    public static func validate(_ record: EntityRelationRecord) throws {
        guard record.schema == recordSchema else {
            throw EntityRelationRecordErrorV1.invalidRecordShape
        }
        try validateIdentifier(record.relationID)
        try requireString(record.subject.displayName, field: "subject.displayName", maxUTF8Bytes: 256)
        try requireString(record.origin.sourceLabel, field: "origin.sourceLabel", maxUTF8Bytes: 256)
        for channel in record.channels {
            try requireString(channel.ref, field: "channels.ref", maxUTF8Bytes: 512)
            if looksLikeRawAddress(channel.ref) {
                throw EntityRelationRecordErrorV1.rawContactValueNotAllowed
            }
        }
        for evidence in record.evidence {
            try validateIdentifier(evidence.id)
            try requireString(evidence.ref, field: "evidence.ref", maxUTF8Bytes: 512)
        }
        if let introducedBy = record.origin.introducedByRelationID {
            try validateIdentifier(introducedBy)
        }
        guard record.revision >= 1, record.interactions.count >= 0 else {
            throw EntityRelationRecordErrorV1.invalidRecordShape
        }
    }

    public static func validate(_ event: EntityRelationInteractionEvent) throws {
        guard event.schema == eventSchema else {
            throw EntityRelationRecordErrorV1.invalidEventShape
        }
        try validateIdentifier(event.id)
        try validateIdentifier(event.relationID)
        try requireString(event.sourceCell, field: "sourceCell", maxUTF8Bytes: 256)
        if event.contentMode == .off || (event.contentMode != .full && event.summary != nil) {
            throw EntityRelationRecordErrorV1.contentNotAllowedUnderPolicy
        }
        if let summary = event.summary, summary.utf8.count > 2_000 {
            throw EntityRelationRecordErrorV1.invalidStringField("summary")
        }
    }

    /// A missing setting means metadata only; malformed persisted settings
    /// disable capture. A submitted event cannot grant itself content consent.
    public static func interactionPolicy(from stored: ValueType?) -> EntityRelationInteractionPolicyMode {
        guard let stored else { return defaultInteractionPolicy }
        guard case let .string(raw) = stored,
              let mode = EntityRelationInteractionPolicyMode(rawValue: raw) else { return .off }
        return mode
    }

    /// v1's hyphen-separated chronicle address can collide for different
    /// relation/event ID pairs. Keep its wire shape, but never overwrite an
    /// existing event with different content or a different binding.
    public static func validateExistingEvent(_ stored: ValueType?, proposed: ValueType) throws {
        guard let stored, stored != .null else { return }
        guard ExploreContractValidator.deepEqual(stored, proposed) else {
            throw EntityRelationRecordErrorV1.relationBindingMismatch
        }
    }

    /// Value-free schema metadata for an owner-only Explore/read surface.
    public static func schemaValue() -> ValueType {
        .object([
            "schema": .string(envelopeSchema),
            "recordSchema": .string(recordSchema),
            "eventSchema": .string(eventSchema),
            "protectedRoot": .string(protectedRoot),
            "chronicleIDPrefix": .string(chronicleIDPrefix),
            "interactionPolicyKeypath": .string(interactionPolicyKeypath),
            "defaultInteractionPolicy": .string(defaultInteractionPolicy.rawValue),
            "writeOperation": .string(EntityBatchPersistEnvelope.operation),
            "rawContactValuesAllowed": .bool(false),
            "originKinds": .list(EntityRelationOriginKind.allCases.map { .string($0.rawValue) }),
            "channelKinds": .list(EntityRelationChannelKind.allCases.map { .string($0.rawValue) }),
            "interactionKinds": .list(EntityRelationInteractionKind.allCases.map { .string($0.rawValue) }),
            "evidenceKinds": .list(EntityRelationEvidenceKind.allCases.map { .string($0.rawValue) })
        ])
    }

    // MARK: helpers

    /// A channel ref is a token, a peer id or an entity reference. If it reads
    /// as an e-mail address or a phone number, the caller put the wrong thing
    /// in it, and the record would leak the moment it left the device.
    static func looksLikeRawAddress(_ value: String) -> Bool {
        if value.contains("@") { return true }
        let digits = value.filter(\.isNumber)
        if value.hasPrefix("+"), digits.count >= 8, digits.count == value.count - 1 { return true }
        if digits.count >= 8, digits.count == value.filter({ !$0.isWhitespace }).count { return true }
        return false
    }

    private static func validateIdentifier(_ value: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !value.isEmpty,
              value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw EntityRelationRecordErrorV1.invalidIdentifier(value)
        }
    }

    private static func requireString(_ value: String, field: String, maxUTF8Bytes: Int) throws {
        guard value.trimmingCharacters(in: .whitespacesAndNewlines) == value,
              !value.isEmpty,
              value.utf8.count <= maxUTF8Bytes else {
            throw EntityRelationRecordErrorV1.invalidStringField(field)
        }
    }
}

public enum EntityRelationRecordErrorV1: Error, Equatable, Sendable {
    case protectedKeypathRequiresRelationSchema
    case invalidRecordShape
    case invalidEventShape
    case relationBindingMismatch
    case rawContactValueNotAllowed
    case contentNotAllowedUnderPolicy
    case invalidIdentifier(String)
    case invalidStringField(String)
}

/// Codable ↔ ValueType through JSON, dates as ISO 8601 strings so a skeleton
/// can bind them directly. Same shape on every surface.
public enum EntityRelationCodec {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func value<T: Encodable>(_ value: T) -> ValueType {
        guard let data = try? encoder().encode(value),
              let bridged = try? decoder().decode(ValueType.self, from: data) else {
            return .null
        }
        return bridged
    }

    public static func decode<T: Decodable>(_ type: T.Type, from value: ValueType?) -> T? {
        guard let value,
              let data = try? encoder().encode(value) else { return nil }
        return try? decoder().decode(type, from: data)
    }
}

// MARK: - Reach: how to start a conversation with this person

public enum EntityRelationReachAction: String, Codable, CaseIterable, Sendable {
    /// They have an entity; open a HAVEN chat with it.
    case openChat = "open-chat"
    /// An assistant-correspondence peer exists; send through it.
    case sendCorrespondence = "send-correspondence"
    /// Not in HAVEN yet; prepare an invitation link for an address we hold.
    case sendInvite = "send-invite"
    /// An invitation is already out; sending again is allowed but should be
    /// a decision, not a reflex.
    case resendInvite = "resend-invite"
    /// They were nearby recently; the radar can hand over.
    case meetNearby = "meet-nearby"
}

public struct EntityRelationReachOption: Codable, Equatable, Sendable {
    public var action: EntityRelationReachAction
    public var channel: EntityRelationChannelKind
    public var ref: String
    public var reason: String
    public var score: Int

    public init(action: EntityRelationReachAction, channel: EntityRelationChannelKind, ref: String, reason: String, score: Int) {
        self.action = action
        self.channel = channel
        self.ref = ref
        self.reason = reason
        self.score = score
    }
}

public struct EntityRelationReachPlan: Codable, Equatable, Sendable {
    public var relationID: String
    public var displayName: String
    public var recommended: EntityRelationReachOption?
    public var alternatives: [EntityRelationReachOption]
    public var blockers: [String]
    public var lastContact: Date?
    public var lastContactKind: String?

    public var canReach: Bool { recommended != nil }
}

/// Decides how best to start a conversation, from the record alone. Pure and
/// deterministic so a surface, the butler and the scaffold all give the same
/// answer for the same person. The reasons are written for the owner.
public enum EntityRelationReachPlanner {
    public static let inviteCooldown: TimeInterval = 7 * 24 * 3_600
    public static let nearbyFreshness: TimeInterval = 24 * 3_600

    public static func plan(for record: EntityRelationRecord, now: Date = Date()) -> EntityRelationReachPlan {
        var plan = EntityRelationReachPlan(
            relationID: record.relationID,
            displayName: record.subject.displayName,
            recommended: nil,
            alternatives: [],
            blockers: [],
            lastContact: record.interactions.lastAt,
            lastContactKind: record.interactions.lastKind
        )

        if record.standing.trust == .blocked {
            plan.blockers.append("\(record.subject.displayName) er blokkert. Opphev blokkeringen først.")
            return plan
        }

        var options: [EntityRelationReachOption] = []
        for channel in record.reachableChannels {
            switch channel.kind {
            case .havenChat:
                options.append(EntityRelationReachOption(
                    action: .openChat, channel: .havenChat, ref: channel.ref,
                    reason: "\(record.subject.displayName) har en egen entitet i HAVEN — chatten går direkte.",
                    score: 100 + (channel.preferred ? 50 : 0)
                ))
            case .havenCorrespondence:
                options.append(EntityRelationReachOption(
                    action: .sendCorrespondence, channel: .havenCorrespondence, ref: channel.ref,
                    reason: channel.confirmed
                        ? "Korrespondansekanalen er bekreftet — dere har utvekslet meldinger der."
                        : "Korrespondansekanalen finnes, men er ikke bekreftet av et svar ennå.",
                    score: (channel.confirmed ? 90 : 80) + (channel.preferred ? 50 : 0)
                ))
            case .nearby:
                if let seen = channel.lastUsedAt, now.timeIntervalSince(seen) < nearbyFreshness {
                    options.append(EntityRelationReachOption(
                        action: .meetNearby, channel: .nearby, ref: channel.ref,
                        reason: "Var i nærheten for under et døgn siden.",
                        score: 70
                    ))
                }
            case .email, .sms, .phone:
                let alreadyOut: Bool = {
                    guard let last = record.standing.lastInviteAt else { return false }
                    return now.timeIntervalSince(last) < inviteCooldown
                        && ["prepared", "sent", "opened"].contains(record.standing.inviteState ?? "")
                }()
                let base = channel.kind == .email ? 60 : 50
                options.append(EntityRelationReachOption(
                    action: alreadyOut ? .resendInvite : .sendInvite,
                    channel: channel.kind, ref: channel.ref,
                    reason: alreadyOut
                        ? "Invitasjon ble sendt \(Self.dayText(record.standing.lastInviteAt, now: now)) og er ikke besvart. Send igjen bare om du mener det."
                        : "Ikke i HAVEN ennå. En invitasjonslenke over \(channel.kind == .email ? "e-post" : "SMS") er veien inn.",
                    score: (alreadyOut ? base - 30 : base) + (channel.preferred ? 50 : 0) + (channel.confirmed ? 5 : 0)
                ))
            case .conference, .web:
                break
            }
        }

        // Someone who joined but for whom we hold no entity reference is a data
        // gap, not a reachability fact — say so instead of guessing.
        if record.standing.trust == .joined,
           !record.channels.contains(where: { $0.kind == .havenChat }) {
            plan.blockers.append("\(record.subject.displayName) er med i HAVEN, men jeg mangler entitetsreferansen. Sjekk invitasjonsstatusen.")
        }

        options.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.channel.reachRank > rhs.channel.reachRank
        }
        plan.recommended = options.first
        plan.alternatives = Array(options.dropFirst())
        if options.isEmpty, plan.blockers.isEmpty {
            plan.blockers.append("Jeg har ingen kanal til \(record.subject.displayName) — verken entitet, korrespondanse, e-post eller telefon.")
        }
        return plan
    }

    private static func dayText(_ date: Date?, now: Date) -> String {
        guard let date else { return "tidligere" }
        let days = Int(now.timeIntervalSince(date) / 86_400)
        switch days {
        case 0: return "i dag"
        case 1: return "i går"
        default: return "for \(days) dager siden"
        }
    }
}
