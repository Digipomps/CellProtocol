// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import Foundation

/// A one-shot owner command. The signed timestamp establishes a persistent
/// subject cutoff: older admission/renewal signatures cannot restore access.
public struct ContractRevocation: Codable {
    public var cellUUID: String
    public var subjectUUID: String
    public var contractUUID: String
    public var agreementUUID: String
    public var domain: String
    public var issuedAt: TimeInterval
    public var nonce: String
    public var signature: Data?

    private struct Payload: Codable {
        let purpose: String
        let cellUUID: String
        let subjectUUID: String
        let contractUUID: String
        let agreementUUID: String
        let domain: String
        let issuedAt: TimeInterval
        let nonce: String
    }
    private func signingData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Payload(purpose: "haven.contract.revocation.v1",
            cellUUID: cellUUID, subjectUUID: subjectUUID, contractUUID: contractUUID,
            agreementUUID: agreementUUID, domain: domain, issuedAt: issuedAt, nonce: nonce))
    }
    public static func signed(contract: Contract, owner: Identity, at date: Date = Date()) async throws -> Self {
        guard let cellUUID = contract.targetCellUUID else { throw ContractError.signingFailed }
        var result = Self(cellUUID: cellUUID, subjectUUID: contract.subject.uuid,
            contractUUID: contract.uuid, agreementUUID: contract.agreement.uuid,
            domain: contract.domain, issuedAt: date.timeIntervalSince1970,
            nonce: UUID().uuidString, signature: nil)
        guard let signature = try await owner.sign(data: result.signingData()) else { throw ContractError.signingFailed }
        result.signature = signature
        return result
    }
    public func verify(owner: Identity) -> Bool {
        guard issuedAt.isFinite, UUID(uuidString: nonce) != nil,
              let signature, let data = try? signingData() else { return false }
        return IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: data, identity: owner)
    }
}
