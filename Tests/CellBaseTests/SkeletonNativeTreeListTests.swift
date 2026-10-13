// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import CellBase
@testable import CellApple

/// WP1a / A1 and A5: local disclosure, Porthole parity and row-owned wrapping chips.
final class SkeletonNativeTreeListTests: XCTestCase {
    private struct PortholeFixture: Decodable {
        struct Case: Decodable {
            let name: String
            let expanded: ValueType?
            let labels: [String]
            let depths: [Int]
        }
        let scope: ValueTypeList
        let cases: [Case]
    }

    private struct ArticleFixture: Decodable {
        let skeleton: SkeletonElement
        let data: ValueType
    }

    private func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func branch(_ id: String, children: ValueTypeList = []) -> ValueType {
        .object(["id": .string(id), "label": .string(id), "children": .list(children)])
    }

    private func labels(_ rows: [SkeletonListTreeRow]) -> [String] {
        rows.compactMap { if case .string(let label)? = $0.value["label"] { return label }; return nil }
    }

    private func assertJSONEqual(_ lhs: ValueType?, _ rhs: ValueType?, file: StaticString = #filePath, line: UInt = #line) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(lhs), try encoder.encode(rhs), file: file, line: line)
    }

    func testNativeTreeListInitialExpansionRules() {
        let tree = [branch("a", children: [branch("a.1")]), branch("b", children: [branch("b.1")])]
        func flattened(_ keypath: String?, _ value: ValueType?) -> [SkeletonListTreeRow] {
            SkeletonListTree.flatten(tree, childrenKeypath: "children", expandedStateKeypath: keypath, expandedStateValue: value)
        }
        XCTAssertEqual(labels(flattened(nil, nil)), ["a", "a.1", "b", "b.1"])
        XCTAssertEqual(labels(flattened("", .list([]))), ["a", "a.1", "b", "b.1"])
        XCTAssertEqual(labels(flattened("expanded", .list([.string("b")]))), ["a", "b", "b.1"])
        for seed in [ValueType.string("*"), .list([.string("*")])] {
            XCTAssertEqual(labels(flattened("expanded", seed)), ["a", "a.1", "b", "b.1"])
        }
        let closed: [ValueType?] = [nil, .null, .list([]), .bool(true), .integer(1), .string("a"), .object(["a": .bool(true)])]
        for seed in closed {
            let rows = flattened("expanded", seed)
            XCTAssertEqual(labels(rows), ["a", "b"], "Invalid or unresolved seed must start closed: \(String(describing: seed))")
            XCTAssertTrue(rows.allSatisfy { !$0.expanded })
        }
        let all = flattened(nil, nil)
        XCTAssertEqual(all.map(\.hasChildren), [true, false, true, false])
        XCTAssertEqual(all.map(\.expanded), [true, false, true, false])
    }

    func testNativeTreeListIdentityAndNestedChildrenKeypath() {
        let tree: ValueTypeList = [
            .object(["chosen": .integer(7), "id": .string("ignored"), "nodes": .object(["items": .list([
                .object(["chosen": .null, "id": .string("fallback-id")]),
                .object(["uuid": .string("fallback-uuid")]),
                .object(["label": .string("path")])
            ])])]),
            .object(["chosen": .bool(false)]),
            .object(["nodes.items": .list([.string("direct child")])]),
            .object(["id": .null, "uuid": .null])
        ]
        let rows = SkeletonListTree.flatten(tree, childrenKeypath: "nodes.items", selectionValueKeypath: "chosen")
        XCTAssertEqual(rows.map(\.identity), ["7", "fallback-id", "fallback-uuid", "#0.2", "false", "#2", "#2.0", "#3"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 1, 0, 0, 1, 0])
        XCTAssertEqual(SkeletonListTree.initialExpansion(keypath: "expanded", value: .list([.integer(7), .bool(false)])), ["7", "false"])
        let dotted: ValueType = .object(["chosen.id": .string("direct"), "chosen": .object(["id": .string("nested")])])
        XCTAssertEqual(SkeletonListTree.identity(dotted, selectionValueKeypath: "chosen.id", path: [0]), "direct")
        XCTAssertTrue(SkeletonListTree.children(.object(["children": .string("invalid")]), keypath: "children").isEmpty)
        let numbers: [Double] = [-0.0, 7.0, 0.000001, 0.0000001, 1e20, 1e21]
        XCTAssertEqual(numbers.map { SkeletonListTree.identity(.object(["id": .float($0)]), selectionValueKeypath: nil, path: [0]) },
                       ["0", "7", "0.000001", "1e-7", "100000000000000000000", "1e+21"])
    }

    func testNativeTreeListPlainListIsUnchanged() throws {
        let input = [branch("a", children: [branch("hidden child")]), branch("b")]
        let rows = SkeletonListTree.flatten(input, childrenKeypath: nil, expanded: ["*"])
        try assertJSONEqual(.list(rows.map(\.value)), .list(input))
        XCTAssertEqual(rows.map(\.depth), [0, 0])
        XCTAssertTrue(rows.allSatisfy { !$0.hasChildren && !$0.expanded })
    }

    func testNativeTreeListCollapsingAllKeepsOtherBranchesOpen() throws {
        let tree = [branch("a", children: [branch("a.1", children: [branch("a.1.1")])]), branch("b", children: [branch("b.1")])]
        var state = SkeletonListTreeExpansion().seeded(keypath: nil, value: nil)
        func visible() -> [SkeletonListTreeRow] {
            SkeletonListTree.flatten(tree, childrenKeypath: "children", expanded: state.expanded)
        }
        state.toggle(try XCTUnwrap(visible().first), visibleRows: visible())
        XCTAssertEqual(labels(visible()), ["a", "b", "b.1"])
        state = state.seeded(keypath: nil, value: nil)
        state.toggle(try XCTUnwrap(visible().first), visibleRows: visible())
        XCTAssertEqual(labels(visible()), ["a", "a.1", "a.1.1", "b", "b.1"])
    }

    func testNativeTreeListChangedSeedReplacesLocalExpansion() throws {
        let tree = [branch("a", children: [branch("child")])]
        var state = SkeletonListTreeExpansion().seeded(keypath: "expanded", value: .list([]))
        let rows = SkeletonListTree.flatten(tree, childrenKeypath: "children", expanded: state.expanded)
        state.toggle(try XCTUnwrap(rows.first), visibleRows: rows)
        state = state.seeded(keypath: "expanded", value: .list([]))
        XCTAssertEqual(state.expanded, ["a"], "Unchanged seed preserves local opening")
        state = state.seeded(keypath: "expanded", value: .null)
        XCTAssertEqual(state.expanded, [], "Changed seed resets even when both seeds mean closed")
        state = state.seeded(keypath: "expanded", value: nil)
        XCTAssertEqual(state.expanded, [], "Unresolved and null have the same seed signature")
    }

    func testNativeTreeParityWithPorthole() throws {
        // Tree copied verbatim from the pinned Playwright source; oracle contains
        // exactly its visible labels. Depths follow the same pre-order traversal.
        let oracle = try fixture("SkeletonListTreePorthole", as: PortholeFixture.self)
        for example in oracle.cases {
            let rows = SkeletonListTree.flatten(oracle.scope, childrenKeypath: "children", selectionValueKeypath: "id",
                expandedStateKeypath: example.expanded == nil ? nil : "expanded", expandedStateValue: example.expanded)
            XCTAssertEqual(labels(rows), example.labels, example.name)
            XCTAssertEqual(rows.map(\.depth), example.depths, example.name)
        }
        var state = SkeletonListTreeExpansion().seeded(keypath: "expanded", value: .list([.string("staging")]))
        func visible() -> [SkeletonListTreeRow] {
            SkeletonListTree.flatten(oracle.scope, childrenKeypath: "children", selectionValueKeypath: "id", expanded: state.expanded)
        }
        state.toggle(try XCTUnwrap(visible().first { $0.identity == "cellscaffold" }), visibleRows: visible())
        XCTAssertEqual(labels(visible()), oracle.cases[2].labels)
        XCTAssertEqual(visible().map(\.depth), oracle.cases[2].depths)
        state.toggle(try XCTUnwrap(visible().first { $0.identity == "staging" }), visibleRows: visible())
        XCTAssertEqual(labels(visible()), oracle.cases[3].labels)
        XCTAssertEqual(visible().map(\.depth), oracle.cases[3].depths)
    }

    @MainActor
    func testNativeTreeListDisclosureDoesNotSendAnAction() async throws {
        let article = try fixture("SkeletonListArticleReaction", as: ArticleFixture.self)
        guard case .List(var spec) = article.skeleton else { return XCTFail("S2 must be List") }
        spec.selectionMode = .single
        spec.selectionPayloadMode = .itemID
        spec.selectionActionKeypath = "selection.change"
        spec.selectionStateKeypath = "selection.state"
        spec.activationActionKeypath = "selection.open"
        let host = TreeListHost(element: .List(spec), data: article.data, width: 390)
        defer { host.close() }
        try await host.settle()
        XCTAssertFalse(host.texts.contains("arancini"))
        XCTAssertEqual(host.label(of: "skeleton-list-toggle:art-arancini"), "Utvid")
        let revision = host.model.localMutationVersion
        try host.press("skeleton-list-toggle:art-arancini")
        try await host.settle()
        XCTAssertTrue(host.texts.contains("arancini"), host.texts.joined(separator: " | "))
        XCTAssertEqual(host.label(of: "skeleton-list-toggle:art-arancini"), "Slå sammen")
        XCTAssertTrue(host.requests.isEmpty, "Disclosure must not select, activate or publish selection")
        try host.press("skeleton-list-toggle:art-arancini")
        try await host.settle()
        XCTAssertFalse(host.texts.contains("arancini"))
        XCTAssertTrue(host.requests.isEmpty)
        XCTAssertEqual(host.model.localMutationVersion, revision, "Disclosure must not cause a Cell reload")
    }

    @MainActor
    func testNestedListReadsTagsFromRow() async throws {
        let article = try fixture("SkeletonListArticleReaction", as: ArticleFixture.self)
        let row = try XCTUnwrap(SkeletonRenderDataContext.value("reaction.0.children.0", in: article.data))
        let inner = SkeletonList(keypath: "tags")
        let values = try XCTUnwrap(skeletonListRowElements(inner, userInfoValue: row))
        XCTAssertEqual(values.compactMap { value -> String? in
            if case .string(let label)? = value["label"] { return label }; return nil
        }, ["arancini", "ris", "safran", "palermo", "catania", "gatemat", "fritert"])
        XCTAssertEqual(skeletonListRowElements(inner, userInfoValue: .object([:]))?.count, 0)
        XCTAssertEqual(skeletonListRowElements(inner, userInfoValue: .object(["tags": .null]))?.count, 0)
        XCTAssertNil(skeletonListRowElements(SkeletonList(keypath: "cell:///Porthole/tags"), userInfoValue: row))
        // A root-level tags collection must not leak into either S2 row.
        var root = try XCTUnwrap(article.data.objectValue)
        root["tags"] = .list([.object(["label": .string("WRONG ROOT TAG")])])
        let host = TreeListHost(element: article.skeleton, data: .object(root), width: 390)
        defer { host.close() }
        try await host.settle()
        XCTAssertFalse(host.texts.contains("WRONG ROOT TAG"))
        try host.press("skeleton-list-toggle:art-arancini")
        try await host.settle()
        for tag in ["arancini", "ris", "safran", "palermo", "catania", "gatemat", "fritert"] {
            XCTAssertTrue(host.texts.contains(tag), "Missing chip \(tag): \(host.texts)")
        }
        XCTAssertFalse(host.texts.contains("WRONG ROOT TAG"))
        XCTAssertFalse(host.texts.contains { $0.contains("ikke tilgjengelig") }, "S2's child deliberately has no label")
    }

    @MainActor
    func testOpenRowStaysOpenOnReload() async throws {
        let article = try fixture("SkeletonListArticleReaction", as: ArticleFixture.self)
        let host = TreeListHost(element: article.skeleton, data: article.data, width: 390)
        defer { host.close() }
        try await host.settle()
        try host.press("skeleton-list-toggle:art-arancini")
        try await host.settle()
        // Keep the same hosting view and skeleton identity, replace the snapshot
        // and bump the same revision a successful native Cell action would bump.
        var root = try XCTUnwrap(article.data.objectValue)
        var reaction = try XCTUnwrap(SkeletonRenderDataContext.value("reaction.0", in: article.data)?.objectValue)
        reaction["label"] = .string("Registrert: Vil smake · tolket som 7 emner")
        root["reaction"] = .list([.object(reaction)])
        host.snapshot.data = .object(root)
        host.model.markLocalMutation()
        try await host.settle()
        XCTAssertTrue(host.texts.contains("Registrert: Vil smake · tolket som 7 emner"))
        XCTAssertTrue(host.texts.contains("fritert"), "Stable row identity retains local opening after reload")
        XCTAssertEqual(host.label(of: "skeleton-list-toggle:art-arancini"), "Slå sammen")
        XCTAssertTrue(host.requests.isEmpty)
    }

    @MainActor
    func testNativeTreeListPlainListHasNoDisclosure() async throws {
        let element = try JSONDecoder().decode(SkeletonElement.self, from: Data(#"{"List":{"keypath":"rows","flowElementSkeleton":{"VStack":{"elements":[{"Text":{"keypath":"label"}}]}}}}"#.utf8))
        let data: ValueType = .object(["rows": .list([branch("a", children: [branch("child")]), branch("b")])])
        let host = TreeListHost(element: element, data: data, width: 390)
        defer { host.close() }
        try await host.settle()
        XCTAssertTrue(host.texts.contains("a")); XCTAssertTrue(host.texts.contains("b"))
        XCTAssertFalse(host.texts.contains("child"))
        XCTAssertFalse(host.identifiers.contains { $0.hasPrefix("skeleton-list-toggle:") || $0.hasPrefix("skeleton-list-row:") })
        XCTAssertTrue(host.requests.isEmpty)
    }

    @MainActor
    func testTreeRowMissingRequiredTextKeepsUnavailableMessage() async throws {
        let article = try fixture("SkeletonListArticleReaction", as: ArticleFixture.self)
        guard case .List(var tree) = article.skeleton,
              var row = tree.flowElementSkeleton,
              case .Text(var label) = row.elements[0] else { return XCTFail("S2 row template is missing") }
        label.modifiers?.visibility = nil
        row.elements[0] = .Text(label)
        tree.flowElementSkeleton = row
        let host = TreeListHost(element: .List(tree), data: article.data, width: 390)
        defer { host.close() }
        try await host.settle()
        try host.press("skeleton-list-toggle:art-arancini")
        try await host.settle()
        XCTAssertTrue(host.texts.contains { $0.contains("ikke tilgjengelig") },
                      "Only an explicit visibility rule may hide S2's absent label; required fields must retain the error")
    }

    @MainActor
    func testWrappedListItemsTakeTheirOwnWidth() async throws {
        let article = try fixture("SkeletonListArticleReaction", as: ArticleFixture.self)
        guard case .List(let tree) = article.skeleton,
              let last = tree.flowElementSkeleton?.elements.last,
              case .List(var chips) = last else {
            return XCTFail("S2 must contain the wrapped tags list")
        }
        // Exercise the default wrap contract, then explicit extra row insets.
        // Neither measurement is derived from CellListView or FlowLayout.
        let labels = ["ris", "safran", "arancini"]
        let contentSizes = labels.map { label in
            NSHostingView(rootView: Text(label).font(.caption).padding(4)
                .fixedSize().environment(\.colorScheme, .light)).fittingSize
        }
        let spacing: CGFloat = 4
        let data: ValueType = .object(["tags": .list(labels.map { .object(["label": .string($0)]) })])
        chips.modifiers?.visibility = nil
        for explicitInsets in [false, true] {
            chips.modifiers?.rowInsets = explicitInsets ? SkeletonInsets(top: 2, leading: 3, bottom: 2, trailing: 3) : nil
            // The accessibility frame of a wrap item is the union of its children,
            // so it excludes the row's own insets (measured 2026-09-29: FlowLayout
            // sees 26/44.5/52 pt with insets, the AX frames 20/38.5/46 pt).
            // Explicit insets therefore show up in the gap between chips.
            let insetWidth: CGFloat = explicitInsets ? 6 : 0
            let expectedWidths = contentSizes.map { $0.width }
            // Only two spare points: invisible row chrome must force a failure.
            let available = expectedWidths.reduce(0, +) + insetWidth * 3 + spacing * 2 + 2
            // Only the nested case: a wrap list inside a row, as Palazzo S2 uses it.
            // A wrap list alone at the root goes through CellListView's ScrollView
            // path; at this tight width it wraps every chip. Measured 2026-09-29
            // (diag3): origin/main 81601a6 and this branch place the root case the
            // same way, so it predates WP1a and is recorded as a known deviation in
            // Documentation/Skeleton_List_Tree.md, not tested here.
            for nested in [true] {
                var enclosing = SkeletonList(elements: [data], flowElementSkeleton: SkeletonVStack(elements: [.List(chips)]))
                var enclosingModifiers = SkeletonModifiers()
                enclosingModifiers.rowInsets = SkeletonInsets()
                enclosing.modifiers = enclosingModifiers
                let element: SkeletonElement = nested ? .List(enclosing) : .List(chips)
                // The ordinary enclosing row has a Spacer (8 + 8 gap).
                let host = TreeListHost(element: element, data: data, width: available + 24 + (nested ? 16 : 0))
                defer { host.close() }
                try await host.settle()
                let frames = try labels.indices.map { try host.frame(of: "skeleton-list-wrap-item:\($0)") }
                for i in labels.indices {
                    XCTAssertGreaterThan(frames[i].height, 0)
                    XCTAssertEqual(frames[i].width, expectedWidths[i], accuracy: 1, "\(labels[i]), nested=\(nested), insets=\(explicitInsets)")
                    XCTAssertEqual(frames[i].minY, frames[0].minY, accuracy: 1, "All three chips must fit on one line")
                    if i > 0 {
                        XCTAssertGreaterThan(frames[i].width, frames[i - 1].width)
                        XCTAssertEqual(frames[i].minX - frames[i - 1].maxX, spacing + insetWidth, accuracy: 1)
                    }
                }
            }
        }
    }

    @MainActor
    func testRenderArticleReactionRowImages() async throws {
        guard let directory = ProcessInfo.processInfo.environment["NATIVE_TREE_IMAGE_DIR"], !directory.isEmpty else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let article = try fixture("SkeletonListArticleReaction", as: ArticleFixture.self)
        for width in [390, 320] {
            let host = TreeListHost(element: article.skeleton, data: article.data, width: CGFloat(width))
            defer { host.close() }
            try await host.settle()
            XCTAssertFalse(host.texts.contains("arancini"))
            if width == 390 {
                try host.savePNG(to: output.appendingPathComponent("native-brikker-lukket.png"))
            }
            try host.press("skeleton-list-toggle:art-arancini")
            try await host.settle()
            for tag in ["arancini", "ris", "safran", "palermo", "catania", "gatemat", "fritert"] {
                XCTAssertTrue(host.texts.contains(tag), "Missing chip \(tag) at \(width) pt")
            }
            XCTAssertFalse(host.texts.contains { $0.contains("ikke tilgjengelig") })
            let frames = try (0..<7).map { try host.frame(of: "skeleton-list-wrap-item:\($0)") }
            let header = try host.frame(ofText: "Registrert: Interessant · tolket som 7 emner")
            let headerGap = header.minY - frames[0].maxY // AX frames use screen coordinates (y up).
            XCTAssertGreaterThanOrEqual(headerGap, 0, "Chips must not overlap the registered label")
            XCTAssertLessThanOrEqual(headerGap, 16, "An absent row field must not leave a blank line above the chips")
            let firstLine = frames.filter { abs($0.minY - frames[0].minY) < 1 }
            if width == 390 {
                XCTAssertGreaterThanOrEqual(firstLine.count, 5, "390 pt should pack at least five of the S2 chips on the first line")
            }
            let lineTops = Array(Set(frames.map { $0.maxY.rounded() })).sorted(by: >)
            for i in 1..<lineTops.count {
                XCTAssertEqual(lineTops[i - 1] - lineTops[i] - frames[0].height, 4, accuracy: 1,
                               "itemSpacing controls the vertical gap as well")
            }
            XCTAssertTrue(host.requests.isEmpty)
            try host.savePNG(to: output.appendingPathComponent(width == 390 ? "native-brikker-aapen.png" : "native-brikker-smal.png"))
            if width == 390 {
                // TreeListTestSurface explicitly sets .environment(\.colorScheme, .light),
                // and the NSHostingView uses Aqua; name this review artifact accordingly.
                try host.savePNG(to: output.appendingPathComponent("native-brikker-aapen-lyst.png"))
            }
        }
    }
}

private extension ValueType {
    var objectValue: Object? { if case .object(let object) = self { return object }; return nil }
}

@MainActor
private final class TreeListSnapshot: ObservableObject {
    @Published var data: ValueType
    init(_ data: ValueType) { self.data = data }
}

@MainActor
private struct TreeListTestSurface: View {
    let element: SkeletonElement
    @ObservedObject var snapshot: TreeListSnapshot
    let model: PortholeViewModel
    let handler: SkeletonNativeActionHandler

    var body: some View {
        SkeletonView(element: element, showsKeyboardToolbar: false,
                     renderData: SkeletonRenderDataContext(root: snapshot.data))
            .environmentObject(model)
            .environment(\.skeletonNativeActionHandler, handler)
            .padding(12)
            .background(Color.white)
            .environment(\.colorScheme, .light)
    }
}

/// Uses the same offscreen NSHostingView + cacheDisplay path as the supplied
/// bildevei-probe.swift. ImageRenderer is deliberately not involved.
@MainActor
private final class TreeListHost {
    let snapshot: TreeListSnapshot
    let model = PortholeViewModel()
    private(set) var requests: [SkeletonNativeActionRequest] = []
    private var host: NSHostingView<TreeListTestSurface>!
    private let window: NSWindow
    private let accessibilityMode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    private let previousAccessibilityMode: Any?

    init(element: SkeletonElement, data: ValueType, width: CGFloat) {
        snapshot = TreeListSnapshot(data)
        previousAccessibilityMode = NSApplication.shared.accessibilityAttributeValue(accessibilityMode)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: accessibilityMode)
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 420),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let handler = SkeletonNativeActionHandler { [weak self] request in
            self?.requests.append(request)
            return .bool(true)
        }
        host = NSHostingView(rootView: TreeListTestSurface(element: element, snapshot: snapshot, model: model, handler: handler))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 420)
        host.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
        window.close()
        NSApplication.shared.accessibilitySetValue(previousAccessibilityMode, forAttribute: accessibilityMode)
    }

    func settle() async throws {
        // Yield the main actor for list .task reads and SwiftUI layout work.
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private func attribute(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard node.responds(to: selector) else { return nil }
        return node.perform(selector)?.takeUnretainedValue()
    }

    private var nodes: [NSObject] {
        var result: [NSObject] = []
        var visited = Set<ObjectIdentifier>()
        func walk(_ value: Any) {
            guard let node = value as? NSObject, visited.insert(ObjectIdentifier(node)).inserted else { return }
            result.append(node)
            for child in attribute(node, "accessibilityChildren") as? [Any] ?? [] { walk(child) }
            if let view = node as? NSView { view.subviews.forEach(walk) }
        }
        walk(host as NSView)
        return result
    }

    var texts: [String] {
        nodes.flatMap { node in
            [attribute(node, "accessibilityLabel") as? String, attribute(node, "accessibilityValue") as? String].compactMap { $0 }
        }
    }

    var identifiers: [String] { nodes.compactMap { attribute($0, "accessibilityIdentifier") as? String } }

    func label(of identifier: String) -> String? {
        guard let node = nodes.first(where: { attribute($0, "accessibilityIdentifier") as? String == identifier }) else { return nil }
        return attribute(node, "accessibilityLabel") as? String
    }

    func frame(of identifier: String) throws -> CGRect {
        let node = try XCTUnwrap(nodes.first { attribute($0, "accessibilityIdentifier") as? String == identifier },
                                 "Missing \(identifier); found \(identifiers)")
        return try accessibilityFrame(node)
    }

    func frame(ofText text: String) throws -> CGRect {
        let node = try XCTUnwrap(nodes.first {
            attribute($0, "accessibilityValue") as? String == text
                || attribute($0, "accessibilityLabel") as? String == text
        }, "Missing text \(text)")
        return try accessibilityFrame(node)
    }

    private func accessibilityFrame(_ node: NSObject) throws -> CGRect {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard node.responds(to: selector) else {
            XCTFail("Node has no accessibility frame")
            return .zero
        }
        // Like accessibilityPerformPress, this accessor needs its actual ABI;
        // NSObject.perform is only appropriate for object-valued attributes.
        typealias Frame = @convention(c) (AnyObject, Selector) -> CGRect
        let frame = unsafeBitCast(node.method(for: selector), to: Frame.self)
        return frame(node, selector)
    }

    func press(_ identifier: String) throws {
        let node = try XCTUnwrap(nodes.first { attribute($0, "accessibilityIdentifier") as? String == identifier }, "Missing \(identifier); found \(identifiers)")
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard node.responds(to: selector) else { return XCTFail("\(identifier) has no press action") }
        // SwiftUI AX objects need not declare NSAccessibilityProtocol conformance.
        // Call its Objective-C accessor with the correct BOOL result ABI.
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let press = unsafeBitCast(node.method(for: selector), to: Press.self)
        XCTAssertTrue(press(node, selector), "Press failed for \(identifier)")
    }

    func savePNG(to url: URL) throws {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var colors = Set<UInt32>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = UInt32(max(0, min(255, color.redComponent * 255)))
                let g = UInt32(max(0, min(255, color.greenComponent * 255)))
                let b = UInt32(max(0, min(255, color.blueComponent * 255)))
                colors.insert((r << 16) | (g << 8) | b)
            }
        }
        XCTAssertGreaterThan(colors.count, 8, "\(url.lastPathComponent) must contain rendered content, not a uniform bitmap")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
#endif
