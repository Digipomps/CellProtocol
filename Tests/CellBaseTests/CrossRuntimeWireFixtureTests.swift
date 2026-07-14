// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

final class CrossRuntimeWireFixtureTests: XCTestCase {
    func testMinimalCellConfigurationFixtureDecodesWithGeneratedUUID() throws {
        let fixture = TestFixtures.loadJSON(named: "CellConfigurationMinimal.json")
        let configuration = try JSONDecoder().decode(CellConfiguration.self, from: fixture)

        XCTAssertNotNil(UUID(uuidString: configuration.uuid))
        XCTAssertEqual(configuration.name, "Test Config")
        XCTAssertEqual(configuration.cellReferences?.count, 1)
        XCTAssertEqual(configuration.cellReferences?.first?.endpoint, "cell:///Example")
        XCTAssertEqual(configuration.cellReferences?.first?.label, "example")
        XCTAssertEqual(
            configuration.cellReferences?.first?.setKeysAndValues.first?.value,
            .string("hello")
        )
        guard case let .Text(text)? = configuration.skeleton else {
            return XCTFail("Expected the shared Text Skeleton fixture")
        }
        XCTAssertEqual(text.text, "Hello")
    }

    func testSetStringBridgeCommandFixtureIsExactSemanticJSONRoundTrip() throws {
        let fixture = TestFixtures.loadJSON(named: "BridgeCommandSetString.v1.json")
        let command = try JSONDecoder().decode(BridgeCommand.self, from: fixture)

        XCTAssertEqual(command.command, .set)
        XCTAssertEqual(command.cid, 7)
        guard case let .keyValue(keyValue)? = command.payload else {
            return XCTFail("Expected the shared typed KeyValue payload")
        }
        XCTAssertEqual(keyValue.key, "profile.name")
        XCTAssertEqual(keyValue.value, .string("CellProtocol"))

        let encoded = try JSONEncoder().encode(command)
        XCTAssertEqual(try canonicalJSON(encoded), try canonicalJSON(fixture))
    }

    private func canonicalJSON(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
