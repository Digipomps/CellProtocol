// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 04/04/2024.
//

import Foundation

public struct VCPresentation: Codable {
    public let uuid: String
    public var context: [String]? // Future use - to be interoperable with vc standard
    public var id: String
    public var type: [String] // How to define/describe what type of claim this is
    public var holder: IssuerType
    public var challenge: Data?
    public var domain: String?
    public var holderBinding: IdentityPublicKeyDescriptor?
    
//    public var issuanceDate: Date
//    public var credentialSubject: Object // may be list or object
    public var proof: VCProof
    
    public var verifiableCredential: [VCClaim]?
    
    private var encodeProof = true
    
    enum CodingKeys: String, CodingKey {
        case uuid
        case context = "@context"
        case id
        case type
        case holder
        case challenge
        case domain
        case holderBinding
        case verifiableCredential
//        case issuer //
//        case issuanceDate
//        case credentialSubject
        case proof
    }
    
    public init(type: String, holderIdentity: Identity, subjectIdentity: Identity, verifiableCredentials: [VCClaim]) async throws {
        self.uuid = UUID().uuidString
        context = ["https://www.w3.org/2018/credentials/v1", "https://www.w3.org/2018/credentials/examples/v1"]
        //   "id": "http://example.edu/credentials/1872"
        self.id = "cell:///identity/\(subjectIdentity.uuid)/claims/\(self.uuid)" // Id of claim?
        self.type = ["VerifiableCredential", type]
        self.holder = .reference(try holderIdentity.did())
        self.challenge = nil
        self.domain = nil
        self.holderBinding = try? Self.identityDescriptor(for: holderIdentity)
        
        self.verifiableCredential = verifiableCredentials
        self.proof = VCProof(proofPurpose: .assertionMethod, issuerIdentity: holderIdentity)
        
        
        //try await self.proof.setSignature(.object(credentialSubject), for: issuerIdentity) // TODO: sign for CredentialSubject struct
        
    }
    
    // initializer for use in swiftui preview
    public init(holderIdentity: Identity, subjectIdentity: Identity, verifiableCredentials: [VCClaim]) {
        self.uuid = UUID().uuidString
        context = ["https://www.w3.org/2018/credentials/v1", "https://www.w3.org/2018/credentials/examples/v1"]
        self.id = "cell:///identity/\(subjectIdentity.uuid)/claims/\(self.uuid)" // Id of claim?
        self.type = ["VerifiableCredential", "type"]
        if let holderDID = try? holderIdentity.did() {
            self.holder = .reference(holderDID)
        } else {
            self.holder = .reference("did:err:missing_issuer")
        }
        self.challenge = nil
        self.domain = nil
        self.holderBinding = try? Self.identityDescriptor(for: holderIdentity)
        
        self.verifiableCredential = verifiableCredentials
        self.proof = VCProof(proofPurpose: .assertionMethod, issuerIdentity: holderIdentity)
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
        context = try values.decodeIfPresent([String].self, forKey: .context)
        id = try values.decode(String.self, forKey: .id)
        type = try values.decode([String].self, forKey: .type)
        holder = try values.decode(IssuerType.self, forKey: .holder)
        challenge = try values.decodeIfPresent(Data.self, forKey: .challenge)
        domain = try values.decodeIfPresent(String.self, forKey: .domain)
        holderBinding = try values.decodeIfPresent(IdentityPublicKeyDescriptor.self, forKey: .holderBinding)

//
        verifiableCredential = try values.decodeIfPresent([VCClaim].self, forKey: .verifiableCredential)
        proof = try values.decode(VCProof.self, forKey: .proof)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if context != nil {
            try container.encode(context, forKey: .context)
        }
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(holder, forKey: .holder)
        try container.encodeIfPresent(challenge, forKey: .challenge)
        try container.encodeIfPresent(domain, forKey: .domain)
        try container.encodeIfPresent(holderBinding, forKey: .holderBinding)
        
        
        try container.encode(verifiableCredential, forKey: .verifiableCredential)
        
        if self.encodeProof {
            try container.encode(proof, forKey: .proof)
        }
    }

    public mutating func bindAndSign(
        holderIdentity: Identity,
        challenge: Data,
        domain: String
    ) async throws {
        self.holder = .reference(try holderIdentity.did())
        self.challenge = challenge
        self.domain = domain
        self.holderBinding = try Self.identityDescriptor(for: holderIdentity)
        self.proof = VCProof(proofPurpose: .authentication, issuerIdentity: holderIdentity)
        let payload = try canonicalPayloadData()
        guard let signature = try await holderIdentity.sign(data: payload) else {
            throw IdentityVaultError.signingFailed
        }
        self.proof.signatureData = signature
    }

    public func canonicalPayloadData() throws -> Data {
        var copy = self
        copy.encodeProof = false
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return try encoder.encode(copy)
    }

    public func verifyHolderProof(
        expectedChallenge: Data,
        expectedDomain: String
    ) async throws -> Bool {
        guard challenge == expectedChallenge,
              domain == expectedDomain,
              let holderBinding,
              proof.proofPurpose == .authentication,
              proof.verificationMethod == holderBinding.uuid,
              proof.signatureData.isEmpty == false else {
            return false
        }

        let descriptorIdentity = Identity(
            holderBinding.uuid,
            displayName: holderBinding.displayName ?? holderBinding.uuid,
            identityVault: nil
        )
        descriptorIdentity.publicSecureKey = SecureKey(
            date: Date(timeIntervalSince1970: 0),
            privateKey: false,
            use: .signature,
            algorithm: holderBinding.algorithm,
            size: holderBinding.publicKey.count * 8,
            curveType: holderBinding.curveType,
            x: nil,
            y: nil,
            compressedKey: holderBinding.publicKey
        )
        guard case let .reference(holderDID) = holder,
              holderDID == (try? descriptorIdentity.did()),
              proof.type == VCProof.proofType(for: descriptorIdentity) else {
            return false
        }
        return IdentityPublicKeySignatureVerifier.verify(
            signature: proof.signatureData,
            messageData: try canonicalPayloadData(),
            descriptor: holderBinding
        )
    }

    private static func identityDescriptor(for identity: Identity) throws -> IdentityPublicKeyDescriptor {
        guard let publicSecureKey = identity.publicSecureKey,
              let publicKey = publicSecureKey.compressedKey else {
            throw DIDError.noPublicKey
        }
        return IdentityPublicKeyDescriptor(
            uuid: identity.uuid,
            displayName: identity.displayName,
            publicKey: publicKey,
            algorithm: publicSecureKey.algorithm,
            curveType: publicSecureKey.curveType
        )
    }
}
