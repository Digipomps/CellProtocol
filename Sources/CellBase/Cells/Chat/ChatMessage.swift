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

    public init(
        id: String = UUID().uuidString,
        owner: Identity,
        content: String,
        contentType: String = "text/plain",
        topic: String = "chat",
        createdAt: String? = nil
    ) {
        self.id = id
        self.owner = owner
        self.content = content
        self.contentType = contentType
        self.topic = topic
        self.createdAt = createdAt ?? Self.timestampString()
    }

    public func messageObject() -> Object {
        var messageObject: Object = [:]
        let preview = ChatPresentation.preview(for: content)
        messageObject["id"] = .string(id)
        messageObject["owner"] = .identity(owner)
        messageObject["ownerUUID"] = .string(owner.uuid)
        messageObject["ownerDisplayName"] = .string(owner.displayName)
        messageObject["ownerInitials"] = .string(ChatPresentation.initials(from: owner.displayName))
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
