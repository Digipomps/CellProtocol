// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

/// `ValueType ==` compared every object, list, data and keyValue as unequal,
/// even to itself. These tests pin value equality and its consistency with
/// `hash(into:)`.
final class ValueTypeEquatableTests: XCTestCase {

    private func assertEqualAndSameHash(_ lhs: ValueType, _ rhs: ValueType, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(lhs == rhs, "expected equal: \(lhs) vs \(rhs)", file: file, line: line)
        XCTAssertFalse(lhs != rhs, file: file, line: line)
        XCTAssertEqual(lhs.hashValue, rhs.hashValue, "equal values must hash equally", file: file, line: line)
    }

    private func assertUnequal(_ lhs: ValueType, _ rhs: ValueType, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(lhs == rhs, "expected unequal: \(lhs) vs \(rhs)", file: file, line: line)
        XCTAssertTrue(lhs != rhs, file: file, line: line)
    }

    func testObjectsCompareByValue() {
        let object: ValueType = .object(["name": .string("Ada"), "age": .integer(36), "flag": .bool(true)])
        assertEqualAndSameHash(object, object)
        assertEqualAndSameHash(object, .object(["flag": .bool(true), "age": .integer(36), "name": .string("Ada")]))
        assertEqualAndSameHash(.object([:]), .object([:]))

        assertUnequal(object, .object(["name": .string("Ada"), "age": .integer(37), "flag": .bool(true)]))
        assertUnequal(object, .object(["name": .string("Ada"), "age": .integer(36)]))
        assertUnequal(object, .object(["name": .string("Ada"), "age": .integer(36), "flag": .bool(true), "extra": .null]))
        assertUnequal(object, .object(["name": .string("Ada"), "age": .number(36), "flag": .bool(true)]))
        assertUnequal(.object([:]), .list([]))
    }

    func testListsCompareByValueAndOrder() {
        let list: ValueType = .list([.integer(1), .string("to"), .null])
        assertEqualAndSameHash(list, .list([.integer(1), .string("to"), .null]))
        assertEqualAndSameHash(.list([]), .list([]))

        assertUnequal(list, .list([.string("to"), .integer(1), .null]))
        assertUnequal(list, .list([.integer(1), .string("to")]))
        assertUnequal(list, .list([.integer(1), .string("tre"), .null]))
    }

    func testNestedObjectsAndListsCompareByValue() {
        func nested(_ leaf: String) -> ValueType {
            .object([
                "items": .list([
                    .object(["id": .string("a"), "tags": .list([.string(leaf), .data(Data([1, 2, 3]))])]),
                    .list([.object(["deep": .object(["value": .float(1.5)])])]),
                ]),
                "pair": .keyValue(KeyValue(key: "k", value: .object(["v": .string(leaf)]), target: "cell:///T")),
            ])
        }
        assertEqualAndSameHash(nested("x"), nested("x"))
        assertUnequal(nested("x"), nested("y"))
    }

    func testOtherValueCasesCompareByValue() {
        assertEqualAndSameHash(.data(Data([1, 2])), .data(Data([1, 2])))
        assertUnequal(.data(Data([1, 2])), .data(Data([2, 1])))
        assertEqualAndSameHash(.signData(Data([9])), .signData(Data([9])))
        assertEqualAndSameHash(.signature(Data([7])), .signature(Data([7])))
        assertUnequal(.signData(Data([7])), .signature(Data([7])))
        assertUnequal(.data(Data([7])), .signData(Data([7])))

        assertEqualAndSameHash(.keyValue(KeyValue(key: "a", value: .list([.integer(1)]))),
                               .keyValue(KeyValue(key: "a", value: .list([.integer(1)]))))
        assertUnequal(.keyValue(KeyValue(key: "a", value: .integer(1))), .keyValue(KeyValue(key: "b", value: .integer(1))))
        assertUnequal(.keyValue(KeyValue(key: "a", value: .integer(1), target: "x")),
                      .keyValue(KeyValue(key: "a", value: .integer(1), target: "y")))

        assertEqualAndSameHash(.setValueState(.ok), .setValueState(.ok))
        assertEqualAndSameHash(.connectState(.connected), .connectState(.connected))
        assertEqualAndSameHash(.contractState(.signed), .contractState(.signed))
        assertUnequal(.contractState(.signed), .contractState(.rejected))

        let response = SetValueResponse(state: .ok, value: .object(["a": .integer(1)]))
        assertEqualAndSameHash(.setValueResponse(response), .setValueResponse(SetValueResponse(state: .ok, value: .object(["a": .integer(1)]))))
        assertUnequal(.setValueResponse(response), .setValueResponse(SetValueResponse(state: .ok, value: .object(["a": .integer(2)]))))
    }

    func testDifferentCasesStayUnequal() {
        assertUnequal(.number(1), .integer(1))
        assertUnequal(.integer(1), .float(1))
        assertUnequal(.string("1"), .integer(1))
        assertUnequal(.null, .object([:]))
        assertUnequal(.list([]), .null)
    }

    func testObjectAndOptionalAndCollectionHelpersNowWork() {
        let a: Object = ["x": .list([.integer(1)])]
        let b: Object = ["x": .list([.integer(1)])]
        XCTAssertEqual(a, b)
        XCTAssertEqual(Optional(ValueType.object(a)), Optional(ValueType.object(b)))
        XCTAssertTrue([ValueType.object(a)].contains(.object(b)))
        XCTAssertEqual(Set([ValueType.object(a), .object(b), .list([])]).count, 2)
    }

    /// Cases that carry reference types or lack a settled equality are unchanged.
    func testReferenceLikeCasesAreUnchanged() {
        let identity = Identity("6F1C2B0A-0000-4000-8000-000000000001", displayName: "x", identityVault: nil)
        assertUnequal(.identity(identity), .identity(identity))
    }
}
