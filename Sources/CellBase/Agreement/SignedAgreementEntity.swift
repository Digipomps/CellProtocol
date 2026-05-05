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

    public init(
        id: String? = nil,
        agreement: Agreement,
        counterparty: String? = nil,
        purpose: String? = nil,
        dataPointer: String? = nil,
        summary: String? = nil,
        savedAt: Int? = nil,
        savedAtText: String? = nil,
        recordState: AgreementState = .signed
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

public struct SignedAgreementEntity: Codable {
    public var name: String
    public var description: String?
    public var records: [SignedAgreementRecord]

    public init(
        name: String = "Signed Agreement Entity",
        description: String? = nil,
        records: [SignedAgreementRecord] = []
    ) {
        self.name = name
        self.description = description
        self.records = records
    }

    public func agreementRefs(
        recordKeypathPrefix: String = "signedAgreementEntity.records",
        sourceEntityKeypath: String = "entityRepresentation.agreementRefs"
    ) -> [AgreementReference] {
        records.map { record in
            record.agreementReference(
                recordKeypath: "\(recordKeypathPrefix).\(record.id)",
                sourceEntityKeypath: sourceEntityKeypath
            )
        }
    }
}
