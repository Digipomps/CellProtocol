// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum CorrespondenceEnvelopeError: Error, Equatable {
    case senderIdentityMismatch
    case signingFailed
    case invalidInnerEnvelope
    case innerSignatureInvalid
}

/// Cleartext routing metadata retained by a CorrespondenceCell.
///
/// `receiptState` is the pilot's explicitly server-visible receipt bit. It is
/// not part of the encrypted message and must not grow into a read-history log.
public struct CorrespondenceOuterEnvelope: Codable, Equatable, Sendable {
    public var messageID: String
    public var sequence: Int
    public var cellID: String
    public var senderIdentityUUID: String
    public var purposeRef: String
    public var createdAt: String
    public var expiresAt: String
    public var membershipFingerprint: String
    public var ciphertextSize: Int
    public var receiptState: String

    public init(
        messageID: String,
        sequence: Int,
        cellID: String,
        senderIdentityUUID: String,
        purposeRef: String,
        createdAt: String,
        expiresAt: String,
        membershipFingerprint: String,
        ciphertextSize: Int,
        receiptState: String = "pending"
    ) {
        self.messageID = messageID
        self.sequence = sequence
        self.cellID = cellID
        self.senderIdentityUUID = senderIdentityUUID
        self.purposeRef = purposeRef
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.membershipFingerprint = membershipFingerprint
        self.ciphertextSize = ciphertextSize
        self.receiptState = receiptState
    }
}

/// The encrypted message payload. The sender signature covers every field
/// except `senderSignature` and is created before this value is encrypted.
public struct CorrespondenceInnerEnvelope: Codable {
    public var subject: String?
    public var contentType: String
    public var content: String
    public var clientMessageID: String
    public var owner: Identity
    public var senderSignature: Data

    public init(
        subject: String?,
        contentType: String,
        content: String,
        clientMessageID: String,
        owner: Identity,
        senderSignature: Data
    ) {
        self.subject = subject
        self.contentType = contentType
        self.content = content
        self.clientMessageID = clientMessageID
        self.owner = owner
        self.senderSignature = senderSignature
    }

    public func chatMessage(
        messageID: String,
        purposeRef: String,
        createdAt: String
    ) -> ChatMessage {
        ChatMessage(
            id: messageID,
            owner: owner,
            content: content,
            contentType: contentType,
            topic: purposeRef,
            createdAt: createdAt
        )
    }

    fileprivate var signingPayload: SigningPayload {
        SigningPayload(
            subject: subject,
            contentType: contentType,
            content: content,
            clientMessageID: clientMessageID,
            ownerIdentityUUID: owner.uuid,
            ownerSigningKeyFingerprint: owner.signingPublicKeyFingerprint ?? ""
        )
    }

    fileprivate struct SigningPayload: Codable {
        var subject: String?
        var contentType: String
        var content: String
        var clientMessageID: String
        var ownerIdentityUUID: String
        var ownerSigningKeyFingerprint: String
    }
}

public struct CorrespondencePreparedEnvelope: Codable, Equatable, Sendable {
    public var senderIdentityUUID: String
    public var membershipFingerprint: String
    public var envelope: EncryptedContentEnvelope

    public init(
        senderIdentityUUID: String,
        membershipFingerprint: String,
        envelope: EncryptedContentEnvelope
    ) {
        self.senderIdentityUUID = senderIdentityUUID
        self.membershipFingerprint = membershipFingerprint
        self.envelope = envelope
    }
}

public struct CorrespondenceSendRequest: Codable, Equatable, Sendable {
    public var envelope: EncryptedContentEnvelope
    public var senderIdentityUUID: String
    public var membershipFingerprint: String
    public var purposeRef: String
    public var retentionSeconds: Int?

    public init(
        preparedEnvelope: CorrespondencePreparedEnvelope,
        purposeRef: String,
        retentionSeconds: Int? = nil
    ) {
        envelope = preparedEnvelope.envelope
        senderIdentityUUID = preparedEnvelope.senderIdentityUUID
        membershipFingerprint = preparedEnvelope.membershipFingerprint
        self.purposeRef = purposeRef
        self.retentionSeconds = retentionSeconds
    }

    public func valueType() throws -> ValueType {
        try CorrespondenceCellCodec.encode(self)
    }
}

public struct CorrespondenceStoredEnvelope: Codable, Equatable, Sendable {
    public var outer: CorrespondenceOuterEnvelope
    public var innerCiphertext: EncryptedContentEnvelope

    public init(outer: CorrespondenceOuterEnvelope, innerCiphertext: EncryptedContentEnvelope) {
        self.outer = outer
        self.innerCiphertext = innerCiphertext
    }
}

public struct CorrespondenceOpenedEnvelope {
    public var inner: CorrespondenceInnerEnvelope
    public var senderVerified: Bool

    public init(inner: CorrespondenceInnerEnvelope, senderVerified: Bool) {
        self.inner = inner
        self.senderVerified = senderVerified
    }
}

/// Client-side envelope operations shared by native clients and the later MCP
/// adapter. No plaintext is handed to CorrespondenceCell storage.
public enum CorrespondenceEnvelopeUtility {
    public static let suite = ContentCryptoSuite.chatMessageV1

    public static func prepare(
        message: ChatMessage,
        subject: String? = nil,
        clientMessageID: String? = nil,
        cellID: String,
        membershipFingerprint: String,
        recipients: [Identity],
        provider: IdentityKeyRoleProviderProtocol
    ) async throws -> CorrespondencePreparedEnvelope {
        guard message.owner.signingPublicKeyFingerprint?.isEmpty == false else {
            throw CorrespondenceEnvelopeError.signingFailed
        }

        let signingPayload = CorrespondenceInnerEnvelope.SigningPayload(
            subject: subject,
            contentType: message.contentType,
            content: message.content,
            clientMessageID: clientMessageID ?? message.id,
            ownerIdentityUUID: message.owner.uuid,
            ownerSigningKeyFingerprint: message.owner.signingPublicKeyFingerprint ?? ""
        )
        let signingData = try CanonicalPayloadEncoder.data(for: signingPayload)
        guard let innerSignature = try await message.owner.sign(data: signingData) else {
            throw CorrespondenceEnvelopeError.signingFailed
        }
        let inner = CorrespondenceInnerEnvelope(
            subject: subject,
            contentType: message.contentType,
            content: message.content,
            clientMessageID: clientMessageID ?? message.id,
            owner: message.owner.publicIdentitySnapshot(),
            senderSignature: innerSignature
        )
        let plaintext = try JSONEncoder().encode(inner)
        let envelope = try await ContentCryptoEnvelopeUtility.seal(
            plaintext: plaintext,
            sender: message.owner,
            recipients: recipients,
            provider: provider,
            suite: suite,
            associatedDataContext: associatedDataContext(
                cellID: cellID,
                membershipFingerprint: membershipFingerprint
            )
        )
        return CorrespondencePreparedEnvelope(
            senderIdentityUUID: message.owner.uuid,
            membershipFingerprint: membershipFingerprint,
            envelope: envelope
        )
    }

    public static func open(
        storedEnvelope: CorrespondenceStoredEnvelope,
        recipient: Identity,
        sender: Identity,
        provider: IdentityKeyRoleProviderProtocol
    ) async throws -> CorrespondenceOpenedEnvelope {
        let opened = try await ContentCryptoEnvelopeUtility.open(
            envelope: storedEnvelope.innerCiphertext,
            recipient: recipient,
            sender: sender,
            provider: provider
        )
        let inner: CorrespondenceInnerEnvelope
        do {
            inner = try JSONDecoder().decode(CorrespondenceInnerEnvelope.self, from: opened.plaintext)
        } catch {
            throw CorrespondenceEnvelopeError.invalidInnerEnvelope
        }
        guard identitiesReferenceSame(inner.owner, sender) else {
            throw CorrespondenceEnvelopeError.senderIdentityMismatch
        }
        let signingData = try CanonicalPayloadEncoder.data(for: inner.signingPayload)
        guard await inner.owner.verify(signature: inner.senderSignature, for: signingData) else {
            throw CorrespondenceEnvelopeError.innerSignatureInvalid
        }
        return CorrespondenceOpenedEnvelope(inner: inner, senderVerified: opened.senderVerified)
    }

    public static func associatedDataContext(
        cellID: String,
        membershipFingerprint: String
    ) -> String {
        "correspondence:v1:\(cellID):\(membershipFingerprint)"
    }

    static func verifyTransportSignature(
        envelope: EncryptedContentEnvelope,
        sender: Identity
    ) async -> Bool {
        guard let signature = envelope.senderSignature,
              let headerData = try? CanonicalPayloadEncoder.data(for: envelope.header) else {
            return false
        }
        return await sender.verify(
            signature: signature,
            for: headerData + envelope.combinedCiphertext
        )
    }

    private static func identitiesReferenceSame(_ lhs: Identity, _ rhs: Identity) -> Bool {
        guard lhs.uuid == rhs.uuid,
              let lhsFingerprint = lhs.signingPublicKeyFingerprint,
              let rhsFingerprint = rhs.signingPublicKeyFingerprint else {
            return false
        }
        return lhsFingerprint == rhsFingerprint
    }
}

enum CorrespondenceCellCodec {
    static func decode<T: Decodable>(_ value: ValueType, as type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func encode<T: Encodable>(_ value: T) throws -> ValueType {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(ValueType.self, from: data)
    }
}
