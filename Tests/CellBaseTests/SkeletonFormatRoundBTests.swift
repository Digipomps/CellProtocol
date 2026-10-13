// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import CellBase

/// WP-F (vei B, 2026-09-19): ComponentSurface.instanceIDKeypath og SkeletonLayoutVariant.hidden/width.
/// T-F1: formatet dekodes, valideres og skrives tilbake uten tap. T-F2: auditen behandler
/// instans-ID fra data riktig.
final class SkeletonFormatRoundBTests: XCTestCase {
    private func decode(_ json: String) throws -> SkeletonElement {
        try JSONDecoder().decode(SkeletonElement.self, from: Data(json.utf8))
    }

    private func roundTrip(_ element: SkeletonElement) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(element), as: UTF8.self)
    }

    func testComponentSurfaceAcceptsExactlyOneInstanceSource() throws {
        let keyed = try decode(#"{"ComponentSurface":{"sourceKeypath":"widgets.mount","instanceIDKeypath":"instanceID","variant":"pinned"}}"#)
        guard case let .ComponentSurface(surface) = keyed else { return XCTFail("Expected ComponentSurface") }
        XCTAssertNil(surface.instanceID)
        XCTAssertEqual(surface.instanceIDKeypath, "instanceID")
        let json = try roundTrip(keyed)
        XCTAssertTrue(json.contains(#""instanceIDKeypath":"instanceID""#))
        XCTAssertFalse(json.contains(#""instanceID":"#))
        guard case let .ComponentSurface(again) = try decode(json) else { return XCTFail("Round trip lost the element") }
        XCTAssertEqual(again.instanceIDKeypath, "instanceID")

        let fixed = try decode(#"{"ComponentSurface":{"sourceKeypath":"widgets.mount","instanceID":"w1","variant":"inline"}}"#)
        guard case let .ComponentSurface(fixedSurface) = fixed else { return XCTFail("Expected ComponentSurface") }
        XCTAssertEqual(fixedSurface.instanceID, "w1")
        XCTAssertFalse(try roundTrip(fixed).contains("instanceIDKeypath"))

        for invalid in [
            #"{"ComponentSurface":{"sourceKeypath":"a","variant":"inline"}}"#,
            #"{"ComponentSurface":{"sourceKeypath":"a","instanceID":"w1","instanceIDKeypath":"id","variant":"inline"}}"#,
            #"{"ComponentSurface":{"sourceKeypath":"a","instanceIDKeypath":"","variant":"inline"}}"#,
        ] {
            let element = try? decode(invalid)
            if case .ComponentSurface? = element { XCTFail("Must reject: \(invalid)") }
        }
    }

    func testLayoutVariantHiddenAndWidthDecodeValidateAndRoundTrip() throws {
        let element = try decode(#"{"VStack":{"elements":[],"modifiers":{"layoutVariants":[{"maxAvailableWidth":1099,"hidden":true},{"minAvailableWidth":1100,"width":290}]}}}"#)
        guard case let .VStack(stack) = element, let variants = stack.modifiers?.layoutVariants, variants.count == 2 else {
            return XCTFail("Expected two variants")
        }
        XCTAssertEqual(variants[0].hidden, true)
        XCTAssertNil(variants[0].width)
        XCTAssertEqual(variants[1].width, 290)
        let json = try roundTrip(element)
        XCTAssertTrue(json.contains(#""hidden":true"#))
        XCTAssertTrue(json.contains(#""width":290"#))
        XCTAssertThrowsError(try JSONDecoder().decode(SkeletonLayoutVariant.self, from: Data(#"{"width":-1}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(SkeletonLayoutVariant.self, from: Data(#"{"hide":true}"#.utf8)),
                             "Unknown keys stay rejected")
    }

    func testVariantSelectionUsesTheOfferedWidthWhenTheElementHasNoOwnWidth() throws {
        var modifiers = SkeletonModifiers()
        modifiers.layoutVariants = [
            SkeletonLayoutVariant(maxAvailableWidth: 1099, hidden: true),
            SkeletonLayoutVariant(minAvailableWidth: 1100, width: 290)
        ]
        let wide = try SkeletonLayoutContext(availableWidth: 2000, availableHeight: 1250, capabilities: [])
        let narrow = try SkeletonLayoutContext(availableWidth: 780, availableHeight: 1688, capabilities: [])
        XCTAssertEqual(modifiers.layoutVariant(in: wide)?.width, 290)
        XCTAssertEqual(modifiers.layoutVariant(in: narrow)?.hidden, true)
    }

    func testAuditTreatsKeypathInstancesPerRowAndStillFindsDuplicateFixedIDs() throws {
        let keyed = SkeletonElement.ComponentSurface(SkeletonComponentSurface(sourceKeypath: "mount", instanceIDKeypath: "id", variant: .pinned))
        let fixedA = SkeletonElement.ComponentSurface(SkeletonComponentSurface(sourceKeypath: "mount", instanceID: "same", variant: .inline))
        let fixedB = SkeletonElement.ComponentSurface(SkeletonComponentSurface(sourceKeypath: "mount", instanceID: "same", variant: .inline))
        let twoKeyed = SkeletonElement.VStack(SkeletonVStack(elements: [keyed, keyed], spacing: 0))
        let duplicateFixed = SkeletonElement.VStack(SkeletonVStack(elements: [fixedA, fixedB], spacing: 0))
        func duplicates(_ element: SkeletonElement) -> Int {
            SkeletonReachabilityAudit.audit(element).filter { "\($0)".contains("duplicateComponentInstanceID") }.count
        }
        XCTAssertEqual(duplicates(twoKeyed), 0, "Keypath instance IDs are resolved per row, not compared statically")
        XCTAssertGreaterThan(duplicates(duplicateFixed), 0)
    }
}
