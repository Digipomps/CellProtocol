// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum TrustedIssuerEvaluationReceiptError: Error {
    case invalidEvaluation
    case signingFailed
}

/// A portable verifier-signed wrapper around one TrustedIssuer evaluation.
///
/// The evaluation's `snapshotHash` detects accidental mutation. The verifier
/// signature provides provenance and prevents a caller from fabricating or
/// changing a stored evaluation without control of the verifier key.
public struct TrustedIssuerEvaluationReceipt: Codable {
    public static let format = "trusted_issuer_evaluation_receipt_v1"
    public static let verifierEndpoint = "cell:///TrustedIssuers"
    public static let maximumLifetime: TimeInterval = 300

    public var receiptFormat: String
    public var evaluation: Object
    public var verifier: Identity
    public var verifierCellEndpoint: String
    public var evidenceBinding: Object
    public var issuedAt: String
    public var validUntil: String
    public var signature: Data

    private struct SigningPayload: Codable {
        var receiptFormat: String
        var evaluation: Object
        var verifierUUID: String
        var verifierSigningKeyFingerprint: String
        var verifierCellEndpoint: String
        var evidenceBinding: Object
        var issuedAt: String
        var validUntil: String
    }

    public static func issue(
        evaluation: Object,
        verifier: Identity,
        evidenceBinding: Object,
        issuedAt: Date = Date()
    ) async throws -> TrustedIssuerEvaluationReceipt {
        guard evaluationSnapshotHashIsValid(evaluation) else {
            throw TrustedIssuerEvaluationReceiptError.invalidEvaluation
        }
        let publicVerifier = verifier.publicIdentitySnapshot()
        guard let verifierFingerprint = publicVerifier.signingPublicKeyFingerprint else {
            throw TrustedIssuerEvaluationReceiptError.signingFailed
        }
        let issuedAtString = ISO8601DateFormatter().string(from: issuedAt)
        let validUntilString = ISO8601DateFormatter().string(
            from: issuedAt.addingTimeInterval(maximumLifetime)
        )
        let payload = SigningPayload(
            receiptFormat: format,
            evaluation: evaluation,
            verifierUUID: publicVerifier.uuid,
            verifierSigningKeyFingerprint: verifierFingerprint,
            verifierCellEndpoint: verifierEndpoint,
            evidenceBinding: evidenceBinding,
            issuedAt: issuedAtString,
            validUntil: validUntilString
        )
        guard let signature = try await verifier.sign(data: try canonicalData(payload)) else {
            throw TrustedIssuerEvaluationReceiptError.signingFailed
        }
        return TrustedIssuerEvaluationReceipt(
            receiptFormat: format,
            evaluation: evaluation,
            verifier: publicVerifier,
            verifierCellEndpoint: verifierEndpoint,
            evidenceBinding: evidenceBinding,
            issuedAt: issuedAtString,
            validUntil: validUntilString,
            signature: signature
        )
    }

    public func verifySignature() -> Bool {
        guard receiptFormat == Self.format,
              verifierCellEndpoint == Self.verifierEndpoint,
              Self.evaluationSnapshotHashIsValid(evaluation),
              Self.evidenceBindingIsValid(evidenceBinding, evaluation: evaluation),
              let verifierFingerprint = verifier.signingPublicKeyFingerprint,
              let data = try? Self.canonicalData(SigningPayload(
                receiptFormat: receiptFormat,
                evaluation: evaluation,
                verifierUUID: verifier.uuid,
                verifierSigningKeyFingerprint: verifierFingerprint,
                verifierCellEndpoint: verifierCellEndpoint,
                evidenceBinding: evidenceBinding,
                issuedAt: issuedAt,
                validUntil: validUntil
              )) else {
            return false
        }
        return IdentityPublicKeySignatureVerifier.verify(
            signature: signature,
            messageData: data,
            identity: verifier
        )
    }

    /// Verifies the signature and the security-relevant TrustedIssuer result.
    public func verifyTrustedEvaluation(
        expectedRequesterID: String? = nil,
        expectedIssuerID: String? = nil,
        expectedContextID: String? = nil,
        expectedVerifier: Identity? = nil,
        expectedConditionHash: String? = nil,
        now: Date = Date()
    ) -> Bool {
        guard verifySignature(),
              Self.isWithinValidityWindow(issuedAt: issuedAt, validUntil: validUntil, now: now),
              Self.string(evaluation["decision"]) == "trusted",
              Self.stringList(evaluation["reasons"]).contains("vc_signature_valid") else {
            return false
        }
        if let expectedRequesterID,
           Self.string(evaluation["requesterId"]) != expectedRequesterID {
            return false
        }
        if let expectedIssuerID,
           Self.string(evaluation["issuerId"]) != expectedIssuerID {
            return false
        }
        if let expectedContextID,
           Self.string(evaluation["contextId"]) != expectedContextID {
            return false
        }
        if let expectedVerifier,
           !Self.identitiesReferenceSame(verifier, expectedVerifier) {
            return false
        }
        if let expectedConditionHash,
           Self.string(evidenceBinding["conditionHash"]) != expectedConditionHash {
            return false
        }
        return true
    }

    public func asObject() -> Object {
        [
            "receiptFormat": .string(receiptFormat),
            "evaluation": .object(evaluation),
            "verifier": .identity(verifier),
            "verifierCellEndpoint": .string(verifierCellEndpoint),
            "evidenceBinding": .object(evidenceBinding),
            "issuedAt": .string(issuedAt),
            "validUntil": .string(validUntil),
            "signature": .data(signature)
        ]
    }

    public static func from(object: Object) throws -> TrustedIssuerEvaluationReceipt {
        let data = try canonicalData(object)
        return try JSONDecoder().decode(TrustedIssuerEvaluationReceipt.self, from: data)
    }

    public static func evaluationSnapshotHashIsValid(_ evaluation: Object) -> Bool {
        guard let expectedHash = string(evaluation["snapshotHash"]),
              expectedHash.utf8.count == 64,
              expectedHash.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }),
              evaluation["evaluationId"] != nil,
              evaluation["issuerId"] != nil,
              evaluation["contextId"] != nil,
              evaluation["score"] != nil,
              evaluation["threshold"] != nil,
              evaluation["decision"] != nil,
              evaluation["reasons"] != nil,
              evaluation["components"] != nil,
              evaluation["createdAt"] != nil else {
            return false
        }
        let canonicalEvaluation: Object = [
            "evaluationId": evaluation["evaluationId"]!,
            "issuerId": evaluation["issuerId"]!,
            "contextId": evaluation["contextId"]!,
            "requesterId": evaluation["requesterId"] ?? .null,
            "score": evaluation["score"]!,
            "threshold": evaluation["threshold"]!,
            "decision": evaluation["decision"]!,
            "reasons": evaluation["reasons"]!,
            "components": evaluation["components"]!,
            "createdAt": evaluation["createdAt"]!
        ]
        guard let data = try? canonicalData(canonicalEvaluation) else {
            return false
        }
        return FlowHasher.sha256Hex(data) == expectedHash
    }

    public static func evidenceBinding(
        candidateCredential: Object,
        policySnapshot: Object,
        agreementCondition: Object,
        evaluation: Object
    ) throws -> Object {
        guard let issuerID = string(evaluation["issuerId"]),
              let contextID = string(evaluation["contextId"]),
              let requesterID = string(evaluation["requesterId"]) else {
            throw TrustedIssuerEvaluationReceiptError.invalidEvaluation
        }
        let reasons = stringList(evaluation["reasons"])
        let requireSubjectBinding = bool(policySnapshot["requireSubjectBinding"]) ?? false
        let requireRevocationCheck = bool(policySnapshot["requireRevocationCheck"]) ?? false
        let subjectBindingStatus = requireSubjectBinding
            ? (reasons.contains("subject_binding_missing") || reasons.contains("subject_binding_mismatch") ? "failed" : "verified")
            : "not_required"
        let revocationStatus = requireRevocationCheck
            ? (reasons.contains("revocation_check_failed") || reasons.contains("revocation_check_unsupported") ? "failed" : "verified")
            : "not_required"
        return [
            "credentialHash": .string(FlowHasher.sha256Hex(try canonicalData(candidateCredential))),
            "policyHash": .string(FlowHasher.sha256Hex(try canonicalData(policySnapshot))),
            "conditionHash": .string(FlowHasher.sha256Hex(try canonicalData(agreementCondition))),
            "issuerId": .string(issuerID),
            "contextId": .string(contextID),
            "requesterId": .string(requesterID),
            "requiredCredentialType": agreementCondition["requiredCredentialType"] ?? .string(""),
            "subjectClaimPath": agreementCondition["subjectClaimPath"] ?? .string(""),
            "subjectBindingStatus": .string(subjectBindingStatus),
            "revocationStatus": .string(revocationStatus)
        ]
    }

    public static func conditionHash(_ condition: Object) throws -> String {
        FlowHasher.sha256Hex(try canonicalData(condition))
    }

    private static func evidenceBindingIsValid(_ binding: Object, evaluation: Object) -> Bool {
        let requiredHashes = ["credentialHash", "policyHash", "conditionHash"]
        guard requiredHashes.allSatisfy({ key in
            guard let value = string(binding[key]) else { return false }
            return value.utf8.count == 64 && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
        }),
        string(binding["issuerId"]) == string(evaluation["issuerId"]),
        string(binding["contextId"]) == string(evaluation["contextId"]),
        string(binding["requesterId"]) == string(evaluation["requesterId"]),
        ["verified", "not_required"].contains(string(binding["subjectBindingStatus"]) ?? ""),
        ["verified", "not_required"].contains(string(binding["revocationStatus"]) ?? "") else {
            return false
        }
        return true
    }

    private static func isWithinValidityWindow(issuedAt: String, validUntil: String, now: Date) -> Bool {
        let formatter = ISO8601DateFormatter()
        guard let issued = formatter.date(from: issuedAt),
              let expiry = formatter.date(from: validUntil),
              expiry >= issued,
              expiry.timeIntervalSince(issued) <= maximumLifetime + 1,
              issued.timeIntervalSince(now) <= Contract.allowedClockSkew,
              expiry >= now else {
            return false
        }
        return true
    }

    private static func identitiesReferenceSame(_ lhs: Identity, _ rhs: Identity) -> Bool {
        guard lhs.uuid == rhs.uuid,
              let lhsFingerprint = lhs.signingPublicKeyFingerprint,
              let rhsFingerprint = rhs.signingPublicKeyFingerprint else {
            return false
        }
        return lhsFingerprint == rhsFingerprint
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func string(_ value: ValueType?) -> String? {
        guard case let .string(result)? = value else { return nil }
        return result
    }

    private static func bool(_ value: ValueType?) -> Bool? {
        guard case let .bool(result)? = value else { return nil }
        return result
    }

    private static func stringList(_ value: ValueType?) -> [String] {
        guard case let .list(values)? = value else { return [] }
        return values.compactMap { value in
            guard case let .string(result) = value else { return nil }
            return result
        }
    }
}
