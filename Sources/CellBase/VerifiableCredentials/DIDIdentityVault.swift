// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 16/04/2024.
//

import Foundation
#if canImport(Combine)
import Combine
import CryptoKit
#else
import OpenCombine
import Crypto
#endif

enum DIDIdentityVaultError: Error {
    case signingUnsupported
}

actor DIDIdentityVault: IdentityVaultProtocol, ScopedSecretProviderProtocol {
    
    
    func initialize() async -> any IdentityVaultProtocol {
        return self
    }
    
    func addIdentity(identity: inout Identity, for identityContext: String) async {
        
    }
    
    func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity? {
        return nil
    }
    
    func saveIdentity(_ identity: Identity) async {
        
    }
    
    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        throw DIDIdentityVaultError.signingUnsupported
    }
    
    
    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool {
        IdentityPublicKeySignatureVerifier.verify(
            signature: signature,
            messageData: messageData,
            identity: identity
        )
    }
    
    // Should this be part of IdentityVault protocol?
    func verifySignature(signature: Data, messageData: Data, for publicKey: Data, curveType: CurveType = .Curve25519) async throws -> Bool {
        switch curveType {
        case .Curve25519:
                CellBase.diagnosticLog("DIDIdentityVault verifying Curve25519 signature", domain: .credentials)
            
                let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
                return key.isValidSignature(signature, for: messageData)
        case .P256:
            CellBase.diagnosticLog("DIDIdentityVault verifying ECDSA P-256-compatible signature", domain: .credentials)
            if let publicSigningKey = try? P256.Signing.PublicKey(x963Representation: publicKey),
               let ecdsaSignature = try? P256.Signing.ECDSASignature(derRepresentation: signature) {
                return publicSigningKey.isValidSignature(ecdsaSignature, for: messageData)
            }
        case .secp256k1:
            return false
        }
        
        
            return false
        }
    func randomBytes64() async -> Data? {
            return nil
    }
    
    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) {  // This shouldent be here
        return (key: "Not", iv: "supposed to be here")
    }

    func scopedSecretData(tag: String, minimumLength: Int) async throws -> Data {
        throw ScopedSecretProviderError.unavailable
    }
    
    
}
