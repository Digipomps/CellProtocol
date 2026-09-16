// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// purposeRef: purpose://candidate.tillitspakke-agentflaate.signert-kvittering

/// Metadata for one WebFetch attempt. No URL, credential alias, headers or body.
public struct EffectReceipt: Codable, Equatable, Sendable {
    public static let schemaV0 = "haven.effect-receipt.v0"

    public struct Bindings: Codable, Equatable, Sendable {
        /// Nil when admission could not read a ceiling. Never invent a digest.
        public var ceilingDigest: String?
        /// Present only when this attempt is bound to a trust package.
        public var packageDigest: String?

        public init(ceilingDigest: String?, packageDigest: String? = nil) {
            self.ceilingDigest = ceilingDigest
            self.packageDigest = packageDigest
        }
    }

    public var schema: String
    public var receiptID: String
    public var cellRef: String
    public var action: String
    /// Host only, or empty when an invalid request has no parsed host.
    public var destinationHost: String
    public var method: String
    /// Received response bytes, including any bytes discarded from the preview.
    public var bytes: Int
    public var credentialsUsed: Bool
    public var decisionStatus: PurposeDecisionStatus
    /// A bounded reason code, never a provider error message or raw response.
    public var reason: String?
    public var executionStatus: PurposeExecutionStatus
    public var bindings: Bindings
    public var createdAt: String
    public var signature: ReceiptSignature?

    public init(
        receiptID: String, cellRef: String, destinationHost: String, method: String,
        bytes: Int, credentialsUsed: Bool, decisionStatus: PurposeDecisionStatus,
        reason: String? = nil, executionStatus: PurposeExecutionStatus,
        bindings: Bindings, createdAt: String, signature: ReceiptSignature? = nil
    ) throws {
        schema = Self.schemaV0
        self.receiptID = receiptID
        self.cellRef = cellRef
        action = "web.fetch"
        self.destinationHost = destinationHost
        self.method = method
        self.bytes = bytes
        self.credentialsUsed = credentialsUsed
        self.decisionStatus = decisionStatus
        self.reason = reason
        self.executionStatus = executionStatus
        self.bindings = bindings
        self.createdAt = createdAt
        self.signature = signature
        try validateMetadata()
    }

    public func signed(by signer: Identity) async throws -> EffectReceipt {
        var copy = self
        copy.createdAt = try AgentTrustPackageCanonicalEncoder.rfc3339UTC(createdAt)
        copy.signature = nil
        copy.signature = try await ReceiptSigning.sign(copy, createdAt: copy.createdAt, by: signer)
        return copy
    }

    public func verify(against signer: Identity) -> ReceiptSignatureVerification {
        guard let signature else { return .unsigned }
        var unsigned = self
        unsigned.signature = nil
        guard let timestamp = try? AgentTrustPackageCanonicalEncoder.rfc3339UTC(createdAt) else {
            return .invalid
        }
        unsigned.createdAt = timestamp
        return ReceiptSigning.verify(unsigned, signature: signature, createdAt: timestamp, against: signer)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(String.self, forKey: .schema)
        receiptID = try c.decode(String.self, forKey: .receiptID)
        cellRef = try c.decode(String.self, forKey: .cellRef)
        action = try c.decode(String.self, forKey: .action)
        destinationHost = try c.decode(String.self, forKey: .destinationHost)
        method = try c.decode(String.self, forKey: .method)
        bytes = try c.decode(Int.self, forKey: .bytes)
        credentialsUsed = try c.decode(Bool.self, forKey: .credentialsUsed)
        decisionStatus = try c.decode(PurposeDecisionStatus.self, forKey: .decisionStatus)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        executionStatus = try c.decode(PurposeExecutionStatus.self, forKey: .executionStatus)
        bindings = try c.decode(Bindings.self, forKey: .bindings)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        signature = try c.decodeIfPresent(ReceiptSignature.self, forKey: .signature)
        try validateMetadata()
    }

    public func encode(to encoder: Encoder) throws {
        try validateMetadata()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(receiptID, forKey: .receiptID)
        try c.encode(cellRef, forKey: .cellRef)
        try c.encode(action, forKey: .action)
        try c.encode(destinationHost, forKey: .destinationHost)
        try c.encode(method, forKey: .method)
        try c.encode(bytes, forKey: .bytes)
        try c.encode(credentialsUsed, forKey: .credentialsUsed)
        try c.encode(decisionStatus, forKey: .decisionStatus)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encode(executionStatus, forKey: .executionStatus)
        try c.encode(bindings, forKey: .bindings)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(signature, forKey: .signature)
    }

    private func validateMetadata() throws {
        let url = URLComponents(string: "https://\(destinationHost)")
        let hostOnly = destinationHost.isEmpty || (
            url?.host == destinationHost && url?.port == nil && url?.user == nil
                && url?.password == nil && url?.path == "" && url?.query == nil && url?.fragment == nil
        )
        guard schema == Self.schemaV0, action == "web.fetch", bytes >= 0, hostOnly,
              method.range(of: #"\A[A-Z]{1,16}\z"#, options: .regularExpression) != nil,
              reason.map({ $0.range(of: #"\A[a-z0-9_]{1,128}\z"#, options: .regularExpression) != nil }) ?? true else {
            throw ReceiptSigningError.invalidEffectMetadata
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schema, receiptID, cellRef, action, destinationHost, method, bytes
        case credentialsUsed, decisionStatus, reason, executionStatus, bindings, createdAt, signature
    }
}
