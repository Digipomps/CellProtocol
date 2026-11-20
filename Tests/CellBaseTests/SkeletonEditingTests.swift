// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import CellBase

/// PDD redigerer-paneler 2026-11-20, F5.1 / F1.1: the rules for moving,
/// duplicating and wrapping elements, and which targets are legal.
final class SkeletonEditingTests: XCTestCase {

    // V[ T(title) T(hero) H[ T(menu) T(book) ] L{ V[ T(row) ] } T(hours) ]
    private let pageJSON = #"""
    {"VStack":{"elements":[
      {"Text":{"text":"title"}},
      {"Text":{"text":"hero"}},
      {"HStack":{"elements":[{"Text":{"text":"menu"}},{"Text":{"text":"book"}}]}},
      {"List":{"keypath":"rows","flowElementSkeleton":{"VStack":{"elements":[{"Text":{"text":"row"}}]}}}},
      {"Text":{"text":"hours"}}
    ]}}
    """#

    private func page() throws -> SkeletonElement {
        try JSONDecoder().decode(SkeletonElement.self, from: Data(pageJSON.utf8))
    }

    private func path(_ raw: String) -> SkeletonEditPath { SkeletonEditPath(raw)! }

    /// Compact shape for assertions: V[...], H[...], L{...}, Tabs<...|...>, text.
    private func shape(_ element: SkeletonElement) -> String {
        switch element {
        case .Text(let text): return text.text ?? "?"
        case .VStack(let stack): return "V[" + stack.elements.map(shape).joined(separator: " ") + "]"
        case .HStack(let stack): return "H[" + stack.elements.map(shape).joined(separator: " ") + "]"
        case .List(let list): return "L{" + (list.flowElementSkeleton.map { shape(.VStack($0)) } ?? "") + "}"
        case .Tabs(let tabs): return "Tabs<" + tabs.panels.map { $0.content.map(shape).joined(separator: " ") }.joined(separator: "|") + ">"
        default: return SkeletonEditing.kindIdentifier(for: element)
        }
    }

    func testPathParsingAndEncoding() throws {
        XCTAssertEqual(SkeletonEditPath("root"), .root)
        XCTAssertEqual(SkeletonEditPath(""), .root)
        XCTAssertEqual(SkeletonEditPath("root.2.1")?.indices, [2, 1])
        XCTAssertEqual(SkeletonEditPath("2.1")?.indices, [2, 1])
        XCTAssertNil(SkeletonEditPath("root.x"))
        XCTAssertNil(SkeletonEditPath("root..1"))
        XCTAssertNil(SkeletonEditPath("-1"))
        let data = try JSONEncoder().encode(path("root.2.1"))
        XCTAssertEqual(String(data: data, encoding: .utf8), #""root.2.1""#)
        XCTAssertEqual(try JSONDecoder().decode(SkeletonEditPath.self, from: data), path("root.2.1"))
    }

    func testElementLookupIncludesListTemplate() throws {
        let root = try page()
        XCTAssertEqual(shape(SkeletonEditing.element(in: root, at: path("root.2.1"))!), "book")
        XCTAssertEqual(shape(SkeletonEditing.element(in: root, at: path("root.3.0.0"))!), "row")
        XCTAssertNil(SkeletonEditing.element(in: root, at: path("root.9")))
        XCTAssertTrue(SkeletonEditing.isFixedSlot(path("root.3.0"), in: root))
        XCTAssertFalse(SkeletonEditing.isFixedSlot(path("root.3.0.0"), in: root))
    }

    func testMoveButtonToBeforeHeroAdjustsForRemovalInOtherBranch() throws {
        let root = try page()
        let (moved, newPath) = try SkeletonEditing.moving(
            from: path("root.2.1"),
            to: SkeletonInsertionPoint(parent: .root, index: 1),
            in: root
        )
        XCTAssertEqual(shape(moved), "V[title book hero H[menu] L{V[row]} hours]")
        XCTAssertEqual(newPath, path("root.1"))
        XCTAssertEqual(shape(SkeletonEditing.element(in: moved, at: newPath)!), "book")
    }

    func testMoveDownwardsInSameParentCountsPositionBeforeTheMove() throws {
        let root = try page()
        // "title" to just before "hours" (index 4 in the tree before the move).
        let (moved, newPath) = try SkeletonEditing.moving(
            from: path("root.0"),
            to: SkeletonInsertionPoint(parent: .root, index: 4),
            in: root
        )
        XCTAssertEqual(shape(moved), "V[hero H[menu book] L{V[row]} title hours]")
        XCTAssertEqual(newPath, path("root.3"))
    }

    func testMoveIntoLaterSiblingContainerAdjustsParentIndex() throws {
        let root = try page()
        // "hero" (root.1) into the HStack (root.2) at the end.
        let (moved, newPath) = try SkeletonEditing.moving(
            from: path("root.1"),
            to: SkeletonInsertionPoint(parent: path("root.2"), index: 2),
            in: root
        )
        XCTAssertEqual(shape(moved), "V[title H[menu book hero] L{V[row]} hours]")
        XCTAssertEqual(newPath, path("root.1.2"))
    }

    func testMoveIntoListRowTemplate() throws {
        let root = try page()
        let (moved, newPath) = try SkeletonEditing.moving(
            from: path("root.4"),
            to: SkeletonInsertionPoint(parent: path("root.3.0"), index: 1),
            in: root
        )
        XCTAssertEqual(shape(moved), "V[title hero H[menu book] L{V[row hours]}]")
        XCTAssertEqual(newPath, path("root.3.0.1"))
    }

    func testIllegalMovesAreRefused() throws {
        let root = try page()
        XCTAssertThrowsError(try SkeletonEditing.moving(from: .root, to: SkeletonInsertionPoint(parent: .root, index: 0), in: root)) {
            XCTAssertEqual($0 as? SkeletonEditingError, .cannotMoveRoot)
        }
        XCTAssertThrowsError(try SkeletonEditing.moving(from: path("root.2"), to: SkeletonInsertionPoint(parent: path("root.2"), index: 0), in: root)) {
            XCTAssertEqual($0 as? SkeletonEditingError, .targetInsideSource("root.2"))
        }
        XCTAssertThrowsError(try SkeletonEditing.moving(from: path("root.3.0"), to: SkeletonInsertionPoint(parent: .root, index: 0), in: root)) {
            XCTAssertEqual($0 as? SkeletonEditingError, .fixedSlot("root.3.0"))
        }
        XCTAssertThrowsError(try SkeletonEditing.moving(from: path("root.0"), to: SkeletonInsertionPoint(parent: path("root.1"), index: 0), in: root)) {
            XCTAssertEqual($0 as? SkeletonEditingError, .notAContainer("root.1"))
        }
        XCTAssertThrowsError(try SkeletonEditing.moving(from: path("root.0"), to: SkeletonInsertionPoint(parent: path("root.3"), index: 0), in: root)) {
            XCTAssertEqual($0 as? SkeletonEditingError, .notAContainer("root.3"))
        }
        XCTAssertThrowsError(try SkeletonEditing.moving(from: path("root.0"), to: SkeletonInsertionPoint(parent: .root, index: 6), in: root)) {
            XCTAssertEqual($0 as? SkeletonEditingError, .indexOutOfRange("root#6"))
        }
    }

    func testLegalTargetsExcludeSelfNoOpsAndListSlot() throws {
        let root = try page()
        let targets = SkeletonEditing.legalMoveTargets(for: path("root.2.1"), in: root)
        let ids = Set(targets.map(\.id))
        // root has 5 children: 6 positions. HStack (source parent) has 2: positions 0..2 minus 1 and 2.
        // List template V[row]: 2 positions.
        XCTAssertEqual(ids, ["root#0", "root#1", "root#2", "root#3", "root#4", "root#5",
                             "root.2#0",
                             "root.3.0#0", "root.3.0#1"])
        for target in targets {
            let (moved, newPath) = try SkeletonEditing.moving(from: path("root.2.1"), to: target.point, in: root)
            XCTAssertEqual(newPath, target.resultingPath, target.id)
            XCTAssertEqual(shape(SkeletonEditing.element(in: moved, at: newPath)!), "book", target.id)
        }
        // A container is never a target for itself or its descendants.
        let hstackTargets = SkeletonEditing.legalMoveTargets(for: path("root.2"), in: root).map(\.point.parent)
        XCTAssertFalse(hstackTargets.contains { path("root.2").contains($0) })
        XCTAssertTrue(SkeletonEditing.legalMoveTargets(for: .root, in: root).isEmpty)
        XCTAssertTrue(SkeletonEditing.legalMoveTargets(for: path("root.3.0"), in: root).isEmpty)
    }

    func testPreviewEqualsMoveResult() throws {
        let root = try page()
        let point = SkeletonInsertionPoint(parent: .root, index: 1)
        let preview = try SkeletonEditing.previewMove(from: path("root.2.1"), to: point, in: root)
        let moved = try SkeletonEditing.moving(from: path("root.2.1"), to: point, in: root)
        XCTAssertEqual(try canonical(preview.root), try canonical(moved.root))
        XCTAssertEqual(preview.path, moved.path)
    }

    func testDuplicateAndWrapAndRemove() throws {
        let root = try page()
        let (duplicated, copyPath) = try SkeletonEditing.duplicating(at: path("root.2.1"), in: root)
        XCTAssertEqual(shape(duplicated), "V[title hero H[menu book book] L{V[row]} hours]")
        XCTAssertEqual(copyPath, path("root.2.2"))

        let (wrapped, wrapperPath) = try SkeletonEditing.wrapping(at: path("root.1"), in: .vStack, root: root)
        XCTAssertEqual(shape(wrapped), "V[title V[hero] H[menu book] L{V[row]} hours]")
        XCTAssertEqual(wrapperPath, path("root.1"))

        let (removed, element) = try SkeletonEditing.removing(at: path("root.4"), in: root)
        XCTAssertEqual(shape(removed), "V[title hero H[menu book] L{V[row]}]")
        XCTAssertEqual(shape(element), "hours")
        XCTAssertThrowsError(try SkeletonEditing.removing(at: path("root.3.0"), in: root))
        XCTAssertThrowsError(try SkeletonEditing.duplicating(at: .root, in: root))
    }

    func testTabsKeepPanelsWhenMovingAcrossThem() throws {
        let tabs = SkeletonElement.Tabs(SkeletonTabs(
            activeTabStateKeypath: "tab",
            panels: [
                SkeletonTabPanel(id: "a", content: [.Text(SkeletonText(text: "a1")), .Text(SkeletonText(text: "a2"))]),
                SkeletonTabPanel(id: "b", content: [.Text(SkeletonText(text: "b1"))])
            ]
        ))
        let root = SkeletonElement.VStack(SkeletonVStack(elements: [tabs, .Text(SkeletonText(text: "x"))]))
        XCTAssertEqual(shape(root), "V[Tabs<a1 a2|b1> x]")

        // a1 to the end: lands in the last panel.
        let toEnd = try SkeletonEditing.moving(from: path("root.0.0"), to: SkeletonInsertionPoint(parent: path("root.0"), index: 3), in: root)
        XCTAssertEqual(shape(toEnd.root), "V[Tabs<a2|b1 a1> x]")
        XCTAssertEqual(toEnd.path, path("root.0.2"))

        // x into the tabs at index 1: in panel a, before a2.
        let inside = try SkeletonEditing.moving(from: path("root.1"), to: SkeletonInsertionPoint(parent: path("root.0"), index: 1), in: root)
        XCTAssertEqual(shape(inside.root), "V[Tabs<a1 x a2|b1>]")

        // b1 out of the tabs.
        let out = try SkeletonEditing.moving(from: path("root.0.2"), to: SkeletonInsertionPoint(parent: .root, index: 2), in: root)
        XCTAssertEqual(shape(out.root), "V[Tabs<a1 a2|> x b1]")
    }

    func testPurposeRefSetReadAndGroup() throws {
        let root = try page()
        let tagged = try SkeletonEditing.settingPurposeRef("purpose://palazzo.table.book", at: path("root.2.1"), in: root)
        XCTAssertEqual(SkeletonEditing.purposeRef(of: SkeletonEditing.element(in: tagged, at: path("root.2.1"))!), "purpose://palazzo.table.book")
        XCTAssertEqual(shape(tagged), shape(root))
        let groups = SkeletonEditing.purposeGroups(in: tagged)
        XCTAssertEqual(groups.first?.purposeRef, "purpose://palazzo.table.book")
        XCTAssertEqual(groups.first?.paths, [path("root.2.1")])
        XCTAssertNil(groups.last?.purposeRef)
        // Every element except the list template slot is in exactly one group.
        XCTAssertEqual(groups.flatMap(\.paths).count, SkeletonEditing.allPaths(in: root).count - 1)
        let cleared = try SkeletonEditing.settingPurposeRef(nil, at: path("root.2.1"), in: tagged)
        XCTAssertNil(SkeletonEditing.purposeRef(of: SkeletonEditing.element(in: cleared, at: path("root.2.1"))!))
        XCTAssertThrowsError(try SkeletonEditing.settingPurposeRef("bord", at: path("root.2.1"), in: root)) {
            XCTAssertEqual($0 as? SkeletonEditingError, .invalidPurposeRef("bord"))
        }
    }

    private func canonical(_ element: SkeletonElement) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: try encoder.encode(element), encoding: .utf8) ?? ""
    }
}
