// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum OID4VPDirectPostJWTEncryptionError: Error, Equatable {
    case missingKeyManagementAlgorithm
    case unsupportedKeyManagementAlgorithm(String)
    case unsupportedContentEncryption(String)
    case unsupportedKeyType(String)
    case unsupportedCurve(String?)
    case invalidPublicKeyCoordinate
    case publicKeyConstructionFailed
    case keyAgreementFailed
    case encryptionFailed
    case keyWrapFailed
}

public enum OID4VPDirectPostJWTEncryptor {
    public static func encrypt(
        preparation: OID4VPDirectPostJWTPreparation
    ) throws -> JOSECompactJWE {
        guard let keyManagementAlgorithm = preparation.selectedKey.algorithm else {
            throw OID4VPDirectPostJWTEncryptionError.missingKeyManagementAlgorithm
        }
        guard supportedKeyManagementAlgorithms.contains(keyManagementAlgorithm) else {
            throw OID4VPDirectPostJWTEncryptionError.unsupportedKeyManagementAlgorithm(keyManagementAlgorithm)
        }

        let contentKeyLengthBytes = try contentEncryptionKeyLengthBytes(
            for: preparation.selectedContentEncryptionAlgorithm
        )
        let keyAgreement = try makeKeyAgreementContext(for: preparation.selectedKey)
        let ephemeralPublicJWK: JOSEJWK
        let sharedSecretData: Data

        switch keyAgreement {
        case .p256(let recipientPublicKey):
            let ephemeralPrivateKey = P256.KeyAgreement.PrivateKey()
            ephemeralPublicJWK = makeEphemeralPublicJWK(
                publicKeyData: ephemeralPrivateKey.publicKey.x963Representation,
                curve: "P-256"
            )
            let sharedSecret = sharedSecretBytes(
                try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: recipientPublicKey)
            )
            sharedSecretData = sharedSecret
        case .p384(let recipientPublicKey):
            let ephemeralPrivateKey = P384.KeyAgreement.PrivateKey()
            ephemeralPublicJWK = makeEphemeralPublicJWK(
                publicKeyData: ephemeralPrivateKey.publicKey.x963Representation,
                curve: "P-384"
            )
            let sharedSecret = sharedSecretBytes(
                try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: recipientPublicKey)
            )
            sharedSecretData = sharedSecret
        case .p521(let recipientPublicKey):
            let ephemeralPrivateKey = P521.KeyAgreement.PrivateKey()
            ephemeralPublicJWK = makeEphemeralPublicJWK(
                publicKeyData: ephemeralPrivateKey.publicKey.x963Representation,
                curve: "P-521"
            )
            let sharedSecret = sharedSecretBytes(
                try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: recipientPublicKey)
            )
            sharedSecretData = sharedSecret
        }

        let keyManagementKeyLengthBytes = try keyManagementKeyLengthBytes(
            for: keyManagementAlgorithm,
            contentEncryptionKeyLengthBytes: contentKeyLengthBytes
        )
        let encryptedKeySegment: String
        let contentEncryptionKeyData: Data

        if keyManagementAlgorithm == "ECDH-ES" {
            contentEncryptionKeyData = try concatKDF(
                sharedSecret: sharedSecretData,
                algorithmIdentifier: preparation.selectedContentEncryptionAlgorithm,
                keyLengthBits: contentKeyLengthBytes * 8
            )
            encryptedKeySegment = ""
        } else {
            let keyEncryptionKey = try concatKDF(
                sharedSecret: sharedSecretData,
                algorithmIdentifier: keyManagementAlgorithm,
                keyLengthBits: keyManagementKeyLengthBytes * 8
            )
            let randomContentEncryptionKey = makeContentEncryptionKey(lengthBytes: contentKeyLengthBytes)
            let randomContentEncryptionKeyData = keyData(randomContentEncryptionKey)
            let wrappedKey: Data
            do {
                wrappedKey = try JOSEAESKeyWrap.wrap(
                    plaintextKey: randomContentEncryptionKeyData,
                    using: keyEncryptionKey
                )
            } catch {
                throw OID4VPDirectPostJWTEncryptionError.keyWrapFailed
            }
            contentEncryptionKeyData = randomContentEncryptionKeyData
            encryptedKeySegment = JOSEBase64URL.encode(wrappedKey)
        }

        let protectedHeader = DirectPostJWTProtectedHeader(
            algorithm: keyManagementAlgorithm,
            encryption: preparation.selectedContentEncryptionAlgorithm,
            keyID: preparation.selectedKey.keyID,
            ephemeralPublicKey: ephemeralPublicJWK
        )
        let protectedHeaderData = try encodeProtectedHeader(protectedHeader)
        let protectedHeaderSegment = JOSEBase64URL.encode(protectedHeaderData)
        let contentEncryptionKey = SymmetricKey(data: contentEncryptionKeyData)

        do {
            let sealedContent = try sealContent(
                plaintext: preparation.payloadData,
                using: contentEncryptionKey,
                contentEncryptionAlgorithm: preparation.selectedContentEncryptionAlgorithm,
                additionalAuthenticatedData: Data(protectedHeaderSegment.utf8)
            )
            return JOSECompactJWE(
                protectedHeaderSegment: protectedHeaderSegment,
                encryptedKeySegment: encryptedKeySegment,
                initializationVector: sealedContent.initializationVector,
                ciphertext: sealedContent.ciphertext,
                authenticationTag: sealedContent.authenticationTag
            )
        } catch {
            throw OID4VPDirectPostJWTEncryptionError.encryptionFailed
        }
    }

    public static func buildSubmission(
        preparation: OID4VPDirectPostJWTPreparation
    ) throws -> OID4VPDirectPostSubmission {
        let jwe = try encrypt(preparation: preparation)
        return OID4VPDirectPostSubmission(
            responseURI: preparation.responseURI,
            responseMode: .directPostJwt,
            formParameters: ["response": jwe.compactSerialization]
        )
    }
}

private struct DirectPostJWTProtectedHeader: Encodable {
    var algorithm: String
    var encryption: String
    var keyID: String?
    var ephemeralPublicKey: JOSEJWK

    enum CodingKeys: String, CodingKey {
        case algorithm = "alg"
        case encryption = "enc"
        case keyID = "kid"
        case ephemeralPublicKey = "epk"
    }
}

private struct SealedContent {
    var initializationVector: Data
    var ciphertext: Data
    var authenticationTag: Data
}

private enum KeyAgreementContext {
    case p256(P256.KeyAgreement.PublicKey)
    case p384(P384.KeyAgreement.PublicKey)
    case p521(P521.KeyAgreement.PublicKey)
}

private let supportedKeyManagementAlgorithms: Set<String> = [
    "ECDH-ES",
    "ECDH-ES+A128KW",
    "ECDH-ES+A192KW",
    "ECDH-ES+A256KW"
]

private func contentEncryptionKeyLengthBytes(for contentEncryptionAlgorithm: String) throws -> Int {
    switch contentEncryptionAlgorithm {
    case "A128GCM":
        return 16
    case "A192GCM":
        return 24
    case "A256GCM":
        return 32
    default:
        throw OID4VPDirectPostJWTEncryptionError.unsupportedContentEncryption(contentEncryptionAlgorithm)
    }
}

private func keyManagementKeyLengthBytes(
    for keyManagementAlgorithm: String,
    contentEncryptionKeyLengthBytes: Int
) throws -> Int {
    switch keyManagementAlgorithm {
    case "ECDH-ES":
        return contentEncryptionKeyLengthBytes
    case "ECDH-ES+A128KW":
        return 16
    case "ECDH-ES+A192KW":
        return 24
    case "ECDH-ES+A256KW":
        return 32
    default:
        throw OID4VPDirectPostJWTEncryptionError.unsupportedKeyManagementAlgorithm(keyManagementAlgorithm)
    }
}

private func makeKeyAgreementContext(for jwk: JOSEJWK) throws -> KeyAgreementContext {
    guard jwk.keyType == "EC" else {
        throw OID4VPDirectPostJWTEncryptionError.unsupportedKeyType(jwk.keyType)
    }
    guard let curve = jwk.curve else {
        throw OID4VPDirectPostJWTEncryptionError.unsupportedCurve(nil)
    }
    guard let x = jwk.x, let y = jwk.y else {
        throw OID4VPDirectPostJWTEncryptionError.invalidPublicKeyCoordinate
    }

    switch curve {
    case "P-256":
        let keyData = try makeUncompressedECPublicKeyData(x: x, y: y, expectedCoordinateLength: 32)
        guard let publicKey = try? P256.KeyAgreement.PublicKey(x963Representation: keyData) else {
            throw OID4VPDirectPostJWTEncryptionError.publicKeyConstructionFailed
        }
        return .p256(publicKey)
    case "P-384":
        let keyData = try makeUncompressedECPublicKeyData(x: x, y: y, expectedCoordinateLength: 48)
        guard let publicKey = try? P384.KeyAgreement.PublicKey(x963Representation: keyData) else {
            throw OID4VPDirectPostJWTEncryptionError.publicKeyConstructionFailed
        }
        return .p384(publicKey)
    case "P-521":
        let keyData = try makeUncompressedECPublicKeyData(x: x, y: y, expectedCoordinateLength: 66)
        guard let publicKey = try? P521.KeyAgreement.PublicKey(x963Representation: keyData) else {
            throw OID4VPDirectPostJWTEncryptionError.publicKeyConstructionFailed
        }
        return .p521(publicKey)
    default:
        throw OID4VPDirectPostJWTEncryptionError.unsupportedCurve(curve)
    }
}

private func makeUncompressedECPublicKeyData(
    x: String,
    y: String,
    expectedCoordinateLength: Int
) throws -> Data {
    let xData = try JOSEBase64URL.decode(x)
    let yData = try JOSEBase64URL.decode(y)
    guard xData.count == expectedCoordinateLength, yData.count == expectedCoordinateLength else {
        throw OID4VPDirectPostJWTEncryptionError.invalidPublicKeyCoordinate
    }
    return Data([0x04]) + xData + yData
}

private func makeEphemeralPublicJWK(publicKeyData: Data, curve: String) -> JOSEJWK {
    let coordinateLength = (publicKeyData.count - 1) / 2
    let xRange = 1..<(1 + coordinateLength)
    let yRange = (1 + coordinateLength)..<publicKeyData.count
    return JOSEJWK(
        keyType: "EC",
        curve: curve,
        x: JOSEBase64URL.encode(publicKeyData.subdata(in: xRange)),
        y: JOSEBase64URL.encode(publicKeyData.subdata(in: yRange))
    )
}

private func encodeProtectedHeader(_ header: DirectPostJWTProtectedHeader) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(header)
}

private func sealContent(
    plaintext: Data,
    using contentEncryptionKey: SymmetricKey,
    contentEncryptionAlgorithm: String,
    additionalAuthenticatedData: Data
) throws -> SealedContent {
    switch contentEncryptionAlgorithm {
    case "A128GCM", "A192GCM", "A256GCM":
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: contentEncryptionKey,
            nonce: nonce,
            authenticating: additionalAuthenticatedData
        )
        return SealedContent(
            initializationVector: nonceData(nonce),
            ciphertext: sealedBox.ciphertext,
            authenticationTag: sealedBox.tag
        )
    default:
        throw OID4VPDirectPostJWTEncryptionError.unsupportedContentEncryption(contentEncryptionAlgorithm)
    }
}

private func concatKDF(
    sharedSecret: Data,
    algorithmIdentifier: String,
    keyLengthBits: Int
) throws -> Data {
    let algorithmIdentifierData = Data(algorithmIdentifier.utf8)
    let otherInfo =
        lengthPrefixed(algorithmIdentifierData) +
        lengthPrefixed(Data()) +
        lengthPrefixed(Data()) +
        UInt32(keyLengthBits).bigEndianData +
        UInt32(0).bigEndianData

    let repetitions = Int(ceil(Double(keyLengthBits) / Double(256)))
    var derived = Data()
    for counter in 1...repetitions {
        let roundData = UInt32(counter).bigEndianData + sharedSecret + otherInfo
        let digest = SHA256.hash(data: roundData)
        derived.append(contentsOf: digest)
    }
    return Data(derived.prefix(keyLengthBits / 8))
}

private func lengthPrefixed(_ data: Data) -> Data {
    UInt32(data.count).bigEndianData + data
}

private func sharedSecretBytes(_ sharedSecret: SharedSecret) -> Data {
    sharedSecret.withUnsafeBytes { Data($0) }
}

private func nonceData(_ nonce: AES.GCM.Nonce) -> Data {
    nonce.withUnsafeBytes { Data($0) }
}

private func makeContentEncryptionKey(lengthBytes: Int) -> SymmetricKey {
    switch lengthBytes {
    case 16:
        return SymmetricKey(size: .bits128)
    case 24:
        return SymmetricKey(size: .bits192)
    default:
        return SymmetricKey(size: .bits256)
    }
}

private func keyData(_ symmetricKey: SymmetricKey) -> Data {
    symmetricKey.withUnsafeBytes { Data($0) }
}

private extension UInt32 {
    var bigEndianData: Data {
        withUnsafeBytes(of: self.bigEndian) { Data($0) }
    }
}
