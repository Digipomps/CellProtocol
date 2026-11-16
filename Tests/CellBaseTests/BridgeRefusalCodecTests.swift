// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import CellBase

/// Refusals travel as data with a reason and, when known, a wait; the client
/// still accepts the legacy `failure: …` text (Kjetil 2026-11-16).
final class BridgeRefusalCodecTests: XCTestCase {
    func testRefusalRoundTripsWithAndWithoutWait() {
        let timed = BridgeRefusal(reasonCode: CellSecurityReasonCode.bridgeQuarantined,
                                  message: "signingTemporarilyUnavailable", retryAfterSeconds: 240)
        XCTAssertEqual(BridgeRefusal.parse(timed.value), timed)
        let plain = BridgeRefusal(reasonCode: "denied", message: "no contract")
        XCTAssertEqual(BridgeRefusal.parse(plain.value), plain)
        guard case .object(let fields) = plain.value else { return XCTFail("Expected object") }
        XCTAssertNil(fields["retryAfterSeconds"])
        XCTAssertEqual(fields["status"], .string("error"))
    }

    func testLegacyFailureTextIsReadWithoutCrashing() {
        let refusal = BridgeRefusal.parse(.string("failure: Consume command get failed for get(state): denied"))
        XCTAssertEqual(refusal?.reasonCode, "failure")
        XCTAssertEqual(refusal?.message, "Consume command get failed for get(state): denied")
        XCTAssertNil(refusal?.retryAfterSeconds)
        XCTAssertEqual(refusal?.legacyFailureText, .string("failure: Consume command get failed for get(state): denied"))
    }

    func testOrdinaryValuesAreNotRefusals() {
        XCTAssertNil(BridgeRefusal.parse(.string("ok")))
        XCTAssertNil(BridgeRefusal.parse(.object(["status": .string("error"), "reasonCode": .string("x")])))
        XCTAssertNil(BridgeRefusal.parse(.integer(3)))
        XCTAssertNil(BridgeRefusal.parse(nil))
    }

    func testQuarantineRetryKeepsTheWireCodeOlderClientsRecognise() {
        let retry = BridgeSigningBackpressure(retryAfterSeconds: 200, cause: CellSecurityReasonCode.bridgeQuarantined)
        guard case .object(var fields) = retry.rejection else { return XCTFail("Expected rejection object") }
        XCTAssertEqual(fields["reasonCode"], .string(CellSecurityReasonCode.signingRateLimited))
        XCTAssertEqual(fields["cause"], .string(CellSecurityReasonCode.bridgeQuarantined))
        XCTAssertEqual(BridgeSigningBackpressure.rejection(retry.rejection), retry)
        XCTAssertEqual(BridgeRefusal.parse(retry.rejection)?.reasonCode, CellSecurityReasonCode.bridgeQuarantined)
        // An older sender without the cause field still decodes as a rate limit.
        fields.removeValue(forKey: "cause")
        XCTAssertEqual(BridgeSigningBackpressure.rejection(.object(fields)),
                       BridgeSigningBackpressure(retryAfterSeconds: 200))
    }

    func testQuarantineReportsTheTimeUntilItEnds() async {
        let controller = CellSecurityContainmentController()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let none = await controller.quarantineRetryAfter(resourceKind: "bridge", identifier: "b1", now: now)
        XCTAssertNil(none)
        await controller.applyManualAction(CellSecurityContainmentAction(
            kind: .quarantineBridge, reasonCode: CellSecurityReasonCode.bridgeQuarantined,
            resource: CellSecurityResource(kind: "bridge", identifier: "b1", action: "sign"),
            requiredAction: "wait_for_quarantine_or_reauthenticate", automatic: true,
            expiresAt: now.addingTimeInterval(300)), now: now)
        let remaining = await controller.quarantineRetryAfter(resourceKind: "bridge", identifier: "b1",
                                                              now: now.addingTimeInterval(60))
        XCTAssertEqual(remaining ?? 0, 240, accuracy: 0.001)
        let after = await controller.quarantineRetryAfter(resourceKind: "bridge", identifier: "b1",
                                                          now: now.addingTimeInterval(301))
        XCTAssertNil(after)
    }
}
