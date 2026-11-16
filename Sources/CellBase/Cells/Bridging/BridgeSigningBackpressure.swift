// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A proof request was rate limited before the protected operation could run.
/// Retrying requires a fresh operation and all ordinary authorization checks.
public struct BridgeSigningBackpressure: Error, Equatable, Sendable {
    public let retryAfterSeconds: Int
    /// Why signing must wait: the rate limit or a temporary bridge quarantine.
    /// The wire reasonCode stays `signing_rate_limited` so older clients still
    /// recognise the retry; the cause travels in its own field.
    public let cause: String

    public init(retryAfterSeconds: Int, cause: String = CellSecurityReasonCode.signingRateLimited) {
        self.retryAfterSeconds = max(1, retryAfterSeconds)
        self.cause = cause
    }

    // An application rejection remains an error for older clients. This marker
    // is emitted only at a known pre-effect authorization rejection boundary.
    var rejection: ValueType {
        .object(["status": .string("error"), "message": .string("signingTemporarilyUnavailable"),
                 "&bridgeRetry": .string("signing_before_effect.v1"),
                 "reasonCode": .string("signing_rate_limited"),
                 "cause": .string(cause),
                 "retryAfterSeconds": .integer(retryAfterSeconds)])
    }

    static func rejection(_ value: ValueType?) -> Self? {
        guard case .object(let fields)? = value,
              fields["status"] == .string("error"),
              fields["&bridgeRetry"] == .string("signing_before_effect.v1"),
              fields["reasonCode"] == .string("signing_rate_limited") else { return nil }
        let seconds: Int
        switch fields["retryAfterSeconds"] {
        case .integer(let n)?, .number(let n)?: seconds = n
        default: return nil
        }
        guard seconds > 0 else { return nil }
        if case .string(let cause)? = fields["cause"] {
            return Self(retryAfterSeconds: seconds, cause: cause)
        }
        return Self(retryAfterSeconds: seconds)
    }
}

/// A refusal the bridge reports as data instead of a free-text failure: why, and
/// how long to wait when that is known. It does not invite an automatic replay;
/// only `BridgeSigningBackpressure` at an audited pre-effect gate does that.
public struct BridgeRefusal: Error, Equatable, Sendable {
    public static let marker = "refusal.v1"
    public let reasonCode: String
    public let message: String
    public let retryAfterSeconds: Int?

    public init(reasonCode: String, message: String, retryAfterSeconds: Int? = nil) {
        self.reasonCode = reasonCode
        self.message = message
        self.retryAfterSeconds = retryAfterSeconds.map { max(1, $0) }
    }

    public var value: ValueType {
        var fields: Object = ["status": .string("error"), "&bridgeRefusal": .string(Self.marker),
                              "reasonCode": .string(reasonCode), "message": .string(message)]
        if let retryAfterSeconds { fields["retryAfterSeconds"] = .integer(retryAfterSeconds) }
        return .object(fields)
    }

    /// Reads a refusal in any shape a bridge has sent: this object, the audited
    /// signing retry object, or the legacy `failure: …` text. Anything else is
    /// an ordinary value and returns nil.
    public static func parse(_ value: ValueType?) -> BridgeRefusal? {
        if let retry = BridgeSigningBackpressure.rejection(value) {
            return BridgeRefusal(reasonCode: retry.cause, message: "signingTemporarilyUnavailable",
                                 retryAfterSeconds: retry.retryAfterSeconds)
        }
        switch value {
        case .object(let fields)?:
            guard fields["status"] == .string("error"),
                  fields["&bridgeRefusal"] == .string(marker),
                  case .string(let code)? = fields["reasonCode"] else { return nil }
            let message: String
            if case .string(let text)? = fields["message"] { message = text } else { message = "" }
            var seconds: Int?
            switch fields["retryAfterSeconds"] {
            case .integer(let n)?, .number(let n)?: seconds = n > 0 ? n : nil
            default: seconds = nil
            }
            return BridgeRefusal(reasonCode: code, message: message, retryAfterSeconds: seconds)
        case .string(let text)?:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("failure:") else { return nil }
            let message = String(trimmed.dropFirst("failure:".count)).trimmingCharacters(in: .whitespaces)
            return BridgeRefusal(reasonCode: "failure", message: message)
        default:
            return nil
        }
    }

    /// The legacy text older consumers of `get` already recognise.
    public var legacyFailureText: ValueType { .string("failure: \(message)") }
}

/// Each inbound command gets its own proxy and its own diagnostic state.
/// This is not proof reuse, permission, or a bridge-wide mutable error slot.
final class BridgeSigningAttemptState: @unchecked Sendable {
    private let lock = NSLock()
    private var retryDeadline: Date?

    func record(_ error: BridgeSigningBackpressure) {
        lock.withLock { retryDeadline = Date().addingTimeInterval(TimeInterval(error.retryAfterSeconds)) }
    }

    var backpressure: BridgeSigningBackpressure? {
        lock.withLock {
            retryDeadline.map { .init(retryAfterSeconds: max(1, Int(ceil($0.timeIntervalSinceNow)))) }
        }
    }
}

/// An audited Correspondence gate rejected this exact receiver and operation.
/// A child rejection must not invite replay of a parent that already ran.
struct BridgePreEffectSigningRejection: Error, @unchecked Sendable {
    let sourceID: ObjectIdentifier
    let keypath: String
    let retry: BridgeSigningBackpressure

    init(source: CorrespondenceCell, keypath: String, retry: BridgeSigningBackpressure) {
        sourceID = ObjectIdentifier(source)
        self.keypath = keypath
        self.retry = retry
    }

    func matches(_ publisher: any Meddle, keypath: String) -> Bool {
        guard let cell = publisher as? CorrespondenceCell else { return false }
        return sourceID == ObjectIdentifier(cell) && self.keypath == keypath
    }
}
