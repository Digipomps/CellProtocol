// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum JOSECompactJWSError: Error, Equatable {
    case invalidCompactSerialization
}

public struct JOSECompactJWS: Equatable, Sendable {
    public var protectedHeaderSegment: String
    public var payloadSegment: String
    public var signatureSegment: String

    public init(
        protectedHeaderSegment: String,
        payloadSegment: String,
        signatureSegment: String
    ) {
        self.protectedHeaderSegment = protectedHeaderSegment
        self.payloadSegment = payloadSegment
        self.signatureSegment = signatureSegment
    }

    public init(compactSerialization: String) throws {
        let segments = compactSerialization.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              !segments[0].isEmpty,
              !segments[1].isEmpty,
              !segments[2].isEmpty else {
            throw JOSECompactJWSError.invalidCompactSerialization
        }

        self.protectedHeaderSegment = String(segments[0])
        self.payloadSegment = String(segments[1])
        self.signatureSegment = String(segments[2])
    }

    public var compactSerialization: String {
        [protectedHeaderSegment, payloadSegment, signatureSegment].joined(separator: ".")
    }

    public var protectedHeaderData: Data? {
        try? JOSEBase64URL.decode(protectedHeaderSegment)
    }

    public var payloadData: Data? {
        try? JOSEBase64URL.decode(payloadSegment)
    }

    public var signatureData: Data? {
        try? JOSEBase64URL.decode(signatureSegment)
    }
}
