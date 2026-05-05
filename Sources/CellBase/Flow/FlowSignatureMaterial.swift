// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

enum FlowSignatureMaterial {
    static func originPayloadSigningData(
        originCell: String,
        originIdentity: String,
        payloadHash: String
    ) throws -> Data {
        let object: [String: String] = [
            "originCell": originCell,
            "originIdentity": originIdentity,
            "payloadHash": payloadHash
        ]

        guard JSONSerialization.isValidJSONObject(object) else {
            throw FlowCanonicalEncodingError.invalidJSONObject
        }

        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
