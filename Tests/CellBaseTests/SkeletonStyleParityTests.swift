// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class SkeletonStyleParityTests: XCTestCase {

    private func normalize(_ json: String) throws -> ([String: Any], [SkeletonStyleParity.Finding]) {
        let (data, findings) = try SkeletonStyleParity.normalizedForParity(
            jsonData: Data(json.utf8)
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return (object, findings)
    }

    func testWebOnlyRoleIsRemovedAndReported() throws {
        let (object, findings) = try normalize("""
        { "Text": { "text": "Overskrift",
                    "modifiers": { "fontSize": 24, "styleRole": "admin-page-heading" } } }
        """)

        let text = try XCTUnwrap(object["Text"] as? [String: Any])
        let modifiers = try XCTUnwrap(text["modifiers"] as? [String: Any])

        XCTAssertNil(modifiers["styleRole"], "Rollen tolkes bare av web og maa vekk foer maaling")
        XCTAssertEqual(modifiers["fontSize"] as? Double, 24, "Eksplisitt geometri skal staa urort")

        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.token, "admin-page-heading")
        XCTAssertEqual(findings.first?.kind, .webOnly)
        XCTAssertEqual(findings.first?.path, "$.Text.modifiers.styleRole")
    }

    func testNativeOnlyRoleIsRemovedAndReported() throws {
        let (_, findings) = try normalize("""
        { "Button": { "title": "Send", "modifiers": { "styleRole": "chat-primary-action" } } }
        """)

        XCTAssertEqual(findings.map(\.kind), [.nativeOnly])
    }

    func testUnknownRoleIsReportedAsUnclaimed() throws {
        let (_, findings) = try normalize("""
        { "Text": { "text": "x", "modifiers": { "styleRole": "noe-ingen-tolker" } } }
        """)

        XCTAssertEqual(findings.map(\.kind), [.unclaimed])
    }

    func testAgreedRolesSurviveNormalization() throws {
        // Settet er tomt i dag. Testen beskriver kontrakten for naar det ikke er
        // det: en rolle begge rendrerne hedrer skal staa igjen, ellers maaler vi
        // noe annet enn produktet.
        for role in SkeletonStyleParity.agreedRoles {
            let (object, findings) = try normalize("""
            { "Text": { "text": "x", "modifiers": { "styleRole": "\(role)" } } }
            """)
            let text = try XCTUnwrap(object["Text"] as? [String: Any])
            let modifiers = try XCTUnwrap(text["modifiers"] as? [String: Any])
            XCTAssertEqual(modifiers["styleRole"] as? String, role)
            XCTAssertTrue(findings.isEmpty)
        }
    }

    func testVocabulariesDoNotOverlap() {
        XCTAssertTrue(
            SkeletonStyleParity.webOnlyRoles
                .isDisjoint(with: SkeletonStyleParity.nativeOnlyRoles),
            "En rolle som er i begge sett er per definisjon en avtalt rolle og hoerer i agreedRoles"
        )
        XCTAssertTrue(
            SkeletonStyleParity.agreedRoles
                .isDisjoint(with: SkeletonStyleParity.webOnlyRoles.union(SkeletonStyleParity.nativeOnlyRoles)),
            "En avtalt rolle kan ikke samtidig staa oppfoert som ensidig"
        )
    }

    func testNestedElementsAreVisited() throws {
        let (_, findings) = try normalize("""
        { "VStack": { "elements": [
            { "Text": { "text": "a", "modifiers": { "styleRole": "markdown" } } },
            { "HStack": { "elements": [
                { "Text": { "text": "b", "modifiers": { "styleClasses": ["admin-form-field", "ukjent"] } } }
            ] } }
        ] } }
        """)

        XCTAssertEqual(findings.count, 3)
        XCTAssertEqual(Set(findings.map(\.token)), ["markdown", "admin-form-field", "ukjent"])
    }

    func testElementWithoutModifiersIsUnchanged() throws {
        let source = """
        { "Text": { "text": "uendret" } }
        """
        let (object, findings) = try normalize(source)
        let text = try XCTUnwrap(object["Text"] as? [String: Any])
        XCTAssertEqual(text["text"] as? String, "uendret")
        XCTAssertTrue(findings.isEmpty)
    }
}
