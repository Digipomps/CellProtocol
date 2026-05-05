// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
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
        switch method {
        case .weightedRaw:
            let scores = await weightedScores(
                interests: interests,
                includeChallengeDecoys: includeChallengeDecoys,
                tuning: tuning
            )
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
        case .cosine:
            return cosineRankings(
                interests: interests,
                profiles: purposeProfiles(includeChallengeDecoys: includeChallengeDecoys, tuning: tuning)
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
        for method in [ScenarioRankingMethod.weightedRaw, .cosine] {
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
                for method in ScenarioRankingMethod.allCases {
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
            for method in ScenarioRankingMethod.allCases {
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
        let engine = await seededEngine(includeChallengeDecoys: includeChallengeDecoys, tuning: tuning)
        let contextSnapshot = RelationalContextSnapshot(activeInterestRefs: interests)
        let scores = await engine.scorePurposes(contextSnapshot: contextSnapshot, at: fixtureTimestamp, explainTopN: 5)
        return scores.sorted {
            if $0.explain.rawScore == $1.explain.rawScore {
                return $0.purposeId < $1.purposeId
            }
            return $0.explain.rawScore > $1.explain.rawScore
        }
    }

    private static func seededEngine(
        includeChallengeDecoys: Bool,
        tuning: ScenarioWeightTuningConfig? = nil
    ) async -> RelationalLearningEngine {
        let engine = RelationalLearningEngine()
        for profile in purposeProfiles(includeChallengeDecoys: includeChallengeDecoys, tuning: tuning) {
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
}
