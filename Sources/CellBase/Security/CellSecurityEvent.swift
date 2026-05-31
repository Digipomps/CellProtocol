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
