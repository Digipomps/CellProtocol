// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum CellSecurityContainmentMode: String, Codable, Sendable {
    case monitorOnly
    case localProtection
}

public enum CellSecurityContainmentActionKind: String, Codable, Sendable {
    case rateLimitSigning
    case quarantineBridge
    case revokeOrRetryChallenge
    case requireReauthentication
    case blockRemoteConfigurationLookup
}

public struct CellSecurityRateLimitPolicy: Codable, Equatable, Sendable {
    public var maxAttempts: Int
    public var windowSeconds: TimeInterval

    public init(maxAttempts: Int = 12, windowSeconds: TimeInterval = 60) {
        self.maxAttempts = max(1, maxAttempts)
        self.windowSeconds = max(1, windowSeconds)
    }
}

public struct CellSecurityContainmentPolicy: Codable, Equatable, Sendable {
    public var mode: CellSecurityContainmentMode
    public var signingRateLimit: CellSecurityRateLimitPolicy
    public var bridgeQuarantineSeconds: TimeInterval
    public var requireReauthenticationForHighSeverity: Bool
    public var blockRemoteConfigurationLookup: Bool

    public init(
        mode: CellSecurityContainmentMode = .monitorOnly,
        signingRateLimit: CellSecurityRateLimitPolicy = CellSecurityRateLimitPolicy(),
        bridgeQuarantineSeconds: TimeInterval = 300,
        requireReauthenticationForHighSeverity: Bool = true,
        blockRemoteConfigurationLookup: Bool = true
    ) {
        self.mode = mode
        self.signingRateLimit = signingRateLimit
        self.bridgeQuarantineSeconds = max(1, bridgeQuarantineSeconds)
        self.requireReauthenticationForHighSeverity = requireReauthenticationForHighSeverity
        self.blockRemoteConfigurationLookup = blockRemoteConfigurationLookup
    }

    public static let monitorOnly = CellSecurityContainmentPolicy(mode: .monitorOnly)

    public static let localProtection = CellSecurityContainmentPolicy(mode: .localProtection)

    public func actions(
        for event: CellSecurityEvent,
        now: Date = Date()
    ) -> [CellSecurityContainmentAction] {
        var actions = [CellSecurityContainmentAction]()

        if event.kind == .signingChallengeReplay {
            actions.append(
                CellSecurityContainmentAction(
                    kind: .revokeOrRetryChallenge,
                    eventID: event.id,
                    reasonCode: event.reasonCode,
                    resource: event.resource,
                    requiredAction: "retry_with_fresh_challenge",
                    automatic: mode == .localProtection
                )
            )
            actions.append(
                CellSecurityContainmentAction(
                    kind: .quarantineBridge,
                    eventID: event.id,
                    reasonCode: event.reasonCode,
                    resource: event.resource,
                    requiredAction: "temporary_bridge_quarantine",
                    automatic: mode == .localProtection,
                    expiresAt: now.addingTimeInterval(bridgeQuarantineSeconds)
                )
            )
        }

        if event.kind == .vaultSignRejected || event.kind == .transportRejected {
            actions.append(
                CellSecurityContainmentAction(
                    kind: .rateLimitSigning,
                    eventID: event.id,
                    reasonCode: event.reasonCode,
                    resource: event.resource,
                    requiredAction: "slow_down_and_retry_with_valid_proof",
                    automatic: mode == .localProtection
                )
            )
        }

        if event.kind == .configLookupBlocked && blockRemoteConfigurationLookup {
            actions.append(
                CellSecurityContainmentAction(
                    kind: .blockRemoteConfigurationLookup,
                    eventID: event.id,
                    reasonCode: event.reasonCode,
                    resource: event.resource,
                    requiredAction: "allowlist_endpoint_or_use_local_configuration",
                    automatic: mode == .localProtection
                )
            )
        }

        if requireReauthenticationForHighSeverity && (event.severity == .high || event.severity == .critical) {
            actions.append(
                CellSecurityContainmentAction(
                    kind: .requireReauthentication,
                    eventID: event.id,
                    reasonCode: event.reasonCode,
                    resource: event.resource,
                    actor: event.requester,
                    requiredAction: "require_reauthentication",
                    automatic: mode == .localProtection
                )
            )
        }

        return actions
    }
}

public struct CellSecurityContainmentAction: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: CellSecurityContainmentActionKind
    public var eventID: String?
    public var reasonCode: String
    public var resource: CellSecurityResource
    public var actor: CellSecurityActor?
    public var requiredAction: String
    public var automatic: Bool
    public var createdAt: Date
    public var expiresAt: Date?

    public init(
        id: String = UUID().uuidString,
        kind: CellSecurityContainmentActionKind,
        eventID: String? = nil,
        reasonCode: String,
        resource: CellSecurityResource,
        actor: CellSecurityActor? = nil,
        requiredAction: String,
        automatic: Bool,
        createdAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.eventID = eventID
        self.reasonCode = reasonCode
        self.resource = resource
        self.actor = actor
        self.requiredAction = requiredAction
        self.automatic = automatic
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public enum CellSecurityRateLimitDecision: Equatable, Sendable {
    case allowed(remaining: Int)
    case denied(retryAfter: TimeInterval)

    public var allowed: Bool {
        switch self {
        case .allowed:
            return true
        case .denied:
            return false
        }
    }
}

public struct CellSecurityContainmentSnapshot: Codable, Equatable, Sendable {
    public var actions: [CellSecurityContainmentAction]
    public var quarantinedResources: [String: Date]
    public var reauthenticationRequired: [String: Date]

    public init(
        actions: [CellSecurityContainmentAction],
        quarantinedResources: [String: Date],
        reauthenticationRequired: [String: Date]
    ) {
        self.actions = actions
        self.quarantinedResources = quarantinedResources
        self.reauthenticationRequired = reauthenticationRequired
    }
}

public actor CellSecurityContainmentController {
    private var actions = [CellSecurityContainmentAction]()
    private var quarantinedResources = [String: Date]()
    private var reauthenticationRequired = [String: Date]()
    private var rateLimitBuckets = [String: [Date]]()

    public init() {}

    @discardableResult
    public func observe(
        _ event: CellSecurityEvent,
        policy: CellSecurityContainmentPolicy,
        now: Date = Date()
    ) -> [CellSecurityContainmentAction] {
        purgeExpired(now: now)
        let proposedActions = policy.actions(for: event, now: now)
        actions.append(contentsOf: proposedActions)

        guard policy.mode == .localProtection else {
            return proposedActions
        }

        for action in proposedActions where action.automatic {
            apply(action, now: now)
        }
        return proposedActions
    }

    public func applyManualAction(
        _ action: CellSecurityContainmentAction,
        now: Date = Date()
    ) {
        actions.append(action)
        apply(action, now: now)
    }

    public func checkSigningRateLimit(
        scope: String,
        policy: CellSecurityContainmentPolicy,
        now: Date = Date()
    ) -> CellSecurityRateLimitDecision {
        guard policy.mode == .localProtection else {
            return .allowed(remaining: policy.signingRateLimit.maxAttempts)
        }

        let windowStart = now.addingTimeInterval(-policy.signingRateLimit.windowSeconds)
        let attempts = (rateLimitBuckets[scope] ?? []).filter { $0 >= windowStart }
        let updated = attempts + [now]
        rateLimitBuckets[scope] = updated

        guard updated.count <= policy.signingRateLimit.maxAttempts else {
            let oldest = updated.first ?? now
            let retryAfter = max(1, policy.signingRateLimit.windowSeconds - now.timeIntervalSince(oldest))
            return .denied(retryAfter: retryAfter)
        }
        return .allowed(remaining: max(0, policy.signingRateLimit.maxAttempts - updated.count))
    }

    public func isQuarantined(
        resourceKind: String,
        identifier: String,
        now: Date = Date()
    ) -> Bool {
        purgeExpired(now: now)
        return quarantinedResources[resourceKey(kind: resourceKind, identifier: identifier)] != nil
    }

    public func requireReauthentication(
        actor: CellSecurityActor,
        now: Date = Date()
    ) {
        guard let key = actorKey(actor) else { return }
        reauthenticationRequired[key] = now
    }

    public func snapshot(now: Date = Date()) -> CellSecurityContainmentSnapshot {
        purgeExpired(now: now)
        return CellSecurityContainmentSnapshot(
            actions: actions,
            quarantinedResources: quarantinedResources,
            reauthenticationRequired: reauthenticationRequired
        )
    }

    public func clear() {
        actions.removeAll()
        quarantinedResources.removeAll()
        reauthenticationRequired.removeAll()
        rateLimitBuckets.removeAll()
    }

    private func apply(_ action: CellSecurityContainmentAction, now: Date) {
        switch action.kind {
        case .quarantineBridge:
            let expiry = action.expiresAt ?? now.addingTimeInterval(300)
            quarantinedResources[resourceKey(action.resource)] = expiry
        case .requireReauthentication:
            if let actor = action.actor, let key = actorKey(actor) {
                reauthenticationRequired[key] = now
            }
        case .rateLimitSigning, .revokeOrRetryChallenge, .blockRemoteConfigurationLookup:
            break
        }
    }

    private func purgeExpired(now: Date) {
        quarantinedResources = quarantinedResources.filter { _, expiresAt in expiresAt >= now }
        let cutoff = now.addingTimeInterval(-3600)
        rateLimitBuckets = rateLimitBuckets.mapValues { attempts in attempts.filter { $0 >= cutoff } }
    }

    private func resourceKey(_ resource: CellSecurityResource) -> String {
        resourceKey(kind: resource.kind, identifier: resource.identifier)
    }

    private func resourceKey(kind: String, identifier: String) -> String {
        "\(kind):\(identifier)"
    }

    private func actorKey(_ actor: CellSecurityActor) -> String? {
        guard let identityUUID = actor.identityUUID?.trimmingCharacters(in: .whitespacesAndNewlines),
              identityUUID.isEmpty == false else {
            return nil
        }
        let fingerprint = actor.signingKeyFingerprint ?? ""
        let domain = actor.domain ?? ""
        return [identityUUID, fingerprint, domain].joined(separator: ":")
    }
}
