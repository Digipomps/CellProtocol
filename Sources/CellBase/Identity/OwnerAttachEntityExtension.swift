// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Presence reuses the identity that proved ownership. It does not enroll a new
/// key, copy cell data, create an index, or grant notification permissions.
public enum OwnerAttachExtensionError: Error, Equatable {
    case unavailable, ownerProofRequired, invalidProof, expired, wrongContext
    case enrollmentRequired, persistenceFailed, completionUnconfirmed, busy
}

public enum OwnerAttachExtensionChoice: String, Codable, Sendable {
    case once, alwaysHere, neverHere
}

/// The complete policy boundary. A hostname or a display name is not a pin.
public struct OwnerAttachExtensionBinding: Codable, Equatable, Sendable {
    public let version: Int
    public let purpose: String
    public let receiver: IdentityPublicKeyDescriptor
    public let requester: IdentityPublicKeyDescriptor
    public let domain: String

    public var storageID: String {
        // Length-prefixed fields avoid ambiguous concatenation and exclude
        // mutable display names from the durable policy key.
        let fields = [String(version), purpose, receiver.uuid, receiver.publicKey.base64EncodedString(),
            String(describing: receiver.algorithm), String(describing: receiver.curveType),
            requester.uuid, requester.publicKey.base64EncodedString(),
            String(describing: requester.algorithm), String(describing: requester.curveType), domain]
        return OwnerAttachWire.digest(Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8))
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.version == b.version && a.purpose == b.purpose && a.domain == b.domain
            && OwnerAttachWire.sameKey(a.receiver, b.receiver) && OwnerAttachWire.sameKey(a.requester, b.requester)
    }
}

public struct OwnerAttachExtensionOffer: Codable, Sendable {
    public let binding: OwnerAttachExtensionBinding
    public let cellUUID: String
    public let cellOwner: IdentityPublicKeyDescriptor
    public let receiverLabel: String
    public let nonce: Data
    public let expiresAt: Date
    public var signature: Data?

    public func validate(now: Date = Date()) throws {
        guard binding.version == 1, binding.purpose == "owner_attach_presence",
              !binding.domain.isEmpty, !cellUUID.isEmpty, nonce.count == 32,
              let signature, !signature.isEmpty else { throw OwnerAttachExtensionError.invalidProof }
        guard expiresAt > now, expiresAt.timeIntervalSince(now) <= 301 else {
            throw OwnerAttachExtensionError.expired
        }
        guard IdentityPublicKeySignatureVerifier.verify(signature: signature,
            messageData: try signingData(), identity: IdentityLinkProtocolService.identity(from: binding.receiver)) else {
            throw OwnerAttachExtensionError.invalidProof
        }
    }

    func signingData() throws -> Data {
        var unsigned = self; unsigned.signature = nil
        return try OwnerAttachWire.encode(unsigned)
    }
}

public struct OwnerAttachExtensionConsent: Codable, Sendable {
    public let offer: OwnerAttachExtensionOffer
    public let choice: OwnerAttachExtensionChoice
    public let signer: IdentityPublicKeyDescriptor
    public var signature: Data?

    /// Call only after a human decision or a matching, unexpired owner policy.
    /// This signs a new purpose-bound consent, never reuses an origin challenge.
    public static func make(offer: OwnerAttachExtensionOffer, choice: OwnerAttachExtensionChoice,
                            identity: Identity, now: Date = Date()) async throws -> Self {
        try offer.validate(now: now)
        let signer = try IdentityLinkProtocolService.descriptor(for: identity)
        guard OwnerAttachWire.sameKey(signer, offer.binding.requester) else {
            throw OwnerAttachExtensionError.enrollmentRequired
        }
        var consent = Self(offer: offer, choice: choice, signer: signer)
        consent.signature = try await identity.sign(data: consent.signingData())
        return consent
    }

    func validate(now: Date) throws {
        try offer.validate(now: now)
        guard choice != .neverHere, OwnerAttachWire.sameKey(signer, offer.binding.requester),
              let signature,
              IdentityPublicKeySignatureVerifier.verify(signature: signature,
                messageData: try signingData(), identity: IdentityLinkProtocolService.identity(from: signer)) else {
            throw OwnerAttachExtensionError.invalidProof
        }
    }

    func signingData() throws -> Data {
        var unsigned = self; unsigned.signature = nil
        return try OwnerAttachWire.encode(unsigned)
    }
}

public struct OwnerAttachExtensionReceipt: Codable, Sendable {
    public let binding: OwnerAttachExtensionBinding
    public let firstConfirmedAt: Date
    public let ownershipCellUUID: String
    public let consent: OwnerAttachExtensionConsent
    public var signature: Data?

    public func validate(for binding: OwnerAttachExtensionBinding) throws {
        guard self.binding == binding, consent.offer.binding == binding,
              ownershipCellUUID == consent.offer.cellUUID, let signature,
              IdentityPublicKeySignatureVerifier.verify(signature: signature,
                messageData: try signingData(), identity: IdentityLinkProtocolService.identity(from: binding.receiver)) else {
            throw OwnerAttachExtensionError.invalidProof
        }
        // Validate historical evidence at the time it was committed. This is a
        // receipt, not authority to bypass today's owner/revocation checks.
        try consent.validate(now: firstConfirmedAt)
    }

    func signingData() throws -> Data {
        var unsigned = self; unsigned.signature = nil
        return try OwnerAttachWire.encode(unsigned)
    }
}

public struct OwnerAttachExtensionPolicy: Codable, Sendable {
    public let binding: OwnerAttachExtensionBinding
    public let choice: OwnerAttachExtensionChoice
    public let expiresAt: Date
    public init(binding: OwnerAttachExtensionBinding, choice: OwnerAttachExtensionChoice, expiresAt: Date) {
        self.binding = binding; self.choice = choice; self.expiresAt = expiresAt
    }
    public func applies(to offer: OwnerAttachExtensionOffer, now: Date = Date()) -> Bool {
        choice != .once && binding == offer.binding && expiresAt > now
    }
}

/// Hosts supply private, durable storage. The contract is atomic replacement
/// plus read-after-write; errors must never be reported as completed presence.
public protocol OwnerAttachExtensionStore: Sendable {
    func read(id: String) async throws -> Data?
    func write(_ data: Data, id: String) async throws
}

/// One actor per receiving runtime. The receiver key belongs to the runtime,
/// never becomes a member of the human's entity, and only signs receipts.
public actor OwnerAttachEntityExtensionHost {
    public static let offerKeypath = "entityExtension.ownerAttach.offer"
    public static let acceptKeypath = "entityExtension.ownerAttach.accept"
    private let receiver: Identity
    private let label: String
    private let store: any OwnerAttachExtensionStore
    private let clock: @Sendable () -> Date
    private var committing: Set<String> = []

    public init(receiver: Identity, label: String, store: any OwnerAttachExtensionStore,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.receiver = receiver; self.label = label; self.store = store; self.clock = clock
    }

    public func offer(cell: GeneralCell, requester: Identity) async throws -> OwnerAttachExtensionOffer {
        try await cell.requireOwnerAttachProof(requester: requester)
        let offer = OwnerAttachExtensionOffer(
            binding: OwnerAttachExtensionBinding(version: 1, purpose: "owner_attach_presence",
                receiver: try IdentityLinkProtocolService.descriptor(for: receiver),
                requester: try IdentityLinkProtocolService.descriptor(for: requester), domain: cell.identityDomain),
            cellUUID: cell.uuid, cellOwner: try IdentityLinkProtocolService.descriptor(for: cell.storedOwnerIdentity),
            receiverLabel: label, nonce: try SecureRandom.data(count: 32), expiresAt: clock().addingTimeInterval(300))
        var signed = offer
        signed.signature = try await receiver.sign(data: offer.signingData())
        return signed
    }

    public func accept(_ consent: OwnerAttachExtensionConsent, cell: GeneralCell,
                       requester: Identity) async throws -> OwnerAttachExtensionReceipt {
        let now = clock()
        try consent.validate(now: now)
        let offer = consent.offer
        guard OwnerAttachWire.sameKey(offer.binding.receiver, try IdentityLinkProtocolService.descriptor(for: receiver)),
              OwnerAttachWire.sameKey(offer.binding.requester, try IdentityLinkProtocolService.descriptor(for: requester)),
              offer.cellUUID == cell.uuid, offer.binding.domain == cell.identityDomain,
              OwnerAttachWire.sameKey(offer.cellOwner, try IdentityLinkProtocolService.descriptor(for: cell.storedOwnerIdentity)) else {
            throw OwnerAttachExtensionError.wrongContext
        }
        let id = offer.binding.storageID
        guard committing.insert(id).inserted else { throw OwnerAttachExtensionError.busy }
        defer { committing.remove(id) }
        // A saved policy/receipt cannot resurrect revoked owner access. Check
        // the real Cell's current owner path on every completion and retry.
        try await cell.requireOwnerAttachProof(requester: requester)
        if let data = try await store.read(id: id) {
            let receipt = try OwnerAttachWire.decode(OwnerAttachExtensionReceipt.self, data: data)
            try receipt.validate(for: offer.binding)
            return receipt
        }
        guard clock() < offer.expiresAt else { throw OwnerAttachExtensionError.expired }
        var receipt = OwnerAttachExtensionReceipt(binding: offer.binding, firstConfirmedAt: now,
            ownershipCellUUID: cell.uuid, consent: consent)
        receipt.signature = try await receiver.sign(data: receipt.signingData())
        let data = try OwnerAttachWire.encode(receipt)
        try await store.write(data, id: id)
        guard try await store.read(id: id) == data else { throw OwnerAttachExtensionError.persistenceFailed }
        return receipt
    }
}

/// Runtime composition only; never populated from CellConfiguration or bridge
/// input. Unconfigured receivers fail closed and ordinary attach keeps working.
public actor OwnerAttachExtensionRuntime {
    public static let shared = OwnerAttachExtensionRuntime()
    public private(set) var host: OwnerAttachEntityExtensionHost?
    private var configurationToken = UUID()
    public func install(_ host: OwnerAttachEntityExtensionHost?) {
        configurationToken = UUID()
        self.host = host
    }
    func beginConfiguration() -> UUID {
        install(nil)
        return configurationToken
    }
    func finishConfiguration(_ host: OwnerAttachEntityExtensionHost, token: UUID) throws {
        guard token == configurationToken else { throw OwnerAttachExtensionError.unavailable }
        self.host = host
    }
}

/// Hosts wrap explicit user navigation (or an approved resume) in this context.
/// Generic/background Absorb retains its existing semantics without a context.
public enum OwnerAttachExtensionContext {
    public typealias Handler = @Sendable (GeneralCell, any Emit, String, Identity) async -> Void
    @TaskLocal public static var handler: Handler?
}

public enum OwnerAttachWire {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        guard data.count <= 256 * 1024 else { throw OwnerAttachExtensionError.invalidProof }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
    public static func value<T: Encodable>(from value: T) throws -> ValueType {
        try JSONDecoder().decode(ValueType.self, from: encode(value))
    }
    public static func decode<T: Decodable>(_ type: T.Type, from value: ValueType) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try decode(type, data: data)
    }
    public static func sameKey(_ a: IdentityPublicKeyDescriptor, _ b: IdentityPublicKeyDescriptor) -> Bool {
        a.uuid == b.uuid && a.publicKey == b.publicKey && a.algorithm == b.algorithm && a.curveType == b.curveType
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
