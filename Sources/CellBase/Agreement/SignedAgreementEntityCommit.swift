// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum SignedAgreementEntityCommitError: Error {
    case invalidPayload
    case invalidContract
    case invalidCredentialReceipt
    case immutableRecordConflict
    case readAfterWriteMismatch
    case signingFailed
}

public struct SignedAgreementEntityCommitRequest {
    public var contract: Contract
    public var metadata: Object
    public var credentialReceipts: [TrustedIssuerEvaluationReceipt]

    public init(
        contract: Contract,
        metadata: Object = [:],
        credentialReceipts: [TrustedIssuerEvaluationReceipt] = []
    ) {
        self.contract = contract
        self.metadata = metadata
        self.credentialReceipts = credentialReceipts
    }

    public static func from(value: ValueType) throws -> SignedAgreementEntityCommitRequest {
        guard case let .object(object) = value,
              case let .object(contractObject)? = object["contract"] else {
            throw SignedAgreementEntityCommitError.invalidPayload
        }
        let contract = try SignedAgreementEntitySupport.decodeContract(from: contractObject)
        let metadata: Object
        if case let .object(value)? = object["metadata"] {
            metadata = value
        } else {
            metadata = [:]
        }
        let credentialReceipts: [TrustedIssuerEvaluationReceipt]
        if case let .list(values)? = object["credentialReceipts"] {
            credentialReceipts = try values.map { value in
                guard case let .object(receiptObject) = value else {
                    throw SignedAgreementEntityCommitError.invalidPayload
                }
                return try TrustedIssuerEvaluationReceipt.from(object: receiptObject)
            }
        } else {
            credentialReceipts = []
        }
        return SignedAgreementEntityCommitRequest(
            contract: contract,
            metadata: metadata,
            credentialReceipts: credentialReceipts
        )
    }
}

public struct SignedAgreementEntityCommitReceipt: Codable {
    public static let format = "signed_agreement_entity_commit_receipt_v1"

    public var receiptFormat: String
    public var receiptID: String
    public var recordID: String
    public var entityKeypath: String
    public var entityOwner: Identity
    public var contractHash: String
    public var recordHash: String
    public var persistedAt: String
    public var persistenceSemantics: String
    public var signature: Data

    private struct SigningPayload: Codable {
        var receiptFormat: String
        var receiptID: String
        var recordID: String
        var entityKeypath: String
        var entityOwnerUUID: String
        var entityOwnerSigningKeyFingerprint: String
        var contractHash: String
        var recordHash: String
        var persistedAt: String
        var persistenceSemantics: String
    }

    public static func issue(
        recordID: String,
        entityKeypath: String,
        entityOwner: Identity,
        contractHash: String,
        recordHash: String,
        persistedAt: Date = Date()
    ) async throws -> SignedAgreementEntityCommitReceipt {
        let receiptID = UUID().uuidString
        let publicOwner = entityOwner.publicIdentitySnapshot()
        guard let ownerFingerprint = publicOwner.signingPublicKeyFingerprint else {
            throw SignedAgreementEntityCommitError.signingFailed
        }
        let persistedAtString = ISO8601DateFormatter().string(from: persistedAt)
        let semantics = "entity_anchor_persisted_read_after_write_v1"
        let payload = SigningPayload(
            receiptFormat: format,
            receiptID: receiptID,
            recordID: recordID,
            entityKeypath: entityKeypath,
            entityOwnerUUID: publicOwner.uuid,
            entityOwnerSigningKeyFingerprint: ownerFingerprint,
            contractHash: contractHash,
            recordHash: recordHash,
            persistedAt: persistedAtString,
            persistenceSemantics: semantics
        )
        guard let signature = try await entityOwner.sign(
            data: try SignedAgreementEntitySupport.canonicalData(payload)
        ) else {
            throw SignedAgreementEntityCommitError.signingFailed
        }
        return SignedAgreementEntityCommitReceipt(
            receiptFormat: format,
            receiptID: receiptID,
            recordID: recordID,
            entityKeypath: entityKeypath,
            entityOwner: publicOwner,
            contractHash: contractHash,
            recordHash: recordHash,
            persistedAt: persistedAtString,
            persistenceSemantics: semantics,
            signature: signature
        )
    }

    public func verifySignature() -> Bool {
        guard receiptFormat == Self.format,
              persistenceSemantics == "entity_anchor_persisted_read_after_write_v1",
              let ownerFingerprint = entityOwner.signingPublicKeyFingerprint,
              let data = try? SignedAgreementEntitySupport.canonicalData(SigningPayload(
                receiptFormat: receiptFormat,
                receiptID: receiptID,
                recordID: recordID,
                entityKeypath: entityKeypath,
                entityOwnerUUID: entityOwner.uuid,
                entityOwnerSigningKeyFingerprint: ownerFingerprint,
                contractHash: contractHash,
                recordHash: recordHash,
                persistedAt: persistedAt,
                persistenceSemantics: persistenceSemantics
              )) else {
            return false
        }
        return IdentityPublicKeySignatureVerifier.verify(
            signature: signature,
            messageData: data,
            identity: entityOwner
        )
    }

    public func asObject() -> Object {
        return [
            "receiptFormat": .string(receiptFormat),
            "receiptID": .string(receiptID),
            "recordID": .string(recordID),
            "entityKeypath": .string(entityKeypath),
            "entityOwner": .identity(entityOwner),
            "contractHash": .string(contractHash),
            "recordHash": .string(recordHash),
            "persistedAt": .string(persistedAt),
            "persistenceSemantics": .string(persistenceSemantics),
            "signature": .data(signature)
        ]
    }

    public static func from(object: Object) throws -> SignedAgreementEntityCommitReceipt {
        let data = try SignedAgreementEntitySupport.canonicalData(object)
        return try JSONDecoder().decode(SignedAgreementEntityCommitReceipt.self, from: data)
    }
}

public enum SignedAgreementEntitySupport {
    public static func ownerEntityDomain(for owner: Identity) -> String {
        "entity:\(owner.uuid)"
    }

    public static func contractHash(_ contract: Contract) throws -> String {
        FlowHasher.sha256Hex(try canonicalData(contract))
    }

    public static func contractObject(_ contract: Contract) throws -> Object {
        try JSONDecoder().decode(Object.self, from: canonicalData(contract))
    }

    public static func decodeContract(from object: Object) throws -> Contract {
        try JSONDecoder().decode(Contract.self, from: canonicalData(object))
    }

    public static func recordObject(
        request: SignedAgreementEntityCommitRequest,
        contractHash: String,
        committedAt: Date = Date()
    ) throws -> Object {
        let contentHash = try immutableContentHash(request: request, contractHash: contractHash)
        return [
            "id": .string(request.contract.uuid),
            "recordState": .string("signed"),
            "signatureValidationState": .string("verified"),
            "signingSemantics": .string(request.contract.signingSemantics),
            "counterpartySignatureState": .string("not_present"),
            "immutable": .bool(true),
            "contractHash": .string(contractHash),
            "immutableContentHash": .string(contentHash),
            "contract": .object(try contractObject(request.contract)),
            "metadata": .object(request.metadata),
            "credentialReceipts": .list(request.credentialReceipts.map { .object($0.asObject()) }),
            "committedAt": .string(ISO8601DateFormatter().string(from: committedAt))
        ]
    }

    public static func immutableContentHash(
        request: SignedAgreementEntityCommitRequest,
        contractHash: String
    ) throws -> String {
        let content: Object = [
            "contractHash": .string(contractHash),
            "metadata": .object(request.metadata),
            "credentialReceipts": .list(request.credentialReceipts.map { .object($0.asObject()) })
        ]
        return FlowHasher.sha256Hex(try canonicalData(content))
    }

    public static func recordHash(_ record: Object) throws -> String {
        FlowHasher.sha256Hex(try canonicalData(record))
    }

    public static func credentialReceiptsAreBound(
        request: SignedAgreementEntityCommitRequest,
        expectedVerifier: Identity,
        now: Date = Date()
    ) -> Bool {
        let conditions: [Object] = {
            guard case let .list(values)? = request.metadata["conditions"] else { return [] }
            return values.compactMap { value in
                guard case let .object(object) = value else { return nil }
                return object
            }
        }()
        let proofConditions = conditions.filter {
            guard case let .string(kind)? = $0["kind"] else { return false }
            return kind == "prove"
        }
        guard proofConditions.count == request.credentialReceipts.count else { return false }
        guard let expectedHashes = try? Set(proofConditions.map(TrustedIssuerEvaluationReceipt.conditionHash)) else {
            return false
        }
        let receiptHashes = Set(request.credentialReceipts.compactMap { receipt -> String? in
            guard receipt.verifyTrustedEvaluation(expectedVerifier: expectedVerifier, now: now),
                  case let .string(hash)? = receipt.evidenceBinding["conditionHash"] else {
                return nil
            }
            return hash
        })
        return receiptHashes.count == request.credentialReceipts.count
            && receiptHashes == expectedHashes
    }

    public static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
