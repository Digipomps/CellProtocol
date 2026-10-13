// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import CellBase
@testable import CellApple

/// WP-F (2026-09-19): native stakker tolker som web etter WP-B4 og som SwiftUI-stakken på main —
/// en Spacer tar ledig plass, lang tekst brytes i raden i stedet for å gå ut over kanten — og
/// layoutvarianter kan gi fast bredde eller skjule elementet.
final class SkeletonNativeLayoutRoundBTests: XCTestCase {
    @MainActor
    private func image<V: View>(_ view: V, width: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: width).background(Color.white))
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> NSColor {
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    private func square(_ hex: String) -> SkeletonElement {
        var modifiers = SkeletonModifiers()
        modifiers.width = 20
        modifiers.height = 20
        modifiers.background = hex
        return .VStack(SkeletonVStack(elements: [], spacing: 0, modifiers: modifiers))
    }

    @MainActor
    func testSpacerPushesTheTrailingElementToTheEdge() throws {
        let row = SkeletonElement.HStack(SkeletonHStack(
            elements: [square("#ff0000"), .Spacer(SkeletonSpacer()), square("#0000ff")], spacing: 0))
        let rendered = try image(SkeletonView(element: row).environmentObject(PortholeViewModel()), width: 200)
        XCTAssertEqual(rendered.width, 200)
        let left = try pixel(rendered, x: 10, y: 10)
        let middle = try pixel(rendered, x: 100, y: 10)
        let right = try pixel(rendered, x: 190, y: 10)
        XCTAssertGreaterThan(left.redComponent, 0.8)
        XCTAssertGreaterThan(right.blueComponent, 0.8, "The trailing square sits at the right edge")
        XCTAssertLessThan(right.redComponent, 0.2)
        XCTAssertGreaterThan(middle.greenComponent, 0.8, "White space between the two squares")
    }

    @MainActor
    func testLongTextWrapsInsideTheRowInsteadOfOverflowing() throws {
        let long = String(repeating: "Avtalen gir ti minutter på hovedscenen. ", count: 6)
        let row = SkeletonLinearLayout(axis: .horizontal, spacing: 8, horizontal: .leading, vertical: .top) {
            Color.red.frame(width: 20, height: 20)
            Text(long)
        }
        let rendered = try image(row, width: 200)
        XCTAssertEqual(rendered.width, 200)
        XCTAssertGreaterThan(rendered.height, 40, "The text wraps onto several lines within 200 pt")
        XCTAssertGreaterThan(try pixel(rendered, x: 10, y: 10).redComponent, 0.8, "The fixed square keeps its width")
    }

    func testLayoutVariantWidthAndHiddenApplyNatively() throws {
        var modifiers = SkeletonModifiers()
        modifiers.layoutVariants = [
            SkeletonLayoutVariant(maxAvailableWidth: 1099, hidden: true),
            SkeletonLayoutVariant(minAvailableWidth: 1100, width: 290)
        ]
        let wide = try SkeletonLayoutContext(availableWidth: 2000, availableHeight: 800, capabilities: [])
        let narrow = try SkeletonLayoutContext(availableWidth: 780, availableHeight: 800, capabilities: [])
        let (wideModifiers, wideVariant) = SkeletonNativeLayout.effective(modifiers, layout: wide, data: SkeletonRenderDataContext())
        XCTAssertEqual(wideModifiers.width, 290)
        XCTAssertNotEqual(wideVariant?.hidden, true)
        let (_, narrowVariant) = SkeletonNativeLayout.effective(modifiers, layout: narrow, data: SkeletonRenderDataContext())
        XCTAssertEqual(narrowVariant?.hidden, true)
    }
}
#endif
