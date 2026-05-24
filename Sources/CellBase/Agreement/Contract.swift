// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum ContractError: Error {
    case signingFailed
    case missingVerifier
}

public struct Contract: Codable {
    public var uuid: String
    public var agreement: Agreement
    public var issuer: Identity
    public var subject: Identity
    public var domain: String
    public var issuedAt: TimeInterval
    public var expiresAt: TimeInterval
    public var signature: Data?

    enum CodingKeys: String, CodingKey {
        case uuid
        case agreement
        case issuer
        case subject
        case domain
        case issuedAt
        case expiresAt
        case signature
    }

    private struct SigningPayload: Codable {
        var uuid: String
        var agreement: Agreement
        var issuerUUID: String
        var issuerSigningKeyFingerprint: String?
        var subjectUUID: String
        var subjectSigningKeyFingerprint: String?
        var domain: String
        var issuedAt: TimeInterval
        var expiresAt: TimeInterval
    }

    public static func signed(
        agreement: Agreement,
        issuer: Identity,
        subject: Identity,
        domain: String,
        issuedAt: Date = Date()
    ) async throws -> Contract {
        let agreementSnapshot = try snapshot(agreement)
        var contract = Contract(
            uuid: UUID().uuidString,
            agreement: agreementSnapshot,
            issuer: issuer,
            subject: subject,
            domain: domain,
            issuedAt: issuedAt.timeIntervalSince1970,
            expiresAt: issuedAt.addingTimeInterval(TimeInterval(agreementSnapshot.duration)).timeIntervalSince1970,
            signature: nil
        )
        guard let signature = try await issuer.sign(data: contract.signingData()) else {
            throw ContractError.signingFailed
        }
        contract.signature = signature
        return contract
    }

    public func verifySignature(now: Date = Date()) async -> Bool {
        guard let signature else { return false }
        guard expiresAt >= now.timeIntervalSince1970 else { return false }
        guard let verifier = issuer.identityVault ?? CellBase.defaultIdentityVault else {
            return false
        }
        return (try? await verifier.verifySignature(
            signature: signature,
            messageData: signingData(),
            for: issuer
        )) ?? false
    }

    private func signingData() throws -> Data {
        let payload = SigningPayload(
            uuid: uuid,
            agreement: agreement,
            issuerUUID: issuer.uuid,
            issuerSigningKeyFingerprint: issuer.signingPublicKeyFingerprint,
            subjectUUID: subject.uuid,
            subjectSigningKeyFingerprint: subject.signingPublicKeyFingerprint,
            domain: domain,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
        return try Self.canonicalEncoder().encode(payload)
    }

    private static func snapshot(_ agreement: Agreement) throws -> Agreement {
        let data = try canonicalEncoder().encode(agreement)
        return try JSONDecoder().decode(Agreement.self, from: data)
    }

    private static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
