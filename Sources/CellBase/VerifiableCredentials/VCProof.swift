// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

public enum ProofPurpose : String, Codable {
    case assertionMethod
    case authentication
}

public class VCProof : Codable {
    public var type: ProofType
    public var created: Date
    public var proofPurpose: ProofPurpose
    public var verificationMethod: String
    public var signatureData: Data = Data()
    
    private var signingCancellable: AnyCancellable?
    
    enum CodingKeys: String, CodingKey
    {
        case type
        case created
        case proofPurpose
        case verificationMethod
        case signatureData
    }
    
    public init(proofPurpose: ProofPurpose, issuerIdentity: Identity) {
        self.proofPurpose = proofPurpose
        self.created = Date()
        self.verificationMethod = issuerIdentity.uuid
        self.type = .EcdsaSecp256r1Signature2019 // Extract from identity
        
//        self.signatureData /*= Data()*/
    }
    
//     func setSignature(_ payload: ValueType, for issuerIdentity: Identity) async throws {
//        
//         self.signatureData = try await self.signPayload(payload, for: issuerIdentity)
//    }
    
//    func signPayload(_ payload: ValueType, for issuerDIDDocument: DIDDocument) async throws -> Data {
//        return try await signPayload(payload, for: issuerDIDDocument.)
//    }
    
    func signPayload(_ claim: VCClaim, for issuerIdentity: Identity) async throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let jsonPayloadData = try encoder.encode(claim)
        
        if let signatureData = try await  issuerIdentity.sign(data: jsonPayloadData) {
            return signatureData
        }
        
        throw IdentityVaultError.signingFailed
    }
    
    func verifySignatureData(signedData: Data, payload: ValueType, issuerIdentity: Identity) async throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let jsonPayloadData = try encoder.encode(payload)
        
        return await issuerIdentity.verify(signature: signedData, for: jsonPayloadData)
    }
    
    required public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(ProofType.self, forKey: .type)
        let createdString = try values.decode(String.self, forKey: .created)
        CellBase.diagnosticLog("VCProof decode created=\(createdString)", domain: .credentials)
        let RFC3339DateFormatter = DateFormatter()
        RFC3339DateFormatter.locale = Locale(identifier: "en_US_POSIX")
        RFC3339DateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        RFC3339DateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        created = RFC3339DateFormatter.date(from: createdString)! // Should throw instead
        proofPurpose = try values.decode(ProofPurpose.self, forKey: .proofPurpose)
        verificationMethod = try values.decode(String.self, forKey: .verificationMethod)
        signatureData = try values.decode(Data.self, forKey: .signatureData)
    }
    
     public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        
        // 2010-01-01T00:00:00Z
        let RFC3339DateFormatter = DateFormatter()
        RFC3339DateFormatter.locale = Locale(identifier: "en_US_POSIX")
        RFC3339DateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        RFC3339DateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        let dateString = RFC3339DateFormatter.string(from: created)
        try container.encode(dateString, forKey: .created)
        
        try container.encode(proofPurpose, forKey: .proofPurpose)
        try container.encode(verificationMethod, forKey: .verificationMethod)
        try container.encode(signatureData, forKey: .signatureData)
    }
}
