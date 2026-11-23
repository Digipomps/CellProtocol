// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct SignedAgreementRecord: Codable {
    public var id: String
    public var agreement: Agreement
    public var counterparty: String?
    public var purpose: String?
    public var dataPointer: String?
    public var summary: String?
    public var savedAt: Int?
    public var savedAtText: String?
    public var recordState: AgreementState
    /// Position in the revision chain; nil for records written before the chain.
    public var sequence: Int?
    /// `recordHash` of the record with the previous sequence; nil for the first.
    public var previousRecordHash: String?

    public init(
        id: String? = nil,
        agreement: Agreement,
        counterparty: String? = nil,
        purpose: String? = nil,
        dataPointer: String? = nil,
        summary: String? = nil,
        savedAt: Int? = nil,
        savedAtText: String? = nil,
        recordState: AgreementState = .signed,
        sequence: Int? = nil,
        previousRecordHash: String? = nil
    ) {
        self.id = id ?? agreement.uuid
        self.agreement = agreement
        self.counterparty = counterparty
        self.purpose = purpose
        self.dataPointer = dataPointer
        self.summary = summary
        self.savedAt = savedAt
        self.savedAtText = savedAtText
        self.recordState = recordState
        self.sequence = sequence
        self.previousRecordHash = previousRecordHash
    }

    public func agreementReference(
        recordKeypath: String? = nil,
        sourceEntityKeypath: String? = nil
    ) -> AgreementReference {
        AgreementReference(
            id: id,
            label: agreement.name,
            counterparty: counterparty,
            purpose: purpose,
            dataPointer: dataPointer,
            recordState: recordState,
            savedAt: savedAt,
            savedAtText: savedAtText,
            recordKeypath: recordKeypath,
            sourceEntityKeypath: sourceEntityKeypath
        )
    }
}

/// Mirrors the stored form: `records` is an object keyed by contract uuid
/// (`signedAgreementEntity.records.<uuid>`), not a list. Order comes from the
/// revision chain (`sequence`, `previousRecordHash`), see
/// `SignedAgreementEntitySupport.verifyChain` (Kjetil 2026-11-23).
public struct SignedAgreementEntity: Codable {
    public var name: String
    public var description: String?
    public var records: [String: SignedAgreementRecord]

    public init(
        name: String = "Signed Agreement Entity",
        description: String? = nil,
        records: [String: SignedAgreementRecord] = [:]
    ) {
        self.name = name
        self.description = description
        self.records = records
    }

    /// Keys each record by its id.
    public init(
        name: String = "Signed Agreement Entity",
        description: String? = nil,
        records: [SignedAgreementRecord]
    ) {
        self.init(name: name, description: description,
                  records: Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }))
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
