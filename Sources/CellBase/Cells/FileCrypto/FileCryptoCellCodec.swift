// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

enum FileCryptoCellCodec {
    static func decode<T: Decodable>(_ value: ValueType, as type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func success(operation: String, result: ValueType) -> ValueType {
        .object([
            "status": .string("ok"),
            "operation": .string(operation),
            "result": result
        ])
    }

    static func encodeSealResponse(_ response: FileCryptoSealResponse) -> ValueType {
        .object([
            "encryptedData": .data(response.encryptedData),
            "envelope": encodeEnvelope(response.envelope),
            "resolvedCredentialID": .string(response.resolvedCredentialID),
            "newCredentials": .list(response.newCredentials.map(encodeCredential)),
            "credentialWasGenerated": .bool(response.credentialWasGenerated),
            "originalByteCount": .integer(response.originalByteCount),
            "compressedByteCount": .integer(response.compressedByteCount)
        ])
    }

    static func encodeOpenResponse(_ response: FileCryptoOpenResponse) -> ValueType {
        .object([
            "decryptedData": .data(response.decryptedData),
            "envelope": encodeEnvelope(response.envelope),
            "resolvedCredentialID": .string(response.resolvedCredentialID),
            "originalByteCount": .integer(response.originalByteCount),
            "compressedByteCount": .integer(response.compressedByteCount)
        ])
    }

    static func encodeEnvelope(_ envelope: FileCryptoEnvelope) -> ValueType {
        var object: Object = [
            "version": .integer(Int(envelope.version)),
            "algorithm": .string(envelope.algorithm.rawValue),
            "compression": .string(envelope.compression.rawValue),
            "credentialID": .string(envelope.credentialID),
            "originalByteCount": .integer(envelope.originalByteCount),
            "compressedByteCount": .integer(envelope.compressedByteCount),
            "combinedCiphertext": .data(envelope.combinedCiphertext)
        ]

        if let associatedData = envelope.associatedData {
            object["associatedData"] = .data(associatedData)
        }

        return .object(object)
    }

    static func encodeCredential(_ credential: FileCryptoCredential) -> ValueType {
        var object: Object = [
            "id": .string(credential.id),
            "algorithm": .string(credential.algorithm.rawValue),
            "keyMaterial": .data(credential.keyMaterial),
            "createdAtEpochMs": .integer(credential.createdAtEpochMs),
            "keyVersion": .integer(credential.keyVersion)
        ]

        if let metadata = credential.metadata, !metadata.isEmpty {
            object["metadata"] = .object(
                Object(propertyValues: metadata.mapValues(ValueType.string))
            )
        }

        return .object(object)
    }

    static func error(_ payload: FileCryptoErrorPayload) -> ValueType {
        .object([
            "status": .string(payload.status),
            "operation": .string(payload.operation),
            "code": .string(payload.code),
            "message": .string(payload.message),
            "field_errors": .list(
                payload.fieldErrors.map { entry in
                    .object([
                        "field": .string(entry.field),
                        "code": .string(entry.code),
                        "message": .string(entry.message)
                    ])
                }
            )
        ])
    }
}
