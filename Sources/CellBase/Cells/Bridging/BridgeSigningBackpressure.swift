// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A proof request was rate limited before the protected operation could run.
/// Retrying requires a fresh operation and all ordinary authorization checks.
public struct BridgeSigningBackpressure: Error, Equatable, Sendable {
    public let retryAfterSeconds: Int

    public init(retryAfterSeconds: Int) {
        self.retryAfterSeconds = max(1, retryAfterSeconds)
    }

    // An application rejection remains an error for older clients. This marker
    // is emitted only at a known pre-effect authorization rejection boundary.
    var rejection: ValueType {
        .object(["status": .string("error"), "message": .string("attachmentUnavailable"),
                 "&bridgeRetry": .string("signing_before_effect.v1"),
                 "reasonCode": .string("signing_rate_limited"),
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
        return Self(retryAfterSeconds: seconds)
    }
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
