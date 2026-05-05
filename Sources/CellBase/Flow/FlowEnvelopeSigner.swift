// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum FlowEnvelopeSigner {
    public static func sign(
        _ envelope: FlowEnvelope,
        with identity: Identity,
        signatureKeyId: String? = nil,
        ensureProvenance: Bool = true,
        signProvenance: Bool = true
    ) async throws -> FlowEnvelope {
        guard envelope.producerIdentity == identity.uuid else {
            throw FlowIntegrityError.producerIdentityMismatch(
                expected: envelope.producerIdentity,
                actual: identity.uuid
            )
        }

        var signedEnvelope = envelope
        signedEnvelope.payloadHash = try FlowHasher.payloadHash(for: signedEnvelope.payload)

        if ensureProvenance, signedEnvelope.provenance == nil {
            signedEnvelope.provenance = FlowProvenance(
                originCell: signedEnvelope.producerCell,
                originIdentity: signedEnvelope.producerIdentity,
                originPayloadHash: signedEnvelope.payloadHash,
                originSignature: nil
            )
        }

        if var provenance = signedEnvelope.provenance {
            provenance.originPayloadHash = signedEnvelope.payloadHash

            if signProvenance {
                guard provenance.originIdentity == identity.uuid else {
                    throw FlowIntegrityError.provenanceOriginIdentityMismatch(
                        expected: provenance.originIdentity,
                        actual: identity.uuid
                    )
                }

                let provenanceData = try FlowSignatureMaterial.originPayloadSigningData(
                    originCell: provenance.originCell,
                    originIdentity: provenance.originIdentity,
                    payloadHash: signedEnvelope.payloadHash
                )

                guard let provenanceSignature = try await identity.sign(data: provenanceData) else {
                    throw FlowIntegrityError.signingFailed
                }

                provenance.originSignature = provenanceSignature
            }

            signedEnvelope.provenance = provenance
        }

        signedEnvelope.signatureKeyId = signatureKeyId ?? signedEnvelope.signatureKeyId ?? identity.uuid

        let signingData = try FlowCanonicalEncoder.canonicalData(
            for: signedEnvelope,
            includingSignature: false,
            includingProvenance: false
        )
        guard let signature = try await identity.sign(data: signingData) else {
            throw FlowIntegrityError.signingFailed
        }

        signedEnvelope.signature = signature

        return signedEnvelope
    }
}
