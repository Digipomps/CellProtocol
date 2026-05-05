// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public final class FileCryptoCell: GeneralCell {
    private enum CodingKeys: String, CodingKey {
        case generalCell
    }

    public required init(owner: Identity) async {
        await super.init(owner: owner)
        await setupPermissions(owner: owner)
        await setupKeys(owner: owner)
    }

    public required init(from decoder: Decoder) throws {
        try super.init(from: decoder)

        Task {
            await setupPermissions(owner: self.owner)
            await setupKeys(owner: self.owner)
        }
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
    }

    private func setupPermissions(owner: Identity) async {
        agreementTemplate.addGrant("rw--", for: "fileCrypto")
    }

    private func setupKeys(owner: Identity) async {
        await addInterceptForGet(requester: owner, key: "fileCrypto.state") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "fileCrypto", for: requester) else { return .string("denied") }
            return self.statePayload()
        }

        await addInterceptForSet(requester: owner, key: "fileCrypto.seal") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "fileCrypto", for: requester) else { return .string("denied") }
            return self.handleSeal(value: value)
        }

        await addInterceptForSet(requester: owner, key: "fileCrypto.open") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "fileCrypto", for: requester) else { return .string("denied") }
            return self.handleOpen(value: value)
        }

        await registerContracts(requester: owner)
    }

    private func statePayload() -> ValueType {
        .object([
            "status": .string("ok"),
            "cell": .string("FileCryptoCell"),
            "operations": .list([
                .string("fileCrypto.seal"),
                .string("fileCrypto.open")
            ]),
            "supportedAlgorithms": .list([
                .string(FileCryptoAlgorithm.chachaPoly.rawValue)
            ]),
            "supportedCompression": .list([
                .string(FileCryptoCompressionAlgorithm.none.rawValue),
                .string(FileCryptoCompressionAlgorithm.zlib.rawValue)
            ]),
            "credentialModes": .list([
                .string(FileCryptoCredentialMode.generateIfMissing.rawValue),
                .string(FileCryptoCredentialMode.reuseIncoming.rawValue),
                .string(FileCryptoCredentialMode.generateNew.rawValue)
            ])
        ])
    }

    private func handleSeal(value: ValueType) -> ValueType {
        let operation = "fileCrypto.seal"

        let request: FileCryptoSealRequest
        do {
            request = try FileCryptoCellCodec.decode(value, as: FileCryptoSealRequest.self)
        } catch {
            return FileCryptoCellCodec.error(
                FileCryptoErrorPayload(
                    operation: operation,
                    code: "validation_error",
                    message: "Invalid payload for file encryption",
                    fieldErrors: [
                        FileCryptoFieldError(
                            field: "request",
                            code: "invalid_payload",
                            message: "Expected FileCryptoSealRequest payload"
                        )
                    ]
                )
            )
        }

        let validationErrors = validate(request: request)
        if !validationErrors.isEmpty {
            return FileCryptoCellCodec.error(
                FileCryptoErrorPayload(
                    operation: operation,
                    code: "validation_error",
                    message: "Validation failed for file encryption request",
                    fieldErrors: validationErrors
                )
            )
        }

        do {
            let response = try FileCryptoUtility.seal(request: normalized(request: request))
            return FileCryptoCellCodec.success(
                operation: operation,
                result: FileCryptoCellCodec.encodeSealResponse(response)
            )
        } catch let error as FileCryptoUtilityError {
            return FileCryptoCellCodec.error(mapUtilityError(error, operation: operation, request: request))
        } catch {
            return FileCryptoCellCodec.error(
                FileCryptoErrorPayload(
                    operation: operation,
                    code: "encryption_failed",
                    message: "File encryption failed"
                )
            )
        }
    }

    private func handleOpen(value: ValueType) -> ValueType {
        let operation = "fileCrypto.open"

        let request: FileCryptoOpenRequest
        do {
            request = try FileCryptoCellCodec.decode(value, as: FileCryptoOpenRequest.self)
        } catch {
            return FileCryptoCellCodec.error(
                FileCryptoErrorPayload(
                    operation: operation,
                    code: "validation_error",
                    message: "Invalid payload for file decryption",
                    fieldErrors: [
                        FileCryptoFieldError(
                            field: "request",
                            code: "invalid_payload",
                            message: "Expected FileCryptoOpenRequest payload"
                        )
                    ]
                )
            )
        }

        let validationErrors = validate(request: request)
        if !validationErrors.isEmpty {
            return FileCryptoCellCodec.error(
                FileCryptoErrorPayload(
                    operation: operation,
                    code: "validation_error",
                    message: "Validation failed for file decryption request",
                    fieldErrors: validationErrors
                )
            )
        }

        do {
            let response = try FileCryptoUtility.open(request: normalized(request: request))
            return FileCryptoCellCodec.success(
                operation: operation,
                result: FileCryptoCellCodec.encodeOpenResponse(response)
            )
        } catch let error as FileCryptoUtilityError {
            return FileCryptoCellCodec.error(mapOpenUtilityError(error, operation: operation))
        } catch {
            return FileCryptoCellCodec.error(
                FileCryptoErrorPayload(
                    operation: operation,
                    code: "decryption_failed",
                    message: "File decryption failed"
                )
            )
        }
    }

    private func validate(request: FileCryptoSealRequest) -> [FileCryptoFieldError] {
        var errors: [FileCryptoFieldError] = []

        if request.credentialMode == .reuseIncoming,
           let preferredID = normalize(optionalString: request.preferredCredentialID),
           !request.incomingCredentials.contains(where: { $0.id == preferredID }) {
            errors.append(
                FileCryptoFieldError(
                    field: "preferredCredentialID",
                    code: "not_found",
                    message: "preferredCredentialID did not match any incoming credential"
                )
            )
        }

        errors.append(contentsOf: validate(credentials: request.incomingCredentials))

        return errors
    }

    private func validate(request: FileCryptoOpenRequest) -> [FileCryptoFieldError] {
        validate(credentials: request.incomingCredentials)
    }

    private func normalized(request: FileCryptoSealRequest) -> FileCryptoSealRequest {
        return FileCryptoSealRequest(
            data: request.data,
            incomingCredentials: normalized(credentials: request.incomingCredentials),
            algorithm: request.algorithm,
            compression: request.compression,
            associatedData: request.associatedData,
            credentialMode: request.credentialMode,
            preferredCredentialID: normalize(optionalString: request.preferredCredentialID)
        )
    }

    private func normalized(request: FileCryptoOpenRequest) -> FileCryptoOpenRequest {
        FileCryptoOpenRequest(
            encryptedData: request.encryptedData,
            incomingCredentials: normalized(credentials: request.incomingCredentials)
        )
    }

    private func mapUtilityError(
        _ error: FileCryptoUtilityError,
        operation: String,
        request: FileCryptoSealRequest
    ) -> FileCryptoErrorPayload {
        switch error {
        case .credentialMissing:
            return FileCryptoErrorPayload(
                operation: operation,
                code: "credential_missing",
                message: "No compatible credential was available for encryption",
                fieldErrors: [
                    FileCryptoFieldError(
                        field: request.preferredCredentialID == nil ? "incomingCredentials" : "preferredCredentialID",
                        code: "not_found",
                        message: request.preferredCredentialID == nil
                            ? "Provide a compatible incoming credential or allow generation"
                            : "Preferred credential was not available"
                    )
                ]
            )
        case .invalidCredential:
            return FileCryptoErrorPayload(
                operation: operation,
                code: "invalid_credential",
                message: "Credential key material was invalid",
                fieldErrors: [
                    FileCryptoFieldError(
                        field: "incomingCredentials",
                        code: "invalid_value",
                        message: "Credential keyMaterial must not be empty"
                    )
                ]
            )
        case .compressionFailed:
            return FileCryptoErrorPayload(
                operation: operation,
                code: "compression_failed",
                message: "Compression failed before encryption"
            )
        case .encryptionFailed:
            return FileCryptoErrorPayload(
                operation: operation,
                code: "encryption_failed",
                message: "ChaChaPoly encryption failed"
            )
        case .invalidEnvelope, .decryptionFailed, .decompressionFailed:
            return FileCryptoErrorPayload(
                operation: operation,
                code: "encryption_failed",
                message: "File encryption failed"
            )
        }
    }

    private func mapOpenUtilityError(
        _ error: FileCryptoUtilityError,
        operation: String
    ) -> FileCryptoErrorPayload {
        switch error {
        case .credentialMissing:
            return FileCryptoErrorPayload(
                operation: operation,
                code: "credential_missing",
                message: "No credential matched the encrypted file envelope",
                fieldErrors: [
                    FileCryptoFieldError(
                        field: "incomingCredentials",
                        code: "not_found",
                        message: "Provide a credential matching the envelope credentialID"
                    )
                ]
            )
        case .invalidCredential:
            return FileCryptoErrorPayload(
                operation: operation,
                code: "invalid_credential",
                message: "Credential key material was invalid",
                fieldErrors: [
                    FileCryptoFieldError(
                        field: "incomingCredentials",
                        code: "invalid_value",
                        message: "Credential keyMaterial must not be empty"
                    )
                ]
            )
        case .invalidEnvelope:
            return FileCryptoErrorPayload(
                operation: operation,
                code: "invalid_envelope",
                message: "Encrypted data did not contain a valid file crypto envelope",
                fieldErrors: [
                    FileCryptoFieldError(
                        field: "encryptedData",
                        code: "invalid_value",
                        message: "Expected FileCrypto envelope bytes"
                    )
                ]
            )
        case .decryptionFailed:
            return FileCryptoErrorPayload(
                operation: operation,
                code: "decryption_failed",
                message: "ChaChaPoly decryption failed"
            )
        case .decompressionFailed:
            return FileCryptoErrorPayload(
                operation: operation,
                code: "decompression_failed",
                message: "Decompression failed after decryption"
            )
        case .compressionFailed, .encryptionFailed:
            return FileCryptoErrorPayload(
                operation: operation,
                code: "decryption_failed",
                message: "File decryption failed"
            )
        }
    }

    private func validate(credentials: [FileCryptoCredential]) -> [FileCryptoFieldError] {
        var errors: [FileCryptoFieldError] = []

        for (index, credential) in credentials.enumerated() {
            if normalize(optionalString: credential.id) == nil {
                errors.append(
                    FileCryptoFieldError(
                        field: "incomingCredentials[\(index)].id",
                        code: "missing",
                        message: "Credential id is required"
                    )
                )
            }
            if credential.keyMaterial.isEmpty {
                errors.append(
                    FileCryptoFieldError(
                        field: "incomingCredentials[\(index)].keyMaterial",
                        code: "missing",
                        message: "Credential keyMaterial is required"
                    )
                )
            }
        }

        return errors
    }

    private func normalized(credentials: [FileCryptoCredential]) -> [FileCryptoCredential] {
        credentials.map { credential in
            FileCryptoCredential(
                id: credential.id.trimmingCharacters(in: .whitespacesAndNewlines),
                algorithm: credential.algorithm,
                keyMaterial: credential.keyMaterial,
                createdAtEpochMs: credential.createdAtEpochMs,
                keyVersion: credential.keyVersion,
                metadata: credential.metadata
            )
        }
    }

    private func normalize(optionalString: String?) -> String? {
        guard let optionalString else { return nil }
        let trimmed = optionalString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func registerContracts(requester: Identity) async {
        await registerExploreContract(
            requester: requester,
            key: "fileCrypto.state",
            method: .get,
            input: .null,
            returns: Self.stateSchema(),
            permissions: ["r---"],
            required: false,
            description: .string("Reports the file crypto cell status and the supported algorithms, compression modes, and credential modes.")
        )

        await registerExploreContract(
            requester: requester,
            key: "fileCrypto.seal",
            method: .set,
            input: Self.sealRequestSchema(),
            returns: Self.operationResponseSchema(
                operation: "fileCrypto.seal",
                result: Self.sealResponseSchema()
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Encrypts binary data and returns the encrypted payload, envelope metadata, and any generated credentials.")
        )

        await registerExploreContract(
            requester: requester,
            key: "fileCrypto.open",
            method: .set,
            input: Self.openRequestSchema(),
            returns: Self.operationResponseSchema(
                operation: "fileCrypto.open",
                result: Self.openResponseSchema()
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Decrypts a sealed file payload using compatible credentials and returns the decrypted bytes plus envelope metadata.")
        )
    }

    private static func stateSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "cell": ExploreContract.schema(type: "string"),
                "operations": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "supportedAlgorithms": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "supportedCompression": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "credentialModes": ExploreContract.listSchema(item: ExploreContract.schema(type: "string"))
            ],
            requiredKeys: ["status", "cell", "operations"],
            description: "File crypto runtime capabilities."
        )
    }

    private static func credentialSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "id": ExploreContract.schema(type: "string"),
                "algorithm": ExploreContract.schema(type: "string"),
                "keyMaterial": ExploreContract.schema(type: "data"),
                "createdAtEpochMs": ExploreContract.schema(type: "integer"),
                "keyVersion": ExploreContract.schema(type: "integer"),
                "metadata": ExploreContract.schema(type: "object")
            ],
            requiredKeys: ["id", "algorithm", "keyMaterial", "createdAtEpochMs"],
            description: "Credential material used to encrypt or decrypt a file payload."
        )
    }

    private static func sealRequestSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "data": ExploreContract.schema(type: "data"),
                "incomingCredentials": ExploreContract.listSchema(item: credentialSchema()),
                "algorithm": ExploreContract.schema(type: "string"),
                "compression": ExploreContract.schema(type: "string"),
                "associatedData": ExploreContract.schema(type: "data"),
                "credentialMode": ExploreContract.schema(type: "string"),
                "preferredCredentialID": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["data"],
            description: "Encryption request with optional incoming credentials and credential handling mode."
        )
    }

    private static func openRequestSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "encryptedData": ExploreContract.schema(type: "data"),
                "incomingCredentials": ExploreContract.listSchema(item: credentialSchema())
            ],
            requiredKeys: ["encryptedData"],
            description: "Decryption request carrying the sealed bytes and candidate credentials."
        )
    }

    private static func envelopeSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "version": ExploreContract.schema(type: "integer"),
                "algorithm": ExploreContract.schema(type: "string"),
                "compression": ExploreContract.schema(type: "string"),
                "credentialID": ExploreContract.schema(type: "string"),
                "originalByteCount": ExploreContract.schema(type: "integer"),
                "compressedByteCount": ExploreContract.schema(type: "integer"),
                "associatedData": ExploreContract.schema(type: "data"),
                "combinedCiphertext": ExploreContract.schema(type: "data")
            ],
            requiredKeys: ["version", "algorithm", "compression", "credentialID", "combinedCiphertext"],
            description: "Structured metadata stored alongside the encrypted file bytes."
        )
    }

    private static func sealResponseSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "encryptedData": ExploreContract.schema(type: "data"),
                "envelope": envelopeSchema(),
                "resolvedCredentialID": ExploreContract.schema(type: "string"),
                "newCredentials": ExploreContract.listSchema(item: credentialSchema()),
                "credentialWasGenerated": ExploreContract.schema(type: "bool"),
                "originalByteCount": ExploreContract.schema(type: "integer"),
                "compressedByteCount": ExploreContract.schema(type: "integer")
            ],
            requiredKeys: ["encryptedData", "envelope", "resolvedCredentialID", "newCredentials", "credentialWasGenerated"],
            description: "Successful encryption result."
        )
    }

    private static func openResponseSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "decryptedData": ExploreContract.schema(type: "data"),
                "envelope": envelopeSchema(),
                "resolvedCredentialID": ExploreContract.schema(type: "string"),
                "originalByteCount": ExploreContract.schema(type: "integer"),
                "compressedByteCount": ExploreContract.schema(type: "integer")
            ],
            requiredKeys: ["decryptedData", "envelope", "resolvedCredentialID"],
            description: "Successful decryption result."
        )
    }

    private static func fieldErrorSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "field": ExploreContract.schema(type: "string"),
                "code": ExploreContract.schema(type: "string"),
                "message": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["field", "code", "message"],
            description: "Structured validation error for a single request field."
        )
    }

    private static func errorSchema(operation: String) -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "operation": ExploreContract.schema(type: "string", description: operation),
                "code": ExploreContract.schema(type: "string"),
                "message": ExploreContract.schema(type: "string"),
                "field_errors": ExploreContract.listSchema(item: fieldErrorSchema())
            ],
            requiredKeys: ["status", "operation", "code", "message"],
            description: "Structured error response for a file crypto operation."
        )
    }

    private static func successEnvelopeSchema(result: ValueType, operation: String) -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "operation": ExploreContract.schema(type: "string", description: operation),
                "result": result
            ],
            requiredKeys: ["status", "operation", "result"],
            description: "Successful file crypto response envelope."
        )
    }

    private static func operationResponseSchema(operation: String, result: ValueType) -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                successEnvelopeSchema(result: result, operation: operation),
                errorSchema(operation: operation)
            ],
            description: "Returns either a successful result envelope or a structured error payload."
        )
    }
}
