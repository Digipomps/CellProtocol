// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// JSON Canonicalization Scheme, RFC 8785 (JCS).
///
/// Kjetil decided 2026-11-23 that JCS becomes the one canonical form for
/// signed and hashed objects in CellProtocol. This type is the Swift
/// reference. No signing path uses it yet; see `Docs/JCS_TRANSITION_PLAN.md`.
///
/// The rules, in short:
/// - Object members are sorted by their names as UTF-16 code units, compared
///   unsigned (RFC 8785 §3.2.3). Not code points, not locale order.
/// - Numbers are IEEE 754 doubles written as ECMAScript `Number.prototype.toString`
///   writes them (§3.2.2.3). NaN and infinities are errors. `-0` is `0`.
/// - Strings escape only `"`, `\` and U+0000–U+001F; `\b \t \n \f \r` use the
///   short forms, other controls `\u00xx` in lowercase hex. `/` and all other
///   characters are written as raw UTF-8 (§3.2.2.2).
/// - No whitespace. Duplicate member names are an error (I-JSON, RFC 7493).
///
/// HAVEN profile: an integer literal outside ±2^53 cannot survive the trip
/// through a double, so the parser refuses it by default
/// (`NumberPolicy.rejectUnsafeIntegers`). Such values must travel as strings.
public enum JCSCanonicalizer {
    /// The canonicalization identifier signed objects will carry.
    public static let identifier = "jcs-rfc8785"

    /// 2^53, the largest magnitude below which every integer is an exact double.
    public static let maximumSafeInteger: Double = 9_007_199_254_740_992

    public enum NumberPolicy: Sendable, Equatable {
        /// Refuse an integer literal (no fraction, no exponent) whose magnitude
        /// is above 2^53. Default for HAVEN.
        case rejectUnsafeIntegers
        /// Plain RFC 8785: every number is read as a double, whatever it loses.
        case ieee754
    }

    public enum Failure: Error, Equatable {
        case invalidJSON(String)
        case nonFiniteNumber
        case unsafeInteger(String)
        case duplicateKey(String)
        case invalidUnicode
        case unsupportedValue(String)
    }

    /// Parses JSON text and returns its canonical UTF-8 bytes.
    public static func canonicalize(jsonData: Data, numberPolicy: NumberPolicy = .rejectUnsafeIntegers) throws -> Data {
        try canonicalize(try parse(jsonData, numberPolicy: numberPolicy))
    }

    /// Encodes `value` with `encoder` and returns the canonical bytes of the result.
    /// The encoder's key order and formatting do not matter; its date and data
    /// strategies do.
    public static func canonicalize<T: Encodable>(
        _ value: T,
        encoder: JSONEncoder = JSONEncoder(),
        numberPolicy: NumberPolicy = .rejectUnsafeIntegers
    ) throws -> Data {
        try canonicalize(jsonData: try encoder.encode(value), numberPolicy: numberPolicy)
    }

    public static func canonicalize(_ value: JCSValue) throws -> Data {
        var out = ""
        try write(value, into: &out)
        return Data(out.utf8)
    }

    public static func canonicalString(_ value: JCSValue) throws -> String {
        var out = ""
        try write(value, into: &out)
        return out
    }

    // MARK: - Serialization

    private static func write(_ value: JCSValue, into out: inout String) throws {
        switch value {
        case .null:
            out += "null"
        case let .bool(flag):
            out += flag ? "true" : "false"
        case let .number(number):
            out += try serialize(number: number)
        case let .string(string):
            writeString(string, into: &out)
        case let .array(items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                try write(item, into: &out)
            }
            out += "]"
        case let .object(members):
            out += "{"
            for (index, key) in sortedKeys(members.keys).enumerated() {
                if index > 0 { out += "," }
                writeString(key, into: &out)
                out += ":"
                try write(members[key]!, into: &out)
            }
            out += "}"
        }
    }

    /// Member names in UTF-16 code unit order (RFC 8785 §3.2.3).
    public static func sortedKeys<S: Sequence>(_ keys: S) -> [String] where S.Element == String {
        keys.sorted { lhs, rhs in
            lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
        }
    }

    static func writeString(_ string: String, into out: inout String) {
        out += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{09}": out += "\\t"
            case "\u{0A}": out += "\\n"
            case "\u{0C}": out += "\\f"
            case "\u{0D}": out += "\\r"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    /// ECMAScript `Number.prototype.toString` for a double (RFC 8785 §3.2.2.3).
    public static func serialize(number: Double) throws -> String {
        guard number.isFinite else { throw Failure.nonFiniteNumber }
        if number == 0 { return "0" }   // also -0

        // Swift's description is the shortest digit string that round-trips,
        // the same digits ECMAScript chooses. Only the layout differs.
        let text = abs(number).description
        let mantissa: Substring
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<e]
            exponent = Int(text[text.index(after: e)...])!
        } else {
            mantissa = text[...]
        }
        let integerPart: Substring
        let fractionPart: Substring
        if let dot = mantissa.firstIndex(of: ".") {
            integerPart = mantissa[..<dot]
            fractionPart = mantissa[mantissa.index(after: dot)...]
        } else {
            integerPart = mantissa
            fractionPart = ""
        }
        let allDigits = Array(integerPart + fractionPart)
        guard let first = allDigits.firstIndex(where: { $0 != "0" }) else { return "0" }
        let last = allDigits.lastIndex(where: { $0 != "0" })!
        let digits = String(allDigits[first...last])
        let k = digits.count
        // Value = 0.digits × 10^n.
        let n = integerPart.count - first + exponent

        var result = number < 0 ? "-" : ""
        if k <= n && n <= 21 {
            result += digits + String(repeating: "0", count: n - k)
        } else if 0 < n && n <= 21 {
            let split = digits.index(digits.startIndex, offsetBy: n)
            result += String(digits[..<split]) + "." + String(digits[split...])
        } else if -6 < n && n <= 0 {
            result += "0." + String(repeating: "0", count: -n) + digits
        } else {
            let e = n - 1
            result += String(digits.first!)
            if k > 1 { result += "." + String(digits.dropFirst()) }
            result += "e" + (e >= 0 ? "+" : "-") + String(abs(e))
        }
        return result
    }

    // MARK: - Parsing

    /// Strict JSON (RFC 8259) parser that keeps what JCS needs: numbers as
    /// doubles, strings as Unicode scalars, duplicate names refused.
    public static func parse(_ data: Data, numberPolicy: NumberPolicy = .rejectUnsafeIntegers) throws -> JCSValue {
        var parser = Parser(bytes: Array(data), numberPolicy: numberPolicy)
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.atEnd else { throw Failure.invalidJSON("trailing content at byte \(parser.index)") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        let numberPolicy: NumberPolicy
        var index = 0
        static let maximumDepth = 512

        init(bytes: [UInt8], numberPolicy: NumberPolicy) {
            self.bytes = bytes
            self.numberPolicy = numberPolicy
        }

        var atEnd: Bool { index >= bytes.count }

        func fail(_ reason: String) -> Failure {
            .invalidJSON("\(reason) at byte \(index)")
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func expect(_ literal: String) throws {
            for byte in literal.utf8 {
                guard index < bytes.count, bytes[index] == byte else { throw fail("expected \(literal)") }
                index += 1
            }
        }

        mutating func parseValue(depth: Int) throws -> JCSValue {
            guard depth < Self.maximumDepth else { throw fail("nesting too deep") }
            guard index < bytes.count else { throw fail("unexpected end") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
            default: throw fail("unexpected character")
            }
        }

        mutating func parseObject(depth: Int) throws -> JCSValue {
            index += 1
            var members: [String: JCSValue] = [:]
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw fail("expected member name") }
                let key = try parseString()
                skipWhitespace()
                try expect(":")
                skipWhitespace()
                let value = try parseValue(depth: depth + 1)
                guard members.updateValue(value, forKey: key) == nil else { throw Failure.duplicateKey(key) }
                skipWhitespace()
                guard index < bytes.count else { throw fail("unexpected end in object") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                throw fail("expected , or }")
            }
        }

        mutating func parseArray(depth: Int) throws -> JCSValue {
            index += 1
            var items: [JCSValue] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw fail("unexpected end in array") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw fail("expected , or ]")
            }
        }

        mutating func parseHex4() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw fail("short \\u escape") }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                let digit: UInt32
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
                default: throw fail("bad hex digit")
                }
                value = value * 16 + digit
                index += 1
            }
            return value
        }

        mutating func parseString() throws -> String {
            index += 1   // opening quote
            var raw: [UInt8] = []
            var scalars = String.UnicodeScalarView()
            func flush() throws {
                guard !raw.isEmpty else { return }
                guard let text = String(bytes: raw, encoding: .utf8) else { throw Failure.invalidUnicode }
                scalars.append(contentsOf: text.unicodeScalars)
                raw.removeAll(keepingCapacity: true)
            }
            while true {
                guard index < bytes.count else { throw fail("unterminated string") }
                let byte = bytes[index]
                switch byte {
                case UInt8(ascii: "\""):
                    index += 1
                    try flush()
                    return String(scalars)
                case UInt8(ascii: "\\"):
                    try flush()
                    index += 1
                    guard index < bytes.count else { throw fail("unterminated escape") }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\u{0A}")
                    case UInt8(ascii: "r"): scalars.append("\u{0D}")
                    case UInt8(ascii: "t"): scalars.append("\u{09}")
                    case UInt8(ascii: "u"):
                        var code = try parseHex4()
                        if (0xD800...0xDBFF).contains(code) {
                            guard index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else {
                                throw Failure.invalidUnicode
                            }
                            index += 2
                            let low = try parseHex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw Failure.invalidUnicode }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        } else if (0xDC00...0xDFFF).contains(code) {
                            throw Failure.invalidUnicode
                        }
                        guard let scalar = Unicode.Scalar(code) else { throw Failure.invalidUnicode }
                        scalars.append(scalar)
                    default:
                        throw fail("bad escape")
                    }
                default:
                    guard byte >= 0x20 else { throw fail("raw control character in string") }
                    raw.append(byte)
                    index += 1
                }
            }
        }

        mutating func parseNumber() throws -> Double {
            let start = index
            var isInteger = true
            if bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count else { throw fail("bad number") }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else if (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(bytes[index]) {
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            } else {
                throw fail("bad number")
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                isInteger = false
                index += 1
                let digitsStart = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
                guard index > digitsStart else { throw fail("bad fraction") }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                isInteger = false
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                let digitsStart = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
                guard index > digitsStart else { throw fail("bad exponent") }
            }
            let token = String(decoding: bytes[start..<index], as: UTF8.self)
            guard let value = Double(token) else { throw fail("bad number") }
            guard value.isFinite else { throw Failure.nonFiniteNumber }
            // Compare the digits, not the double: 9007199254740993 rounds to 2^53.
            if isInteger, numberPolicy == .rejectUnsafeIntegers {
                let magnitude = token.hasPrefix("-") ? String(token.dropFirst()) : token
                let limit = "9007199254740992"
                if magnitude.count > limit.count || (magnitude.count == limit.count && magnitude > limit) {
                    throw Failure.unsafeInteger(token)
                }
            }
            return value
        }
    }
}

/// A JSON value as JCS sees it: every number is a double.
public indirect enum JCSValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JCSValue])
    case object([String: JCSValue])
}
