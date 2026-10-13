// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import CellBase

final class BridgeSigningBackpressureCodecTests: XCTestCase {
    func testRetryMessageIsNeutralAndDoesNotControlDecoding() {
        let retry = BridgeSigningBackpressure(retryAfterSeconds: 12)
        guard case .object(var fields) = retry.rejection else { return XCTFail("Expected rejection object") }
        XCTAssertEqual(fields["message"], .string("signingTemporarilyUnavailable"))
        XCTAssertEqual(BridgeSigningBackpressure.rejection(retry.rejection), retry)
        fields["message"] = .string("legacy or translated message")
        XCTAssertEqual(BridgeSigningBackpressure.rejection(.object(fields)), retry)
    }

    func testOrdinaryApplicationErrorObjectIsNotAProtocolRetry() {
        XCTAssertNil(BridgeSigningBackpressure.rejection(.object([
            "status": .string("error"), "reasonCode": .string("signing_rate_limited"),
            "retryAfterSeconds": .integer(60)])))
        XCTAssertNil(BridgeSigningBackpressure.rejection(.object([
            "status": .string("error"), "&bridgeRetry": .string("signing_before_effect.v1"),
            "reasonCode": .string("signing_rate_limited"), "retryAfterSeconds": .integer(-1)])))
    }
}
