// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

@testable import CellBase
import XCTest

final class CellJSONCoderTests: XCTestCase {

    struct CSTest: Codable {
        var test: String
        var test2: String?
    }

    let input =
"""
{
    "cellTypeString": "CSTest_name",
    "cell": {
        "test": "B",
        "test2": "C",
    }
}
"""
    func testDecode() throws {
        var decoder = CellJSONCoder()
        try decoder.register(name: "CSTest_name", type: CSTest.self)
        let data = input.data(using: .utf8)!
        let result = try decoder.decode(from: data) as? CSTest
        XCTAssertEqual(result?.test, "B")
        XCTAssertEqual(result?.test2, "C")
    }
}
