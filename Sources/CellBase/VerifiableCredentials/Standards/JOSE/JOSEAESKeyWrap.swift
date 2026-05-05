// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import CryptoSwift

public enum JOSEAESKeyWrapError: Error, Equatable {
    case invalidKeyLength(Int)
    case invalidPlaintextLength(Int)
    case invalidCiphertextLength(Int)
    case wrapFailed
    case integrityCheckFailed
}

public enum JOSEAESKeyWrap {
    private static let defaultInitialValue = Data(repeating: 0xA6, count: 8)

    public static func wrap(
        plaintextKey: Data,
        using kek: Data
    ) throws -> Data {
        try validateKEKLength(kek.count)
        guard plaintextKey.count >= 16, plaintextKey.count.isMultiple(of: 8) else {
            throw JOSEAESKeyWrapError.invalidPlaintextLength(plaintextKey.count)
        }

        let n = plaintextKey.count / 8
        var a = defaultInitialValue
        var r = stride(from: 0, to: plaintextKey.count, by: 8).map {
            plaintextKey.subdata(in: $0..<($0 + 8))
        }

        for j in 0..<6 {
            for i in 0..<n {
                let block = a + r[i]
                let b = try aesECBEncrypt(block, key: kek)
                let t = UInt64(n * j + i + 1).bigEndianData
                a = xor8(b.prefix(8), t)
                r[i] = Data(b.suffix(8))
            }
        }

        return a + r.reduce(into: Data(), { $0.append($1) })
    }

    public static func unwrap(
        wrappedKey: Data,
        using kek: Data
    ) throws -> Data {
        try validateKEKLength(kek.count)
        guard wrappedKey.count >= 24, wrappedKey.count.isMultiple(of: 8) else {
            throw JOSEAESKeyWrapError.invalidCiphertextLength(wrappedKey.count)
        }

        let n = (wrappedKey.count / 8) - 1
        var a = wrappedKey.prefix(8)
        var r = stride(from: 8, to: wrappedKey.count, by: 8).map {
            wrappedKey.subdata(in: $0..<($0 + 8))
        }

        for j in stride(from: 5, through: 0, by: -1) {
            for i in stride(from: n - 1, through: 0, by: -1) {
                let t = UInt64(n * j + i + 1).bigEndianData
                let block = xor8(a, t) + r[i]
                let b = try aesECBDecrypt(block, key: kek)
                a = Data(b.prefix(8))
                r[i] = Data(b.suffix(8))
            }
        }

        guard Data(a) == defaultInitialValue else {
            throw JOSEAESKeyWrapError.integrityCheckFailed
        }

        return r.reduce(into: Data(), { $0.append($1) })
    }

    private static func validateKEKLength(_ count: Int) throws {
        guard [16, 24, 32].contains(count) else {
            throw JOSEAESKeyWrapError.invalidKeyLength(count)
        }
    }

    private static func aesECBEncrypt(_ block: Data, key: Data) throws -> Data {
        do {
            let aes = try AES(key: Array(key), blockMode: ECB(), padding: .noPadding)
            return Data(try aes.encrypt(Array(block)))
        } catch {
            throw JOSEAESKeyWrapError.wrapFailed
        }
    }

    private static func aesECBDecrypt(_ block: Data, key: Data) throws -> Data {
        do {
            let aes = try AES(key: Array(key), blockMode: ECB(), padding: .noPadding)
            return Data(try aes.decrypt(Array(block)))
        } catch {
            throw JOSEAESKeyWrapError.wrapFailed
        }
    }

    private static func xor8<S: Sequence>(_ lhs: S, _ rhs: Data) -> Data where S.Element == UInt8 {
        Data(zip(lhs, rhs).map(^))
    }
}

private extension UInt64 {
    var bigEndianData: Data {
        withUnsafeBytes(of: self.bigEndian) { Data($0) }
    }
}
