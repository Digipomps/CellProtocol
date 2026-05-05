// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum JOSEBase64URLError: Error, Equatable {
    case invalidEncoding
}

public enum JOSEBase64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) throws -> Data {
        var normalized = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: normalized) else {
            throw JOSEBase64URLError.invalidEncoding
        }
        return data
    }
}
