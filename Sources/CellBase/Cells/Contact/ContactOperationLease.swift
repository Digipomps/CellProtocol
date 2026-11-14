// SPDX-License-Identifier: Apache-2.0
import Foundation
import Crypto

public enum ContactRetirement: String, Sendable {
    case cancelled, expired, authRevoked, linkChanged, targetChanged
    case grantChanged, blocked, routeChanged, sessionClosed, terminal
}

/// Host-provided application admission metadata, never a grant or wire proof.
/// The CS admission store must retire the lease before publishing a changed
/// auth/link/target/block/route revision. No authority is inferred from strings.
public struct ContactApplicationAdmission: Sendable {
    public let attemptID: UUID
    public let operationID: UUID
    public let bindingRecordID: String
    public let bindingGeneration: UInt64
    public let authenticationReference: String
    public let authenticationRevision: UInt64
    public let personLinkRevision: UInt64?
    public let intentRevision: UInt64
    public let routePolicyRevision: UInt64
    public let expiresAt: Date

    public init(attemptID: UUID, operationID: UUID = UUID(), bindingRecordID: String,
        bindingGeneration: UInt64, authenticationReference: String, authenticationRevision: UInt64,
        personLinkRevision: UInt64?, intentRevision: UInt64, routePolicyRevision: UInt64, expiresAt: Date) {
        self.attemptID = attemptID; self.operationID = operationID
        self.bindingRecordID = bindingRecordID; self.bindingGeneration = bindingGeneration
        self.authenticationReference = authenticationReference; self.authenticationRevision = authenticationRevision
        self.personLinkRevision = personLinkRevision; self.intentRevision = intentRevision
        self.routePolicyRevision = routePolicyRevision; self.expiresAt = expiresAt
    }
}

public struct ContactOperationSnapshot: Sendable {
    public let binding: VerifiedContactBinding
    public let admission: ContactApplicationAdmission
    public let requester: BridgeChannelAuthentication.PublicIdentity
    public let homeVaultReference: String
    public let requestID: String
    public let canonicalPayloadBytes: Data
    public let payloadDigest: Data
    public let expiresAt: Date
}

/// All constructor inputs are trusted host application state. This lease only
/// fences that state; recipient Cell authorization is still independent.
public final class ContactOperationLease: @unchecked Sendable {
    public let snapshot: ContactOperationSnapshot
    private let lock = NSLock()
    private let wallClock: @Sendable () -> Date
    private let monotonic: @Sendable () -> TimeInterval
    private let deadline: TimeInterval
    private var retired: ContactRetirement?
    private var dispatchAdmitted = false
    private var rpc: ContactRPCBinding?

    public convenience init(binding: VerifiedContactBinding, requester: Identity,
        admission: ContactApplicationAdmission, request: ValueType) throws {
        try self.init(binding: binding, requester: requester, admission: admission, request: request,
                      wallClock: Date.init, monotonic: { ProcessInfo.processInfo.systemUptime })
    }

    init(binding: VerifiedContactBinding, requester: Identity, admission: ContactApplicationAdmission,
         request: ValueType, wallClock: @escaping @Sendable () -> Date,
         monotonic: @escaping @Sendable () -> TimeInterval) throws {
        let descriptor = try BridgeChannelAuthentication.PublicIdentity(requester)
        let now = wallClock()
        guard descriptor == binding.reference.subject,
              try ContactReferenceCodec.milliseconds(now) >= binding.reference.issuedAtMilliseconds,
              let home = requester.homeVaultReference, !home.isEmpty,
              !admission.bindingRecordID.isEmpty, !admission.authenticationReference.isEmpty,
              case let .object(object) = request,
              case let .string(requestID)? = object["requestID"], !requestID.isEmpty, requestID.utf8.count <= 128,
              let expiry = ContactInboxCell.requestExpiry(object["expiresAt"]),
              expiry <= now.timeIntervalSince1970 + 7 * 86400,
              let payload = object["payload"], try JSONEncoder().encode(payload).count <= 32768,
              let agreement = object["agreement"], let target = object["targetBinding"],
              try ContactReferenceCodec.encode(agreement) == binding.contractBytes,
              try ContactReferenceCodec.encode(target) == binding.referenceBytes,
              Set(object.keys) == Set(["requestID", "expiresAt", "payload", "agreement", "targetBinding"]) else {
            throw ContactOperationFailure.invalidBinding
        }
        let effective = min(admission.expiresAt.timeIntervalSince1970,
                            binding.expiresAt.timeIntervalSince1970, expiry)
        guard effective.isFinite, effective > now.timeIntervalSince1970 else { throw ContactOperationFailure.expired }
        let bytes = try ContactReferenceCodec.encode(request)
        snapshot = ContactOperationSnapshot(binding: binding, admission: admission, requester: descriptor,
            homeVaultReference: home, requestID: requestID, canonicalPayloadBytes: bytes,
            payloadDigest: Data(SHA256.hash(data: bytes)), expiresAt: Date(timeIntervalSince1970: effective))
        self.wallClock = wallClock; self.monotonic = monotonic
        deadline = monotonic() + effective - now.timeIntervalSince1970
    }

    public func retire(_ reason: ContactRetirement) {
        lock.withLock { if retired == nil { retired = reason } }
    }

    public var applicationDispatchWasAdmitted: Bool { lock.withLock { dispatchAdmitted } }

    func withCurrent<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock { try Task.checkCancellation(); try checkLocked(); return try body() }
    }

    private func checkLocked() throws {
        if let retired {
            switch retired {
            case .cancelled: throw ContactOperationFailure.cancelled
            case .expired: throw ContactOperationFailure.expired
            case .routeChanged: throw ContactOperationFailure.routeChanged
            case .sessionClosed: throw ContactOperationFailure.channelClosed
            default: throw ContactOperationFailure.staleIntent
            }
        }
        guard monotonic() < deadline, wallClock() < snapshot.expiresAt else {
            retired = .expired
            throw ContactOperationFailure.expired
        }
    }

    func bindRPC(_ binding: ContactRPCBinding) throws {
        try lock.withLock {
            try checkLocked()
            guard rpc == nil, !dispatchAdmitted,
                  binding.logicalEndpoint == snapshot.binding.reference.logicalEndpoint else {
                throw ContactOperationFailure.staleIntent
            }
            rpc = binding
        }
    }

    func admitEnqueue<T>(binding: ContactRPCBinding, body: () throws -> T) throws -> T {
        try lock.withLock {
            try checkLocked()
            guard rpc == binding, !dispatchAdmitted else { throw ContactOperationFailure.staleIntent }
            // From this point onward an enqueue attempt may have an effect even
            // if its callback throws or cancellation arrives. Never roll back.
            dispatchAdmitted = true
            return try body()
        }
    }

    func complete(receipt: ContactHostReceiptV1, binding: ContactRPCBinding) throws -> ValidatedContactDelivery {
        try lock.withLock {
            try checkLocked()
            guard rpc == binding, dispatchAdmitted else { throw ContactOperationFailure.invalidReceipt }
            try receipt.validate(for: snapshot)
            let result = ValidatedContactDelivery(attemptID: snapshot.admission.attemptID,
                                                  receipt: receipt, rpc: binding)
            retired = .terminal
            return result
        }
    }
}

/// Only the actual Bridge lifecycle owner constructs this local correlation.
public struct ContactRPCBinding: Equatable, Sendable {
    public let logicalEndpoint: String
    public let physicalEndpoint: String
    public let routeGeneration: UInt64
    public let channelGeneration: String
    public let commandID: Int
    let ownerToken: UUID
    init(logicalEndpoint: String, physicalEndpoint: String, routeGeneration: UInt64,
         channelGeneration: String, commandID: Int, ownerToken: UUID) {
        self.logicalEndpoint = logicalEndpoint; self.physicalEndpoint = physicalEndpoint
        self.routeGeneration = routeGeneration; self.channelGeneration = channelGeneration
        self.commandID = commandID; self.ownerToken = ownerToken
    }
}

public struct ValidatedContactDelivery: Sendable {
    public let attemptID: UUID
    public let receipt: ContactHostReceiptV1
    public let rpc: ContactRPCBinding
    // No public init, Codable, or constructor from a stored receipt.
    init(attemptID: UUID, receipt: ContactHostReceiptV1, rpc: ContactRPCBinding) {
        self.attemptID = attemptID; self.receipt = receipt; self.rpc = rpc
    }
}

public enum ContactDeliveryOutcome: Sendable {
    case queued(ValidatedContactDelivery)
    case notSent(ContactOperationFailure)
    case unconfirmed(ContactOperationFailure)
}
