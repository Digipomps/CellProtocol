// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct JOSEJWKSet: Codable, Equatable, Sendable {
    public var keys: [JOSEJWK]

    public init(keys: [JOSEJWK]) {
        self.keys = keys
    }
}

public struct JOSEJWK: Codable, Equatable, Sendable {
    public var keyType: String
    public var keyID: String?
    public var publicKeyUse: String?
    public var keyOperations: [String]?
    public var algorithm: String?
    public var curve: String?
    public var x: String?
    public var y: String?
    public var n: String?
    public var e: String?
    public var x5c: [String]?

    enum CodingKeys: String, CodingKey {
        case keyType = "kty"
        case keyID = "kid"
        case publicKeyUse = "use"
        case keyOperations = "key_ops"
        case algorithm = "alg"
        case curve = "crv"
        case x
        case y
        case n
        case e
        case x5c
    }

    public init(
        keyType: String,
        keyID: String? = nil,
        publicKeyUse: String? = nil,
        keyOperations: [String]? = nil,
        algorithm: String? = nil,
        curve: String? = nil,
        x: String? = nil,
        y: String? = nil,
        n: String? = nil,
        e: String? = nil,
        x5c: [String]? = nil
    ) {
        self.keyType = keyType
        self.keyID = keyID
        self.publicKeyUse = publicKeyUse
        self.keyOperations = keyOperations
        self.algorithm = algorithm
        self.curve = curve
        self.x = x
        self.y = y
        self.n = n
        self.e = e
        self.x5c = x5c
    }

    public var isEncryptionCapable: Bool {
        if let publicKeyUse {
            return publicKeyUse == "enc"
        }
        if let keyOperations {
            return keyOperations.contains("encrypt") || keyOperations.contains("deriveKey")
        }
        return true
    }
}
