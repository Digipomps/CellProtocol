// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
#if canImport(CellBase)
@testable import CellBase
#else
@testable import CellIdentifierSupport
#endif

final class CellIdentifierStorageTests: XCTestCase {
    private struct Record: Codable, Equatable {
        @UUIDText var uuid: String
        @OptionalUUIDText var ownerUUID: String?
    }

    private func fixtures() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/UUIDTextCompatibility.v1.json")
        return try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
    }

    func testAllUUIDVersionsAndLegacyTextPreserveExactWireBytes() throws {
        for text in try fixtures() {
            let identifier = CellIdentifier(rawValue: text)
            XCTAssertEqual(identifier.rawValue, text)
            XCTAssertEqual(identifier.uuid, UUID(uuidString: text))
            let original = try JSONEncoder().encode(text)
            XCTAssertEqual(try JSONEncoder().encode(identifier), original)
            XCTAssertEqual(try JSONDecoder().decode(CellIdentifier.self, from: original), identifier)
        }
    }

    func testEveryLetterPositionAndMixedCaseArePreserved() {
        let uppercase = "ABCDEFAB-CDEF-4ABC-ABCD-EFABCDEFABCD"
        let bytes = Array(uppercase.utf8)
        for index in bytes.indices where (65...70).contains(bytes[index]) {
            var changed = bytes
            changed[index] += 32
            let text = String(decoding: changed, as: UTF8.self)
            XCTAssertEqual(CellIdentifier(rawValue: text).rawValue, text)
        }
    }

    func testCaseVariantsRemainDistinctAuthorizationKeys() {
        let upper = "A42F007B-931D-4682-A842-AABBCCDDEEFF"
        let lower = upper.lowercased()
        let a = CellIdentifier(rawValue: upper)
        let b = CellIdentifier(rawValue: lower)
        XCTAssertEqual(a.uuid, b.uuid)
        XCTAssertNotEqual(a, b)
        var map: [CellIdentifier: Int] = [a: 1, b: 2]
        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map[upper], 1)
        XCTAssertEqual(map[lower], 2)
        map[lower]? += 1
        XCTAssertEqual(map[b], 3)
        XCTAssertEqual(map.removeValue(forKey: upper), 1)
        XCTAssertNil(map[a])
        XCTAssertEqual(map[b], 3)
    }

    func testDictionaryWireShapeRemainsObjectWithExactStringKeys() throws {
        let texts = try fixtures()
        let original = Dictionary(uniqueKeysWithValues: texts.enumerated().map { ($0.element, $0.offset) })
        let compact = Dictionary(uniqueKeysWithValues: texts.enumerated().map {
            (CellIdentifier(rawValue: $0.element), $0.offset)
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(compact)
        XCTAssertEqual(data.first, UInt8(ascii: "{"))
        XCTAssertEqual(data, try encoder.encode(original))
        XCTAssertEqual(try JSONDecoder().decode([CellIdentifier: Int].self, from: data), compact)
    }

    func testOptionalFieldKeepsAbsentNullAndStringBehavior() throws {
        let decoder = JSONDecoder()
        for data in [Data(#"{"uuid":"legacy"}"#.utf8), Data(#"{"uuid":"legacy","ownerUUID":null}"#.utf8)] {
            let record = try decoder.decode(Record.self, from: data)
            XCTAssertNil(record.ownerUUID)
            let encoded = try JSONEncoder().encode(record)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertNil(json["ownerUUID"])
        }
        let text = "a42f007b-931d-4682-a842-aabbccddeeff"
        let original = Record(uuid: text, ownerUUID: text)
        let decoded = try decoder.decode(Record.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.$uuid.uuid, UUID(uuidString: text))
        XCTAssertEqual(decoded.$ownerUUID?.uuid, UUID(uuidString: text))
    }

    func testWrongJSONTypesAreRejectedInsteadOfMintingIdentity() {
        for text in ["null", "42", "{}", "[]", "true"] {
            XCTAssertThrowsError(try JSONDecoder().decode(CellIdentifier.self, from: Data(text.utf8)))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(Record.self, from: Data(#"{"uuid":"legacy","ownerUUID":42}"#.utf8)))
    }

    func testNewIdentifiersUseFoundationUUIDv4WithoutRetainedText() {
        let identifier = CellIdentifier()
        XCTAssertNotNil(identifier.uuid)
        XCTAssertEqual(identifier.uuid!.uuid.6 >> 4, 4)
        XCTAssertEqual(identifier.rawValue, identifier.uuid!.uuidString)
        XCTAssertEqual(MemoryLayout<UUID>.size, 16)
        // UUID bytes plus spelling metadata and the legacy-reference discriminator.
        XCTAssertLessThanOrEqual(MemoryLayout<CellIdentifier>.stride, 32)
    }

    func testMutationReplacesBinaryOrLegacyStorageAndKeepsValueSemantics() {
        var record = Record(uuid: "legacy", ownerUUID: nil)
        let original = record
        record.uuid = "a42f007b-931d-4682-a842-aabbccddeeff"
        XCTAssertNotNil(record.$uuid.uuid)
        XCTAssertEqual(original.uuid, "legacy")
        record.uuid = "another-legacy"
        XCTAssertNil(record.$uuid.uuid)
        XCTAssertEqual(record.uuid, "another-legacy")
    }
}
