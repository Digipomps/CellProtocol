// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import CellBase

final class PerspectiveGeneralizationContractTests: XCTestCase {
    func testThresholdAliasesHaveOneCanonicalMeaning() throws {
        XCTAssertEqual(try PerspectiveQueryContract.minimumPurposeWeight(in: [:]), 0)
        for key in ["minPurposeWeight", "minWeight", "minimumWeight"] {
            XCTAssertEqual(try PerspectiveQueryContract.minimumPurposeWeight(in: [key: .float(0.9)]), 0.9)
        }
        XCTAssertEqual(try PerspectiveQueryContract.minimumPurposeWeight(in: ["minPurposeWeight": .integer(1), "minWeight": .float(1)]), 1)
        XCTAssertThrowsError(try PerspectiveQueryContract.minimumPurposeWeight(in: ["minPurposeWeight": .float(0.9), "minimumWeight": .float(0.1)]))
    }

    func testMalformedThresholdNeverBecomesUnfilteredQuery() {
        for value: ValueType in [.string("0.9"), .null, .bool(true), .float(.infinity), .float(.nan)] {
            XCTAssertThrowsError(try PerspectiveQueryContract.minimumPurposeWeight(in: ["minWeight": value]))
        }
    }

    func testLegacyStoragePathAndBytesArePreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PerspectiveCellStorage(documentsRoot: root, cellName: "legacy-perspective")
        let expected = root.appendingPathComponent("CellsContainer/legacy-perspective/Perspective.json")
        XCTAssertEqual(try store.url(filename: "Perspective.json"), expected)
        let original = Data("[  { \"reference\": \"existing-purpose\" }  ]".utf8)
        try FileManager.default.createDirectory(at: expected.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: expected)
        XCTAssertEqual(try store.read(filename: "Perspective.json"), original)
        let context = Data("{\"schemaVersion\":1}".utf8)
        try store.write(context, filename: "PerspectiveContext.json")
        XCTAssertEqual(try store.read(filename: "PerspectiveContext.json"), context)
        XCTAssertEqual(try Data(contentsOf: expected), original)
        XCTAssertThrowsError(try store.write(Data(), filename: "Perspective.json"))
        XCTAssertEqual(try store.read(filename: "Perspective.json"), original)
        XCTAssertThrowsError(try store.url(filename: "../outside.json"))
    }
}
