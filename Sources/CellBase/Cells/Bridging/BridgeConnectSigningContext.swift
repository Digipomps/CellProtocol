// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// An inert local token until a vault retains and recognizes this exact object.
/// Creating another token for the same descriptor confers no holder authority.
/// Neither the token nor its attachment is encoded or copied by public snapshots.
public final class BridgeConnectHolderCapability: @unchecked Sendable {
    public init() {}

    /// The resulting local identity is the holder's authorized startup handle.
    /// Keep it private; publish only publicIdentitySnapshot().
    public func holderIdentity(_ identity: Identity) -> Identity {
        let result = identity.publicIdentitySnapshot()
        result.identityVault = identity.identityVault
        result.homeVaultReference = identity.homeVaultReference
        result.grants = identity.grants
        result.properties = identity.properties
        result.entityAnchorReference = identity.entityAnchorReference
        result.bridgeConnectHolder = self
        return result
    }
}

/// One operation's live, exact-byte signing authority. Only CP can issue it;
/// a holder vault must independently recognize its retained holder token.
/// Not Codable, not a challenge allowlist, and never sent on the bridge.
public final class BridgeConnectSigningContext: @unchecked Sendable {
    private let holder: BridgeConnectHolderCapability
    private let data: Data
    private let uuid: String
    private let fingerprint: String
    private let endpoint: BridgeChannelAuthentication.Endpoint
    private let issuedAt: Int64
    private let deadline: TimeInterval
    private let monotonic: @Sendable () -> TimeInterval
    private let wallClock: @Sendable () -> Date
    private let lock = NSLock()
    private var active = true
    private var consumed = false

    init(holder: BridgeConnectHolderCapability, challenge: BridgeChannelAuthentication.Challenge,
         identity: Identity, deadline: TimeInterval,
         monotonic: @escaping @Sendable () -> TimeInterval,
         wallClock: @escaping @Sendable () -> Date) throws {
        guard let fingerprint = identity.signingPublicKeyFingerprint else {
            throw BridgeChannelAuthentication.Failure.invalidProof
        }
        self.holder = holder; data = challenge.signingData
        uuid = identity.uuid; self.fingerprint = fingerprint
        endpoint = challenge.transcript.endpoint
        issuedAt = challenge.transcript.issuedAtMilliseconds
        self.deadline = deadline; self.monotonic = monotonic; self.wallClock = wallClock
    }

    private func check(messageData: Data, identity: Identity) throws {
        try Task.checkCancellation()
        let now = wallClock()
        let milliseconds = BridgeChannelAuthentication.milliseconds(now)
        guard active, !consumed, monotonic() < deadline,
              data == messageData, identity.uuid == uuid,
              identity.signingPublicKeyFingerprint == fingerprint,
              issuedAt <= milliseconds + 5_000, issuedAt > milliseconds - 30_000 else {
            throw BridgeChannelAuthentication.Failure.invalidProof
        }
        _ = try IdentitySigningChallenge.validateSigningData(messageData, for: identity, now: now)
    }

    /// Non-consuming adapter check; final live admission belongs to the signer.
    public func validate(holder: BridgeConnectHolderCapability, messageData: Data,
                         identity: Identity, endpoint: BridgeChannelAuthentication.Endpoint) throws {
        try lock.withLock {
            guard self.holder === holder, self.endpoint == endpoint else {
                throw BridgeChannelAuthentication.Failure.invalidProof
            }
            try check(messageData: messageData, identity: identity)
        }
    }

    /// Call on the vault actor after its final await, immediately before its
    /// synchronous private signing call. A failed signing attempt stays consumed.
    public func consume(messageData: Data, identity: Identity) throws {
        try lock.withLock {
            try check(messageData: messageData, identity: identity)
            consumed = true
        }
    }

    func invalidate() { lock.withLock { active = false } }
}
