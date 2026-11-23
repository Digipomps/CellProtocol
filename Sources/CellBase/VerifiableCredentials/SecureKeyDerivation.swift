// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// `SecureKey.use` and `SecureKey.size` are redundant: both follow from the
// algorithm and the curve. Kjetil decided 2026-11-23 that they are derived,
// so every implementation (Swift, Kotlin, ...) gets the same values from the
// same table instead of copying literals. The stored fields remain for wire
// compatibility; new keys should be made with the deriving initializer.

public extension CurveAlgorithm {
    /// What a key for this algorithm is used for.
    var derivedKeyUse: KeyUse {
        switch self {
        case .EdDSA, .ECDSA:
            return .signature
        case .X25519, .ECDH, .FHMQV:
            return .keyAgreement
        case .ECIES, .EEECC:
            return .encrypt
        }
    }
}

public extension CurveType {
    /// Key size in bits: the size of the curve's field. All supported curves
    /// are 256-bit (Curve25519, P-256 and secp256k1), whatever the length of
    /// the encoded key (32 raw bytes, 33 compressed or 65 uncompressed).
    var derivedKeySizeBits: Int {
        switch self {
        case .Curve25519, .P256, .secp256k1:
            return 256
        }
    }
}

public extension SecureKey {
    static func derivedUse(for algorithm: CurveAlgorithm) -> KeyUse {
        algorithm.derivedKeyUse
    }

    static func derivedSize(for curveType: CurveType) -> Int {
        curveType.derivedKeySizeBits
    }

    /// Makes a key whose `use` and `size` are derived from `algorithm` and `curveType`.
    init(
        date: Date,
        privateKey: Bool,
        algorithm: CurveAlgorithm,
        curveType: CurveType,
        x: Data?,
        y: Data?,
        compressedKey: Data?
    ) {
        self.init(
            date: date,
            privateKey: privateKey,
            use: algorithm.derivedKeyUse,
            algorithm: algorithm,
            size: curveType.derivedKeySizeBits,
            curveType: curveType,
            x: x,
            y: y,
            compressedKey: compressedKey
        )
    }

    /// Whether the stored `use` and `size` agree with the derivation. Older
    /// keys may carry a byte length (32) or an encoded length as `size`.
    var useAndSizeMatchDerivation: Bool {
        use == algorithm.derivedKeyUse && size == curveType.derivedKeySizeBits
    }
}
