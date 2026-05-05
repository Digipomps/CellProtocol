// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

#if canImport(Security)
import Security
#endif

public enum JOSEJWSVerificationError: Error, Equatable {
    case unsupportedAlgorithm(String)
    case missingKeyMaterial
    case invalidKeyMaterial
}

public enum JOSEJWSVerifier {
    public static func verify(
        jws: JOSECompactJWS,
        algorithm: String,
        using jwk: JOSEJWK
    ) throws -> Bool {
        let signature = try signatureData(from: jws)
        let signingInput = signingInputData(for: jws)
        return try verify(
            signingInput: signingInput,
            signature: signature,
            algorithm: algorithm,
            using: jwk
        )
    }

    public static func verify(
        jws: JOSECompactJWS,
        algorithm: String,
        publicKey: Data,
        curveType: CurveType
    ) throws -> Bool {
        let signature = try signatureData(from: jws)
        let signingInput = signingInputData(for: jws)
        return try verify(
            signingInput: signingInput,
            signature: signature,
            algorithm: algorithm,
            publicKey: publicKey,
            curveType: curveType
        )
    }

    #if canImport(Security)
    public static func verify(
        jws: JOSECompactJWS,
        algorithm: String,
        certificateData: Data
    ) throws -> Bool {
        let signature = try signatureData(from: jws)
        let signingInput = signingInputData(for: jws)
        return try verify(
            signingInput: signingInput,
            signature: signature,
            algorithm: algorithm,
            certificateData: certificateData
        )
    }
    #endif

    public static func verify(
        signingInput: Data,
        signature: Data,
        algorithm: String,
        using jwk: JOSEJWK
    ) throws -> Bool {
        switch algorithm {
        case "EdDSA":
            guard let x = jwk.x else {
                throw JOSEJWSVerificationError.missingKeyMaterial
            }
            let publicKey = try JOSEBase64URL.decode(x)
            return try verify(
                signingInput: signingInput,
                signature: signature,
                algorithm: algorithm,
                publicKey: publicKey,
                curveType: .Curve25519
            )
        case "ES256", "ES384", "ES512":
            guard let x = jwk.x, let y = jwk.y else {
                throw JOSEJWSVerificationError.missingKeyMaterial
            }
            let xData = try JOSEBase64URL.decode(x)
            let yData = try JOSEBase64URL.decode(y)
            let x963Representation = Data([0x04]) + xData + yData

            let curveType: CurveType
            switch algorithm {
            case "ES256":
                curveType = .P256
            case "ES384", "ES512":
                curveType = .secp256k1
            default:
                curveType = .P256
            }

            return try verify(
                signingInput: signingInput,
                signature: signature,
                algorithm: algorithm,
                publicKey: x963Representation,
                curveType: curveType
            )
        default:
            throw JOSEJWSVerificationError.unsupportedAlgorithm(algorithm)
        }
    }

    public static func verify(
        signingInput: Data,
        signature: Data,
        algorithm: String,
        publicKey: Data,
        curveType: CurveType
    ) throws -> Bool {
        switch algorithm {
        case "EdDSA":
            guard curveType == .Curve25519 else {
                throw JOSEJWSVerificationError.invalidKeyMaterial
            }
            let signingKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
            return signingKey.isValidSignature(signature, for: signingInput)
        case "ES256":
            let signingKey: P256.Signing.PublicKey
            if let compactKey = try? P256.Signing.PublicKey(compactRepresentation: publicKey) {
                signingKey = compactKey
            } else {
                signingKey = try P256.Signing.PublicKey(x963Representation: publicKey)
            }
            let parsedSignature = try P256.Signing.ECDSASignature(rawRepresentation: signature)
            return signingKey.isValidSignature(parsedSignature, for: signingInput)
        case "ES384":
            let signingKey: P384.Signing.PublicKey
            if let compactKey = try? P384.Signing.PublicKey(compactRepresentation: publicKey) {
                signingKey = compactKey
            } else {
                signingKey = try P384.Signing.PublicKey(x963Representation: publicKey)
            }
            let parsedSignature = try P384.Signing.ECDSASignature(rawRepresentation: signature)
            return signingKey.isValidSignature(parsedSignature, for: signingInput)
        case "ES512":
            let signingKey: P521.Signing.PublicKey
            if let compactKey = try? P521.Signing.PublicKey(compactRepresentation: publicKey) {
                signingKey = compactKey
            } else {
                signingKey = try P521.Signing.PublicKey(x963Representation: publicKey)
            }
            let parsedSignature = try P521.Signing.ECDSASignature(rawRepresentation: signature)
            return signingKey.isValidSignature(parsedSignature, for: signingInput)
        default:
            throw JOSEJWSVerificationError.unsupportedAlgorithm(algorithm)
        }
    }

    #if canImport(Security)
    public static func verify(
        signingInput: Data,
        signature: Data,
        algorithm: String,
        certificateData: Data
    ) throws -> Bool {
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
              let publicKey = SecCertificateCopyKey(certificate) else {
            throw JOSEJWSVerificationError.invalidKeyMaterial
        }

        let secKeyAlgorithm: SecKeyAlgorithm
        switch algorithm {
        case "ES256":
            secKeyAlgorithm = .ecdsaSignatureMessageX962SHA256
        case "ES384":
            secKeyAlgorithm = .ecdsaSignatureMessageX962SHA384
        case "ES512":
            secKeyAlgorithm = .ecdsaSignatureMessageX962SHA512
        default:
            throw JOSEJWSVerificationError.unsupportedAlgorithm(algorithm)
        }

        let derSignature = try derEncodedECDSASignature(rawSignature: signature)
        var error: Unmanaged<CFError>?
        let verified = SecKeyVerifySignature(
            publicKey,
            secKeyAlgorithm,
            signingInput as CFData,
            derSignature as CFData,
            &error
        )
        if let error {
            let _ = error.takeRetainedValue()
        }
        return verified
    }
    #endif

    private static func signingInputData(for jws: JOSECompactJWS) -> Data {
        Data("\(jws.protectedHeaderSegment).\(jws.payloadSegment)".utf8)
    }

    private static func signatureData(from jws: JOSECompactJWS) throws -> Data {
        guard let signature = jws.signatureData else {
            throw JOSEJWSVerificationError.invalidKeyMaterial
        }
        return signature
    }

    #if canImport(Security)
    private static func derEncodedECDSASignature(rawSignature: Data) throws -> Data {
        guard rawSignature.count.isMultiple(of: 2), !rawSignature.isEmpty else {
            throw JOSEJWSVerificationError.invalidKeyMaterial
        }

        let componentLength = rawSignature.count / 2
        let r = derEncodedInteger(Data(rawSignature.prefix(componentLength)))
        let s = derEncodedInteger(Data(rawSignature.suffix(componentLength)))
        let sequenceBody = r + s
        return Data([0x30]) + derEncodedLength(sequenceBody.count) + sequenceBody
    }

    private static func derEncodedInteger(_ value: Data) -> Data {
        var normalized = Array(value.drop { $0 == 0 })
        if normalized.isEmpty {
            normalized = [0]
        }
        if normalized[0] & 0x80 != 0 {
            normalized.insert(0, at: 0)
        }
        return Data([0x02]) + derEncodedLength(normalized.count) + Data(normalized)
    }

    private static func derEncodedLength(_ length: Int) -> Data {
        if length < 128 {
            return Data([UInt8(length)])
        }

        var value = length
        var octets: [UInt8] = []
        while value > 0 {
            octets.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(octets.count)]) + Data(octets)
    }
    #endif
}
