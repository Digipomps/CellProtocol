// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

final class DeviceIngressWireFixtureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_784_454_400)
    private let audience = "staging.haven.digipomps.org"
    private let body = Data(#"{"participantId":"binding-participant","pushToken":"private"}"#.utf8)

    func testGoldenVersion3RequestAgreementAndResponseRemainCryptographicallyBound() async throws {
        let challengeData = try fixtureData(named: "DeviceIngressChallenge.v3.b64")
        let requestData = try fixtureData(named: "DeviceIngressRequest.v3.b64")
        let signedContractData = try fixtureData(named: "DeviceIngressSignedContract.v3.b64")
        let responseData = try fixtureData(named: "DeviceIngressResponse.v3.b64")
        let challengeIssuer = IdentityPublicKeyDescriptor(
            uuid: "11111111-1111-4111-8111-111111111111",
            displayName: nil,
            publicKey: try XCTUnwrap(Data(base64Encoded: "vkaKzCt4StwmOSmlN3p6LBKrCYvrWiYyAXGyCjoc/tU=")),
            algorithm: .EdDSA,
            curveType: .Curve25519
        )

        XCTAssertEqual(digest(challengeData), "yk5RAiOuVI5tSCAEkmx9Mi7EmZ2OKCmEQBtrCCVPFd4")
        XCTAssertEqual(digest(requestData), "jIyh9exZhIjS2gZ0KRoGnNWxFpuyQZanZ_5Nh3DLmHc")
        XCTAssertEqual(digest(signedContractData), "XkamAnOF_UGvm1bjhwKY5beWZtWcJPC7FlZCfhee8IM")
        XCTAssertEqual(digest(responseData), "KRo1d1yb44JuSKbTMOqAJ9i-SQtv0Wl-nJRtoXDqoLA")

        let pair = try DeviceIngressEnvelopeVerifier.verifyRequest(
            canonicalData: requestData,
            protectedBody: body,
            canonicalChallengeData: challengeData,
            expectedAudience: audience,
            expectedChallengeIssuer: challengeIssuer,
            now: now
        )
        let contract = try JSONDecoder().decode(Contract.self, from: signedContractData)
        XCTAssertEqual(
            try SignedAgreementEntitySupport.canonicalData(contract),
            signedContractData
        )
        let contractBindingIsValid = await contract.verifyAuthorizationBinding(
            expectedIssuer: contract.issuer,
            expectedSubject: contract.subject,
            expectedDomain: DeviceIngressEnvelope.identityDomain,
            now: now
        )
        XCTAssertTrue(contractBindingIsValid)

        let authority = pair.request.authority
        XCTAssertEqual(pair.request.schema, DeviceIngressEnvelope.currentSchema)
        XCTAssertEqual(pair.request.requiredAccess, "rw-s")
        XCTAssertEqual(authority.schema, DeviceIngressAuthorityReference.currentSchema)
        XCTAssertEqual(authority.agreementID, contract.uuid)
        XCTAssertEqual(authority.signedAgreementSHA256, DeviceIngressCanonicalWire.sha256(signedContractData))
        XCTAssertEqual(authority.contentPolicy.schema, DeviceIngressContentPolicy.currentSchema)
        XCTAssertTrue(authority.contentPolicy.subjectResponseRetentionRequiresStorageGrant)

        let expectedGrant = Grant(
            keypath: try DeviceIngressAgreementScope(
                operation: .register,
                audience: audience,
                contentPolicy: authority.contentPolicy
            ).grantKeypath(),
            permission: DeviceIngressOperation.register.requiredAccess
        )
        XCTAssertTrue(contract.agreement.grants.contains { $0.granted(expectedGrant) })

        let response = try DeviceIngressOperationResponseVerifier.verify(
            canonicalData: responseData,
            expectation: DeviceIngressResponseExpectation(verifiedPair: pair)
        )
        XCTAssertEqual(response.operation, .register)
        XCTAssertEqual(response.result.kind, .registrationReceipt)
        XCTAssertEqual(response.subjectIdentityUUID, pair.request.subject.uuid)
        let responseText = try XCTUnwrap(String(data: responseData, encoding: .utf8))
        XCTAssertFalse(responseText.contains("pushToken"))
        XCTAssertFalse(responseText.contains("private"))
    }

    func testRawVersion2FixturesRemainPinnedNegativeVectors() throws {
        let challengeData = try fixtureData(named: "DeviceIngressChallenge.v2.b64")
        let requestData = try fixtureData(named: "DeviceIngressRequest.v2.b64")
        let signedContractData = try fixtureData(named: "DeviceIngressSignedContract.v2.b64")

        XCTAssertEqual(digest(challengeData), "sSYEKq6lAKGkN4NP72ylOY6ntGN9oT_eRt5VxwuLgSw")
        XCTAssertEqual(digest(requestData), "QY8wQAqdbJVS3sXrNS5nsGMbCr3vCfAxBRdM_vBXrRg")
        XCTAssertEqual(digest(signedContractData), "_LX7S-Y8Ew76LTlrvvFR48kMERtyZ8OZ30JaX3q5Cl8")
        XCTAssertEqual(try rawSchema(in: challengeData), "cellprotocol.device-ingress.envelope.v2")
        XCTAssertEqual(try rawSchema(in: requestData), "cellprotocol.device-ingress.envelope.v2")
        XCTAssertThrowsError(try DeviceIngressCanonicalWire.decodeCanonical(challengeData))
        XCTAssertThrowsError(try DeviceIngressCanonicalWire.decodeCanonical(requestData))
    }

    func testRawVersion1FixturesRemainPinnedNegativeVectors() throws {
        let challengeData = try fixtureData(named: "DeviceIngressChallenge.v1.b64")
        let requestData = try fixtureData(named: "DeviceIngressRequest.v1.b64")

        XCTAssertEqual(digest(challengeData), "9St5FxHjp374yXgwQW2PMCInxnD1qZnT_32dX1S0le0")
        XCTAssertEqual(digest(requestData), "wGaFHeAh5WFLZrecWeQr2LxI0ORPe8vjw6fx4HcUZAM")
        XCTAssertEqual(try rawSchema(in: challengeData), "cellprotocol.device-ingress.envelope.v1")
        XCTAssertEqual(try rawSchema(in: requestData), "cellprotocol.device-ingress.envelope.v1")
        XCTAssertThrowsError(try DeviceIngressCanonicalWire.decodeCanonical(challengeData))
        XCTAssertThrowsError(try DeviceIngressCanonicalWire.decodeCanonical(requestData))
    }

    private func digest(_ data: Data) -> String {
        DeviceIngressCanonicalWire.base64URL(DeviceIngressCanonicalWire.sha256(data))
    }

    private func rawSchema(in data: Data) throws -> String? {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return object["schema"] as? String
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
