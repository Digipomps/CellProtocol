// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Security)
import Security
#endif

public enum SecureRandomError: Error {
    case invalidLength
    case systemRngFailure(status: Int32)
    case entropyDeviceUnavailable
    case entropyReadIncomplete
    case stringEncodingFailed
}

public enum SecureRandom {
    public static func data(count: Int) throws -> Data {
        guard count > 0 else {
            throw SecureRandomError.invalidLength
        }

#if canImport(Security)
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw SecureRandomError.systemRngFailure(status: status)
        }
        return Data(bytes)
#else
        let sourceURL = URL(fileURLWithPath: "/dev/urandom")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw SecureRandomError.entropyDeviceUnavailable
        }

        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer {
            try? handle.close()
        }

        var output = Data()
        output.reserveCapacity(count)

        while output.count < count {
            let remaining = count - output.count
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                throw SecureRandomError.entropyReadIncomplete
            }
            output.append(chunk)
        }
        return output
#endif
    }

    public static func alphanumericString(length: Int) throws -> String {
        guard length > 0 else {
            throw SecureRandomError.invalidLength
        }

        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
        let alphabetCount = UInt8(alphabet.count)
        let unbiasedUpperBound = UInt8.max - UInt8.max % alphabetCount

        var output = [UInt8]()
        output.reserveCapacity(length)

        while output.count < length {
            let entropy = try data(count: max(32, length - output.count))
            for byte in entropy {
                if byte >= unbiasedUpperBound {
                    continue
                }
                output.append(alphabet[Int(byte % alphabetCount)])
                if output.count == length {
                    break
                }
            }
        }

        guard let value = String(bytes: output, encoding: .utf8) else {
            throw SecureRandomError.stringEncodingFailed
        }
        return value
    }
}
