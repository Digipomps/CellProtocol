// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import CellBase
@testable import CellApple

final class SkeletonButtonResolutionTests: XCTestCase {
    func testDefaultRowResolutionRemainsBackwardCompatible() {
        let template = SkeletonButton(
            keypath: "fallback.action",
            label: "Fallback",
            url: "cell:///Fallback",
            payload: .string("fallback")
        )
        let row: ValueType = .object([
            "keypath": .string("row.action"),
            "label": .string("Row"),
            "url": .string("cell:///Row"),
            "payload": .string("row")
        ])

        let resolved = SkeletonButtonResolutionSupport.resolve(
            template: template,
            userInfoValue: row
        )

        XCTAssertEqual(resolved.keypath, "row.action")
        XCTAssertEqual(resolved.label, "Row")
        XCTAssertEqual(resolved.url, "cell:///Row")
        XCTAssertEqual(resolved.payload, .string("row"))
    }

    func testHostTransformRunsAfterRowResolutionAndReceivesTemplate() throws {
        let template = SkeletonButton(
            keypath: "host.open",
            label: "Open",
            url: "cell:///HostAdapter",
            payload: .object(["hostToken": .string("scene-a")])
        )
        let row: ValueType = .object([
            "keypath": .string("row.override"),
            "label": .string("Resolved label"),
            "url": .string("cell:///RowOverride"),
            "payload": .object(["hostToken": .string("attacker")])
        ])
        let transform = SkeletonButtonResolutionTransform { original, resolved in
            var preserved = original
            preserved.label = resolved.label
            return preserved
        }

        let resolved = SkeletonButtonResolutionSupport.resolve(
            template: template,
            userInfoValue: row,
            transform: transform
        )

        XCTAssertEqual(resolved.keypath, "host.open")
        XCTAssertEqual(resolved.label, "Resolved label")
        XCTAssertEqual(resolved.url, "cell:///HostAdapter")
        XCTAssertEqual(
            try resolved.payload?.jsonString(),
            try ValueType.object(["hostToken": .string("scene-a")]).jsonString()
        )
    }
}
