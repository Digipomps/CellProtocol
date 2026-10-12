// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import CellBase

final class BridgeSigningBackpressureCodecTests: XCTestCase {
    func testOrdinaryApplicationErrorObjectIsNotAProtocolRetry() {
        XCTAssertNil(BridgeSigningBackpressure.rejection(.object([
            "status": .string("error"), "reasonCode": .string("signing_rate_limited"),
            "retryAfterSeconds": .integer(60)])))
        XCTAssertNil(BridgeSigningBackpressure.rejection(.object([
            "status": .string("error"), "&bridgeRetry": .string("signing_before_effect.v1"),
            "reasonCode": .string("signing_rate_limited"), "retryAfterSeconds": .integer(-1)])))
    }
}
