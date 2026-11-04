// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Transient client state, never a persistence or learning journal. Unknown
/// transport outcomes retain their original ID; completed submissions do not.
public struct OriginalUserActionLedger {
    public struct Submission {
        public let id: String
        public let payload: ValueType
        fileprivate let key: String
    }
    public enum Failure: Error { case pendingCapacity, invalidIdentity }
    private struct Pending {
        let fingerprint: Data
        let submission: Submission
    }
    private var pending: [String: Pending] = [:]
    public init() {}

    public static func canonicalOperation(_ keypath: String) -> String? {
        var key = keypath
        if key.hasPrefix("cell://"), let url = URL(string: key) {
            key = url.lastPathComponent
        }
        if key.hasPrefix("chatHub.") { key = String(key.dropFirst("chatHub.".count)) }
        return ["prompt.submit", "assistant.analyzeDraft", "assistant.answerClarification"].contains(key) ? key : nil
    }

    public mutating func prepare(keypath: String, scope: String, payload: ValueType?,
                                 newID: String = UUID().uuidString,
                                 occurredAt: TimeInterval = Date().timeIntervalSince1970) throws -> Submission? {
        guard let operation = Self.canonicalOperation(keypath), let payload else { return nil }
        var object: Object
        switch payload {
        case let .object(value): object = value
        case let .string(value): object = ["text": .string(value)]
        default: return nil
        }
        let explicitID: String?
        if let supplied = object.removeValue(forKey: "userActionID") {
            guard case let .string(id) = supplied, !id.isEmpty, id.utf8.count <= 128 else { throw Failure.invalidIdentity }
            explicitID = id
        } else { explicitID = nil }
        let suppliedTime = object.removeValue(forKey: "userActionOccurredAt")
        if let suppliedTime {
            let time: Double
            switch suppliedTime {
            case let .float(value): time = value
            case let .number(value), let .integer(value): time = Double(value)
            default: throw Failure.invalidIdentity
            }
            guard time.isFinite else { throw Failure.invalidIdentity }
        }
        var semantic = object
        if operation != "assistant.answerClarification" {
            // Button payloads use the draft object; Enter sends the same text.
            // These aliases have the same precedence as the submit receiver.
            let text = ["draft", "body", "text", "prompt"].compactMap { key -> String? in
                guard case let .string(value)? = object[key] else { return nil }
                return value
            }.first
            if let text {
                for key in ["draft", "body", "text", "prompt"] { semantic.removeValue(forKey: key) }
                semantic["text"] = .string(text)
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fingerprint = try encoder.encode(semantic)
        let key = "\(scope.utf8.count):\(scope)\(operation)|\(FlowHasher.sha256Hex(fingerprint))"
        if let old = pending[key], old.fingerprint == fingerprint,
           explicitID == nil || explicitID == old.submission.id {
            return old.submission
        }
        guard pending[key] != nil || pending.count < 64 else { throw Failure.pendingCapacity }
        let id = explicitID ?? newID
        guard !id.isEmpty, id.utf8.count <= 128, occurredAt.isFinite else { throw Failure.invalidIdentity }
        object["userActionID"] = .string(id)
        object["userActionOccurredAt"] = suppliedTime ?? .float(occurredAt)
        let submission = Submission(id: id, payload: .object(object), key: key)
        pending[key] = Pending(fingerprint: fingerprint, submission: submission)
        return submission
    }

    public mutating func complete(_ submission: Submission) {
        guard pending[submission.key]?.submission.id == submission.id else { return }
        pending.removeValue(forKey: submission.key)
    }
}
