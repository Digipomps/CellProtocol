// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class VaultContractsTests: XCTestCase {
    func testVaultNoteRecordJSONRoundTrip() throws {
        let note = VaultNoteRecord(
            id: "note-1",
            slug: "note-1",
            title: "Planning",
            content: "Sprint note",
            tags: ["planning", "sprint"],
            createdAtEpochMs: 1_700_000_000_000,
            updatedAtEpochMs: 1_700_000_123_000
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(note)
        let decoded = try decoder.decode(VaultNoteRecord.self, from: data)

        XCTAssertEqual(decoded, note)
    }

    func testVaultLinkRecordJSONRoundTrip() throws {
        let link = VaultLinkRecord(
            fromNoteID: "note-1",
            toNoteID: "note-2",
            relationship: "wiki",
            createdAtEpochMs: 1_700_000_500_000
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(link)
        let decoded = try decoder.decode(VaultLinkRecord.self, from: data)

        XCTAssertEqual(decoded, link)
    }
}
