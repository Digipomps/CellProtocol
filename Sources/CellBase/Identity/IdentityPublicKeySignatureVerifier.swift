// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Verifies signatures only from the public key embedded in an identity descriptor.
/// It never consults a vault and therefore cannot select or expose signing authority.
public enum IdentityPublicKeySignatureVerifier {
    public static func descriptor(for identity: Identity) -> IdentityPublicKeyDescriptor? {
        guard identity.uuid.isEmpty == false,
              identity.uuid.utf8.count <= 512,
              let publicKey = identity.publicSecureKey,
              publicKey.privateKey == false,
              publicKey.use == .signature,
              let keyData = publicKey.compressedKey,
              keyData.isEmpty == false,
              keyData.count <= 256 else {
            return nil
        }
        return IdentityPublicKeyDescriptor(
            uuid: identity.uuid,
            displayName: identity.displayName,
            publicKey: keyData,
            algorithm: publicKey.algorithm,
            curveType: publicKey.curveType
        )
    }

    public static func verify(signature: Data, messageData: Data, identity: Identity) -> Bool {
        guard let descriptor = descriptor(for: identity) else {
            return false
        }
        return verify(signature: signature, messageData: messageData, descriptor: descriptor)
    }

    public static func verify(
        signature: Data,
        messageData: Data,
        descriptor: IdentityPublicKeyDescriptor
    ) -> Bool {
        switch (descriptor.algorithm, descriptor.curveType) {
        case (.EdDSA, .Curve25519):
            guard descriptor.publicKey.count == 32,
                  signature.count == 64,
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: descriptor.publicKey) else {
                return false
            }
            return publicKey.isValidSignature(signature, for: messageData)

        case (.ECDSA, .P256):
            guard let publicKey = p256PublicKey(from: descriptor.publicKey),
                  let ecdsaSignature = try? P256.Signing.ECDSASignature(derRepresentation: signature) else {
                return false
            }
            return publicKey.isValidSignature(ecdsaSignature, for: messageData)

        case (.ECDSA, .secp256k1),
             (.EdDSA, .secp256k1),
             (.EdDSA, .P256),
             (.ECDSA, .Curve25519),
             (.ECIES, _),
             (.EEECC, _),
             (.ECDH, _),
             (.X25519, _),
             (.FHMQV, _):
            return false
        }
    }

    private static func p256PublicKey(from data: Data) -> P256.Signing.PublicKey? {
        if data.count == 65 {
            return try? P256.Signing.PublicKey(x963Representation: data)
        }
        if data.count == 33 {
            return try? P256.Signing.PublicKey(compressedRepresentation: data)
        }
        return nil
    }
}
