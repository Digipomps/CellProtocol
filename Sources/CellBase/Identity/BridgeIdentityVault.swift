// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  CloudBridgeIdentityVault.swift
//  App
//
//  Created by Kjetil Hustveit on 02/11/2021.
//

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
import Crypto

// BridgeIdentityVault is a stateless adapter over an existing bridge reference.
// The bridge itself owns command correlation and synchronization.
public struct BridgeIdentityVault: IdentityVaultProtocol, ScopedSecretProviderProtocol, @unchecked Sendable {
    
    public init(cloudBridge: BridgeProtocol? = nil) {
        self.cloudBridge = cloudBridge
    }
    
    public func initialize() async -> IdentityVaultProtocol {
        return self
    }
    
    
    public func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) {
        return (key: "NA", iv: "NA")
    }

    public func scopedSecretData(tag: String, minimumLength: Int) async throws -> Data {
        throw ScopedSecretProviderError.unavailable
    }
    
    public func setPostAuthenticationInitializer(initializer: @escaping () -> ()) async {
        
    }
    
    public func randomBytes64() -> Data? {
        return randomData(count: 64)
    }
    
    var cloudBridge: BridgeProtocol?
    
    
    // This have to be reconsidered - not meaningful in multiuser server environment ... or?
    public func addIdentity(identity: inout Identity, for identityContext: String) {
        CellBase.diagnosticLog("BridgeIdentityVault.addIdentity uuid=\(identity.uuid)", domain: .identity)
        
        
    }
    
    // This have to be reconsidered - not meaningful in multiuser server environment ... or?
    public func identity(for identityContext: String, makeNewIfNotFound: Bool = true) -> Identity? {
        CellBase.diagnosticLog("BridgeIdentityVault.identity context=\(identityContext)", domain: .identity)
        return Identity(identityContext, displayName: "Not meaningful", identityVault: CellBase.defaultIdentityVault)
    }
    
    public func saveIdentity(_ identity: Identity) {
        CellBase.diagnosticLog("BridgeIdentityVault.saveIdentity uuid=\(identity.uuid)", domain: .identity)
        
    }
    
    public func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        guard let signaturePublisher = cloudBridge?.signMessageForIdentity(messageData: messageData, identity: identity) else {
            throw IdentityVaultError.publisherGone
        }
        return try await signaturePublisher.getOneWithTimeout(5)
    }
    
    let dispatchQueue = DispatchQueue.init(label: "Cloud Bridge Signing dispatch queue")
    
    // Legacy sync adapter retained for callers that still need a blocking bridge.
    public func signMessageForIdentityTransform(messageData: Data, identity: Identity) throws -> Data {
        let resultLock = NSLock()
        let semaphore = DispatchSemaphore(value: 0)
        var signedData: Data?
        var signingError: Error?
        
        guard let signaturePublisher = cloudBridge?.signMessageForIdentity(messageData: messageData, identity: identity) else {
            throw IdentityVaultError.publisherGone
        }
        let signCancellable = signaturePublisher
            .sink(receiveCompletion: { completion in
                if case .failure(let error) = completion {
                    resultLock.lock()
                    signingError = error
                    resultLock.unlock()
                }
                semaphore.signal()
            }, receiveValue: { data in
                resultLock.lock()
                signedData = data
                resultLock.unlock()
            })
        
        
        let timeout = DispatchTime.now() + .seconds(5)
        if semaphore.wait(timeout: timeout) == .timedOut {
            signCancellable.cancel()
            print("CloudBridgeIdentityVault sign semaphore timed out! ")
            throw IdentityVaultError.signingFailed
        }

        if let signingError {
            throw signingError
        }
        
        if signedData == nil || signedData!.count == 0 {
            throw IdentityVaultError.signingFailed
        }
        return signedData!
    }

    public func signMessageForIdentity(messageData: Data, identity: Identity) throws -> AnyPublisher<Data, Error> {
        CellBase.diagnosticLog("BridgeIdentityVault.signMessage publisher uuid=\(identity.uuid)", domain: .identity)
        guard let signaturePublisher = cloudBridge?.signMessageForIdentity(messageData: messageData, identity: identity) else {
            throw IdentityVaultError.publisherGone
        }
        
        return signaturePublisher
    }
    
    public func verifySignature(signature: Data, messageData: Data, for identity: Identity) throws -> Bool {
        var valid = false
        if let publicSecureKey = identity.publicSecureKey {
            switch publicSecureKey.curveType {
            case .Curve25519:
                //                print("About to verify signature with Curve25519")
                if let compressedKey = publicSecureKey.compressedKey {
                    let key = try Curve25519.Signing.PublicKey(rawRepresentation: compressedKey)
                    valid = key.isValidSignature(signature, for: messageData)
                } else {
                    print("No compressed key")
                }
            case .secp256k1, .P256:
                CellBase.diagnosticLog("BridgeIdentityVault verifying ECDSA P-256-compatible signature", domain: .identity)
                if let compressedKey = publicSecureKey.compressedKey,
                   let publicKey = try? P256.Signing.PublicKey(x963Representation: compressedKey),
                   let ecdsaSignature = try? P256.Signing.ECDSASignature(derRepresentation: signature) {
                    if publicKey.isValidSignature(ecdsaSignature, for: messageData) {
                        return true
                    }
                }
            }
            
        } else {
            print("No public secure key cloud bridge")
        }
        return valid
    }
}


func randomBytes32() -> Data? {
    try? SecureRandom.data(count: 32)
}

func randomBytes64() -> Data? {
    try? SecureRandom.data(count: 64)
}

func randomData(count: Int) -> Data? {
    try? SecureRandom.data(count: count)
}
