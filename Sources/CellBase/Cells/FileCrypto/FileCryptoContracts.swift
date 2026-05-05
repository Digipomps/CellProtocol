// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum FileCryptoAlgorithm: String, Codable, Sendable {
    case chachaPoly

    var wireValue: UInt8 {
        switch self {
        case .chachaPoly:
            return 1
        }
    }

    static func fromWireValue(_ value: UInt8) throws -> FileCryptoAlgorithm {
        switch value {
        case 1:
            return .chachaPoly
        default:
            throw FileCryptoUtilityError.invalidEnvelope
        }
    }
}

public enum FileCryptoCompressionAlgorithm: String, Codable, Sendable {
    case none
    case zlib

    var wireValue: UInt8 {
        switch self {
        case .none:
            return 0
        case .zlib:
            return 1
        }
    }

    static func fromWireValue(_ value: UInt8) throws -> FileCryptoCompressionAlgorithm {
        switch value {
        case 0:
            return .none
        case 1:
            return .zlib
        default:
            throw FileCryptoUtilityError.invalidEnvelope
        }
    }
}

public enum FileCryptoCredentialMode: String, Codable, Sendable {
    case generateIfMissing
    case reuseIncoming
    case generateNew
}

public struct FileCryptoCredential: Codable, Equatable, Sendable {
    public var id: String
    public var algorithm: FileCryptoAlgorithm
    public var keyMaterial: Data
    public var createdAtEpochMs: Int
    public var keyVersion: Int
    public var metadata: [String: String]?

    public init(
        id: String,
        algorithm: FileCryptoAlgorithm,
        keyMaterial: Data,
        createdAtEpochMs: Int,
        keyVersion: Int = 1,
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.algorithm = algorithm
        self.keyMaterial = keyMaterial
        self.createdAtEpochMs = createdAtEpochMs
        self.keyVersion = keyVersion
        self.metadata = metadata
    }
}

public struct FileCryptoSealRequest: Codable, Equatable, Sendable {
    public var data: Data
    public var incomingCredentials: [FileCryptoCredential]
    public var algorithm: FileCryptoAlgorithm
    public var compression: FileCryptoCompressionAlgorithm
    public var associatedData: Data?
    public var credentialMode: FileCryptoCredentialMode
    public var preferredCredentialID: String?

    public init(
        data: Data,
        incomingCredentials: [FileCryptoCredential] = [],
        algorithm: FileCryptoAlgorithm = .chachaPoly,
        compression: FileCryptoCompressionAlgorithm = .zlib,
        associatedData: Data? = nil,
        credentialMode: FileCryptoCredentialMode = .generateIfMissing,
        preferredCredentialID: String? = nil
    ) {
        self.data = data
        self.incomingCredentials = incomingCredentials
        self.algorithm = algorithm
        self.compression = compression
        self.associatedData = associatedData
        self.credentialMode = credentialMode
        self.preferredCredentialID = preferredCredentialID
    }
}

public struct FileCryptoOpenRequest: Codable, Equatable, Sendable {
    public var encryptedData: Data
    public var incomingCredentials: [FileCryptoCredential]

    public init(
        encryptedData: Data,
        incomingCredentials: [FileCryptoCredential] = []
    ) {
        self.encryptedData = encryptedData
        self.incomingCredentials = incomingCredentials
    }
}

public struct FileCryptoEnvelope: Codable, Equatable, Sendable {
    public var version: UInt8
    public var algorithm: FileCryptoAlgorithm
    public var compression: FileCryptoCompressionAlgorithm
    public var credentialID: String
    public var originalByteCount: Int
    public var compressedByteCount: Int
    public var associatedData: Data?
    public var combinedCiphertext: Data

    public init(
        version: UInt8 = 1,
        algorithm: FileCryptoAlgorithm,
        compression: FileCryptoCompressionAlgorithm,
        credentialID: String,
        originalByteCount: Int,
        compressedByteCount: Int,
        associatedData: Data?,
        combinedCiphertext: Data
    ) {
        self.version = version
        self.algorithm = algorithm
        self.compression = compression
        self.credentialID = credentialID
        self.originalByteCount = originalByteCount
        self.compressedByteCount = compressedByteCount
        self.associatedData = associatedData
        self.combinedCiphertext = combinedCiphertext
    }
}

public struct FileCryptoSealResponse: Codable, Equatable, Sendable {
    public var encryptedData: Data
    public var envelope: FileCryptoEnvelope
    public var resolvedCredentialID: String
    public var newCredentials: [FileCryptoCredential]
    public var credentialWasGenerated: Bool
    public var originalByteCount: Int
    public var compressedByteCount: Int

    public init(
        encryptedData: Data,
        envelope: FileCryptoEnvelope,
        resolvedCredentialID: String,
        newCredentials: [FileCryptoCredential],
        credentialWasGenerated: Bool,
        originalByteCount: Int,
        compressedByteCount: Int
    ) {
        self.encryptedData = encryptedData
        self.envelope = envelope
        self.resolvedCredentialID = resolvedCredentialID
        self.newCredentials = newCredentials
        self.credentialWasGenerated = credentialWasGenerated
        self.originalByteCount = originalByteCount
        self.compressedByteCount = compressedByteCount
    }
}

public struct FileCryptoOpenResponse: Codable, Equatable, Sendable {
    public var decryptedData: Data
    public var envelope: FileCryptoEnvelope
    public var resolvedCredentialID: String
    public var originalByteCount: Int
    public var compressedByteCount: Int

    public init(
        decryptedData: Data,
        envelope: FileCryptoEnvelope,
        resolvedCredentialID: String,
        originalByteCount: Int,
        compressedByteCount: Int
    ) {
        self.decryptedData = decryptedData
        self.envelope = envelope
        self.resolvedCredentialID = resolvedCredentialID
        self.originalByteCount = originalByteCount
        self.compressedByteCount = compressedByteCount
    }
}

public struct FileCryptoFieldError: Codable, Equatable, Sendable {
    public var field: String
    public var code: String
    public var message: String

    public init(field: String, code: String, message: String) {
        self.field = field
        self.code = code
        self.message = message
    }
}

public struct FileCryptoErrorPayload: Codable, Equatable, Sendable {
    public var status: String
    public var operation: String
    public var code: String
    public var message: String
    public var fieldErrors: [FileCryptoFieldError]

    enum CodingKeys: String, CodingKey {
        case status
        case operation
        case code
        case message
        case fieldErrors = "field_errors"
    }

    public init(
        status: String = "error",
        operation: String,
        code: String,
        message: String,
        fieldErrors: [FileCryptoFieldError] = []
    ) {
        self.status = status
        self.operation = operation
        self.code = code
        self.message = message
        self.fieldErrors = fieldErrors
    }
}
