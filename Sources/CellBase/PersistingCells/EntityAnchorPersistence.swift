// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Shared Apple/Vapor side-file policy. Bind ciphertext to both Cell and file,
/// so a journal cannot be substituted for a snapshot or another Cell's data.
public enum EntityAnchorPersistence {
    public static func requiresEncryption(agreement: Agreement) -> Bool {
        (try? agreement.runtimeLifecycleResolution(nowTick: 0).encryptedAtRestRequired) ?? true
    }

    public static func encode(_ plaintext: Data, cellUUID: String, filename: String,
                              owner: Identity, agreement: Agreement) throws -> Data {
        try CellPersistenceCrypto.encodeForStorage(plaintext: plaintext,
            uuid: binding(cellUUID: cellUUID, filename: filename),
            options: CellStorageWriteOptions(ownerIdentityUUID: owner.uuid,
                encryptedAtRestRequired: requiresEncryption(agreement: agreement)))
    }

    public static func decode(_ stored: Data, cellUUID: String, filename: String) throws -> Data {
        try CellPersistenceCrypto.decodeFromStorage(stored: stored,
            uuid: binding(cellUUID: cellUUID, filename: filename))
    }

    private static func binding(cellUUID: String, filename: String) -> String {
        // Length prefix avoids ambiguous component concatenations.
        "entity-anchor-side-file-v1:\(cellUUID.utf8.count):\(cellUUID):\(filename)"
    }
}
