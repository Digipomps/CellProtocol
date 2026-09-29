// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// A compact identifier with a byte-for-byte compatible textual representation.
///
/// UUIDs use Foundation's 128-bit value plus a bit mask recording the spelling
/// of hexadecimal letters. Older opaque references remain text. Equality keeps
/// the existing case-sensitive String contract: normalizing an authorization
/// key or a signed/persisted identifier is not part of this storage refactor.
public struct CellIdentifier: Hashable, Sendable, Codable, RawRepresentable, Comparable {
    private enum Storage: Hashable, Sendable {
        case uuid(UUID, lowercaseLetters: UInt32)
        case text(String)
    }

    private let storage: Storage

    public init(rawValue: String) {
        guard rawValue.utf8.count == 36 else {
            storage = .text(rawValue)
            return
        }
        var lowercaseLetters: UInt32 = 0
        var digit = 0
        for (position, byte) in rawValue.utf8.enumerated() {
            if position == 8 || position == 13 || position == 18 || position == 23 {
                guard byte == 45 else {
                    storage = .text(rawValue)
                    return
                }
                continue
            }
            guard (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) else {
                storage = .text(rawValue)
                return
            }
            if (97...102).contains(byte) { lowercaseLetters |= 1 << digit }
            digit += 1
        }
        guard let uuid = UUID(uuidString: rawValue) else {
            storage = .text(rawValue)
            return
        }
        storage = .uuid(uuid, lowercaseLetters: lowercaseLetters)
    }

    public init(_ uuid: UUID = UUID()) {
        storage = .uuid(uuid, lowercaseLetters: 0)
    }

    /// The binary UUID, without reparsing text; nil for an opaque legacy reference.
    public var uuid: UUID? {
        guard case let .uuid(uuid, _) = storage else { return nil }
        return uuid
    }

    public var isEmpty: Bool {
        if case let .text(text) = storage { return text.isEmpty }
        return false
    }

    public var rawValue: String {
        switch storage {
        case let .text(text): return text
        case let .uuid(uuid, lowercaseLetters):
            let canonical = uuid.uuidString
            guard lowercaseLetters != 0 else { return canonical }
            var bytes = Array(canonical.utf8)
            var digit = 0
            for index in bytes.indices where bytes[index] != 45 {
                if lowercaseLetters & (1 << digit) != 0 { bytes[index] += 32 }
                digit += 1
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    // RawRepresentable supplies text-based defaults. Override them explicitly
    // so hashing and equality never format a UUID back into a heap String.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.storage == rhs.storage }
    public static func != (lhs: Self, rhs: Self) -> Bool { !(lhs == rhs) }
    public func hash(into hasher: inout Hasher) { storage.hash(into: &hasher) }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// Keep scalar identifiers usable at the package's older tvOS deployment target.
// Dictionary object coding requires the standard-library protocol's availability.
@available(macOS 12.3, iOS 15.4, watchOS 8.5, tvOS 15.4, *)
extension CellIdentifier: CodingKeyRepresentable {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public var codingKey: any CodingKey { Key(stringValue: rawValue) }
    public init?<K: CodingKey>(codingKey: K) { self.init(rawValue: codingKey.stringValue) }
}

/// Keeps source-compatible String APIs while storing valid UUIDs as binary values.
/// `$property` exposes the stored identifier for allocation-free internal lookup.
@propertyWrapper
public struct UUIDText: Hashable, Sendable, Codable {
    private var identifier: CellIdentifier
    public init(wrappedValue: String) { identifier = CellIdentifier(rawValue: wrappedValue) }
    public var wrappedValue: String {
        get { identifier.rawValue }
        set { identifier = CellIdentifier(rawValue: newValue) }
    }
    public var projectedValue: CellIdentifier { identifier }
    public init(from decoder: Decoder) throws { identifier = try CellIdentifier(from: decoder) }
    public func encode(to encoder: Encoder) throws { try identifier.encode(to: encoder) }
}

@propertyWrapper
public struct OptionalUUIDText: Hashable, Sendable, Codable {
    private var identifier: CellIdentifier?
    public init(wrappedValue: String?) {
        identifier = wrappedValue.map { CellIdentifier(rawValue: $0) }
    }
    public var wrappedValue: String? {
        get { identifier?.rawValue }
        set { identifier = newValue.map { CellIdentifier(rawValue: $0) } }
    }
    public var projectedValue: CellIdentifier? { identifier }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        identifier = container.decodeNil() ? nil : try container.decode(CellIdentifier.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(identifier)
    }
}

// Preserve synthesized Codable's absent/null behavior for optional String fields.
extension KeyedDecodingContainer {
    public func decode(_ type: OptionalUUIDText.Type, forKey key: Key) throws -> OptionalUUIDText {
        try decodeIfPresent(type, forKey: key) ?? OptionalUUIDText(wrappedValue: nil)
    }
}

extension KeyedEncodingContainer {
    public mutating func encode(_ value: OptionalUUIDText, forKey key: Key) throws {
        try encodeIfPresent(value.projectedValue, forKey: key)
    }
}

// Text is accepted only at compatibility boundaries. Internal callers can pass
// a stored CellIdentifier directly using Dictionary's ordinary subscript.
extension Dictionary where Key == CellIdentifier {
    public subscript(_ text: String) -> Value? {
        get { self[CellIdentifier(rawValue: text)] }
        set { self[CellIdentifier(rawValue: text)] = newValue }
        _modify {
            let key = CellIdentifier(rawValue: text)
            yield &self[key]
        }
    }

    @discardableResult
    public mutating func removeValue(forKey text: String) -> Value? {
        removeValue(forKey: CellIdentifier(rawValue: text))
    }
}
