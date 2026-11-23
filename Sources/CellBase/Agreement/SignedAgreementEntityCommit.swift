// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum SignedAgreementEntityCommitError: Error {
    case invalidPayload
    case invalidContract
    case invalidCredentialReceipt
    case immutableRecordConflict
    /// The revision chain in `signedAgreementEntity.records` does not hold.
    case recordChainBroken(String)
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

    // MARK: Revision chain (Kjetil 2026-11-23)
    //
    // Records stay keyed by contract uuid (`signedAgreementEntity.records.<uuid>`).
    // Order and history come from a chain inside the records: each new record
    // gets `sequence` (1, 2, 3, ...) and `previousRecordHash`, the `recordHash`
    // of the record with the sequence before it. Records written before the chain
    // have neither field; they are left out of the chain and not rewritten.

    public static let recordsKeypath = "signedAgreementEntity.records"

    public struct ChainLink: Equatable, Sendable {
        public let sequence: Int
        public let previousRecordHash: String?
    }

    /// Chained records in order, after checking every link.
    /// Throws `recordChainBroken` on a gap, a duplicate sequence or a wrong hash.
    @discardableResult
    public static func verifyChain(_ records: Object) throws -> [(id: String, record: Object)] {
        var chained: [(id: String, sequence: Int, record: Object)] = []
        for (id, value) in records {
            guard case let .object(record) = value else { continue }
            switch record["sequence"] {
            case nil: continue   // legacy record from before the chain
            case let .integer(sequence)?, let .number(sequence)?:
                chained.append((id, sequence, record))
            default:
                throw SignedAgreementEntityCommitError.recordChainBroken("\(id): sequence is not an integer")
            }
        }
        chained.sort { $0.sequence < $1.sequence }
        var previousHash: String?
        for (index, entry) in chained.enumerated() {
            guard entry.sequence == index + 1 else {
                throw SignedAgreementEntityCommitError.recordChainBroken("expected sequence \(index + 1), found \(entry.sequence) at \(entry.id)")
            }
            let link: String?
            switch entry.record["previousRecordHash"] {
            case nil, .null?: link = nil
            case let .string(hash)?: link = hash
            default: throw SignedAgreementEntityCommitError.recordChainBroken("\(entry.id): previousRecordHash is not a string")
            }
            guard link == previousHash else {
                throw SignedAgreementEntityCommitError.recordChainBroken("\(entry.id): previousRecordHash does not match record \(entry.sequence - 1)")
            }
            previousHash = try recordHash(entry.record)
        }
        return chained.map { ($0.id, $0.record) }
    }

    /// The link a new record gets, after verifying the existing chain.
    public static func nextLink(after records: Object) throws -> ChainLink {
        let chain = try verifyChain(records)
        return ChainLink(sequence: chain.count + 1, previousRecordHash: try chain.last.map { try recordHash($0.record) })
    }

    /// Decides what a commit stores. A record that already exists for the
    /// contract is returned unchanged when its content is identical (idempotent
    /// retry) and refused when it differs. A new record is linked to the chain.
    public static func prepareRecord(
        request: SignedAgreementEntityCommitRequest,
        contractHash: String,
        existingRecords: Object,
        committedAt: Date = Date()
    ) throws -> (record: Object, isNew: Bool) {
        let contentHash = try immutableContentHash(request: request, contractHash: contractHash)
        if case let .object(existing)? = existingRecords[request.contract.uuid] {
            guard case let .string(existingContentHash)? = existing["immutableContentHash"],
                  existingContentHash == contentHash else {
                throw SignedAgreementEntityCommitError.immutableRecordConflict
            }
            return (existing, false)
        }
        let link = try nextLink(after: existingRecords)
        var record = try recordObject(request: request, contractHash: contractHash, committedAt: committedAt)
        record["sequence"] = .integer(link.sequence)
        if let previous = link.previousRecordHash {
            record["previousRecordHash"] = .string(previous)
        }
        return (record, true)
    }

    /// `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`: UTC, always three fractional digits,
    /// truncated to milliseconds (date rule in Docs/JCS_TRANSITION_PLAN.md).
    public static func committedAtString(_ date: Date) -> String {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        let seconds = milliseconds >= 0 ? milliseconds / 1000 : (milliseconds - 999) / 1000
        let fraction = milliseconds - seconds * 1000
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        let whole = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        let digits = String(fraction)
        return String(whole.dropLast()) + "." + String(repeating: "0", count: 3 - digits.count) + digits + "Z"
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
            "committedAt": .string(committedAtString(committedAt))
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
