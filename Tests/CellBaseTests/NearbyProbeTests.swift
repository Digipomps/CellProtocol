import XCTest
@testable import CellApple

final class NearbyProbeTests: XCTestCase {
    private let local = NearbyBeacon(
        sessionUUID: "local",
        entityKind: .person,
        purposeTokens: ["11111111", "22222222"],
        interestTokens: ["aaaaaaaa"]
    )
    private let remote = NearbyBeacon(
        sessionUUID: "remote",
        entityKind: .organization,
        purposeTokens: ["11111111"],
        interestTokens: ["aaaaaaaa"]
    )

    private var policy: NearbyDisclosurePolicy {
        var policy = NearbyDisclosurePolicy.approved(
            entityKind: .person,
            purposeRefs: ["purpose://one"],
            interestRefs: ["interest://one"],
            now: 1_000
        )
        policy.probeMaxPerPeer = 2
        policy.probeMaxPerMinute = 12
        return policy
    }

    func testAutomaticResponseContainsOnlyBucketsAndNeverReferences() throws {
        var session = NearbyProbeSession()
        let request = NearbyProbeRequest(
            remoteUUID: "local",
            requestId: "request-1",
            nonce: "nonce-1",
            reasonTokens: ["11111111", "aaaaaaaa"]
        )

        let response = try session.aggregateResponse(
            to: request,
            from: "remote",
            localBeacon: local,
            remoteBeacon: remote,
            policy: policy,
            now: 1_001
        )
        let json = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)

        XCTAssertEqual(response.purposeMatches, .one)
        XCTAssertEqual(response.interestMatches, .one)
        XCTAssertFalse(json.contains("purpose://"))
        XCTAssertFalse(json.contains("interest://"))
        XCTAssertFalse(json.contains("references"))
    }

    func testDuplicateRequestIDIsRejected() throws {
        var session = NearbyProbeSession()
        let request = NearbyProbeRequest(remoteUUID: "local", requestId: "same", nonce: "nonce", reasonTokens: ["11111111"])
        _ = try session.aggregateResponse(to: request, from: "remote", localBeacon: local, remoteBeacon: remote, policy: policy, now: 1_001)

        XCTAssertThrowsError(
            try session.aggregateResponse(to: request, from: "remote", localBeacon: local, remoteBeacon: remote, policy: policy, now: 1_002)
        ) { XCTAssertEqual($0 as? NearbyProbeSession.ProbeError, .duplicateRequest) }
    }

    func testDuplicateNonceIsRejectedEvenWithFreshRequestID() throws {
        var session = NearbyProbeSession()
        let original = NearbyProbeRequest(remoteUUID: "local", requestId: "first", nonce: "replayed", reasonTokens: ["11111111"])
        let replay = NearbyProbeRequest(remoteUUID: "local", requestId: "second", nonce: "replayed", reasonTokens: ["11111111"])
        _ = try session.aggregateResponse(to: original, from: "remote", localBeacon: local, remoteBeacon: remote, policy: policy, now: 1_001)

        XCTAssertThrowsError(
            try session.aggregateResponse(to: replay, from: "remote", localBeacon: local, remoteBeacon: remote, policy: policy, now: 1_002)
        ) { XCTAssertEqual($0 as? NearbyProbeSession.ProbeError, .duplicateRequest) }
    }

    func testOversizedRequestIsRejectedRatherThanTruncated() {
        var session = NearbyProbeSession()
        let request = NearbyProbeRequest(
            remoteUUID: "local",
            requestId: "large",
            nonce: "nonce",
            reasonTokens: [String(repeating: "1", count: NearbyProbeSession.maximumPayloadBytes)]
        )

        XCTAssertThrowsError(
            try session.aggregateResponse(to: request, from: "remote", localBeacon: local, remoteBeacon: remote, policy: policy, now: 1_001)
        ) { XCTAssertEqual($0 as? NearbyProbeSession.ProbeError, .payloadTooLarge) }
    }

    func testExpiredPolicyDoesNotAnswer() {
        var session = NearbyProbeSession()
        let request = NearbyProbeRequest(remoteUUID: "local", requestId: "expired", nonce: "nonce", reasonTokens: ["11111111"])

        XCTAssertThrowsError(
            try session.aggregateResponse(to: request, from: "remote", localBeacon: local, remoteBeacon: remote, policy: policy, now: 1_000 + 8 * 60 * 60)
        ) { XCTAssertEqual($0 as? NearbyProbeSession.ProbeError, .policyInactive) }
    }

    func testStopEquivalentResetClearsNoncesAndResults() throws {
        var session = NearbyProbeSession()
        let request = NearbyProbeRequest(remoteUUID: "local", requestId: "again", nonce: "nonce", reasonTokens: ["11111111"])
        let response = try session.aggregateResponse(to: request, from: "remote", localBeacon: local, remoteBeacon: remote, policy: policy, now: 1_001)
        try session.store(.aggregate(response), for: "remote")
        session.reset()

        XCTAssertTrue(session.resultsByRemoteUUID.isEmpty)
        XCTAssertNoThrow(
            try session.aggregateResponse(to: request, from: "remote", localBeacon: local, remoteBeacon: remote, policy: policy, now: 1_002)
        )
    }

    func testOraclePeerAdvertisingEveryTokenReceivesAggregateAndZeroReferences() throws {
        let vocabulary = (0..<30).map { String(format: "%08x", $0) }
        let attacker = NearbyBeacon(
            sessionUUID: "attacker",
            entityKind: .agent,
            purposeTokens: vocabulary + local.purposeTokens,
            interestTokens: vocabulary + local.interestTokens
        )
        var session = NearbyProbeSession()
        let request = NearbyProbeRequest(
            remoteUUID: "local",
            requestId: "oracle",
            nonce: "fresh",
            reasonTokens: vocabulary + local.purposeTokens + local.interestTokens
        )

        let response = try session.aggregateResponse(
            to: request,
            from: "attacker",
            localBeacon: local,
            remoteBeacon: attacker,
            policy: policy,
            now: 1_001
        )
        let json = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)

        XCTAssertEqual(response.purposeMatches, .two)
        XCTAssertEqual(response.interestMatches, .one)
        XCTAssertFalse(json.contains("://"))
        XCTAssertFalse(json.contains("references"))
    }
}
