import XCTest
@testable import CellApple

final class NearbyDisclosurePolicyTests: XCTestCase {
    func testStrictPolicyDisclosesNothing() throws {
        let policy = NearbyDisclosurePolicy.strict

        try policy.validate()
        XCTAssertFalse(policy.beaconEnabled)
        XCTAssertFalse(policy.isActive(at: 1_000))
        XCTAssertNil(policy.beacon)
        XCTAssertEqual(policy.probeMode, .off)
        XCTAssertTrue(policy.beaconPurposeRefs.isEmpty)
        XCTAssertTrue(policy.beaconInterestRefs.isEmpty)
    }

    func testApprovedPolicyDefaultsToEightHoursAndExpires() throws {
        let policy = NearbyDisclosurePolicy.approved(
            entityKind: .person,
            purposeRefs: ["purpose://climate"],
            interestRefs: [],
            now: 1_000
        )

        try policy.validate(activePerspectiveRefs: ["purpose://climate"])
        XCTAssertTrue(policy.isActive(at: 1_001))
        XCTAssertFalse(policy.isActive(at: 1_000 + 8 * 60 * 60))
        XCTAssertEqual(policy.expiresAt, 1_000 + 8 * 60 * 60)
    }

    func testValidationRejectsReferencesOutsideActivePerspective() {
        let policy = NearbyDisclosurePolicy.approved(
            entityKind: .person,
            purposeRefs: ["purpose://not-active"],
            interestRefs: [],
            now: 1_000
        )

        XCTAssertThrowsError(try policy.validate(activePerspectiveRefs: ["purpose://active"])) { error in
            XCTAssertEqual(
                error as? NearbyDisclosurePolicy.ValidationError,
                .referenceNotActive(["purpose://not-active"])
            )
        }
    }

    func testRedactedSummaryContainsCountsButNotReferences() {
        let policy = NearbyDisclosurePolicy.approved(
            entityKind: .person,
            purposeRefs: ["purpose://secret-purpose"],
            interestRefs: ["interest://secret-interest"],
            now: 1_000
        )

        let summary = policy.redactedSummary()

        XCTAssertTrue(summary.contains("purposeCount=1"))
        XCTAssertTrue(summary.contains("interestCount=1"))
        XCTAssertFalse(summary.contains("secret-purpose"))
        XCTAssertFalse(summary.contains("secret-interest"))
    }
}
