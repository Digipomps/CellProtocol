import Foundation

/// Host-owned device boundary. Preparation must not collect audio. Each start
/// gets a fresh prepared object; stop must synchronously stop the physical input.
/// The implementation must gate EVERY buffer with session.withAudioAdmission.
public protocol MeetingPreparedCapture: AnyObject, Sendable {
    func start(session: MeetingConsentSession, permit: MeetingRecordingPermit) throws
    func stop()
    func cancelProcessing()
    var isProcessing: Bool { get }
}

public protocol MeetingCaptureDevice: Sendable {
    func prepare(plan: MeetingPlan) async throws -> any MeetingPreparedCapture
}

/// Coordinates device preparation and physical capture without manufacturing
/// remote presence. The host still owns authentication, durable consent and
/// verified lease renewal. This actor is not a network authorization boundary.
public actor MeetingCaptureCoordinator {
    private let session: MeetingConsentSession
    private let device: any MeetingCaptureDevice
    private let clock: @Sendable () -> Date
    private let beforeCapture: @Sendable (MeetingRecordingPermit) async throws -> Void
    private var pending: UUID?
    private var capture: (any MeetingPreparedCapture)?
    private var active: MeetingRecordingPermit?
    private var watchdog: Task<Void, Never>?
    private var finalizing: [UUID: any MeetingPreparedCapture] = [:]

    public init(session: MeetingConsentSession, device: any MeetingCaptureDevice,
                clock: @escaping @Sendable () -> Date = { Date() },
                beforeCapture: @escaping @Sendable (MeetingRecordingPermit) async throws -> Void = { _ in }) {
        self.session = session; self.device = device; self.clock = clock; self.beforeCapture = beforeCapture
    }

    deinit { watchdog?.cancel(); capture?.cancelProcessing(); finalizing.values.forEach { $0.cancelProcessing() } }

    /// OS permission waits never hold the policy gate. A changed plan or stop
    /// during any await invalidates the pending start, even if all later approve.
    public func start(by requester: MeetingPrincipal, expected: MeetingPlanReference) async throws -> MeetingRecordingPermit {
        guard pending == nil, capture == nil else { throw MeetingSessionError.alreadyRecording }
        checkAdmission()
        guard finalizing.count < 4 else { throw MeetingSessionError.unavailable }
        let snapshot = try session.snapshot(now: clock())
        guard snapshot.reference == expected else { throw MeetingSessionError.stalePlan }
        guard snapshot.plan.recorder == requester else { throw MeetingSessionError.wrongRecorder }
        guard Set(snapshot.approvals.map(\.participant)) == Set(snapshot.plan.participants), snapshot.declined.isEmpty else {
            throw MeetingSessionError.consentIncomplete
        }
        let attempt = UUID(); pending = attempt
        let prepared: any MeetingPreparedCapture
        do { prepared = try await device.prepare(plan: snapshot.plan) }
        catch { if pending == attempt { pending = nil }; throw error }
        guard pending == attempt, !Task.isCancelled else {
            if pending == attempt { pending = nil }
            prepared.stop(); throw MeetingSessionError.staleEpoch
        }
        pending = nil
        do {
            // Rechecks the entire current plan and consent after preparation.
            let permit = try session.start(by: requester, expected: expected, now: clock())
            do {
                try await beforeCapture(permit)
                try Task.checkCancellation()
                // Start cannot race a roster mutation at the policy boundary.
                // Device callbacks must not synchronously reenter this gate.
                try session.withAudioAdmission(epoch: permit.epoch, clock: clock) {
                    try prepared.start(session: session, permit: permit)
                }
            } catch {
                session.captureFailed(epoch: permit.epoch, now: clock(), reason: "deviceStartFailed")
                throw error
            }
            capture = prepared; active = permit
            watchdog?.cancel()
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                    guard let self else { return }
                    await self.checkAdmission()
                }
            }
            return permit
        } catch { prepared.stop(); throw error }
    }

    /// Called by the host after an authorized stop/roster mutation. Also polled
    /// independently of buffers, so a silent device cannot outlive its lease.
    public func checkAdmission() {
        let snapshot = try? session.snapshot(now: clock())
        let revoked = Set(snapshot?.processingRevokedSegments ?? [])
        let expired = Set(snapshot?.segments.filter {
            clock() >= $0.startedAt.addingTimeInterval($0.plan.rawAudioLifetime)
        }.map(\.id) ?? [])
        if let active {
            do { try session.withAudioAdmission(epoch: active.epoch, clock: clock) {} }
            catch { stopDevice(discardProcessing: revoked.contains(active.segmentID) || snapshot == nil) }
        }
        for (segmentID, device) in finalizing {
            if snapshot == nil || revoked.contains(segmentID) || expired.contains(segmentID) { device.cancelProcessing() }
            if !device.isProcessing { finalizing.removeValue(forKey: segmentID) }
        }
        if active == nil && finalizing.isEmpty {
            watchdog?.cancel(); watchdog = nil
        }
    }

    /// Authenticated participant stop. All approvals are invalidated by policy.
    public func stop(by requester: MeetingPrincipal, operationID: UUID = UUID()) throws {
        // Invalid requesters must not cancel someone else's pending capture.
        try session.stop(by: requester, operationID: operationID, now: clock())
        pending = nil
        checkAdmission()
    }

    private func stopDevice(discardProcessing: Bool = false) {
        if discardProcessing { capture?.cancelProcessing() } else { capture?.stop() }
        if let active, let capture, capture.isProcessing { finalizing[active.segmentID] = capture }
        capture = nil; active = nil
    }

    public var isCapturing: Bool { capture != nil }
}
