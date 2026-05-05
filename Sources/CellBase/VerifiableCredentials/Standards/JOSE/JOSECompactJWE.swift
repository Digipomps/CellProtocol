// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum JOSECompactJWEError: Error, Equatable {
    case invalidCompactSerialization
}

public struct JOSECompactJWE: Equatable, Sendable {
    public var protectedHeaderSegment: String
    public var encryptedKeySegment: String
    public var initializationVector: Data
    public var ciphertext: Data
    public var authenticationTag: Data

    public init(
        protectedHeaderSegment: String,
        encryptedKeySegment: String,
        initializationVector: Data,
        ciphertext: Data,
        authenticationTag: Data
    ) {
        self.protectedHeaderSegment = protectedHeaderSegment
        self.encryptedKeySegment = encryptedKeySegment
        self.initializationVector = initializationVector
        self.ciphertext = ciphertext
        self.authenticationTag = authenticationTag
    }

    public init(compactSerialization: String) throws {
        let segments = compactSerialization.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 5 else {
            throw JOSECompactJWEError.invalidCompactSerialization
        }

        self.protectedHeaderSegment = String(segments[0])
        self.encryptedKeySegment = String(segments[1])
        self.initializationVector = try JOSEBase64URL.decode(String(segments[2]))
        self.ciphertext = try JOSEBase64URL.decode(String(segments[3]))
        self.authenticationTag = try JOSEBase64URL.decode(String(segments[4]))
    }

    public var compactSerialization: String {
        [
            protectedHeaderSegment,
            encryptedKeySegment,
            JOSEBase64URL.encode(initializationVector),
            JOSEBase64URL.encode(ciphertext),
            JOSEBase64URL.encode(authenticationTag)
        ].joined(separator: ".")
    }

    public var protectedHeaderData: Data? {
        try? JOSEBase64URL.decode(protectedHeaderSegment)
    }
}
