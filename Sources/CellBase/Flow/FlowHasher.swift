// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import Crypto

public enum FlowHasher {
    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func payloadHash(for flowElement: FlowElement) throws -> String {
        let canonicalData = try FlowCanonicalEncoder.canonicalData(for: flowElement)
        return sha256Hex(canonicalData)
    }

    public static func envelopeHash(for envelope: FlowEnvelope, includingSignature: Bool = false) throws -> String {
        let canonicalData = try FlowCanonicalEncoder.canonicalData(for: envelope, includingSignature: includingSignature)
        return sha256Hex(canonicalData)
    }
}
