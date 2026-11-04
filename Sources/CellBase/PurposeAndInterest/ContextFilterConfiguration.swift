// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

public struct ContextFilterConfiguration: Codable, Equatable, Sendable {
    public var perspectiveEndpoint: String
    public var contentEndpoints: [String]
    public var baseTopics: [String]
    /// Each active semantic label adds an intersection constraint.
    public var topicsByLabel: [String: [String]]
    public init(perspectiveEndpoint: String, contentEndpoints: [String], baseTopics: [String], topicsByLabel: [String: [String]] = [:]) {
        self.perspectiveEndpoint = perspectiveEndpoint; self.contentEndpoints = contentEndpoints
        self.baseTopics = baseTopics; self.topicsByLabel = topicsByLabel
    }
    public func permits(topic: String, decision: ContextDecision?, now: Date) -> Bool {
        func matches(_ patterns: [String]) -> Bool {
            patterns.contains { $0 == "*" || $0 == topic || ($0.hasSuffix(".*") && topic.hasPrefix(String($0.dropLast()))) }
        }
        guard matches(baseTopics) else { return false }
        guard let decision, let expiry = decision.validUntil, expiry > now else { return true }
        for label in decision.labels {
            if let topics = topicsByLabel[label], !matches(topics) { return false }
        }
        return true
    }
}
