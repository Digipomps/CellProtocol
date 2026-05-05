// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Crypto
import Foundation

public enum CellPersistenceCryptoError: Error {
    case missingMasterKey
    case invalidEnvelope
    case decryptionFailed
}

public enum CellPersistenceCrypto {
    private static let envelopeMagic = Data("CELLENC1".utf8)
    private static let masterKeyEnvName = "CELL_PERSISTENCE_MASTER_KEY_B64"

    private struct Envelope: Codable {
        let version: UInt8
        let ownerIdentityUUID: String?
        let combined: Data
    }

    public static func encodeForStorage(
        plaintext: Data,
        uuid: String,
        options: CellStorageWriteOptions
    ) throws -> Data {
        guard options.encryptedAtRestRequired else {
            return plaintext
        }
        guard let masterKey = resolvedMasterKeyData() else {
            throw CellPersistenceCryptoError.missingMasterKey
        }
        let symmetricKey = derivePerCellSymmetricKey(
            masterKey: masterKey,
            ownerIdentityUUID: options.ownerIdentityUUID,
            uuid: uuid
        )
        let aad = additionalAuthenticatedData(ownerIdentityUUID: options.ownerIdentityUUID, uuid: uuid)
        let sealed = try ChaChaPoly.seal(plaintext, using: symmetricKey, authenticating: aad)
        let envelope = Envelope(
            version: 1,
            ownerIdentityUUID: options.ownerIdentityUUID,
            combined: sealed.combined
        )
        let encodedEnvelope = try JSONEncoder().encode(envelope)
        var output = Data()
        output.append(envelopeMagic)
        output.append(encodedEnvelope)
        return output
    }

    public static func decodeFromStorage(stored: Data, uuid: String) throws -> Data {
        guard isEncryptedEnvelope(stored) else {
            return stored
        }
        guard let masterKey = resolvedMasterKeyData() else {
            throw CellPersistenceCryptoError.missingMasterKey
        }

        let envelopeData = stored.dropFirst(envelopeMagic.count)
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(envelopeData))
        guard envelope.version == 1 else {
            throw CellPersistenceCryptoError.invalidEnvelope
        }

        let symmetricKey = derivePerCellSymmetricKey(
            masterKey: masterKey,
            ownerIdentityUUID: envelope.ownerIdentityUUID,
            uuid: uuid
        )
        let aad = additionalAuthenticatedData(ownerIdentityUUID: envelope.ownerIdentityUUID, uuid: uuid)

        do {
            let box = try ChaChaPoly.SealedBox(combined: envelope.combined)
            return try ChaChaPoly.open(box, using: symmetricKey, authenticating: aad)
        } catch {
            throw CellPersistenceCryptoError.decryptionFailed
        }
    }

    public static func isEncryptedEnvelope(_ data: Data) -> Bool {
        data.starts(with: envelopeMagic)
    }

    private static func resolvedMasterKeyData() -> Data? {
        if let configured = CellBase.persistedCellMasterKey, !configured.isEmpty {
            return normalizeToDigestLength(configured)
        }
        if let base64 = ProcessInfo.processInfo.environment[masterKeyEnvName]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let envData = Data(base64Encoded: base64),
           !envData.isEmpty {
            return normalizeToDigestLength(envData)
        }
        return nil
    }

    private static func normalizeToDigestLength(_ data: Data) -> Data {
        if data.count == 32 {
            return data
        }
        return Data(SHA256.hash(data: data))
    }

    private static func derivePerCellSymmetricKey(
        masterKey: Data,
        ownerIdentityUUID: String?,
        uuid: String
    ) -> SymmetricKey {
        var seed = Data()
        seed.append(masterKey)
        seed.append(Data((ownerIdentityUUID ?? "_").utf8))
        seed.append(0x2E)
        seed.append(Data(uuid.utf8))
        let digest = SHA256.hash(data: seed)
        return SymmetricKey(data: Data(digest))
    }

    private static func additionalAuthenticatedData(ownerIdentityUUID: String?, uuid: String) -> Data {
        var aad = Data("cell-persistence-v1".utf8)
        aad.append(0x00)
        aad.append(Data((ownerIdentityUUID ?? "_").utf8))
        aad.append(0x00)
        aad.append(Data(uuid.utf8))
        return aad
    }
}
