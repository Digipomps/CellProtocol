// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum RelationalDecayProfileKind: String, Codable, Sendable {
    case noaDoubleSigmoid
    case none
}

public struct RelationalNoaDecayParameters: Codable, Hashable, Sendable {
    public var t1Seconds: TimeInterval
    public var t2Seconds: TimeInterval
    public var k1: Double
    public var k2: Double
    public var rMin: Double

    public init(t1Seconds: TimeInterval,
                t2Seconds: TimeInterval,
                k1: Double,
                k2: Double,
                rMin: Double) {
        self.t1Seconds = max(1.0, t1Seconds)
        self.t2Seconds = max(1.0, t2Seconds)
        self.k1 = max(0.01, k1)
        self.k2 = max(0.01, k2)
        self.rMin = RelationalMath.clamp01(rMin)
    }

    public static let noaDefaults = RelationalNoaDecayParameters(
        t1Seconds: 7.0 * 24.0 * 3600.0,
        t2Seconds: 30.0 * 24.0 * 3600.0,
        k1: 1.2,
        k2: 0.6,
        rMin: 0.05
    )
}

public struct RelationalDecayPolicy: Codable, Hashable, Sendable {
    public var profileId: String
    public var version: Int
    public var effectiveFromTimestamp: TimeInterval
    public var kind: RelationalDecayProfileKind
    public var noaParameters: RelationalNoaDecayParameters?

    public init(profileId: String,
                version: Int,
                effectiveFromTimestamp: TimeInterval,
                kind: RelationalDecayProfileKind,
                noaParameters: RelationalNoaDecayParameters? = nil) {
        self.profileId = profileId
        self.version = max(1, version)
        self.effectiveFromTimestamp = effectiveFromTimestamp
        self.kind = kind
        self.noaParameters = noaParameters
    }

    public static let defaultNoa = RelationalDecayPolicy(
        profileId: "noa",
        version: 1,
        effectiveFromTimestamp: 0,
        kind: .noaDoubleSigmoid,
        noaParameters: .noaDefaults
    )
}

public struct RelationalDecayPolicyUpdatedEvent: Codable, Sendable {
    public var eventId: String
    public var emittedAt: TimeInterval
    public var policy: RelationalDecayPolicy

    public init(eventId: String = UUID().uuidString,
                emittedAt: TimeInterval,
                policy: RelationalDecayPolicy) {
        self.eventId = eventId
        self.emittedAt = emittedAt
        self.policy = policy
    }
}

public enum RelationalDecay {
    public static func retention(policy: RelationalDecayPolicy,
                                 now: TimeInterval,
                                 lastReinforcedAt: TimeInterval) -> Double {
        let delta = max(0.0, now - lastReinforcedAt)

        switch policy.kind {
        case .none:
            return 1.0
        case .noaDoubleSigmoid:
            let params = policy.noaParameters ?? .noaDefaults
            return noaRetention(delta: delta, params: params)
        }
    }

    private static func noaRetention(delta: TimeInterval,
                                     params: RelationalNoaDecayParameters) -> Double {
        let scaledK1 = max(1.0, params.k1 * params.t1Seconds)
        let scaledK2 = max(1.0, params.k2 * params.t2Seconds)

        let s1 = 1.0 / (1.0 + exp((delta - params.t1Seconds) / scaledK1))
        let s2 = 1.0 / (1.0 + exp((delta - params.t2Seconds) / scaledK2))

        let baseS1 = 1.0 / (1.0 + exp((0.0 - params.t1Seconds) / scaledK1))
        let baseS2 = 1.0 / (1.0 + exp((0.0 - params.t2Seconds) / scaledK2))
        let base = max(1.0e-9, baseS1 * baseS2)
        let normalizedShape = (s1 * s2) / base

        let value = params.rMin + (1.0 - params.rMin) * normalizedShape
        return RelationalMath.clamp01(value)
    }
}
