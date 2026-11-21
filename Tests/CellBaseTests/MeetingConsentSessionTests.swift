import XCTest
@testable import CellBase

final class MeetingConsentSessionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1000)
    let a = MeetingPrincipal(id: "a", signingKeyFingerprint: "a-key")
    let b = MeetingPrincipal(id: "b", signingKeyFingerprint: "b-key")
    let c = MeetingPrincipal(id: "c", signingKeyFingerprint: "c-key")
    let d = MeetingPrincipal(id: "d", signingKeyFingerprint: "d-key")
    func make(_ people: [MeetingPrincipal]) throws -> MeetingConsentSession {
        try MeetingConsentSession(owner: a, plan: MeetingPlan(purpose: "Felles referat", participants: people, recorder: a), now: now)
    }
    func approveAll(_ s: MeetingConsentSession, _ people: [MeetingPrincipal], at date: Date? = nil) throws -> MeetingPlanReference {
        let at = date ?? now; let ref = try s.snapshot(now: at).reference
        for p in people { try s.approve(by: p, expected: ref, now: at) }
        return ref
    }
    func testMissingApprovalPreventsActualSink() throws {
        let s = try make([a,b,c]); let ref = try s.snapshot(now: now).reference
        try s.approve(by: a, expected: ref, now: now); try s.approve(by: b, expected: ref, now: now)
        XCTAssertThrowsError(try s.start(by: a, expected: ref, now: now))
        var effects = 0
        XCTAssertThrowsError(try s.withAudioAdmission(epoch: UUID(), clock: {  now }) { effects += 1 })
        XCTAssertEqual(effects, 0)
        try s.approve(by: c, expected: ref, now: now)
        let p = try s.start(by: a, expected: ref, now: now)
        try s.withAudioAdmission(epoch: p.epoch, clock: {  now }) { effects += 1 }
        XCTAssertEqual(effects, 1)
    }
    func testNewParticipantStopsAndInvalidatesEveryOldApproval() throws {
        let s = try make([a,b,c]); let ref = try approveAll(s,[a,b,c])
        let old = try s.start(by: a, expected: ref, now: now)
        try s.replacePlan(MeetingPlan(purpose: "Felles referat",participants:[a,b,c,d],recorder:a),by:a,expected:ref,now:now)
        let snapshot = try s.snapshot(now: now)
        XCTAssertNil(snapshot.recording); XCTAssertTrue(snapshot.approvals.isEmpty)
        XCTAssertNotEqual(snapshot.reference.hash, ref.hash)
        XCTAssertThrowsError(try s.withAudioAdmission(epoch: old.epoch, clock: {  now }) { XCTFail("Old buffer admitted") })
        XCTAssertThrowsError(try s.approve(by: b, expected: ref, now: now))
        try s.approve(by:d,expected:snapshot.reference,now:now)
        XCTAssertThrowsError(try s.start(by:a,expected:snapshot.reference,now:now))
        _ = try approveAll(s,[a,b,c,d])
        XCTAssertNil(try s.snapshot(now:now).recording, "No automatic restart")
        let fresh = try s.start(by:a,expected:snapshot.reference,now:now)
        XCTAssertNotEqual(fresh.epoch,old.epoch)
        XCTAssertEqual(try s.snapshot(now:now).segments.first?.plan.participants,[a,b,c])
    }
    func testSameUUIDWithAnotherKeyCannotApproveOrStop() throws {
        let s = try make([a,b]); let ref = try s.snapshot(now:now).reference
        let forged = MeetingPrincipal(id:b.id,signingKeyFingerprint:"forged")
        XCTAssertThrowsError(try s.approve(by:forged,expected:ref,now:now))
        XCTAssertThrowsError(try s.stop(by:forged,now:now))
    }
    func testOwnerCannotReplaceAnotherPersonsApproval() throws {
        let s = try make([a,b]); let ref = try s.snapshot(now:now).reference
        for _ in 0..<4 { try s.approve(by:a,expected:ref,now:now) }
        XCTAssertEqual(try s.snapshot(now:now).approvals.count,1)
        XCTAssertThrowsError(try s.start(by:a,expected:ref,now:now))
    }
    func testDeclineStopsAndNeedsNewPlan() throws {
        let s = try make([a,b]); let ref = try approveAll(s,[a,b]); let permit = try s.start(by:a,expected:ref,now:now)
        try s.decline(by:b,expected:ref,now:now)
        XCTAssertThrowsError(try s.withAudioAdmission(epoch:permit.epoch, clock: { now }) { XCTFail() })
        let next = try s.snapshot(now:now).reference
        XCTAssertThrowsError(try s.approve(by:b,expected:next,now:now))
    }
    func testStopInvalidatesDelayedApprovalAndCallback() throws {
        let s = try make([a,b]); let ref = try approveAll(s,[a,b]); let p = try s.start(by:a,expected:ref,now:now)
        try s.stop(by:b,now:now)
        XCTAssertThrowsError(try s.approve(by:a,expected:ref,now:now))
        XCTAssertThrowsError(try s.withAudioAdmission(epoch:p.epoch, clock: { now }) { XCTFail() })
    }
    func testLeaseExpiryFailsClosedAndRequiresEveryoneAgain() throws {
        let s = try make([a,b]); let ref = try approveAll(s,[a,b]); let p = try s.start(by:a,expected:ref,now:now)
        let expired = now.addingTimeInterval(3)
        XCTAssertThrowsError(try s.withAudioAdmission(epoch:p.epoch, clock: { expired }) { XCTFail() })
        let state = try s.snapshot(now:expired)
        XCTAssertNil(state.recording); XCTAssertTrue(state.approvals.isEmpty)
        XCTAssertThrowsError(try s.start(by:a,expected:state.reference,now:expired))
    }
    func testRenewRequiresExactFreshPresenceSetAndRecorder() throws {
        let s = try make([a,b,c]); let ref = try approveAll(s,[a,b,c]); let p = try s.start(by:a,expected:ref,now:now)
        XCTAssertThrowsError(try s.renew(p,by:b,present:Set([a,b,c]),now:now))
        let renewed = try s.renew(p,by:a,present:Set([a,b,c]),now:now.addingTimeInterval(1))
        XCTAssertEqual(renewed.expiresAt,now.addingTimeInterval(4))
        XCTAssertThrowsError(try s.renew(renewed,by:a,present:Set([a,b]),now:now.addingTimeInterval(2)))
        XCTAssertNil(try s.snapshot(now:now.addingTimeInterval(2)).recording)
    }
    func testRestoreNeverRestoresConsentOrRecording() throws {
        let s = try make([a,b]); let ref = try approveAll(s,[a,b]); _ = try s.start(by:a,expected:ref,now:now)
        let bytes = try JSONEncoder().encode(s.snapshot(now:now))
        let restored = try MeetingConsentSession(owner:a,restoring:JSONDecoder().decode(MeetingConsentSnapshot.self,from:bytes),now:now)
        let state = try restored.snapshot(now:now)
        XCTAssertNil(state.recording); XCTAssertTrue(state.approvals.isEmpty)
        XCTAssertNotEqual(state.reference,ref); XCTAssertNotNil(state.segments.first?.stoppedAt)
        XCTAssertThrowsError(try restored.start(by:a,expected:state.reference,now:now))
    }
    func testInvalidRosterChangeStillClosesAudioGate() throws {
        let s = try make([a,b]); let ref = try approveAll(s,[a,b]); let p = try s.start(by:a,expected:ref,now:now)
        XCTAssertThrowsError(try s.replacePlan(MeetingPlan(purpose:"",participants:[a,b,c],recorder:a),by:a,expected:ref,now:now))
        XCTAssertThrowsError(try s.withAudioAdmission(epoch:p.epoch, clock: { now }) { XCTFail() })
        XCTAssertTrue(try s.snapshot(now:now).approvals.isEmpty)
        let next = try approveAll(s, [a,b]); let active = try s.start(by: a, expected: next, now: now)
        let invalidNumeric = MeetingPlan(purpose: "Meeting", participants: [a,b], recorder: a, rawAudioLifetime: .nan)
        XCTAssertThrowsError(try s.replacePlan(invalidNumeric, by: a, expected: next, now: now)) { error in
            XCTAssertEqual(error as? MeetingSessionError, .invalidPlan)
        }
        XCTAssertThrowsError(try s.withAudioAdmission(epoch: active.epoch, clock: { self.now }) { XCTFail("Invalid numeric proposal left gate open") })
    }
    func testChangedTermsInvalidateAllAndCannotUseOldReference() throws {
        let s = try make([a,b]); let ref = try approveAll(s,[a,b])
        try s.replacePlan(MeetingPlan(purpose:"Nytt formål",participants:[a,b],recorder:a),by:a,expected:ref,now:now)
        XCTAssertTrue(try s.snapshot(now:now).approvals.isEmpty)
        XCTAssertThrowsError(try s.start(by:a,expected:ref,now:now))
    }
    func testInvalidPlanAndClockRegressionDenyCapture() throws {
        XCTAssertThrowsError(try make([a,a]))
        XCTAssertThrowsError(try make([a]))
        let s = try make([a,b]); let ref = try approveAll(s,[a,b]); let p = try s.start(by:a,expected:ref,now:now)
        XCTAssertThrowsError(try s.withAudioAdmission(epoch:p.epoch, clock: { now.addingTimeInterval(-1) }) { XCTFail() })
        XCTAssertNil(try s.snapshot(now:now).recording)
    }
    func testExpiredConsentAndWrongRecorderCannotStart() throws {
        let s = try make([a,b]); let ref = try approveAll(s,[a,b])
        XCTAssertThrowsError(try s.start(by:b,expected:ref,now:now))
        XCTAssertThrowsError(try s.start(by:a,expected:ref,now:now.addingTimeInterval(3600)))
    }
    func testRepeatedRestoreCannotReplayConsentFromPriorIncarnation() throws {
        let s = try make([a,b]); _ = try approveAll(s,[a,b])
        let saved = try s.snapshot(now:now)
        let first = try MeetingConsentSession(owner:a,restoring:saved,now:now)
        let second = try MeetingConsentSession(owner:a,restoring:saved,now:now)
        let oldReference = try first.snapshot(now:now).reference
        let currentReference = try second.snapshot(now:now).reference
        XCTAssertEqual(oldReference.sessionID,currentReference.sessionID)
        XCTAssertNotEqual(oldReference.hash,currentReference.hash)
        XCTAssertThrowsError(try second.approve(by:b,expected:oldReference,now:now))
        XCTAssertTrue(try second.snapshot(now:now).approvals.isEmpty)
    }
    func testExpiredApprovalIsNotDisplayedOrExtendedByReplay() throws {
        let s = try make([a,b]); let ref = try approveAll(s,[a,b])
        let later = now.addingTimeInterval(3600)
        XCTAssertTrue(try s.snapshot(now:later).approvals.isEmpty)
        XCTAssertThrowsError(try s.approve(by:a,expected:ref,now:later))
        XCTAssertNotEqual(try s.snapshot(now:later).reference,ref)
        let fresh = try approveAll(s,[a,b],at:later)
        XCTAssertNoThrow(try s.start(by:a,expected:fresh,now:later))
    }

    func testStopRetryDoesNotStopANewerSegmentAndSurvivesRestore() throws {
        let s = try make([a,b]); let first = try approveAll(s,[a,b])
        _ = try s.start(by:a,expected:first,now:now)
        let operationID = UUID()
        try s.stop(by:b,operationID:operationID,now:now)
        let restored = try MeetingConsentSession(owner:a,restoring:s.snapshot(now:now),now:now)
        let fresh = try approveAll(restored,[a,b])
        let permit = try restored.start(by:a,expected:fresh,now:now)
        try restored.stop(by:b,operationID:operationID,now:now)
        XCTAssertEqual(try restored.snapshot(now:now).recording?.epoch,permit.epoch)
        XCTAssertThrowsError(try restored.stop(by:a,operationID:operationID,now:now))
        XCTAssertThrowsError(try restored.stop(by:b,operationID:operationID,expected:fresh,now:now))
        XCTAssertThrowsError(try restored.stop(by:b,operationID:operationID,now:now,reason:"changed"))
        try restored.stop(by:b,operationID:UUID(),now:now)
        XCTAssertNil(try restored.snapshot(now:now).recording)
    }

    func testRetriedApprovalDoesNotRenewOrRestoreConsent() throws {
        let s = try make([a,b]); let ref = try s.snapshot(now: now).reference; let id = UUID()
        try s.approve(by: b, operationID: id, expected: ref, now: now)
        let expiry = try XCTUnwrap(s.snapshot(now: now).approvals.first?.expiresAt)
        try s.approve(by: b, operationID: id, expected: ref, now: now.addingTimeInterval(1))
        XCTAssertEqual(try s.snapshot(now: now.addingTimeInterval(1)).approvals.first?.expiresAt, expiry)
        let saved = try s.snapshot(now: now.addingTimeInterval(1))
        let restored = try MeetingConsentSession(owner: a, restoring: saved, now: now.addingTimeInterval(2))
        try restored.approve(by: b, operationID: id, expected: ref, now: now.addingTimeInterval(2))
        XCTAssertTrue(try restored.snapshot(now: now.addingTimeInterval(2)).approvals.isEmpty)
        XCTAssertThrowsError(try restored.approve(by: a, operationID: id, expected: ref, now: now.addingTimeInterval(2)))
        XCTAssertThrowsError(try restored.stop(by: b, operationID: id, now: now.addingTimeInterval(2)))
    }
    func testRetriedDeclineCannotStopFreshlyApprovedSegment() throws {
        let s = try make([a,b]); let ref = try approveAll(s, [a,b]); let id = UUID()
        try s.decline(by: b, operationID: id, expected: ref, now: now)
        let state = try s.snapshot(now: now)
        try s.replacePlan(state.plan, by: a, expected: state.reference, now: now)
        let next = try approveAll(s, [a,b]); let active = try s.start(by: a, expected: next, now: now)
        try s.decline(by: b, operationID: id, expected: ref, now: now)
        XCTAssertEqual(try s.snapshot(now: now).recording?.epoch, active.epoch)
        XCTAssertThrowsError(try s.decline(by: b, operationID: id, expected: next, now: now))
        XCTAssertEqual(try s.snapshot(now: now).recording?.epoch, active.epoch)
    }
    func testPlanRetriesBindCompletePayloadAndKeepEveryoneApproved() throws {
        let id = UUID(); let plan = MeetingPlan(purpose: "Initial", participants: [a,b], recorder: a)
        let s = try MeetingConsentSession(owner: a, plan: plan, now: now, initialOperationID: id)
        let first = try approveAll(s, [a,b])
        try s.replacePlan(plan, by: a, operationID: id, expected: nil, now: now)
        XCTAssertEqual(try s.snapshot(now: now).approvals.count, 2)
        XCTAssertEqual(try s.snapshot(now: now).reference, first)
        let changed = MeetingPlan(purpose: "Changed", participants: [a,b,c], recorder: a)
        XCTAssertThrowsError(try s.replacePlan(changed, by: a, operationID: id, expected: nil, now: now))
        let changeID = UUID()
        try s.replacePlan(changed, by: a, operationID: changeID, expected: first, now: now)
        _ = try approveAll(s, [a,b,c])
        try s.replacePlan(changed, by: a, operationID: changeID, expected: first, now: now)
        XCTAssertEqual(try s.snapshot(now: now).approvals.count, 3)
    }
    func testRetriedFailedPlanDoesNotInvalidateLaterApprovals() throws {
        let s = try make([a,b]); let first = try approveAll(s, [a,b]); let id = UUID()
        let invalid = MeetingPlan(purpose: "", participants: [a,b], recorder: a)
        XCTAssertThrowsError(try s.replacePlan(invalid, by: a, operationID: id, expected: first, now: now))
        let state = try s.snapshot(now: now)
        try s.replacePlan(state.plan, by: a, expected: state.reference, now: now)
        _ = try approveAll(s, [a,b])
        let restored = try MeetingConsentSession(owner: a, restoring: s.snapshot(now: now), now: now)
        let next = try approveAll(restored, [a,b]); let active = try restored.start(by: a, expected: next, now: now)
        XCTAssertThrowsError(try restored.replacePlan(invalid, by: a, operationID: id, expected: first, now: now)) { error in
            XCTAssertEqual(error as? MeetingSessionError, .invalidPlan)
        }
        XCTAssertEqual(try restored.snapshot(now: now).recording?.epoch, active.epoch)
    }
    func testConcurrentStartAndNewParticipantAlwaysEndsClosed() throws {
        for _ in 0..<20 {
            let s = try make([a,b,c]); let ref = try approveAll(s, [a,b,c])
            let finished = DispatchGroup(); let begin = DispatchSemaphore(value: 0)
            let recorder = a; let date = now
            finished.enter()
            DispatchQueue.global().async {
                begin.wait()
                _ = try? s.start(by: recorder, expected: ref, now: date)
                finished.leave()
            }
            finished.enter()
            let changed = MeetingPlan(purpose: "Felles referat", participants: [a,b,c,d], recorder: a)
            DispatchQueue.global().async {
                begin.wait()
                do { try s.replacePlan(changed, by: recorder, expected: ref, now: date) }
                catch { XCTFail("Authorized roster update failed: \(error)") }
                finished.leave()
            }
            begin.signal(); begin.signal()
            XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
            let state = try s.snapshot(now: now)
            XCTAssertEqual(state.plan.participants.count, 4)
            XCTAssertTrue(state.approvals.isEmpty); XCTAssertNil(state.recording)
            XCTAssertThrowsError(try s.withAudioAdmission(epoch: UUID(), clock: { self.now }) { XCTFail("Post-join audio admitted") })
        }
    }

    func testRestorePreservesRefusalWithoutRestoringPositiveAuthority() throws {
        let s = try make([a,b]); let ref = try approveAll(s, [a,b])
        try s.decline(by: b, expected: ref, now: now)
        let restored = try MeetingConsentSession(owner: a, restoring: s.snapshot(now: now), now: now)
        let state = try restored.snapshot(now: now)
        XCTAssertEqual(state.declined, [b]); XCTAssertTrue(state.approvals.isEmpty)
        XCTAssertThrowsError(try restored.approve(by: b, expected: state.reference, now: now))
        XCTAssertThrowsError(try restored.start(by: a, expected: state.reference, now: now))
        try restored.replacePlan(state.plan, by: a, expected: state.reference, now: now)
        let fresh = try approveAll(restored, [a,b])
        XCTAssertNoThrow(try restored.start(by: a, expected: fresh, now: now))
    }

}
