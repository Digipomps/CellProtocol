// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum UserDataErasureCodingError: Error, Equatable, LocalizedError {
    case invalidProfile
    case invalidDescriptor(String)
    case duplicateFragment(Int)
    case corruptFragment(Int)
    case insufficientFragments(required: Int, actual: Int)
    case singularMatrix
    case reconstructedPayloadHashMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidProfile:
            return "The erasure-coding profile is outside the supported GF(256) bounds."
        case let .invalidDescriptor(reason):
            return "The erasure-set descriptor is invalid: \(reason)"
        case let .duplicateFragment(index):
            return "Erasure fragment index \(index) was supplied more than once."
        case let .corruptFragment(index):
            return "Erasure fragment index \(index) failed its metadata-bound integrity hash."
        case let .insufficientFragments(required, actual):
            return "Reconstruction requires \(required) distinct fragments, but only \(actual) were valid."
        case .singularMatrix:
            return "The selected Reed-Solomon fragment matrix is singular."
        case .reconstructedPayloadHashMismatch:
            return "The reconstructed payload does not match the committed payload hash."
        }
    }
}

/// A systematic k+m Reed-Solomon profile over GF(256). The first k fragments
/// contain data shards and the remaining m fragments contain parity shards.
public struct UserDataErasureProfile: Codable, Equatable, Sendable {
    public static let default4Plus2 = Self(dataShardCount: 4, parityShardCount: 2)

    public var dataShardCount: Int
    public var parityShardCount: Int

    public init(dataShardCount: Int, parityShardCount: Int) {
        self.dataShardCount = dataShardCount
        self.parityShardCount = parityShardCount
    }

    public var totalShardCount: Int { dataShardCount + parityShardCount }

    public func validate() throws {
        guard dataShardCount > 0,
              parityShardCount > 0,
              totalShardCount <= 255 else {
            throw UserDataErasureCodingError.invalidProfile
        }
    }
}

public struct UserDataErasureFragment: Codable, Equatable, Sendable {
    public static let schema = "haven.user-data-erasure-fragment.v0"

    public var schema: String
    public var setID: String
    public var index: Int
    public var dataShardCount: Int
    public var parityShardCount: Int
    public var originalByteCount: Int
    public var shardByteCount: Int
    public var payloadHash: String
    public var bytes: Data
    public var fragmentHash: String

    public init(
        schema: String = Self.schema,
        setID: String,
        index: Int,
        dataShardCount: Int,
        parityShardCount: Int,
        originalByteCount: Int,
        shardByteCount: Int,
        payloadHash: String,
        bytes: Data,
        fragmentHash: String
    ) {
        self.schema = schema
        self.setID = setID
        self.index = index
        self.dataShardCount = dataShardCount
        self.parityShardCount = parityShardCount
        self.originalByteCount = originalByteCount
        self.shardByteCount = shardByteCount
        self.payloadHash = payloadHash
        self.bytes = bytes
        self.fragmentHash = fragmentHash
    }

    public func calculatedFragmentHash() throws -> String {
        FlowHasher.sha256Hex(try EntityAuthorityCanonical.data(for: UserDataErasureFragmentHashMaterial(self)))
    }
}

public struct UserDataErasureSetDescriptor: Codable, Equatable, Sendable {
    public static let schema = "haven.user-data-erasure-set.v0"

    public var schema: String
    public var setID: String
    public var payloadHash: String
    public var originalByteCount: Int
    public var shardByteCount: Int
    public var dataShardCount: Int
    public var parityShardCount: Int
    /// Canonical index order: element zero is fragment zero.
    public var fragmentHashes: [String]

    public init(
        schema: String = Self.schema,
        setID: String,
        payloadHash: String,
        originalByteCount: Int,
        shardByteCount: Int,
        dataShardCount: Int,
        parityShardCount: Int,
        fragmentHashes: [String]
    ) {
        self.schema = schema
        self.setID = setID
        self.payloadHash = payloadHash
        self.originalByteCount = originalByteCount
        self.shardByteCount = shardByteCount
        self.dataShardCount = dataShardCount
        self.parityShardCount = parityShardCount
        self.fragmentHashes = fragmentHashes
    }

    public var profile: UserDataErasureProfile {
        UserDataErasureProfile(
            dataShardCount: dataShardCount,
            parityShardCount: parityShardCount
        )
    }

    public func validate() throws {
        try profile.validate()
        guard schema == Self.schema else {
            throw UserDataErasureCodingError.invalidDescriptor("schema")
        }
        guard setID.hasPrefix("ers-"), setID.utf8.count == 68 else {
            throw UserDataErasureCodingError.invalidDescriptor("set_id")
        }
        guard Self.isSHA256Hex(payloadHash) else {
            throw UserDataErasureCodingError.invalidDescriptor("payload_hash")
        }
        guard originalByteCount >= 0,
              shardByteCount >= 0,
              shardByteCount == Self.expectedShardByteCount(
                originalByteCount: originalByteCount,
                dataShardCount: dataShardCount
              ) else {
            throw UserDataErasureCodingError.invalidDescriptor("byte_counts")
        }
        guard fragmentHashes.count == profile.totalShardCount,
              fragmentHashes.allSatisfy(Self.isSHA256Hex) else {
            throw UserDataErasureCodingError.invalidDescriptor("fragment_hashes")
        }
        let expectedSetID = try Self.calculateSetID(
            payloadHash: payloadHash,
            originalByteCount: originalByteCount,
            shardByteCount: shardByteCount,
            profile: profile
        )
        guard setID == expectedSetID else {
            throw UserDataErasureCodingError.invalidDescriptor("set_id_hash")
        }
    }

    fileprivate static func calculateSetID(
        payloadHash: String,
        originalByteCount: Int,
        shardByteCount: Int,
        profile: UserDataErasureProfile
    ) throws -> String {
        let material = UserDataErasureSetIDMaterial(
            schema: Self.schema,
            payloadHash: payloadHash,
            originalByteCount: originalByteCount,
            shardByteCount: shardByteCount,
            dataShardCount: profile.dataShardCount,
            parityShardCount: profile.parityShardCount
        )
        return "ers-" + FlowHasher.sha256Hex(try EntityAuthorityCanonical.data(for: material))
    }

    fileprivate static func expectedShardByteCount(
        originalByteCount: Int,
        dataShardCount: Int
    ) -> Int {
        guard originalByteCount > 0 else { return 0 }
        return (originalByteCount + dataShardCount - 1) / dataShardCount
    }

    static func isSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }
}

public struct UserDataErasureSet: Codable, Equatable, Sendable {
    public var descriptor: UserDataErasureSetDescriptor
    public var fragments: [UserDataErasureFragment]

    public init(
        descriptor: UserDataErasureSetDescriptor,
        fragments: [UserDataErasureFragment]
    ) {
        self.descriptor = descriptor
        self.fragments = fragments
    }
}

/// Deterministic systematic Reed-Solomon coding for already encrypted payloads.
/// This type does not encrypt and must not be given plaintext for remote storage.
public enum UserDataErasureCoding {
    public static func encode(
        encryptedPayload: Data,
        profile: UserDataErasureProfile = .default4Plus2
    ) throws -> UserDataErasureSet {
        try profile.validate()
        let payloadHash = FlowHasher.sha256Hex(encryptedPayload)
        let shardByteCount = UserDataErasureSetDescriptor.expectedShardByteCount(
            originalByteCount: encryptedPayload.count,
            dataShardCount: profile.dataShardCount
        )
        let setID = try UserDataErasureSetDescriptor.calculateSetID(
            payloadHash: payloadHash,
            originalByteCount: encryptedPayload.count,
            shardByteCount: shardByteCount,
            profile: profile
        )

        let payloadBytes = [UInt8](encryptedPayload)
        var shards = Array(
            repeating: Array(repeating: UInt8(0), count: shardByteCount),
            count: profile.totalShardCount
        )
        for dataIndex in 0..<profile.dataShardCount {
            let start = dataIndex * shardByteCount
            guard start < payloadBytes.count else { continue }
            let end = min(start + shardByteCount, payloadBytes.count)
            shards[dataIndex].replaceSubrange(0..<(end - start), with: payloadBytes[start..<end])
        }

        let generator = try ReedSolomonGF256.systematicGenerator(
            rows: profile.totalShardCount,
            columns: profile.dataShardCount
        )
        if shardByteCount > 0 {
            for shardIndex in profile.dataShardCount..<profile.totalShardCount {
                for byteIndex in 0..<shardByteCount {
                    var encoded: UInt8 = 0
                    for dataIndex in 0..<profile.dataShardCount {
                        encoded ^= ReedSolomonGF256.multiply(
                            generator[shardIndex][dataIndex],
                            shards[dataIndex][byteIndex]
                        )
                    }
                    shards[shardIndex][byteIndex] = encoded
                }
            }
        }

        var fragments: [UserDataErasureFragment] = []
        fragments.reserveCapacity(profile.totalShardCount)
        for index in 0..<profile.totalShardCount {
            var fragment = UserDataErasureFragment(
                setID: setID,
                index: index,
                dataShardCount: profile.dataShardCount,
                parityShardCount: profile.parityShardCount,
                originalByteCount: encryptedPayload.count,
                shardByteCount: shardByteCount,
                payloadHash: payloadHash,
                bytes: Data(shards[index]),
                fragmentHash: ""
            )
            fragment.fragmentHash = try fragment.calculatedFragmentHash()
            fragments.append(fragment)
        }
        let descriptor = UserDataErasureSetDescriptor(
            setID: setID,
            payloadHash: payloadHash,
            originalByteCount: encryptedPayload.count,
            shardByteCount: shardByteCount,
            dataShardCount: profile.dataShardCount,
            parityShardCount: profile.parityShardCount,
            fragmentHashes: fragments.map(\.fragmentHash)
        )
        try descriptor.validate()
        return UserDataErasureSet(descriptor: descriptor, fragments: fragments)
    }

    /// Reconstructs the encrypted payload from any k valid, distinct fragments.
    public static func reconstruct(
        fragments: [UserDataErasureFragment],
        descriptor: UserDataErasureSetDescriptor
    ) throws -> Data {
        try descriptor.validate()
        var unique: [Int: UserDataErasureFragment] = [:]
        for fragment in fragments {
            guard unique[fragment.index] == nil else {
                throw UserDataErasureCodingError.duplicateFragment(fragment.index)
            }
            try validate(fragment: fragment, against: descriptor)
            unique[fragment.index] = fragment
        }
        guard unique.count >= descriptor.dataShardCount else {
            throw UserDataErasureCodingError.insufficientFragments(
                required: descriptor.dataShardCount,
                actual: unique.count
            )
        }

        let selected = unique.keys.sorted().prefix(descriptor.dataShardCount)
        let generator = try ReedSolomonGF256.systematicGenerator(
            rows: descriptor.profile.totalShardCount,
            columns: descriptor.dataShardCount
        )
        let decodeMatrix = try ReedSolomonGF256.invert(
            selected.map { generator[$0] }
        )
        let selectedShards = selected.map { [UInt8](unique[$0]!.bytes) }
        var dataShards = Array(
            repeating: Array(repeating: UInt8(0), count: descriptor.shardByteCount),
            count: descriptor.dataShardCount
        )
        if descriptor.shardByteCount > 0 {
            for dataIndex in 0..<descriptor.dataShardCount {
                for byteIndex in 0..<descriptor.shardByteCount {
                    var decoded: UInt8 = 0
                    for selectedIndex in 0..<descriptor.dataShardCount {
                        decoded ^= ReedSolomonGF256.multiply(
                            decodeMatrix[dataIndex][selectedIndex],
                            selectedShards[selectedIndex][byteIndex]
                        )
                    }
                    dataShards[dataIndex][byteIndex] = decoded
                }
            }
        }

        var reconstructed = Data()
        reconstructed.reserveCapacity(descriptor.dataShardCount * descriptor.shardByteCount)
        for shard in dataShards {
            reconstructed.append(contentsOf: shard)
        }
        reconstructed = reconstructed.prefix(descriptor.originalByteCount)
        guard FlowHasher.sha256Hex(reconstructed) == descriptor.payloadHash else {
            throw UserDataErasureCodingError.reconstructedPayloadHashMismatch
        }
        return reconstructed
    }

    /// Recreates the complete canonical fragment set without requiring the
    /// decryption key. Repairers need only k valid ciphertext fragments.
    public static func repair(
        fragments: [UserDataErasureFragment],
        descriptor: UserDataErasureSetDescriptor
    ) throws -> UserDataErasureSet {
        let payload = try reconstruct(fragments: fragments, descriptor: descriptor)
        let repaired = try encode(encryptedPayload: payload, profile: descriptor.profile)
        guard repaired.descriptor == descriptor else {
            throw UserDataErasureCodingError.reconstructedPayloadHashMismatch
        }
        return repaired
    }

    private static func validate(
        fragment: UserDataErasureFragment,
        against descriptor: UserDataErasureSetDescriptor
    ) throws {
        guard fragment.schema == UserDataErasureFragment.schema,
              fragment.setID == descriptor.setID,
              fragment.index >= 0,
              fragment.index < descriptor.profile.totalShardCount,
              fragment.dataShardCount == descriptor.dataShardCount,
              fragment.parityShardCount == descriptor.parityShardCount,
              fragment.originalByteCount == descriptor.originalByteCount,
              fragment.shardByteCount == descriptor.shardByteCount,
              fragment.payloadHash == descriptor.payloadHash,
              fragment.bytes.count == descriptor.shardByteCount,
              fragment.fragmentHash == descriptor.fragmentHashes[fragment.index],
              fragment.fragmentHash == (try fragment.calculatedFragmentHash()) else {
            throw UserDataErasureCodingError.corruptFragment(fragment.index)
        }
    }
}

private struct UserDataErasureSetIDMaterial: Codable {
    var schema: String
    var payloadHash: String
    var originalByteCount: Int
    var shardByteCount: Int
    var dataShardCount: Int
    var parityShardCount: Int
}

private struct UserDataErasureFragmentHashMaterial: Codable {
    var schema: String
    var setID: String
    var index: Int
    var dataShardCount: Int
    var parityShardCount: Int
    var originalByteCount: Int
    var shardByteCount: Int
    var payloadHash: String
    var bytes: Data

    init(_ fragment: UserDataErasureFragment) {
        schema = fragment.schema
        setID = fragment.setID
        index = fragment.index
        dataShardCount = fragment.dataShardCount
        parityShardCount = fragment.parityShardCount
        originalByteCount = fragment.originalByteCount
        shardByteCount = fragment.shardByteCount
        payloadHash = fragment.payloadHash
        bytes = fragment.bytes
    }
}

private enum ReedSolomonGF256 {
    private static let tables: (exp: [UInt8], log: [Int]) = {
        var exp = Array(repeating: UInt8(0), count: 512)
        var log = Array(repeating: 0, count: 256)
        var value = 1
        for exponent in 0..<255 {
            exp[exponent] = UInt8(value)
            log[value] = exponent
            value <<= 1
            if value & 0x100 != 0 {
                value ^= 0x11D
            }
        }
        for exponent in 255..<512 {
            exp[exponent] = exp[exponent - 255]
        }
        return (exp, log)
    }()

    static func multiply(_ lhs: UInt8, _ rhs: UInt8) -> UInt8 {
        guard lhs != 0, rhs != 0 else { return 0 }
        return tables.exp[tables.log[Int(lhs)] + tables.log[Int(rhs)]]
    }

    private static func inverse(_ value: UInt8) throws -> UInt8 {
        guard value != 0 else {
            throw UserDataErasureCodingError.singularMatrix
        }
        return tables.exp[255 - tables.log[Int(value)]]
    }

    static func systematicGenerator(rows: Int, columns: Int) throws -> [[UInt8]] {
        let vandermonde = (0..<rows).map { row -> [UInt8] in
            var value: UInt8 = 1
            let base = UInt8(row)
            return (0..<columns).map { column in
                defer { value = multiply(value, base) }
                return column == 0 ? 1 : value
            }
        }
        let top = Array(vandermonde.prefix(columns))
        return multiply(vandermonde, try invert(top))
    }

    static func invert(_ matrix: [[UInt8]]) throws -> [[UInt8]] {
        let size = matrix.count
        guard size > 0, matrix.allSatisfy({ $0.count == size }) else {
            throw UserDataErasureCodingError.singularMatrix
        }
        var augmented = matrix.enumerated().map { rowIndex, row in
            row + (0..<size).map { rowIndex == $0 ? UInt8(1) : UInt8(0) }
        }

        for column in 0..<size {
            if augmented[column][column] == 0 {
                guard let pivot = ((column + 1)..<size).first(where: {
                    augmented[$0][column] != 0
                }) else {
                    throw UserDataErasureCodingError.singularMatrix
                }
                augmented.swapAt(column, pivot)
            }
            let pivotInverse = try inverse(augmented[column][column])
            for index in 0..<(size * 2) {
                augmented[column][index] = multiply(augmented[column][index], pivotInverse)
            }
            for row in 0..<size where row != column {
                let factor = augmented[row][column]
                guard factor != 0 else { continue }
                for index in 0..<(size * 2) {
                    augmented[row][index] ^= multiply(factor, augmented[column][index])
                }
            }
        }
        return augmented.map { Array($0[size..<(size * 2)]) }
    }

    private static func multiply(
        _ lhs: [[UInt8]],
        _ rhs: [[UInt8]]
    ) -> [[UInt8]] {
        let rows = lhs.count
        let shared = rhs.count
        let columns = rhs.first?.count ?? 0
        var result = Array(
            repeating: Array(repeating: UInt8(0), count: columns),
            count: rows
        )
        guard shared > 0 else { return result }
        for row in 0..<rows {
            for column in 0..<columns {
                var value: UInt8 = 0
                for index in 0..<shared {
                    value ^= multiply(lhs[row][index], rhs[index][column])
                }
                result[row][column] = value
            }
        }
        return result
    }
}
