// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum CellSecurityReplayDecision: Equatable, Sendable {
    case accepted
    case replay
    case expired
    case issuedInFuture
    case missingScope
}

public actor CellSecuritySigningChallengeReplayStore {
    private var consumedChallenges: [String: TimeInterval] = [:]

    public init() {}

    public func consume(
        _ challenge: IdentitySigningChallenge,
        now: Date = Date()
    ) -> CellSecurityReplayDecision {
        purgeExpired(now: now)

        let nowInterval = now.timeIntervalSince1970
        guard challenge.issuedAt <= nowInterval + IdentitySigningChallenge.allowedClockSkew else {
            return .issuedInFuture
        }
        guard challenge.expiresAt >= nowInterval else {
            return .expired
        }
        guard hasCompleteScope(challenge) else {
            return .missingScope
        }

        let key = replayKey(for: challenge)
        guard consumedChallenges[key] == nil else {
            return .replay
        }
        consumedChallenges[key] = challenge.expiresAt
        return .accepted
    }

    public func count(now: Date = Date()) -> Int {
        purgeExpired(now: now)
        return consumedChallenges.count
    }

    public func clear() {
        consumedChallenges.removeAll()
    }

    private func purgeExpired(now: Date) {
        let nowInterval = now.timeIntervalSince1970
        consumedChallenges = consumedChallenges.filter { _, expiresAt in
            expiresAt >= nowInterval
        }
    }

    private func hasCompleteScope(_ challenge: IdentitySigningChallenge) -> Bool {
        challenge.identityUUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && challenge.publicKeyFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && challenge.domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && challenge.resource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && challenge.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && challenge.audience.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && challenge.nonce.isEmpty == false
    }

    private func replayKey(for challenge: IdentitySigningChallenge) -> String {
        [
            challenge.identityUUID,
            challenge.publicKeyFingerprint ?? "",
            challenge.domain,
            challenge.resource,
            challenge.action,
            challenge.audience,
            challenge.nonce.base64EncodedString()
        ].joined(separator: "\u{1F}")
    }
}
