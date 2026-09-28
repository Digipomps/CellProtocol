// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

/// `SkeletonModifiers` holds its fields in a copy-on-write box (WP-R4b/WP-R4d).
/// Purpose: large skeletons can be built and encoded on a Swift concurrency
/// thread (512 KiB stack on Apple platforms) without overflowing the stack in
/// debug builds. These tests keep element payloads small and check that the box
/// changes neither value semantics nor JSON.
final class SkeletonModifiersStorageTests: XCTestCase {
    func testModifiersArePointerSized() {
        XCTAssertEqual(MemoryLayout<SkeletonModifiers>.size, MemoryLayout<UnsafeRawPointer>.size)
        XCTAssertEqual(MemoryLayout<SkeletonModifiers?>.size, MemoryLayout<UnsafeRawPointer>.size)
    }

    func testElementPayloadsStayWithinBudget() {
        let budget = 512
        let sizes: [(String, Int)] = [
            ("SkeletonAutocomplete", MemoryLayout<SkeletonAutocomplete>.size),
            ("SkeletonButton", MemoryLayout<SkeletonButton>.size),
            ("SkeletonCellReference", MemoryLayout<SkeletonCellReference>.size),
            ("SkeletonComponentMount", MemoryLayout<SkeletonComponentMount>.size),
            ("SkeletonComponentSurface", MemoryLayout<SkeletonComponentSurface>.size),
            ("SkeletonDivider", MemoryLayout<SkeletonDivider>.size),
            ("SkeletonGrid", MemoryLayout<SkeletonGrid>.size),
            ("SkeletonHStack", MemoryLayout<SkeletonHStack>.size),
            ("SkeletonImage", MemoryLayout<SkeletonImage>.size),
            ("SkeletonList", MemoryLayout<SkeletonList>.size),
            ("SkeletonNavigationBar", MemoryLayout<SkeletonNavigationBar>.size),
            ("SkeletonNavigationBarItem", MemoryLayout<SkeletonNavigationBarItem>.size),
            ("SkeletonObject", MemoryLayout<SkeletonObject>.size),
            ("SkeletonPicker", MemoryLayout<SkeletonPicker>.size),
            ("SkeletonScrollView", MemoryLayout<SkeletonScrollView>.size),
            ("SkeletonSection", MemoryLayout<SkeletonSection>.size),
            ("SkeletonSpacer", MemoryLayout<SkeletonSpacer>.size),
            ("SkeletonTabPanel", MemoryLayout<SkeletonTabPanel>.size),
            ("SkeletonTabs", MemoryLayout<SkeletonTabs>.size),
            ("SkeletonText", MemoryLayout<SkeletonText>.size),
            ("SkeletonTextArea", MemoryLayout<SkeletonTextArea>.size),
            ("SkeletonTextField", MemoryLayout<SkeletonTextField>.size),
            ("SkeletonToggle", MemoryLayout<SkeletonToggle>.size),
            ("SkeletonTree", MemoryLayout<SkeletonTree>.size),
            ("SkeletonUnsupported", MemoryLayout<SkeletonUnsupported>.size),
            ("SkeletonVStack", MemoryLayout<SkeletonVStack>.size),
            ("SkeletonVisualization", MemoryLayout<SkeletonVisualization>.size),
            ("SkeletonZStack", MemoryLayout<SkeletonZStack>.size),
        ]
        for (name, size) in sizes {
            print("LAYOUT\t\(name)\t\(size)")
            XCTAssertLessThanOrEqual(size, budget, "\(name) is \(size) bytes; modifiers must not be stored inline")
        }
    }

    func testCopiesAreIndependent() {
        var original = SkeletonModifiers()
        original.padding = 4
        original.styleClasses = ["a"]
        var copy = original
        copy.padding = 8
        copy.styleClasses?.append("b")
        XCTAssertEqual(original.padding, 4)
        XCTAssertEqual(original.styleClasses, ["a"])
        XCTAssertEqual(copy.padding, 8)
        XCTAssertEqual(copy.styleClasses, ["a", "b"])
    }

    func testOptionalChainedMutationThroughContainerDoesNotLeak() {
        struct Holder { var modifiers: SkeletonModifiers? }
        var first = Holder(modifiers: SkeletonModifiers())
        first.modifiers?.background = "#FFFFFF"
        var second = first
        second.modifiers?.background = "#000000"
        second.modifiers?.hidden = true
        XCTAssertEqual(first.modifiers?.background, "#FFFFFF")
        XCTAssertNil(first.modifiers?.hidden)
        XCTAssertEqual(second.modifiers?.background, "#000000")
        XCTAssertEqual(second.modifiers?.hidden, true)
    }

    func testJSONIsUnchanged() throws {
        var modifiers = SkeletonModifiers()
        modifiers.padding = 4
        modifiers.background = "#FFFFFF"
        modifiers.hidden = true
        modifiers.styleClasses = ["a", "b"]
        modifiers.lineHeightMultiple = 1.5
        modifiers.contentClip = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(modifiers), as: UTF8.self)
        XCTAssertEqual(json, ##"{"background":"#FFFFFF","contentClip":true,"hidden":true,"lineHeightMultiple":1.5,"padding":4,"styleClasses":["a","b"]}"##)
        let decoded = try JSONDecoder().decode(SkeletonModifiers.self, from: Data(json.utf8))
        XCTAssertEqual(String(decoding: try encoder.encode(decoded), as: UTF8.self), json)
        XCTAssertEqual(String(decoding: try encoder.encode(SkeletonModifiers()), as: UTF8.self), "{}")
    }

    func testDecodingRulesAreUnchanged() throws {
        // Older fields stay lenient: an invalid value decodes as nil.
        let lenient = try JSONDecoder().decode(SkeletonModifiers.self, from: Data(#"{"padding":"wide"}"#.utf8))
        XCTAssertNil(lenient.padding)
        // M1-M10 fields stay strict: an invalid value is rejected.
        XCTAssertThrowsError(try JSONDecoder().decode(SkeletonModifiers.self, from: Data(#"{"lineHeightMultiple":0}"#.utf8)))
    }
}
