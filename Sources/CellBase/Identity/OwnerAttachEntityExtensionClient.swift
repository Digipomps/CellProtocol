// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum OwnerAttachExtensionOutcome: Sendable {
    case confirmed(OwnerAttachExtensionReceipt)
    case declined(OwnerAttachExtensionBinding)
    case alreadyConsidering, noLongerAttached
}

public struct OwnerAttachExtensionClientRecord: Codable, Sendable {
    public var policy: OwnerAttachExtensionPolicy?
    public var receipt: OwnerAttachExtensionReceipt?
    /// Host-supplied routing hint from the attached reference. Future use must
    /// still authenticate the receiver key; this string grants no authority.
    public var receiverEndpoint: String?
    public init(policy: OwnerAttachExtensionPolicy? = nil, receipt: OwnerAttachExtensionReceipt? = nil,
                receiverEndpoint: String? = nil) {
        self.policy = policy; self.receipt = receipt; self.receiverEndpoint = receiverEndpoint
    }
}

/// Shared native/headless coordinator. Hosts provide a human-context identity,
/// private storage and a consent UI (headless hosts can return nil = not now).
/// The owner-attach callback is opt-in, rather than a global read/Absorb hook.
public actor OwnerAttachEntityExtensionClient {
    public typealias Review = @Sendable (OwnerAttachExtensionOffer) async -> OwnerAttachExtensionChoice?
    private let store: any OwnerAttachExtensionStore
    private var considering: Set<String> = []
    private let clock: @Sendable () -> Date

    public init(store: any OwnerAttachExtensionStore, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.clock = clock
    }

    public func consider(emitter: any Emit, activeHuman: Identity, requester: Identity,
                         receiverEndpoint: String? = nil,
                         stillAttached: @escaping @Sendable () async -> Bool,
                         review: @escaping Review) async throws -> OwnerAttachExtensionOutcome {
        // An agent/organisation identity that happens to be available in the
        // vault cannot silently become the currently selected human identity.
        guard activeHuman.referencesSameSigningIdentity(as: requester) else {
            throw OwnerAttachExtensionError.enrollmentRequired
        }
        guard let target = emitter as? any Meddle else { throw OwnerAttachExtensionError.unavailable }
        guard !Task.isCancelled, await stillAttached() else { return .noLongerAttached }
        let value = try await target.get(keypath: OwnerAttachEntityExtensionHost.offerKeypath, requester: requester)
        let offer = try OwnerAttachWire.decode(OwnerAttachExtensionOffer.self, from: value)
        try offer.validate(now: clock())
        guard offer.cellUUID == emitter.uuid, offer.binding.domain == emitter.identityDomain,
              OwnerAttachWire.sameKey(offer.binding.requester, try IdentityLinkProtocolService.descriptor(for: activeHuman)) else {
            throw OwnerAttachExtensionError.wrongContext
        }
        let id = offer.binding.storageID
        guard considering.insert(id).inserted else { return .alreadyConsidering }
        defer { considering.remove(id) }
        var record = OwnerAttachExtensionClientRecord()
        if let data = try await store.read(id: id) {
            record = try OwnerAttachWire.decode(OwnerAttachExtensionClientRecord.self, data: data)
            if let receipt = record.receipt { try receipt.validate(for: offer.binding) }
        }
        if let endpoint = receiverEndpoint {
            guard endpoint.utf8.count <= 8192, !endpoint.contains("\n"), !endpoint.contains("\r") else {
                throw OwnerAttachExtensionError.wrongContext
            }
            record.receiverEndpoint = endpoint
        }
        let choice: OwnerAttachExtensionChoice?
        let appliedPolicy = record.policy.flatMap { $0.applies(to: offer, now: clock()) ? $0 : nil }
        if let policy = appliedPolicy {
            choice = policy.choice
        } else {
            choice = await review(offer)
        }
        guard !Task.isCancelled, await stillAttached() else { return .noLongerAttached }
        guard let choice else { return .declined(offer.binding) }
        // No long-lived meaning is attached to a once-only answer.
        if choice == .neverHere {
            record.policy = appliedPolicy ?? OwnerAttachExtensionPolicy(binding: offer.binding, choice: choice,
                expiresAt: clock().addingTimeInterval(365 * 86400))
            try await save(record, id: id)
            return .declined(offer.binding)
        }
        let consent = try await OwnerAttachExtensionConsent.make(offer: offer, choice: choice,
            identity: activeHuman, now: clock())
        guard !Task.isCancelled, await stillAttached() else { return .noLongerAttached }
        let response: ValueType
        do {
            guard let confirmed = try await target.set(keypath: OwnerAttachEntityExtensionHost.acceptKeypath,
                value: OwnerAttachWire.value(from: consent), requester: requester) else {
                throw OwnerAttachExtensionError.completionUnconfirmed
            }
            response = confirmed
        } catch {
            // A lost reply does not prove rollback. The receiver's durable
            // receipt makes retry safe, after another current owner proof.
            throw OwnerAttachExtensionError.completionUnconfirmed
        }
        let receipt = try OwnerAttachWire.decode(OwnerAttachExtensionReceipt.self, from: response)
        try receipt.validate(for: offer.binding)
        record.receipt = receipt
        if choice == .alwaysHere {
            // Automatic use must not renew the duration the human approved.
            record.policy = appliedPolicy ?? OwnerAttachExtensionPolicy(binding: offer.binding, choice: choice,
                expiresAt: clock().addingTimeInterval(365 * 86400))
        } else {
            record.policy = nil
        }
        try await save(record, id: id)
        return .confirmed(receipt)
    }

    /// Removing an automatic policy neither revokes an identity link nor
    /// deletes the entity's data. It only restores consent on the next attach.
    public func forgetPolicy(for binding: OwnerAttachExtensionBinding) async throws {
        guard let data = try await store.read(id: binding.storageID) else { return }
        var record = try OwnerAttachWire.decode(OwnerAttachExtensionClientRecord.self, data: data)
        record.policy = nil
        try await save(record, id: binding.storageID)
    }

    private func save(_ record: OwnerAttachExtensionClientRecord, id: String) async throws {
        let data = try OwnerAttachWire.encode(record)
        try await store.write(data, id: id)
        guard try await store.read(id: id) == data else { throw OwnerAttachExtensionError.persistenceFailed }
    }
}
