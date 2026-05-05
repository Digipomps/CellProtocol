// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  DIDKeyParser.swift
//  CellsContainer
//
//  Created by Kjetil Hustveit on 13/06/2025.
//

import Foundation
import BigInt

enum DIDKeyError: Error {
    case invalidDID
    case unsupportedKeyType
    case base58DecodingFailed
}

public struct DIDKeyParser {
    static let ed25519PublicKeyPrefix = Data([0xED, 0x01])
    static let secp256k1PublicKeyPrefix = Data([0xE7, 0x01])
    static let p256PublicKeyPrefix = Data([0x80, 0x24])
    
    static func base58Decode(_ input: String) -> Data? {
        let alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
        var result = [UInt8]()
        
        for char in input {
            guard let index = alphabet.firstIndex(of: char) else { return nil }
            var carry = alphabet.distance(from: alphabet.startIndex, to: index)
            
            for i in 0..<result.count {
                carry += Int(result[i]) * 58
                result[i] = UInt8(carry & 0xff)
                carry >>= 8
            }
            
            while carry > 0 {
                result.append(UInt8(carry & 0xff))
                carry >>= 8
            }
        }
        
        return Data(result.reversed())
    }

    static func multicodecPrefix(for curveType: CurveType) throws -> Data {
        switch curveType {
        case .Curve25519:
            return ed25519PublicKeyPrefix
        case .secp256k1:
            return secp256k1PublicKeyPrefix
        case .P256:
            return p256PublicKeyPrefix
        }
    }

    static func multibaseEncodedPublicKey(_ publicKey: Data, curveType: CurveType) throws -> String {
        let prefix = try multicodecPrefix(for: curveType)
        var multicodec = Data(prefix)
        multicodec.append(publicKey)
        return "z\(encodeBase58(multicodec))"
    }

    static func decodeMultikey(_ multibase: String) throws -> (keyType: String, curveType: CurveType, publicKey: Data) {
        guard multibase.starts(with: "z") else {
            throw DIDKeyError.invalidDID
        }

        let base58 = String(multibase.dropFirst())
        guard let decoded = base58Decode(base58) else {
            throw DIDKeyError.base58DecodingFailed
        }

        if decoded.starts(with: ed25519PublicKeyPrefix) {
            return ("Multikey", .Curve25519, decoded.dropFirst(ed25519PublicKeyPrefix.count))
        }

        if decoded.starts(with: secp256k1PublicKeyPrefix) {
            return ("Multikey", .secp256k1, decoded.dropFirst(secp256k1PublicKeyPrefix.count))
        }

        if decoded.starts(with: p256PublicKeyPrefix) {
            return ("Multikey", .P256, decoded.dropFirst(p256PublicKeyPrefix.count))
        }

        throw DIDKeyError.unsupportedKeyType
    }
    
    static func extractPublicKeyAndDID(from did: String) throws -> (did: String, keyType: String, curveType: CurveType, publicKey: Data, multibase: String) {
        guard did.starts(with: "did:key:") else {
            throw DIDKeyError.invalidDID
        }

        let multibase = String(did.dropFirst("did:key:".count))
        let decoded = try decodeMultikey(multibase)
        return (did, decoded.keyType, decoded.curveType, decoded.publicKey, multibase)
    }

    public static func createDIDDocument(from did: String) throws -> String {
        let (did, keyType, _, _, multibase) = try extractPublicKeyAndDID(from: did)

        let keyId = "\(did)#\(did.components(separatedBy: ":").last!)"

        let didDoc: [String: Any] = [
            "@context": [
                "https://www.w3.org/ns/did/v1",
                "https://w3id.org/security/multikey/v1"
            ],
            "id": did,
            "verificationMethod": [
                [
                    "id": keyId,
                    "type": keyType,
                    "controller": did,
                    "publicKeyMultibase": multibase
                ]
            ],
            "authentication": [keyId],
            "assertionMethod": [keyId]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: didDoc, options: [.prettyPrinted])
        return String(data: jsonData, encoding: .utf8) ?? "{}"
    }

    // Simplified Base58 encoder for small data
    static func encodeBase58(_ data: Data) -> String {
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        var intData = BigUInt(data)
        var encoded = ""

        while intData > 0 {
            let (quotient, remainder) = intData.quotientAndRemainder(dividingBy: 58)
            encoded.insert(alphabet[Int(remainder)], at: encoded.startIndex)
            intData = quotient
        }

        // Add '1' for each leading zero byte
        for byte in data {
            if byte == 0 {
                encoded.insert("1", at: encoded.startIndex)
            } else {
                break
            }
        }

        return encoded
    }
}
