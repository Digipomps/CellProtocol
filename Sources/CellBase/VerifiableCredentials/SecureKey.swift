// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum CurveType: String, Sendable  {
    case secp256k1
    case P256 = "P-256"
    case Curve25519
}

enum StringEnumError: Error {
    case decodeError(String)
}

extension CurveType: Codable {
    public init(from decoder: Decoder) throws {
        let singleValueContainer = try decoder.singleValueContainer()
        let value = try singleValueContainer.decode(String.self)
        self = try Self(rawValue: value) ?? { throw StringEnumError.decodeError(value) }()
    }
    
    public func encode(to encoder: Encoder) throws {
        var singleValueContainer = encoder.singleValueContainer()
        try singleValueContainer.encode(self.rawValue)
    }
}

public enum CurveAlgorithm: String, Sendable {
    case ECDSA // For signing
    case EdDSA // For signing
    case ECIES // For encryption
    case EEECC // For encryption
    case ECDH // For key agreement
    case X25519 // For key agreement
    case FHMQV // For key agreement
}

extension CurveAlgorithm: Codable {
    public init(from decoder: Decoder) throws {
        let singleValueContainer = try decoder.singleValueContainer()
        let value = try singleValueContainer.decode(String.self)
        self = try Self(rawValue: value) ?? { throw StringEnumError.decodeError(value) }()
    }
    
    public func encode(to encoder: Encoder) throws {
        var singleValueContainer = encoder.singleValueContainer()
        try singleValueContainer.encode(self.rawValue)
    }
}

public enum KeyUse: String, Sendable {
    case signature
    case encrypt
    case keyAgreement
}

extension KeyUse: Codable {
    public init(from decoder: Decoder) throws {
        let singleValueContainer = try decoder.singleValueContainer()
        let value = try singleValueContainer.decode(String.self)
        self = try Self(rawValue: value) ?? { throw StringEnumError.decodeError(value) }()
    }
    
    public func encode(to encoder: Encoder) throws {
        var singleValueContainer = encoder.singleValueContainer()
        try singleValueContainer.encode(self.rawValue)
    }
}

public struct SecureKey: Codable { // We will have to refactor to limit access
    var date: Date
    
    public var privateKey: Bool
    public let use: KeyUse
    public let algorithm: CurveAlgorithm
    public let size: Int
    
    public let curveType: CurveType
    public let x: Data?
    public let y: Data?
    public let compressedKey: Data? // I guess we'll use the compressed key to start with
    
    public init(date: Date, privateKey: Bool, use: KeyUse, algorithm: CurveAlgorithm, size: Int, curveType: CurveType, x: Data?, y: Data?, compressedKey: Data?) {
        self.date = date
        self.privateKey = privateKey
        self.use = use
        self.algorithm = algorithm
        self.size = size
        self.curveType = curveType
        self.x = x
        self.y = y
        self.compressedKey = compressedKey
    }
}

extension SecureKey: Sendable {
    
}
