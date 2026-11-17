import Foundation

/// Per-device client. Uses its own identity/vault for every signature, never
/// accepts a principal from a button payload and never approves from a timer.
/// The caller resolves the private Meddle endpoint through the normal resolver.
public actor MeetingParticipantClient {
    private let cellID: String
    private let target: any Meddle
    private let identity: Identity
    private let recorder: Identity
    private let inbox: MeetingDeliveryService
    private var permit: MeetingRecordingPermit?
    private var approvalAttempts: [UUID: MeetingSignedConsent] = [:]
    private struct Current: Decodable { let plan: MeetingPlan; let reference: MeetingPlanReference }
    public init(cellID: String, target: any Meddle, identity: Identity, recorder: Identity,
                inbox: MeetingDeliveryService) {
        self.cellID = cellID; self.target = target; self.identity = identity; self.recorder = recorder; self.inbox = inbox
    }
    private func current() async throws -> Current {
        let value = try await target.get(keypath: "plan.current", requester: identity)
        return try JSONDecoder().decode(Current.self, from: JSONEncoder().encode(value))
    }
    private func requireOK(_ value: ValueType?) throws {
        guard ExploreContract.object(from: value)?["status"] == .string("ok") else { throw MeetingSessionError.unavailable }
    }
    /// Only wire this to the user's explicit approval action for the shown ref.
    public func approve(expected: MeetingPlanReference, operationID: UUID = UUID()) async throws {
        let view = try await current()
        guard view.reference == expected else { throw MeetingSessionError.stalePlan }
        let evidence: MeetingSignedConsent
        if let existing = approvalAttempts[operationID] {
            guard existing.reference == expected, existing.plan == view.plan else { throw MeetingSessionError.operationConflict }
            evidence = existing
        } else {
            guard approvalAttempts.count < 4096 else { throw MeetingSessionError.unavailable }
            let signed = try await MeetingSignedConsent.approve(cellID: cellID, operationID: operationID,
                reference: expected, plan: view.plan, identity: identity)
            // Concurrent double invocation retains one exact signed command.
            evidence = approvalAttempts[operationID] ?? signed
            approvalAttempts[operationID] = evidence
        }
        try requireOK(try await target.set(keypath: "consent.submit", value: MeetingSurfaceConfiguration.encode(evidence), requester: identity))
    }
    public func start(expected: MeetingPlanReference, operationID: UUID = UUID()) async throws {
        let value = try await target.set(keypath: "recording.start", value: MeetingSurfaceConfiguration.encode(MeetingActionInput(operationID: operationID, expected: expected)), requester: identity)
        try requireOK(value)
        guard let encoded = ExploreContract.object(from: value)?["permit"] else { throw MeetingSessionError.unavailable }
        permit = try JSONDecoder().decode(MeetingRecordingPermit.self, from: JSONEncoder().encode(encoded))
    }
    public func stop(expected: MeetingPlanReference, operationID: UUID = UUID()) async throws {
        permit = nil
        try requireOK(try await target.set(keypath: "recording.stop", value: MeetingSurfaceConfiguration.encode(MeetingActionInput(operationID: operationID, expected: expected)), requester: identity))
    }
    /// Host calls once a second while this meeting is open and connected. Each
    /// participant runs their own pulse. Failure means no manufactured liveness.
    public func pulse() async throws {
        let view = try await current()
        try requireOK(try await target.set(keypath: "presence.confirm", value: MeetingSurfaceConfiguration.encode(view.reference), requester: identity))
        if let active = permit {
            guard active.plan == view.reference else { permit = nil; throw MeetingSessionError.stalePlan }
            guard let value = try await target.set(keypath: "recording.renew", value: MeetingSurfaceConfiguration.encode(active), requester: identity) else { throw MeetingSessionError.unavailable }
            permit = try JSONDecoder().decode(MeetingRecordingPermit.self, from: JSONEncoder().encode(value))
        }
    }
    /// Poll after stop/reconnect and while waiting for delivery. An offline client
    /// keeps its own inbox and resumes with the exact same signed receipt.
    @discardableResult public func synchronizeDelivery() async throws -> Int {
        let value = try await target.get(keypath: "delivery.index", requester: identity)
        let indexBytes = try JSONEncoder().encode(value)
        guard indexBytes.count <= 32768 else { throw MeetingSessionError.wrongPackage }
        let index = try JSONDecoder().decode([MeetingDeliveryIndex].self, from: indexBytes)
        guard index.count <= 16 else { throw MeetingSessionError.wrongPackage }
        var count = 0
        for entry in index {
            guard entry.byteCount > 0, entry.byteCount <= MeetingFileStore.maximumBytes else { throw MeetingSessionError.wrongPackage }
            var bytes = Data()
            while bytes.count < entry.byteCount {
                try Task.checkCancellation()
                let value = try await target.set(keypath: "delivery.fetch", value: MeetingSurfaceConfiguration.encode(MeetingDeliveryFetch(id: entry.id, offset: bytes.count)), requester: identity)
                let encoded = try JSONEncoder().encode(value)
                guard encoded.count < 256 * 1024 else { throw MeetingSessionError.wrongPackage }
                let chunk = try JSONDecoder().decode(MeetingDeliveryChunk.self, from: encoded)
                guard chunk.id == entry.id, chunk.offset == bytes.count, chunk.byteCount == entry.byteCount,
                      chunk.packetHash == entry.packetHash, !chunk.bytes.isEmpty,
                      chunk.bytes.count <= MeetingDeliveryChunk.maximumBytes,
                      chunk.bytes.count <= entry.byteCount - bytes.count else { throw MeetingSessionError.wrongPackage }
                bytes.append(chunk.bytes)
            }
            guard FlowHasher.sha256Hex(bytes) == entry.packetHash else { throw MeetingSessionError.wrongPackage }
            let packet = try JSONDecoder().decode(MeetingDeliveryPacket.self, from: bytes)
            guard packet.cellID == cellID else { throw MeetingSessionError.wrongPackage }
            let receipt = try await inbox.receive(packet, authenticatedSender: recorder)
            try requireOK(try await target.set(keypath: "delivery.receipt", value: MeetingSurfaceConfiguration.encode(receipt), requester: identity))
            count += 1
        }
        try await inbox.purgeExpired()
        return count
    }
}
