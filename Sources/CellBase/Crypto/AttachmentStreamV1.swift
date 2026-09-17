// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

extension ContentCryptoSuite {
    /// Chunk encryption only. Key distribution and sender authentication belong
    /// to the enclosing application protocol, not this direct-symmetric suite.
    public static let attachmentStreamV1 = ContentCryptoSuite(
        id: "haven.attachment.stream.v1",
        version: 1,
        purpose: .attachment,
        contentAlgorithm: .chachaPoly,
        keyWrappingAlgorithm: .directSymmetric,
        requiresSenderSignature: false,
        supportsForwardSecrecy: false
    )
}

public struct AttachmentStreamHeader: Codable, Equatable, Sendable {
    public var suiteID: String
    public var version: Int
    public var chunkSize: Int

    public init(chunkSize: Int = AttachmentStreamV1.defaultChunkSize) {
        suiteID = ContentCryptoSuite.attachmentStreamV1.id
        version = ContentCryptoSuite.attachmentStreamV1.version
        self.chunkSize = chunkSize
    }
}

public struct AttachmentStreamChunk: Codable, Equatable, Sendable {
    public var index: UInt64
    public var isFinal: Bool
    /// CryptoKit / swift-crypto combined representation: nonce || ciphertext || tag.
    public var combinedCiphertext: Data

    public init(index: UInt64, isFinal: Bool, combinedCiphertext: Data) {
        self.index = index
        self.isFinal = isFinal
        self.combinedCiphertext = combinedCiphertext
    }
}

public struct EncryptedAttachmentStream: Codable, Equatable, Sendable {
    public var header: AttachmentStreamHeader
    public var chunks: [AttachmentStreamChunk]

    public init(header: AttachmentStreamHeader, chunks: [AttachmentStreamChunk]) {
        self.header = header
        self.chunks = chunks
    }
}

/// Deliberately not Codable: the secret must never be serialized with ciphertext.
public struct SealedAttachmentStream {
    public let stream: EncryptedAttachmentStream
    public let contentKey: SymmetricKey
}

public enum AttachmentStreamError: Error, Equatable {
    case unsupportedSuite
    case invalidChunkSize
    case invalidKeySize
    case invalidChunkLength
    case unexpectedChunkIndex(expected: UInt64, actual: UInt64)
    case authenticationFailed
    case missingFinalChunk
    case chunkAfterFinal
    case chunkAfterShortChunk
    case sealerClosed
    case tooManyChunks
}

/// In-memory convenience API plus an incremental sealer. See Docs/AttachmentStreamV1.md.
public enum AttachmentStreamV1 {
    /// 64 KiB of plaintext per data chunk; callers may explicitly override it.
    public static let defaultChunkSize = 64 * 1024
    /// Format limit per chunk, not a total attachment-size policy.
    public static let maximumChunkSize = Int(UInt32.max)
    private static let combinedOverhead = 12 + 16

    public static func seal(
        plaintext: Data,
        chunkSize: Int = defaultChunkSize
    ) throws -> SealedAttachmentStream {
        let sealer = try AttachmentStreamSealer(chunkSize: chunkSize)
        var chunks: [AttachmentStreamChunk] = []
        var offset = plaintext.startIndex
        while offset < plaintext.endIndex {
            let count = min(chunkSize, plaintext.endIndex - offset)
            chunks.append(try sealer.sealChunk(Data(plaintext[offset..<(offset + count)])))
            offset += count
        }
        chunks.append(try sealer.finish())
        return SealedAttachmentStream(
            stream: EncryptedAttachmentStream(header: sealer.header, chunks: chunks),
            contentKey: sealer.contentKey
        )
    }

    public static func open(
        stream: EncryptedAttachmentStream,
        using contentKey: SymmetricKey
    ) throws -> Data {
        try open(header: stream.header, chunks: stream.chunks, using: contentKey)
    }

    /// Consumes chunks once, in order. No plaintext escapes until authenticated
    /// EOF and exhaustion of the input have both been verified. Buffers plaintext.
    public static func open<Chunks: Sequence>(
        header: AttachmentStreamHeader,
        chunks: Chunks,
        using contentKey: SymmetricKey
    ) throws -> Data where Chunks.Element == AttachmentStreamChunk {
        guard header.suiteID == ContentCryptoSuite.attachmentStreamV1.id,
              header.version == ContentCryptoSuite.attachmentStreamV1.version else {
            throw AttachmentStreamError.unsupportedSuite
        }
        try validateChunkSize(header.chunkSize)
        guard contentKey.bitCount == 256 else { throw AttachmentStreamError.invalidKeySize }
        let prefix = noncePrefix(using: contentKey)
        var expectedIndex: UInt64 = 0
        var sawFinal = false
        var sawShortChunk = false
        var plaintext = Data()

        for chunk in chunks {
            guard !sawFinal else { throw AttachmentStreamError.chunkAfterFinal }
            guard chunk.index == expectedIndex else {
                throw AttachmentStreamError.unexpectedChunkIndex(expected: expectedIndex, actual: chunk.index)
            }
            guard chunk.combinedCiphertext.count >= combinedOverhead else {
                throw AttachmentStreamError.invalidChunkLength
            }
            let length = chunk.combinedCiphertext.count - combinedOverhead
            if chunk.isFinal {
                guard length == 0 else { throw AttachmentStreamError.invalidChunkLength }
            } else {
                guard !sawShortChunk else { throw AttachmentStreamError.chunkAfterShortChunk }
                guard length > 0, length <= header.chunkSize else {
                    throw AttachmentStreamError.invalidChunkLength
                }
                guard expectedIndex < UInt64.max else { throw AttachmentStreamError.tooManyChunks }
            }
            let opened: Data
            do {
                let box = try ChaChaPoly.SealedBox(combined: chunk.combinedCiphertext)
                guard Data(box.nonce) == nonceData(prefix: prefix, index: chunk.index) else {
                    throw AttachmentStreamError.authenticationFailed
                }
                opened = try ChaChaPoly.open(
                    box, using: contentKey,
                    authenticating: authenticatedData(header: header, index: chunk.index, isFinal: chunk.isFinal)
                )
            } catch {
                throw AttachmentStreamError.authenticationFailed
            }
            if chunk.isFinal {
                sawFinal = true
            } else {
                plaintext.append(opened)
                sawShortChunk = length < header.chunkSize
                expectedIndex += 1
            }
        }
        guard sawFinal else { throw AttachmentStreamError.missingFinalChunk }
        return plaintext
    }

    fileprivate static func validateChunkSize(_ chunkSize: Int) throws {
        guard chunkSize > 0, chunkSize <= maximumChunkSize else {
            throw AttachmentStreamError.invalidChunkSize
        }
    }

    fileprivate static func noncePrefix(using key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: Data("HAVEN.AttachmentStream.v1.nonce".utf8), using: key
        ).prefix(4))
    }

    fileprivate static func nonceData(prefix: Data, index: UInt64) -> Data {
        prefix + bigEndian(index)
    }

    fileprivate static func authenticatedData(
        header: AttachmentStreamHeader, index: UInt64, isFinal: Bool
    ) -> Data {
        // Fixed domain + fixed-width integers: independent of JSON serialization.
        Data("haven.attachment.stream.v1\0".utf8)
            + bigEndian(UInt32(header.version))
            + bigEndian(UInt32(header.chunkSize))
            + bigEndian(index)
            + Data([isFinal ? 1 : 0])
    }

    private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var encoded = value.bigEndian
        return withUnsafeBytes(of: &encoded) { Data($0) }
    }
}

/// A single-use, sequential sealer; do not call concurrently. A reference type
/// prevents copying/resetting the counter. Each instance generates a fresh key;
/// accepting caller-supplied encryption keys would allow key/nonce reuse.
/// Retains only key, header and counters, not previous plaintext or ciphertext.
public final class AttachmentStreamSealer {
    public let header: AttachmentStreamHeader
    public let contentKey: SymmetricKey
    private let prefix: Data
    private var nextIndex: UInt64 = 0
    private var closed = false
    private var sawShortChunk = false

    public init(chunkSize: Int = AttachmentStreamV1.defaultChunkSize) throws {
        try AttachmentStreamV1.validateChunkSize(chunkSize)
        header = AttachmentStreamHeader(chunkSize: chunkSize)
        contentKey = SymmetricKey(size: .bits256)
        prefix = AttachmentStreamV1.noncePrefix(using: contentKey)
    }

    /// Supply full chunks, followed by at most one nonempty short chunk.
    /// Call finish even for an empty stream. No further data follows a short chunk.
    public func sealChunk(_ plaintext: Data) throws -> AttachmentStreamChunk {
        guard !closed else { throw AttachmentStreamError.sealerClosed }
        guard !sawShortChunk else { throw AttachmentStreamError.chunkAfterShortChunk }
        guard !plaintext.isEmpty, plaintext.count <= header.chunkSize else {
            throw AttachmentStreamError.invalidChunkLength
        }
        guard nextIndex < UInt64.max else { throw AttachmentStreamError.tooManyChunks }
        let chunk = try encrypt(plaintext, isFinal: false)
        nextIndex += 1
        sawShortChunk = plaintext.count < header.chunkSize
        return chunk
    }

    /// Authenticated empty terminal chunk. Its index commits to the data-chunk count.
    public func finish() throws -> AttachmentStreamChunk {
        guard !closed else { throw AttachmentStreamError.sealerClosed }
        let chunk = try encrypt(Data(), isFinal: true)
        closed = true
        return chunk
    }

    private func encrypt(_ plaintext: Data, isFinal: Bool) throws -> AttachmentStreamChunk {
        // A crypto failure permanently closes this sealer: never retry a nonce.
        closed = true
        let nonce = try ChaChaPoly.Nonce(data: AttachmentStreamV1.nonceData(prefix: prefix, index: nextIndex))
        let box = try ChaChaPoly.seal(
            plaintext, using: contentKey, nonce: nonce,
            authenticating: AttachmentStreamV1.authenticatedData(header: header, index: nextIndex, isFinal: isFinal)
        )
        closed = false
        return AttachmentStreamChunk(index: nextIndex, isFinal: isFinal, combinedCiphertext: box.combined)
    }
}
