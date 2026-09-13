// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import Crypto
@testable import CellBase

final class FileCryptoSecurityTests: XCTestCase {
    func testLegacyEnvelopeRemainsReadableWithExplicitPolicyAndV2CannotDowngrade() throws {
        // Independent pre-v2 writer using a synthetic key and deterministic nonce.
        let plaintext = Data("legacy persisted file".utf8)
        let credential = FileCryptoCredential(id: "legacy", algorithm: .chachaPoly,
            keyMaterial: Data(repeating: 0x42, count: 32), createdAtEpochMs: 0)
        let aad = Data("legacy context".utf8)
        let box = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: credential.keyMaterial),
            nonce: ChaChaPoly.Nonce(data: Data(repeating: 0, count: 12)), authenticating: aad)
        let legacy = FileCryptoEnvelope(version: 1, algorithm: .chachaPoly, compression: .none,
            credentialID: credential.id, originalByteCount: plaintext.count,
            compressedByteCount: plaintext.count, associatedData: aad, combinedCiphertext: box.combined)
        let bytes = try FileCryptoUtility.encodeEnvelopeData(legacy)
        XCTAssertEqual(try FileCryptoUtility.open(encryptedData: bytes, credentials: [credential]), plaintext)
        XCTAssertThrowsError(try FileCryptoUtility.open(encryptedData: bytes, credentials: [credential],
            limits: .init(allowLegacyEnvelope: false)))

        let sealed = try FileCryptoUtility.seal(request: .init(data: plaintext, compression: .none))
        XCTAssertEqual(sealed.envelope.version, 2)
        var downgrade = sealed.encryptedData
        downgrade[7] = 1
        XCTAssertThrowsError(try FileCryptoUtility.open(encryptedData: downgrade, credentials: sealed.newCredentials))
    }

    func testV2AuthenticatesMetadataAndRejectsUnknownVersions() throws {
        let sealed = try FileCryptoUtility.seal(request: .init(data: Data("authenticated".utf8), compression: .none,
                                                              associatedData: Data([0x42])))
        // Version, compression, plaintext length, compressed length, credential ID, user AAD.
        for offset in [7, 9, 12, 20, 40, 40 + sealed.resolvedCredentialID.utf8.count] {
            var bytes = sealed.encryptedData
            bytes[offset] ^= 1
            var credentials = sealed.newCredentials
            if offset == 40 {
                // Same key under the altered ID proves that the ID itself is bound.
                credentials[0].id = try FileCryptoUtility.decodeEnvelopeData(bytes).credentialID
            }
            XCTAssertThrowsError(try FileCryptoUtility.open(encryptedData: bytes, credentials: credentials), "offset \(offset)")
        }
        for version: UInt8 in [0, 3, 255] {
            var bytes = sealed.encryptedData
            bytes[7] = version
            XCTAssertThrowsError(try FileCryptoUtility.decodeEnvelopeData(bytes))
        }
        let emptyAAD = try FileCryptoUtility.seal(request: .init(data: Data(), compression: .none, associatedData: Data()))
        XCTAssertEqual(try FileCryptoUtility.open(encryptedData: emptyAAD.encryptedData, credentials: emptyAAD.newCredentials), Data())
    }
    func testTrustedReadLimitsBoundBothEnvelopeAndPlaintextAndAllowExplicitLargerFiles() throws {
        let plaintext = Data(repeating: 7, count: 4_096)
        let sealed = try FileCryptoUtility.seal(request: FileCryptoSealRequest(data: plaintext, compression: .none))
        let bytes = sealed.encryptedData.count
        XCTAssertThrowsError(try FileCryptoUtility.open(encryptedData: sealed.encryptedData, credentials: sealed.newCredentials,
                                                      limits: .init(maximumEncryptedByteCount: bytes - 1, maximumPlaintextByteCount: plaintext.count)))
        XCTAssertThrowsError(try FileCryptoUtility.open(encryptedData: sealed.encryptedData, credentials: sealed.newCredentials,
                                                      limits: .init(maximumEncryptedByteCount: bytes, maximumPlaintextByteCount: plaintext.count - 1)))
        let opened = try FileCryptoUtility.open(encryptedData: sealed.encryptedData, credentials: sealed.newCredentials,
                                               limits: .init(maximumEncryptedByteCount: bytes, maximumPlaintextByteCount: plaintext.count))
        XCTAssertEqual(opened, plaintext)
        XCTAssertThrowsError(try FileCryptoUtility.open(encryptedData: sealed.encryptedData, credentials: sealed.newCredentials,
                                                      limits: .init(maximumPlaintextByteCount: -1)))
    }

    func testDecompressionCannotExpandPastDeclaredOrHostLimit() throws {
        let data = Data(repeating: 0, count: 512 * 1_024)
        XCTAssertThrowsError(try FileCryptoCompression.decompress(data, algorithm: .none, maximumByteCount: 32))
#if canImport(Compression)
        let compressed = try FileCryptoCompression.compress(data, algorithm: .zlib)
        XCTAssertThrowsError(try FileCryptoCompression.decompress(compressed, algorithm: .zlib, expectedByteCount: 32))
        XCTAssertThrowsError(try FileCryptoCompression.decompress(compressed, algorithm: .zlib, maximumByteCount: 64))
        XCTAssertEqual(try FileCryptoCompression.decompress(compressed, algorithm: .zlib, expectedByteCount: data.count), data)
        XCTAssertThrowsError(try FileCryptoCompression.decompress(compressed.dropLast(), algorithm: .zlib, expectedByteCount: data.count))
#endif
    }

    func testUnrepresentableWireLengthsAndOverflowingSliceLengthAreRejected() throws {
        let sealed = try FileCryptoUtility.seal(request: FileCryptoSealRequest(data: Data("safe".utf8), compression: .none))
        for offset in [12, 20, 32] {
            var malformed = sealed.encryptedData
            malformed.replaceSubrange(offset..<(offset + 8), with: repeatElement(UInt8.max, count: 8))
            XCTAssertThrowsError(try FileCryptoUtility.decodeEnvelopeData(malformed)) { error in
                XCTAssertEqual(error as? FileCryptoUtilityError, .invalidEnvelope)
            }
        }
        var overflowingEnd = sealed.encryptedData
        var hugeLength = UInt64(Int.max).littleEndian
        withUnsafeBytes(of: &hugeLength) { overflowingEnd.replaceSubrange(32..<40, with: $0) }
        XCTAssertThrowsError(try FileCryptoUtility.decodeEnvelopeData(overflowingEnd))
    }

    func testEveryTruncatedEnvelopePrefixIsRejectedAndCompleteDataStillOpens() throws {
        let plaintext = Data("small authenticated plaintext".utf8)
        let sealed = try FileCryptoUtility.seal(request: FileCryptoSealRequest(data: plaintext, compression: .none))
        for count in 0..<sealed.encryptedData.count {
            XCTAssertThrowsError(try FileCryptoUtility.decodeEnvelopeData(sealed.encryptedData.prefix(count)), "prefix \(count)")
        }
        XCTAssertEqual(try FileCryptoUtility.open(encryptedData: sealed.encryptedData, credentials: sealed.newCredentials), plaintext)
    }

    func testEnvelopeCanBeReadFromDataWithNonzeroStartIndex() throws {
        let plaintext = Data("slice-backed input".utf8)
        let sealed = try FileCryptoUtility.seal(request: FileCryptoSealRequest(data: plaintext, compression: .none))
        let prefixed = Data(repeating: 0xAA, count: 64) + sealed.encryptedData
        let slice = prefixed.dropFirst(64)
        XCTAssertNotEqual(slice.startIndex, 0)
        XCTAssertEqual(try FileCryptoUtility.open(encryptedData: slice, credentials: sealed.newCredentials), plaintext)
    }
}
