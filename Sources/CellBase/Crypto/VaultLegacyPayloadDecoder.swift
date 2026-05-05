// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import CryptoSwift

public enum VaultLegacyPayloadDecoder {
    public static func decrypt(_ encryptedData: Data) throws -> Data {
        let aes = try AES(key: LegacyVaultCipher.key, iv: LegacyVaultCipher.iv)
        let decryptedBytes = try aes.decrypt(Array(encryptedData))
        return Data(decryptedBytes)
    }
}

private enum LegacyVaultCipher {
    static let iv = "kUtY38ej4jRMkjxp"
    static let key = "pBjOLlBLzIMbq6oEQzmdPPHg70nGEvZR"
}
