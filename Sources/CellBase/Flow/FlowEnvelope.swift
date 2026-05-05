// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct FlowEnvelope: Codable, Identifiable {
    public var id: String {
        "\(streamId):\(sequence)"
    }

    public var envelopeVersion: Int
    public var streamId: String
    public var sequence: UInt64
    public var domain: String
    public var producerCell: String
    public var producerIdentity: String

    public var payload: FlowElement
    public var payloadHash: String
    public var previousEnvelopeHash: String?

    public var signature: Data?
    public var signatureKeyId: String?

    public var provenance: FlowProvenance?
    public var revisionLink: FlowRevisionLink?
    public var metadata: [String: String]?

    public init(
        envelopeVersion: Int = 1,
        streamId: String,
        sequence: UInt64,
        domain: String,
        producerCell: String,
        producerIdentity: String,
        payload: FlowElement,
        payloadHash: String? = nil,
        previousEnvelopeHash: String? = nil,
        signature: Data? = nil,
        signatureKeyId: String? = nil,
        provenance: FlowProvenance? = nil,
        revisionLink: FlowRevisionLink? = nil,
        metadata: [String: String]? = nil
    ) throws {
        self.envelopeVersion = envelopeVersion
        self.streamId = streamId
        self.sequence = sequence
        self.domain = domain
        self.producerCell = producerCell
        self.producerIdentity = producerIdentity
        self.payload = payload
        self.payloadHash = try payloadHash ?? FlowHasher.payloadHash(for: payload)
        self.previousEnvelopeHash = previousEnvelopeHash
        self.signature = signature
        self.signatureKeyId = signatureKeyId
        self.provenance = provenance
        self.revisionLink = revisionLink
        self.metadata = metadata
    }
}
