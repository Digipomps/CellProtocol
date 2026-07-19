// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

final class DeviceIngressWireFixtureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_784_454_400)
    private let audience = "staging.haven.digipomps.org"
    private let body = Data(#"{"participantId":"binding-participant","pushToken":"private"}"#.utf8)
    private let challengeSHA256 = "5WQGMVU-MhOL4j27s7-apOeQiHw7IWZ7u1wLvHAnw1w"
    private let requestSHA256 = "5z0ZIkZWfiT6OzGAdUEpCLKBOKSVLxhxrbtOKKMuJ7k"

    func testGoldenChallengeAndRequestRemainCanonicalAndCryptographicallyBound() throws {
        let challengeData = try fixtureData(named: "DeviceIngressChallenge.v2.b64")
        let requestData = try fixtureData(named: "DeviceIngressRequest.v2.b64")
        let issuerKey = try XCTUnwrap(
            Data(base64Encoded: "AvY6ckguDhZKw7VAF+9wOjMasFkVaURnD3R69Jg3jtZo")
        )
        let pinnedIssuer = IdentityPublicKeyDescriptor(
            uuid: "11111111-1111-4111-8111-111111111111",
            displayName: nil,
            publicKey: issuerKey,
            algorithm: .ECDSA,
            curveType: .P256
        )

        XCTAssertEqual(
            DeviceIngressCanonicalWire.base64URL(
                DeviceIngressCanonicalWire.sha256(challengeData)
            ),
            challengeSHA256
        )
        XCTAssertEqual(
            DeviceIngressCanonicalWire.base64URL(
                DeviceIngressCanonicalWire.sha256(requestData)
            ),
            requestSHA256
        )

        let pair = try DeviceIngressEnvelopeVerifier.verifyRequest(
            canonicalData: requestData,
            protectedBody: body,
            canonicalChallengeData: challengeData,
            expectedAudience: audience,
            expectedChallengeIssuer: pinnedIssuer,
            now: now
        )

        XCTAssertEqual(try pair.challenge.canonicalWireData(), challengeData)
        XCTAssertEqual(try pair.request.canonicalWireData(), requestData)
        XCTAssertEqual(pair.request.operation, .register)
        XCTAssertEqual(pair.challenge.signer.algorithm, .ECDSA)
        XCTAssertEqual(pair.challenge.signer.curveType, .P256)
        XCTAssertEqual(pair.request.subject.algorithm, .ECDSA)
        XCTAssertEqual(pair.request.subject.curveType, .P256)
        XCTAssertEqual(pair.request.purpose, DeviceIngressEnvelope.purpose)
        XCTAssertEqual(pair.request.identityDomain, DeviceIngressEnvelope.identityDomain)
        XCTAssertEqual(pair.request.challengeSHA256, DeviceIngressCanonicalWire.sha256(challengeData))
        XCTAssertEqual(pair.request.bodySHA256, DeviceIngressCanonicalWire.sha256(body))
        XCTAssertEqual(
            pair.request.authority.targetCellUUID,
            "66666666-6666-4666-8666-666666666666"
        )
        XCTAssertEqual(pair.request.authority.targetOwnerIdentityUUID, pinnedIssuer.uuid)
        XCTAssertEqual(
            pair.request.authority.targetOwnerSigningKeyFingerprint,
            DeviceIngressEnvelopeVerifier.signingKeyFingerprint(for: pinnedIssuer)
        )
        XCTAssertEqual(pair.request.authority.signedAgreementSHA256.count, 32)
    }

    private func fixtureData(named name: String) throws -> Data {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
        let encoded = try String(contentsOf: fixtureURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(Data(base64Encoded: encoded))
    }
}
