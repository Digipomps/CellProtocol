// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// One process-wide quota owner, shared by all public bridge routes. Source must
/// come from the socket/trusted proxy, not an unverified forwarded header.
public final class BridgeChannelLimits: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var maximumConnections = 512
        public var maximumPending = 256
        public var maximumPendingPerSource = 4
        public var maximumConnectionsPerKey = 8
        public var maximumOperationsPerKey = 32
        public var maximumFeedsPerKey = 16
        public var maximumChannelsPerKey = 16
        public var maximumPendingSendBytes = 16 * 1024 * 1024
        public var maximumPendingSendBytesPerConnection = 4 * 1024 * 1024
        public var maximumAttemptsPerMinute = 512
        public var maximumAttemptsPerSourcePerMinute = 60
        public var maximumVerifiedHandshakesPerKeyPerMinute = 12
        public var maximumRateBuckets = 4096
        public init() {}
    }
    private struct Entry {
        let source: String
        var principal: String?
        var operations = 0
        var feeds = 0
        var channels = 0
        var sendBytes = 0
        let revoke: @Sendable () -> Void
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    public let configuration: Configuration
    private struct RateBucket { var started: TimeInterval; var count: Int }
    private var rateBuckets: [String: RateBucket] = [:]
    private let monotonic: @Sendable () -> TimeInterval
    public init(configuration: Configuration = .init(),
                monotonic: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.configuration = configuration; self.monotonic = monotonic
    }

    // Fixed 60-second windows. Entries outlive sockets, so close/reconnect cannot
    // reset the rate. Never allocate a bucket from an unverified identity UUID.
    private func consumeRate(_ key: String, maximum: Int) throws {
        let now = monotonic()
        rateBuckets = rateBuckets.filter { now < $0.value.started + 60 }
        if var bucket = rateBuckets[key] {
            guard bucket.count < maximum else { throw BridgeChannelAuthentication.Failure.capacity }
            bucket.count += 1; rateBuckets[key] = bucket
        } else {
            guard maximum > 0, rateBuckets.count < configuration.maximumRateBuckets else {
                throw BridgeChannelAuthentication.Failure.capacity
            }
            rateBuckets[key] = RateBucket(started: now, count: 1)
        }
    }

    func reserve(_ id: String, source: String, revoke: @escaping @Sendable () -> Void) throws {
        try lock.withLock {
            guard source.utf8.count <= 256 else { throw BridgeChannelAuthentication.Failure.capacity }
            try consumeRate("global", maximum: configuration.maximumAttemptsPerMinute)
            try consumeRate("source:" + source, maximum: configuration.maximumAttemptsPerSourcePerMinute)
            guard entries[id] == nil,
                  entries.count < configuration.maximumConnections,
                  entries.values.filter({ $0.principal == nil }).count < configuration.maximumPending,
                  entries.values.filter({ $0.principal == nil && $0.source == source }).count < configuration.maximumPendingPerSource else {
                throw BridgeChannelAuthentication.Failure.capacity
            }
            entries[id] = Entry(source: source, revoke: revoke)
        }
    }
    func authenticate(_ id: String, principal: String) throws {
        try lock.withLock {
            guard var entry = entries[id], entry.principal == nil else { throw BridgeChannelAuthentication.Failure.closed }
            guard entries.values.filter({ $0.principal == principal }).count < configuration.maximumConnectionsPerKey else {
                throw BridgeChannelAuthentication.Failure.capacity
            }
            try consumeRate("key:" + principal, maximum: configuration.maximumVerifiedHandshakesPerKeyPerMinute)
            entry.principal = principal
            entries[id] = entry
        }
    }
    enum Resource { case operation, feed, channel }
    func acquire(_ id: String, resource: Resource) throws {
        try lock.withLock {
            guard var entry = entries[id], let principal = entry.principal else { throw BridgeChannelAuthentication.Failure.closed }
            let related = entries.values.filter { $0.principal == principal }
            switch resource {
            case .operation:
                guard related.reduce(0, { $0 + $1.operations }) < configuration.maximumOperationsPerKey else { throw BridgeChannelAuthentication.Failure.capacity }
                entry.operations += 1
            case .feed:
                guard related.reduce(0, { $0 + $1.feeds }) < configuration.maximumFeedsPerKey else { throw BridgeChannelAuthentication.Failure.capacity }
                entry.feeds += 1
            case .channel:
                guard related.reduce(0, { $0 + $1.channels }) < configuration.maximumChannelsPerKey else { throw BridgeChannelAuthentication.Failure.capacity }
                entry.channels += 1
            }
            entries[id] = entry
        }
    }
    func release(_ id: String, resource: Resource) {
        lock.withLock {
            guard var entry = entries[id] else { return }
            switch resource {
            case .operation: entry.operations = max(0, entry.operations - 1)
            case .feed: entry.feeds = max(0, entry.feeds - 1)
            case .channel: entry.channels = max(0, entry.channels - 1)
            }
            entries[id] = entry
        }
    }
    func acquireSend(_ id: String, bytes: Int) throws {
        try lock.withLock {
            guard var entry = entries[id], entry.principal != nil else { throw BridgeChannelAuthentication.Failure.closed }
            guard bytes <= configuration.maximumPendingSendBytesPerConnection - entry.sendBytes,
                  bytes <= configuration.maximumPendingSendBytes - entries.values.reduce(0, { $0 + $1.sendBytes }) else {
                throw BridgeChannelAuthentication.Failure.capacity
            }
            entry.sendBytes += bytes
            entries[id] = entry
        }
    }
    func releaseSend(_ id: String, bytes: Int) {
        lock.withLock { if var entry = entries[id] { entry.sendBytes = max(0, entry.sendBytes - bytes); entries[id] = entry } }
    }
    func release(_ id: String) { lock.withLock { _ = entries.removeValue(forKey: id) } }
    public var connectionCount: Int { lock.withLock { entries.count } }

    /// Local host policy calls this after its authoritative key status changes.
    /// This only revokes active transport leases; Cells still own grant revocation.
    public func revoke(identity: BridgeChannelAuthentication.PublicIdentity, domain: String) {
        let principal = Self.principal(identity: identity, domain: domain)
        let callbacks = lock.withLock { entries.values.filter { $0.principal == principal }.map(\.revoke) }
        callbacks.forEach { $0() }
    }
    static func principal(identity: BridgeChannelAuthentication.PublicIdentity, domain: String) -> String {
        // Canonical JSON array avoids delimiter collisions in caller-controlled scopes.
        let fields = [domain, identity.uuid, identity.makeIdentity().signingPublicKeyFingerprint ?? ""]
        return BridgeChannelAuthentication.digest(try! BridgeChannelAuthentication.encode(fields))
    }
}

/// Immutable principal plus connection-owned lease. Not Codable, not a bearer
/// credential. Only the verifier/client acknowledgement can activate it.
public final class BridgeChannelSession: @unchecked Sendable {
    public typealias Auth = BridgeChannelAuthentication
    public enum State: String, Sendable { case unauthenticated, challengeIssued, verifying, authenticated, closed, revoked }
    private let lock = NSLock()
    private var stateValue: State = .unauthenticated
    private var pending: Auth.Challenge?
    private var identityValue: Auth.PublicIdentity?
    private var authValue: Auth.Authenticated?
    private var absoluteExpiry: Date?
    private var deadline: TimeInterval
    private let monotonic: @Sendable () -> TimeInterval
    private let wallClock: @Sendable () -> Date
    private let limits: BridgeChannelLimits?
    public let generation = UUID().uuidString
    public let endpoint: Auth.Endpoint
    private var closedCallback: (@Sendable () -> Void)?

    public init(endpoint: Auth.Endpoint, limits: BridgeChannelLimits? = nil, source: String = "local",
                wallClock: @escaping @Sendable () -> Date = { Date() },
                monotonic: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        try endpoint.validate()
        self.endpoint = endpoint; self.limits = limits; self.wallClock = wallClock; self.monotonic = monotonic
        deadline = monotonic() + 10
        try limits?.reserve(generation, source: source) { [weak self] in self?.revoke() }
    }
    deinit { limits?.release(generation) }
    public var state: State { lock.withLock { stateValue } }
    public var publicIdentity: Auth.PublicIdentity? { lock.withLock { identityValue } }
    public var expiresAt: Date? { lock.withLock { absoluteExpiry } }
    func onClose(_ callback: @escaping @Sendable () -> Void) { lock.withLock { closedCallback = callback } }

    public func issueChallenge(_ hello: Auth.Hello) throws -> Auth.Challenge {
        try lock.withLock {
            guard stateValue == .unauthenticated else { throw Auth.Failure.unexpectedMessage }
            guard monotonic() < deadline else { throw Auth.Failure.expired }
            let challenge = try Auth.challenge(hello: hello, endpoint: endpoint, generation: generation, now: wallClock())
            pending = challenge
            stateValue = .challengeIssued
            return challenge
        }
    }

    /// Generalizes PersonEntityReadRouteCoordinator's reserve/recheck/activate
    /// sequence. Consume before expensive verification; no concurrent winner and
    /// no replacement of pending bytes from the wire. No vault is consulted.
    public func reserveOpen(_ proof: Auth.Proof) throws {
        let challenge = try lock.withLock { () throws -> Auth.Challenge in
            guard stateValue == .challengeIssued, let pending else { throw Auth.Failure.unexpectedMessage }
            guard monotonic() < deadline,
                  wallClock().timeIntervalSince1970 < Double(pending.transcript.issuedAtMilliseconds) / 1000 + Auth.challengeLifetime else {
                throw Auth.Failure.expired
            }
            guard proof.sessionID == pending.transcript.sessionID, proof.generation == generation else { throw Auth.Failure.staleGeneration }
            stateValue = .verifying
            self.pending = nil
            return pending
        }
        guard proof.signature.count <= 256,
              IdentityPublicKeySignatureVerifier.verify(signature: proof.signature, messageData: challenge.signingData,
                identity: challenge.transcript.identity.makeIdentity()) else {
            close(); throw Auth.Failure.invalidProof
        }
        try lock.withLock {
            guard stateValue == .verifying, monotonic() < deadline else { throw Auth.Failure.expired }
            try limits?.authenticate(generation, principal: BridgeChannelLimits.principal(identity: challenge.transcript.identity, domain: endpoint.domain))
            identityValue = challenge.transcript.identity
            absoluteExpiry = Date(timeIntervalSince1970: Double(challenge.transcript.channelExpiresAtMilliseconds) / 1000)
            authValue = Auth.Authenticated(sessionID: proof.sessionID, generation: generation,
                transcriptDigest: Auth.digest(try Auth.encode(challenge.transcript)))
        }
    }

    /// Call again after any awaited route/policy check and before Cell creation.
    public func recheckBeforeActivation() throws {
        try lock.withLock {
            guard stateValue == .verifying, identityValue != nil, monotonic() < deadline,
                  let expiry = absoluteExpiry, wallClock() < expiry else { throw Auth.Failure.expired }
        }
    }
    public func activate() throws -> Auth.Authenticated {
        try lock.withLock {
            guard stateValue == .verifying, monotonic() < deadline, let authValue,
                  let expiry = absoluteExpiry, wallClock() < expiry else { throw Auth.Failure.expired }
            deadline = monotonic() + min(Auth.channelLifetime, expiry.timeIntervalSince(wallClock()))
            stateValue = .authenticated
            return authValue
        }
    }

    func acceptAcknowledgement(_ acknowledgement: Auth.Authenticated, challenge: Auth.Challenge) throws {
        try lock.withLock {
            guard stateValue == .unauthenticated, monotonic() < deadline,
                  acknowledgement.sessionID == challenge.transcript.sessionID,
                  acknowledgement.generation == challenge.transcript.generation,
                  acknowledgement.transcriptDigest == Auth.digest(try Auth.encode(challenge.transcript)) else { throw Auth.Failure.invalidProof }
            let expiry = Date(timeIntervalSince1970: Double(challenge.transcript.channelExpiresAtMilliseconds) / 1000)
            guard wallClock() < expiry else { throw Auth.Failure.expired }
            identityValue = challenge.transcript.identity
            authValue = acknowledgement
            absoluteExpiry = expiry
            deadline = monotonic() + min(Auth.channelLifetime, expiry.timeIntervalSince(wallClock()))
            stateValue = .authenticated
        }
    }

    public func check(identity: Identity? = nil, requiresIdentity: Bool = false) throws {
        try lock.withLock {
            guard stateValue == .authenticated else { throw stateValue == .revoked ? Auth.Failure.revoked : Auth.Failure.closed }
            guard monotonic() < deadline, let expiry = absoluteExpiry, wallClock() < expiry else { throw Auth.Failure.expired }
            if let identity {
                guard let identityValue, (try? Auth.PublicIdentity(identity)) == identityValue else { throw Auth.Failure.identityMismatch }
            } else if requiresIdentity { throw Auth.Failure.identityMismatch }
        }
    }
    func acquireSend(bytes: Int) throws { try check(); try limits?.acquireSend(generation, bytes: bytes) }
    func releaseSend(bytes: Int) { limits?.releaseSend(generation, bytes: bytes) }
    func acquire(_ resource: BridgeChannelLimits.Resource) throws {
        try check()
        try limits?.acquire(generation, resource: resource)
    }
    func release(_ resource: BridgeChannelLimits.Resource) { limits?.release(generation, resource: resource) }
    public func requester(for presented: Identity, bridge: BridgeProtocol) throws -> Identity {
        try check(identity: presented, requiresIdentity: true)
        guard let descriptor = publicIdentity else { throw Auth.Failure.closed }
        let identity = descriptor.makeIdentity()
        identity.identityVault = BridgeIdentityVault(cloudBridge: bridge)
        return identity
    }
    public func revoke() { terminate(.revoked) }
    public func close() { terminate(.closed) }
    private func terminate(_ state: State) {
        let callback: (@Sendable () -> Void)? = lock.withLock {
            guard stateValue != .closed && stateValue != .revoked else { return nil }
            stateValue = state; pending = nil; authValue = nil
            let callback = closedCallback; closedCallback = nil
            return callback
        }
        limits?.release(generation)
        callback?()
    }
}
