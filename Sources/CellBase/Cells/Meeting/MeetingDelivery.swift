import Foundation

/// Same canonical plaintext for every original participant. No raw audio, speaker
/// guesses, other meetings, vault references, or private keys belong here.
public struct MeetingTranscriptPackage: Codable, Equatable, Sendable {
    public let cellID: String
    public let segment: MeetingSegment
    public let consents: [MeetingSignedConsent]
    public let version: Int
    public let previousHash: String?
    public let transcript: String
    public let incomplete: Bool
    public let uncertainties: [String]
    public let createdAt: Date
    public let automaticUnapprovedTranscript: Bool

    public init(cellID: String, segment: MeetingSegment, consents: [MeetingSignedConsent],
                version: Int = 1, previousHash: String? = nil, transcript: String,
                incomplete: Bool, uncertainties: [String], createdAt: Date = Date()) {
        self.cellID = cellID; self.segment = segment; self.consents = consents
        self.version = version; self.previousHash = previousHash; self.transcript = transcript
        self.incomplete = incomplete; self.uncertainties = uncertainties; self.createdAt = createdAt
        automaticUnapprovedTranscript = true
    }
    public var id: String { segment.id.uuidString + "-v" + String(version) }
    public var deliveryExpiresAt: Date { segment.stoppedAt!.addingTimeInterval(segment.plan.deliveryLifetime) }
    public var recipientExpiresAt: Date { segment.stoppedAt!.addingTimeInterval(segment.plan.recipientLifetime) }

    public func validate() throws {
        try segment.plan.validate()
        guard UUID(uuidString: cellID) != nil, version > 0, version <= 10000,
              (version == 1 ? previousHash == nil : previousHash?.count == 64),
              automaticUnapprovedTranscript, transcript.utf8.count <= 4 * 1024 * 1024,
              uncertainties.count <= 128, uncertainties.allSatisfy({ $0.utf8.count <= 4096 }),
              segment.startedAt.timeIntervalSince1970.isFinite, createdAt.timeIntervalSince1970.isFinite,
              let stoppedAt = segment.stoppedAt, stoppedAt.timeIntervalSince1970.isFinite,
              stoppedAt >= segment.startedAt, createdAt >= stoppedAt,
              consents.count == segment.plan.participants.count,
              segment.consents.count == consents.count else { throw MeetingSessionError.wrongPackage }
        let principals = try consents.map { try $0.principal }
        guard Set(principals) == Set(segment.plan.participants), Set(principals).count == principals.count,
              Set(segment.consents.map(\.participant)) == Set(principals) else { throw MeetingSessionError.wrongPackage }
        for proof in consents {
            try proof.verify(cellID: cellID, reference: segment.reference, plan: segment.plan, at: segment.startedAt)
            guard let accepted = segment.consents.first(where: { $0.participant == (try? proof.principal) }),
                  accepted.plan == segment.reference, accepted.approvedAt >= proof.issuedAt,
                  accepted.approvedAt <= segment.startedAt, accepted.expiresAt > segment.startedAt else {
                throw MeetingSessionError.wrongPackage
            }
        }
    }
}

public struct MeetingDeliveryPacket: Codable, Equatable, Sendable {
    public let id: String
    public let cellID: String
    public let segmentID: UUID
    public let reference: MeetingPlanReference
    public let version: Int
    public let packageHash: String
    public let sender: MeetingPrincipal
    public let recipients: [MeetingPrincipal]
    public let deliveryExpiresAt: Date
    public let recipientExpiresAt: Date
    public let envelope: EncryptedContentEnvelope
    public var context: String { "haven.meeting.package.v1|" + cellID + "|" + id + "|" + packageHash }
}

public struct MeetingStoredReceipt: Codable, Equatable, Sendable {
    public let domain: String
    public let packetID: String
    public let cellID: String
    public let reference: MeetingPlanReference
    public let packageHash: String
    public let envelopeHash: String
    public let recipient: MeetingPrincipal
    public let storedAt: Date
    public let deleteBy: Date
    public private(set) var signature: Data

    fileprivate static func make(_ packet: MeetingDeliveryPacket, recipient: Identity, now: Date) async throws -> Self {
        var value = Self(domain: "haven.meeting.stored.v1", packetID: packet.id, cellID: packet.cellID,
                         reference: packet.reference, packageHash: packet.packageHash,
                         envelopeHash: try MeetingEvidence.hash(packet.envelope), recipient: try MeetingEvidence.principal(recipient),
                         storedAt: now, deleteBy: packet.recipientExpiresAt, signature: Data())
        value.signature = try await MeetingEvidence.sign(value, identity: recipient)
        return value
    }
    public func verify(packet: MeetingDeliveryPacket, signer: Identity, now: Date) throws {
        guard domain == "haven.meeting.stored.v1", packetID == packet.id, cellID == packet.cellID,
              reference == packet.reference, packageHash == packet.packageHash,
              envelopeHash == (try MeetingEvidence.hash(packet.envelope)),
              recipient == (try MeetingEvidence.principal(signer)), packet.recipients.contains(recipient),
              storedAt.timeIntervalSince1970.isFinite, storedAt <= now, storedAt < packet.deliveryExpiresAt,
              deleteBy == packet.recipientExpiresAt,
              MeetingEvidence.verify(self, signature: signature, identity: signer) else { throw MeetingSessionError.wrongPackage }
    }
}

public enum MeetingDeliveryState: String, Codable, Sendable { case queued, stored, expired }

/// Durable outbox/inbox for one local identity. Network transport must authenticate
/// the original requester; packet encryption and signed receipts additionally bind
/// content to the original segment roster. Reopening never resets expiry.
/// purposeRef: purpose://candidate.palazzo-binding-og-samtykket-tale.delivery
public actor MeetingDeliveryService {
    private let identity: Identity
    private let provider: any IdentityKeyRoleProviderProtocol
    private let store: any MeetingDurableStore
    private let authorizeRelease: @Sendable (UUID) throws -> Void
    public init(identity: Identity, provider: any IdentityKeyRoleProviderProtocol, store: any MeetingDurableStore,
                authorizeRelease: @escaping @Sendable (UUID) throws -> Void = { _ in }) {
        self.identity = identity; self.provider = provider; self.store = store; self.authorizeRelease = authorizeRelease
    }
    private func packetKey(_ id: String, inbox: Bool = false) -> String { (inbox ? "in-" : "out-") + id }
    private func receiptKey(_ packet: MeetingDeliveryPacket, recipient: MeetingPrincipal, inbox: Bool = false) -> String {
        (inbox ? "received-" : "receipt-") + packet.id + "-" + FlowHasher.sha256Hex(Data((recipient.id + "|" + recipient.signingKeyFingerprint).utf8))
    }
    private func decode<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        guard let bytes = try store.read(key) else { return nil }; return try JSONDecoder().decode(type, from: bytes)
    }

    /// Finalization retries return the exact original envelope. New versions never
    /// replace a prior transcript, and recipients cannot be expanded by a retry.
    public func enqueue(_ package: MeetingTranscriptPackage, now: Date = Date()) async throws -> MeetingDeliveryPacket {
        let began = ProcessInfo.processInfo.systemUptime
        try authorizeRelease(package.segment.id)
        try package.validate()
        guard try MeetingEvidence.principal(identity) == package.segment.plan.recorder,
              now >= package.createdAt, now < package.deliveryExpiresAt else { throw MeetingSessionError.deliveryExpired }
        let hash = try MeetingEvidence.hash(package)
        if let old = try decode(MeetingDeliveryPacket.self, key: packetKey(package.id)) {
            guard old.packageHash == hash else { throw MeetingSessionError.operationConflict }; return old
        }
        if package.version > 1 {
            let previousID = package.segment.id.uuidString + "-v" + String(package.version - 1)
            guard let previous = try decode(MeetingDeliveryPacket.self, key: packetKey(previousID)),
                  previous.packageHash == package.previousHash else { throw MeetingSessionError.wrongPackage }
        }
        let context = "haven.meeting.package.v1|" + package.cellID + "|" + package.id + "|" + hash
        // Sender is part of the original approved set. Envelope utility always
        // includes it; never use a server/service identity as sender here.
        let envelope = try await ContentCryptoEnvelopeUtility.seal(plaintext: MeetingEvidence.bytes(package), sender: identity,
            recipients: package.consents.map(\.identity), provider: provider, suite: .userOwnedBackupV1,
            associatedDataContext: context, includeRecipientIdentityMetadata: false)
        let packet = MeetingDeliveryPacket(id: package.id, cellID: package.cellID, segmentID: package.segment.id,
            reference: package.segment.reference, version: package.version, packageHash: hash,
            sender: package.segment.plan.recorder, recipients: package.segment.plan.participants,
            deliveryExpiresAt: package.deliveryExpiresAt, recipientExpiresAt: package.recipientExpiresAt, envelope: envelope)
        guard now.addingTimeInterval(ProcessInfo.processInfo.systemUptime - began) < package.deliveryExpiresAt else { throw MeetingSessionError.deliveryExpired }
        try authorizeRelease(package.segment.id)
        // Actor reentrancy during crypto: another finalization may have won.
        if let old = try decode(MeetingDeliveryPacket.self, key: packetKey(package.id)) {
            guard old.packageHash == hash else { throw MeetingSessionError.operationConflict }; return old
        }
        try store.commit(MeetingEvidence.bytes(packet), key: packetKey(packet.id))
        return packet
    }

    private func open(_ packet: MeetingDeliveryPacket, sender: Identity) async throws -> MeetingTranscriptPackage {
        guard packet.sender == (try MeetingEvidence.principal(sender)), packet.recipients.contains(try MeetingEvidence.principal(identity)),
              packet.envelope.header.associatedDataContext == packet.context,
              packet.envelope.header.suiteID == ContentCryptoSuite.userOwnedBackupV1.id else { throw MeetingSessionError.forbidden }
        let opened = try await ContentCryptoEnvelopeUtility.open(envelope: packet.envelope, recipient: identity, sender: sender, provider: provider)
        let package = try JSONDecoder().decode(MeetingTranscriptPackage.self, from: opened.plaintext)
        try package.validate()
        guard try MeetingEvidence.hash(package) == packet.packageHash, package.id == packet.id,
              package.cellID == packet.cellID, package.segment.id == packet.segmentID,
              package.segment.reference == packet.reference, package.version == packet.version,
              package.segment.plan.recorder == packet.sender, package.segment.plan.participants == packet.recipients,
              package.deliveryExpiresAt == packet.deliveryExpiresAt, package.recipientExpiresAt == packet.recipientExpiresAt else {
            throw MeetingSessionError.wrongPackage
        }
        return package
    }

    /// Returns a signed stored receipt only AFTER decrypt+proof+hash validation,
    /// encrypted disk commit and exact readback. No receipt on disk-full/failure.
    public func receive(_ packet: MeetingDeliveryPacket, authenticatedSender: Identity, now: Date = Date()) async throws -> MeetingStoredReceipt {
        let began = ProcessInfo.processInfo.systemUptime
        guard now.timeIntervalSince1970.isFinite, now < packet.deliveryExpiresAt, now < packet.recipientExpiresAt else {
            throw MeetingSessionError.deliveryExpired
        }
        let package = try await open(packet, sender: authenticatedSender)
        guard now >= package.createdAt else { throw MeetingSessionError.clockRegressed }
        guard now.addingTimeInterval(ProcessInfo.processInfo.systemUptime - began) < min(packet.deliveryExpiresAt, packet.recipientExpiresAt) else { throw MeetingSessionError.deliveryExpired }
        let principal = try MeetingEvidence.principal(identity)
        let key = receiptKey(packet, recipient: principal, inbox: true)
        if let previous = try decode(MeetingStoredReceipt.self, key: key) {
            try previous.verify(packet: packet, signer: identity, now: now)
            guard try store.read(packetKey(packet.id, inbox: true)) == MeetingEvidence.bytes(packet) else { throw MeetingSessionError.unavailable }
            return previous
        }
        try store.commit(MeetingEvidence.bytes(packet), key: packetKey(packet.id, inbox: true))
        let receipt = try await MeetingStoredReceipt.make(packet, recipient: identity, now: now)
        guard now.addingTimeInterval(ProcessInfo.processInfo.systemUptime - began) < min(packet.deliveryExpiresAt, packet.recipientExpiresAt),
              try store.read(packetKey(packet.id, inbox: true)) == MeetingEvidence.bytes(packet) else { throw MeetingSessionError.unavailable }
        if let previous = try decode(MeetingStoredReceipt.self, key: key) {
            try previous.verify(packet: packet, signer: identity, now: now); return previous
        }
        try store.commitReceipt(MeetingEvidence.bytes(receipt), key: key, requiring: MeetingEvidence.bytes(packet), packageKey: packetKey(packet.id, inbox: true))
        return receipt
    }

    public func acknowledge(_ receipt: MeetingStoredReceipt, authenticatedRecipient: Identity, now: Date = Date()) throws {
        guard let packet = try decode(MeetingDeliveryPacket.self, key: packetKey(receipt.packetID)),
              packet.sender == (try MeetingEvidence.principal(identity)) else { throw MeetingSessionError.wrongPackage }
        try receipt.verify(packet: packet, signer: authenticatedRecipient, now: now)
        try store.commit(MeetingEvidence.bytes(receipt), key: receiptKey(packet, recipient: receipt.recipient))
    }
    public func states(packetID: String, now: Date = Date()) throws -> [MeetingPrincipal: MeetingDeliveryState] {
        guard let packet = try decode(MeetingDeliveryPacket.self, key: packetKey(packetID)) else { throw MeetingSessionError.wrongPackage }
        return try Dictionary(uniqueKeysWithValues: packet.recipients.map { recipient in
            let stored = try store.read(receiptKey(packet, recipient: recipient)) != nil
            return (recipient, stored ? .stored : (now >= packet.deliveryExpiresAt ? .expired : .queued))
        })
    }
    public func containsPacket(_ id: String) throws -> Bool {
        try decode(MeetingDeliveryPacket.self, key: packetKey(id)) != nil
    }
    public func receivedPackets(now: Date = Date()) throws -> [MeetingDeliveryPacket] {
        try store.keys().filter { $0.hasPrefix("in-") }.compactMap {
            try decode(MeetingDeliveryPacket.self, key: $0)
        }.filter { $0.recipientExpiresAt > now }.sorted { $0.id < $1.id }
    }
    public func readReceived(packetID: String, sender: Identity, now: Date = Date()) async throws -> MeetingTranscriptPackage {
        guard let packet = try decode(MeetingDeliveryPacket.self, key: packetKey(packetID, inbox: true)),
              now < packet.recipientExpiresAt else { throw MeetingSessionError.deliveryExpired }
        let began = ProcessInfo.processInfo.systemUptime
        let package = try await open(packet, sender: sender)
        guard now >= package.createdAt, now.addingTimeInterval(ProcessInfo.processInfo.systemUptime - began) < packet.recipientExpiresAt,
              try store.read(packetKey(packet.id, inbox: true)) == MeetingEvidence.bytes(packet) else { throw MeetingSessionError.deliveryExpired }
        return package
    }
    public func pending(for recipient: MeetingPrincipal? = nil, now: Date = Date()) throws -> [MeetingDeliveryPacket] {
        try store.keys().filter { $0.hasPrefix("out-") }.compactMap { key in
            guard let packet = try decode(MeetingDeliveryPacket.self, key: key), now < packet.deliveryExpiresAt else { return nil }
            if let recipient {
                guard packet.recipients.contains(recipient), try store.read(receiptKey(packet, recipient: recipient)) == nil else { return nil }
            }
            do { try authorizeRelease(packet.segmentID) } catch MeetingSessionError.forbidden { return nil }
            return packet
        }
    }
    /// Retry worker used by the host on reconnect and after finalization. The
    /// transport's success response alone is insufficient: every receipt is
    /// verified against that recipient's original signed consent key.
    public func deliverPending(now: Date = Date(),
        send: @Sendable (MeetingPrincipal, MeetingDeliveryPacket) async throws -> MeetingStoredReceipt) async throws -> Int {
        let began = ProcessInfo.processInfo.systemUptime
        var confirmed = 0
        for packet in try pending(now: now) {
            let package = try await open(packet, sender: identity)
            for proof in package.consents {
                let recipient = try proof.principal
                if try store.read(receiptKey(packet, recipient: recipient)) != nil { continue }
                do {
                    try authorizeRelease(packet.segmentID)
                    guard now.addingTimeInterval(ProcessInfo.processInfo.systemUptime - began) < min(packet.deliveryExpiresAt, packet.recipientExpiresAt) else { continue }
                    let receipt = try await send(recipient, packet)
                    try acknowledge(receipt, authenticatedRecipient: proof.identity, now: max(now, Date()))
                    confirmed += 1
                } catch {
                    // Keep the original encrypted outbox record for retry. Never
                    // turn a timeout/lost receipt into a delivered indicator.
                    continue
                }
            }
        }
        return confirmed
    }

    /// Host schedules on launch/resume and periodically; access also enforces
    /// expiry. Removal is local unlink, not a promise about exported copies/backups.
    /// Removes one received package and its receipts from this device only.
    /// The sender's copy and other participants' copies are not touched.
    @discardableResult
    public func removeReceived(packetID: String) throws -> Bool {
        let key = packetKey(packetID, inbox: true)
        guard let packet = try decode(MeetingDeliveryPacket.self, key: key) else { return false }
        for recipient in packet.recipients { try store.remove(receiptKey(packet, recipient: recipient, inbox: true)) }
        try store.remove(key)
        return true
    }
    public func purgeExpired(now: Date = Date()) throws {
        for key in try store.keys() where key.hasPrefix("out-") || key.hasPrefix("in-") {
            guard let packet = try decode(MeetingDeliveryPacket.self, key: key) else { continue }
            let inbox = key.hasPrefix("in-")
            if now >= (inbox ? packet.recipientExpiresAt : packet.deliveryExpiresAt) {
                for recipient in packet.recipients { try store.remove(receiptKey(packet, recipient: recipient, inbox: inbox)) }
                try store.remove(key)
            }
        }
    }
}

/// Bounded application paging keeps large encrypted packages below Nearby's
/// physical frame limit. Hash validation precedes durable receive/receipt.
public struct MeetingDeliveryIndex: Codable, Sendable {
    public let id: String
    public let byteCount: Int
    public let packetHash: String
}
struct MeetingDeliveryFetch: Codable { let id: String; let offset: Int }
struct MeetingDeliveryChunk: Codable {
    let id: String; let offset: Int; let byteCount: Int; let packetHash: String; let bytes: Data
    static let maximumBytes = 128 * 1024
}
