// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation


public enum IssuerType: Codable {
    case reference(String)
    case embedded(Object)
    
    public init(from decoder: Decoder) throws {
        do {
            let singleValueContainer = try decoder.singleValueContainer()
            let value = try singleValueContainer.decode(Object.self)
            self = .embedded(value)
            return
        } catch {}
        do {
            let singleValueContainer = try decoder.singleValueContainer()
            let value = try singleValueContainer.decode(String.self)
            self = .reference(value)
            return
        } catch {}
        
        throw DIDError.noVerificationMethod
        
        
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .reference(value):
            try container.encode(value) //
        case let .embedded(value):
            try container.encode(value)
        }
    }
}

public struct CredentialSubject: Codable {
     var id: String
     var claim: ValueType
     var claimLabel: String
    
    
    public init(id: String, claim: ValueType, claimLabel: String) {
        self.id = id
        self.claim = claim
        self.claimLabel = claimLabel
    }
    
    public func valueType() -> ValueType {
        let credentialSubjectObject: Object = ["id" : .string(self.id), self.claimLabel : self.claim]
        
        return .object(credentialSubjectObject)
    }
}

// first step into veryfiable creadential standard
public struct VCClaim: Codable {
    public let uuid: String
    public var context: [String]? // Future use - to be interoperable with vc standard
    public var id: String // The id property is OPTIONAL. If present, id property's value MUST be a single URL
    public var type: [String] // How to define/describe what type of claim this is
    public var issuer: IssuerType
    public var issuanceDate: Date
    public var credentialSubject: Object // may be list or object
    public var proof: VCProof
    
    
    enum CodingKeys: String, CodingKey {
        case uuid
        case context = "@context"
        case id
        case type
        case issuer
        case issuanceDate
        case credentialSubject
        case proof
    }
    
    public init(type: String, issuerIdentity: Identity, subjectIdentity: Identity, credentialSubject: Object) async throws {
        self.uuid = UUID().uuidString
        context = ["https://www.w3.org/2018/credentials/v1", "https://www.w3.org/2018/credentials/examples/v1"]
        //   "id": "http://example.edu/credentials/1872"
        self.id = "cell:///identity/\(subjectIdentity.uuid)/claims/\(self.uuid)" // Id of claim?
        self.type = ["VerifiableCredential", type]
        self.issuer = .reference(try issuerIdentity.did())
        self.issuanceDate = Date()
        
        self.credentialSubject = credentialSubject
        self.proof = VCProof(proofPurpose: .assertionMethod, issuerIdentity: issuerIdentity)
        
        
        //try await self.proof.setSignature(.object(credentialSubject), for: issuerIdentity) // TODO: sign for CredentialSubject struct
        
    }
    
    // initializer for use in swiftui preview
    public init(issuerIdentity: Identity, subjectIdentity: Identity, credentialSubject: Object) {
        self.uuid = UUID().uuidString
        context = ["https://www.w3.org/2018/credentials/v1", "https://www.w3.org/2018/credentials/examples/v1"]
        self.id = "cell:///identity/\(subjectIdentity.uuid)/claims/\(self.uuid)" // Id of claim?
        self.type = ["VerifiableCredential", "type"]
        if let issuerIdentity = try? issuerIdentity.did() {
            self.issuer = .reference(issuerIdentity)
        } else {
            self.issuer = .reference("did:err:missing_issuer")
        }
        self.issuanceDate = Date()
        
        self.credentialSubject =  credentialSubject
        if let did  = try? subjectIdentity.did() {
            self.credentialSubject["id"] = .string(did)
        }
        self.proof = VCProof(proofPurpose: .assertionMethod, issuerIdentity: issuerIdentity)
//        Task {
//            try await self.proof.setSignature(credentialSubject, for: issuerIdentity)
//        }
    }
    
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let tmpUuid = try values.decodeIfPresent(String.self, forKey: .uuid) {
            uuid = tmpUuid
        } else {
            uuid = UUID().uuidString
        }
        context = try? values.decodeIfPresent([String].self, forKey: .context)
        id = try values.decode(String.self, forKey: .id)
        type = try values.decode([String].self, forKey: .type)
        issuer = try values.decode(IssuerType.self, forKey: .issuer)
        let issuanceDateString = try values.decode(String.self, forKey: .issuanceDate)
        CellBase.diagnosticLog("VCClaim decode issuanceDate=\(issuanceDateString)", domain: .credentials)
        let RFC3339DateFormatter = DateFormatter()
        RFC3339DateFormatter.locale = Locale(identifier: "en_US_POSIX")
        RFC3339DateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        RFC3339DateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        issuanceDate = RFC3339DateFormatter.date(from: issuanceDateString)! // Should throw instead
//        issuanceDate = try values.decode(Date.self, forKey: .issuanceDate)
        credentialSubject = try values.decode(Object.self, forKey: .credentialSubject)
        proof = try values.decode(VCProof.self, forKey: .proof)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if context != nil {
            try container.encode(context, forKey: .context)
        }
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(issuer, forKey: .issuer)
        
        let RFC3339DateFormatter = DateFormatter()
        RFC3339DateFormatter.locale = Locale(identifier: "en_US_POSIX")
        RFC3339DateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        RFC3339DateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        let issuanceDateString = RFC3339DateFormatter.string(from: issuanceDate)
        
        try container.encode(issuanceDateString, forKey: .issuanceDate)
        try container.encode(credentialSubject, forKey: .credentialSubject)
        
        guard let userInfoKey = CodingUserInfoKey(rawValue: "skipProof") else {
            throw DIDError.failedUserInfoKey
        }
        if encoder.userInfo[userInfoKey] == nil {
            
            try container.encode(proof, forKey: .proof)
        }
    
    }
    
    
    // to verify we need the issuers public key - let's embed this in issuerIdentity. Data and signature is embedded in the VCClaim
    public func verify(issuer issuerIdentity: Identity) async throws -> Bool {
        // Should we verify that issuerIdentity is the same as in the claim?
        
        let encoder = JSONEncoder()
        guard let userInfoKey = CodingUserInfoKey(rawValue: "skipProof") else {
            throw DIDError.failedUserInfoKey
        }
        encoder.userInfo[userInfoKey] = true
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
            
            
        let claimJsonData = try encoder.encode(self)
        CellBase.diagnosticLog("VCClaim verify encoded payload prepared", domain: .credentials)
        encoder.userInfo[userInfoKey] = nil
            
        
        guard let identityVault = issuerIdentity.identityVault else {
            throw CellBaseError.noVault
        }
        return try await identityVault.verifySignature(signature: self.proof.signatureData, messageData: claimJsonData, for: issuerIdentity)
        
    }
    
    public func verify(diDocument: DIDDocument) async throws -> Bool {
        let publicSecureKey = try diDocument.verificationMethod2SecureKey(.verification)
        guard let compressedKey = publicSecureKey.compressedKey else {
            throw DIDError.noPublicKey
        }
        return try await self.verify(issuer: compressedKey, curveType: publicSecureKey.curveType)
    }
    
    public func verify(issuer issuerPublicKey: Data) async throws -> Bool {
        try await verify(issuer: issuerPublicKey, curveType: .Curve25519)
    }

    public func verify(issuer issuerPublicKey: Data, curveType: CurveType) async throws -> Bool {
        // Should we verify that issuerIdentity is the same as in the claim?
        
//        let issuerIdentity = Identity()
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        
        
        guard let userInfoKey = CodingUserInfoKey(rawValue: "skipProof") else {
            throw DIDError.failedUserInfoKey
        }
        encoder.userInfo[userInfoKey] = true
        let claimJsonData = try encoder.encode(self)
        encoder.userInfo[userInfoKey] = nil
        
        let identityVault = DIDIdentityVault()
        var validated = false
//        validated = try await identityVault.verifySignature(signature: self.proof.signatureData, messageData: messageData, for: issuerIdentity)
        
        
        validated = try await identityVault.verifySignature(signature: self.proof.signatureData, messageData: claimJsonData, for: issuerPublicKey, curveType: curveType)
        
        
        return validated
        
    }
    
    public func verify() async throws -> Bool {
        let verificationMaterial = try await getIssuerVerificationMaterial()
        return try await verify(issuer: verificationMaterial.publicKey, curveType: verificationMaterial.curveType)
    }
    
    func transformCredentialSubjectToValueType(_ credentialSubject: CredentialSubject) async throws -> ValueType {
        
        let credentialSubjectObject: Object = ["id" : .string(credentialSubject.id), credentialSubject.claimLabel : credentialSubject.claim]
        
        return .object(credentialSubjectObject)
    }
    
    
    func sign(with identity: Identity) async throws -> Data {
        return try await self.proof.signPayload(self, for: identity)
    }
    
    
    mutating public func generateProof(issuerIdentity: Identity) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        
        guard let userInfoKey = CodingUserInfoKey(rawValue: "skipProof") else {
            throw DIDError.failedUserInfoKey
        }
        encoder.userInfo[userInfoKey] = true
        let claimJsonData = try encoder.encode(self)
        CellBase.diagnosticLog("VCClaim generateProof encoded payload prepared", domain: .credentials)
        encoder.userInfo[userInfoKey] = nil
        if let signatureData = try await  issuerIdentity.sign(data: claimJsonData) {
            self.proof.signatureData = signatureData
        } else {
            throw IdentityVaultError.signingFailed
        }
    }
    
    func getIssuerVerificationMaterial() async throws -> (publicKey: Data, curveType: CurveType) {
        switch self.issuer {
        case .reference(let string):
            CellBase.diagnosticLog("VCClaim issuer reference=\(string)", domain: .credentials)
            if string.hasPrefix("did:key:") {
                let (_, _, curveType, publicKey, _) = try DIDKeyParser.extractPublicKeyAndDID(from: string)
                return (publicKey, curveType)
            } else {
                print("Get DID from Universal Resolver? ...anyway not implementet and it's nor running per now")
            }
            
        case .embedded:
            CellBase.diagnosticLog("VCClaim issuer embedded object encountered", domain: .credentials)
        }
        
        
        return (Data(), .Curve25519)
    }
    
    
    /*
     
     
     */
}
