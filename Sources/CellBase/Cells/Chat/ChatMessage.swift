// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct ChatMessage: Codable {
    public let id: String
    public let owner: Identity
    public let content: String
    public let contentType: String
    public let topic: String
    public let createdAt: String
    public let ownerDisplayNameSnapshot: String?
    /// Who wrote the message: "person" (default, also for older messages) or "model".
    public let authorKind: String?
    /// For a model message: the member who asked, the model that answered,
    /// whether the route was local or external, and how many messages it read.
    public let askedByUUID: String?
    public let askedByDisplayName: String?
    public let model: String?
    public let routeClass: String?
    public let contextCount: Int?

    public init(
        id: String = UUID().uuidString,
        owner: Identity,
        content: String,
        contentType: String = "text/plain",
        topic: String = "chat",
        createdAt: String? = nil,
        ownerDisplayNameSnapshot: String? = nil,
        authorKind: String? = nil,
        askedByUUID: String? = nil,
        askedByDisplayName: String? = nil,
        model: String? = nil,
        routeClass: String? = nil,
        contextCount: Int? = nil
    ) {
        self.id = id
        self.owner = owner
        self.content = content
        self.contentType = contentType
        self.topic = topic
        self.createdAt = createdAt ?? Self.timestampString()
        self.ownerDisplayNameSnapshot = ownerDisplayNameSnapshot ?? owner.displayName
        self.authorKind = authorKind
        self.askedByUUID = askedByUUID
        self.askedByDisplayName = askedByDisplayName
        self.model = model
        self.routeClass = routeClass
        self.contextCount = contextCount
    }

    /// "person" unless the message was written by the chat's model participant.
    public var resolvedAuthorKind: String { authorKind ?? "person" }

    public func messageObject() -> Object {
        messageObject(presentationScopeID: nil)
    }

    func messageObject(presentationScopeID: String?) -> Object {
        var messageObject: Object = [:]
        let preview = ChatPresentation.preview(for: content)
        let displayName = ownerDisplayNameSnapshot ?? owner.displayName
        messageObject["id"] = .string(id)
        messageObject["owner"] = .identity(owner)
        messageObject["ownerUUID"] = .string(owner.uuid)
        messageObject["ownerDisplayName"] = .string(displayName)
        messageObject["ownerInitials"] = .string(ChatPresentation.initials(from: displayName))
        messageObject["ownerPresentation"] = .object(ChatPresentation.participantPresentation(
            displayName: displayName,
            scopeID: presentationScopeID,
            participantID: owner.uuid
        ))
        messageObject["content"] = .string(content)
        messageObject["contentPreview"] = .string(preview)
        messageObject["contentRichText"] = .string(ChatPresentation.richTextContent(from: content, contentType: contentType))
        messageObject["contentType"] = .string(contentType)
        messageObject["formatLabel"] = .string(ChatPresentation.formatLabel(for: contentType))
        messageObject["isMarkdown"] = .bool(ChatPresentation.isMarkdown(contentType: contentType))
        messageObject["topic"] = .string(topic)
        messageObject["createdAt"] = .string(createdAt)
        messageObject["displayTimestamp"] = .string(ChatPresentation.absoluteTimestamp(from: createdAt))
        messageObject["relativeTimestamp"] = .string(ChatPresentation.relativeTimestamp(from: createdAt))
        messageObject["authorKind"] = .string(resolvedAuthorKind)
        if resolvedAuthorKind == "model" {
            messageObject["askedByUUID"] = askedByUUID.map(ValueType.string) ?? .null
            messageObject["askedByDisplayName"] = askedByDisplayName.map(ValueType.string) ?? .null
            messageObject["model"] = model.map(ValueType.string) ?? .null
            messageObject["routeClass"] = routeClass.map(ValueType.string) ?? .null
            messageObject["contextCount"] = contextCount.map { .integer($0) } ?? .null
        }
        return messageObject
    }

    public func messageValue() -> ValueType {
        .object(messageObject())
    }

    public func messageData() throws -> Data {
        try JSONEncoder().encode(messageValue())
    }

    public static func generate(owner: Identity) -> ChatMessage {
        let samples = [
            "Hei fra Scaffold Chat. Denne meldingen kommer fra demo-emitteren.",
            "Markdown stoettes via text/markdown hvis klienten vil rendre det.",
            "Binding kan absorbere staging-chat og vise historikk + nye meldinger i samme liste."
        ]
        let index = Int.random(in: 0 ..< samples.count)
        let useMarkdown = Bool.random()
        return ChatMessage(
            owner: owner,
            content: samples[index],
            contentType: useMarkdown ? "text/markdown" : "text/plain",
            topic: "chat"
        )
    }

    private static func timestampString(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
