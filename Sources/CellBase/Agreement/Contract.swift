// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum ContractError: Error {
    case signingFailed
    case missingVerifier
}

public struct Contract: Codable {
    public static let maximumDuration: TimeInterval = 60 * 60 * 24 * 365
    public static let allowedClockSkew: TimeInterval = 300
    public var uuid: String
    public var agreement: Agreement
    public var issuer: Identity
    public var subject: Identity
    public var domain: String
    public var issuedAt: TimeInterval
    public var expiresAt: TimeInterval
    public var signature: Data?

    var authorizationDeduplicationKey: String {
        let grants = agreement.grants
            .map { "\($0.keypath):\($0.permission.fullPermissionString)" }
            .sorted()
            .joined(separator: ",")
        let conditions = agreement.conditions
            .map { "\(String(reflecting: type(of: $0))):\($0.uuid)" }
            .sorted()
            .joined(separator: ",")
        return [
            subject.uuid,
            subject.signingPublicKeyFingerprint ?? "missing-subject-key",
            domain,
            agreement.owner.uuid,
            agreement.owner.signingPublicKeyFingerprint ?? "missing-owner-key",
            grants,
            conditions,
            String(agreement.duration)
        ].joined(separator: "|")
    }

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
        let nowInterval = now.timeIntervalSince1970
        guard issuedAt.isFinite,
              expiresAt.isFinite,
              issuedAt <= nowInterval + Self.allowedClockSkew,
              expiresAt >= nowInterval,
              expiresAt >= issuedAt,
              expiresAt - issuedAt <= Self.maximumDuration,
              agreement.duration > 0,
              abs((expiresAt - issuedAt) - TimeInterval(agreement.duration)) < 0.001 else {
            return false
        }
        guard let verifier = issuer.identityVault ?? CellBase.defaultIdentityVault else {
            return false
        }
        return (try? await verifier.verifySignature(
            signature: signature,
            messageData: signingData(),
            for: issuer
        )) ?? false
    }

    public func verifyAuthorizationBinding(
        expectedIssuer: Identity,
        expectedSubject: Identity,
        expectedDomain: String,
        now: Date = Date()
    ) async -> Bool {
        guard domain == expectedDomain,
              Self.identitiesReferenceSame(issuer, expectedIssuer),
              Self.identitiesReferenceSame(subject, expectedSubject),
              Self.identitiesReferenceSame(agreement.owner, expectedIssuer),
              agreement.state == .signed,
              agreement.signatories.contains(where: { Self.identitiesReferenceSame($0, expectedIssuer) }),
              agreement.signatories.contains(where: { Self.identitiesReferenceSame($0, expectedSubject) }) else {
            return false
        }
        return await verifySignature(now: now)
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

    private static func identitiesReferenceSame(_ lhs: Identity, _ rhs: Identity) -> Bool {
        guard lhs.uuid == rhs.uuid,
              let lhsFingerprint = lhs.signingPublicKeyFingerprint,
              let rhsFingerprint = rhs.signingPublicKeyFingerprint else {
            return false
        }
        return lhsFingerprint == rhsFingerprint
    }
}
