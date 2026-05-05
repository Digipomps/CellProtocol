// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

enum TestFixtures {
    static let fixedUUID1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let fixedUUID2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let fixedDate = Date(timeIntervalSince1970: 0)

    static func makeIdentity(displayName: String = "test", uuid: UUID = fixedUUID1) -> Identity {
        return Identity(uuid.uuidString, displayName: displayName, identityVault: CellBase.defaultIdentityVault)
    }

    static func fixtureURL(named filename: String, file: StaticString = #filePath) -> URL {
        let base = URL(fileURLWithPath: String(describing: file))
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        return base.appendingPathComponent(filename)
    }

    static func loadJSON(named filename: String, file: StaticString = #filePath, line: UInt = #line) -> Data {
        let url = fixtureURL(named: filename, file: file)
        do {
            return try Data(contentsOf: url)
        } catch {
            XCTFail("Failed to load fixture \(filename): \(error)", file: file, line: line)
            return Data()
        }
    }
}
