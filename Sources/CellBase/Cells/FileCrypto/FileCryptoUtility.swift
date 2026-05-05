// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Crypto
import Foundation

public enum FileCryptoUtilityError: Error, Equatable {
    case invalidCredential
    case credentialMissing
    case invalidEnvelope
    case encryptionFailed
    case decryptionFailed
    case compressionFailed
    case decompressionFailed
}

public enum FileCryptoUtility {
    private static let envelopeMagic = Data("FCRYP01".utf8)

    private struct CredentialResolution {
        let credential: FileCryptoCredential
        let newCredentials: [FileCryptoCredential]
        let credentialWasGenerated: Bool
    }

    public static func seal(request: FileCryptoSealRequest) throws -> FileCryptoSealResponse {
        let resolution = try resolveCredential(for: request)

        let compressedData: Data
        do {
            compressedData = try FileCryptoCompression.compress(request.data, algorithm: request.compression)
        } catch {
            throw FileCryptoUtilityError.compressionFailed
        }

        let keyData = try normalizedSymmetricKeyData(resolution.credential.keyMaterial)
        let symmetricKey = SymmetricKey(data: keyData)
        let authenticatedData = request.associatedData ?? Data()

        let sealedBox: ChaChaPoly.SealedBox
        do {
            switch request.algorithm {
            case .chachaPoly:
                sealedBox = try ChaChaPoly.seal(
                    compressedData,
                    using: symmetricKey,
                    authenticating: authenticatedData
                )
            }
        } catch {
            throw FileCryptoUtilityError.encryptionFailed
        }

        let envelope = FileCryptoEnvelope(
            algorithm: request.algorithm,
            compression: request.compression,
            credentialID: resolution.credential.id,
            originalByteCount: request.data.count,
            compressedByteCount: compressedData.count,
            associatedData: request.associatedData,
            combinedCiphertext: sealedBox.combined
        )

        let encryptedData = try encodeEnvelopeData(envelope)
        return FileCryptoSealResponse(
            encryptedData: encryptedData,
            envelope: envelope,
            resolvedCredentialID: resolution.credential.id,
            newCredentials: resolution.newCredentials,
            credentialWasGenerated: resolution.credentialWasGenerated,
            originalByteCount: request.data.count,
            compressedByteCount: compressedData.count
        )
    }

    public static func open(
        encryptedData: Data,
        credentials: [FileCryptoCredential]
    ) throws -> Data {
        try openResponse(
            encryptedData: encryptedData,
            credentials: credentials
        ).decryptedData
    }

    public static func open(request: FileCryptoOpenRequest) throws -> FileCryptoOpenResponse {
        try openResponse(
            encryptedData: request.encryptedData,
            credentials: request.incomingCredentials
        )
    }

    private static func openResponse(
        encryptedData: Data,
        credentials: [FileCryptoCredential]
    ) throws -> FileCryptoOpenResponse {
        let envelope = try decodeEnvelopeData(encryptedData)
        guard let credential = credentials.first(where: { $0.id == envelope.credentialID }) else {
            throw FileCryptoUtilityError.credentialMissing
        }

        let keyData = try normalizedSymmetricKeyData(credential.keyMaterial)
        let symmetricKey = SymmetricKey(data: keyData)
        let authenticatedData = envelope.associatedData ?? Data()

        let compressedPlaintext: Data
        do {
            switch envelope.algorithm {
            case .chachaPoly:
                let sealedBox = try ChaChaPoly.SealedBox(combined: envelope.combinedCiphertext)
                compressedPlaintext = try ChaChaPoly.open(
                    sealedBox,
                    using: symmetricKey,
                    authenticating: authenticatedData
                )
            }
        } catch {
            throw FileCryptoUtilityError.decryptionFailed
        }

        let decryptedData: Data
        do {
            decryptedData = try FileCryptoCompression.decompress(
                compressedPlaintext,
                algorithm: envelope.compression,
                expectedByteCount: envelope.originalByteCount
            )
        } catch {
            throw FileCryptoUtilityError.decompressionFailed
        }

        return FileCryptoOpenResponse(
            decryptedData: decryptedData,
            envelope: envelope,
            resolvedCredentialID: credential.id,
            originalByteCount: envelope.originalByteCount,
            compressedByteCount: envelope.compressedByteCount
        )
    }

    public static func decodeEnvelopeData(_ encryptedData: Data) throws -> FileCryptoEnvelope {
        guard encryptedData.starts(with: envelopeMagic) else {
            throw FileCryptoUtilityError.invalidEnvelope
        }

        var cursor = envelopeMagic.count
        let version = try readUInt8(from: encryptedData, cursor: &cursor)
        let algorithm = try FileCryptoAlgorithm.fromWireValue(readUInt8(from: encryptedData, cursor: &cursor))
        let compression = try FileCryptoCompressionAlgorithm.fromWireValue(readUInt8(from: encryptedData, cursor: &cursor))
        let credentialIDLength = Int(try readUInt16(from: encryptedData, cursor: &cursor))
        let originalByteCount = Int(try readUInt64(from: encryptedData, cursor: &cursor))
        let compressedByteCount = Int(try readUInt64(from: encryptedData, cursor: &cursor))
        let associatedDataLength = Int(try readUInt32(from: encryptedData, cursor: &cursor))
        let combinedCiphertextLength = Int(try readUInt64(from: encryptedData, cursor: &cursor))

        let credentialIDData = try readData(from: encryptedData, cursor: &cursor, length: credentialIDLength)
        guard let credentialID = String(data: credentialIDData, encoding: .utf8), !credentialID.isEmpty else {
            throw FileCryptoUtilityError.invalidEnvelope
        }

        let associatedData = try readData(from: encryptedData, cursor: &cursor, length: associatedDataLength)
        let combinedCiphertext = try readData(from: encryptedData, cursor: &cursor, length: combinedCiphertextLength)

        guard cursor == encryptedData.count else {
            throw FileCryptoUtilityError.invalidEnvelope
        }

        return FileCryptoEnvelope(
            version: version,
            algorithm: algorithm,
            compression: compression,
            credentialID: credentialID,
            originalByteCount: originalByteCount,
            compressedByteCount: compressedByteCount,
            associatedData: associatedData.isEmpty ? nil : associatedData,
            combinedCiphertext: combinedCiphertext
        )
    }

    static func encodeEnvelopeData(_ envelope: FileCryptoEnvelope) throws -> Data {
        let credentialIDData = Data(envelope.credentialID.utf8)
        guard !credentialIDData.isEmpty else {
            throw FileCryptoUtilityError.invalidEnvelope
        }

        guard let credentialIDLength = UInt16(exactly: credentialIDData.count),
              let associatedDataLength = UInt32(exactly: envelope.associatedData?.count ?? 0),
              let combinedLength = UInt64(exactly: envelope.combinedCiphertext.count),
              let originalByteCount = UInt64(exactly: envelope.originalByteCount),
              let compressedByteCount = UInt64(exactly: envelope.compressedByteCount) else {
            throw FileCryptoUtilityError.invalidEnvelope
        }

        var data = Data()
        data.append(envelopeMagic)
        data.append(envelope.version)
        data.append(envelope.algorithm.wireValue)
        data.append(envelope.compression.wireValue)
        data.append(contentsOf: withUnsafeBytes(of: credentialIDLength.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: originalByteCount.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: compressedByteCount.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: associatedDataLength.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: combinedLength.littleEndian, Array.init))
        data.append(credentialIDData)
        if let associatedData = envelope.associatedData {
            data.append(associatedData)
        }
        data.append(envelope.combinedCiphertext)
        return data
    }

    private static func resolveCredential(for request: FileCryptoSealRequest) throws -> CredentialResolution {
        let normalizedPreferredID = normalize(optionalString: request.preferredCredentialID)

        switch request.credentialMode {
        case .generateNew:
            let generated = generatedCredential(algorithm: request.algorithm)
            return CredentialResolution(
                credential: generated,
                newCredentials: [generated],
                credentialWasGenerated: true
            )
        case .generateIfMissing:
            if let credential = matchingCredential(
                credentials: request.incomingCredentials,
                preferredID: normalizedPreferredID,
                algorithm: request.algorithm
            ) {
                return CredentialResolution(
                    credential: credential,
                    newCredentials: [],
                    credentialWasGenerated: false
                )
            }
            let generated = generatedCredential(algorithm: request.algorithm)
            return CredentialResolution(
                credential: generated,
                newCredentials: [generated],
                credentialWasGenerated: true
            )
        case .reuseIncoming:
            guard let credential = matchingCredential(
                credentials: request.incomingCredentials,
                preferredID: normalizedPreferredID,
                algorithm: request.algorithm
            ) else {
                throw FileCryptoUtilityError.credentialMissing
            }
            return CredentialResolution(
                credential: credential,
                newCredentials: [],
                credentialWasGenerated: false
            )
        }
    }

    private static func matchingCredential(
        credentials: [FileCryptoCredential],
        preferredID: String?,
        algorithm: FileCryptoAlgorithm
    ) -> FileCryptoCredential? {
        let filtered = credentials.filter { credential in
            normalize(optionalString: credential.id) != nil && credential.algorithm == algorithm
        }

        if let preferredID {
            return filtered.first { $0.id == preferredID }
        }

        return filtered.first
    }

    private static func generatedCredential(algorithm: FileCryptoAlgorithm) -> FileCryptoCredential {
        let symmetricKey = SymmetricKey(size: .bits256)
        let keyMaterial = symmetricKey.withUnsafeBytes { Data($0) }
        return FileCryptoCredential(
            id: UUID().uuidString.lowercased(),
            algorithm: algorithm,
            keyMaterial: keyMaterial,
            createdAtEpochMs: currentEpochMs()
        )
    }

    private static func normalizedSymmetricKeyData(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            throw FileCryptoUtilityError.invalidCredential
        }
        if data.count == 32 {
            return data
        }
        return Data(SHA256.hash(data: data))
    }

    private static func currentEpochMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000.0)
    }

    private static func normalize(optionalString: String?) -> String? {
        guard let optionalString else { return nil }
        let trimmed = optionalString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func readUInt8(from data: Data, cursor: inout Int) throws -> UInt8 {
        let chunk = try readData(from: data, cursor: &cursor, length: 1)
        return chunk[chunk.startIndex]
    }

    private static func readUInt16(from data: Data, cursor: inout Int) throws -> UInt16 {
        let chunk = try readData(from: data, cursor: &cursor, length: MemoryLayout<UInt16>.size)
        var value: UInt16 = 0
        _ = withUnsafeMutableBytes(of: &value) { chunk.copyBytes(to: $0) }
        return UInt16(littleEndian: value)
    }

    private static func readUInt32(from data: Data, cursor: inout Int) throws -> UInt32 {
        let chunk = try readData(from: data, cursor: &cursor, length: MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { chunk.copyBytes(to: $0) }
        return UInt32(littleEndian: value)
    }

    private static func readUInt64(from data: Data, cursor: inout Int) throws -> UInt64 {
        let chunk = try readData(from: data, cursor: &cursor, length: MemoryLayout<UInt64>.size)
        var value: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &value) { chunk.copyBytes(to: $0) }
        return UInt64(littleEndian: value)
    }

    private static func readData(from data: Data, cursor: inout Int, length: Int) throws -> Data {
        guard length >= 0, cursor + length <= data.count else {
            throw FileCryptoUtilityError.invalidEnvelope
        }
        let slice = data.subdata(in: cursor..<(cursor + length))
        cursor += length
        return slice
    }
}
