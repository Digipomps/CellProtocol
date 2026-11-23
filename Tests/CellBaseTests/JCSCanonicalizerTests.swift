// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

/// RFC 8785 test vectors. A port (Kotlin, Python, Go) should run the same table.
final class JCSCanonicalizerTests: XCTestCase {

    func canonical(_ json: String, policy: JCSCanonicalizer.NumberPolicy = .rejectUnsafeIntegers) throws -> String {
        String(decoding: try JCSCanonicalizer.canonicalize(jsonData: Data(json.utf8), numberPolicy: policy), as: UTF8.self)
    }

    /// RFC 8785 §3.2.2 (and Appendix A): the main example.
    func testRFC8785MainExample() throws {
        let input = #"""
        {
          "numbers": [333333333.33333329, 1E30, 4.50,
                      2e-3, 0.000000000000000000000000001],
          "string": "\u20ac$\u000F\u000aA'\u0042\u0022\u005c\\\"\/",
          "literals": [null, true, false]
        }
        """#
        let expected = #"{"literals":[null,true,false],"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27],"string":"€$\u000f\nA'B\"\\\\\"/"}"#
        XCTAssertEqual(try canonical(input), expected)
    }

    /// RFC 8785 §3.2.3: members are sorted by UTF-16 code units.
    /// U+1F600 (surrogates D83D DE00) sorts before U+FB33, unlike code point order.
    func testRFC8785SortingExample() throws {
        let input = #"""
        {
          "\u20ac": "Euro Sign",
          "\r": "Carriage Return",
          "\ufb33": "Hebrew Letter Dalet With Dagesh",
          "1": "One",
          "\ud83d\ude00": "Emoji: Grinning Face",
          "\u0080": "Control",
          "\u00f6": "Latin Small Letter O With Diaeresis"
        }
        """#
        let expected = "{\"\\r\":\"Carriage Return\",\"1\":\"One\",\"\u{80}\":\"Control\",\"ö\":\"Latin Small Letter O With Diaeresis\",\"€\":\"Euro Sign\",\"😀\":\"Emoji: Grinning Face\",\"\u{FB33}\":\"Hebrew Letter Dalet With Dagesh\"}"
        XCTAssertEqual(try canonical(input), expected)
    }

    /// RFC 8785 Appendix B: IEEE 754 bit patterns and their ECMAScript strings.
    static let numberVectors: [(UInt64, String?)] = [
        (0x0000000000000000, "0"),
        (0x8000000000000000, "0"),                 // minus zero
        (0x0000000000000001, "5e-324"),
        (0x8000000000000001, "-5e-324"),
        (0x7fefffffffffffff, "1.7976931348623157e+308"),
        (0xffefffffffffffff, "-1.7976931348623157e+308"),
        (0x4340000000000000, "9007199254740992"),
        (0xc340000000000000, "-9007199254740992"),
        (0x4430000000000000, "295147905179352830000"),
        (0x7fffffffffffffff, nil),                 // NaN
        (0x7ff0000000000000, nil),                 // Infinity
        (0x44b52d02c7e14af5, "9.999999999999997e+22"),
        (0x44b52d02c7e14af6, "1e+23"),
        (0x44b52d02c7e14af7, "1.0000000000000001e+23"),
        (0x444b1ae4d6e2ef4e, "999999999999999700000"),
        (0x444b1ae4d6e2ef4f, "999999999999999900000"),
        (0x444b1ae4d6e2ef50, "1e+21"),
        (0x3eb0c6f7a0b5ed8c, "9.999999999999997e-7"),
        (0x3eb0c6f7a0b5ed8d, "0.000001"),
        (0x41b3de4355555553, "333333333.3333332"),
        (0x41b3de4355555554, "333333333.33333325"),
        (0x41b3de4355555555, "333333333.3333333"),
        (0x41b3de4355555556, "333333333.3333334"),
        (0x41b3de4355555557, "333333333.33333343"),
        (0xbecbf647612f3696, "-0.0000033333333333333333"),
        (0x43143ff3c1cb0959, "1424953923781206.2"),
    ]

    func testRFC8785NumberVectors() throws {
        for (bits, expected) in Self.numberVectors {
            let value = Double(bitPattern: bits)
            let label = String(bits, radix: 16)
            if let expected {
                XCTAssertEqual(try JCSCanonicalizer.serialize(number: value), expected, label)
            } else {
                XCTAssertThrowsError(try JCSCanonicalizer.serialize(number: value), label) { error in
                    XCTAssertEqual(error as? JCSCanonicalizer.Failure, .nonFiniteNumber)
                }
            }
        }
    }

    func testNumberLayoutBoundaries() throws {
        let cases: [(Double, String)] = [
            (1, "1"), (-1, "-1"), (1.5, "1.5"), (0.1, "0.1"), (100, "100"),
            (1e20, "100000000000000000000"), (1e21, "1e+21"), (1.2345678901234568e20, "123456789012345680000"),
            (1e-6, "0.000001"), (1e-7, "1e-7"), (1.25e-7, "1.25e-7"), (0.000123, "0.000123"),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(try JCSCanonicalizer.serialize(number: value), expected, "\(value)")
        }
    }

    func testStringEscaping() throws {
        // Only " \ and controls are escaped; / and U+2028 stay raw.
        XCTAssertEqual(try canonical(#"["a/b", "\u2028", "\u001f\u0000\b\f", "æ🙂"]"#),
                       "[\"a/b\",\"\u{2028}\",\"\\u001f\\u0000\\b\\f\",\"æ🙂\"]")
    }

    func testNestedStructureAndWhitespace() throws {
        XCTAssertEqual(try canonical(" { \"b\" : [ 1 , { \"d\":true, \"c\":null } ], \"a\" : {} , \"e\":[] } "),
                       #"{"a":{},"b":[1,{"c":null,"d":true}],"e":[]}"#)
    }

    /// Code-point and UTF-16 order differ from Foundation's case-insensitive,
    /// numeric `.sortedKeys` order: JCS is plain code unit order.
    func testKeyOrderIsNotFoundationOrder() throws {
        XCTAssertEqual(try canonical(#"{"item10":1,"item2":2,"Zulu":3,"alpha":4,"requestedScopes":5,"requestID":6}"#),
                       #"{"Zulu":3,"alpha":4,"item10":1,"item2":2,"requestID":6,"requestedScopes":5}"#)
    }

    func testHavenProfileRejectsUnsafeIntegers() throws {
        XCTAssertEqual(try canonical("[9007199254740992, -9007199254740992]"), "[9007199254740992,-9007199254740992]")
        for token in ["9007199254740993", "-9007199254740993", "12345678901234567890"] {
            XCTAssertThrowsError(try canonical("[\(token)]"), token) { error in
                XCTAssertEqual(error as? JCSCanonicalizer.Failure, .unsafeInteger(token))
            }
        }
        // A fraction or exponent says "this is a double": allowed, as in RFC 8785.
        XCTAssertEqual(try canonical("[1E30, 9007199254740993.0]"), "[1e+30,9007199254740992]")
        // Plain RFC 8785 reads every number as a double.
        XCTAssertEqual(try canonical("[9007199254740993]", policy: .ieee754), "[9007199254740992]")
    }

    func testCanonicalOutputIsAFixedPoint() throws {
        let once = try canonical(#"{"z":[1E30,4.50,"\u20ac"],"a":{"y":false,"x":0.000001}}"#, policy: .ieee754)
        XCTAssertEqual(try canonical(once, policy: .ieee754), once)
    }

    func testRejectsInvalidInput() {
        let bad = [
            #"{"a":1,"a":2}"#,          // duplicate name
            #"["\ud800"]"#,             // lone high surrogate
            #"["\udc00"]"#,             // lone low surrogate
            "[01]", "[1.]", "[.5]", "[1e]", "[+1]",
            "[NaN]", "[1e400]",
            "{\"a\":1,}", "[1,]", "[1] x", "\"raw\ttab\"",
        ]
        for input in bad {
            XCTAssertThrowsError(try canonical(input), input)
        }
    }

    func testEncodableEntryPoint() throws {
        struct Sample: Encodable {
            var zeta = "z"
            var alpha = 1.5
            var path = "a/b"
            var flag = true
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]   // formatting does not matter
        XCTAssertEqual(String(decoding: try JCSCanonicalizer.canonicalize(Sample(), encoder: encoder), as: UTF8.self),
                       #"{"alpha":1.5,"flag":true,"path":"a/b","zeta":"z"}"#)
        XCTAssertThrowsError(try JCSCanonicalizer.canonicalize(["n": Int64(9_007_199_254_740_993)]))
    }

    func testIdentifier() {
        XCTAssertEqual(JCSCanonicalizer.identifier, "jcs-rfc8785")
    }
}
