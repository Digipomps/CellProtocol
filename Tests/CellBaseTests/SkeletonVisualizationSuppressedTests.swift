// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import SwiftUI
import CellBase
@testable import CellApple

/// PDD forskningsdata-verktoy WP8 (test.fd.skjult-vises, CellApple half). Same
/// contract and cases as CellScaffold scripts/skeleton-suppressed-bucket.test.js.
final class SkeletonVisualizationSuppressedTests: XCTestCase {
    private func row(_ label: String, _ value: Int) -> ValueType {
        .object(["id": .string(label), "label": .string(label), "value": .integer(value)])
    }

    private func suppressed(_ label: String, _ text: String? = nil) -> ValueType {
        var object: Object = ["id": .string(label), "label": .string(label), "value": .null, "suppressed": .bool(true)]
        if let text { object["suppressedLabel"] = .string(text) }
        return .object(object)
    }

    private var weeks: ValueType {
        .object(["points": .list([
            row("Uke 42", 6), row("Uke 43", 9), suppressed("Uke 44", "færre enn 5"), row("Uke 45", 12), row("Uke 46", 7),
        ])])
    }

    func testSuppressedBucketKeepsItsPlaceWithLabel() {
        let points = visualizationChartPoints(from: weeks)
        XCTAssertEqual(points.map(\.label), ["Uke 42", "Uke 43", "Uke 44", "Uke 45", "Uke 46"])
        XCTAssertEqual(points.map(\.suppressed), [false, false, true, false, false])
        XCTAssertEqual(points[2].suppressedLabel, "færre enn 5")
        XCTAssertEqual(points[2].value, 0)
    }

    func testDefaultLabelFromSpecThenFallback() {
        let fromSpec = visualizationChartPoints(from: .object([
            "suppressedLabel": .string("færre enn k"), "points": .list([suppressed("Uke 1")]),
        ]))
        XCTAssertEqual(fromSpec.first?.suppressedLabel, "færre enn k")
        let fallback = visualizationChartPoints(from: .object(["points": .list([suppressed("Uke 1")])]))
        XCTAssertEqual(fallback.first?.suppressedLabel, visualizationDefaultSuppressedLabel)
    }

    func testLineBreaksAtSuppressedBucket() {
        let points = visualizationChartPoints(from: weeks)
        XCTAssertEqual(points.count, 5)
        guard points.count == 5 else { return }
        let positions = points.indices.map { CGPoint(x: Double($0) * 10, y: 0) }
        let segments = visualizationLineSegments(points: points, positions: positions)
        XCTAssertEqual(segments.map(\.count), [2, 2])
        XCTAssertFalse(segments.joined().contains(positions[2]))
    }

    func testSeriesWithoutSuppressedBucketIsOneSegment() {
        let points = visualizationChartPoints(from: .object(["points": .list([row("a", 1), row("b", 2), row("c", 3)])]))
        XCTAssertEqual(points.filter(\.suppressed).count, 0)
        let positions = points.indices.map { CGPoint(x: Double($0), y: 0) }
        XCTAssertEqual(visualizationLineSegments(points: points, positions: positions).map(\.count), [3])
    }

    func testRowsKeyStillWorks() {
        let points = visualizationChartPoints(from: .object(["rows": .list([row("a", 1), suppressed("b")])]))
        XCTAssertEqual(points.map(\.suppressed), [false, true])
    }

    func testRowWithNullValueAndNoFlagIsStillDropped() {
        let points = visualizationChartPoints(from: .object(["points": .list([
            .object(["label": .string("x"), "value": .null]), row("y", 1),
        ])]))
        XCTAssertEqual(points.map(\.label), ["y"])
    }
}
