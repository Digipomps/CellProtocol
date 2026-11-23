// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// One record in `signedAgreementEntity.records.<contract uuid>`, exactly as the
/// EntityAnchor commit flow stores it (`SignedAgreementEntitySupport.recordObject`
/// and `prepareRecord`). Kjetil 2026-11-23: the model follows storage.
///
/// The round trip `init(object:)` → `asObject()` is lossless: values the record
/// hash covers (`contract`, `metadata`, `credentialReceipts`) stay as stored
/// objects, `committedAt` stays the stored string (whole seconds before the
/// chain, milliseconds after), and members this model does not know are kept in
/// `additionalFields`. So `SignedAgreementEntitySupport.recordHash` of the
/// re-encoded record equals the hash of the stored one.
public struct SignedAgreementRecord: Codable {
    public var id: String
    public var recordState: String
    public var signatureValidationState: String
    public var signingSemantics: String
    public var counterpartySignatureState: String
    public var immutable: Bool
    public var contractHash: String
    public var immutableContentHash: String
    /// The signed contract as stored. Decode with `decodedContract()`.
    public var contract: Object
    public var metadata: Object
    public var credentialReceipts: [Object]
    /// ISO 8601 UTC as stored.
    public var committedAt: String
    /// Position in the revision chain; nil for records written before the chain.
    public var sequence: Int?
    /// `recordHash` of the record with the previous sequence; nil for the first.
    public var previousRecordHash: String?
    /// Stored members this model does not name, kept for a lossless round trip.
    public var additionalFields: Object
    /// The stored `sequence` value as read (`.integer` or `.number` after a
    /// storage round trip), reused while `sequence` is unchanged.
    private var storedSequence: ValueType? = nil

    static let knownFields: Set<String> = [
        "id", "recordState", "signatureValidationState", "signingSemantics", "counterpartySignatureState",
        "immutable", "contractHash", "immutableContentHash", "contract", "metadata", "credentialReceipts",
        "committedAt", "sequence", "previousRecordHash",
    ]

    public enum DecodingFailure: Error, Equatable {
        case missingField(String)
        case wrongType(String)
    }

    public init(
        id: String,
        recordState: String = AgreementState.signed.rawValue,
        signatureValidationState: String = "verified",
        signingSemantics: String,
        counterpartySignatureState: String = "not_present",
        immutable: Bool = true,
        contractHash: String,
        immutableContentHash: String,
        contract: Object,
        metadata: Object = [:],
        credentialReceipts: [Object] = [],
        committedAt: String,
        sequence: Int? = nil,
        previousRecordHash: String? = nil,
        additionalFields: Object = [:]
    ) {
        self.id = id
        self.recordState = recordState
        self.signatureValidationState = signatureValidationState
        self.signingSemantics = signingSemantics
        self.counterpartySignatureState = counterpartySignatureState
        self.immutable = immutable
        self.contractHash = contractHash
        self.immutableContentHash = immutableContentHash
        self.contract = contract
        self.metadata = metadata
        self.credentialReceipts = credentialReceipts
        self.committedAt = committedAt
        self.sequence = sequence
        self.previousRecordHash = previousRecordHash
        self.additionalFields = additionalFields
    }

    /// Reads a stored record object.
    public init(object: Object) throws {
        func string(_ key: String) throws -> String {
            guard let value = object[key] else { throw DecodingFailure.missingField(key) }
            guard case let .string(text) = value else { throw DecodingFailure.wrongType(key) }
            return text
        }
        func objectField(_ key: String) throws -> Object {
            guard let value = object[key] else { throw DecodingFailure.missingField(key) }
            guard case let .object(inner) = value else { throw DecodingFailure.wrongType(key) }
            return inner
        }
        id = try string("id")
        recordState = try string("recordState")
        signatureValidationState = try string("signatureValidationState")
        signingSemantics = try string("signingSemantics")
        counterpartySignatureState = try string("counterpartySignatureState")
        guard let immutableValue = object["immutable"] else { throw DecodingFailure.missingField("immutable") }
        guard case let .bool(flag) = immutableValue else { throw DecodingFailure.wrongType("immutable") }
        immutable = flag
        contractHash = try string("contractHash")
        immutableContentHash = try string("immutableContentHash")
        contract = try objectField("contract")
        metadata = try objectField("metadata")
        guard let receiptsValue = object["credentialReceipts"] else { throw DecodingFailure.missingField("credentialReceipts") }
        guard case let .list(receipts) = receiptsValue else { throw DecodingFailure.wrongType("credentialReceipts") }
        credentialReceipts = try receipts.map { value in
            guard case let .object(receipt) = value else { throw DecodingFailure.wrongType("credentialReceipts") }
            return receipt
        }
        committedAt = try string("committedAt")
        switch object["sequence"] {
        case nil: sequence = nil
        case let .integer(number)?, let .number(number)?: sequence = number
        default: throw DecodingFailure.wrongType("sequence")
        }
        storedSequence = object["sequence"]
        switch object["previousRecordHash"] {
        case nil: previousRecordHash = nil
        case let .string(hash)?: previousRecordHash = hash
        default: throw DecodingFailure.wrongType("previousRecordHash")
        }
        additionalFields = object.filter { !Self.knownFields.contains($0.key) }
    }

    /// The stored form. Chain fields are written only when present, so a
    /// legacy record re-encodes to the same bytes.
    public func asObject() -> Object {
        var object = additionalFields
        object["id"] = .string(id)
        object["recordState"] = .string(recordState)
        object["signatureValidationState"] = .string(signatureValidationState)
        object["signingSemantics"] = .string(signingSemantics)
        object["counterpartySignatureState"] = .string(counterpartySignatureState)
        object["immutable"] = .bool(immutable)
        object["contractHash"] = .string(contractHash)
        object["immutableContentHash"] = .string(immutableContentHash)
        object["contract"] = .object(contract)
        object["metadata"] = .object(metadata)
        object["credentialReceipts"] = .list(credentialReceipts.map { .object($0) })
        object["committedAt"] = .string(committedAt)
        if let sequence {
            switch storedSequence {
            case let .integer(number)? where number == sequence, let .number(number)? where number == sequence:
                object["sequence"] = storedSequence
            default:
                object["sequence"] = .integer(sequence)
            }
        }
        if let previousRecordHash { object["previousRecordHash"] = .string(previousRecordHash) }
        return object
    }

    public init(from decoder: Decoder) throws {
        try self.init(object: try decoder.singleValueContainer().decode(Object.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(asObject())
    }

    public func decodedContract() throws -> Contract {
        try SignedAgreementEntitySupport.decodeContract(from: contract)
    }

    public var agreementState: AgreementState? { AgreementState(rawValue: recordState) }

    /// `committedAt` as seconds since 1970, for whole-second and millisecond forms.
    public var committedAtEpochSeconds: Int? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: committedAt) { return Int(date.timeIntervalSince1970.rounded(.down)) }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: committedAt).map { Int($0.timeIntervalSince1970.rounded(.down)) }
    }

    private func metadataString(_ key: String) -> String? {
        guard case let .string(value)? = metadata[key] else { return nil }
        return value
    }

    /// Label: the agreement's name in the signed contract, else the template
    /// title in metadata, else the record id.
    public var label: String {
        if case let .object(agreement)? = contract["agreement"], case let .string(name)? = agreement["name"], !name.isEmpty {
            return name
        }
        return metadataString("templateTitle") ?? id
    }

    public func agreementReference(
        recordKeypath: String? = nil,
        sourceEntityKeypath: String? = nil
    ) -> AgreementReference {
        AgreementReference(
            id: id,
            label: label,
            counterparty: metadataString("counterparty"),
            purpose: metadataString("purpose"),
            dataPointer: metadataString("dataPointer"),
            recordState: agreementState,
            savedAt: committedAtEpochSeconds,
            savedAtText: committedAt,
            recordKeypath: recordKeypath,
            sourceEntityKeypath: sourceEntityKeypath
        )
    }
}

/// `signedAgreementEntity` as stored: `records` is an object keyed by contract
/// uuid (`signedAgreementEntity.records.<uuid>`), not a list, and `receipts`
/// holds the commit receipts. Order comes from the revision chain
/// (`sequence`, `previousRecordHash`), see `SignedAgreementEntitySupport.verifyChain`
/// (Kjetil 2026-11-23). `name` and `description` are display fields the anchors
/// do not store; they are left out when they have their default values.
public struct SignedAgreementEntity: Codable {
    public var name: String
    public var description: String?
    public var records: [String: SignedAgreementRecord]
    /// `signedAgreementEntity.receipts.<receiptID>`, kept as stored.
    public var receipts: Object

    public static let defaultName = "Signed Agreement Entity"

    public init(
        name: String = SignedAgreementEntity.defaultName,
        description: String? = nil,
        records: [String: SignedAgreementRecord] = [:],
        receipts: Object = [:]
    ) {
        self.name = name
        self.description = description
        self.records = records
        self.receipts = receipts
    }

    /// Keys each record by its id.
    public init(
        name: String = SignedAgreementEntity.defaultName,
        description: String? = nil,
        records: [SignedAgreementRecord]
    ) {
        self.init(name: name, description: description,
                  records: Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }))
    }

    /// Reads the stored `signedAgreementEntity` object.
    public init(object: Object) throws {
        var records: [String: SignedAgreementRecord] = [:]
        if let stored = object["records"] {
            guard case let .object(storedRecords) = stored else { throw SignedAgreementRecord.DecodingFailure.wrongType("records") }
            for (key, value) in storedRecords {
                guard case let .object(record) = value else { throw SignedAgreementRecord.DecodingFailure.wrongType("records.\(key)") }
                records[key] = try SignedAgreementRecord(object: record)
            }
        }
        var receipts = Object()
        if case let .object(stored)? = object["receipts"] { receipts = stored }
        var name = Self.defaultName
        if case let .string(stored)? = object["name"] { name = stored }
        var description: String?
        if case let .string(stored)? = object["description"] { description = stored }
        self.init(name: name, description: description, records: records, receipts: receipts)
    }

    public func asObject() -> Object {
        var object: Object = ["records": .object(records.mapValues { .object($0.asObject()) })]
        if !receipts.isEmpty { object["receipts"] = .object(receipts) }
        if name != Self.defaultName { object["name"] = .string(name) }
        if let description { object["description"] = .string(description) }
        return object
    }

    public init(from decoder: Decoder) throws {
        try self.init(object: try decoder.singleValueContainer().decode(Object.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(asObject())
    }

    /// Chained records by sequence, then records from before the chain by id.
    public var orderedRecords: [SignedAgreementRecord] {
        records.values.sorted { lhs, rhs in
            switch (lhs.sequence, rhs.sequence) {
            case let (l?, r?): return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.id < rhs.id
            }
        }
    }

    public func agreementRefs(
        recordKeypathPrefix: String = "signedAgreementEntity.records",
        sourceEntityKeypath: String = "entityRepresentation.agreementRefs"
    ) -> [AgreementReference] {
        orderedRecords.map { record in
            record.agreementReference(
                recordKeypath: "\(recordKeypathPrefix).\(record.id)",
                sourceEntityKeypath: sourceEntityKeypath
            )
        }
    }
}
