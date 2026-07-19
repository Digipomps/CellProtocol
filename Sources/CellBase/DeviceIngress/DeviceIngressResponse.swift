// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Requester-owned verification input. It is produced from the exact locally
/// verified challenge/request/body tuple before transport and is never decoded
/// from a server response.
public struct DeviceIngressResponseExpectation: Codable, Equatable, Sendable {
    public static let currentSchema = "cellprotocol.device-ingress.response-expectation.v1"

    public let schema: String
    public let operation: DeviceIngressOperation
    public let admissionID: String
    public let requestSHA256: Data
    public let challengeSHA256: Data
    public let bodySHA256: Data
    public let subjectIdentityUUID: String
    public let subjectSigningKeyFingerprint: String
    public let targetCellUUID: String
    public let targetOwnerIdentityUUID: String
    public let targetOwnerSigningKeyFingerprint: String
    public let signedAgreementSHA256: Data
    public let authorityGeneration: UInt64
    public let revocationLedgerID: String
    public let revocationGeneration: UInt64
    public let contentPolicy: DeviceIngressContentPolicy
    public let requestIssuedAtMilliseconds: Int64
    public let requestExpiresAtMilliseconds: Int64

    init(verifiedPair: DeviceIngressVerifiedPair) {
        let request = verifiedPair.request
        schema = Self.currentSchema
        operation = request.operation
        admissionID = DeviceIngressCanonicalWire.base64URL(verifiedPair.requestSHA256)
        requestSHA256 = verifiedPair.requestSHA256
        challengeSHA256 = verifiedPair.challengeSHA256
        bodySHA256 = verifiedPair.bodySHA256
        subjectIdentityUUID = request.subject.uuid
        subjectSigningKeyFingerprint =
            DeviceIngressEnvelopeVerifier.signingKeyFingerprint(for: request.subject) ?? ""
        targetCellUUID = request.authority.targetCellUUID
        targetOwnerIdentityUUID = request.authority.targetOwnerIdentityUUID
        targetOwnerSigningKeyFingerprint =
            request.authority.targetOwnerSigningKeyFingerprint
        signedAgreementSHA256 = request.authority.signedAgreementSHA256
        authorityGeneration = request.authority.authorityGeneration
        revocationLedgerID = request.authority.revocationLedgerID
        revocationGeneration = request.authority.revocationGeneration
        contentPolicy = request.authority.contentPolicy
        requestIssuedAtMilliseconds = request.issuedAtMilliseconds
        requestExpiresAtMilliseconds = request.expiresAtMilliseconds
    }

    init(admissionRecord record: DeviceIngressAdmissionRecord) {
        schema = Self.currentSchema
        operation = record.operation
        admissionID = record.admissionID
        requestSHA256 = record.requestSHA256
        challengeSHA256 = record.challengeSHA256
        bodySHA256 = record.bodySHA256
        subjectIdentityUUID = record.subjectIdentityUUID
        subjectSigningKeyFingerprint = record.subjectSigningKeyFingerprint
        targetCellUUID = record.targetCellUUID
        targetOwnerIdentityUUID = record.targetOwnerIdentityUUID
        targetOwnerSigningKeyFingerprint = record.targetOwnerSigningKeyFingerprint
        signedAgreementSHA256 = record.signedAgreementSHA256
        authorityGeneration = record.authorityGeneration
        revocationLedgerID = record.revocationLedgerID
        revocationGeneration = record.revocationGeneration
        contentPolicy = record.contentPolicy
        requestIssuedAtMilliseconds = record.issuedAtMilliseconds
        requestExpiresAtMilliseconds = record.expiresAtMilliseconds
    }
}

public struct DeviceIngressPreparedRequest: Sendable {
    public let canonicalRequestData: Data
    public let expectation: DeviceIngressResponseExpectation

    init(
        canonicalRequestData: Data,
        expectation: DeviceIngressResponseExpectation
    ) {
        self.canonicalRequestData = canonicalRequestData
        self.expectation = expectation
    }
}

/// The only operation-result variants accepted from a resolver-selected
/// DeviceIngress authority Cell. A transport carries the signed response bytes
/// verbatim and never constructs one of these values.
public enum DeviceIngressOperationResultKind: String, Codable, Sendable {
    case noPayload = "no_payload"
    case registrationReceipt = "registration_receipt"
    case resolvedTicket = "resolved_ticket"
    case submissionReceipt = "submission_receipt"
}

public enum DeviceIngressRegistrationState: String, Codable, Sendable {
    case activeConsented = "active_consented"
    case revoked = "revoked"
}

/// Durable, non-secret projection of a DeviceRegistration Cell mutation.
///
/// The raw APNS token and any stable derivative are deliberately absent. The
/// outer request/body digest already binds exactly what the target Cell
/// committed without adding a cross-response device correlator.
public struct DeviceIngressRegistrationReceipt: Codable, Equatable, Sendable {
    public static let currentSchema = "cellprotocol.device-ingress.registration-receipt.v1"
    public static let durableSameCellRegistration =
        "same_cell_durable_device_registration"

    public let schema: String
    public let registrationID: String
    public let deviceIdentityUUID: String
    public let registrationGeneration: UInt64
    public let durableSequence: UInt64
    public let state: DeviceIngressRegistrationState
    public let registrationRecordSHA256: Data
    public let committedAtMilliseconds: Int64
    public let persistenceSemantics: String

    @_spi(HAVENRuntime)
    public init(
        schema: String = Self.currentSchema,
        registrationID: String,
        deviceIdentityUUID: String,
        registrationGeneration: UInt64,
        durableSequence: UInt64,
        state: DeviceIngressRegistrationState,
        registrationRecordSHA256: Data,
        committedAtMilliseconds: Int64,
        persistenceSemantics: String = Self.durableSameCellRegistration
    ) {
        self.schema = schema
        self.registrationID = registrationID
        self.deviceIdentityUUID = deviceIdentityUUID
        self.registrationGeneration = registrationGeneration
        self.durableSequence = durableSequence
        self.state = state
        self.registrationRecordSHA256 = registrationRecordSHA256
        self.committedAtMilliseconds = committedAtMilliseconds
        self.persistenceSemantics = persistenceSemantics
    }
}

public enum DeviceIngressResolvedPayloadPrivacyPolicy: String, Codable, Sendable {
    /// The resolver-selected Cell has validated the payload against the exact
    /// content contract and its own policy before committing it. CellProtocol
    /// binds that assertion; it does not guess at secrets by parsing opaque
    /// application bytes.
    case cellVerifiedNoTransportCredentials =
        "cell_verified_no_transport_credentials_or_private_route"
}

/// A bounded application payload selected by DeviceCallbackBridge.
///
/// The exact payload contract is content-addressed. CellProtocol verifies the
/// byte bound and digests, while the resolver-selected Cell verifies the
/// content schema and the explicit privacy policy. No APNS token or private
/// route field exists in the protocol response type.
public struct DeviceIngressResolvedTicket: Codable, Equatable, Sendable {
    public static let currentSchema = "cellprotocol.device-ingress.resolved-ticket.v1"
    public static let maximumPayloadBytes = 16_384
    public static let maximumTicketLifetimeMilliseconds: Int64 = 24 * 60 * 60 * 1_000

    public let schema: String
    public let ticketID: String
    public let ticketSequence: UInt64
    public let recipientDeviceIdentityUUID: String
    public let payloadSchema: String
    public let payloadContentContractSHA256: Data
    public let privacyPolicy: DeviceIngressResolvedPayloadPrivacyPolicy
    public let canonicalPayload: Data
    public let payloadSHA256: Data
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64

    @_spi(HAVENRuntime)
    public init(
        schema: String = Self.currentSchema,
        ticketID: String,
        ticketSequence: UInt64,
        recipientDeviceIdentityUUID: String,
        payloadSchema: String,
        payloadContentContractSHA256: Data,
        privacyPolicy: DeviceIngressResolvedPayloadPrivacyPolicy =
            .cellVerifiedNoTransportCredentials,
        canonicalPayload: Data,
        payloadSHA256: Data? = nil,
        issuedAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64
    ) {
        self.schema = schema
        self.ticketID = ticketID
        self.ticketSequence = ticketSequence
        self.recipientDeviceIdentityUUID = recipientDeviceIdentityUUID
        self.payloadSchema = payloadSchema
        self.payloadContentContractSHA256 = payloadContentContractSHA256
        self.privacyPolicy = privacyPolicy
        self.canonicalPayload = canonicalPayload
        self.payloadSHA256 = payloadSHA256
            ?? DeviceIngressCanonicalWire.sha256(canonicalPayload)
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
    }
}

public enum DeviceIngressSubmissionDisposition: String, Codable, Sendable {
    case accepted
    case rejected
}

/// Durable acknowledgement that DeviceCallbackBridge stored one submitted
/// callback result. The callback result itself is not echoed in the response.
public struct DeviceIngressSubmissionReceipt: Codable, Equatable, Sendable {
    public static let currentSchema = "cellprotocol.device-ingress.submission-receipt.v1"
    public static let durableSameCellSubmission =
        "same_cell_durable_callback_submission"

    public let schema: String
    public let ticketID: String
    public let ticketSequence: UInt64
    public let submittedBodySHA256: Data
    public let resultRecordSHA256: Data
    public let durableSequence: UInt64
    public let disposition: DeviceIngressSubmissionDisposition
    public let committedAtMilliseconds: Int64
    public let persistenceSemantics: String

    @_spi(HAVENRuntime)
    public init(
        schema: String = Self.currentSchema,
        ticketID: String,
        ticketSequence: UInt64,
        submittedBodySHA256: Data,
        resultRecordSHA256: Data,
        durableSequence: UInt64,
        disposition: DeviceIngressSubmissionDisposition,
        committedAtMilliseconds: Int64,
        persistenceSemantics: String = Self.durableSameCellSubmission
    ) {
        self.schema = schema
        self.ticketID = ticketID
        self.ticketSequence = ticketSequence
        self.submittedBodySHA256 = submittedBodySHA256
        self.resultRecordSHA256 = resultRecordSHA256
        self.durableSequence = durableSequence
        self.disposition = disposition
        self.committedAtMilliseconds = committedAtMilliseconds
        self.persistenceSemantics = persistenceSemantics
    }
}

/// A canonical, operation-specific result produced inside the target Cell's
/// serialized mutation. Exactly one typed payload is present, except that a
/// resolve operation may explicitly report `no_payload`.
public struct DeviceIngressOperationResult: Codable, Equatable, Sendable {
    public static let currentSchema = "cellprotocol.device-ingress.operation-result.v1"
    public static let maximumEncodedBytes = 32_768

    public let schema: String
    public let operation: DeviceIngressOperation
    public let kind: DeviceIngressOperationResultKind
    public let registrationReceipt: DeviceIngressRegistrationReceipt?
    public let resolvedTicket: DeviceIngressResolvedTicket?
    public let submissionReceipt: DeviceIngressSubmissionReceipt?

    private init(
        operation: DeviceIngressOperation,
        kind: DeviceIngressOperationResultKind,
        registrationReceipt: DeviceIngressRegistrationReceipt? = nil,
        resolvedTicket: DeviceIngressResolvedTicket? = nil,
        submissionReceipt: DeviceIngressSubmissionReceipt? = nil
    ) {
        schema = Self.currentSchema
        self.operation = operation
        self.kind = kind
        self.registrationReceipt = registrationReceipt
        self.resolvedTicket = resolvedTicket
        self.submissionReceipt = submissionReceipt
    }

    @_spi(HAVENRuntime)
    public static func registration(
        _ receipt: DeviceIngressRegistrationReceipt
    ) -> Self {
        Self(
            operation: .register,
            kind: .registrationReceipt,
            registrationReceipt: receipt
        )
    }

    @_spi(HAVENRuntime)
    public static func resolvedTicket(_ ticket: DeviceIngressResolvedTicket) -> Self {
        Self(operation: .resolve, kind: .resolvedTicket, resolvedTicket: ticket)
    }

    @_spi(HAVENRuntime)
    public static func noResolvedPayload() -> Self {
        Self(operation: .resolve, kind: .noPayload)
    }

    @_spi(HAVENRuntime)
    public static func submission(_ receipt: DeviceIngressSubmissionReceipt) -> Self {
        Self(
            operation: .submit,
            kind: .submissionReceipt,
            submissionReceipt: receipt
        )
    }

    public func canonicalData() throws -> Data {
        let data = try DeviceIngressCanonicalWire.canonicalData(
            for: self,
            excludingTopLevelKeys: []
        )
        guard data.count <= Self.maximumEncodedBytes else {
            throw DeviceIngressResponseValidationError.operationResultTooLarge
        }
        return data
    }
}

/// Target-Cell signed, transport-neutral response. The nested mutation receipt
/// and operation result make the response self-contained for client
/// verification. `proof` is omitted from signing material.
public struct DeviceIngressOperationResponse: Codable, Equatable, Sendable,
    CanonicalPayloadSignable {
    public static let currentSchema = "cellprotocol.device-ingress.operation-response.v1"
    public static let maximumEncodedBytes = 65_536
    public static let maximumJSONSafeTimestampMilliseconds: Int64 =
        DeviceIngressEnvelope.maximumJSONSafeTimestampMilliseconds

    public let schema: String
    public let responseID: String
    public let operation: DeviceIngressOperation
    public let admissionID: String
    public let requestSHA256: Data
    public let challengeSHA256: Data
    public let bodySHA256: Data
    public let mutationReceiptSHA256: Data
    public let operationResultSHA256: Data
    public let targetCellUUID: String
    public let targetOwnerIdentityUUID: String
    public let targetOwnerSigningKeyFingerprint: String
    public let subjectIdentityUUID: String
    public let subjectSigningKeyFingerprint: String
    public let signedAgreementSHA256: Data
    public let authorityGeneration: UInt64
    public let revocationLedgerID: String
    public let revocationGeneration: UInt64
    public let contentPolicySHA256: Data
    public let mutationReceipt: DeviceIngressMutationReceipt
    public let result: DeviceIngressOperationResult
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let signer: IdentityPublicKeyDescriptor
    public var proof: DeviceIngressIdentityProof?

    init(
        responseID: String,
        operation: DeviceIngressOperation,
        admissionID: String,
        requestSHA256: Data,
        challengeSHA256: Data,
        bodySHA256: Data,
        mutationReceiptSHA256: Data,
        operationResultSHA256: Data,
        targetCellUUID: String,
        targetOwnerIdentityUUID: String,
        targetOwnerSigningKeyFingerprint: String,
        subjectIdentityUUID: String,
        subjectSigningKeyFingerprint: String,
        signedAgreementSHA256: Data,
        authorityGeneration: UInt64,
        revocationLedgerID: String,
        revocationGeneration: UInt64,
        contentPolicySHA256: Data,
        mutationReceipt: DeviceIngressMutationReceipt,
        result: DeviceIngressOperationResult,
        issuedAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64,
        signer: IdentityPublicKeyDescriptor,
        proof: DeviceIngressIdentityProof? = nil
    ) {
        schema = Self.currentSchema
        self.responseID = responseID
        self.operation = operation
        self.admissionID = admissionID
        self.requestSHA256 = requestSHA256
        self.challengeSHA256 = challengeSHA256
        self.bodySHA256 = bodySHA256
        self.mutationReceiptSHA256 = mutationReceiptSHA256
        self.operationResultSHA256 = operationResultSHA256
        self.targetCellUUID = targetCellUUID
        self.targetOwnerIdentityUUID = targetOwnerIdentityUUID
        self.targetOwnerSigningKeyFingerprint = targetOwnerSigningKeyFingerprint
        self.subjectIdentityUUID = subjectIdentityUUID
        self.subjectSigningKeyFingerprint = subjectSigningKeyFingerprint
        self.signedAgreementSHA256 = signedAgreementSHA256
        self.authorityGeneration = authorityGeneration
        self.revocationLedgerID = revocationLedgerID
        self.revocationGeneration = revocationGeneration
        self.contentPolicySHA256 = contentPolicySHA256
        self.mutationReceipt = mutationReceipt
        self.result = result
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.signer = signer
        self.proof = proof
    }

    public func canonicalPayloadData() throws -> Data {
        try DeviceIngressCanonicalWire.canonicalData(
            for: self,
            excludingTopLevelKeys: ["proof"]
        )
    }

    public func canonicalWireData() throws -> Data {
        let data = try DeviceIngressCanonicalWire.canonicalData(
            for: self,
            excludingTopLevelKeys: []
        )
        guard data.count <= Self.maximumEncodedBytes else {
            throw DeviceIngressResponseValidationError.responseTooLarge
        }
        return data
    }
}

public enum DeviceIngressResponseValidationError: Error, Equatable, Sendable {
    case emptyResponse
    case responseTooLarge
    case malformedResponse
    case nonCanonicalResponse
    case wrongSchema
    case invalidIdentifier
    case invalidDigest
    case invalidGeneration
    case invalidTimestamp
    case invalidSigner
    case invalidProof
    case operationResultTooLarge
    case operationResultMismatch
    case invalidRegistrationReceipt
    case invalidResolvedTicket
    case invalidSubmissionReceipt
    case admissionBindingMismatch
    case mutationReceiptMismatch
    case responseIDMismatch
    case responseNotDurable
}

public enum DeviceIngressOperationResponseFactory {
    /// Called only by the resolver-selected target Cell while its serialized
    /// mutation is still being committed. The returned bytes must be persisted
    /// with the mutation before
    /// `commitOrReturnExistingDeviceIngressMutation` reports success.
    @_spi(HAVENRuntime)
    public static func sign(
        command: DeviceIngressMutationCommand,
        mutationReceipt: DeviceIngressMutationReceipt,
        result: DeviceIngressOperationResult,
        signer: Identity
    ) async throws -> Data {
        let resultData = try result.canonicalData()
        let resultSHA256 = DeviceIngressCanonicalWire.sha256(resultData)
        let receiptData = try mutationReceipt.canonicalData()
        let receiptSHA256 = DeviceIngressCanonicalWire.sha256(receiptData)
        guard let signerDescriptor = DeviceIngressIdentityDescriptor.publicDescriptor(
            for: signer
        ),
              signerDescriptor.uuid == mutationReceipt.targetOwnerIdentityUUID,
              signer.signingPublicKeyFingerprint
                == mutationReceipt.targetOwnerSigningKeyFingerprint else {
            throw DeviceIngressResponseValidationError.invalidSigner
        }
        let contentPolicySHA256 = try command.admissionRecord.contentPolicy.canonicalSHA256()
        let response = DeviceIngressOperationResponse(
            responseID: mutationReceipt.responseID,
            operation: command.admissionRecord.operation,
            admissionID: command.admissionRecord.admissionID,
            requestSHA256: command.admissionRecord.requestSHA256,
            challengeSHA256: command.admissionRecord.challengeSHA256,
            bodySHA256: command.admissionRecord.bodySHA256,
            mutationReceiptSHA256: receiptSHA256,
            operationResultSHA256: resultSHA256,
            targetCellUUID: command.admissionRecord.targetCellUUID,
            targetOwnerIdentityUUID: command.admissionRecord.targetOwnerIdentityUUID,
            targetOwnerSigningKeyFingerprint:
                command.admissionRecord.targetOwnerSigningKeyFingerprint,
            subjectIdentityUUID: command.admissionRecord.subjectIdentityUUID,
            subjectSigningKeyFingerprint:
                command.admissionRecord.subjectSigningKeyFingerprint,
            signedAgreementSHA256: command.admissionRecord.signedAgreementSHA256,
            authorityGeneration: command.admissionRecord.authorityGeneration,
            revocationLedgerID: command.admissionRecord.revocationLedgerID,
            revocationGeneration: command.admissionRecord.revocationGeneration,
            contentPolicySHA256: contentPolicySHA256,
            mutationReceipt: mutationReceipt,
            result: result,
            issuedAtMilliseconds: mutationReceipt.committedAtMilliseconds,
            expiresAtMilliseconds: command.admissionRecord.expiresAtMilliseconds,
            signer: signerDescriptor
        )
        try DeviceIngressOperationResponseVerifier.validateUnsignedResponse(
            response,
            expectation: DeviceIngressResponseExpectation(
                admissionRecord: command.admissionRecord
            )
        )
        var signed = response
        let signingData = try signed.canonicalPayloadData()
        guard let signature = try await signer.sign(data: signingData),
              IdentityPublicKeySignatureVerifier.verify(
                signature: signature,
                messageData: signingData,
                descriptor: signerDescriptor
              ) else {
            throw DeviceIngressResponseValidationError.invalidProof
        }
        signed.proof = DeviceIngressIdentityProof(
            signerIdentityUUID: signerDescriptor.uuid,
            signature: signature
        )
        return try signed.canonicalWireData()
    }
}

public enum DeviceIngressOperationResponseVerifier {
    public static func decodeCanonical(_ data: Data) throws -> DeviceIngressOperationResponse {
        guard data.isEmpty == false else {
            throw DeviceIngressResponseValidationError.emptyResponse
        }
        guard data.count <= DeviceIngressOperationResponse.maximumEncodedBytes else {
            throw DeviceIngressResponseValidationError.responseTooLarge
        }
        let response: DeviceIngressOperationResponse
        do {
            response = try JSONDecoder().decode(DeviceIngressOperationResponse.self, from: data)
        } catch {
            throw DeviceIngressResponseValidationError.malformedResponse
        }
        guard try response.canonicalWireData() == data else {
            throw DeviceIngressResponseValidationError.nonCanonicalResponse
        }
        return response
    }

    /// Verifies a self-contained response as historical evidence. Current
    /// access to any resolved payload remains governed by the surrounding Cell
    /// operation; the response does not create a new capability.
    public static func verify(
        canonicalData: Data,
        expectation: DeviceIngressResponseExpectation
    ) throws -> DeviceIngressOperationResponse {
        let response = try decodeCanonical(canonicalData)
        try validateUnsignedResponse(
            response,
            expectation: expectation
        )
        guard response.signer.displayName == nil,
              response.signer.uuid == expectation.targetOwnerIdentityUUID,
              DeviceIngressEnvelopeVerifier.signingKeyFingerprint(for: response.signer)
                == expectation.targetOwnerSigningKeyFingerprint else {
            throw DeviceIngressResponseValidationError.invalidSigner
        }
        guard let proof = response.proof,
              proof.schema == DeviceIngressIdentityProof.currentSchema,
              proof.type == DeviceIngressIdentityProof.identitySignatureType,
              proof.signerIdentityUUID == response.signer.uuid,
              IdentityPublicKeySignatureVerifier.verify(
                signature: proof.signature,
                messageData: try response.canonicalPayloadData(),
                descriptor: response.signer
              ) else {
            throw DeviceIngressResponseValidationError.invalidProof
        }
        return response
    }

    static func validateUnsignedResponse(
        _ response: DeviceIngressOperationResponse,
        expectation: DeviceIngressResponseExpectation
    ) throws {
        guard response.schema == DeviceIngressOperationResponse.currentSchema,
              response.mutationReceipt.schema == DeviceIngressMutationReceipt.currentSchema,
              response.result.schema == DeviceIngressOperationResult.currentSchema else {
            throw DeviceIngressResponseValidationError.wrongSchema
        }
        guard validIdentifier(response.responseID),
              validIdentifier(response.admissionID),
              validUUID(response.targetCellUUID),
              validUUID(response.targetOwnerIdentityUUID),
              validSigningKeyFingerprint(response.targetOwnerSigningKeyFingerprint),
              validIdentifier(response.revocationLedgerID) else {
            throw DeviceIngressResponseValidationError.invalidIdentifier
        }
        guard expectation.schema == DeviceIngressResponseExpectation.currentSchema,
              response.requestSHA256.count == 32,
              response.challengeSHA256.count == 32,
              response.bodySHA256.count == 32,
              response.mutationReceiptSHA256.count == 32,
              response.operationResultSHA256.count == 32,
              response.signedAgreementSHA256.count == 32,
              response.contentPolicySHA256.count == 32 else {
            throw DeviceIngressResponseValidationError.invalidDigest
        }
        guard response.authorityGeneration > 0,
              response.authorityGeneration
                <= DeviceIngressAuthorityReference.maximumJSONSafeGeneration,
              response.revocationGeneration
                <= DeviceIngressAuthorityReference.maximumJSONSafeGeneration else {
            throw DeviceIngressResponseValidationError.invalidGeneration
        }
        guard response.issuedAtMilliseconds == response.mutationReceipt.committedAtMilliseconds,
              response.expiresAtMilliseconds == expectation.requestExpiresAtMilliseconds,
              response.expiresAtMilliseconds > response.issuedAtMilliseconds,
              response.expiresAtMilliseconds
                <= DeviceIngressOperationResponse.maximumJSONSafeTimestampMilliseconds else {
            throw DeviceIngressResponseValidationError.invalidTimestamp
        }
        guard response.operation == expectation.operation,
              response.admissionID == expectation.admissionID,
              response.requestSHA256 == expectation.requestSHA256,
              response.challengeSHA256 == expectation.challengeSHA256,
              response.bodySHA256 == expectation.bodySHA256,
              response.targetCellUUID == expectation.targetCellUUID,
              response.targetOwnerIdentityUUID == expectation.targetOwnerIdentityUUID,
              response.targetOwnerSigningKeyFingerprint
                == expectation.targetOwnerSigningKeyFingerprint,
              response.subjectIdentityUUID == expectation.subjectIdentityUUID,
              response.subjectSigningKeyFingerprint
                == expectation.subjectSigningKeyFingerprint,
              response.signedAgreementSHA256 == expectation.signedAgreementSHA256,
              response.authorityGeneration == expectation.authorityGeneration,
              response.revocationLedgerID == expectation.revocationLedgerID,
              response.revocationGeneration == expectation.revocationGeneration,
              response.contentPolicySHA256
                == (try expectation.contentPolicy.canonicalSHA256()) else {
            throw DeviceIngressResponseValidationError.admissionBindingMismatch
        }
        let mutationReceiptData = try response.mutationReceipt.canonicalData()
        let resultData = try response.result.canonicalData()
        let resultSHA256 = DeviceIngressCanonicalWire.sha256(resultData)
        guard response.mutationReceiptSHA256
                == DeviceIngressCanonicalWire.sha256(mutationReceiptData),
              response.operationResultSHA256 == resultSHA256,
              response.mutationReceipt.operationResultSHA256 == resultSHA256,
              response.mutationReceipt.operation == response.operation,
              response.mutationReceipt.admissionID == response.admissionID,
              response.mutationReceipt.requestSHA256 == response.requestSHA256,
              response.mutationReceipt.challengeSHA256 == response.challengeSHA256,
              response.mutationReceipt.bodySHA256 == response.bodySHA256,
              response.mutationReceipt.targetCellUUID == response.targetCellUUID,
              response.mutationReceipt.targetOwnerIdentityUUID
                == response.targetOwnerIdentityUUID,
              response.mutationReceipt.targetOwnerSigningKeyFingerprint
                == response.targetOwnerSigningKeyFingerprint,
              response.mutationReceipt.subjectIdentityUUID
                == response.subjectIdentityUUID,
              response.mutationReceipt.subjectSigningKeyFingerprint
                == response.subjectSigningKeyFingerprint,
              response.mutationReceipt.signedAgreementSHA256
                == response.signedAgreementSHA256,
              response.mutationReceipt.authorityGeneration
                == response.authorityGeneration,
              response.mutationReceipt.revocationLedgerID
                == response.revocationLedgerID,
              response.mutationReceipt.revocationGeneration
                == response.revocationGeneration,
              response.mutationReceipt.contentPolicySHA256
                == response.contentPolicySHA256,
              response.mutationReceipt.mutationRecordSHA256.count == 32,
              response.mutationReceipt.durableSequence > 0,
              response.mutationReceipt.durableSequence
                <= DeviceIngressAuthorityReference.maximumJSONSafeGeneration else {
            throw DeviceIngressResponseValidationError.mutationReceiptMismatch
        }
        try validate(
            result: response.result,
            operation: response.operation,
            expectation: expectation,
            mutationReceipt: response.mutationReceipt
        )
        let expectedResponseID = try DeviceIngressMutationReceipt.responseID(
            admissionID: response.admissionID,
            requestSHA256: response.requestSHA256,
            mutationRecordSHA256: response.mutationReceipt.mutationRecordSHA256,
            operationResultSHA256: response.operationResultSHA256
        )
        guard response.responseID == expectedResponseID,
              response.mutationReceipt.responseID == expectedResponseID else {
            throw DeviceIngressResponseValidationError.responseIDMismatch
        }
        guard response.mutationReceipt.persistenceSemantics
                == DeviceIngressMutationReceipt.atomicMutationAndResponse else {
            throw DeviceIngressResponseValidationError.responseNotDurable
        }
    }

    static func validate(
        result: DeviceIngressOperationResult,
        operation: DeviceIngressOperation,
        expectation: DeviceIngressResponseExpectation,
        mutationReceipt: DeviceIngressMutationReceipt
    ) throws {
        guard result.operation == operation else {
            throw DeviceIngressResponseValidationError.operationResultMismatch
        }
        switch (operation, result.kind) {
        case (.register, .registrationReceipt):
            guard let receipt = result.registrationReceipt,
                  result.resolvedTicket == nil,
                  result.submissionReceipt == nil else {
                throw DeviceIngressResponseValidationError.operationResultMismatch
            }
            try validate(
                receipt,
                expectation: expectation,
                mutationReceipt: mutationReceipt
            )
        case (.resolve, .resolvedTicket):
            guard let ticket = result.resolvedTicket,
                  result.registrationReceipt == nil,
                  result.submissionReceipt == nil else {
                throw DeviceIngressResponseValidationError.operationResultMismatch
            }
            try validate(
                ticket,
                expectation: expectation,
                mutationReceipt: mutationReceipt
            )
        case (.resolve, .noPayload):
            guard result.registrationReceipt == nil,
                  result.resolvedTicket == nil,
                  result.submissionReceipt == nil else {
                throw DeviceIngressResponseValidationError.operationResultMismatch
            }
        case (.submit, .submissionReceipt):
            guard let receipt = result.submissionReceipt,
                  result.registrationReceipt == nil,
                  result.resolvedTicket == nil else {
                throw DeviceIngressResponseValidationError.operationResultMismatch
            }
            try validate(
                receipt,
                expectation: expectation,
                mutationReceipt: mutationReceipt
            )
        default:
            throw DeviceIngressResponseValidationError.operationResultMismatch
        }
    }

    private static func validate(
        _ receipt: DeviceIngressRegistrationReceipt,
        expectation: DeviceIngressResponseExpectation,
        mutationReceipt: DeviceIngressMutationReceipt
    ) throws {
        guard receipt.schema == DeviceIngressRegistrationReceipt.currentSchema,
              validIdentifier(receipt.registrationID),
              validUUID(receipt.deviceIdentityUUID),
              receipt.deviceIdentityUUID == expectation.subjectIdentityUUID,
              receipt.registrationGeneration > 0,
              receipt.registrationGeneration
                <= DeviceIngressAuthorityReference.maximumJSONSafeGeneration,
              receipt.durableSequence > 0,
              receipt.durableSequence
                <= DeviceIngressAuthorityReference.maximumJSONSafeGeneration,
              receipt.registrationRecordSHA256.count == 32,
              receipt.committedAtMilliseconds == mutationReceipt.committedAtMilliseconds,
              receipt.committedAtMilliseconds
                <= DeviceIngressOperationResponse.maximumJSONSafeTimestampMilliseconds,
              receipt.persistenceSemantics
                == DeviceIngressRegistrationReceipt.durableSameCellRegistration else {
            throw DeviceIngressResponseValidationError.invalidRegistrationReceipt
        }
    }

    private static func validate(
        _ ticket: DeviceIngressResolvedTicket,
        expectation: DeviceIngressResponseExpectation,
        mutationReceipt: DeviceIngressMutationReceipt
    ) throws {
        guard ticket.schema == DeviceIngressResolvedTicket.currentSchema,
              validIdentifier(ticket.ticketID),
              ticket.ticketSequence > 0,
              ticket.ticketSequence
                <= DeviceIngressAuthorityReference.maximumJSONSafeGeneration,
              validUUID(ticket.recipientDeviceIdentityUUID),
              ticket.recipientDeviceIdentityUUID == expectation.subjectIdentityUUID,
              validIdentifier(ticket.payloadSchema),
              ticket.payloadContentContractSHA256.count == 32,
              ticket.payloadContentContractSHA256
                == expectation.contentPolicy.resolvedPayloadContentContractSHA256,
              ticket.privacyPolicy == .cellVerifiedNoTransportCredentials,
              ticket.canonicalPayload.isEmpty == false,
              ticket.canonicalPayload.count <= DeviceIngressResolvedTicket.maximumPayloadBytes,
              ticket.payloadSHA256.count == 32,
              ticket.payloadSHA256
                == DeviceIngressCanonicalWire.sha256(ticket.canonicalPayload),
              ticket.issuedAtMilliseconds >= 0,
              ticket.issuedAtMilliseconds <= mutationReceipt.committedAtMilliseconds,
              ticket.expiresAtMilliseconds > mutationReceipt.committedAtMilliseconds,
              ticket.expiresAtMilliseconds - ticket.issuedAtMilliseconds
                <= DeviceIngressResolvedTicket.maximumTicketLifetimeMilliseconds,
              ticket.expiresAtMilliseconds
                <= expectation.requestExpiresAtMilliseconds,
              ticket.expiresAtMilliseconds
                <= DeviceIngressOperationResponse.maximumJSONSafeTimestampMilliseconds else {
            throw DeviceIngressResponseValidationError.invalidResolvedTicket
        }
    }

    private static func validate(
        _ receipt: DeviceIngressSubmissionReceipt,
        expectation: DeviceIngressResponseExpectation,
        mutationReceipt: DeviceIngressMutationReceipt
    ) throws {
        guard receipt.schema == DeviceIngressSubmissionReceipt.currentSchema,
              validIdentifier(receipt.ticketID),
              receipt.ticketSequence > 0,
              receipt.ticketSequence
                <= DeviceIngressAuthorityReference.maximumJSONSafeGeneration,
              receipt.submittedBodySHA256 == expectation.bodySHA256,
              receipt.resultRecordSHA256.count == 32,
              receipt.durableSequence > 0,
              receipt.durableSequence
                <= DeviceIngressAuthorityReference.maximumJSONSafeGeneration,
              receipt.committedAtMilliseconds == mutationReceipt.committedAtMilliseconds,
              receipt.committedAtMilliseconds
                <= DeviceIngressOperationResponse.maximumJSONSafeTimestampMilliseconds,
              receipt.persistenceSemantics
                == DeviceIngressSubmissionReceipt.durableSameCellSubmission else {
            throw DeviceIngressResponseValidationError.invalidSubmissionReceipt
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == value
            && trimmed.isEmpty == false
            && trimmed.utf8.count <= 128
            && trimmed.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 0x30 && scalar.value <= 0x39)
                    || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                    || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                    || scalar == "." || scalar == "_" || scalar == ":" || scalar == "-"
            }
    }

    private static func validSigningKeyFingerprint(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == value
            && trimmed.isEmpty == false
            && trimmed.utf8.count <= 256
            && trimmed.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x21 && scalar.value <= 0x7E
            }
    }

    private static func validUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil && value.utf8.count == 36
    }
}
