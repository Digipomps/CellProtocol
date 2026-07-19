// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

final class DeviceIngressWireFixtureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_784_454_400)
    private let audience = "staging.haven.digipomps.org"
    private let body = Data(#"{"participantId":"binding-participant","pushToken":"private"}"#.utf8)
    private let challengeSHA256 = "9St5FxHjp374yXgwQW2PMCInxnD1qZnT_32dX1S0le0"
    private let requestSHA256 = "wGaFHeAh5WFLZrecWeQr2LxI0ORPe8vjw6fx4HcUZAM"

    func testGoldenChallengeAndRequestRemainCanonicalAndCryptographicallyBound() throws {
        let challengeData = try fixtureData(named: "DeviceIngressChallenge.v1.b64")
        let requestData = try fixtureData(named: "DeviceIngressRequest.v1.b64")
        let issuerKey = try XCTUnwrap(
            Data(base64Encoded: "/jh9Jtkcb6x61aq89vWFZuVS1/7YsH1PCqPPObhslus=")
        )
        let pinnedIssuer = IdentityPublicKeyDescriptor(
            uuid: "11111111-1111-4111-8111-111111111111",
            displayName: nil,
            publicKey: issuerKey,
            algorithm: .EdDSA,
            curveType: .Curve25519
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
        XCTAssertEqual(pair.request.purpose, DeviceIngressEnvelope.purpose)
        XCTAssertEqual(pair.request.identityDomain, DeviceIngressEnvelope.identityDomain)
        XCTAssertEqual(pair.request.challengeSHA256, DeviceIngressCanonicalWire.sha256(challengeData))
        XCTAssertEqual(pair.request.bodySHA256, DeviceIngressCanonicalWire.sha256(body))
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
