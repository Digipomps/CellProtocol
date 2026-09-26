// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class AttachmentStreamV1Tests: XCTestCase {
    private let chunkSize = 32

    private func payload(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 * 37) })
    }

    private func sealed(_ count: Int = 101) throws -> SealedAttachmentStream {
        try AttachmentStreamV1.seal(plaintext: payload(count), chunkSize: chunkSize)
    }

    private func assertRejected(
        _ stream: EncryptedAttachmentStream, key: SymmetricKey,
        error expected: AttachmentStreamError? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var returnedPlaintext: Data?
        XCTAssertThrowsError(
            returnedPlaintext = try AttachmentStreamV1.open(stream: stream, using: key),
            file: file, line: line
        ) { error in
            if let expected {
                XCTAssertEqual(error as? AttachmentStreamError, expected, file: file, line: line)
            }
        }
        XCTAssertNil(returnedPlaintext, "Rejected stream must never return partial plaintext", file: file, line: line)
    }

    func testMultiChunkRoundTrip() throws {
        let result = try sealed()
        XCTAssertEqual(result.stream.chunks.count, 5) // Four data chunks + authenticated EOF.
        XCTAssertEqual(try AttachmentStreamV1.open(stream: result.stream, using: result.contentKey), payload(101))
    }

    func testZeroOneExactChunkAndChunkPlusOneBytes() throws {
        for count in [0, 1, chunkSize, chunkSize + 1] {
            let result = try sealed(count)
            XCTAssertEqual(result.stream.chunks.count, (count + chunkSize - 1) / chunkSize + 1, "length=\(count)")
            XCTAssertTrue(try XCTUnwrap(result.stream.chunks.last).isFinal)
            XCTAssertEqual(result.stream.chunks.last?.combinedCiphertext.count, 28)
            XCTAssertEqual(try AttachmentStreamV1.open(stream: result.stream, using: result.contentKey), payload(count))
        }
    }

    func testOneBitChangedInEveryChunkFailsIncludingFinalTag() throws {
        let result = try sealed()
        for index in result.stream.chunks.indices {
            var damaged = result.stream
            damaged.chunks[index].combinedCiphertext[12] ^= 1 // Ciphertext, or tag for empty EOF.
            assertRejected(damaged, key: result.contentKey, error: .authenticationFailed)
        }
    }

    func testSwappedChunksFail() throws {
        let result = try sealed()
        var swapped = result.stream
        swapped.chunks.swapAt(0, 1)
        assertRejected(swapped, key: result.contentKey, error: .unexpectedChunkIndex(expected: 0, actual: 1))
    }

    func testSwappedChunksWithRewrittenIndicesStillFailAuthentication() throws {
        let result = try sealed()
        var swapped = result.stream
        swapped.chunks.swapAt(0, 1)
        swapped.chunks[0].index = 0
        swapped.chunks[1].index = 1
        assertRejected(swapped, key: result.contentKey, error: .authenticationFailed)
    }

    func testRemovedFinalChunkFailsWithoutReturningPartialPlaintext() throws {
        for count in [0, chunkSize, 101] {
            let result = try sealed(count)
            var truncated = result.stream
            truncated.chunks.removeLast()
            assertRejected(truncated, key: result.contentKey, error: .missingFinalChunk)
        }
    }

    func testMissingDataChunkAtEveryPositionFails() throws {
        let result = try sealed()
        for index in result.stream.chunks.indices.dropLast() {
            var truncated = result.stream
            truncated.chunks.remove(at: index)
            assertRejected(truncated, key: result.contentKey)
        }
    }

    func testRemovedLastDataChunkAndRenumberedFinalChunkFail() throws {
        let result = try sealed()
        var truncated = result.stream
        truncated.chunks.remove(at: truncated.chunks.count - 2)
        truncated.chunks[truncated.chunks.count - 1].index -= 1
        assertRejected(truncated, key: result.contentKey, error: .authenticationFailed)
    }

    func testRepeatedChunkAtEveryPositionFails() throws {
        let result = try sealed()
        for index in result.stream.chunks.indices {
            var repeated = result.stream
            repeated.chunks.insert(repeated.chunks[index], at: index + 1)
            assertRejected(repeated, key: result.contentKey)
        }
    }

    func testWrong256BitKeyFailsIncludingEmptyStream() throws {
        for count in [0, 101] {
            let result = try sealed(count)
            assertRejected(result.stream, key: SymmetricKey(size: .bits256), error: .authenticationFailed)
        }
    }

    func testWrongKeyLengthFails() throws {
        let result = try sealed()
        assertRejected(result.stream, key: SymmetricKey(size: .bits128), error: .invalidKeySize)
    }

    func testHeaderChunkSizeIsAuthenticated() throws {
        let result = try sealed(1)
        var changed = result.stream
        changed.header.chunkSize += 1
        assertRejected(changed, key: result.contentKey, error: .authenticationFailed)
    }

    func testUnknownSuiteAndVersionAreRejected() throws {
        let result = try sealed()
        var changed = result.stream
        changed.header.suiteID = ContentCryptoSuite.chatMessageV1.id
        assertRejected(changed, key: result.contentKey, error: .unsupportedSuite)
        changed = result.stream
        changed.header.version += 1
        assertRejected(changed, key: result.contentKey, error: .unsupportedSuite)
    }

    func testFinalFlagCannotTurnDataIntoEOF() throws {
        let result = try sealed()
        var changed = result.stream
        changed.chunks = [changed.chunks[0]]
        changed.chunks[0].isFinal = true
        // Preserve a structurally valid empty sealed box, but the original tag.
        let combined = changed.chunks[0].combinedCiphertext
        changed.chunks[0].combinedCiphertext = Data(combined.prefix(12)) + Data(combined.suffix(16))
        assertRejected(changed, key: result.contentKey, error: .authenticationFailed)
    }

    func testTruncatedCombinedCiphertextAndTrailingDataFail() throws {
        let result = try sealed()
        var changed = result.stream
        changed.chunks[0].combinedCiphertext = Data(repeating: 0, count: 27)
        assertRejected(changed, key: result.contentKey, error: .invalidChunkLength)
        changed = result.stream
        changed.chunks.append(changed.chunks[0])
        assertRejected(changed, key: result.contentKey, error: .chunkAfterFinal)
    }

    func testFreshContentKeyPerStreamRejectsSplicing() throws {
        let first = try sealed()
        let second = try sealed()
        XCTAssertNotEqual(first.contentKey.withUnsafeBytes { Data($0) }, second.contentKey.withUnsafeBytes { Data($0) })
        var mixed = first.stream
        mixed.chunks[1] = second.stream.chunks[1]
        assertRejected(mixed, key: first.contentKey, error: .authenticationFailed)
    }

    func testNonceDerivationAndSharedContentKeyForAllChunks() throws {
        let result = try sealed()
        let prefix = Data(HMAC<SHA256>.authenticationCode(
            for: Data("HAVEN.AttachmentStream.v1.nonce".utf8), using: result.contentKey
        ).prefix(4))
        var nonces = Set<Data>()
        for (index, chunk) in result.stream.chunks.enumerated() {
            let box = try ChaChaPoly.SealedBox(combined: chunk.combinedCiphertext)
            let expectedNonce = prefix + Data([0, 0, 0, 0, 0, 0, 0, UInt8(index)])
            XCTAssertEqual(Data(box.nonce), expectedNonce)
            XCTAssertTrue(nonces.insert(Data(box.nonce)).inserted)
            // Independently construct the documented fixed-width AAD for size 32.
            let aad = Data("haven.attachment.stream.v1\0".utf8)
                + Data([0, 0, 0, 1, 0, 0, 0, 32])
                + Data([0, 0, 0, 0, 0, 0, 0, UInt8(index), chunk.isFinal ? 1 : 0])
            let clear = try ChaChaPoly.open(box, using: result.contentKey, authenticating: aad)
            let expected = chunk.isFinal ? Data() : payload(101).subdata(in: (index * chunkSize)..<min((index + 1) * chunkSize, 101))
            XCTAssertEqual(clear, expected)
        }
    }

    func testCodableRoundTripPreservesStreamAndSuite() throws {
        let result = try sealed()
        let encoded = try JSONEncoder().encode(result.stream)
        let decoded = try JSONDecoder().decode(EncryptedAttachmentStream.self, from: encoded)
        XCTAssertEqual(decoded, result.stream)
        XCTAssertEqual(try AttachmentStreamV1.open(stream: decoded, using: result.contentKey), payload(101))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["header", "chunks"])
        let suite = ContentCryptoSuite.attachmentStreamV1
        XCTAssertEqual(try JSONDecoder().decode(ContentCryptoSuite.self, from: JSONEncoder().encode(suite)), suite)
        XCTAssertEqual(suite.id, "haven.attachment.stream.v1")
        XCTAssertEqual(suite.purpose, .attachment)
        XCTAssertEqual(suite.keyWrappingAlgorithm, .directSymmetric)
    }

    func testDefaultAndExplicitChunkSizes() throws {
        XCTAssertEqual(AttachmentStreamV1.defaultChunkSize, 65_536)
        let result = try AttachmentStreamV1.seal(plaintext: payload(65_537))
        XCTAssertEqual(result.stream.header.chunkSize, 65_536)
        XCTAssertEqual(result.stream.chunks.map { $0.combinedCiphertext.count }, [65_536 + 28, 1 + 28, 28])
        XCTAssertEqual(try AttachmentStreamV1.open(stream: result.stream, using: result.contentKey), payload(65_537))
        for size in [1, 17, 1024] {
            let custom = try AttachmentStreamV1.seal(plaintext: payload(1025), chunkSize: size)
            XCTAssertEqual(custom.stream.header.chunkSize, size)
            XCTAssertEqual(try AttachmentStreamV1.open(stream: custom.stream, using: custom.contentKey), payload(1025))
        }
    }

    func testInvalidChunkSizesFailBeforeSealingOrOpening() throws {
        let result = try sealed()
        for size in [Int.min, -1, 0, AttachmentStreamV1.maximumChunkSize + 1, Int.max] {
            XCTAssertThrowsError(try AttachmentStreamV1.seal(plaintext: Data(), chunkSize: size)) {
                XCTAssertEqual($0 as? AttachmentStreamError, .invalidChunkSize)
            }
            var changed = result.stream
            changed.header.chunkSize = size
            assertRejected(changed, key: result.contentKey, error: .invalidChunkSize)
        }
    }

    func testIncrementalSealerAndSinglePassOpen() throws {
        let sealer = try AttachmentStreamSealer(chunkSize: chunkSize)
        let chunks = try [sealer.sealChunk(payload(32)), sealer.sealChunk(payload(1)), sealer.finish()]
        var iterator = chunks.makeIterator()
        let sequence = AnySequence { AnyIterator { iterator.next() } }
        XCTAssertEqual(
            try AttachmentStreamV1.open(header: sealer.header, chunks: sequence, using: sealer.contentKey),
            payload(32) + payload(1)
        )
        XCTAssertThrowsError(try sealer.finish()) { XCTAssertEqual($0 as? AttachmentStreamError, .sealerClosed) }
        XCTAssertThrowsError(try sealer.sealChunk(payload(1))) { XCTAssertEqual($0 as? AttachmentStreamError, .sealerClosed) }
    }

    func testIncrementalSealerRejectsInvalidChunkBoundaries() throws {
        let sealer = try AttachmentStreamSealer(chunkSize: chunkSize)
        XCTAssertThrowsError(try sealer.sealChunk(Data())) { XCTAssertEqual($0 as? AttachmentStreamError, .invalidChunkLength) }
        XCTAssertThrowsError(try sealer.sealChunk(payload(33))) { XCTAssertEqual($0 as? AttachmentStreamError, .invalidChunkLength) }
        _ = try sealer.sealChunk(payload(1))
        XCTAssertThrowsError(try sealer.sealChunk(payload(1))) { XCTAssertEqual($0 as? AttachmentStreamError, .chunkAfterShortChunk) }
        _ = try sealer.finish()
    }
}
