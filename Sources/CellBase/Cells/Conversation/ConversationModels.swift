// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// One stored chat message. The same object is written to `sent/`, to every
/// recipient's `inbox/<member>/`, carried whole in `message.appended`, and
/// returned by `messages.since`. Times are ISO 8601 UTC; clients format them
/// in their own time zone.
public struct ConversationMessage: Codable, Equatable, Sendable {
    public static let plainContentSuite = "haven.chat.plain.v1"

    public var conversationID: String
    public var seq: Int
    public var messageID: String
    public var clientMessageID: String
    public var authorUUID: String
    public var authorDisplayName: String
    public var contentSuite: String
    public var contentType: String
    public var content: String
    public var createdAt: String

    public init(
        conversationID: String,
        seq: Int,
        messageID: String,
        clientMessageID: String,
        authorUUID: String,
        authorDisplayName: String,
        contentSuite: String = ConversationMessage.plainContentSuite,
        contentType: String = "text/plain",
        content: String,
        createdAt: String
    ) {
        self.conversationID = conversationID
        self.seq = seq
        self.messageID = messageID
        self.clientMessageID = clientMessageID
        self.authorUUID = authorUUID
        self.authorDisplayName = authorDisplayName
        self.contentSuite = contentSuite
        self.contentType = contentType
        self.content = content
        self.createdAt = createdAt
    }
}

/// An accepted member. When `signingPublicKeyFingerprint` is recorded, a
/// requester presenting the UUID must also present that key and prove control.
public struct ConversationMember: Codable, Equatable, Sendable {
    public var uuid: String
    public var displayName: String
    public var signingPublicKeyFingerprint: String?

    public init(uuid: String, displayName: String, signingPublicKeyFingerprint: String? = nil) {
        self.uuid = uuid
        self.displayName = displayName
        self.signingPublicKeyFingerprint = signingPublicKeyFingerprint
    }
}

/// Membership and title for one generation. Written once per generation to
/// `meta/<generation>.json`; the highest generation is current.
public struct ConversationMeta: Codable, Equatable, Sendable {
    public var conversationID: String
    public var generation: Int
    public var title: String
    public var ownerUUID: String
    public var inviterDisplayName: String
    public var members: [ConversationMember]
    public var pendingInviteeUUIDs: [String]
    public var blockedUUIDs: [String]
    public var updatedAt: String

    public init(
        conversationID: String,
        generation: Int,
        title: String,
        ownerUUID: String,
        inviterDisplayName: String,
        members: [ConversationMember],
        pendingInviteeUUIDs: [String] = [],
        blockedUUIDs: [String] = [],
        updatedAt: String
    ) {
        self.conversationID = conversationID
        self.generation = generation
        self.title = title
        self.ownerUUID = ownerUUID
        self.inviterDisplayName = inviterDisplayName
        self.members = members
        self.pendingInviteeUUIDs = pendingInviteeUUIDs
        self.blockedUUIDs = blockedUUIDs
        self.updatedAt = updatedAt
    }

    /// Accepted and not blocked.
    public func acceptedMember(_ uuid: String) -> ConversationMember? {
        guard !blockedUUIDs.contains(uuid) else { return nil }
        return members.first { $0.uuid == uuid }
    }

    func sameMembership(as other: ConversationMeta) -> Bool {
        title == other.title
            && members.sorted { $0.uuid < $1.uuid } == other.members.sorted { $0.uuid < $1.uuid }
            && Set(pendingInviteeUUIDs) == Set(other.pendingInviteeUUIDs)
            && Set(blockedUUIDs) == Set(other.blockedUUIDs)
    }
}

/// Reasons a conversation operation is refused. Raw values are the contract's
/// `denialReasons`.
public enum ConversationDenialReason: String, Codable, Sendable {
    case notMember = "not_member"
    case pendingInvite = "pending_invite"
    case blocked
    case storageFailed = "storage_failed"
    case invalidPayload = "invalid_payload"
}

/// The answer to `messages.send`.
public struct ConversationSendResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case sent, duplicate, error }

    public var ok: Bool
    public var status: Status
    public var seq: Int?
    public var messageID: String?
    public var message: ConversationMessage?
    public var code: String?

    public static func failure(_ reason: ConversationDenialReason) -> ConversationSendResult {
        ConversationSendResult(ok: false, status: .error, seq: nil, messageID: nil, message: nil, code: reason.rawValue)
    }

    public static func stored(_ message: ConversationMessage, duplicate: Bool) -> ConversationSendResult {
        ConversationSendResult(
            ok: true,
            status: duplicate ? .duplicate : .sent,
            seq: message.seq,
            messageID: message.messageID,
            message: message,
            code: nil
        )
    }
}

/// A page of messages after a sequence number.
public struct ConversationMessagePage: Codable, Equatable, Sendable {
    public var messages: [ConversationMessage]
    public var lastSeq: Int
    public var hasMore: Bool
}

enum ConversationCodec {
    static func value<T: Encodable>(_ value: T) throws -> ValueType {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(ValueType.self, from: data)
    }

    static func decode<T: Decodable>(_ value: ValueType, as type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Deterministic bytes, so an identical re-write can be recognised.
    static func objectData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
