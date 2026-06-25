// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import PurposeInterestBenchmarkSupport

final class ConferenceSwarmSignalMatchingTests: XCTestCase {
    func testConferenceSwarmDatasetContainsPIIButMatchingUsesOnlyMinimizedContext() {
        XCTAssertGreaterThanOrEqual(PerspectiveMatchingScenarioSupport.conferenceSwarmEntities.count, 6)
        XCTAssertGreaterThanOrEqual(PerspectiveMatchingScenarioSupport.conferenceSwarmOpportunities.count, 7)
        XCTAssertGreaterThanOrEqual(PerspectiveMatchingScenarioSupport.conferenceSwarmCases.count, 6)
        XCTAssertEqual(
            PerspectiveMatchingScenarioSupport.conferenceSwarmCapabilityGrants.count,
            PerspectiveMatchingScenarioSupport.conferenceSwarmCases.count
        )

        let privateKeys = Set(
            PerspectiveMatchingScenarioSupport.conferenceSwarmEntities.flatMap { entity in
                entity.privateVariables.keys
            }
        )
        XCTAssertTrue(privateKeys.contains("email"))
        XCTAssertTrue(privateKeys.contains("phone"))
        XCTAssertTrue(privateKeys.contains("fullName"))

        let unsafeOpportunity = PerspectiveMatchingScenarioSupport.conferenceSwarmOpportunities.first {
            $0.opportunityID == "opportunity.swarm.sponsor-lead-capture.unsafe"
        }
        XCTAssertNotNil(unsafeOpportunity)
        XCTAssertTrue(unsafeOpportunity?.requirements.contains { $0.key == "email" } ?? false)
    }

    func testConferenceSwarmRanksExpectedMatchesAfterLayeredPrivacyFiltering() async throws {
        let summary = try await PerspectiveMatchingScenarioSupport.evaluateConferenceSwarm(iterations: 2)

        XCTAssertEqual(summary.schemaVersion, "1.0")
        XCTAssertEqual(summary.caseCount, PerspectiveMatchingScenarioSupport.conferenceSwarmCases.count)
        XCTAssertEqual(summary.top1Correct, summary.caseCount)
        XCTAssertEqual(summary.top3Correct, summary.caseCount)
        XCTAssertEqual(summary.meanReciprocalRank, 1.0, accuracy: 0.0001)
        XCTAssertGreaterThan(summary.totalElapsedNanoseconds, 0)
        XCTAssertGreaterThan(summary.averageNanosecondsPerCase, 0.0)
        XCTAssertTrue(summary.capabilityRejectedOpportunityIDs.isEmpty)

        for result in summary.caseResults {
            XCTAssertEqual(result.selectedOpportunityID, result.expectedOpportunityID, result.caseID)
            XCTAssertNotNil(result.authorizationGrantID, result.caseID)
            XCTAssertEqual(result.finalRankOfExpected, 1, result.caseID)
            XCTAssertEqual(result.compositionStatus, .satisfied, result.caseID)
            XCTAssertEqual(result.compositionScore, 1.0, accuracy: 0.0001, result.caseID)
            XCTAssertGreaterThan(result.selectedScore, 0.0, result.caseID)
            XCTAssertGreaterThan(result.rawRankingCount, 0, result.caseID)
            XCTAssertGreaterThan(result.acceptedRankingCount, 0, result.caseID)
            XCTAssertFalse(result.matchedInterestRefs.isEmpty, result.caseID)
        }
    }

    func testConferenceSwarmRejectsUnsafeRawLeadCaptureEvenWhenItScoresHighest() async throws {
        let testCase = try XCTUnwrap(
            PerspectiveMatchingScenarioSupport.conferenceSwarmCases.first {
                $0.caseID == "swarm.hostedbuyer-security"
            }
        )

        let result = try await PerspectiveMatchingScenarioSupport.resolveConferenceSwarmCase(testCase)
        let unsafeRejection = try XCTUnwrap(
            result.rejectedCandidates.first {
                $0.opportunityID == "opportunity.swarm.sponsor-lead-capture.unsafe"
            }
        )
        let violationKeys = Set(unsafeRejection.privacyViolations.map(\.key))

        XCTAssertEqual(result.rawTopOpportunityID, "opportunity.swarm.sponsor-lead-capture.unsafe")
        XCTAssertEqual(result.selectedOpportunityID, "opportunity.swarm.vendor-security.enterprise")
        XCTAssertTrue(unsafeRejection.reasons.contains(.privacyRequirementFailed))
        XCTAssertTrue(violationKeys.contains("email"))
        XCTAssertTrue(violationKeys.contains("phone"))
        XCTAssertNil(result.carriedLocalVariables["email"])
        XCTAssertNil(result.carriedLocalVariables["phone"])
        XCTAssertNil(result.carriedLocalVariables["legalName"])
    }

    func testConferenceSwarmRequiresActiveCapabilityGrant() async throws {
        let testCase = try XCTUnwrap(
            PerspectiveMatchingScenarioSupport.conferenceSwarmCases.first {
                $0.caseID == "swarm.hostedbuyer-security"
            }
        )
        let grantsWithoutExpected = PerspectiveMatchingScenarioSupport.conferenceSwarmCapabilityGrants.filter {
            $0.opportunityID != testCase.expectedOpportunityID
        }

        let result = try await PerspectiveMatchingScenarioSupport.resolveConferenceSwarmCase(
            testCase,
            grants: grantsWithoutExpected
        )
        let rejectedExpected = try XCTUnwrap(
            result.rejectedCandidates.first {
                $0.opportunityID == testCase.expectedOpportunityID
            }
        )

        XCTAssertNil(result.selectedOpportunityID)
        XCTAssertNil(result.authorizationGrantID)
        XCTAssertEqual(result.compositionStatus, .unsatisfied)
        XCTAssertTrue(rejectedExpected.reasons.contains(.capabilityRequirementFailed))
    }

    func testConferenceSwarmRejectsExpiredCapabilityGrant() async throws {
        let testCase = try XCTUnwrap(
            PerspectiveMatchingScenarioSupport.conferenceSwarmCases.first {
                $0.caseID == "swarm.hostedbuyer-security"
            }
        )
        let currentGrant = try XCTUnwrap(
            PerspectiveMatchingScenarioSupport.conferenceSwarmCapabilityGrants.first {
                $0.opportunityID == testCase.expectedOpportunityID
            }
        )
        let expiredGrant = ConferenceSwarmCapabilityGrant(
            grantID: currentGrant.grantID,
            granteeEntityRef: currentGrant.granteeEntityRef,
            opportunityID: currentGrant.opportunityID,
            capabilities: currentGrant.capabilities,
            issuedAt: PerspectiveMatchingScenarioSupport.fixtureTimestamp - 3_600,
            expiresAt: PerspectiveMatchingScenarioSupport.fixtureTimestamp - 1
        )
        let grants = PerspectiveMatchingScenarioSupport.conferenceSwarmCapabilityGrants
            .filter { $0.grantID != currentGrant.grantID } + [expiredGrant]

        let result = try await PerspectiveMatchingScenarioSupport.resolveConferenceSwarmCase(
            testCase,
            grants: grants
        )
        let rejectedExpected = try XCTUnwrap(
            result.rejectedCandidates.first {
                $0.opportunityID == testCase.expectedOpportunityID
            }
        )

        XCTAssertNil(result.selectedOpportunityID)
        XCTAssertNil(result.authorizationGrantID)
        XCTAssertTrue(rejectedExpected.reasons.contains(.capabilityRequirementFailed))
    }

    func testConferenceSwarmDoesNotCarryOrDiscloseForbiddenPIIKeys() async throws {
        let forbiddenKeys = PerspectiveMatchingScenarioSupport.conferenceSwarmForbiddenVariableKeys

        for testCase in PerspectiveMatchingScenarioSupport.conferenceSwarmCases {
            let result = try await PerspectiveMatchingScenarioSupport.resolveConferenceSwarmCase(testCase)
            let selectedOpportunity = try XCTUnwrap(
                PerspectiveMatchingScenarioSupport.conferenceSwarmOpportunities.first {
                    $0.opportunityID == result.selectedOpportunityID
                },
                testCase.caseID
            )
            let selectedRequiredRequesterKeys = Set(
                selectedOpportunity.requirements
                    .filter { $0.scope == .requester }
                    .map(\.key)
            )
            let disclosedKeys = Set(result.disclosedVariableKeys)

            XCTAssertTrue(Set(result.carriedLocalVariables.keys).isDisjoint(with: forbiddenKeys), testCase.caseID)
            XCTAssertTrue(disclosedKeys.isDisjoint(with: forbiddenKeys), testCase.caseID)
            XCTAssertEqual(disclosedKeys, selectedRequiredRequesterKeys, testCase.caseID)
            XCTAssertTrue(disclosedKeys.isSubset(of: Set(selectedOpportunity.allowedDisclosureKeys)), testCase.caseID)
        }
    }

    func testConferenceSwarmResultsAreDeterministicApartFromTiming() async throws {
        let first = try await PerspectiveMatchingScenarioSupport.evaluateConferenceSwarm(iterations: 1)
        let second = try await PerspectiveMatchingScenarioSupport.evaluateConferenceSwarm(iterations: 1)

        XCTAssertEqual(first.caseResults, second.caseResults)
        XCTAssertEqual(first.top1Correct, second.top1Correct)
        XCTAssertEqual(first.top3Correct, second.top3Correct)
        XCTAssertEqual(first.meanReciprocalRank, second.meanReciprocalRank)
        XCTAssertGreaterThan(first.totalElapsedNanoseconds, 0)
        XCTAssertGreaterThan(second.totalElapsedNanoseconds, 0)
    }

    func testConferenceSwarmReportRendersMarkdownAndJSON() async throws {
        let markdown = try await PerspectiveMatchingScenarioSupport.buildConferenceSwarmReport(
            format: .markdown,
            iterations: 1
        )
        let json = try await PerspectiveMatchingScenarioSupport.buildConferenceSwarmReport(
            format: .json,
            iterations: 1
        )

        XCTAssertTrue(markdown.contains("# Conference Swarm Signal Matching"))
        XCTAssertTrue(markdown.contains("Privacy violations rejected"))
        XCTAssertTrue(markdown.contains("Capability-rejected opportunities"))
        XCTAssertTrue(markdown.contains("grant.swarm.hostedbuyer-security.vendor"))
        XCTAssertTrue(json.contains("\"schemaVersion\""))
        XCTAssertTrue(json.contains("\"authorizationGrantID\""))
        XCTAssertTrue(json.contains("\"capabilityRejectedOpportunityIDs\""))
    }
}
