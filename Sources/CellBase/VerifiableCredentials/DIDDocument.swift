// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 06/02/2024.
//

import Foundation

/*
 {
   "@context": [
     "https://www.w3.org/ns/did/v1",
     "https://w3id.org/security/suites/ed25519-2020/v1"
   ]
   "id": "did:example:123456789abcdefghi",
   "authentication": [{
     // used to authenticate as did:...fghi
     "id": "did:example:123456789abcdefghi#keys-1",
     "type": "Ed25519VerificationKey2020",
     "controller": "did:example:123456789abcdefghi",
     "publicKeyMultibase": "zH3C2AVvLMv6gmMNam3uVAjZpfkcJCwDwnZn6z3wXmqPV"
   }]
 }
 
 did:cell:<UUID>
 
 */

/*
 id    yes    A string that conforms to the rules in 3.2 DID URL Syntax.
 controller    yes    A string that conforms to the rules in 3.1 DID Syntax.
 type    yes    A string.
 publicKeyJwk    no    A map representing a JSON Web Key that conforms to [RFC7517]. See definition of publicKeyJwk for additional constraints.
 publicKeyMultibase    no    A string that conforms to a [MULTIBASE] encoded public key.
 */

public enum PublicKeyType: Codable { //  TODO: ensure that this encodes / decodes according to spec (DID)
    case publicKeyMultibase(String)
    case publicBase58(String)
    case publicKeyJwk(PublicKeyJwk)
    
}

/*
 "publicKeyJwk": {
   "kid": "urn:ietf:params:oauth:jwk-thumbprint:sha-256:FfMbzOjMmQ4efT6kvwTIJjelTqjl0xjEIWQ2qobsRMM",
   "kty": "OKP",
   "crv": "Ed25519",
   "alg": "EdDSA",
   "x": "ANRjH_zxcKBxsjRPUtzRbp7FSVLKJXQ9APX9MP1j7k4"
 }
 */

// Use existing?
public enum Curve: String, Codable {
    case Ed25519
    case secp256k1
    case P256 = "P-256"
}

public enum Algorithm:String, Codable {
    case EdDSA
    case ES256
}


public struct PublicKeyJwk: Codable {
    var kid: String?
    var kty: String // enum?
    var crv: Curve
    var alg: Algorithm?
    var x: String? // public key data as base64
    var d: String?// private key as base64
}


struct DIDVerificationMethod: Codable { // Same as DID authentication?
    let id: String
    let type: DIDAuthentiactionType
    let controller:String
    let publicKeyType: PublicKeyType

    init(id: String, type: DIDAuthentiactionType, controller: String, publicKeyType: PublicKeyType) {
        self.id = id
        self.type = type
        self.controller = controller
        self.publicKeyType = publicKeyType
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case type
        case controller
        case publicKeyJwk
        case base58
        case multiBase
        case publicKeyMultibase
        
    }
    
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        type = try values.decode(DIDAuthentiactionType.self, forKey: .type)
        controller = try values.decode(String.self, forKey: .controller)
        
        if let publicKeyJwk = try values.decodeIfPresent(PublicKeyJwk.self, forKey: .publicKeyJwk) {
            publicKeyType = .publicKeyJwk(publicKeyJwk)
        } else if let base58 = try values.decodeIfPresent(String.self, forKey: .base58) {
            publicKeyType = .publicBase58(base58) //
        } else if let multiBase = try values.decodeIfPresent(String.self, forKey: .publicKeyMultibase) {
            publicKeyType = .publicKeyMultibase(multiBase) //
        } else {
            throw DIDError.noPublicKeyType
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        switch publicKeyType {
        case .publicBase58(let base58):
            try container.encode(base58, forKey: .base58)
        case .publicKeyJwk(let jwk):
            try container.encode(jwk, forKey: .publicKeyJwk)
        case .publicKeyMultibase(let multibase):
            try container.encode(multibase, forKey: .publicKeyMultibase)
        }
    }
    
}


enum DIDVerification: Codable {
    case embedded(DIDVerificationMethod)
    case reference(String)
    
    // write decoding encoding methods...
    public init(from decoder: Decoder) throws {
        do {
            let singleValueContainer = try decoder.singleValueContainer()
            let value = try singleValueContainer.decode(DIDVerificationMethod.self)
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

struct Authentication: Codable {
    
}

enum DIDAuthentication : Codable {
    case embedded(DIDAuthenticationEmbedded)
    case reference(String)
    
    public init(from decoder: Decoder) throws {
        do {
            let singleValueContainer = try decoder.singleValueContainer()
            let value = try singleValueContainer.decode(DIDAuthenticationEmbedded.self)
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

enum DIDService {
    case embedded(DIDServiceEmbedded)
    case reference(String)
    
    public init(from decoder: Decoder) throws {
        do {
            let singleValueContainer = try decoder.singleValueContainer()
            let value = try singleValueContainer.decode(DIDServiceEmbedded.self)
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

//enum Multitype: Decodable {
//    case string(String)
//    case object(Object)
//    case list(ValueTypeList)
//}

struct DIDServiceEmbedded: Codable {
    let id: String
    let type: DIDAuthentiactionType
    let serviceEndpoint: URL
}

enum DIDAuthentiactionType: String, Codable {
    case Ed25519VerificationKey2020
    case Ed25519VerificationKey2018
    case JsonWebKey2020
    case Multikey
}

struct DIDURL : Codable {
    let method: String
    let identificator: String
    
    init(from urlString: String) {
        method = ""
        identificator = ""
    }
    
    func urlString() -> String {
        return "\(method):\(identificator)"
    }
}

struct DIDAuthenticationEmbedded: Codable {
    let id: String
    let type: DIDAuthentiactionType
    let controller:DIDURL
    let publicKeyMultibase: String // enum of types assiciated with string?
}

public struct DIDDocument : Codable {
    let id: String // Should we make it's own type?
    let context: ValueType
    let authentications: [DIDAuthentication]?
    let verificationMethods: [DIDVerificationMethod]?
    var verificationMethodsDict: [String : DIDVerificationMethod] = [:]
    let assertionMethods: [DIDVerification]? // Change to set of VerificationMethod or String (as enum?)
    
    var keyAgreements: [DIDVerification]?
    var capabilityInvocations: [DIDVerification]?
    var capabilityDelegations: [DIDVerification]?
    var services: [String]? = nil
    
    enum CodingKeys: String, CodingKey {
        case context = "@context"
        case id
        case type
        case verificationMethods = "verificationMethod"
        case authentications = "authentication"
        case assertionMethods = "assertionMethod"
        case keyAgreements = "keyAgreement"
        case capabilityInvocations = "capabilityInvocation"
        case capabilityDelegations = "capabilityDelegation"
        case services = "service"
        case alsoKnownAs
        case controller
    }
    
    init(with identity: Identity, method: DidMethod = .key, urlString: String? = nil) throws {
        guard let publicKeyData = identity.publicSecureKey?.compressedKey,
              let curveType = identity.publicSecureKey?.curveType else {
            throw DIDError.noPublicKey
        }

        let did = try identity.did(urlString, type: method)
        let multibase = try DIDKeyParser.multibaseEncodedPublicKey(publicKeyData, curveType: curveType)
        let keyId = "\(did)#\(multibase)"
        let verificationMethod = DIDVerificationMethod(
            id: keyId,
            type: .Multikey,
            controller: did,
            publicKeyType: .publicKeyMultibase(multibase)
        )

        id = did
        context = .list([
            .string("https://www.w3.org/ns/did/v1"),
            .string("https://w3id.org/security/multikey/v1")
        ])
        verificationMethods = [verificationMethod]
        verificationMethodsDict = [keyId: verificationMethod]
        authentications = [.reference(keyId)]
        assertionMethods = [.reference(keyId)]
        keyAgreements = nil
        capabilityInvocations = nil
        capabilityDelegations = nil
        services = nil
    }
    
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try values.decode(String.self, forKey: .id)
        context = try values.decode(ValueType.self, forKey: .context)

            verificationMethods = try values.decode([DIDVerificationMethod].self, forKey: .verificationMethods)
        
        
        if verificationMethods != nil {
            for verificationMethod in verificationMethods! {
                verificationMethodsDict[verificationMethod.id] = verificationMethod
            }
        }
        
        authentications = try values.decodeIfPresent([DIDAuthentication].self, forKey: .authentications)
        assertionMethods = try values.decodeIfPresent([DIDVerification].self, forKey: .assertionMethods)
        keyAgreements = try values.decodeIfPresent([DIDVerification].self, forKey: .keyAgreements)
        capabilityInvocations = try values.decodeIfPresent([DIDVerification].self, forKey: .capabilityInvocations)
        capabilityDelegations = try values.decodeIfPresent([DIDVerification].self, forKey: .capabilityDelegations)
        services = try values.decodeIfPresent([String].self, forKey: .services)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(context, forKey: .context)
        
        if let authentications = authentications {
            try container.encode(authentications, forKey: .authentications)
        }
        
        if let verificationMethods = verificationMethods {
            try container.encode(verificationMethods, forKey: .verificationMethods)
        }
        
        if let assertionMethods = assertionMethods {
            try container.encode(assertionMethods, forKey: .assertionMethods)
        }
        
        if let keyAgreements = keyAgreements {
            try container.encode(keyAgreements, forKey: .keyAgreements)
        }
        
        if let capabilityInvocations = capabilityInvocations {
            try container.encode(capabilityInvocations, forKey: .capabilityInvocations)
        }

        if let capabilityDelegations = capabilityDelegations {
            try container.encode(capabilityDelegations, forKey: .capabilityDelegations)
        }
        
        if let services = services {
            try container.encode(services, forKey: .services)
        }

        
    }
    
    public enum VCKeyUse {
        case verification
        case assertion
        case authentication
        case keyAgreement
    }
    
    public func identity(use vcKeyUse: VCKeyUse = .verification) throws -> Identity { // Should we indicate what we intend to use it for?
        
        let identityVault = DIDIdentityVault()
        
        
        
        var verificationMethod: DIDVerificationMethod? = nil
        switch vcKeyUse {
        case .verification: // verification used for other lookups
            CellBase.diagnosticLog("DIDDocument.identity use=verification", domain: .credentials)
            if let verificationMethods = self.verificationMethods,
               verificationMethods.count > 0
            {
                verificationMethod = verificationMethods[0] // there may be
            }
            
        case .assertion:
            CellBase.diagnosticLog("DIDDocument.identity use=assertion", domain: .credentials)
            
        case .authentication:
            CellBase.diagnosticLog("DIDDocument.identity use=authentication", domain: .credentials)
            
        case .keyAgreement:
            CellBase.diagnosticLog("DIDDocument.identity use=keyAgreement", domain: .credentials)
        }
        
        guard let selectedVerificationMethod = verificationMethod else {
            throw DIDError.noVerificationMethod
        }
        
        /*
         When validating VCs we ask for assertion methods - which may be embedded or
         */
        
        let identity = Identity(self.id, displayName: self.id, identityVault: identityVault)
        
        // use - probably given
        //algorithm
        
        identity.publicSecureKey = try self.verificationMethod2SecureKey(vcKeyUse)
        
        return identity
    }
    
    // testing
    func verificationMethod2SecureKey(_ vcKeyUse: VCKeyUse) throws -> SecureKey {
        
        let verificationMethod = try self.verificationMethodForKeyUse(vcKeyUse)
        
        let publicSecureKey = try self.verificationMethod2SecureKey(verificationMethod)
        
        return publicSecureKey
    }
    
    func verificationMethodForKeyUse(_ vcKeyUse: VCKeyUse) throws -> DIDVerificationMethod {
        var verificationMethod: DIDVerificationMethod? = nil
        switch vcKeyUse {
        case .verification: // verification used for other lookups
            CellBase.diagnosticLog("DIDDocument.verificationMethodForKeyUse use=verification", domain: .credentials)
            if let verificationMethods = self.verificationMethods,
               verificationMethods.count > 0
            {
                verificationMethod = verificationMethods[0] // there may be
            }
            
        case .assertion:
            CellBase.diagnosticLog("DIDDocument.verificationMethodForKeyUse use=assertion", domain: .credentials)
            
        case .authentication:
            CellBase.diagnosticLog("DIDDocument.verificationMethodForKeyUse use=authentication", domain: .credentials)
            
        case .keyAgreement:
            CellBase.diagnosticLog("DIDDocument.verificationMethodForKeyUse use=keyAgreement", domain: .credentials)
        }
        
        guard let selectedVerificationMethod = verificationMethod else {
            throw DIDError.noVerificationMethod
        }
        return selectedVerificationMethod
    }
    
    func verificationMethod2SecureKey(_ verificationMethod: DIDVerificationMethod) throws -> SecureKey {
        
        let date = Date()
        
        switch verificationMethod.type {
        case .Ed25519VerificationKey2020:
            CellBase.diagnosticLog("DIDDocument key type=Ed25519VerificationKey2020", domain: .credentials)
        case .Ed25519VerificationKey2018:
            CellBase.diagnosticLog("DIDDocument key type=Ed25519VerificationKey2018", domain: .credentials)
        case .JsonWebKey2020:
            CellBase.diagnosticLog("DIDDocument key type=JsonWebKey2020", domain: .credentials)
        case .Multikey:
            CellBase.diagnosticLog("DIDDocument key type=Multikey", domain: .credentials)
        }
        /*
         OKP    Ed25519     EdDSA           ECDH-ES+A256KW
         OKP    X25519      ECDH            ECDH-ES+A256KW
         EC     secp256k1   ES256K  ECDH    ECDH-ES+A256KW
         EC     P-256       ES256   ECDH    ECDH-ES+A256KW
         EC     P-384       ES384   ECDH    ECDH-ES+A256KW
         RSA    2048+       PS256           RSA-OAEP
    
         OKP x: public key in base64url d: private key
         */
        
        var keyUse = KeyUse.signature
        var curveType = CurveType.Curve25519
        var algorithm = CurveAlgorithm.EdDSA
        var publicKeyData = Data()
        
        switch verificationMethod.publicKeyType {
        case .publicKeyMultibase(let string):
            if string.starts(with: "z") {
                let decoded = try DIDKeyParser.decodeMultikey(string)
                publicKeyData = decoded.publicKey
                switch decoded.curveType {
                case .Curve25519:
                    curveType = .Curve25519
                    algorithm = .EdDSA
                case .secp256k1:
                    curveType = .secp256k1
                    algorithm = .ECDSA
                case .P256:
                    curveType = .P256
                    algorithm = .ECDSA
                }
            }
            CellBase.diagnosticLog("DIDDocument publicKeyMultibase encountered", domain: .credentials)
        case .publicBase58(let string):
            CellBase.diagnosticLog("DIDDocument publicBase58 encountered", domain: .credentials)
        case .publicKeyJwk(let publicKeyJwk):
            if let publicKeyDataBase64 = publicKeyJwk.x,
                    let keydata = Data(base64Encoded: publicKeyDataBase64)
            {
                publicKeyData = keydata
                
                switch publicKeyJwk.crv {
                case .Ed25519:
                     curveType = CurveType.Curve25519
                case .secp256k1:
                    curveType = CurveType.secp256k1
                case .P256:
                    curveType = CurveType.P256
                }
                switch publicKeyJwk.alg {
                    
                case .EdDSA:
                    algorithm = .EdDSA
                case .ES256:
                    algorithm = .ECDSA
                case .none: ()
                    
                }
            }
        }
    // check what to do with type
        let secureKey = SecureKey(date: date, privateKey: false, use: keyUse, algorithm: algorithm, size: 256, curveType: curveType, x: nil, y:nil, compressedKey: publicKeyData) // x and y here is related to the elliptic curve
        
       
        return secureKey
    }
    
    func getpublickey(verificationMethods: [DIDVerificationMethod]) -> SecureKey {
        let publicKey = SecureKey(date: Date(), privateKey: false, use: .signature, algorithm: .EdDSA, size: 256, curveType: .Curve25519, x: nil, y:nil, compressedKey: nil)
        
        
        return publicKey

    }
    

}


enum DIDError: Error {
    case noVerificationMethod
    case noPublicKeyType
    case noPublicKey
    case invalidDID
    case failedUserInfoKey
}
