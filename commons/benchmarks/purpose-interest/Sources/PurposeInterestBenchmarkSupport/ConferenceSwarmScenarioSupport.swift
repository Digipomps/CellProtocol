// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Dispatch
import Foundation
import CellBase

public enum ConferenceSwarmVariableScope: String, Codable, Sendable {
    case requester
    case candidate
}

public struct ConferenceSwarmVariableRequirement: Codable, Sendable, Equatable {
    public var scope: ConferenceSwarmVariableScope
    public var key: String
    public var expectedValue: String

    public init(scope: ConferenceSwarmVariableScope, key: String, expectedValue: String) {
        self.scope = scope
        self.key = key
        self.expectedValue = expectedValue
    }
}

public struct ConferenceSwarmEntity: Codable, Sendable, Equatable {
    public var entityRef: String
    public var role: String
    public var purposeID: String
    public var interestWeights: [String: Double]
    public var shareableVariables: [String: String]
    public var privateVariables: [String: String]

    public init(
        entityRef: String,
        role: String,
        purposeID: String,
        interestWeights: [String: Double],
        shareableVariables: [String: String],
        privateVariables: [String: String] = [:]
    ) {
        self.entityRef = entityRef
        self.role = role
        self.purposeID = purposeID
        self.interestWeights = interestWeights
        self.shareableVariables = shareableVariables
        self.privateVariables = privateVariables
    }
}

public struct ConferenceSwarmOpportunity: Codable, Sendable, Equatable {
    public var opportunityID: String
    public var entityRef: String
    public var purposeID: String
    public var description: String
    public var interestWeights: [String: Double]
    public var requirements: [ConferenceSwarmVariableRequirement]
    public var allowedDisclosureKeys: [String]
    public var helperPurposeIDs: [String]

    public init(
        opportunityID: String,
        entityRef: String,
        purposeID: String,
        description: String,
        interestWeights: [String: Double],
        requirements: [ConferenceSwarmVariableRequirement],
        allowedDisclosureKeys: [String],
        helperPurposeIDs: [String] = []
    ) {
        self.opportunityID = opportunityID
        self.entityRef = entityRef
        self.purposeID = purposeID
        self.description = description
        self.interestWeights = interestWeights
        self.requirements = requirements
        self.allowedDisclosureKeys = allowedDisclosureKeys.sorted()
        self.helperPurposeIDs = helperPurposeIDs.sorted()
    }

    public var matchPurposeID: String {
        "\(entityRef).\(purposeID)"
    }
}

public struct ConferenceSwarmCase: Codable, Sendable, Equatable {
    public var caseID: String
    public var requesterRef: String
    public var expectedOpportunityID: String

    public init(caseID: String, requesterRef: String, expectedOpportunityID: String) {
        self.caseID = caseID
        self.requesterRef = requesterRef
        self.expectedOpportunityID = expectedOpportunityID
    }
}

public enum ConferenceSwarmRejectionReason: String, Codable, Sendable, Equatable {
    case contextRequirementFailed
    case privacyRequirementFailed
    case capabilityRequirementFailed
}

public enum ConferenceSwarmCapability: String, Codable, Sendable, Equatable {
    case matchPurpose
    case discloseContext
    case requestIntro
}

public struct ConferenceSwarmCapabilityGrant: Codable, Sendable, Equatable {
    public var grantID: String
    public var granteeEntityRef: String
    public var opportunityID: String
    public var capabilities: [ConferenceSwarmCapability]
    public var issuedAt: TimeInterval
    public var expiresAt: TimeInterval

    public init(
        grantID: String,
        granteeEntityRef: String,
        opportunityID: String,
        capabilities: [ConferenceSwarmCapability],
        issuedAt: TimeInterval,
        expiresAt: TimeInterval
    ) {
        self.grantID = grantID
        self.granteeEntityRef = granteeEntityRef
        self.opportunityID = opportunityID
        self.capabilities = capabilities.sorted { $0.rawValue < $1.rawValue }
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public func isActive(at timestamp: TimeInterval) -> Bool {
        issuedAt <= timestamp && timestamp <= expiresAt
    }
}

public struct ConferenceSwarmPrivacyViolation: Codable, Sendable, Equatable {
    public var opportunityID: String
    public var scope: ConferenceSwarmVariableScope
    public var key: String
    public var reason: String

    public init(
        opportunityID: String,
        scope: ConferenceSwarmVariableScope,
        key: String,
        reason: String
    ) {
        self.opportunityID = opportunityID
        self.scope = scope
        self.key = key
        self.reason = reason
    }
}

public struct ConferenceSwarmRejectedCandidate: Codable, Sendable, Equatable {
    public var opportunityID: String
    public var reasons: [ConferenceSwarmRejectionReason]
    public var privacyViolations: [ConferenceSwarmPrivacyViolation]

    public init(
        opportunityID: String,
        reasons: [ConferenceSwarmRejectionReason],
        privacyViolations: [ConferenceSwarmPrivacyViolation] = []
    ) {
        self.opportunityID = opportunityID
        self.reasons = reasons
        self.privacyViolations = privacyViolations
    }
}

public struct ConferenceSwarmCaseResult: Codable, Sendable, Equatable {
    public var caseID: String
    public var requesterRef: String
    public var expectedOpportunityID: String
    public var rawTopOpportunityID: String?
    public var selectedOpportunityID: String?
    public var selectedEntityRef: String?
    public var selectedPurposeID: String?
    public var authorizationGrantID: String?
    public var selectedScore: Double
    public var finalRankOfExpected: Int?
    public var matchedInterestRefs: [String]
    public var carriedLocalVariables: [String: String]
    public var disclosedVariableKeys: [String]
    public var rawRankingCount: Int
    public var acceptedRankingCount: Int
    public var rejectedCandidates: [ConferenceSwarmRejectedCandidate]
    public var compositionStatus: PurposeCompositionStatus
    public var compositionScore: Double

    public init(
        caseID: String,
        requesterRef: String,
        expectedOpportunityID: String,
        rawTopOpportunityID: String?,
        selectedOpportunityID: String?,
        selectedEntityRef: String?,
        selectedPurposeID: String?,
        authorizationGrantID: String?,
        selectedScore: Double,
        finalRankOfExpected: Int?,
        matchedInterestRefs: [String],
        carriedLocalVariables: [String: String],
        disclosedVariableKeys: [String],
        rawRankingCount: Int,
        acceptedRankingCount: Int,
        rejectedCandidates: [ConferenceSwarmRejectedCandidate],
        compositionStatus: PurposeCompositionStatus,
        compositionScore: Double
    ) {
        self.caseID = caseID
        self.requesterRef = requesterRef
        self.expectedOpportunityID = expectedOpportunityID
        self.rawTopOpportunityID = rawTopOpportunityID
        self.selectedOpportunityID = selectedOpportunityID
        self.selectedEntityRef = selectedEntityRef
        self.selectedPurposeID = selectedPurposeID
        self.authorizationGrantID = authorizationGrantID
        self.selectedScore = selectedScore
        self.finalRankOfExpected = finalRankOfExpected
        self.matchedInterestRefs = matchedInterestRefs.sorted()
        self.carriedLocalVariables = carriedLocalVariables
        self.disclosedVariableKeys = disclosedVariableKeys.sorted()
        self.rawRankingCount = rawRankingCount
        self.acceptedRankingCount = acceptedRankingCount
        self.rejectedCandidates = rejectedCandidates
        self.compositionStatus = compositionStatus
        self.compositionScore = compositionScore
    }
}

public struct ConferenceSwarmEvaluationSummary: Codable, Sendable, Equatable {
    public var schemaVersion: String
    public var caseCount: Int
    public var top1Correct: Int
    public var top3Correct: Int
    public var meanReciprocalRank: Double
    public var privacyViolationCount: Int
    public var rejectedPrivacyOpportunityIDs: [String]
    public var capabilityRejectedOpportunityIDs: [String]
    public var totalElapsedNanoseconds: UInt64
    public var averageNanosecondsPerCase: Double
    public var caseResults: [ConferenceSwarmCaseResult]

    public init(
        schemaVersion: String = "1.0",
        caseCount: Int,
        top1Correct: Int,
        top3Correct: Int,
        meanReciprocalRank: Double,
        privacyViolationCount: Int,
        rejectedPrivacyOpportunityIDs: [String],
        capabilityRejectedOpportunityIDs: [String],
        totalElapsedNanoseconds: UInt64,
        averageNanosecondsPerCase: Double,
        caseResults: [ConferenceSwarmCaseResult]
    ) {
        self.schemaVersion = schemaVersion
        self.caseCount = caseCount
        self.top1Correct = top1Correct
        self.top3Correct = top3Correct
        self.meanReciprocalRank = meanReciprocalRank
        self.privacyViolationCount = privacyViolationCount
        self.rejectedPrivacyOpportunityIDs = rejectedPrivacyOpportunityIDs.sorted()
        self.capabilityRejectedOpportunityIDs = capabilityRejectedOpportunityIDs.sorted()
        self.totalElapsedNanoseconds = totalElapsedNanoseconds
        self.averageNanosecondsPerCase = averageNanosecondsPerCase
        self.caseResults = caseResults
    }
}

public extension PerspectiveMatchingScenarioSupport {
    static let conferenceSwarmEntities: [ConferenceSwarmEntity] = [
        ConferenceSwarmEntity(
            entityRef: "entity.swarm.attendee.ai-nb",
            role: "attendee",
            purposeID: "purpose.swarm.attendee.high-trust-intros",
            interestWeights: [
                "interest.peer-meetings": 0.95,
                "interest.after-hours": 0.80,
                "interest.trust-signal": 0.90,
                "interest.ai-agents": 0.70
            ],
            shareableVariables: [
                "role": "attendee",
                "language": "nb",
                "consent.intros": "true",
                "consent.social": "true",
                "trust.bucket": "high",
                "timeWindow": "evening",
                "topic.ai": "true",
                "hotelZone": "central"
            ],
            privateVariables: [
                "email": "ai-attendee@example.invalid",
                "fullName": "Ada Nordmann"
            ]
        ),
        ConferenceSwarmEntity(
            entityRef: "entity.swarm.hostedbuyer.security",
            role: "hostedBuyer",
            purposeID: "purpose.swarm.hostedbuyer.vendor-evaluation",
            interestWeights: [
                "interest.hosted-buyer": 0.95,
                "interest.procurement-readiness": 0.90,
                "interest.security": 0.85,
                "interest.vendor-comparison": 0.80
            ],
            shareableVariables: [
                "role": "hostedBuyer",
                "consent.commercial": "true",
                "budgetRange": "enterprise",
                "procurementWindow": "quarter",
                "topic.security": "true",
                "timeWindow": "afternoon",
                "companySize": "large"
            ],
            privateVariables: [
                "email": "buyer@example.invalid",
                "phone": "+47 00000000",
                "legalName": "Example Buyer AS"
            ]
        ),
        ConferenceSwarmEntity(
            entityRef: "entity.swarm.press.roadmap",
            role: "press",
            purposeID: "purpose.swarm.press.private-briefing",
            interestWeights: [
                "interest.speaker-fit": 0.90,
                "interest.documentation": 0.80,
                "interest.topic-authority": 0.85
            ],
            shareableVariables: [
                "role": "press",
                "embargoAccepted": "true",
                "allowedTopic": "roadmap",
                "timeWindow": "afternoon",
                "language": "en"
            ],
            privateVariables: [
                "email": "press@example.invalid",
                "profileURL": "https://example.invalid/press"
            ]
        ),
        ConferenceSwarmEntity(
            entityRef: "entity.swarm.attendee.accessibility",
            role: "attendee",
            purposeID: "purpose.swarm.attendee.accessible-program",
            interestWeights: [
                "interest.schedule-fit": 0.85,
                "interest.energy-management": 0.80,
                "interest.accessibility": 0.95,
                "interest.conference.session": 0.75
            ],
            shareableVariables: [
                "role": "attendee",
                "accessibility.stepFree": "true",
                "accessibility.captioning": "true",
                "distanceTolerance": "near",
                "timeWindow": "midday",
                "energy.level": "medium",
                "preciseLocation": "59.913868,10.752245"
            ],
            privateVariables: [
                "medicalNote": "knee recovery",
                "email": "access@example.invalid"
            ]
        ),
        ConferenceSwarmEntity(
            entityRef: "entity.swarm.founder.optout",
            role: "founder",
            purposeID: "purpose.swarm.founder.safe-intros",
            interestWeights: [
                "interest.partner-fit": 0.90,
                "interest.startup-demo": 0.85,
                "interest.shared-projects": 0.80,
                "interest.conference.sponsor": 0.40
            ],
            shareableVariables: [
                "role": "founder",
                "consent.intros": "true",
                "consent.commercial": "false",
                "stage": "seed",
                "topic.ai": "true",
                "timeWindow": "morning"
            ],
            privateVariables: [
                "email": "founder@example.invalid",
                "phone": "+47 11111111"
            ]
        ),
        ConferenceSwarmEntity(
            entityRef: "entity.swarm.remote.community",
            role: "attendee",
            purposeID: "purpose.swarm.attendee.low-energy-community",
            interestWeights: [
                "interest.community": 0.90,
                "interest.peer-meetings": 0.70,
                "interest.rest": 0.80,
                "interest.energy-management": 0.85
            ],
            shareableVariables: [
                "role": "attendee",
                "consent.social": "true",
                "energy.level": "low",
                "conversationMode": "small-group",
                "timeWindow": "late-afternoon",
                "language": "en"
            ],
            privateVariables: [
                "email": "remote@example.invalid",
                "calendarURL": "https://calendar.example.invalid/remote"
            ]
        )
    ]

    static let conferenceSwarmOpportunities: [ConferenceSwarmOpportunity] = [
        ConferenceSwarmOpportunity(
            opportunityID: "opportunity.swarm.speaker-dinner.nb",
            entityRef: "entity.swarm.speaker.nordic-ai",
            purposeID: "purpose.swarm.opportunity.high-trust-speaker-dinner",
            description: "Small after-hours dinner with a Nordic AI speaker for high-trust introductions.",
            interestWeights: [
                "interest.peer-meetings": 0.90,
                "interest.after-hours": 0.85,
                "interest.trust-signal": 0.80,
                "interest.ai-agents": 0.75
            ],
            requirements: [
                ConferenceSwarmVariableRequirement(scope: .requester, key: "role", expectedValue: "attendee"),
                ConferenceSwarmVariableRequirement(scope: .requester, key: "language", expectedValue: "nb"),
                ConferenceSwarmVariableRequirement(scope: .requester, key: "consent.intros", expectedValue: "true"),
                ConferenceSwarmVariableRequirement(scope: .requester, key: "trust.bucket", expectedValue: "high"),
                ConferenceSwarmVariableRequirement(scope: .candidate, key: "availableWindow", expectedValue: "evening")
            ],
            allowedDisclosureKeys: ["role", "language", "consent.intros", "trust.bucket"],
            helperPurposeIDs: ["purpose.helper.schedule-intro", "purpose.helper.reserve-small-table"]
        ),
        ConferenceSwarmOpportunity(
            opportunityID: "opportunity.swarm.vendor-security.enterprise",
            entityRef: "entity.swarm.vendor.security",
            purposeID: "purpose.swarm.opportunity.enterprise-security-vendor",
            description: "Qualified vendor meeting for hosted buyers evaluating security tooling.",
            interestWeights: [
                "interest.hosted-buyer": 0.88,
                "interest.procurement-readiness": 0.92,
                "interest.security": 0.90,
                "interest.vendor-comparison": 0.85
            ],
            requirements: [
                ConferenceSwarmVariableRequirement(scope: .requester, key: "role", expectedValue: "hostedBuyer"),
                ConferenceSwarmVariableRequirement(scope: .requester, key: "consent.commercial", expectedValue: "true"),
                ConferenceSwarmVariableRequirement(scope: .requester, key: "budgetRange", expectedValue: "enterprise"),
                ConferenceSwarmVariableRequirement(scope: .requester, key: "procurementWindow", expectedValue: "quarter"),
                ConferenceSwarmVariableRequirement(scope: .candidate, key: "topic.security", expectedValue: "true")
            ],
            allowedDisclosureKeys: ["role", "consent.commercial", "budgetRange", "procurementWindow"],
            helperPurposeIDs: ["purpose.helper.vendor-availability", "purpose.helper.contract-followup"]
        ),
        ConferenceSwarmOpportunity(
            opportunityID: "opportunity.swarm.sponsor-lead-capture.unsafe",
            entityRef: "entity.swarm.sponsor.lead-broker",
            purposeID: "purpose.swarm.opportunity.raw-lead-capture",
            description: "Unsafe lead capture attempt that asks for direct contact details.",
            interestWeights: [
                "interest.hosted-buyer": 1.00,
                "interest.procurement-readiness": 1.00,
                "interest.security": 0.94,
                "interest.vendor-comparison": 0.90,
                "interest.partner-fit": 0.85,
                "interest.startup-demo": 0.82
            ],
            requirements: [
                ConferenceSwarmVariableRequirement(scope: .requester, key: "email", expectedValue: "buyer@example.invalid"),
                ConferenceSwarmVariableRequirement(scope: .requester, key: "phone", expectedValue: "+47 00000000")
            ],
            allowedDisclosureKeys: ["email", "phone"],
            helperPurposeIDs: ["purpose.helper.reject-raw-lead-export"]
        ),
        ConferenceSwarmOpportunity(
            opportunityID: "opportunity.swarm.press-briefing.roadmap",
            entityRef: "entity.swarm.speaker.product",
            purposeID: "purpose.swarm.opportunity.press-roadmap-briefing",
            description: "Private roadmap briefing for press who accepted embargo terms.",
            interestWeights: [
                "interest.speaker-fit": 0.90,
                "interest.documentation": 0.85,
                "interest.topic-authority": 0.88
            ],
            requirements: [
                ConferenceSwarmVariableRequirement(scope: .requester, key: "role", expectedValue: "press"),
                ConferenceSwarmVariableRequirement(scope: .requester, key: "embargoAccepted", expectedValue: "true"),
                ConferenceSwarmVariableRequirement(scope: .requester, key: "allowedTopic", expectedValue: "roadmap"),
                ConferenceSwarmVariableRequirement(scope: .candidate, key: "allowedTopic", expectedValue: "roadmap")
            ],
            allowedDisclosureKeys: ["role", "embargoAccepted", "allowedTopic"],
            helperPurposeIDs: ["purpose.helper.embargo-check", "purpose.helper.private-briefing-room"]
        ),
        ConferenceSwarmOpportunity(
            opportunityID: "opportunity.swarm.accessible-session.captioned",
            entityRef: "entity.swarm.session.accessible-ai",
            purposeID: "purpose.swarm.opportunity.captioned-accessible-session",
            description: "Nearby captioned session with step-free route and recovery buffer.",
            interestWeights: [
                "interest.schedule-fit": 0.82,
                "interest.energy-management": 0.78,
                "interest.accessibility": 0.96,
                "interest.conference.session": 0.80
            ],
            requirements: [
                ConferenceSwarmVariableRequirement(scope: .requester, key: "accessibility.stepFree", expectedValue: "true"),
                ConferenceSwarmVariableRequirement(scope: .requester, key: "accessibility.captioning", expectedValue: "true"),
                ConferenceSwarmVariableRequirement(scope: .requester, key: "distanceTolerance", expectedValue: "near"),
                ConferenceSwarmVariableRequirement(scope: .candidate, key: "roomFeature", expectedValue: "captioning")
            ],
            allowedDisclosureKeys: ["accessibility.stepFree", "accessibility.captioning", "distanceTolerance"],
            helperPurposeIDs: ["purpose.helper.route-step-free", "purpose.helper.reserve-captioning-seat"]
        ),
        ConferenceSwarmOpportunity(
            opportunityID: "opportunity.swarm.founder-roundtable.safe",
            entityRef: "entity.swarm.investor.roundtable",
            purposeID: "purpose.swarm.opportunity.founder-roundtable",
            description: "Consent-bound founder roundtable without raw contact export.",
            interestWeights: [
                "interest.partner-fit": 0.88,
                "interest.startup-demo": 0.82,
                "interest.shared-projects": 0.86
            ],
            requirements: [
                ConferenceSwarmVariableRequirement(scope: .requester, key: "role", expectedValue: "founder"),
                ConferenceSwarmVariableRequirement(scope: .requester, key: "consent.intros", expectedValue: "true"),
                ConferenceSwarmVariableRequirement(scope: .requester, key: "stage", expectedValue: "seed"),
                ConferenceSwarmVariableRequirement(scope: .candidate, key: "roundtableType", expectedValue: "founder")
            ],
            allowedDisclosureKeys: ["role", "consent.intros", "stage"],
            helperPurposeIDs: ["purpose.helper.mutual-intro-token"]
        ),
        ConferenceSwarmOpportunity(
            opportunityID: "opportunity.swarm.quiet-peer-table",
            entityRef: "entity.swarm.community.host",
            purposeID: "purpose.swarm.opportunity.quiet-peer-table",
            description: "Small low-energy peer table for attendees who want community without overload.",
            interestWeights: [
                "interest.community": 0.90,
                "interest.peer-meetings": 0.72,
                "interest.rest": 0.82,
                "interest.energy-management": 0.86
            ],
            requirements: [
                ConferenceSwarmVariableRequirement(scope: .requester, key: "consent.social", expectedValue: "true"),
                ConferenceSwarmVariableRequirement(scope: .requester, key: "energy.level", expectedValue: "low"),
                ConferenceSwarmVariableRequirement(scope: .requester, key: "conversationMode", expectedValue: "small-group"),
                ConferenceSwarmVariableRequirement(scope: .candidate, key: "conversationMode", expectedValue: "small-group")
            ],
            allowedDisclosureKeys: ["consent.social", "energy.level", "conversationMode"],
            helperPurposeIDs: ["purpose.helper.group-size-cap", "purpose.helper.quiet-space-routing"]
        )
    ]

    static let conferenceSwarmCandidateVariables: [String: [String: String]] = [
        "entity.swarm.speaker.nordic-ai": [
            "availableWindow": "evening",
            "language": "nb",
            "topic.ai": "true"
        ],
        "entity.swarm.vendor.security": [
            "topic.security": "true",
            "availableWindow": "afternoon"
        ],
        "entity.swarm.sponsor.lead-broker": [
            "exportType": "raw-lead-list",
            "contactTarget": "email"
        ],
        "entity.swarm.speaker.product": [
            "allowedTopic": "roadmap",
            "availableWindow": "afternoon"
        ],
        "entity.swarm.session.accessible-ai": [
            "roomFeature": "captioning",
            "route": "stepFree",
            "distanceTolerance": "near"
        ],
        "entity.swarm.investor.roundtable": [
            "roundtableType": "founder",
            "contactMode": "mutual-intro"
        ],
        "entity.swarm.community.host": [
            "conversationMode": "small-group",
            "noiseLevel": "low"
        ]
    ]

    static let conferenceSwarmCapabilityGrants: [ConferenceSwarmCapabilityGrant] = [
        ConferenceSwarmCapabilityGrant(
            grantID: "grant.swarm.attendee-ai-nb.speaker-dinner",
            granteeEntityRef: "entity.swarm.attendee.ai-nb",
            opportunityID: "opportunity.swarm.speaker-dinner.nb",
            capabilities: [.matchPurpose, .discloseContext, .requestIntro],
            issuedAt: fixtureTimestamp - 60,
            expiresAt: fixtureTimestamp + 3_600
        ),
        ConferenceSwarmCapabilityGrant(
            grantID: "grant.swarm.hostedbuyer-security.vendor",
            granteeEntityRef: "entity.swarm.hostedbuyer.security",
            opportunityID: "opportunity.swarm.vendor-security.enterprise",
            capabilities: [.matchPurpose, .discloseContext, .requestIntro],
            issuedAt: fixtureTimestamp - 60,
            expiresAt: fixtureTimestamp + 3_600
        ),
        ConferenceSwarmCapabilityGrant(
            grantID: "grant.swarm.press-roadmap.briefing",
            granteeEntityRef: "entity.swarm.press.roadmap",
            opportunityID: "opportunity.swarm.press-briefing.roadmap",
            capabilities: [.matchPurpose, .discloseContext, .requestIntro],
            issuedAt: fixtureTimestamp - 60,
            expiresAt: fixtureTimestamp + 3_600
        ),
        ConferenceSwarmCapabilityGrant(
            grantID: "grant.swarm.accessible-attendee.session",
            granteeEntityRef: "entity.swarm.attendee.accessibility",
            opportunityID: "opportunity.swarm.accessible-session.captioned",
            capabilities: [.matchPurpose, .discloseContext],
            issuedAt: fixtureTimestamp - 60,
            expiresAt: fixtureTimestamp + 3_600
        ),
        ConferenceSwarmCapabilityGrant(
            grantID: "grant.swarm.founder-optout.roundtable",
            granteeEntityRef: "entity.swarm.founder.optout",
            opportunityID: "opportunity.swarm.founder-roundtable.safe",
            capabilities: [.matchPurpose, .discloseContext, .requestIntro],
            issuedAt: fixtureTimestamp - 60,
            expiresAt: fixtureTimestamp + 3_600
        ),
        ConferenceSwarmCapabilityGrant(
            grantID: "grant.swarm.remote-community.peer-table",
            granteeEntityRef: "entity.swarm.remote.community",
            opportunityID: "opportunity.swarm.quiet-peer-table",
            capabilities: [.matchPurpose, .discloseContext, .requestIntro],
            issuedAt: fixtureTimestamp - 60,
            expiresAt: fixtureTimestamp + 3_600
        )
    ]

    static let conferenceSwarmCases: [ConferenceSwarmCase] = [
        ConferenceSwarmCase(
            caseID: "swarm.attendee-ai-nb",
            requesterRef: "entity.swarm.attendee.ai-nb",
            expectedOpportunityID: "opportunity.swarm.speaker-dinner.nb"
        ),
        ConferenceSwarmCase(
            caseID: "swarm.hostedbuyer-security",
            requesterRef: "entity.swarm.hostedbuyer.security",
            expectedOpportunityID: "opportunity.swarm.vendor-security.enterprise"
        ),
        ConferenceSwarmCase(
            caseID: "swarm.press-roadmap",
            requesterRef: "entity.swarm.press.roadmap",
            expectedOpportunityID: "opportunity.swarm.press-briefing.roadmap"
        ),
        ConferenceSwarmCase(
            caseID: "swarm.accessible-attendee",
            requesterRef: "entity.swarm.attendee.accessibility",
            expectedOpportunityID: "opportunity.swarm.accessible-session.captioned"
        ),
        ConferenceSwarmCase(
            caseID: "swarm.founder-optout",
            requesterRef: "entity.swarm.founder.optout",
            expectedOpportunityID: "opportunity.swarm.founder-roundtable.safe"
        ),
        ConferenceSwarmCase(
            caseID: "swarm.remote-community",
            requesterRef: "entity.swarm.remote.community",
            expectedOpportunityID: "opportunity.swarm.quiet-peer-table"
        )
    ]

    static let conferenceSwarmForbiddenVariableKeys: Set<String> = [
        "birthDate",
        "calendarURL",
        "email",
        "fullName",
        "legalName",
        "medicalNote",
        "passport",
        "personNumber",
        "phone",
        "preciseLocation",
        "profileURL",
        "rawCalendar"
    ]

    static let conferenceSwarmAllowedMatchingVariableKeys: Set<String> = [
        "accessibility.captioning",
        "accessibility.stepFree",
        "allowedTopic",
        "budgetRange",
        "companySize",
        "consent.commercial",
        "consent.intros",
        "consent.social",
        "conversationMode",
        "distanceTolerance",
        "embargoAccepted",
        "energy.level",
        "language",
        "procurementWindow",
        "role",
        "stage",
        "timeWindow",
        "topic.ai",
        "topic.security",
        "trust.bucket"
    ]

    static func resolveConferenceSwarmCase(
        _ testCase: ConferenceSwarmCase,
        grants explicitGrants: [ConferenceSwarmCapabilityGrant]? = nil
    ) async throws -> ConferenceSwarmCaseResult {
        guard let requester = conferenceSwarmEntities.first(where: { $0.entityRef == testCase.requesterRef }) else {
            throw ConferenceSwarmError.missingRequester(testCase.requesterRef)
        }
        let grants = explicitGrants ?? conferenceSwarmCapabilityGrants

        let candidateRelevantOpportunities = conferenceSwarmOpportunities.filter { opportunity in
            !Set(opportunity.interestWeights.keys).isDisjoint(with: Set(requester.interestWeights.keys))
        }
        let carriedLocalVariables = minimizedVariables(for: requester, opportunities: candidateRelevantOpportunities)
        let rawRankings = try await conferenceSwarmRawRankings(
            requester: requester,
            carriedLocalVariables: carriedLocalVariables
        )

        let rawTopOpportunityID = rawRankings.first?.opportunity.opportunityID
        var acceptedRankings = [ConferenceSwarmAcceptedCandidate]()
        var rejectedCandidates = [ConferenceSwarmRejectedCandidate]()

        for ranking in rawRankings where ranking.score > 0.0 {
            let decision = evaluateSwarmCandidate(
                ranking: ranking,
                requester: requester,
                carriedLocalVariables: carriedLocalVariables,
                grants: grants
            )
            if let accepted = decision.accepted {
                acceptedRankings.append(accepted)
            } else {
                rejectedCandidates.append(
                    ConferenceSwarmRejectedCandidate(
                        opportunityID: ranking.opportunity.opportunityID,
                        reasons: decision.reasons,
                        privacyViolations: decision.privacyViolations
                    )
                )
            }
        }

        let selected = acceptedRankings.first
        let finalRankOfExpected = acceptedRankings.firstIndex {
            $0.opportunity.opportunityID == testCase.expectedOpportunityID
        }.map { $0 + 1 }
        let selectedCompositionResult = selected?.compositionResult

        return ConferenceSwarmCaseResult(
            caseID: testCase.caseID,
            requesterRef: requester.entityRef,
            expectedOpportunityID: testCase.expectedOpportunityID,
            rawTopOpportunityID: rawTopOpportunityID,
            selectedOpportunityID: selected?.opportunity.opportunityID,
            selectedEntityRef: selected?.opportunity.entityRef,
            selectedPurposeID: selected?.opportunity.purposeID,
            authorizationGrantID: selected?.authorizationGrantID,
            selectedScore: selected?.score ?? 0.0,
            finalRankOfExpected: finalRankOfExpected,
            matchedInterestRefs: selected?.matchedInterestRefs ?? [],
            carriedLocalVariables: carriedLocalVariables,
            disclosedVariableKeys: selected?.disclosedVariableKeys ?? [],
            rawRankingCount: rawRankings.count,
            acceptedRankingCount: acceptedRankings.count,
            rejectedCandidates: rejectedCandidates,
            compositionStatus: selectedCompositionResult?.status ?? .unsatisfied,
            compositionScore: selectedCompositionResult?.score ?? 0.0
        )
    }

    static func evaluateConferenceSwarm(
        iterations: Int = 1,
        grants explicitGrants: [ConferenceSwarmCapabilityGrant]? = nil
    ) async throws -> ConferenceSwarmEvaluationSummary {
        let safeIterations = max(1, iterations)
        let grants = explicitGrants ?? conferenceSwarmCapabilityGrants
        let started = DispatchTime.now().uptimeNanoseconds
        var finalResults = [ConferenceSwarmCaseResult]()

        for iteration in 0..<safeIterations {
            var iterationResults = [ConferenceSwarmCaseResult]()
            for testCase in conferenceSwarmCases {
                iterationResults.append(try await resolveConferenceSwarmCase(testCase, grants: grants))
            }
            if iteration == safeIterations - 1 {
                finalResults = iterationResults
            }
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let reciprocalRanks = finalResults.map { result -> Double in
            guard let rank = result.finalRankOfExpected else {
                return 0.0
            }
            return 1.0 / Double(rank)
        }
        let privacyViolations = finalResults.flatMap { result in
            result.rejectedCandidates.flatMap(\.privacyViolations)
        }
        let rejectedPrivacyOpportunityIDs = finalResults.flatMap { result in
            result.rejectedCandidates
                .filter { !$0.privacyViolations.isEmpty }
                .map(\.opportunityID)
        }
        let capabilityRejectedOpportunityIDs = finalResults.flatMap { result in
            result.rejectedCandidates
                .filter { $0.reasons.contains(.capabilityRequirementFailed) }
                .map(\.opportunityID)
        }

        return ConferenceSwarmEvaluationSummary(
            caseCount: finalResults.count,
            top1Correct: finalResults.filter { $0.selectedOpportunityID == $0.expectedOpportunityID }.count,
            top3Correct: finalResults.filter { ($0.finalRankOfExpected ?? Int.max) <= 3 }.count,
            meanReciprocalRank: stableNumber(
                reciprocalRanks.reduce(0.0, +) / Double(max(1, reciprocalRanks.count))
            ),
            privacyViolationCount: privacyViolations.count,
            rejectedPrivacyOpportunityIDs: Array(Set(rejectedPrivacyOpportunityIDs)),
            capabilityRejectedOpportunityIDs: Array(Set(capabilityRejectedOpportunityIDs)),
            totalElapsedNanoseconds: elapsed,
            averageNanosecondsPerCase: Double(elapsed) / Double(max(1, safeIterations * conferenceSwarmCases.count)),
            caseResults: finalResults
        )
    }

    static func conferenceSwarmPrivacyViolations(
        in result: ConferenceSwarmCaseResult
    ) -> [ConferenceSwarmPrivacyViolation] {
        result.rejectedCandidates.flatMap(\.privacyViolations)
    }

    static func buildConferenceSwarmReport(
        format: ScenarioBenchmarkReportFormat,
        iterations: Int = 100
    ) async throws -> String {
        let summary = try await evaluateConferenceSwarm(iterations: iterations)
        return try renderConferenceSwarmReport(summary, format: format)
    }

    static func renderConferenceSwarmReport(
        _ summary: ConferenceSwarmEvaluationSummary,
        format: ScenarioBenchmarkReportFormat
    ) throws -> String {
        switch format {
        case .json:
            return try conferenceSwarmJSON(summary)
        case .markdown:
            return markdownConferenceSwarmReport(summary)
        }
    }

    static func markdownConferenceSwarmReport(_ summary: ConferenceSwarmEvaluationSummary) -> String {
        var lines = [
            "# Conference Swarm Signal Matching",
            "",
            "- Cases: `\(summary.caseCount)`",
            "- Top-1 correct: `\(summary.top1Correct)/\(summary.caseCount)`",
            "- Top-3 correct: `\(summary.top3Correct)/\(summary.caseCount)`",
            "- Mean reciprocal rank: `\(swarmFormatted(summary.meanReciprocalRank))`",
            "- Average runtime per case: `\(swarmFormattedNanoseconds(summary.averageNanosecondsPerCase))`",
            "- Privacy violations rejected: `\(summary.privacyViolationCount)`",
            "- Privacy-rejected opportunities: `\(swarmJoinedIDs(summary.rejectedPrivacyOpportunityIDs))`",
            "- Capability-rejected opportunities: `\(swarmJoinedIDs(summary.capabilityRejectedOpportunityIDs))`",
            "",
            "| Case | Raw top | Selected | Grant | Score | Disclosed keys |",
            "| --- | --- | --- | --- | ---: | --- |"
        ]

        for result in summary.caseResults {
            lines.append(
                "| `\(result.caseID)` | `\(result.rawTopOpportunityID ?? "nil")` | `\(result.selectedOpportunityID ?? "nil")` | `\(result.authorizationGrantID ?? "nil")` | `\(swarmFormatted(result.selectedScore))` | `\(result.disclosedVariableKeys.joined(separator: ", "))` |"
            )
        }

        lines.append("")
        lines.append("The fixture is deterministic; timing fields are measurements and should not be used as hard pass/fail thresholds.")
        lines.append("Rejected privacy/capability candidates are expected success paths when a candidate asks for PII or lacks an active grant.")
        return lines.joined(separator: "\n")
    }
}

public enum ConferenceSwarmError: Error {
    case missingRequester(String)
}

private struct ConferenceSwarmRawRanking {
    var opportunity: ConferenceSwarmOpportunity
    var score: Double
    var matchedInterestRefs: [String]
}

private struct ConferenceSwarmAcceptedCandidate {
    var opportunity: ConferenceSwarmOpportunity
    var score: Double
    var matchedInterestRefs: [String]
    var disclosedVariableKeys: [String]
    var authorizationGrantID: String
    var compositionResult: PurposeCompositionEvaluation
}

private struct ConferenceSwarmCandidateDecision {
    var accepted: ConferenceSwarmAcceptedCandidate?
    var reasons: [ConferenceSwarmRejectionReason]
    var privacyViolations: [ConferenceSwarmPrivacyViolation]
}

private extension PerspectiveMatchingScenarioSupport {
    static func conferenceSwarmRawRankings(
        requester: ConferenceSwarmEntity,
        carriedLocalVariables: [String: String]
    ) async throws -> [ConferenceSwarmRawRanking] {
        let purposeNodes = Dictionary(
            uniqueKeysWithValues: conferenceSwarmOpportunities.map { opportunity in
                (
                    opportunity.matchPurposeID,
                    Purpose(
                        name: opportunity.matchPurposeID,
                        description: opportunity.description
                    )
                )
            }
        )
        var purposeEdgesByInterest = [String: [Weight<Purpose>]]()

        for opportunity in conferenceSwarmOpportunities {
            guard let purpose = purposeNodes[opportunity.matchPurposeID] else { continue }
            for (interestID, opportunityWeight) in opportunity.interestWeights
                where requester.interestWeights[interestID] != nil {
                purposeEdgesByInterest[interestID, default: []].append(
                    Weight<Purpose>(weight: opportunityWeight, value: purpose)
                )
            }
        }

        let runtime = WeightedGraphRuntime()
        let configuration = WeightedGraphRuntimeConfiguration(
            relationships: [.purposes],
            maxHops: 1,
            ttl: 5.0,
            maxHits: Int.max,
            minScore: 0.0,
            localVariables: object(from: carriedLocalVariables)
        )
        var scoresByMatchPurposeID = [String: Double]()
        var matchedInterestsByMatchPurposeID = [String: Set<String>]()

        for (interestID, requesterWeight) in requester.interestWeights.sorted(by: { $0.key < $1.key }) {
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
                token: "conference.swarm.\(requester.entityRef).\(interestID)",
                ttl: 5.0,
                hops: 1,
                localVariables: object(from: carriedLocalVariables)
            )
            let result = try await runtime.match(
                start: interest,
                signal: signal,
                configuration: configuration
            )

            for hit in result.hits where hit.node.kind == .purpose {
                let opportunityWeight = hit.evidence.last(where: { $0.relationship == .purposes })?.edgeWeight ?? 0.0
                scoresByMatchPurposeID[hit.ref, default: 0.0] += requesterWeight * opportunityWeight
                matchedInterestsByMatchPurposeID[hit.ref, default: []].insert(interestID)
            }
        }

        return conferenceSwarmOpportunities.map { opportunity in
            ConferenceSwarmRawRanking(
                opportunity: opportunity,
                score: scoresByMatchPurposeID[opportunity.matchPurposeID] ?? 0.0,
                matchedInterestRefs: Array(matchedInterestsByMatchPurposeID[opportunity.matchPurposeID] ?? []).sorted()
            )
        }
        .sorted {
            if $0.score == $1.score {
                return $0.opportunity.opportunityID < $1.opportunity.opportunityID
            }
            return $0.score > $1.score
        }
    }

    static func evaluateSwarmCandidate(
        ranking: ConferenceSwarmRawRanking,
        requester: ConferenceSwarmEntity,
        carriedLocalVariables: [String: String],
        grants: [ConferenceSwarmCapabilityGrant]
    ) -> ConferenceSwarmCandidateDecision {
        let opportunity = ranking.opportunity
        let privacyViolations = privacyViolations(for: opportunity)
        let candidateVariables = conferenceSwarmCandidateVariables[opportunity.entityRef] ?? [:]
        let grant = activeGrant(
            for: requester,
            opportunity: opportunity,
            grants: grants
        )
        let contextSatisfied = opportunity.requirements.allSatisfy { requirement in
            switch requirement.scope {
            case .requester:
                return carriedLocalVariables[requirement.key] == requirement.expectedValue
            case .candidate:
                return candidateVariables[requirement.key] == requirement.expectedValue
            }
        }
        let privacySatisfied = privacyViolations.isEmpty
        let capabilitySatisfied = grant != nil
        let compositionResult = purposeCompositionResult(
            opportunityID: opportunity.opportunityID,
            contextSatisfied: contextSatisfied,
            privacySatisfied: privacySatisfied,
            capabilitySatisfied: capabilitySatisfied
        )

        guard contextSatisfied, privacySatisfied, let authorizationGrant = grant, compositionResult.isSatisfied else {
            var reasons = [ConferenceSwarmRejectionReason]()
            if !contextSatisfied {
                reasons.append(.contextRequirementFailed)
            }
            if !privacySatisfied {
                reasons.append(.privacyRequirementFailed)
            }
            if contextSatisfied && privacySatisfied && !capabilitySatisfied {
                reasons.append(.capabilityRequirementFailed)
            }
            return ConferenceSwarmCandidateDecision(
                accepted: nil,
                reasons: reasons,
                privacyViolations: privacyViolations
            )
        }

        let disclosedVariableKeys = opportunity.requirements
            .filter { $0.scope == .requester }
            .map(\.key)
            .sorted()

        return ConferenceSwarmCandidateDecision(
            accepted: ConferenceSwarmAcceptedCandidate(
                opportunity: opportunity,
                score: ranking.score,
                matchedInterestRefs: ranking.matchedInterestRefs,
                disclosedVariableKeys: disclosedVariableKeys,
                authorizationGrantID: authorizationGrant.grantID,
                compositionResult: compositionResult
            ),
            reasons: [],
            privacyViolations: []
        )
    }

    static func purposeCompositionResult(
        opportunityID: String,
        contextSatisfied: Bool,
        privacySatisfied: Bool,
        capabilitySatisfied: Bool
    ) -> PurposeCompositionEvaluation {
        let composition = PurposeComposition.allOf([
            .leaf("purpose.swarm.\(opportunityID).weighted-match"),
            .leaf("purpose.swarm.\(opportunityID).context-satisfied"),
            .leaf("purpose.swarm.\(opportunityID).privacy-satisfied"),
            .leaf("purpose.swarm.\(opportunityID).capability-satisfied")
        ])
        var resolutions = [
            PurposeResolutionRecord(
                purposeRef: "purpose.swarm.\(opportunityID).weighted-match",
                resolvedAt: fixtureTimestamp
            )
        ]
        if contextSatisfied {
            resolutions.append(
                PurposeResolutionRecord(
                    purposeRef: "purpose.swarm.\(opportunityID).context-satisfied",
                    resolvedAt: fixtureTimestamp + 1
                )
            )
        }
        if privacySatisfied {
            resolutions.append(
                PurposeResolutionRecord(
                    purposeRef: "purpose.swarm.\(opportunityID).privacy-satisfied",
                    resolvedAt: fixtureTimestamp + 2
                )
            )
        }
        if capabilitySatisfied {
            resolutions.append(
                PurposeResolutionRecord(
                    purposeRef: "purpose.swarm.\(opportunityID).capability-satisfied",
                    resolvedAt: fixtureTimestamp + 3
                )
            )
        }
        return composition.evaluate(
            in: PurposeCompositionEvaluationContext(
                evaluatedAt: fixtureTimestamp + 4,
                purposeResolutions: resolutions
            )
        )
    }

    static func activeGrant(
        for requester: ConferenceSwarmEntity,
        opportunity: ConferenceSwarmOpportunity,
        grants: [ConferenceSwarmCapabilityGrant]
    ) -> ConferenceSwarmCapabilityGrant? {
        let requiredCapabilities: Set<ConferenceSwarmCapability> = [.matchPurpose, .discloseContext]
        return grants.first { grant in
            grant.granteeEntityRef == requester.entityRef &&
                grant.opportunityID == opportunity.opportunityID &&
                grant.isActive(at: fixtureTimestamp) &&
                requiredCapabilities.isSubset(of: Set(grant.capabilities))
        }
    }

    static func privacyViolations(
        for opportunity: ConferenceSwarmOpportunity
    ) -> [ConferenceSwarmPrivacyViolation] {
        var violations = [ConferenceSwarmPrivacyViolation]()
        for requirement in opportunity.requirements {
            if conferenceSwarmForbiddenVariableKeys.contains(requirement.key) {
                violations.append(
                    ConferenceSwarmPrivacyViolation(
                        opportunityID: opportunity.opportunityID,
                        scope: requirement.scope,
                        key: requirement.key,
                        reason: "forbidden_pii_key"
                    )
                )
            }
            if requirement.scope == .requester &&
                !opportunity.allowedDisclosureKeys.contains(requirement.key) {
                violations.append(
                    ConferenceSwarmPrivacyViolation(
                        opportunityID: opportunity.opportunityID,
                        scope: requirement.scope,
                        key: requirement.key,
                        reason: "not_in_allowed_disclosure_keys"
                    )
                )
            }
        }
        for key in opportunity.allowedDisclosureKeys where conferenceSwarmForbiddenVariableKeys.contains(key) {
            violations.append(
                ConferenceSwarmPrivacyViolation(
                    opportunityID: opportunity.opportunityID,
                    scope: .requester,
                    key: key,
                    reason: "allowed_disclosure_contains_pii"
                )
            )
        }
        return violations
    }

    static func minimizedVariables(
        for requester: ConferenceSwarmEntity,
        opportunities: [ConferenceSwarmOpportunity]
    ) -> [String: String] {
        let requiredRequesterKeys = Set(
            opportunities.flatMap { opportunity in
                opportunity.requirements
                    .filter { $0.scope == .requester }
                    .map(\.key)
            }
        )
        let allowedKeys = requiredRequesterKeys
            .intersection(conferenceSwarmAllowedMatchingVariableKeys)
            .subtracting(conferenceSwarmForbiddenVariableKeys)

        return Dictionary(
            uniqueKeysWithValues: requester.shareableVariables
                .filter { key, _ in allowedKeys.contains(key) }
                .sorted { $0.key < $1.key }
                .map { key, value in (key, value) }
        )
    }

    static func object(from variables: [String: String]) -> Object {
        Dictionary(uniqueKeysWithValues: variables.map { key, value in
            (key, ValueType.string(value))
        })
    }

    static func stableNumber(_ value: Double, decimals: Int = 12) -> Double {
        let factor = pow(10.0, Double(decimals))
        return (value * factor).rounded() / factor
    }

    static func conferenceSwarmJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func swarmFormatted(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    static func swarmFormattedNanoseconds(_ value: Double) -> String {
        if value < 1_000.0 {
            return String(format: "%.0f ns", value)
        }
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

    static func swarmJoinedIDs(_ values: [String]) -> String {
        values.isEmpty ? "none" : values.joined(separator: ", ")
    }
}
