import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Application policy, not an identity verifier. The Cell adapter must supply the
/// principal from the authorized requester, never from a caller-selected payload.
public struct MeetingPrincipal: Codable, Hashable, Sendable {
    public let id: String
    public let signingKeyFingerprint: String
    public init(id: String, signingKeyFingerprint: String) {
        self.id = id; self.signingKeyFingerprint = signingKeyFingerprint
    }
}

public struct MeetingPlan: Codable, Equatable, Sendable {
    public let purpose: String
    public let participants: [MeetingPrincipal]
    public let recorder: MeetingPrincipal
    public let locale: String
    public let processingRoute: String
    public let rawAudioLifetime: TimeInterval
    public let deliveryLifetime: TimeInterval
    public let recipientLifetime: TimeInterval
    public let consentLifetime: TimeInterval
    public init(purpose: String, participants: [MeetingPrincipal], recorder: MeetingPrincipal,
                locale: String = "nb-NO", processingRoute: String = "apple-speech-on-device",
                rawAudioLifetime: TimeInterval = 86400, deliveryLifetime: TimeInterval = 604800,
                recipientLifetime: TimeInterval = 2592000, consentLifetime: TimeInterval = 3600) {
        self.purpose = purpose; self.participants = participants; self.recorder = recorder
        self.locale = locale; self.processingRoute = processingRoute
        self.rawAudioLifetime = rawAudioLifetime; self.deliveryLifetime = deliveryLifetime
        self.recipientLifetime = recipientLifetime; self.consentLifetime = consentLifetime
    }
    public func validate() throws {
        guard !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !locale.isEmpty, processingRoute == "apple-speech-on-device",
              participants.count >= 2, participants.count <= 64,
              Set(participants).count == participants.count,
              Set(participants.map(\.id)).count == participants.count,
              participants.allSatisfy({ !$0.id.isEmpty && !$0.signingKeyFingerprint.isEmpty }),
              participants.contains(recorder),
              [rawAudioLifetime, deliveryLifetime, recipientLifetime, consentLifetime].allSatisfy({ $0.isFinite && $0 > 0 }),
              rawAudioLifetime <= 86400, deliveryLifetime <= 604800,
              recipientLifetime <= 2592000, consentLifetime <= 3600 else { throw MeetingSessionError.invalidPlan }
    }
}

public enum MeetingSessionError: String, Error, Codable {
    case invalidPlan, forbidden, stalePlan, consentIncomplete, consentExpired
    case consentDeclined, alreadyRecording, notRecording, staleEpoch, leaseExpired
    case wrongRecorder, clockRegressed, wrongPackage, deliveryExpired, unavailable, operationConflict
}

public struct MeetingPlanReference: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let revision: UInt64
    public let hash: String
}
public struct MeetingActionInput: Codable, Sendable {
    public let operationID: UUID
    public let expected: MeetingPlanReference
    public init(operationID: UUID = UUID(), expected: MeetingPlanReference) {
        self.operationID = operationID; self.expected = expected
    }
}
public struct MeetingConsentReceipt: Codable, Equatable, Sendable {
    public let participant: MeetingPrincipal
    public let plan: MeetingPlanReference
    public let approvedAt: Date
    public let expiresAt: Date
}
public struct MeetingRecordingPermit: Codable, Equatable, Sendable {
    public let plan: MeetingPlanReference
    public let segmentID: UUID
    public let epoch: UUID
    public let recorder: MeetingPrincipal
    public let expiresAt: Date
}
public struct MeetingSegment: Codable, Equatable, Sendable {
    public let id: UUID
    public let plan: MeetingPlan
    public let reference: MeetingPlanReference
    public let consents: [MeetingConsentReceipt]
    public let startedAt: Date
    public var stoppedAt: Date?
    public var stopReason: String?
}
public struct MeetingStopOperation: Codable, Equatable, Sendable {
    public let requester: MeetingPrincipal
    public let expected: MeetingPlanReference?
    public let reason: String
}
/// A replay record binds the entire command, not only its caller-selected ID.
/// Restoring this record never restores permission to collect audio.
public struct MeetingOperationRecord: Codable, Equatable, Sendable {
    public let digest: String
    public let failure: MeetingSessionError?
}
public struct MeetingConsentSnapshot: Codable, Sendable {
    public let plan: MeetingPlan
    public let reference: MeetingPlanReference
    public let approvals: [MeetingConsentReceipt]
    public let declined: [MeetingPrincipal]
    public let recording: MeetingRecordingPermit?
    public let segments: [MeetingSegment]
    public let stopOperations: [UUID: MeetingStopOperation]
    public let operations: [UUID: MeetingOperationRecord]?
    public var processingRevokedSegments: [UUID]? = nil
}

/// Serializes policy changes with buffer admission. No authority is encoded for
/// restoration: a restored instance always requires fresh consent from everyone.
/// purposeRef: purpose://candidate.palazzo-binding-og-samtykket-tale.consent
public final class MeetingConsentSession: @unchecked Sendable {
    private let lock = NSLock()
    private let owner: MeetingPrincipal
    private let sessionID: UUID
    // New process incarnation makes replayed approvals fail even when storage
    // restores the same snapshot more than once. Never persisted as authority.
    private let incarnation = UUID()
    private var plan: MeetingPlan
    private var cachedReference: MeetingPlanReference?
    private var revision: UInt64
    private var approvals: [MeetingPrincipal: MeetingConsentReceipt] = [:]
    private var declined: Set<MeetingPrincipal> = []
    private var recording: MeetingRecordingPermit?
    private var segments: [MeetingSegment] = []
    private var processingRevokedSegments: Set<UUID> = []
    private var stopOperations: [UUID: MeetingStopOperation] = [:]
    private var operations: [UUID: MeetingOperationRecord] = [:]
    private var lastObserved: Date
    public static let maximumLease: TimeInterval = 3

    public init(owner: MeetingPrincipal, plan: MeetingPlan, now: Date = Date(), sessionID: UUID = UUID(), initialOperationID: UUID? = nil) throws {
        try plan.validate()
        guard plan.participants.contains(owner), now.timeIntervalSince1970.isFinite else { throw MeetingSessionError.invalidPlan }
        self.owner = owner; self.plan = plan; self.sessionID = sessionID
        revision = 1; lastObserved = now
        if let initialOperationID {
            operations[initialOperationID] = MeetingOperationRecord(
                digest: try Self.commandDigest("plan.propose", by: owner, expected: nil, plan: plan), failure: nil)
        }
    }
    public init(owner: MeetingPrincipal, restoring snapshot: MeetingConsentSnapshot, now: Date = Date()) throws {
        try snapshot.plan.validate()
        guard snapshot.plan.participants.contains(owner), snapshot.reference.revision < UInt64.max,
              now.timeIntervalSince1970.isFinite else { throw MeetingSessionError.invalidPlan }
        self.owner = owner; plan = snapshot.plan; sessionID = snapshot.reference.sessionID
        revision = snapshot.reference.revision + 1; lastObserved = now
        stopOperations = snapshot.stopOperations
        operations = snapshot.operations ?? [:]
        processingRevokedSegments = Set(snapshot.processingRevokedSegments ?? [])
        // A restart removes positive authority, but must not turn an explicit
        // refusal into an automatic new approval prompt for the same plan.
        declined = Set(snapshot.declined.filter { snapshot.plan.participants.contains($0) })
        segments = snapshot.segments.map { segment in
            var closed = segment
            if closed.stoppedAt == nil { closed.stoppedAt = now; closed.stopReason = "runtimeRestart" }
            return closed
        }
    }
    private func reference() -> MeetingPlanReference {
        if let cachedReference { return cachedReference }
        struct Binding: Encodable { let sessionID: UUID; let incarnation: UUID; let revision: UInt64; let plan: MeetingPlan }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Validated finite primitive values make this encoding total.
        let data = try! encoder.encode(Binding(sessionID: sessionID, incarnation: incarnation, revision: revision, plan: plan))
        let result = MeetingPlanReference(sessionID: sessionID, revision: revision,
                                    hash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        cachedReference = result
        return result
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
    private func checkClock(_ now: Date) throws {
        guard now.timeIntervalSince1970.isFinite, now >= lastObserved else {
            close(reason: "clockRegressed", at: lastObserved); invalidate()
            throw MeetingSessionError.clockRegressed
        }
        lastObserved = now
        if let permit = recording, now >= permit.expiresAt { close(reason: "leaseExpired", at: now); invalidate() }
        if approvals.values.contains(where: { now >= $0.expiresAt }) {
            close(reason: "consentExpired", at: now); invalidate()
        }
    }
    private func invalidate() {
        approvals.removeAll(); cachedReference = nil
        if revision < UInt64.max { revision += 1 }
    }
    private func close(reason: String, at now: Date) {
        if let permit = recording, let index = segments.firstIndex(where: { $0.id == permit.segmentID }) {
            segments[index].stoppedAt = now; segments[index].stopReason = reason
        }
        recording = nil
    }
    private func member(_ principal: MeetingPrincipal) throws {
        guard plan.participants.contains(principal) else { throw MeetingSessionError.forbidden }
    }
    private func current(_ ref: MeetingPlanReference) throws {
        guard revision < UInt64.max else { throw MeetingSessionError.unavailable }
        guard ref == reference() else { throw MeetingSessionError.stalePlan }
    }
    private func allApproved(at now: Date) throws {
        guard declined.isEmpty else { throw MeetingSessionError.consentDeclined }
        guard plan.participants.allSatisfy({ approvals[$0]?.plan == reference() }) else { throw MeetingSessionError.consentIncomplete }
        guard plan.participants.allSatisfy({ approvals[$0]!.expiresAt > now }) else { throw MeetingSessionError.consentExpired }
    }
    public func snapshot(now: Date) throws -> MeetingConsentSnapshot {
        try locked {
            try checkClock(now)
            return MeetingConsentSnapshot(plan: plan, reference: reference(),
                approvals: plan.participants.compactMap { approvals[$0] }.filter { $0.expiresAt > now },
                declined: plan.participants.filter { declined.contains($0) }, recording: recording, segments: segments, stopOperations: stopOperations, operations: operations,
                processingRevokedSegments: processingRevokedSegments.sorted { $0.uuidString < $1.uuidString })
        }
    }
    /// A proposed roster/terms change first stops collection and invalidates ALL
    /// approvals, including the existing members, even if the new plan is invalid.
    public func replacePlan(_ newPlan: MeetingPlan, by requester: MeetingPrincipal,
                            operationID: UUID = UUID(), expected: MeetingPlanReference?, now: Date) throws {
        try locked {
            try checkClock(now); guard requester == owner else { throw MeetingSessionError.forbidden }
            try performOperation("plan.propose", id: operationID, by: requester, expected: expected, plan: newPlan) {
                guard let expected else { throw MeetingSessionError.stalePlan }
                try current(expected)
                close(reason: "planChanged", at: now); approvals.removeAll(); declined.removeAll()
                guard revision < UInt64.max else { throw MeetingSessionError.unavailable }
                revision += 1; cachedReference = nil
                try newPlan.validate()
                guard newPlan.participants.contains(owner) else { throw MeetingSessionError.invalidPlan }
                plan = newPlan
            }
        }
    }
    public func approve(by requester: MeetingPrincipal, operationID: UUID = UUID(), expected: MeetingPlanReference, now: Date, signedExpiry: Date? = nil) throws {
        try locked {
            try checkClock(now); try member(requester)
            try performOperation("consent.approve", id: operationID, by: requester, expected: expected, consentExpiry: signedExpiry) {
                if let signedExpiry { guard signedExpiry.timeIntervalSince1970.isFinite, signedExpiry > now else { throw MeetingSessionError.consentExpired } }
                try current(expected)
                guard !declined.contains(requester) else { throw MeetingSessionError.consentDeclined }
                // An additional click cannot extend the original approval lifetime.
                if approvals[requester] != nil { return }
                approvals[requester] = MeetingConsentReceipt(participant: requester, plan: reference(),
                    approvedAt: now, expiresAt: min(now.addingTimeInterval(plan.consentLifetime), signedExpiry ?? .distantFuture))
            }
        }
    }
    public func decline(by requester: MeetingPrincipal, operationID: UUID = UUID(), expected: MeetingPlanReference, now: Date) throws {
        try locked {
            try checkClock(now); try member(requester)
            try performOperation("consent.decline", id: operationID, by: requester, expected: expected) {
                try current(expected)
                // Negative processing authority belongs to the original segment;
                // later roster changes must not erase it. Already delivered
                // copies need their own recipient-side revocation contract.
                processingRevokedSegments.formUnion(segments.filter { $0.plan.participants.contains(requester) }.map(\.id))
                close(reason: "consentDeclined", at: now); invalidate(); declined.insert(requester)
            }
        }
    }
    /// Leaving the current roster does not remove a participant's authority to
    /// stop further processing of a segment they originally approved.
    public func revokeProcessing(segmentID: UUID, by requester: MeetingPrincipal,
                                 operationID: UUID = UUID(), expected: MeetingPlanReference, now: Date) throws {
        try locked {
            try checkClock(now)
            guard let segment = segments.first(where: { $0.id == segmentID }),
                  segment.plan.participants.contains(requester) else { throw MeetingSessionError.forbidden }
            try performOperation("segment.revoke", id: operationID, by: requester,
                                 expected: expected, segmentID: segmentID) {
                guard segment.reference == expected else { throw MeetingSessionError.stalePlan }
                processingRevokedSegments.insert(segmentID)
                if recording?.segmentID == segmentID {
                    close(reason: "processingRevoked", at: now); invalidate()
                    declined.insert(requester)
                }
            }
        }
    }
    static func commandDigest(_ action: String, by requester: MeetingPrincipal,
                                      expected: MeetingPlanReference?, plan: MeetingPlan? = nil,
                                      segmentID: UUID? = nil, consentExpiry: Date? = nil) throws -> String {
        struct Command: Encodable {
            let action: String; let requester: MeetingPrincipal
            let expected: MeetingPlanReference?; let plan: MeetingPlan?
            let segmentID: UUID?
            let consentExpiry: Date?
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Invalid numeric terms from a local Swift caller must still have a
        // replay key, so the proposal reaches stop-before-validation. JSON wire
        // decoding still rejects these string values as numeric plan fields.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let bytes = try encoder.encode(Command(action: action, requester: requester, expected: expected, plan: plan, segmentID: segmentID, consentExpiry: consentExpiry))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    /// Must run under lock after requester authentication. A lost response can be
    /// retried after a later plan without reapplying the old command. Remember
    /// failed proposals too: they may already have closed the audio gate.
    private func performOperation(_ action: String, id: UUID, by requester: MeetingPrincipal,
                                  expected: MeetingPlanReference?, plan: MeetingPlan? = nil, segmentID: UUID? = nil, consentExpiry: Date? = nil,
                                  body: () throws -> Void) throws {
        guard stopOperations[id] == nil else { throw MeetingSessionError.operationConflict }
        let digest = try Self.commandDigest(action, by: requester, expected: expected, plan: plan, segmentID: segmentID, consentExpiry: consentExpiry)
        if let previous = operations[id] {
            guard previous.digest == digest else { throw MeetingSessionError.operationConflict }
            if let failure = previous.failure { throw failure }
            return
        }
        do {
            try body()
            operations[id] = MeetingOperationRecord(digest: digest, failure: nil)
        } catch let error as MeetingSessionError {
            operations[id] = MeetingOperationRecord(digest: digest, failure: error)
            throw error
        }
    }
    public func stop(by requester: MeetingPrincipal, operationID: UUID = UUID(), expected: MeetingPlanReference? = nil, now: Date, reason: String = "participantStopped") throws {
        try locked {
            try checkClock(now); try member(requester)
            guard operations[operationID] == nil else { throw MeetingSessionError.operationConflict }
            let operation = MeetingStopOperation(requester: requester, expected: expected, reason: reason)
            if let previous = stopOperations[operationID] {
                guard previous == operation else { throw MeetingSessionError.operationConflict }
                return // A delayed retry must not stop a later, freshly approved segment.
            }
            close(reason: reason, at: now)
            invalidate() // A fresh start requires a new reference and every participant again.
            stopOperations[operationID] = operation
        }
    }
    public func start(by requester: MeetingPrincipal, expected: MeetingPlanReference, now: Date) throws -> MeetingRecordingPermit {
        try locked {
            try checkClock(now); try member(requester); try current(expected)
            guard requester == plan.recorder else { throw MeetingSessionError.wrongRecorder }
            guard recording == nil else { throw MeetingSessionError.alreadyRecording }
            try allApproved(at: now)
            let deadline = min(now.addingTimeInterval(Self.maximumLease), approvals.values.map(\.expiresAt).min()!)
            let permit = MeetingRecordingPermit(plan: reference(), segmentID: UUID(), epoch: UUID(), recorder: requester, expiresAt: deadline)
            segments.append(MeetingSegment(id: permit.segmentID, plan: plan, reference: permit.plan,
                consents: plan.participants.compactMap { approvals[$0] }, startedAt: now))
            recording = permit; return permit
        }
    }
    /// Call only after authenticated fresh presence checks for every participant.
    /// A local timer must not manufacture remote liveness.
    public func renew(_ permit: MeetingRecordingPermit, by requester: MeetingPrincipal,
                      present: Set<MeetingPrincipal>, now: Date) throws -> MeetingRecordingPermit {
        try locked {
            try checkClock(now)
            guard requester == plan.recorder else { throw MeetingSessionError.wrongRecorder }
            guard let active = recording, active == permit else { throw MeetingSessionError.staleEpoch }
            guard present == Set(plan.participants) else {
                close(reason: "participantUnavailable", at: now); invalidate()
                throw MeetingSessionError.consentIncomplete
            }
            try allApproved(at: now)
            let renewed = MeetingRecordingPermit(plan: active.plan, segmentID: active.segmentID,
                epoch: active.epoch, recorder: requester,
                expiresAt: min(now.addingTimeInterval(Self.maximumLease), approvals.values.map(\.expiresAt).min()!))
            recording = renewed; return renewed
        }
    }
    /// The bounded synchronous sink executes inside the same gate as stop/roster
    /// mutation. Never suspend, reenter this session, or do network IO in the sink.
    public func withAudioAdmission<T>(epoch: UUID, clock: () -> Date = Date.init, sink: () throws -> T) throws -> T {
        try locked {
            // Sample AFTER acquiring the gate: a queued callback cannot use an
            // arrival timestamp from before the lease/consent expired.
            let now = clock()
            try checkClock(now)
            guard let active = recording else { throw MeetingSessionError.notRecording }
            guard active.epoch == epoch else { throw MeetingSessionError.staleEpoch }
            try allApproved(at: now)
            return try sink()
        }
    }

    /// A trusted device failure may close its own epoch only. Delayed Speech or
    /// microphone callbacks from an old segment cannot stop a later recording.
    public func captureFailed(epoch: UUID, now: Date, reason: String) {
        locked {
            guard recording?.epoch == epoch else { return }
            close(reason: reason, at: now)
            invalidate()
        }
    }
}
