// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class BridgeInboundPayloadValidatorTests: XCTestCase {
    func testAcceptsBoundedJSONAndIgnoresContainersInsideStrings() throws {
        let data = Data(#"{"payload":"[[{{\"}}]]"}"#.utf8)
        XCTAssertNoThrow(try BridgeInboundPayloadValidator().validate(data))
    }

    func testRejectsPayloadAboveByteLimit() {
        let validator = BridgeInboundPayloadValidator(maximumBytes: 8)
        let data = Data(repeating: 0x20, count: 9)

        XCTAssertThrowsError(try validator.validate(data)) { error in
            XCTAssertEqual(
                error as? BridgeInboundPayloadError,
                .tooLarge(actualBytes: 9, maximumBytes: 8)
            )
        }
    }

    func testRejectsPayloadAboveNestingLimit() {
        let validator = BridgeInboundPayloadValidator(maximumNestingDepth: 4)
        let data = Data("[[[[[]]]]]".utf8)

        XCTAssertThrowsError(try validator.validate(data)) { error in
            XCTAssertEqual(error as? BridgeInboundPayloadError, .tooDeep(maximumDepth: 4))
        }
    }

    func testRejectsMismatchedOrUnterminatedStructure() {
        let validator = BridgeInboundPayloadValidator()

        XCTAssertThrowsError(try validator.validate(Data("{]".utf8))) { error in
            XCTAssertEqual(error as? BridgeInboundPayloadError, .malformedStructure)
        }
        XCTAssertThrowsError(try validator.validate(Data("{\"payload\":\"unterminated".utf8))) { error in
            XCTAssertEqual(error as? BridgeInboundPayloadError, .malformedStructure)
        }
    }
}
