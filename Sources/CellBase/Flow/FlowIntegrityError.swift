// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum FlowIntegrityError: Error, Equatable {
    case missingEnvelopeReference(flowElementId: String)
    case missingProducerSignature
    case signingFailed

    case producerCellMismatch(expected: String, actual: String)
    case producerIdentityMismatch(expected: String, actual: String)
    case domainMismatch(expected: String, actual: String)
    case sequenceGap(streamId: String, expected: UInt64, actual: UInt64)
    case payloadHashMismatch(expected: String, actual: String)
    case invalidProducerSignature

    case provenanceMissing
    case provenanceSignatureMissing
    case provenanceOriginIdentityMismatch(expected: String, actual: String)
    case provenancePayloadHashMismatch(expected: String, actual: String)
    case invalidProvenanceSignature
}
