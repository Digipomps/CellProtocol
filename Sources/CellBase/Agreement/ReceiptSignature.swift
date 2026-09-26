// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// purposeRef: purpose://candidate.tillitspakke-agentflaate.signert-kvittering

public enum ReceiptSignatureVerification: String, Codable, Sendable {
    case valid, invalid, unsigned
}

public struct ReceiptSignature: Codable, Equatable, Sendable {
    public var signerRef: String
    public var algorithm: String
    public var value: String
    /// Issuance time, required to equal the canonical signed receipt's createdAt.
    /// This is the issuer's declaration, not an independently witnessed timestamp.
    public var signedAt: String

    public init(signerRef: String, algorithm: String, value: String, signedAt: String) {
        self.signerRef = signerRef
        self.algorithm = algorithm
        self.value = value
        self.signedAt = signedAt
    }
}

public enum ReceiptSigningError: Error, Equatable, Sendable {
    case unsupportedSigningIdentity
    case signingFailed
    case invalidEffectMetadata
}

/// Same sorted, compact JSON and UTC timestamp pattern as WP1. Its package-only
/// secret-name guard cannot encode receipts (containsSecrets and base64 signature).
/// Callers pass an unsigned copy, so the signature field is absent, not JSON null.
enum ReceiptSigning {
    static func canonicalBytes<T: Encodable>(_ unsigned: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(unsigned)
    }

    static func sign<T: Encodable>(
        _ unsigned: T, createdAt: String, by signer: Identity
    ) async throws -> ReceiptSignature {
        guard let algorithm = algorithm(for: signer) else {
            throw ReceiptSigningError.unsupportedSigningIdentity
        }
        // Identity.sign checks vault/key control and verifies the returned bytes,
        // exactly as on the Contract.ownerSignedSnapshot path. No new crypto.
        guard let signature = try await signer.sign(data: canonicalBytes(unsigned)) else {
            throw ReceiptSigningError.signingFailed
        }
        return ReceiptSignature(
            signerRef: "identity://\(signer.uuid)", algorithm: algorithm,
            value: signature.base64EncodedString(), signedAt: createdAt
        )
    }

    static func verify<T: Encodable>(
        _ unsigned: T, signature: ReceiptSignature, createdAt: String, against signer: Identity
    ) -> ReceiptSignatureVerification {
        guard signature.signerRef == "identity://\(signer.uuid)",
              signature.algorithm == algorithm(for: signer),
              signature.signedAt == createdAt,
              let bytes = Data(base64Encoded: signature.value),
              bytes.base64EncodedString() == signature.value,
              let message = try? canonicalBytes(unsigned),
              IdentityPublicKeySignatureVerifier.verify(
                signature: bytes, messageData: message, identity: signer
              ) else {
            return .invalid
        }
        return .valid
    }

    private static func algorithm(for identity: Identity) -> String? {
        guard let descriptor = IdentityPublicKeySignatureVerifier.descriptor(for: identity) else {
            return nil
        }
        switch (descriptor.algorithm, descriptor.curveType) {
        case (.ECDSA, .P256): return "P256-ECDSA-SHA256"
        case (.EdDSA, .Curve25519): return "Ed25519"
        default: return nil
        }
    }
}
