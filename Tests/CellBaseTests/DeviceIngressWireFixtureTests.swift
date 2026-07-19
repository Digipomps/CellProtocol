// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

final class DeviceIngressWireFixtureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_784_454_400)
    private let audience = "staging.haven.digipomps.org"
    private let body = Data(#"{"participantId":"binding-participant","pushToken":"private"}"#.utf8)
    private let challengeSHA256 = "sSYEKq6lAKGkN4NP72ylOY6ntGN9oT_eRt5VxwuLgSw"
    private let requestSHA256 = "QY8wQAqdbJVS3sXrNS5nsGMbCr3vCfAxBRdM_vBXrRg"
    private let signedContractSHA256 = "_LX7S-Y8Ew76LTlrvvFR48kMERtyZ8OZ30JaX3q5Cl8"

    func testGoldenChallengeRequestAndSignedContractRemainCryptographicallyBound() async throws {
        let challengeData = try fixtureData(named: "DeviceIngressChallenge.v2.b64")
        let requestData = try fixtureData(named: "DeviceIngressRequest.v2.b64")
        let signedContractData = try fixtureData(named: "DeviceIngressSignedContract.v2.b64")
        let challengeIssuerKey = try XCTUnwrap(
            Data(base64Encoded: "Alr2eo7lSwo9+YLt4NcIOtR3siC/wDThd2WFTB0WS+jG")
        )
        let challengeIssuer = IdentityPublicKeyDescriptor(
            uuid: "11111111-1111-4111-8111-111111111111",
            displayName: nil,
            publicKey: challengeIssuerKey,
            algorithm: .ECDSA,
            curveType: .P256
        )

        XCTAssertEqual(digest(challengeData), challengeSHA256)
        XCTAssertEqual(digest(requestData), requestSHA256)
        XCTAssertEqual(digest(signedContractData), signedContractSHA256)

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

        XCTAssertEqual(pair.challenge.signer.uuid, challengeIssuer.uuid)
        XCTAssertEqual(contract.issuer.uuid, "33333333-3333-4333-8333-333333333333")
        XCTAssertEqual(contract.subject.uuid, "22222222-2222-4222-8222-222222222222")
        XCTAssertNotEqual(pair.challenge.signer.uuid, contract.issuer.uuid)
        XCTAssertNotEqual(pair.challenge.signer.uuid, contract.subject.uuid)
        XCTAssertNotEqual(contract.issuer.uuid, contract.subject.uuid)

        let authority = pair.request.authority
        XCTAssertEqual(authority.agreementID, contract.uuid)
        XCTAssertEqual(authority.targetCellUUID, "66666666-6666-4666-8666-666666666666")
        XCTAssertEqual(authority.targetOwnerIdentityUUID, contract.issuer.uuid)
        XCTAssertEqual(
            authority.targetOwnerSigningKeyFingerprint,
            contract.issuer.signingPublicKeyFingerprint
        )
        XCTAssertEqual(authority.subjectIdentityUUID, contract.subject.uuid)
        XCTAssertEqual(
            authority.subjectSigningKeyFingerprint,
            contract.subject.signingPublicKeyFingerprint
        )
        XCTAssertEqual(
            authority.signedAgreementSHA256,
            DeviceIngressCanonicalWire.sha256(signedContractData)
        )
        XCTAssertTrue(contract.agreement.conditions.isEmpty)

        let expectedGrant = Grant(
            keypath: try DeviceIngressAgreementScope(
                operation: .register,
                audience: audience
            ).grantKeypath(),
            permission: DeviceIngressOperation.register.requiredAccess
        )
        XCTAssertTrue(contract.agreement.grants.contains { $0.granted(expectedGrant) })
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
