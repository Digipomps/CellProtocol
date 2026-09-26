// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import SwiftUI
import CellBase
@testable import CellApple
#if os(macOS)
import AppKit
#endif

final class SkeletonNativeRendererTests: XCTestCase {
    private func assertJSONEqual(_ left: ValueType?, _ right: ValueType?, file: StaticString = #filePath, line: UInt = #line) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(left), try encoder.encode(right), file: file, line: line)
    }
    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("fixtures/skeleton-wp-r1/\(name).json"))
    }
    private func tree() throws -> SkeletonTree {
        guard case .Tree(let tree) = try JSONDecoder().decode(SkeletonElement.self, from: fixture("tree")) else {
            throw NSError(domain: "test", code: 1)
        }
        return tree
    }
    private func node(_ id: String, parent: String? = nil, level: Int = 1, inset: Int = 8,
                      hasChildren: Bool = false, expanded: Bool = false) -> ValueType {
        .object(["nodeID": .string(id), "parentID": parent.map(ValueType.string) ?? .null,
                 "level": .integer(level), "leadingInset": .integer(inset), "hasChildren": .bool(hasChildren),
                 "expanded": .bool(expanded), "label": .string(id)])
    }

    func testRowAndMountLookupUsesWholePathItemFirstThenRootIncludingNull() async throws {
        let root: ValueType = .object(["title": .string("Root"), "nested": .object(["fallback": .string("Host")]),
                                      "rows": .list([.string("host")])])
        let item: ValueType = .object(["title": .null, "nested": .object(["other": .bool(true)]),
                                      "rows": .list([.string("item")])])
        let context = SkeletonRenderDataContext(root: root, item: item)
        XCTAssertEqual(context.resolve("title"), .null)
        XCTAssertEqual(context.resolve("nested.fallback"), .string("Host"))
        XCTAssertEqual(context.resolve("nested.other"), .bool(true))
        XCTAssertNil(context.resolve("cell:///Porthole/title"))
        let list = SkeletonList(keypath: "rows")
        let rows = try await list.getElements(in: context, allowCellFallback: false)
        XCTAssertEqual(rows, [.string("item")])
        let rootRows = try await list.getElements(in: context.row(nil), allowCellFallback: false)
        XCTAssertEqual(rootRows, [.string("host")])
        let nullRows = try await list.getElements(in: context.row(.object(["rows": .null])), allowCellFallback: false)
        XCTAssertEqual(nullRows, [])
    }

    func testSharedTwoInstanceOracleAndSourceUpdate() throws {
        let oracle = try JSONDecoder().decode(ValueType.self, from: fixture("component-mount-two-instances"))
        let root = try XCTUnwrap(oracle["initialRoot"])
        let context = SkeletonRenderDataContext(root: root)
        var a = try SkeletonComponentInstance(instanceID: "A", mount: .decodeFrom(context.resolve("mounts.A")))
        let b = try SkeletonComponentInstance(instanceID: "B", mount: .decodeFrom(context.resolve("mounts.B")))
        for instance in [a, b] {
            let data = context.row(instance.mount.item)
            let expected = SkeletonRenderDataContext.value("expected.initial.\(instance.instanceID)", in: oracle)
            XCTAssertEqual(data.resolve("title"), expected?["title"])
            XCTAssertEqual(data.resolve("subtitle"), expected?["subtitle"])
        }
        let originalDefinitionID = a.mount.skeleton.id
        let update = try XCTUnwrap(SkeletonRenderDataContext.value("sourceUpdates.0.value", in: oracle))
        a.update(try SkeletonComponentInstance.decode(update))
        XCTAssertEqual(a.instanceID, "A")
        XCTAssertEqual(b.instanceID, "B")
        XCTAssertEqual(a.definitionGeneration, 0)
        XCTAssertEqual(a.mount.skeleton.id, originalDefinitionID)
        XCTAssertEqual(context.row(a.mount.item).resolve("title"), .string("Program oppdatert"))
        XCTAssertEqual(context.row(b.mount.item).resolve("title"), .string("Sesjoner"))
        XCTAssertEqual(context.row(a.mount.item).resolve("subtitle"), .string("Fra verten"))
    }

    @MainActor
    func testSourceActionDispatchMatchesOracleWithoutPayloadMutation() async throws {
        let oracle = try JSONDecoder().decode(ValueType.self, from: fixture("component-mount-two-instances"))
        let root = try XCTUnwrap(oracle["initialRoot"])
        let mount = try SkeletonComponentInstance.decode(XCTUnwrap(SkeletonRenderDataContext(root: root).resolve("mounts.A")))
        let instance = SkeletonComponentInstance(instanceID: "A", mount: mount)
        let expected = try XCTUnwrap(SkeletonRenderDataContext.value("expected.actions.0.dispatch", in: oracle))
        let payload = try XCTUnwrap(expected["payload"])
        var requests: [SkeletonNativeActionRequest] = []
        let handler = SkeletonNativeActionHandler { request in requests.append(request); return .bool(true) }
        _ = try await skeletonNativeSend(keypath: "actions.refresh", payload: payload, scope: instance.actionScope,
                                        handler: handler, viewModel: PortholeViewModel())
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.sourceCellEndpoint, "cell:///ProgramFixture")
        XCTAssertEqual(request.keypath, "actions.refresh")
        try assertJSONEqual(request.payload, payload)
        XCTAssertEqual(request.payload?["instanceID"], .string("user-payload"))
        XCTAssertEqual(request.mount, .init(instanceID: "A", componentID: "program-card", revision: "r1"))
    }

    @MainActor
    func testMountedActionWithoutAdapterFailsExplicitly() async throws {
        let scope = SkeletonNativeActionScope(sourceCellEndpoint: "cell:///Source",
            mount: .init(instanceID: "A", componentID: "card", revision: "r1"))
        do {
            _ = try await skeletonNativeSend(keypath: "action", payload: .bool(true), scope: scope,
                                            handler: nil, viewModel: PortholeViewModel())
            XCTFail("Must not fall through to the host cell")
        } catch SkeletonNativeRuntimeError.sourceActionAdapterMissing { }
    }

    func testComponentRevisionReplacesDefinitionButKeepsInstanceAndStableFieldKeys() throws {
        let field = SkeletonElement.TextField(SkeletonTextField(sourceKeypath: "draft", targetKeypath: "save"))
        var instance = SkeletonComponentInstance(instanceID: "A", mount: .init(componentID: "card", revision: "r1",
            sourceCellEndpoint: "cell:///Source", skeleton: field))
        let next = try JSONDecoder().decode(SkeletonElement.self, from: JSONEncoder().encode(field))
        instance.update(.init(componentID: "card", revision: "r2", sourceCellEndpoint: "cell:///Source", skeleton: next))
        XCTAssertEqual(instance.instanceID, "A")
        XCTAssertEqual(instance.definitionGeneration, 1)
        XCTAssertNotEqual(instance.mount.skeleton.id, field.id)
        XCTAssertEqual(instance.mount.skeleton.nativeIdentity(fallback: "0"), field.nativeIdentity(fallback: "0"))
    }

    func testTreeKeyboardUsesConfirmedOrderAndSeparateActions() throws {
        let spec = try tree()
        var state = SkeletonTreeState()
        try state.update([node("a", hasChildren: true), node("b"), node("c")], selectedID: "a", spec: spec)
        let expand = try XCTUnwrap(state.command(.right, spec: spec))
        XCTAssertEqual(expand.0, "tree.expand")
        try assertJSONEqual(expand.1, .object(["nodeID": .string("a"), "expanded": .bool(true)]))
        XCTAssertFalse(state.nodes[0].expanded)
        XCTAssertEqual(state.nodes.map(\.id), ["a", "b", "c"])
        XCTAssertNil(state.command(.down, spec: spec))
        XCTAssertEqual(state.focusedID, "b")
        let select = try XCTUnwrap(state.command(.enter, spec: spec))
        XCTAssertEqual(select.0, "tree.select")
        try assertJSONEqual(select.1, .object(["nodeID": .string("b")]))
        XCTAssertEqual(state.selectedID, "a")
        _ = state.command(.end, spec: spec); XCTAssertEqual(state.focusedID, "c")
        _ = state.command(.up, spec: spec); XCTAssertEqual(state.focusedID, "b")
        _ = state.command(.home, spec: spec); XCTAssertEqual(state.focusedID, "a")
        try assertJSONEqual(state.command(.space, spec: spec)?.1, .object(["nodeID": .string("a")]))
    }

    func testTreeFocusReturnsToSurvivingAncestorOnConfirmedCollapseAndReorder() throws {
        let spec = try tree()
        var state = SkeletonTreeState()
        let parent = node("a", hasChildren: true, expanded: true)
        let child = node("b", parent: "a", level: 2, inset: 8, hasChildren: true, expanded: true)
        let grandchild = node("c", parent: "b", level: 3, inset: 29)
        try state.update([parent, child, grandchild], selectedID: "c", spec: spec)
        XCTAssertEqual(state.nodes[1].level, 2)
        XCTAssertEqual(state.nodes[1].leadingInset, state.nodes[0].leadingInset)
        _ = state.command(.left, spec: spec); XCTAssertEqual(state.focusedID, "b")
        let collapse = try XCTUnwrap(state.command(.left, spec: spec))
        try assertJSONEqual(collapse.1, .object(["nodeID": .string("b"), "expanded": .bool(false)]))
        XCTAssertTrue(state.nodes[1].expanded)
        state.focusedID = "c"
        try state.update([node("z"), node("a", hasChildren: true)], selectedID: "c", spec: spec)
        XCTAssertEqual(state.focusedID, "a")
        try state.update([node("a", hasChildren: true), node("z")], selectedID: "c", spec: spec)
        XCTAssertEqual(state.focusedID, "a")
        try state.update([], selectedID: nil, spec: spec)
        XCTAssertNil(state.focusedID)
    }

    func testTreeRightEntersFirstConfirmedChildAndRejectsDuplicateIDs() throws {
        let spec = try tree()
        var state = SkeletonTreeState()
        try state.update([node("a", hasChildren: true, expanded: true), node("b", parent: "a", level: 2)], selectedID: "a", spec: spec)
        _ = state.command(.right, spec: spec)
        XCTAssertEqual(state.focusedID, "b")
        XCTAssertThrowsError(try state.update([node("a"), node("a")], selectedID: nil, spec: spec))
        XCTAssertEqual(state.nodes.map(\.id), ["a", "b"])
    }

    func testDeclared236PointGridTrackDoesNotInherit1200PointSurface() throws {
        let layout = try SkeletonLayoutContext(availableWidth: 1200, availableHeight: 800, capabilities: [.keyboard])
        let columns = [SkeletonGridColumn(type: .fixed, value: 236), SkeletonGridColumn(type: .flexible, min: 0)]
        let widths = SkeletonNativeLayout.gridWidths(columns, width: layout.availableWidth, spacing: 12, count: 2)
        XCTAssertEqual(widths, [236, 952])
        let child = try layout.narrowed(availableWidth: widths[0])
        var m = SkeletonModifiers()
        m.layoutVariants = [.init(maxAvailableWidth: 236, fontSize: 11), .init(minAvailableWidth: 237, fontSize: 20)]
        XCTAssertEqual(SkeletonNativeLayout.effective(m, layout: child, data: .init()).0.fontSize, 11)
        XCTAssertEqual(SkeletonNativeLayout.children(child, modifiers: .init()).availableWidth, 236)
    }

    func testVariantsUseInclusiveFirstMatchUnknownDimensionsAndItemScope() throws {
        var m = SkeletonModifiers(); m.padding = 10; m.width = 300
        m.layoutVariants = [.init(minAvailableWidth: 300, maxAvailableWidth: 300, requiresCapability: [.keyboard], paddingInsets: .init(leading: 0), fontSize: 12),
                            .init(fontSize: 18)]
        let layout = try SkeletonLayoutContext(availableWidth: 1200, availableHeight: 800, capabilities: [.keyboard])
        let effective = SkeletonNativeLayout.effective(m, layout: layout, data: .init()).0
        XCTAssertEqual(effective.fontSize, 12)
        XCTAssertEqual(SkeletonNativeLayout.children(layout, modifiers: effective).availableWidth, 290)
        m.width = nil
        XCTAssertEqual(SkeletonNativeLayout.effective(m, layout: try .init(), data: .init()).0.fontSize, 18)
        let condition = try JSONDecoder().decode(SkeletonCondition.self, from: Data(#"{"scope":"item","keypath":"mode","equals":"full"}"#.utf8))
        m.layoutVariants = [.init(when: condition, fontSize: 22)]
        XCTAssertEqual(SkeletonNativeLayout.effective(m, layout: layout, data: .init(item: .object(["mode": .string("full")]))).0.fontSize, 22)
    }

    func testInsetsExplicitZeroAndFontWeightsMatchWebTable() {
        let insets = SkeletonInsets(top: 0, leading: 2).resolved(padding: 9).nativeInsets
        XCTAssertEqual(insets, EdgeInsets(top: 0, leading: 2, bottom: 9, trailing: 9))
        let names = ["ultralight", "thin", "light", "regular", "medium", "semibold", "bold", "heavy", "black"]
        for (index, name) in names.enumerated() {
            XCTAssertEqual(SkeletonNativeTypography.weight(name), SkeletonNativeTypography.weight(String((index + 1) * 100)))
        }
        XCTAssertEqual(weightFrom("600"), .semibold)
        XCTAssertEqual(weightFrom("unknown"), .regular)
        XCTAssertEqual(SkeletonNativeLayout.verticalAlignment("firstTextBaseline"), .firstTextBaseline)
    }

    func testHostDragMarksAllAcceptingSurfacesAndClearsOnCancel() {
        let drag = SkeletonNativeDragContext()
        XCTAssertFalse(drag.isActive)
        drag.begin(sourceID: "component:A", role: "card", payload: .string("A"))
        XCTAssertTrue(drag.accepts(["card"]))
        XCTAssertFalse(drag.accepts(["file"]))
        XCTAssertFalse(drag.accepts([]))
        let styles = SkeletonInteractionStyles(dragSource: .init(opacity: 0.42),
                                               dragActive: .init(background: "#fff", opacity: 0.82))
        let source = styles.dragStyle(isSource: drag.sourceID == "component:A", isActive: drag.isActive)
        XCTAssertEqual(source?.opacity, 0.42)
        XCTAssertEqual(source?.background, "#fff")
        XCTAssertEqual(styles.dragStyle(isSource: false, isActive: drag.isActive)?.opacity, 0.82)
        drag.end()
        XCTAssertFalse(drag.isActive); XCTAssertNil(drag.sourceID); XCTAssertNil(drag.payload)
        XCTAssertNil(styles.dragStyle(isSource: false, isActive: drag.isActive))
    }

    func testGenericTransferUsesRowPayloadForComponentsAndOtherElements() throws {
        var m = SkeletonModifiers()
        m.draggableRole = "card"; m.dragPayloadKeypath = "transfer"; m.dragPreviewRole = "card"
        m.dropActionKeypath = "actions.drop"; m.acceptedDragRoles = ["card"]; m.dropTargetPayloadKeypath = "target"
        let data = SkeletonRenderDataContext(root: .object(["target": .string("host-target")]),
            item: .object(["transfer": .object(["componentID": .string("card"), "instanceID": .string("A")])]))
        let source = try XCTUnwrap(SkeletonNativeTransfer.source(m, data: data, id: "component:A"))
        XCTAssertEqual(source.elementID, "component:A"); XCTAssertEqual(source.role, "card")
        XCTAssertEqual(source.payload?["instanceID"], .string("A")); XCTAssertEqual(source.previewRole, "card")
        let target = try XCTUnwrap(SkeletonNativeTransfer.target(m, data: data, id: "surface"))
        XCTAssertEqual(target.payload, .string("host-target")); XCTAssertEqual(target.actionKeypath, "actions.drop")
        XCTAssertEqual(target.acceptedRoles, ["card"])
    }

    func testComponentAndFieldIdentitySurvivesSiblingReorderAndDraftsAreIsolated() {
        let a = SkeletonElement.ComponentSurface(.init(sourceKeypath: "a", instanceID: "A", variant: .pinned))
        let b = SkeletonElement.ComponentSurface(.init(sourceKeypath: "b", instanceID: "B", variant: .pinned))
        XCTAssertEqual(SkeletonNativeChild.children([a, b]).map(\.id), ["component:A", "component:B"])
        XCTAssertEqual(SkeletonNativeChild.children([b, a]).map(\.id), ["component:B", "component:A"])
        let first = SkeletonComponentLocalState(), second = SkeletonComponentLocalState()
        first.drafts["save"] = "unsent A"; second.drafts["save"] = "unsent B"
        first.focusedField = "save"
        XCTAssertEqual(first.drafts["save"], "unsent A"); XCTAssertEqual(second.drafts["save"], "unsent B")
        XCTAssertNil(second.focusedField)
    }

    func testTypographyInheritsUntilExplicitChildOverride() {
        var parent = SkeletonModifiers(); parent.fontSize = 11; parent.lineHeightMultiple = 15.0 / 11
        parent.numericVariant = .tabular; parent.letterSpacing = -0.2; parent.fontFamilies = ["Helvetica"]
        var child = SkeletonModifiers(); child.numericVariant = .proportional; child.letterSpacing = 0
        let resolved = child.inheritingTypography(parent)
        XCTAssertEqual(resolved.fontSize, 11); XCTAssertEqual(resolved.lineHeightMultiple, 15.0 / 11)
        XCTAssertEqual(resolved.fontFamilies, ["Helvetica"]); XCTAssertEqual(resolved.numericVariant, .proportional)
        XCTAssertEqual(resolved.letterSpacing, 0)
    }

    #if os(macOS)
    @MainActor
    func testNativeParagraphUses15PointLineBoxAtFontSize11AndProportionalFeature() async throws {
        var m = SkeletonModifiers()
        m.fontSize = 11; m.lineHeightMultiple = 15.0 / 11; m.letterSpacing = -0.3
        m.fontFamilies = ["Missing fixture font", "Helvetica"]
        m.numericVariant = .proportional; m.textDecoration = .underline
        let value = SkeletonNativeTextAttributes.attributed("123\n456", modifiers: m, color: .black)
        let attributes = value.attributes(at: 0, effectiveRange: nil)
        let paragraph = try XCTUnwrap(attributes[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(paragraph.minimumLineHeight, 15, accuracy: 0.001)
        XCTAssertEqual(paragraph.maximumLineHeight, 15, accuracy: 0.001)
        XCTAssertEqual(attributes[.kern] as? Double, -0.3)
        XCTAssertEqual(attributes[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
        let font = try XCTUnwrap(attributes[.font] as? NSFont)
        XCTAssertNotNil(font.fontDescriptor.object(forKey: .featureSettings))
        XCTAssertEqual(SkeletonNativeTypography.family(m.fontFamilies, size: 11), "Helvetica")
    }

    @MainActor
    func testNativePaddingStaysInsideDeclaredOuterBox() async throws {
        var m = SkeletonModifiers()
        m.width = 100; m.height = 40; m.paddingInsets = .init(top: 2, leading: 11, bottom: 7, trailing: 3)
        m.background = "#ff0000"; m.contentClip = true; m.cornerRadius = 4
        let renderer = ImageRenderer(content: Color.blue.applySkeletonModifiers(m))
        renderer.proposedSize = ProposedViewSize(width: 300, height: 200)
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 100); XCTAssertEqual(image.height, 40)
    }

    @MainActor
    func testBaselineLayoutIncludesAscentAndDescentOfDifferentChildren() async throws {
        let view = SkeletonLinearLayout(axis: .horizontal, spacing: 0, horizontal: .leading, vertical: .firstTextBaseline) {
            Color.red.frame(width: 20, height: 40).alignmentGuide(.firstTextBaseline) { _ in 10 }
            Color.blue.frame(width: 20, height: 30).alignmentGuide(.firstTextBaseline) { _ in 20 }
        }
        let renderer = ImageRenderer(content: view)
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 50, "20pt ascent + 30pt descent, not max child height")
    }

    @MainActor
    func testFlexGrowthDistributesRemainingSpaceByWeight() async throws {
        var first = SkeletonModifiers(); first.height = 20; first.flexGrow = 1
        var second = first; second.flexGrow = 3
        let view = SkeletonLinearLayout(axis: .horizontal, spacing: 0, horizontal: .leading, vertical: .top) {
            Color.red.applySkeletonModifiers(first)
            Color.blue.applySkeletonModifiers(second)
        }.frame(width: 100, height: 20)
        let red = try pixel(AnyView(view), x: 25, y: 30)
        let blue = try pixel(AnyView(view), x: 55, y: 30)
        XCTAssertGreaterThan(red.redComponent, 0.8)
        XCTAssertLessThan(blue.redComponent, 0.1)
        XCTAssertGreaterThan(blue.blueComponent, 0.8)
    }

    @MainActor
    private func pixel(_ view: AnyView, x: Int, y: Int) throws -> NSColor {
        let renderer = ImageRenderer(content: view.frame(width: 120, height: 60).background(Color.white))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 120); XCTAssertEqual(image.height, 60)
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    @MainActor
    func testCornerRadiusDoesNotClipUntilContentClipIsTrue() async throws {
        var m = SkeletonModifiers(); m.width = 60; m.height = 30; m.cornerRadius = 8
        let open = try pixel(AnyView(Color.blue.frame(width: 100, height: 30).applySkeletonModifiers(m)), x: 105, y: 30)
        m.contentClip = true
        let clipped = try pixel(AnyView(Color.blue.frame(width: 100, height: 30).applySkeletonModifiers(m)), x: 105, y: 30)
        XCTAssertLessThan(open.redComponent, 0.1); XCTAssertGreaterThan(open.blueComponent, 0.9)
        XCTAssertGreaterThan(clipped.redComponent, 0.9)
    }

    @MainActor
    func testMarkerAndZeroBlurSpreadPaintOutsideWithoutChangingLayoutSize() async throws {
        let reference = try pixel(AnyView(Color(skeletonHex: "#ff0000")!), x: 60, y: 30)
        var m = SkeletonModifiers(); m.width = 60; m.height = 30
        m.leadingMarker = .init(width: 2, insetTop: 4, insetBottom: 4, offset: -6, cornerRadius: 0, color: "#ff0000")
        let marker = try pixel(AnyView(Color.clear.applySkeletonModifiers(m)), x: 24, y: 30)
        XCTAssertEqual(marker.redComponent, reference.redComponent, accuracy: 0.01)
        XCTAssertEqual(marker.greenComponent, reference.greenComponent, accuracy: 0.01)
        m.leadingMarker = nil; m.shadowSpread = 4; m.shadowRadius = 0; m.shadowColor = "#ff0000"
        let shadow = try pixel(AnyView(Color.clear.applySkeletonModifiers(m)), x: 28, y: 30)
        XCTAssertEqual(shadow.redComponent, reference.redComponent, accuracy: 0.01)
        XCTAssertEqual(shadow.greenComponent, reference.greenComponent, accuracy: 0.01)
    }
    #endif
}

private extension SkeletonComponentMount {
    static func decodeFrom(_ value: ValueType?) throws -> SkeletonComponentMount {
        try SkeletonComponentInstance.decode(XCTUnwrap(value))
    }
}
