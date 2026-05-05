// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum FlowEnvelopeVerifier {
    @discardableResult
    public static func verify(
        _ envelope: FlowEnvelope,
        producerIdentity: Identity,
        originIdentity: Identity? = nil,
        requireProvenanceSignature: Bool = false
    ) async throws -> Bool {
        let calculatedPayloadHash = try FlowHasher.payloadHash(for: envelope.payload)
        guard calculatedPayloadHash == envelope.payloadHash else {
            throw FlowIntegrityError.payloadHashMismatch(
                expected: envelope.payloadHash,
                actual: calculatedPayloadHash
            )
        }

        guard let producerSignature = envelope.signature else {
            throw FlowIntegrityError.missingProducerSignature
        }

        let producerSigningData = try FlowCanonicalEncoder.canonicalData(
            for: envelope,
            includingSignature: false,
            includingProvenance: false
        )
        let producerSignatureIsValid = await producerIdentity.verify(signature: producerSignature, for: producerSigningData)
        guard producerSignatureIsValid else {
            throw FlowIntegrityError.invalidProducerSignature
        }

        let shouldVerifyProvenance = requireProvenanceSignature || envelope.provenance?.originSignature != nil
        if shouldVerifyProvenance {
            try await verifyProvenance(
                envelope,
                producerIdentity: producerIdentity,
                originIdentity: originIdentity
            )
        }

        return true
    }

    private static func verifyProvenance(
        _ envelope: FlowEnvelope,
        producerIdentity: Identity,
        originIdentity: Identity?
    ) async throws {
        guard let provenance = envelope.provenance else {
            throw FlowIntegrityError.provenanceMissing
        }

        guard provenance.originPayloadHash == envelope.payloadHash else {
            throw FlowIntegrityError.provenancePayloadHashMismatch(
                expected: envelope.payloadHash,
                actual: provenance.originPayloadHash ?? "nil"
            )
        }

        guard let provenanceSignature = provenance.originSignature else {
            throw FlowIntegrityError.provenanceSignatureMissing
        }

        let originIdentityToVerifyWith: Identity
        if let originIdentity {
            guard provenance.originIdentity == originIdentity.uuid else {
                throw FlowIntegrityError.provenanceOriginIdentityMismatch(
                    expected: provenance.originIdentity,
                    actual: originIdentity.uuid
                )
            }
            originIdentityToVerifyWith = originIdentity
        } else {
            guard provenance.originIdentity == producerIdentity.uuid else {
                throw FlowIntegrityError.provenanceOriginIdentityMismatch(
                    expected: provenance.originIdentity,
                    actual: producerIdentity.uuid
                )
            }
            originIdentityToVerifyWith = producerIdentity
        }

        let provenanceSigningData = try FlowSignatureMaterial.originPayloadSigningData(
            originCell: provenance.originCell,
            originIdentity: provenance.originIdentity,
            payloadHash: envelope.payloadHash
        )

        let provenanceSignatureIsValid = await originIdentityToVerifyWith.verify(
            signature: provenanceSignature,
            for: provenanceSigningData
        )

        guard provenanceSignatureIsValid else {
            throw FlowIntegrityError.invalidProvenanceSignature
        }
    }
}
