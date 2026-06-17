// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#endif
import HavenPerspectiveSchemas
import CellBase

public enum PerspectiveScenarioPhase: String, CaseIterable, Codable {
    case pre
    case during
    case post
}

public struct PurposeScenarioProfile: Sendable {
    public var purposeId: String
    public var interestWeights: [String: Double]

    public init(purposeId: String, interestWeights: [String: Double]) {
        self.purposeId = purposeId
        self.interestWeights = interestWeights
    }
}

public enum ScenarioRankingMethod: String, Codable, CaseIterable, Sendable {
    case weightedRaw
    case weightedSignal
    case cosine
}

public enum ScenarioWeightTuningOperation: String, Codable, Sendable {
    case set
    case add
    case multiply
    case remove
}

public struct ScenarioWeightTuningAdjustment: Codable, Sendable {
    public var purposeId: String
    public var interestId: String
    public var operation: ScenarioWeightTuningOperation
    public var value: Double?
    public var reason: String?

    public init(
        purposeId: String,
        interestId: String,
        operation: ScenarioWeightTuningOperation,
        value: Double? = nil,
        reason: String? = nil
    ) {
        self.purposeId = purposeId
        self.interestId = interestId
        self.operation = operation
        self.value = value
        self.reason = reason
    }
}

public struct ScenarioWeightTuningConfig: Codable, Sendable {
    public var tuningId: String
    public var description: String
    public var adjustments: [ScenarioWeightTuningAdjustment]

    public init(
        tuningId: String,
        description: String,
        adjustments: [ScenarioWeightTuningAdjustment]
    ) {
        self.tuningId = tuningId
        self.description = description
        self.adjustments = adjustments
    }
}

public struct ScenarioRankedPurpose: Codable, Sendable {
    public var purposeId: String
    public var score: Double
    public var matchedInterestRefs: [String]

    public init(purposeId: String, score: Double, matchedInterestRefs: [String]) {
        self.purposeId = purposeId
        self.score = score
        self.matchedInterestRefs = matchedInterestRefs
    }
}

public struct ScenarioEvaluationCaseResult: Codable, Sendable {
    public var caseID: String
    public var expectedPurposeID: String
    public var topPurposeID: String?
    public var topScore: Double
    public var top3ContainsExpected: Bool
    public var reciprocalRank: Double

    public init(
        caseID: String,
        expectedPurposeID: String,
        topPurposeID: String?,
        topScore: Double,
        top3ContainsExpected: Bool,
        reciprocalRank: Double
    ) {
        self.caseID = caseID
        self.expectedPurposeID = expectedPurposeID
        self.topPurposeID = topPurposeID
        self.topScore = topScore
        self.top3ContainsExpected = top3ContainsExpected
        self.reciprocalRank = reciprocalRank
    }
}

public struct ScenarioEvaluationSummary: Codable, Sendable {
    public var method: ScenarioRankingMethod
    public var totalCases: Int
    public var top1Correct: Int
    public var top3Correct: Int
    public var meanReciprocalRank: Double
    public var caseResults: [ScenarioEvaluationCaseResult]

    public init(
        method: ScenarioRankingMethod,
        totalCases: Int,
        top1Correct: Int,
        top3Correct: Int,
        meanReciprocalRank: Double,
        caseResults: [ScenarioEvaluationCaseResult]
    ) {
        self.method = method
        self.totalCases = totalCases
        self.top1Correct = top1Correct
        self.top3Correct = top3Correct
        self.meanReciprocalRank = meanReciprocalRank
        self.caseResults = caseResults
    }
}

public enum ScenarioChallengeExpectation: Sendable {
    case methodSpecificTopPurpose([ScenarioRankingMethod: String])
    case noConfidentMatch
}

public struct ScenarioChallengeCase: Sendable {
    public var caseID: String
    public var interests: [String]
    public var expectation: ScenarioChallengeExpectation

    public init(caseID: String, interests: [String], expectation: ScenarioChallengeExpectation) {
        self.caseID = caseID
        self.interests = interests
        self.expectation = expectation
    }
}

public struct ScenarioChallengeCaseResult: Codable, Sendable {
    public var caseID: String
    public var method: ScenarioRankingMethod
    public var expectedPurposeID: String?
    public var expectedConfidentMatch: Bool
    public var topPurposeID: String?
    public var topScore: Double
    public var confidentTopPurposeID: String?
    public var matchedInterestRefs: [String]
    public var passed: Bool

    public init(
        caseID: String,
        method: ScenarioRankingMethod,
        expectedPurposeID: String?,
        expectedConfidentMatch: Bool,
        topPurposeID: String?,
        topScore: Double,
        confidentTopPurposeID: String?,
        matchedInterestRefs: [String],
        passed: Bool
    ) {
        self.caseID = caseID
        self.method = method
        self.expectedPurposeID = expectedPurposeID
        self.expectedConfidentMatch = expectedConfidentMatch
        self.topPurposeID = topPurposeID
        self.topScore = topScore
        self.confidentTopPurposeID = confidentTopPurposeID
        self.matchedInterestRefs = matchedInterestRefs
        self.passed = passed
    }
}

public struct ScenarioChallengeMethodSummary: Codable, Sendable {
    public var method: ScenarioRankingMethod
    public var confidenceFloor: Double
    public var caseResults: [ScenarioChallengeCaseResult]

    public init(method: ScenarioRankingMethod, confidenceFloor: Double, caseResults: [ScenarioChallengeCaseResult]) {
        self.method = method
        self.confidenceFloor = confidenceFloor
        self.caseResults = caseResults
    }
}

public struct ScenarioChallengeSummary: Codable, Sendable {
    public var methods: [ScenarioChallengeMethodSummary]
    public var disagreementCaseIDs: [String]

    public init(methods: [ScenarioChallengeMethodSummary], disagreementCaseIDs: [String]) {
        self.methods = methods
        self.disagreementCaseIDs = disagreementCaseIDs
    }
}

public struct ScenarioTuningCaseDelta: Codable, Sendable {
    public var caseID: String
    public var method: ScenarioRankingMethod
    public var expectedPurposeID: String
    public var globalTopPurposeID: String?
    public var tunedTopPurposeID: String?
    public var globalTopScore: Double
    public var tunedTopScore: Double
    public var topChanged: Bool

    public init(
        caseID: String,
        method: ScenarioRankingMethod,
        expectedPurposeID: String,
        globalTopPurposeID: String?,
        tunedTopPurposeID: String?,
        globalTopScore: Double,
        tunedTopScore: Double,
        topChanged: Bool
    ) {
        self.caseID = caseID
        self.method = method
        self.expectedPurposeID = expectedPurposeID
        self.globalTopPurposeID = globalTopPurposeID
        self.tunedTopPurposeID = tunedTopPurposeID
        self.globalTopScore = globalTopScore
        self.tunedTopScore = tunedTopScore
        self.topChanged = topChanged
    }
}

public struct ScenarioTuningSummary: Codable, Sendable {
    public var tuningId: String
    public var description: String
    public var adjustmentCount: Int
    public var tunedCurated: [ScenarioEvaluationSummary]
    public var caseDeltas: [ScenarioTuningCaseDelta]

    public init(
        tuningId: String,
        description: String,
        adjustmentCount: Int,
        tunedCurated: [ScenarioEvaluationSummary],
        caseDeltas: [ScenarioTuningCaseDelta]
    ) {
        self.tuningId = tuningId
        self.description = description
        self.adjustmentCount = adjustmentCount
        self.tunedCurated = tunedCurated
        self.caseDeltas = caseDeltas
    }
}

public struct ScenarioBenchmarkArtifact: Codable, Sendable {
    public var schemaVersion: String
    public var curated: [ScenarioEvaluationSummary]
    public var challenge: ScenarioChallengeSummary
    public var tuning: ScenarioTuningSummary?

    public init(
        schemaVersion: String,
        curated: [ScenarioEvaluationSummary],
        challenge: ScenarioChallengeSummary,
        tuning: ScenarioTuningSummary? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.curated = curated
        self.challenge = challenge
        self.tuning = tuning
    }
}

public struct ScenarioRuntimeMethodMeasurement: Codable, Sendable {
    public var method: ScenarioRankingMethod
    public var iterations: Int
    public var caseCount: Int
    public var rankingCount: Int
    public var totalElapsedNanoseconds: UInt64
    public var averageNanosecondsPerCase: Double
    public var rssBeforeBytes: UInt64?
    public var rssAfterBytes: UInt64?
    public var rssDeltaBytes: Int64?

    public init(
        method: ScenarioRankingMethod,
        iterations: Int,
        caseCount: Int,
        rankingCount: Int,
        totalElapsedNanoseconds: UInt64,
        averageNanosecondsPerCase: Double,
        rssBeforeBytes: UInt64?,
        rssAfterBytes: UInt64?,
        rssDeltaBytes: Int64?
    ) {
        self.method = method
        self.iterations = iterations
        self.caseCount = caseCount
        self.rankingCount = rankingCount
        self.totalElapsedNanoseconds = totalElapsedNanoseconds
        self.averageNanosecondsPerCase = averageNanosecondsPerCase
        self.rssBeforeBytes = rssBeforeBytes
        self.rssAfterBytes = rssAfterBytes
        self.rssDeltaBytes = rssDeltaBytes
    }
}

public struct ScenarioRuntimeComparisonArtifact: Codable, Sendable {
    public var schemaVersion: String
    public var notes: [String]
    public var measurements: [ScenarioRuntimeMethodMeasurement]

    public init(
        schemaVersion: String,
        notes: [String],
        measurements: [ScenarioRuntimeMethodMeasurement]
    ) {
        self.schemaVersion = schemaVersion
        self.notes = notes
        self.measurements = measurements
    }
}

public struct ConferenceScenarioTextCase: Codable, Sendable {
    public var caseID: String
    public var description: String
    public var expectedPurposeID: String
    public var interests: [String]
    public var notes: [String]

    public init(
        caseID: String,
        description: String,
        expectedPurposeID: String,
        interests: [String],
        notes: [String] = []
    ) {
        self.caseID = caseID
        self.description = description
        self.expectedPurposeID = expectedPurposeID
        self.interests = interests
        self.notes = notes
    }
}

public struct ConferenceLayeredCandidate: Codable, Sendable {
    public var candidateID: String
    public var interestID: String
    public var purposeID: String
    public var requiredVariables: [String: String]

    public init(
        candidateID: String,
        interestID: String,
        purposeID: String,
        requiredVariables: [String: String]
    ) {
        self.candidateID = candidateID
        self.interestID = interestID
        self.purposeID = purposeID
        self.requiredVariables = requiredVariables
    }
}

public struct ConferenceLayeredScenario: Codable, Sendable {
    public var caseID: String
    public var description: String
    public var startInterestIDs: [String]
    public var firstLayerPurposeID: String
    public var localVariables: [String: String]
    public var candidates: [ConferenceLayeredCandidate]
    public var expectedCandidateID: String
    public var expectedPurposeID: String

    public init(
        caseID: String,
        description: String,
        startInterestIDs: [String],
        firstLayerPurposeID: String,
        localVariables: [String: String],
        candidates: [ConferenceLayeredCandidate],
        expectedCandidateID: String,
        expectedPurposeID: String
    ) {
        self.caseID = caseID
        self.description = description
        self.startInterestIDs = startInterestIDs
        self.firstLayerPurposeID = firstLayerPurposeID
        self.localVariables = localVariables
        self.candidates = candidates
        self.expectedCandidateID = expectedCandidateID
        self.expectedPurposeID = expectedPurposeID
    }
}

public struct ConferenceLayeredScenarioResult: Codable, Sendable {
    public var caseID: String
    public var firstLayerPurposeID: String?
    public var selectedCandidateID: String?
    public var selectedPurposeID: String?
    public var carriedLocalVariables: [String: String]
    public var layer1HitCount: Int
    public var layer2HitCount: Int
    public var layer3HitCount: Int

    public init(
        caseID: String,
        firstLayerPurposeID: String?,
        selectedCandidateID: String?,
        selectedPurposeID: String?,
        carriedLocalVariables: [String: String],
        layer1HitCount: Int,
        layer2HitCount: Int,
        layer3HitCount: Int
    ) {
        self.caseID = caseID
        self.firstLayerPurposeID = firstLayerPurposeID
        self.selectedCandidateID = selectedCandidateID
        self.selectedPurposeID = selectedPurposeID
        self.carriedLocalVariables = carriedLocalVariables
        self.layer1HitCount = layer1HitCount
        self.layer2HitCount = layer2HitCount
        self.layer3HitCount = layer3HitCount
    }
}

public enum ScenarioBenchmarkReportFormat: String, CaseIterable {
    case json
    case markdown
}

public enum PerspectiveMatchingScenarioSupport {
    public static let fixtureTimestamp: TimeInterval = 1_800_000_000.0
    public static let mandatoryPurposeIDs: Set<String> = [
        "purpose.human-equal-worth",
        "purpose.net-positive-contribution"
    ]

    public static let exampleNames: [String] = [
        "conference-ai-networking.json",
        "restaurant-team-dinner.json",
        "work-hiring-and-collaboration.json",
        "home-weekend-recovery.json",
        "family-care-coordination.json"
    ]

    private static let stableBenchmarkMethods: [ScenarioRankingMethod] = [.weightedRaw, .cosine]

    public static let profiles: [PurposeScenarioProfile] = [
        PurposeScenarioProfile(
            purposeId: "purpose.network",
            interestWeights: [
                "interest.ai": 0.45,
                "interest.design": 0.35,
                "interest.peer-meetings": 0.95,
                "interest.hallway-conversations": 0.80,
                "interest.followup": 0.55
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.learn",
            interestWeights: [
                "interest.ai": 0.75,
                "interest.education": 0.85,
                "interest.workshop-participation": 0.90,
                "interest.note-taking": 0.60,
                "interest.design": 0.45
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.collaborate",
            interestWeights: [
                "interest.shared-projects": 0.95,
                "interest.followup": 0.85,
                "interest.problem-solving": 0.90,
                "interest.team-fit": 0.75,
                "interest.design": 0.35
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.buy",
            interestWeights: [
                "interest.local-food": 0.80,
                "interest.budget": 0.80,
                "interest.dietary-safety": 0.95,
                "interest.reservation-timing": 0.60
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.discuss",
            interestWeights: [
                "interest.conversation": 0.95,
                "interest.hospitality": 0.70,
                "interest.team-bonding": 0.80,
                "interest.family-time": 0.45
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.share",
            interestWeights: [
                "interest.recommendation": 0.85,
                "interest.feedback": 0.70,
                "interest.documentation": 0.75,
                "interest.onboarding": 0.60,
                "interest.local-food": 0.40
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.hire",
            interestWeights: [
                "interest.design": 0.55,
                "interest.security": 0.65,
                "interest.team-fit": 0.80,
                "interest.portfolio-review": 0.95,
                "interest.problem-solving": 0.30
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.home.recover-and-recreate",
            interestWeights: [
                "interest.health": 0.85,
                "interest.rest": 0.95,
                "interest.outdoors": 0.70,
                "interest.low-effort-planning": 0.80
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.home.be-present",
            interestWeights: [
                "interest.family-time": 0.90,
                "interest.meal-at-home": 0.80,
                "interest.outdoors": 0.50,
                "interest.health": 0.45
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.home.reflect-and-reset",
            interestWeights: [
                "interest.household-rhythm": 0.95,
                "interest.next-week-planning": 0.85,
                "interest.health": 0.70,
                "interest.documentation": 0.30
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.family.coordinate-care",
            interestWeights: [
                "interest.family-time": 0.45,
                "interest.calendar-coordination": 0.95,
                "interest.health": 0.75,
                "interest.children": 0.80,
                "interest.school-followup": 0.55
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.family.share-time",
            interestWeights: [
                "interest.family-time": 0.95,
                "interest.children": 0.85,
                "interest.meal-at-home": 0.75
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.family.adjust-plan",
            interestWeights: [
                "interest.calendar-coordination": 0.75,
                "interest.school-followup": 0.90,
                "interest.health": 0.70,
                "interest.next-week-planning": 0.60
            ]
        ),
    ]

    public static let challengeOnlyProfiles: [PurposeScenarioProfile] = [
        PurposeScenarioProfile(
            purposeId: "purpose.feedback-burst",
            interestWeights: [
                "interest.feedback": 1.00,
                "interest.documentation": 1.00
            ]
        ),
    ]

    public static let challengeCases: [ScenarioChallengeCase] = [
        ScenarioChallengeCase(
            caseID: "challenge.work-post-share-vs-feedback-burst",
            interests: [
                "interest.feedback",
                "interest.documentation",
                "interest.onboarding"
            ],
            expectation: .methodSpecificTopPurpose([
                .weightedRaw: "purpose.share",
                .cosine: "purpose.feedback-burst"
            ])
        ),
        ScenarioChallengeCase(
            caseID: "challenge.conference-post-project-followup",
            interests: [
                "interest.followup",
                "interest.shared-projects",
                "interest.problem-solving",
                "interest.ai"
            ],
            expectation: .methodSpecificTopPurpose([
                .weightedRaw: "purpose.collaborate",
                .cosine: "purpose.collaborate"
            ])
        ),
        ScenarioChallengeCase(
            caseID: "challenge.family-coordination-over-dinner",
            interests: [
                "interest.calendar-coordination",
                "interest.health",
                "interest.children",
                "interest.meal-at-home"
            ],
            expectation: .methodSpecificTopPurpose([
                .weightedRaw: "purpose.family.coordinate-care",
                .cosine: "purpose.family.coordinate-care"
            ])
        ),
        ScenarioChallengeCase(
            caseID: "challenge.negative.cross-domain-noise",
            interests: [
                "interest.health",
                "interest.team-fit",
                "interest.local-food"
            ],
            expectation: .noConfidentMatch
        ),
        ScenarioChallengeCase(
            caseID: "challenge.negative.out-of-distribution",
            interests: [
                "interest.tax-filing",
                "interest.pet-grooming"
            ],
            expectation: .noConfidentMatch
        )
    ]

    public static let conferenceProfiles: [PurposeScenarioProfile] = [
        PurposeScenarioProfile(
            purposeId: "purpose.conference.discover-relevant-program",
            interestWeights: [
                "interest.ai": 0.55,
                "interest.conference.track": 0.90,
                "interest.conference.session": 0.85,
                "interest.speaker-fit": 0.65,
                "interest.note-taking": 0.45,
                "interest.schedule-fit": 0.70
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.conference.learn-hands-on",
            interestWeights: [
                "interest.workshop-participation": 1.00,
                "interest.problem-solving": 0.90,
                "interest.practical-exercises": 0.85
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.conference.extract-actionable-insights",
            interestWeights: [
                "interest.education": 0.80,
                "interest.note-taking": 0.85,
                "interest.documentation": 0.70,
                "interest.implementation-notes": 0.90,
                "interest.followup": 0.45
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.conference.scan-strategic-trends",
            interestWeights: [
                "interest.keynote": 0.95,
                "interest.market-trends": 0.90,
                "interest.future-scenarios": 0.80
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.conference.build-high-trust-intros",
            interestWeights: [
                "interest.peer-meetings": 0.95,
                "interest.hallway-conversations": 0.85,
                "interest.shared-context": 0.70,
                "interest.followup": 0.70,
                "interest.team-fit": 0.45,
                "interest.trust-signal": 0.90
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.conference.find-strategic-partner",
            interestWeights: [
                "interest.partner-fit": 1.00,
                "interest.shared-projects": 0.90,
                "interest.decision-maker": 0.75
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.conference.evaluate-vendors",
            interestWeights: [
                "interest.conference.expo": 0.90,
                "interest.vendor-comparison": 0.95,
                "interest.security": 0.70,
                "interest.budget": 0.65,
                "interest.integration-fit": 0.80,
                "interest.procurement-readiness": 0.55
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.conference.buy-with-intent",
            interestWeights: [
                "interest.hosted-buyer": 1.00,
                "interest.procurement-readiness": 0.90,
                "interest.decision-window": 0.85
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.conference.generate-qualified-leads",
            interestWeights: [
                "interest.conference.lead": 1.00,
                "interest.conference.exhibitor": 0.85,
                "interest.pitch-fit": 0.75,
                "interest.followup": 0.80,
                "interest.crm-capture": 0.70,
                "interest.buyer-intent": 0.90
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.conference.capture-feedback-burst",
            interestWeights: [
                "interest.feedback": 1.00,
                "interest.product-demo": 0.90,
                "interest.objection-handling": 0.80
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.conference.find-speakers-to-follow",
            interestWeights: [
                "interest.speaker-fit": 0.95,
                "interest.topic-authority": 0.90,
                "interest.session-quality": 0.75,
                "interest.social-proof": 0.55,
                "interest.followup": 0.50
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.conference.map-opposing-views",
            interestWeights: [
                "interest.panel-discussion": 0.95,
                "interest.policy-debate": 0.90,
                "interest.argument-map": 0.85
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.conference.join-community",
            interestWeights: [
                "interest.community": 0.95,
                "interest.peer-meetings": 0.65,
                "interest.hallway-conversations": 0.70,
                "interest.birds-of-a-feather": 0.85,
                "interest.followup": 0.60,
                "interest.shared-context": 0.80
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.conference.co-create-agenda",
            interestWeights: [
                "interest.unconference": 1.00,
                "interest.participant-led": 0.95,
                "interest.collaborative-agenda": 0.90
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.conference.turn-talks-into-projects",
            interestWeights: [
                "interest.shared-projects": 0.95,
                "interest.problem-solving": 0.85,
                "interest.followup": 0.90,
                "interest.documentation": 0.65,
                "interest.next-step": 0.90,
                "interest.team-fit": 0.55
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.conference.schedule-post-event-followup",
            interestWeights: [
                "interest.followup": 1.00,
                "interest.calendar-coordination": 0.90,
                "interest.next-step": 0.85
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.conference.optimize-personal-agenda",
            interestWeights: [
                "interest.schedule-fit": 1.00,
                "interest.energy-management": 0.80,
                "interest.must-attend-session": 0.85,
                "interest.travel-buffer": 0.60,
                "interest.priority-conflict": 0.90
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.conference.recover-between-sessions",
            interestWeights: [
                "interest.rest": 0.95,
                "interest.energy-management": 0.90,
                "interest.low-effort-planning": 0.80
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.conference.assess-risk-and-compliance",
            interestWeights: [
                "interest.security": 0.95,
                "interest.privacy": 0.90,
                "interest.regulation": 0.85,
                "interest.vendor-comparison": 0.55,
                "interest.documentation": 0.70,
                "interest.decision-maker": 0.45
            ]
        ),
        PurposeScenarioProfile(
            purposeId: "purpose.conference.support-organizer-outcomes",
            interestWeights: [
                "interest.conference.sponsor": 0.90,
                "interest.attendee-success": 0.95,
                "interest.session-feedback": 0.85
            ]
        )
    ]

    public static let conferenceTextCases: [ConferenceScenarioTextCase] = [
        ConferenceScenarioTextCase(
            caseID: "conference.first-time-program-navigation",
            description: "A first-time participant wants to find the sessions and speakers that make the conference intelligible without drowning in the schedule.",
            expectedPurposeID: "purpose.conference.discover-relevant-program",
            interests: ["interest.ai", "interest.conference.track", "interest.conference.session", "interest.speaker-fit", "interest.schedule-fit"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.hands-on-workshop-practice",
            description: "An engineer wants practical exercises and a workshop where they can solve a real implementation problem before going home.",
            expectedPurposeID: "purpose.conference.learn-hands-on",
            interests: ["interest.workshop-participation", "interest.problem-solving", "interest.practical-exercises"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.architecture-notes-for-team",
            description: "A team lead wants implementation notes, documentation and actionable architecture decisions to bring back to colleagues.",
            expectedPurposeID: "purpose.conference.extract-actionable-insights",
            interests: ["interest.documentation", "interest.implementation-notes", "interest.note-taking", "interest.education"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.executive-trend-scan",
            description: "An executive is scanning keynotes for market shifts, future scenarios and strategic technology trends.",
            expectedPurposeID: "purpose.conference.scan-strategic-trends",
            interests: ["interest.keynote", "interest.market-trends", "interest.future-scenarios"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.high-trust-peer-intros",
            description: "A returning attendee wants high-trust hallway conversations with peers who share context and can follow up after the event.",
            expectedPurposeID: "purpose.conference.build-high-trust-intros",
            interests: ["interest.peer-meetings", "interest.hallway-conversations", "interest.shared-context", "interest.trust-signal", "interest.followup"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.partner-search",
            description: "A founder is looking for a strategic partner with shared project fit and decision authority.",
            expectedPurposeID: "purpose.conference.find-strategic-partner",
            interests: ["interest.partner-fit", "interest.shared-projects", "interest.decision-maker"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.enterprise-vendor-shortlist",
            description: "A buyer compares vendors in the expo and needs security, budget, integration and procurement signals.",
            expectedPurposeID: "purpose.conference.evaluate-vendors",
            interests: ["interest.conference.expo", "interest.vendor-comparison", "interest.security", "interest.budget", "interest.integration-fit", "interest.procurement-readiness"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.hosted-buyer-ready",
            description: "A hosted buyer has a near-term decision window and wants to move quickly from procurement intent to meetings.",
            expectedPurposeID: "purpose.conference.buy-with-intent",
            interests: ["interest.hosted-buyer", "interest.procurement-readiness", "interest.decision-window"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.exhibitor-qualified-leads",
            description: "An exhibitor wants qualified buyer intent, CRM capture and follow-up from leads that fit their pitch.",
            expectedPurposeID: "purpose.conference.generate-qualified-leads",
            interests: ["interest.conference.lead", "interest.conference.exhibitor", "interest.pitch-fit", "interest.buyer-intent", "interest.crm-capture", "interest.followup"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.demo-feedback-sprint",
            description: "A product team wants concentrated feedback on a demo and objections they can handle before launch.",
            expectedPurposeID: "purpose.conference.capture-feedback-burst",
            interests: ["interest.feedback", "interest.product-demo", "interest.objection-handling"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.speaker-follow-list",
            description: "A researcher wants to find authoritative speakers to follow based on session quality and social proof.",
            expectedPurposeID: "purpose.conference.find-speakers-to-follow",
            interests: ["interest.speaker-fit", "interest.topic-authority", "interest.session-quality", "interest.social-proof"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.policy-opposing-views",
            description: "A policy analyst wants panel discussions where opposing views can be mapped into a clear argument map.",
            expectedPurposeID: "purpose.conference.map-opposing-views",
            interests: ["interest.panel-discussion", "interest.policy-debate", "interest.argument-map"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.local-community-chapter",
            description: "A community organizer wants birds-of-a-feather groups, shared context and follow-up for a local chapter.",
            expectedPurposeID: "purpose.conference.join-community",
            interests: ["interest.community", "interest.birds-of-a-feather", "interest.shared-context", "interest.followup", "interest.peer-meetings"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.unconference-agenda",
            description: "A participant wants an unconference setting where attendees co-create the agenda rather than only consume talks.",
            expectedPurposeID: "purpose.conference.co-create-agenda",
            interests: ["interest.unconference", "interest.participant-led", "interest.collaborative-agenda"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.post-event-projects",
            description: "A maintainer wants to turn conversations into shared projects with next steps, documentation and follow-up.",
            expectedPurposeID: "purpose.conference.turn-talks-into-projects",
            interests: ["interest.shared-projects", "interest.problem-solving", "interest.next-step", "interest.documentation", "interest.followup"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.followup-scheduling",
            description: "A small group has agreed to continue and now needs calendar coordination and a concrete next step.",
            expectedPurposeID: "purpose.conference.schedule-post-event-followup",
            interests: ["interest.followup", "interest.calendar-coordination", "interest.next-step"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.personal-agenda-optimizer",
            description: "An attendee has conflicts between must-attend sessions and needs a schedule that protects energy and travel buffers.",
            expectedPurposeID: "purpose.conference.optimize-personal-agenda",
            interests: ["interest.schedule-fit", "interest.energy-management", "interest.must-attend-session", "interest.travel-buffer", "interest.priority-conflict"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.recovery-between-sessions",
            description: "A burned-out leader needs low-effort planning, rest and energy management between dense sessions.",
            expectedPurposeID: "purpose.conference.recover-between-sessions",
            interests: ["interest.rest", "interest.energy-management", "interest.low-effort-planning"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.risk-compliance-evaluation",
            description: "A security lead compares regulation, privacy and vendor risk while collecting documentation for compliance review.",
            expectedPurposeID: "purpose.conference.assess-risk-and-compliance",
            interests: ["interest.security", "interest.privacy", "interest.regulation", "interest.vendor-comparison", "interest.documentation"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.organizer-sponsor-outcomes",
            description: "An organizer wants sponsor outcomes, attendee success and useful session feedback without distorting the program.",
            expectedPurposeID: "purpose.conference.support-organizer-outcomes",
            interests: ["interest.conference.sponsor", "interest.attendee-success", "interest.session-feedback"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.accessible-program-path",
            description: "An accessibility advocate wants schedule fit, session quality and quiet recovery space before choosing sessions.",
            expectedPurposeID: "purpose.conference.optimize-personal-agenda",
            interests: ["interest.schedule-fit", "interest.energy-management", "interest.conference.session", "interest.priority-conflict", "interest.rest"],
            notes: ["multi_layer_candidate"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.press-briefing-notes",
            description: "A journalist needs speaker authority, session quality, documentation and follow-up for accurate coverage.",
            expectedPurposeID: "purpose.conference.find-speakers-to-follow",
            interests: ["interest.speaker-fit", "interest.topic-authority", "interest.session-quality", "interest.documentation", "interest.followup"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.investor-founder-patterns",
            description: "An investor uses keynotes and market trends to find decision makers for strategic partnerships.",
            expectedPurposeID: "purpose.conference.find-strategic-partner",
            interests: ["interest.partner-fit", "interest.decision-maker", "interest.market-trends", "interest.shared-projects"]
        ),
        ConferenceScenarioTextCase(
            caseID: "conference.remote-worker-social-energy",
            description: "A remote worker wants small peer meetings and community, but only if energy management and rest are respected.",
            expectedPurposeID: "purpose.conference.join-community",
            interests: ["interest.community", "interest.peer-meetings", "interest.shared-context", "interest.energy-management", "interest.rest"],
            notes: ["multi_layer_candidate"]
        )
    ]

    public static let conferenceLayeredScenarios: [ConferenceLayeredScenario] = [
        ConferenceLayeredScenario(
            caseID: "layered.after-hours-speaker-dinner",
            description: "Layer 1 finds high-trust networking; layer 2 must carry role, after-hours consent, language and trust into dinner candidate selection.",
            startInterestIDs: ["interest.peer-meetings", "interest.after-hours", "interest.trust-signal"],
            firstLayerPurposeID: "purpose.conference.build-high-trust-intros",
            localVariables: ["role": "attendee", "afterHours": "true", "language": "nb", "consent.intros": "true", "trust.min": "0.7"],
            candidates: [
                ConferenceLayeredCandidate(candidateID: "candidate.speaker-dinner.nb", interestID: "interest.layer.speaker-dinner.nb", purposeID: "purpose.conference.build-high-trust-intros", requiredVariables: ["role": "attendee", "afterHours": "true", "language": "nb", "consent.intros": "true"]),
                ConferenceLayeredCandidate(candidateID: "candidate.sponsor-dinner.closed", interestID: "interest.layer.sponsor-dinner.closed", purposeID: "purpose.conference.generate-qualified-leads", requiredVariables: ["role": "sponsor", "afterHours": "true"])
            ],
            expectedCandidateID: "candidate.speaker-dinner.nb",
            expectedPurposeID: "purpose.conference.build-high-trust-intros"
        ),
        ConferenceLayeredScenario(
            caseID: "layered.workshop-seat-allocation",
            description: "Layer 1 finds hands-on learning; layer 2 must keep capacity, ticket tier and time window before recommending a workshop slot.",
            startInterestIDs: ["interest.workshop-participation", "interest.practical-exercises", "interest.problem-solving"],
            firstLayerPurposeID: "purpose.conference.learn-hands-on",
            localVariables: ["ticketTier": "workshop", "capacity.remaining": "4", "timeWindow": "morning", "calendar.conflict": "false"],
            candidates: [
                ConferenceLayeredCandidate(candidateID: "candidate.ai-workshop.morning", interestID: "interest.layer.ai-workshop.morning", purposeID: "purpose.conference.learn-hands-on", requiredVariables: ["ticketTier": "workshop", "timeWindow": "morning", "calendar.conflict": "false"]),
                ConferenceLayeredCandidate(candidateID: "candidate.ai-workshop.waitlist", interestID: "interest.layer.ai-workshop.waitlist", purposeID: "purpose.conference.optimize-personal-agenda", requiredVariables: ["capacity.remaining": "0"])
            ],
            expectedCandidateID: "candidate.ai-workshop.morning",
            expectedPurposeID: "purpose.conference.learn-hands-on"
        ),
        ConferenceLayeredScenario(
            caseID: "layered.hosted-buyer-vendor",
            description: "Layer 1 finds buyer intent; layer 2 must keep role, commercial consent and procurement window to avoid spammy exhibitor matches.",
            startInterestIDs: ["interest.hosted-buyer", "interest.procurement-readiness", "interest.decision-window"],
            firstLayerPurposeID: "purpose.conference.buy-with-intent",
            localVariables: ["role": "hostedBuyer", "consent.commercial": "true", "procurementWindow": "quarter", "budgetRange": "enterprise"],
            candidates: [
                ConferenceLayeredCandidate(candidateID: "candidate.vendor-meeting.enterprise", interestID: "interest.layer.vendor-meeting.enterprise", purposeID: "purpose.conference.evaluate-vendors", requiredVariables: ["role": "hostedBuyer", "consent.commercial": "true", "budgetRange": "enterprise"]),
                ConferenceLayeredCandidate(candidateID: "candidate.exhibitor-lead-capture", interestID: "interest.layer.exhibitor-lead-capture", purposeID: "purpose.conference.generate-qualified-leads", requiredVariables: ["role": "exhibitor", "consent.commercial": "true"])
            ],
            expectedCandidateID: "candidate.vendor-meeting.enterprise",
            expectedPurposeID: "purpose.conference.evaluate-vendors"
        ),
        ConferenceLayeredScenario(
            caseID: "layered.language-compatible-hallway-chat",
            description: "Layer 1 finds networking; layer 2 must carry language, zone and availability to avoid impossible hallway introductions.",
            startInterestIDs: ["interest.hallway-conversations", "interest.shared-context", "interest.peer-meetings"],
            firstLayerPurposeID: "purpose.conference.build-high-trust-intros",
            localVariables: ["language": "en", "locationZone": "hall-b", "availableUntil": "15:30", "conversationMode": "short"],
            candidates: [
                ConferenceLayeredCandidate(candidateID: "candidate.hallway-chat.en.hall-b", interestID: "interest.layer.hallway-chat.en.hall-b", purposeID: "purpose.conference.build-high-trust-intros", requiredVariables: ["language": "en", "locationZone": "hall-b", "conversationMode": "short"]),
                ConferenceLayeredCandidate(candidateID: "candidate.hallway-chat.nb.hall-a", interestID: "interest.layer.hallway-chat.nb.hall-a", purposeID: "purpose.conference.join-community", requiredVariables: ["language": "nb", "locationZone": "hall-a"])
            ],
            expectedCandidateID: "candidate.hallway-chat.en.hall-b",
            expectedPurposeID: "purpose.conference.build-high-trust-intros"
        ),
        ConferenceLayeredScenario(
            caseID: "layered.press-briefing-embargo",
            description: "Layer 1 finds speaker/documentation value; layer 2 must keep press role and embargo acceptance before private briefing.",
            startInterestIDs: ["interest.speaker-fit", "interest.documentation", "interest.topic-authority"],
            firstLayerPurposeID: "purpose.conference.find-speakers-to-follow",
            localVariables: ["role": "press", "embargoAccepted": "true", "allowedTopic": "roadmap", "timeWindow": "afternoon"],
            candidates: [
                ConferenceLayeredCandidate(candidateID: "candidate.press-briefing.roadmap", interestID: "interest.layer.press-briefing.roadmap", purposeID: "purpose.conference.extract-actionable-insights", requiredVariables: ["role": "press", "embargoAccepted": "true", "allowedTopic": "roadmap"]),
                ConferenceLayeredCandidate(candidateID: "candidate.public-session-only", interestID: "interest.layer.public-session-only", purposeID: "purpose.conference.discover-relevant-program", requiredVariables: ["embargoAccepted": "false"])
            ],
            expectedCandidateID: "candidate.press-briefing.roadmap",
            expectedPurposeID: "purpose.conference.extract-actionable-insights"
        ),
        ConferenceLayeredScenario(
            caseID: "layered.accessibility-aware-session",
            description: "Layer 1 finds personal agenda optimization; layer 2 must carry room access needs and distance tolerance.",
            startInterestIDs: ["interest.schedule-fit", "interest.energy-management", "interest.conference.session"],
            firstLayerPurposeID: "purpose.conference.optimize-personal-agenda",
            localVariables: ["accessibilityNeeds": "stepFree", "roomFeature": "captioning", "distanceTolerance": "near", "timeWindow": "midday"],
            candidates: [
                ConferenceLayeredCandidate(candidateID: "candidate.accessible-session.captioned", interestID: "interest.layer.accessible-session.captioned", purposeID: "purpose.conference.discover-relevant-program", requiredVariables: ["accessibilityNeeds": "stepFree", "roomFeature": "captioning", "distanceTolerance": "near"]),
                ConferenceLayeredCandidate(candidateID: "candidate.remote-overflow-room", interestID: "interest.layer.remote-overflow-room", purposeID: "purpose.conference.recover-between-sessions", requiredVariables: ["distanceTolerance": "remote"])
            ],
            expectedCandidateID: "candidate.accessible-session.captioned",
            expectedPurposeID: "purpose.conference.discover-relevant-program"
        ),
        ConferenceLayeredScenario(
            caseID: "layered.followup-project-triage",
            description: "Layer 1 finds project conversion; layer 2 must carry contact consent, follow-up deadline and owner availability.",
            startInterestIDs: ["interest.followup", "interest.shared-projects", "interest.next-step"],
            firstLayerPurposeID: "purpose.conference.turn-talks-into-projects",
            localVariables: ["contactConsent": "true", "followupDeadline": "7d", "ownerAvailability": "high", "trust.min": "0.6"],
            candidates: [
                ConferenceLayeredCandidate(candidateID: "candidate.project-followup.7d", interestID: "interest.layer.project-followup.7d", purposeID: "purpose.conference.schedule-post-event-followup", requiredVariables: ["contactConsent": "true", "followupDeadline": "7d", "ownerAvailability": "high"]),
                ConferenceLayeredCandidate(candidateID: "candidate.defer-followup", interestID: "interest.layer.defer-followup", purposeID: "purpose.conference.extract-actionable-insights", requiredVariables: ["ownerAvailability": "low"])
            ],
            expectedCandidateID: "candidate.project-followup.7d",
            expectedPurposeID: "purpose.conference.schedule-post-event-followup"
        ),
        ConferenceLayeredScenario(
            caseID: "layered.budgeted-after-hours-dinner",
            description: "Layer 1 finds networking; layer 2 must carry budget, dietary need and social consent before suggesting dinner.",
            startInterestIDs: ["interest.peer-meetings", "interest.after-hours", "interest.local-food"],
            firstLayerPurposeID: "purpose.conference.build-high-trust-intros",
            localVariables: ["budgetMax": "moderate", "dietaryNeed": "vegetarian", "availableAfter": "18:00", "consent.social": "true"],
            candidates: [
                ConferenceLayeredCandidate(candidateID: "candidate.vegetarian-dinner.moderate", interestID: "interest.layer.vegetarian-dinner.moderate", purposeID: "purpose.conference.join-community", requiredVariables: ["budgetMax": "moderate", "dietaryNeed": "vegetarian", "consent.social": "true"]),
                ConferenceLayeredCandidate(candidateID: "candidate.expensive-sponsor-dinner", interestID: "interest.layer.expensive-sponsor-dinner", purposeID: "purpose.conference.generate-qualified-leads", requiredVariables: ["budgetMax": "high", "consent.social": "true"])
            ],
            expectedCandidateID: "candidate.vegetarian-dinner.moderate",
            expectedPurposeID: "purpose.conference.join-community"
        )
    ]

    public static func defaultRepositoryRoot(filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    public static func baselineURL(repositoryRoot: URL = defaultRepositoryRoot()) -> URL {
        repositoryRoot
            .appendingPathComponent("Docs", isDirectory: true)
            .appendingPathComponent("benchmarks", isDirectory: true)
            .appendingPathComponent("purpose_interest_matching_baseline.json")
    }

    public static func loadDocument(
        named name: String,
        repositoryRoot: URL = defaultRepositoryRoot()
    ) throws -> PerspectiveDocument {
        let data = try Data(contentsOf: exampleURL(named: name, repositoryRoot: repositoryRoot))
        return try JSONDecoder().decode(PerspectiveDocument.self, from: data)
    }

    public static func snapshot(for phase: PerspectiveScenarioPhase, in document: PerspectiveDocument) -> PerspectiveSnapshot {
        switch phase {
        case .pre:
            return document.pre
        case .during:
            return document.during
        case .post:
            return document.post
        }
    }

    public static func expectedTopPurposeID(for snapshot: PerspectiveSnapshot) -> String? {
        snapshot.purposes.last(where: { !mandatoryPurposeIDs.contains($0) }) ?? snapshot.purposes.last
    }

    public static func score(snapshot: PerspectiveSnapshot) async -> [RelationalPurposeScore] {
        await weightedScores(interests: snapshot.interests, includeChallengeDecoys: false)
    }

    public static func rankedPurposes(
        for snapshot: PerspectiveSnapshot,
        method: ScenarioRankingMethod,
        tuning: ScenarioWeightTuningConfig? = nil
    ) async -> [ScenarioRankedPurpose] {
        await rankedPurposes(
            interests: snapshot.interests,
            method: method,
            includeChallengeDecoys: false,
            tuning: tuning
        )
    }

    public static func rankedPurposes(
        interests: [String],
        method: ScenarioRankingMethod,
        includeChallengeDecoys: Bool,
        tuning: ScenarioWeightTuningConfig? = nil
    ) async -> [ScenarioRankedPurpose] {
        await rankedPurposes(
            interests: interests,
            method: method,
            profiles: purposeProfiles(includeChallengeDecoys: includeChallengeDecoys, tuning: tuning)
        )
    }

    public static func rankedPurposes(
        interests: [String],
        method: ScenarioRankingMethod,
        profiles: [PurposeScenarioProfile]
    ) async -> [ScenarioRankedPurpose] {
        switch method {
        case .weightedRaw:
            let scores = await weightedScores(interests: interests, profiles: profiles)
            return scores.map { score in
                let matched = score.explain.topEdges
                    .map(\.edge.toNode.id)
                    .filter { interests.contains($0) }
                return ScenarioRankedPurpose(
                    purposeId: score.purposeId,
                    score: score.explain.rawScore,
                    matchedInterestRefs: matched
                )
            }
        case .weightedSignal:
            return await weightedSignalRankings(
                interests: interests,
                profiles: profiles
            )
        case .cosine:
            return cosineRankings(
                interests: interests,
                profiles: profiles
            )
        }
    }

    public static func evaluate(
        method: ScenarioRankingMethod,
        repositoryRoot: URL = defaultRepositoryRoot(),
        tuning: ScenarioWeightTuningConfig? = nil
    ) async throws -> ScenarioEvaluationSummary {
        var caseResults = [ScenarioEvaluationCaseResult]()

        for exampleName in exampleNames {
            let document = try loadDocument(named: exampleName, repositoryRoot: repositoryRoot)
            for phase in PerspectiveScenarioPhase.allCases {
                let snapshot = snapshot(for: phase, in: document)
                guard let expectedPurposeID = expectedTopPurposeID(for: snapshot) else {
                    continue
                }

                let rankings = await rankedPurposes(for: snapshot, method: method, tuning: tuning)
                let topPurpose = rankings.first
                let top3 = Array(rankings.prefix(3))
                let reciprocalRank = reciprocalRank(
                    expectedPurposeID: expectedPurposeID,
                    in: rankings
                )

                caseResults.append(
                    ScenarioEvaluationCaseResult(
                        caseID: "\(exampleName)#\(phase.rawValue)",
                        expectedPurposeID: expectedPurposeID,
                        topPurposeID: topPurpose?.purposeId,
                        topScore: topPurpose?.score ?? 0.0,
                        top3ContainsExpected: top3.contains(where: { $0.purposeId == expectedPurposeID }),
                        reciprocalRank: reciprocalRank
                    )
                )
            }
        }

        let totalCases = caseResults.count
        let top1Correct = caseResults.filter { $0.topPurposeID == $0.expectedPurposeID }.count
        let top3Correct = caseResults.filter { $0.top3ContainsExpected }.count
        let meanReciprocalRank = totalCases > 0
            ? caseResults.map(\.reciprocalRank).reduce(0.0, +) / Double(totalCases)
            : 0.0

        return ScenarioEvaluationSummary(
            method: method,
            totalCases: totalCases,
            top1Correct: top1Correct,
            top3Correct: top3Correct,
            meanReciprocalRank: meanReciprocalRank,
            caseResults: caseResults
        )
    }

    public static func evaluateConferenceDataset(method: ScenarioRankingMethod) async -> ScenarioEvaluationSummary {
        var caseResults = [ScenarioEvaluationCaseResult]()

        for scenarioCase in conferenceTextCases {
            let rankings = await rankedPurposes(
                interests: scenarioCase.interests,
                method: method,
                profiles: conferenceProfiles
            )
            let topPurpose = rankings.first
            let top3 = Array(rankings.prefix(3))
            let reciprocalRank = reciprocalRank(
                expectedPurposeID: scenarioCase.expectedPurposeID,
                in: rankings
            )

            caseResults.append(
                ScenarioEvaluationCaseResult(
                    caseID: scenarioCase.caseID,
                    expectedPurposeID: scenarioCase.expectedPurposeID,
                    topPurposeID: topPurpose?.purposeId,
                    topScore: topPurpose?.score ?? 0.0,
                    top3ContainsExpected: top3.contains(where: { $0.purposeId == scenarioCase.expectedPurposeID }),
                    reciprocalRank: reciprocalRank
                )
            )
        }

        let totalCases = caseResults.count
        let top1Correct = caseResults.filter { $0.topPurposeID == $0.expectedPurposeID }.count
        let top3Correct = caseResults.filter { $0.top3ContainsExpected }.count
        let meanReciprocalRank = totalCases > 0
            ? caseResults.map(\.reciprocalRank).reduce(0.0, +) / Double(totalCases)
            : 0.0

        return ScenarioEvaluationSummary(
            method: method,
            totalCases: totalCases,
            top1Correct: top1Correct,
            top3Correct: top3Correct,
            meanReciprocalRank: meanReciprocalRank,
            caseResults: caseResults
        )
    }

    public static func challengeConfidenceFloor(
        method: ScenarioRankingMethod,
        repositoryRoot: URL = defaultRepositoryRoot()
    ) async throws -> Double {
        let summary = try await evaluate(method: method, repositoryRoot: repositoryRoot)
        let topScores = summary.caseResults.map(\.topScore)
        guard let minTopScore = topScores.min() else {
            return 0.0
        }
        return minTopScore * 0.90
    }

    public static func buildBenchmarkArtifact(
        repositoryRoot: URL = defaultRepositoryRoot(),
        tuning: ScenarioWeightTuningConfig? = nil
    ) async throws -> ScenarioBenchmarkArtifact {
        let curatedWeighted = try await evaluate(method: .weightedRaw, repositoryRoot: repositoryRoot)
        let curatedCosine = try await evaluate(method: .cosine, repositoryRoot: repositoryRoot)

        let weightedFloor = try await challengeConfidenceFloor(method: .weightedRaw, repositoryRoot: repositoryRoot)
        let cosineFloor = try await challengeConfidenceFloor(method: .cosine, repositoryRoot: repositoryRoot)

        var methodResults = [ScenarioChallengeMethodSummary]()
        for method in stableBenchmarkMethods {
            let confidenceFloor = method == .weightedRaw ? weightedFloor : cosineFloor
            var caseResults = [ScenarioChallengeCaseResult]()
            for challengeCase in challengeCases {
                let rankings = await rankedPurposes(
                    interests: challengeCase.interests,
                    method: method,
                    includeChallengeDecoys: true
                )
                let top = rankings.first
                let confidentTopPurposeID = top.flatMap { ranked in
                    if ranked.score >= confidenceFloor && Set(ranked.matchedInterestRefs).count >= 2 {
                        return ranked.purposeId
                    }
                    return nil
                }

                switch challengeCase.expectation {
                case let .methodSpecificTopPurpose(expectations):
                    let expectedPurposeID = expectations[method]
                    let passed = (top?.purposeId == expectedPurposeID)
                    caseResults.append(
                        ScenarioChallengeCaseResult(
                            caseID: challengeCase.caseID,
                            method: method,
                            expectedPurposeID: expectedPurposeID,
                            expectedConfidentMatch: true,
                            topPurposeID: top?.purposeId,
                            topScore: top?.score ?? 0.0,
                            confidentTopPurposeID: confidentTopPurposeID,
                            matchedInterestRefs: top?.matchedInterestRefs ?? [],
                            passed: passed
                        )
                    )
                case .noConfidentMatch:
                    let passed = (confidentTopPurposeID == nil)
                    caseResults.append(
                        ScenarioChallengeCaseResult(
                            caseID: challengeCase.caseID,
                            method: method,
                            expectedPurposeID: nil,
                            expectedConfidentMatch: false,
                            topPurposeID: top?.purposeId,
                            topScore: top?.score ?? 0.0,
                            confidentTopPurposeID: confidentTopPurposeID,
                            matchedInterestRefs: top?.matchedInterestRefs ?? [],
                            passed: passed
                        )
                    )
                }
            }
            methodResults.append(
                ScenarioChallengeMethodSummary(
                    method: method,
                    confidenceFloor: confidenceFloor,
                    caseResults: caseResults
                )
            )
        }

        var disagreementCaseIDs = [String]()
        for challengeCase in challengeCases {
            guard case .methodSpecificTopPurpose = challengeCase.expectation else {
                continue
            }
            let weightedTop = await rankedPurposes(
                interests: challengeCase.interests,
                method: .weightedRaw,
                includeChallengeDecoys: true
            ).first?.purposeId
            let cosineTop = await rankedPurposes(
                interests: challengeCase.interests,
                method: .cosine,
                includeChallengeDecoys: true
            ).first?.purposeId
            if weightedTop != cosineTop {
                disagreementCaseIDs.append(challengeCase.caseID)
            }
        }

        let tuningSummary: ScenarioTuningSummary?
        if let tuning {
            tuningSummary = try await buildTuningSummary(tuning, repositoryRoot: repositoryRoot)
        } else {
            tuningSummary = nil
        }

        let artifact = ScenarioBenchmarkArtifact(
            schemaVersion: "1.0",
            curated: [curatedWeighted, curatedCosine],
            challenge: ScenarioChallengeSummary(
                methods: methodResults,
                disagreementCaseIDs: disagreementCaseIDs.sorted()
            ),
            tuning: tuningSummary
        )
        return normalizedArtifact(artifact)
    }

    public static func buildBenchmarkReport(
        format: ScenarioBenchmarkReportFormat,
        repositoryRoot: URL = defaultRepositoryRoot(),
        tuning: ScenarioWeightTuningConfig? = nil
    ) async throws -> String {
        let artifact = try await buildBenchmarkArtifact(repositoryRoot: repositoryRoot, tuning: tuning)
        return try renderReport(artifact, format: format)
    }

    public static func buildRuntimeComparisonArtifact(
        repositoryRoot: URL = defaultRepositoryRoot(),
        iterations: Int = 100,
        methods: [ScenarioRankingMethod] = [.weightedSignal, .cosine, .weightedRaw],
        includeChallengeCases: Bool = true
    ) async throws -> ScenarioRuntimeComparisonArtifact {
        let sanitizedIterations = max(1, iterations)
        let cases = try runtimeComparisonCases(
            repositoryRoot: repositoryRoot,
            includeChallengeCases: includeChallengeCases
        )
        var measurements = [ScenarioRuntimeMethodMeasurement]()

        for method in methods {
            for benchmarkCase in cases {
                _ = await rankedPurposes(
                    interests: benchmarkCase.interests,
                    method: method,
                    includeChallengeDecoys: benchmarkCase.includeChallengeDecoys
                )
            }

            let rssBefore = currentResidentMemoryBytes()
            let started = DispatchTime.now().uptimeNanoseconds
            var rankingCount = 0

            for _ in 0..<sanitizedIterations {
                for benchmarkCase in cases {
                    let rankings = await rankedPurposes(
                        interests: benchmarkCase.interests,
                        method: method,
                        includeChallengeDecoys: benchmarkCase.includeChallengeDecoys
                    )
                    rankingCount += rankings.count
                }
            }

            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            let rssAfter = currentResidentMemoryBytes()
            let operations = max(1, sanitizedIterations * cases.count)
            let rssDelta = rssDeltaBytes(before: rssBefore, after: rssAfter)
            measurements.append(
                ScenarioRuntimeMethodMeasurement(
                    method: method,
                    iterations: sanitizedIterations,
                    caseCount: cases.count,
                    rankingCount: rankingCount,
                    totalElapsedNanoseconds: elapsed,
                    averageNanosecondsPerCase: Double(elapsed) / Double(operations),
                    rssBeforeBytes: rssBefore,
                    rssAfterBytes: rssAfter,
                    rssDeltaBytes: rssDelta
                )
            )
        }

        return ScenarioRuntimeComparisonArtifact(
            schemaVersion: "1.0",
            notes: [
                "`weightedSignal` traverses preweighted Interest -> Purpose edges through `WeightedGraphRuntime` and ranks by edge-weight evidence.",
                "`cosine` is sparse cosine over deterministic interest-id vectors; it is not an external word-vector or embedding baseline yet.",
                "RSS is resident set size sampled before and after each warmed method loop, not peak allocation."
            ],
            measurements: measurements
        )
    }

    public static func buildRuntimeComparisonReport(
        format: ScenarioBenchmarkReportFormat,
        repositoryRoot: URL = defaultRepositoryRoot(),
        iterations: Int = 100
    ) async throws -> String {
        let artifact = try await buildRuntimeComparisonArtifact(
            repositoryRoot: repositoryRoot,
            iterations: iterations
        )
        return try renderRuntimeComparisonReport(artifact, format: format)
    }

    public static func buildConferenceRuntimeComparisonArtifact(
        iterations: Int = 100,
        methods: [ScenarioRankingMethod] = [.weightedSignal, .cosine, .weightedRaw]
    ) async -> ScenarioRuntimeComparisonArtifact {
        let sanitizedIterations = max(1, iterations)
        var measurements = [ScenarioRuntimeMethodMeasurement]()

        for method in methods {
            for scenarioCase in conferenceTextCases {
                _ = await rankedPurposes(
                    interests: scenarioCase.interests,
                    method: method,
                    profiles: conferenceProfiles
                )
            }

            let rssBefore = currentResidentMemoryBytes()
            let started = DispatchTime.now().uptimeNanoseconds
            var rankingCount = 0

            for _ in 0..<sanitizedIterations {
                for scenarioCase in conferenceTextCases {
                    let rankings = await rankedPurposes(
                        interests: scenarioCase.interests,
                        method: method,
                        profiles: conferenceProfiles
                    )
                    rankingCount += rankings.count
                }
            }

            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            let rssAfter = currentResidentMemoryBytes()
            let operations = max(1, sanitizedIterations * conferenceTextCases.count)
            measurements.append(
                ScenarioRuntimeMethodMeasurement(
                    method: method,
                    iterations: sanitizedIterations,
                    caseCount: conferenceTextCases.count,
                    rankingCount: rankingCount,
                    totalElapsedNanoseconds: elapsed,
                    averageNanosecondsPerCase: Double(elapsed) / Double(operations),
                    rssBeforeBytes: rssBefore,
                    rssAfterBytes: rssAfter,
                    rssDeltaBytes: rssDeltaBytes(before: rssBefore, after: rssAfter)
                )
            )
        }

        return ScenarioRuntimeComparisonArtifact(
            schemaVersion: "1.0",
            notes: [
                "Conference dataset: \(conferenceTextCases.count) generated text cases over \(conferenceProfiles.count) deterministic Purpose/Interest profiles.",
                "`weightedSignal` traverses preweighted Interest -> Purpose edges through `WeightedGraphRuntime` and ranks by edge-weight evidence.",
                "`cosine` is sparse cosine over deterministic interest-id vectors; it is not an external word-vector or embedding baseline yet.",
                "Layered conference scenarios are separate because they require localVariables carried from one match layer into the next."
            ],
            measurements: measurements
        )
    }

    public static func buildConferenceRuntimeComparisonReport(
        format: ScenarioBenchmarkReportFormat,
        iterations: Int = 100
    ) async throws -> String {
        let artifact = await buildConferenceRuntimeComparisonArtifact(iterations: iterations)
        return try renderRuntimeComparisonReport(artifact, format: format)
    }

    public static func resolveConferenceLayeredScenario(
        _ scenario: ConferenceLayeredScenario
    ) async throws -> ConferenceLayeredScenarioResult {
        let runtime = WeightedGraphRuntime()
        let finalPurposes = Dictionary(
            uniqueKeysWithValues: Set(scenario.candidates.map(\.purposeID)).map { purposeID in
                (
                    purposeID,
                    Purpose(name: purposeID, description: "Layered conference target \(purposeID)")
                )
            }
        )

        let candidateInterests = Dictionary(
            uniqueKeysWithValues: scenario.candidates.map { candidate in
                (
                    candidate.interestID,
                    Interest(
                        name: candidate.interestID,
                        types: [],
                        parts: [],
                        partOf: [],
                        purposes: [
                            Weight<Purpose>(
                                weight: 1.0,
                                value: finalPurposes[candidate.purposeID]
                            )
                        ]
                    )
                )
            }
        )

        let firstLayerPurpose = Purpose(
            name: scenario.firstLayerPurposeID,
            description: "Layered conference first-layer purpose \(scenario.firstLayerPurposeID)",
            interests: scenario.candidates.compactMap { candidate in
                guard let interest = candidateInterests[candidate.interestID] else {
                    return nil
                }
                return Weight<Interest>(weight: 1.0, value: interest)
            }
        )
        let startInterests = scenario.startInterestIDs.map { interestID in
            Interest(
                name: interestID,
                types: [],
                parts: [],
                partOf: [],
                purposes: [
                    Weight<Purpose>(weight: 1.0, value: firstLayerPurpose)
                ]
            )
        }
        let root = Purpose(
            name: "\(scenario.caseID).root",
            description: "Layered conference root \(scenario.caseID)",
            interests: startInterests.map { Weight<Interest>(weight: 1.0, value: $0) }
        )

        let layer1Signal = Signal(
            relationship: .interests,
            weight: 1.0,
            tolerance: 1.0,
            token: "\(scenario.caseID).layer1",
            ttl: 5.0,
            hops: 2,
            localVariables: object(from: scenario.localVariables)
        )
        let layer1 = try await runtime.match(
            start: root,
            signal: layer1Signal,
            configuration: WeightedGraphRuntimeConfiguration(
                relationships: [.interests, .purposes],
                maxHops: 2,
                ttl: 5.0,
                localVariables: layer1Signal.localVariables
            )
        )
        let firstLayerMatchedPurposeID = layer1.hits
            .first(where: { $0.node.kind == .purpose && $0.ref == scenario.firstLayerPurposeID })?
            .ref

        let layer2Signal = Signal(
            relationship: .interests,
            weight: 1.0,
            tolerance: 1.0,
            token: "\(scenario.caseID).layer2",
            ttl: 5.0,
            hops: 1,
            localVariables: layer1.localVariables
        )
        let layer2 = try await runtime.match(
            start: firstLayerPurpose,
            signal: layer2Signal,
            configuration: WeightedGraphRuntimeConfiguration(signal: layer2Signal)
        )
        let hitInterestIDs = Set(layer2.hits.map(\.ref))
        let selectedCandidate = scenario.candidates.first { candidate in
            hitInterestIDs.contains(candidate.interestID) &&
                requirements(candidate.requiredVariables, areSatisfiedBy: layer2.localVariables)
        }

        let layer3: MatchResult?
        if let selectedCandidate,
           let selectedInterest = candidateInterests[selectedCandidate.interestID] {
            let layer3Signal = Signal(
                relationship: .purposes,
                weight: 1.0,
                tolerance: 1.0,
                token: "\(scenario.caseID).layer3",
                ttl: 5.0,
                hops: 1,
                localVariables: layer2.localVariables
            )
            layer3 = try await runtime.match(
                start: selectedInterest,
                signal: layer3Signal,
                configuration: WeightedGraphRuntimeConfiguration(signal: layer3Signal)
            )
        } else {
            layer3 = nil
        }

        let selectedPurposeID = selectedCandidate.flatMap { candidate in
            layer3?.hits.first(where: { $0.node.kind == .purpose && $0.ref == candidate.purposeID })?.ref
        }

        return ConferenceLayeredScenarioResult(
            caseID: scenario.caseID,
            firstLayerPurposeID: firstLayerMatchedPurposeID,
            selectedCandidateID: selectedCandidate?.candidateID,
            selectedPurposeID: selectedPurposeID,
            carriedLocalVariables: strings(from: layer2.localVariables),
            layer1HitCount: layer1.hits.count,
            layer2HitCount: layer2.hits.count,
            layer3HitCount: layer3?.hits.count ?? 0
        )
    }

    public static func renderReport(
        _ artifact: ScenarioBenchmarkArtifact,
        format: ScenarioBenchmarkReportFormat
    ) throws -> String {
        switch format {
        case .json:
            return try encodeJSON(artifact)
        case .markdown:
            return markdownReport(artifact)
        }
    }

    public static func renderRuntimeComparisonReport(
        _ artifact: ScenarioRuntimeComparisonArtifact,
        format: ScenarioBenchmarkReportFormat
    ) throws -> String {
        switch format {
        case .json:
            return try encodeJSON(artifact)
        case .markdown:
            return markdownRuntimeComparisonReport(artifact)
        }
    }

    public static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    public static func markdownReport(_ artifact: ScenarioBenchmarkArtifact) -> String {
        var lines = [String]()
        lines.append("# Purpose/Interest Matching Benchmark")
        lines.append("")
        lines.append("- Schema version: `\(artifact.schemaVersion)`")
        lines.append("- Curated cases: `\(artifact.curated.first?.totalCases ?? 0)`")
        lines.append("- Challenge cases: `\(artifact.challenge.methods.first?.caseResults.count ?? 0)`")
        lines.append("")
        lines.append("## Curated")
        for summary in artifact.curated {
            lines.append(
                "- `\(summary.method.rawValue)`: top1 `\(summary.top1Correct)/\(summary.totalCases)`, top3 `\(summary.top3Correct)/\(summary.totalCases)`, MRR `\(formatted(summary.meanReciprocalRank))`"
            )
        }
        lines.append("")
        lines.append("## Challenge")
        for methodSummary in artifact.challenge.methods {
            let passed = methodSummary.caseResults.filter(\.passed).count
            lines.append(
                "- `\(methodSummary.method.rawValue)`: passed `\(passed)/\(methodSummary.caseResults.count)`, confidence floor `\(formatted(methodSummary.confidenceFloor))`"
            )
        }
        lines.append("")
        lines.append("## Disagreements")
        if artifact.challenge.disagreementCaseIDs.isEmpty {
            lines.append("- None")
        } else {
            for caseID in artifact.challenge.disagreementCaseIDs {
                let weighted = artifact.challenge.methods
                    .first(where: { $0.method == .weightedRaw })?
                    .caseResults.first(where: { $0.caseID == caseID })
                let cosine = artifact.challenge.methods
                    .first(where: { $0.method == .cosine })?
                    .caseResults.first(where: { $0.caseID == caseID })
                lines.append(
                    "- `\(caseID)`: weighted=`\(weighted?.topPurposeID ?? "nil")`, cosine=`\(cosine?.topPurposeID ?? "nil")`"
                )
            }
        }
        lines.append("")
        lines.append("## Negative And Gated")
        let negativeCaseIDs = Set(
            challengeCases.compactMap { challengeCase in
                if case .noConfidentMatch = challengeCase.expectation {
                    return challengeCase.caseID
                }
                return nil
            }
        )
        let weightedResults = artifact.challenge.methods.first(where: { $0.method == .weightedRaw })?.caseResults ?? []
        let cosineResults = artifact.challenge.methods.first(where: { $0.method == .cosine })?.caseResults ?? []
        for caseID in negativeCaseIDs.sorted() {
            let weighted = weightedResults.first(where: { $0.caseID == caseID })
            let cosine = cosineResults.first(where: { $0.caseID == caseID })
            lines.append(
                "- `\(caseID)`: weighted_confident=`\(weighted?.confidentTopPurposeID ?? "nil")`, cosine_confident=`\(cosine?.confidentTopPurposeID ?? "nil")`"
            )
        }
        if let tuning = artifact.tuning {
            lines.append("")
            lines.append("## Local Tuning")
            lines.append("- Tuning id: `\(tuning.tuningId)`")
            lines.append("- Adjustments: `\(tuning.adjustmentCount)`")
            lines.append("- Shared guardrails: `\(mandatoryPurposeIDs.sorted().joined(separator: "`, `"))`")
            if !tuning.description.isEmpty {
                lines.append("- Description: \(tuning.description)")
            }
            for summary in tuning.tunedCurated {
                lines.append(
                    "- tuned `\(summary.method.rawValue)`: top1 `\(summary.top1Correct)/\(summary.totalCases)`, top3 `\(summary.top3Correct)/\(summary.totalCases)`, MRR `\(formatted(summary.meanReciprocalRank))`"
                )
            }
            let changed = tuning.caseDeltas.filter(\.topChanged)
            if changed.isEmpty {
                lines.append("- No curated top-result changes from local tuning.")
            } else {
                for delta in changed {
                    lines.append(
                        "- `\(delta.caseID)` `\(delta.method.rawValue)`: global=`\(delta.globalTopPurposeID ?? "nil")`, tuned=`\(delta.tunedTopPurposeID ?? "nil")`"
                    )
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func markdownRuntimeComparisonReport(_ artifact: ScenarioRuntimeComparisonArtifact) -> String {
        var lines = [String]()
        lines.append("# Purpose/Interest Runtime Comparison")
        lines.append("")
        lines.append("- Schema version: `\(artifact.schemaVersion)`")
        if let first = artifact.measurements.first {
            lines.append("- Cases: `\(first.caseCount)`")
            lines.append("- Iterations per method: `\(first.iterations)`")
        }
        lines.append("")
        lines.append("## Notes")
        for note in artifact.notes {
            lines.append("- \(note)")
        }
        lines.append("")
        lines.append("## Measurements")
        for measurement in artifact.measurements {
            let average = formattedNanoseconds(measurement.averageNanosecondsPerCase)
            let total = formattedNanoseconds(Double(measurement.totalElapsedNanoseconds))
            let rssDelta = formattedSignedBytes(measurement.rssDeltaBytes)
            let rssAfter = formattedBytes(measurement.rssAfterBytes)
            lines.append(
                "- `\(measurement.method.rawValue)`: avg `\(average)`/case, total `\(total)`, rankings `\(measurement.rankingCount)`, RSS delta `\(rssDelta)`, RSS after `\(rssAfter)`"
            )
        }
        return lines.joined(separator: "\n")
    }

    public static func normalizedArtifact(_ artifact: ScenarioBenchmarkArtifact) -> ScenarioBenchmarkArtifact {
        ScenarioBenchmarkArtifact(
            schemaVersion: artifact.schemaVersion,
            curated: artifact.curated.map { summary in
                ScenarioEvaluationSummary(
                    method: summary.method,
                    totalCases: summary.totalCases,
                    top1Correct: summary.top1Correct,
                    top3Correct: summary.top3Correct,
                    meanReciprocalRank: stableNumber(summary.meanReciprocalRank),
                    caseResults: summary.caseResults.map { result in
                        ScenarioEvaluationCaseResult(
                            caseID: result.caseID,
                            expectedPurposeID: result.expectedPurposeID,
                            topPurposeID: result.topPurposeID,
                            topScore: stableNumber(result.topScore),
                            top3ContainsExpected: result.top3ContainsExpected,
                            reciprocalRank: stableNumber(result.reciprocalRank)
                        )
                    }
                )
            },
            challenge: ScenarioChallengeSummary(
                methods: artifact.challenge.methods.map { methodSummary in
                    ScenarioChallengeMethodSummary(
                        method: methodSummary.method,
                        confidenceFloor: stableNumber(methodSummary.confidenceFloor),
                        caseResults: methodSummary.caseResults.map { result in
                            ScenarioChallengeCaseResult(
                                caseID: result.caseID,
                                method: result.method,
                                expectedPurposeID: result.expectedPurposeID,
                                expectedConfidentMatch: result.expectedConfidentMatch,
                                topPurposeID: result.topPurposeID,
                                topScore: stableNumber(result.topScore),
                                confidentTopPurposeID: result.confidentTopPurposeID,
                                matchedInterestRefs: result.matchedInterestRefs,
                                passed: result.passed
                            )
                        }
                    )
                },
                disagreementCaseIDs: artifact.challenge.disagreementCaseIDs
            ),
            tuning: artifact.tuning.map { tuning in
                ScenarioTuningSummary(
                    tuningId: tuning.tuningId,
                    description: tuning.description,
                    adjustmentCount: tuning.adjustmentCount,
                    tunedCurated: tuning.tunedCurated.map { summary in
                        ScenarioEvaluationSummary(
                            method: summary.method,
                            totalCases: summary.totalCases,
                            top1Correct: summary.top1Correct,
                            top3Correct: summary.top3Correct,
                            meanReciprocalRank: stableNumber(summary.meanReciprocalRank),
                            caseResults: summary.caseResults.map { result in
                                ScenarioEvaluationCaseResult(
                                    caseID: result.caseID,
                                    expectedPurposeID: result.expectedPurposeID,
                                    topPurposeID: result.topPurposeID,
                                    topScore: stableNumber(result.topScore),
                                    top3ContainsExpected: result.top3ContainsExpected,
                                    reciprocalRank: stableNumber(result.reciprocalRank)
                                )
                            }
                        )
                    },
                    caseDeltas: tuning.caseDeltas.map { delta in
                        ScenarioTuningCaseDelta(
                            caseID: delta.caseID,
                            method: delta.method,
                            expectedPurposeID: delta.expectedPurposeID,
                            globalTopPurposeID: delta.globalTopPurposeID,
                            tunedTopPurposeID: delta.tunedTopPurposeID,
                            globalTopScore: stableNumber(delta.globalTopScore),
                            tunedTopScore: stableNumber(delta.tunedTopScore),
                            topChanged: delta.topChanged
                        )
                    }
                )
            }
        )
    }

    private static func buildTuningSummary(
        _ tuning: ScenarioWeightTuningConfig,
        repositoryRoot: URL
    ) async throws -> ScenarioTuningSummary {
        let tunedWeighted = try await evaluate(method: .weightedRaw, repositoryRoot: repositoryRoot, tuning: tuning)
        let tunedCosine = try await evaluate(method: .cosine, repositoryRoot: repositoryRoot, tuning: tuning)
        var deltas = [ScenarioTuningCaseDelta]()

        for exampleName in exampleNames {
            let document = try loadDocument(named: exampleName, repositoryRoot: repositoryRoot)
            for phase in PerspectiveScenarioPhase.allCases {
                let snapshot = snapshot(for: phase, in: document)
                guard let expectedPurposeID = expectedTopPurposeID(for: snapshot) else {
                    continue
                }
                for method in stableBenchmarkMethods {
                    let globalTop = await rankedPurposes(for: snapshot, method: method).first
                    let tunedTop = await rankedPurposes(for: snapshot, method: method, tuning: tuning).first
                    deltas.append(
                        ScenarioTuningCaseDelta(
                            caseID: "\(exampleName)#\(phase.rawValue)",
                            method: method,
                            expectedPurposeID: expectedPurposeID,
                            globalTopPurposeID: globalTop?.purposeId,
                            tunedTopPurposeID: tunedTop?.purposeId,
                            globalTopScore: globalTop?.score ?? 0.0,
                            tunedTopScore: tunedTop?.score ?? 0.0,
                            topChanged: globalTop?.purposeId != tunedTop?.purposeId
                        )
                    )
                }
            }
        }

        for challengeCase in challengeCases {
            for method in stableBenchmarkMethods {
                let globalTop = await rankedPurposes(
                    interests: challengeCase.interests,
                    method: method,
                    includeChallengeDecoys: true
                ).first
                let tunedTop = await rankedPurposes(
                    interests: challengeCase.interests,
                    method: method,
                    includeChallengeDecoys: true,
                    tuning: tuning
                ).first
                deltas.append(
                    ScenarioTuningCaseDelta(
                        caseID: challengeCase.caseID,
                        method: method,
                        expectedPurposeID: expectedPurposeID(for: challengeCase, method: method),
                        globalTopPurposeID: globalTop?.purposeId,
                        tunedTopPurposeID: tunedTop?.purposeId,
                        globalTopScore: globalTop?.score ?? 0.0,
                        tunedTopScore: tunedTop?.score ?? 0.0,
                        topChanged: globalTop?.purposeId != tunedTop?.purposeId
                    )
                )
            }
        }

        return ScenarioTuningSummary(
            tuningId: tuning.tuningId,
            description: tuning.description,
            adjustmentCount: tuning.adjustments.count,
            tunedCurated: [tunedWeighted, tunedCosine],
            caseDeltas: deltas.sorted {
                if $0.caseID == $1.caseID {
                    return $0.method.rawValue < $1.method.rawValue
                }
                return $0.caseID < $1.caseID
            }
        )
    }

    private static func expectedPurposeID(
        for challengeCase: ScenarioChallengeCase,
        method: ScenarioRankingMethod
    ) -> String {
        switch challengeCase.expectation {
        case let .methodSpecificTopPurpose(expectations):
            return expectations[method] ?? "unspecified"
        case .noConfidentMatch:
            return "no_confident_match"
        }
    }

    private struct ScenarioRuntimeComparisonCase {
        var interests: [String]
        var includeChallengeDecoys: Bool
    }

    private static func runtimeComparisonCases(
        repositoryRoot: URL,
        includeChallengeCases: Bool
    ) throws -> [ScenarioRuntimeComparisonCase] {
        var cases = [ScenarioRuntimeComparisonCase]()
        for exampleName in exampleNames {
            let document = try loadDocument(named: exampleName, repositoryRoot: repositoryRoot)
            for phase in PerspectiveScenarioPhase.allCases {
                let snapshot = snapshot(for: phase, in: document)
                cases.append(
                    ScenarioRuntimeComparisonCase(
                        interests: snapshot.interests,
                        includeChallengeDecoys: false
                    )
                )
            }
        }

        if includeChallengeCases {
            for challengeCase in challengeCases {
                cases.append(
                    ScenarioRuntimeComparisonCase(
                        interests: challengeCase.interests,
                        includeChallengeDecoys: true
                    )
                )
            }
        }

        return cases
    }

    private static func apply(
        tuning: ScenarioWeightTuningConfig,
        to profiles: [PurposeScenarioProfile]
    ) -> [PurposeScenarioProfile] {
        var profileByPurpose = Dictionary(uniqueKeysWithValues: profiles.map { ($0.purposeId, $0) })

        for adjustment in tuning.adjustments {
            var profile = profileByPurpose[adjustment.purposeId]
                ?? PurposeScenarioProfile(purposeId: adjustment.purposeId, interestWeights: [:])
            let current = profile.interestWeights[adjustment.interestId] ?? 0.0

            switch adjustment.operation {
            case .set:
                profile.interestWeights[adjustment.interestId] = clamp(adjustment.value ?? current)
            case .add:
                profile.interestWeights[adjustment.interestId] = clamp(current + (adjustment.value ?? 0.0))
            case .multiply:
                profile.interestWeights[adjustment.interestId] = clamp(current * (adjustment.value ?? 1.0))
            case .remove:
                profile.interestWeights.removeValue(forKey: adjustment.interestId)
            }

            profileByPurpose[adjustment.purposeId] = profile
        }

        return profileByPurpose.values.sorted(by: { $0.purposeId < $1.purposeId })
    }

    private static func clamp(_ value: Double, min minValue: Double = 0.0, max maxValue: Double = 1.0) -> Double {
        Swift.max(minValue, Swift.min(maxValue, value))
    }

    private static func weightedScores(
        interests: [String],
        includeChallengeDecoys: Bool,
        tuning: ScenarioWeightTuningConfig? = nil
    ) async -> [RelationalPurposeScore] {
        await weightedScores(
            interests: interests,
            profiles: purposeProfiles(includeChallengeDecoys: includeChallengeDecoys, tuning: tuning)
        )
    }

    private static func weightedScores(
        interests: [String],
        profiles: [PurposeScenarioProfile]
    ) async -> [RelationalPurposeScore] {
        let engine = await seededEngine(profiles: profiles)
        let contextSnapshot = RelationalContextSnapshot(activeInterestRefs: interests)
        let scores = await engine.scorePurposes(contextSnapshot: contextSnapshot, at: fixtureTimestamp, explainTopN: 5)
        return scores.sorted {
            if $0.explain.rawScore == $1.explain.rawScore {
                return $0.purposeId < $1.purposeId
            }
            return $0.explain.rawScore > $1.explain.rawScore
        }
    }

    private static func weightedSignalRankings(
        interests: [String],
        profiles: [PurposeScenarioProfile]
    ) async -> [ScenarioRankedPurpose] {
        let activeInterestIDs = Array(Set(interests)).sorted()
        let purposeNodes = Dictionary(
            uniqueKeysWithValues: profiles.map { profile in
                (
                    profile.purposeId,
                    Purpose(name: profile.purposeId, description: "Scenario benchmark purpose \(profile.purposeId)")
                )
            }
        )
        var purposeEdgesByInterest = [String: [Weight<Purpose>]]()

        for profile in profiles {
            guard let purpose = purposeNodes[profile.purposeId] else { continue }
            for (interestID, weight) in profile.interestWeights where activeInterestIDs.contains(interestID) {
                purposeEdgesByInterest[interestID, default: []].append(
                    Weight<Purpose>(weight: weight, value: purpose)
                )
            }
        }

        let runtime = WeightedGraphRuntime()
        let configuration = WeightedGraphRuntimeConfiguration(
            relationships: [.purposes],
            maxHops: 1,
            ttl: 5.0,
            maxHits: Int.max,
            minScore: 0.0
        )
        var scoresByPurpose = [String: Double]()
        var matchedInterestsByPurpose = [String: Set<String>]()

        for interestID in activeInterestIDs {
            let edges = (purposeEdgesByInterest[interestID] ?? []).sorted {
                ($0.value?.reference ?? $0.reference ?? "") < ($1.value?.reference ?? $1.reference ?? "")
            }
            let interest = Interest(
                name: interestID,
                types: [],
                parts: [],
                partOf: [],
                purposes: edges
            )
            let signal = Signal(
                relationship: .purposes,
                weight: 0.5,
                tolerance: Double.greatestFiniteMagnitude,
                token: "scenario.weightedSignal.\(interestID)",
                ttl: 5.0,
                hops: 1
            )

            guard let result = try? await runtime.match(
                start: interest,
                signal: signal,
                configuration: configuration
            ) else {
                continue
            }

            for hit in result.hits where hit.node.kind == .purpose {
                let edgeWeight = hit.evidence.last(where: { $0.relationship == .purposes })?.edgeWeight ?? 0.0
                scoresByPurpose[hit.ref, default: 0.0] += edgeWeight
                matchedInterestsByPurpose[hit.ref, default: []].insert(interestID)
            }
        }

        let rankings = profiles.map { profile in
            ScenarioRankedPurpose(
                purposeId: profile.purposeId,
                score: scoresByPurpose[profile.purposeId] ?? 0.0,
                matchedInterestRefs: Array(matchedInterestsByPurpose[profile.purposeId] ?? []).sorted()
            )
        }

        return rankings.sorted {
            if $0.score == $1.score {
                return $0.purposeId < $1.purposeId
            }
            return $0.score > $1.score
        }
    }

    private static func seededEngine(
        includeChallengeDecoys: Bool,
        tuning: ScenarioWeightTuningConfig? = nil
    ) async -> RelationalLearningEngine {
        await seededEngine(profiles: purposeProfiles(includeChallengeDecoys: includeChallengeDecoys, tuning: tuning))
    }

    private static func seededEngine(profiles: [PurposeScenarioProfile]) async -> RelationalLearningEngine {
        let engine = RelationalLearningEngine()
        for profile in profiles {
            await seed(profile: profile, into: engine)
        }
        return engine
    }

    private static func purposeProfiles(
        includeChallengeDecoys: Bool,
        tuning: ScenarioWeightTuningConfig? = nil
    ) -> [PurposeScenarioProfile] {
        let baseProfiles = includeChallengeDecoys ? (profiles + challengeOnlyProfiles) : profiles
        guard let tuning else {
            return baseProfiles
        }
        return apply(tuning: tuning, to: baseProfiles)
    }

    private static func seed(profile: PurposeScenarioProfile, into engine: RelationalLearningEngine) async {
        let sortedWeights = profile.interestWeights.sorted(by: { $0.key < $1.key })
        for (interestID, weight) in sortedWeights {
            let edge = RelationalEdge(
                fromNode: RelationalNode(type: .purpose, id: profile.purposeId),
                relationType: .purposeInterest,
                toNode: RelationalNode(type: .interest, id: interestID),
                weightStored: weight,
                lastReinforcedAt: fixtureTimestamp,
                decayProfileId: RelationalDecayPolicy.defaultNoa.profileId,
                decayParamsVersion: RelationalDecayPolicy.defaultNoa.version,
                metadata: ["source": "scenario_fixture"]
            )
            let update = RelationalWeightUpdateEvent(
                eventId: "fixture.\(profile.purposeId).\(interestID)",
                emittedAt: fixtureTimestamp,
                sourceEventId: nil,
                outcome: .explicitPreference,
                edge: edge,
                previousWeightStored: 0.0,
                newWeightStored: weight,
                learningRate: 1.0,
                eligibility: 1.0,
                reason: "scenario_fixture"
            )
            _ = await engine.applyWeightUpdateEvent(update)
        }
    }

    private static func cosineRankings(
        interests: [String],
        profiles: [PurposeScenarioProfile]
    ) -> [ScenarioRankedPurpose] {
        let activeInterestSet = Set(interests)
        let queryNorm = sqrt(Double(activeInterestSet.count))

        let rankings = profiles.map { profile -> ScenarioRankedPurpose in
            let matchedInterestRefs = profile.interestWeights.keys
                .filter { activeInterestSet.contains($0) }
                .sorted()

            let dot = matchedInterestRefs.reduce(0.0) { partial, interestID in
                partial + (profile.interestWeights[interestID] ?? 0.0)
            }
            let candidateNorm = sqrt(
                profile.interestWeights.values.reduce(0.0) { partial, weight in
                    partial + (weight * weight)
                }
            )

            let score: Double
            if queryNorm > 0.0 && candidateNorm > 0.0 {
                score = dot / (queryNorm * candidateNorm)
            } else {
                score = 0.0
            }

            return ScenarioRankedPurpose(
                purposeId: profile.purposeId,
                score: score,
                matchedInterestRefs: matchedInterestRefs
            )
        }

        return rankings.sorted {
            if $0.score == $1.score {
                return $0.purposeId < $1.purposeId
            }
            return $0.score > $1.score
        }
    }

    private static func reciprocalRank(
        expectedPurposeID: String,
        in rankings: [ScenarioRankedPurpose]
    ) -> Double {
        guard let index = rankings.firstIndex(where: { $0.purposeId == expectedPurposeID }) else {
            return 0.0
        }
        return 1.0 / Double(index + 1)
    }

    private static func stableNumber(_ value: Double, decimals: Int = 12) -> Double {
        let factor = pow(10.0, Double(decimals))
        return (value * factor).rounded() / factor
    }

    private static func currentResidentMemoryBytes() -> UInt64? {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPointer,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else {
            return nil
        }
        return UInt64(info.resident_size)
        #else
        return nil
        #endif
    }

    private static func rssDeltaBytes(before: UInt64?, after: UInt64?) -> Int64? {
        guard let before, let after else {
            return nil
        }
        return Int64(after) - Int64(before)
    }

    private static func object(from variables: [String: String]) -> Object {
        Dictionary(uniqueKeysWithValues: variables.map { key, value in
            (key, ValueType.string(value))
        })
    }

    private static func strings(from variables: Object) -> [String: String] {
        Dictionary(uniqueKeysWithValues: variables.compactMap { key, value in
            guard let stringValue = string(from: value) else {
                return nil
            }
            return (key, stringValue)
        })
    }

    private static func requirements(
        _ requirements: [String: String],
        areSatisfiedBy variables: Object
    ) -> Bool {
        requirements.allSatisfy { key, expectedValue in
            string(from: variables[key]) == expectedValue
        }
    }

    private static func string(from value: ValueType?) -> String? {
        guard let value else {
            return nil
        }

        switch value {
        case .string(let string):
            return string
        case .bool(let bool):
            return bool ? "true" : "false"
        case .number(let number), .integer(let number):
            return String(number)
        case .float(let double):
            return String(double)
        default:
            return nil
        }
    }

    private static func exampleURL(named name: String, repositoryRoot: URL) -> URL {
        repositoryRoot
            .appendingPathComponent("commons", isDirectory: true)
            .appendingPathComponent("examples", isDirectory: true)
            .appendingPathComponent("perspectives", isDirectory: true)
            .appendingPathComponent(name)
    }

    private static func formatted(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func formattedNanoseconds(_ value: Double) -> String {
        let microseconds = value / 1_000.0
        if microseconds < 1_000.0 {
            return String(format: "%.1f us", microseconds)
        }
        let milliseconds = microseconds / 1_000.0
        if milliseconds < 1_000.0 {
            return String(format: "%.3f ms", milliseconds)
        }
        return String(format: "%.3f s", milliseconds / 1_000.0)
    }

    private static func formattedBytes(_ value: UInt64?) -> String {
        guard let value else {
            return "unavailable"
        }
        let mib = Double(value) / (1024.0 * 1024.0)
        return String(format: "%.2f MiB", mib)
    }

    private static func formattedSignedBytes(_ value: Int64?) -> String {
        guard let value else {
            return "unavailable"
        }
        let sign = value >= 0 ? "+" : "-"
        let magnitude = Double(abs(value)) / (1024.0 * 1024.0)
        return String(format: "%@%.2f MiB", sign, magnitude)
    }
}
