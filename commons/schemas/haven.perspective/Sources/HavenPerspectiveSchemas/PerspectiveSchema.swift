// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct PerspectiveDocument: Codable, Hashable, Sendable {
    public var pre: PerspectiveSnapshot
    public var during: PerspectiveSnapshot
    public var post: PerspectiveSnapshot

    public init(pre: PerspectiveSnapshot, during: PerspectiveSnapshot, post: PerspectiveSnapshot) {
        self.pre = pre
        self.during = during
        self.post = post
    }
}

public struct PerspectiveSnapshot: Codable, Hashable, Sendable {
    public struct PerspectiveGoal: Codable, Hashable, Sendable {
        public var goalID: String
        public var purposeID: String?
        public var description: String
        public var metric: String?
        public var baseline: String?
        public var target: String?
        public var timeframe: String?
        public var dataSource: String?
        public var evidenceRule: String?
        public var indicatorRefs: [String]
        public var incentiveOnly: Bool

        public init(
            goalID: String,
            purposeID: String? = nil,
            description: String,
            metric: String? = nil,
            baseline: String? = nil,
            target: String? = nil,
            timeframe: String? = nil,
            dataSource: String? = nil,
            evidenceRule: String? = nil,
            indicatorRefs: [String] = [],
            incentiveOnly: Bool = true
        ) {
            self.goalID = goalID
            self.purposeID = purposeID
            self.description = description
            self.metric = metric
            self.baseline = baseline
            self.target = target
            self.timeframe = timeframe
            self.dataSource = dataSource
            self.evidenceRule = evidenceRule
            self.indicatorRefs = indicatorRefs
            self.incentiveOnly = incentiveOnly
        }

        enum CodingKeys: String, CodingKey {
            case goalID = "goal_id"
            case purposeID = "purpose_id"
            case description
            case metric
            case baseline
            case target
            case timeframe
            case dataSource = "data_source"
            case evidenceRule = "evidence_rule"
            case indicatorRefs = "indicator_refs"
            case incentiveOnly = "incentive_only"
        }
    }

    public var purposes: [String]
    public var goals: [PerspectiveGoal]
    public var interests: [String]
    public var constraints: [String]
    public var visibilityPolicyRef: String?

    public init(
        purposes: [String] = [],
        goals: [PerspectiveGoal] = [],
        interests: [String] = [],
        constraints: [String] = [],
        visibilityPolicyRef: String? = nil
    ) {
        self.purposes = purposes
        self.goals = goals
        self.interests = interests
        self.constraints = constraints
        self.visibilityPolicyRef = visibilityPolicyRef
    }

    enum CodingKeys: String, CodingKey {
        case purposes
        case goals
        case interests
        case constraints
        case visibilityPolicyRef = "visibility_policy_ref"
    }
}
