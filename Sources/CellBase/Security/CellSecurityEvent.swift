// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum CellSecuritySeverity: String, Codable, Sendable {
    case info
    case low
    case medium
    case high
    case critical
}

public enum CellSecurityEventKind: String, Codable, Sendable {
    case authorizationAllowed
    case authorizationDenied
    case identityMismatch
    case ownerProofFailed
    case vaultSignRejected
    case signingChallengeReplay
    case configLookupBlocked
    case contractRejected
    case transportRejected
    case policyProbe
}

public struct CellSecurityActor: Codable, Equatable, Sendable {
    public var identityUUID: String?
    public var signingKeyFingerprint: String?
    public var domain: String?

    public init(
        identityUUID: String? = nil,
        signingKeyFingerprint: String? = nil,
        domain: String? = nil
    ) {
        self.identityUUID = identityUUID
        self.signingKeyFingerprint = signingKeyFingerprint
        self.domain = domain
    }
}

public struct CellSecurityResource: Codable, Equatable, Sendable {
    public var kind: String
    public var identifier: String
    public var action: String
    public var keypath: String?

    public init(
        kind: String,
        identifier: String,
        action: String,
        keypath: String? = nil
    ) {
        self.kind = kind
        self.identifier = identifier
        self.action = action
        self.keypath = keypath
    }
}

public struct CellSecurityEvent: Codable, Equatable, Sendable {
    public var id: String
    public var kind: CellSecurityEventKind
    public var severity: CellSecuritySeverity
    public var occurredAt: Date
    public var resource: CellSecurityResource
    public var requester: CellSecurityActor?
    public var reasonCode: String
    public var userMessage: String?
    public var requiredAction: String?
    public var canAutoResolve: Bool
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        kind: CellSecurityEventKind,
        severity: CellSecuritySeverity,
        occurredAt: Date = Date(),
        resource: CellSecurityResource,
        requester: CellSecurityActor? = nil,
        reasonCode: String,
        userMessage: String? = nil,
        requiredAction: String? = nil,
        canAutoResolve: Bool = false,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.occurredAt = occurredAt
        self.resource = resource
        self.requester = requester
        self.reasonCode = reasonCode
        self.userMessage = userMessage
        self.requiredAction = requiredAction
        self.canAutoResolve = canAutoResolve
        self.metadata = metadata
    }
}

public protocol CellSecurityEventSink: Sendable {
    func record(_ event: CellSecurityEvent) async
}

public actor InMemoryCellSecurityEventSink: CellSecurityEventSink {
    private var events: [CellSecurityEvent] = []

    public init() {}

    public func record(_ event: CellSecurityEvent) {
        events.append(event)
    }

    public func snapshot() -> [CellSecurityEvent] {
        events
    }

    public func clear() {
        events.removeAll()
    }
}

public enum CellSecurityReasonCode {
    public static let authorizationDenied = "authorization_denied"
    public static let bridgeSigningDenied = "bridge_signing_denied"
    public static let bridgeNotReady = "bridge_not_ready"
    public static let invalidSigningChallenge = "invalid_signing_challenge"
    public static let challengeReplay = "challenge_replay"
    public static let challengeExpired = "challenge_expired"
    public static let challengeIssuedInFuture = "challenge_issued_in_future"
    public static let challengeMissingScope = "challenge_missing_scope"
    public static let remoteEndpointBlocked = "remote_endpoint_blocked"
    public static let endpointPolicyRejected = "endpoint_policy_rejected"
    public static let signingRateLimited = "signing_rate_limited"
    public static let bridgeQuarantined = "bridge_quarantined"
    public static let reauthenticationRequired = "reauthentication_required"
}

public extension CellSecurityReplayDecision {
    var reasonCode: String {
        switch self {
        case .accepted:
            return "challenge_accepted"
        case .replay:
            return CellSecurityReasonCode.challengeReplay
        case .expired:
            return CellSecurityReasonCode.challengeExpired
        case .issuedInFuture:
            return CellSecurityReasonCode.challengeIssuedInFuture
        case .missingScope:
            return CellSecurityReasonCode.challengeMissingScope
        }
    }

    var requiredAction: String {
        switch self {
        case .accepted:
            return "none"
        case .replay:
            return "retry_with_fresh_challenge"
        case .expired:
            return "retry_with_current_challenge"
        case .issuedInFuture:
            return "check_clock_and_retry"
        case .missingScope:
            return "include_complete_challenge_scope"
        }
    }
}

public extension CellSecurityEvent {
    static func authorizationDenied(_ decision: CellAuthorizationDecision) -> CellSecurityEvent {
        CellSecurityEvent(
            kind: .authorizationDenied,
            severity: severity(for: decision),
            resource: CellSecurityResource(
                kind: "cell",
                identifier: decision.request.cellUUID,
                action: decision.request.requestedAccess,
                keypath: decision.request.keypath
            ),
            requester: CellSecurityActor(
                identityUUID: decision.request.requesterUUID,
                signingKeyFingerprint: decision.request.requesterSigningKeyFingerprint,
                domain: decision.request.identityDomain
            ),
            reasonCode: decision.reasonCode ?? CellSecurityReasonCode.authorizationDenied,
            userMessage: decision.userMessage,
            requiredAction: decision.requiredAction,
            canAutoResolve: decision.canAutoResolve ?? false,
            metadata: [
                "authorizationPath": decision.path.rawValue
            ]
        )
    }

    static func bridgeSigningDenied(
        bridgeUUID: String,
        identity: Identity?,
        reasonCode: String,
        message: String,
        kind: CellSecurityEventKind = .vaultSignRejected,
        requiredAction: String = "retry_with_valid_identity_signing_challenge",
        identityDomain: String? = nil
    ) -> CellSecurityEvent {
        CellSecurityEvent(
            kind: kind,
            severity: kind == .signingChallengeReplay ? .high : .medium,
            resource: CellSecurityResource(
                kind: "bridge",
                identifier: bridgeUUID,
                action: "sign"
            ),
            requester: identity.map {
                CellSecurityActor(
                    identityUUID: $0.uuid,
                    signingKeyFingerprint: $0.signingPublicKeyFingerprint,
                    domain: identityDomain
                )
            },
            reasonCode: reasonCode,
            userMessage: message,
            requiredAction: requiredAction,
            canAutoResolve: false
        )
    }

    static func configLookupBlocked(
        endpoint: String,
        requester: Identity?,
        reasonCode: String = CellSecurityReasonCode.remoteEndpointBlocked,
        message: String
    ) -> CellSecurityEvent {
        let safeEndpoint = sanitizedEndpointIdentifier(endpoint)
        return CellSecurityEvent(
            kind: .configLookupBlocked,
            severity: .medium,
            resource: CellSecurityResource(
                kind: "cellConfiguration",
                identifier: safeEndpoint,
                action: "resolve"
            ),
            requester: requester.map {
                CellSecurityActor(
                    identityUUID: $0.uuid,
                    signingKeyFingerprint: $0.signingPublicKeyFingerprint,
                    domain: nil
                )
            },
            reasonCode: reasonCode,
            userMessage: message,
            requiredAction: "allowlist_endpoint_or_use_local_configuration",
            canAutoResolve: false
        )
    }

    private static func sanitizedEndpointIdentifier(_ endpoint: String) -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              !scheme.isEmpty else {
            return "invalid_endpoint"
        }
        components.scheme = scheme
        if let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            components.host = host.lowercased()
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "invalid_endpoint"
    }

    private static func severity(for decision: CellAuthorizationDecision) -> CellSecuritySeverity {
        switch decision.path {
        case .deniedIdentityReferenceMismatch, .deniedOwnerProofFailed:
            return .high
        case .deniedNoGrant:
            return .medium
        case .debugBypass, .ownerProof, .signedContract, .cellSpecific:
            return .info
        }
    }
}
