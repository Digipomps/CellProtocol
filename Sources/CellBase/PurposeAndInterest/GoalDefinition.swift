// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum GoalLifecycle: String, Codable, Hashable, Sendable {
    case oneShot = "one-shot"
    case continuous
    case deadline
    case untilCancelled = "until-cancelled"
}

public enum GoalEvaluatorKind: String, Codable, Hashable, Sendable {
    case statePredicate = "state-predicate"
    case eventPredicate = "event-predicate"
    case humanConfirmation = "human-confirmation"
    case semanticLocation = "semantic-location"
    case semanticTime = "semantic-time"
    case networkPing = "network-ping"
    case contractProbe = "contract-probe"
    case guiSmoke = "gui-smoke"
    case composite
    case custom
}

public enum GoalStatus: String, Codable, Hashable, Sendable {
    case unknown
    case notStarted = "not-started"
    case approaching
    case active
    case satisfied
    case atRisk = "at-risk"
    case missed
    case blocked
    case cancelled
}

public enum GoalEvidenceStatus: String, Codable, Hashable, Sendable {
    case fresh
    case stale
    case missing
    case denied
    case error
}

public enum GoalEvidenceVisibility: String, Codable, Hashable, Sendable {
    case ownerOnly = "owner-only"
    case requesterScoped = "requester-scoped"
    case statusOnly = "status-only"
    case publishable
}

public struct GoalEvidenceSource: Codable, Hashable, Sendable {
    public var sourceID: String
    public var endpoint: String?
    public var keypath: String?
    public var topic: String?
    public var eventType: String?
    public var requiredGrant: String?
    public var freshnessSeconds: Int?
    public var visibility: GoalEvidenceVisibility
    public var summary: String?

    public init(
        sourceID: String,
        endpoint: String? = nil,
        keypath: String? = nil,
        topic: String? = nil,
        eventType: String? = nil,
        requiredGrant: String? = nil,
        freshnessSeconds: Int? = nil,
        visibility: GoalEvidenceVisibility = .ownerOnly,
        summary: String? = nil
    ) {
        self.sourceID = sourceID
        self.endpoint = endpoint
        self.keypath = keypath
        self.topic = topic
        self.eventType = eventType
        self.requiredGrant = requiredGrant
        self.freshnessSeconds = freshnessSeconds
        self.visibility = visibility
        self.summary = summary
    }
}

public struct GoalPredicate: Codable, Hashable, Sendable {
    public var kind: String
    public var sourceID: String?
    public var keypath: String?
    public var operation: String?
    public var expected: String?
    public var metric: String?
    public var all: [GoalPredicate]
    public var any: [GoalPredicate]

    public init(
        kind: String,
        sourceID: String? = nil,
        keypath: String? = nil,
        operation: String? = nil,
        expected: String? = nil,
        metric: String? = nil,
        all: [GoalPredicate] = [],
        any: [GoalPredicate] = []
    ) {
        self.kind = kind
        self.sourceID = sourceID
        self.keypath = keypath
        self.operation = operation
        self.expected = expected
        self.metric = metric
        self.all = all
        self.any = any
    }
}

public struct GoalTolerance: Codable, Hashable, Sendable {
    public var locationAccuracyMeters: Double?
    public var timeSkewSeconds: Int?
    public var networkTimeoutMilliseconds: Int?
    public var confidenceFloor: Double?

    public init(
        locationAccuracyMeters: Double? = nil,
        timeSkewSeconds: Int? = nil,
        networkTimeoutMilliseconds: Int? = nil,
        confidenceFloor: Double? = nil
    ) {
        self.locationAccuracyMeters = locationAccuracyMeters
        self.timeSkewSeconds = timeSkewSeconds
        self.networkTimeoutMilliseconds = networkTimeoutMilliseconds
        self.confidenceFloor = confidenceFloor
    }
}

public struct GoalStatusPolicy: Codable, Hashable, Sendable {
    public var approachingWindowSeconds: Int?
    public var missedAfterSeconds: Int?
    public var atRiskAfterFailures: Int?
    public var missedAfterFailures: Int?
    public var retryIntervalSeconds: Int?

    public init(
        approachingWindowSeconds: Int? = nil,
        missedAfterSeconds: Int? = nil,
        atRiskAfterFailures: Int? = nil,
        missedAfterFailures: Int? = nil,
        retryIntervalSeconds: Int? = nil
    ) {
        self.approachingWindowSeconds = approachingWindowSeconds
        self.missedAfterSeconds = missedAfterSeconds
        self.atRiskAfterFailures = atRiskAfterFailures
        self.missedAfterFailures = missedAfterFailures
        self.retryIntervalSeconds = retryIntervalSeconds
    }
}

public struct GoalHelperCellRef: Codable, Hashable, Sendable {
    public var endpoint: String
    public var purposeRef: String?
    public var actionKeypath: String?
    public var title: String?

    public init(
        endpoint: String,
        purposeRef: String? = nil,
        actionKeypath: String? = nil,
        title: String? = nil
    ) {
        self.endpoint = endpoint
        self.purposeRef = purposeRef
        self.actionKeypath = actionKeypath
        self.title = title
    }
}

public struct GoalPrivacyPolicy: Codable, Hashable, Sendable {
    public var rawEvidenceVisibility: GoalEvidenceVisibility
    public var publishableStatuses: [GoalStatus]
    public var doNotExportRawLocation: Bool
    public var retentionSeconds: Int?

    public init(
        rawEvidenceVisibility: GoalEvidenceVisibility = .ownerOnly,
        publishableStatuses: [GoalStatus] = [.unknown, .approaching, .active, .satisfied, .atRisk, .missed, .blocked],
        doNotExportRawLocation: Bool = false,
        retentionSeconds: Int? = nil
    ) {
        self.rawEvidenceVisibility = rawEvidenceVisibility
        self.publishableStatuses = publishableStatuses
        self.doNotExportRawLocation = doNotExportRawLocation
        self.retentionSeconds = retentionSeconds
    }
}

public struct GoalDefinition: Codable, Hashable, Sendable {
    public static let schemaID = "haven.goal-definition.v1"

    public var schema: String
    public var goalID: String
    public var purposeRef: String
    public var title: String
    public var description: String
    public var lifecycle: GoalLifecycle
    public var evaluatorKind: GoalEvaluatorKind
    public var metric: String?
    public var baseline: String?
    public var target: String?
    public var timeframe: String?
    public var evidenceSources: [GoalEvidenceSource]
    public var predicate: GoalPredicate?
    public var tolerance: GoalTolerance?
    public var statusPolicy: GoalStatusPolicy?
    public var helperCells: [GoalHelperCellRef]
    public var privacy: GoalPrivacyPolicy
    public var tags: [String]

    public init(
        schema: String = GoalDefinition.schemaID,
        goalID: String,
        purposeRef: String,
        title: String,
        description: String,
        lifecycle: GoalLifecycle,
        evaluatorKind: GoalEvaluatorKind,
        metric: String? = nil,
        baseline: String? = nil,
        target: String? = nil,
        timeframe: String? = nil,
        evidenceSources: [GoalEvidenceSource] = [],
        predicate: GoalPredicate? = nil,
        tolerance: GoalTolerance? = nil,
        statusPolicy: GoalStatusPolicy? = nil,
        helperCells: [GoalHelperCellRef] = [],
        privacy: GoalPrivacyPolicy = GoalPrivacyPolicy(),
        tags: [String] = []
    ) {
        self.schema = schema
        self.goalID = goalID
        self.purposeRef = purposeRef
        self.title = title
        self.description = description
        self.lifecycle = lifecycle
        self.evaluatorKind = evaluatorKind
        self.metric = metric
        self.baseline = baseline
        self.target = target
        self.timeframe = timeframe
        self.evidenceSources = evidenceSources
        self.predicate = predicate
        self.tolerance = tolerance
        self.statusPolicy = statusPolicy
        self.helperCells = helperCells
        self.privacy = privacy
        self.tags = tags
    }

    public static func fromPerspectiveFields(
        goalID: String,
        purposeID: String?,
        description: String,
        metric: String? = nil,
        baseline: String? = nil,
        target: String? = nil,
        timeframe: String? = nil,
        dataSource: String? = nil,
        evidenceRule: String? = nil,
        indicatorRefs: [String] = [],
        incentiveOnly: Bool = true
    ) -> GoalDefinition {
        let sourceID = "perspective-data-source"
        let source = GoalEvidenceSource(
            sourceID: sourceID,
            keypath: dataSource,
            freshnessSeconds: nil,
            visibility: .ownerOnly,
            summary: dataSource.map { "Perspective data source \($0)" }
        )
        let predicate = GoalPredicate(
            kind: "evidence-rule",
            sourceID: sourceID,
            operation: "satisfies",
            expected: evidenceRule ?? target,
            metric: metric
        )
        return GoalDefinition(
            goalID: goalID,
            purposeRef: purposeID ?? "purpose://unknown",
            title: goalID,
            description: description,
            lifecycle: incentiveOnly ? .continuous : .deadline,
            evaluatorKind: .statePredicate,
            metric: metric,
            baseline: baseline,
            target: target,
            timeframe: timeframe,
            evidenceSources: dataSource == nil ? [] : [source],
            predicate: evidenceRule == nil && target == nil ? nil : predicate,
            privacy: GoalPrivacyPolicy(rawEvidenceVisibility: .ownerOnly),
            tags: indicatorRefs
        )
    }
}

public struct GoalEvaluationEvidence: Codable, Hashable, Sendable {
    public var sourceID: String
    public var status: GoalEvidenceStatus
    public var summary: String
    public var observedAt: String?
    public var valueSummary: String?
    public var confidence: Double?

    public init(
        sourceID: String,
        status: GoalEvidenceStatus,
        summary: String,
        observedAt: String? = nil,
        valueSummary: String? = nil,
        confidence: Double? = nil
    ) {
        self.sourceID = sourceID
        self.status = status
        self.summary = summary
        self.observedAt = observedAt
        self.valueSummary = valueSummary
        self.confidence = confidence
    }
}

public struct GoalEvaluation: Codable, Hashable, Sendable {
    public static let schemaID = "haven.goal-evaluation.v1"

    public var schema: String
    public var goalID: String
    public var purposeRef: String
    public var status: GoalStatus
    public var progress: Double
    public var confidence: Double
    public var evaluatedAt: String
    public var evidence: [GoalEvaluationEvidence]
    public var missing: [String]
    public var blockers: [String]
    public var nextCheckAt: String?
    public var emittedEvents: [String]

    public var isSatisfied: Bool {
        status == .satisfied
    }

    public var isTerminal: Bool {
        [.satisfied, .missed, .blocked, .cancelled].contains(status)
    }

    public init(
        schema: String = GoalEvaluation.schemaID,
        goalID: String,
        purposeRef: String,
        status: GoalStatus,
        progress: Double,
        confidence: Double,
        evaluatedAt: String,
        evidence: [GoalEvaluationEvidence] = [],
        missing: [String] = [],
        blockers: [String] = [],
        nextCheckAt: String? = nil,
        emittedEvents: [String] = []
    ) {
        self.schema = schema
        self.goalID = goalID
        self.purposeRef = purposeRef
        self.status = status
        self.progress = progress
        self.confidence = confidence
        self.evaluatedAt = evaluatedAt
        self.evidence = evidence
        self.missing = missing
        self.blockers = blockers
        self.nextCheckAt = nextCheckAt
        self.emittedEvents = emittedEvents
    }
}
