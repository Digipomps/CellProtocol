// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class VCIssuerServiceSecurityTests: XCTestCase {
    func testMintVCRequiresIssuerPrivateKeyInExactHomeVault() async throws {
        let issuerVault = EphemeralIdentityVault()
        let subjectVault = EphemeralIdentityVault()
        let resolvedIssuer = await issuerVault.identity(for: "issuer", makeNewIfNotFound: true)
        let resolvedSubject = await subjectVault.identity(for: "subject", makeNewIfNotFound: true)
        let issuer = try XCTUnwrap(resolvedIssuer)
        let subject = try XCTUnwrap(resolvedSubject)

        let claim = try await VCIssuerService().mintVC(
            for: subject,
            claiming: ["role": .string("member")],
            type: "MembershipCredential",
            issuerIdentity: issuer
        )

        XCTAssertEqual(claim.credentialSubject["id"], .string(try subject.did()))
        let verifies = try await claim.verify(issuer: issuer)
        XCTAssertTrue(verifies)
    }

    func testMintVCRejectsIssuerPresentedThroughWrongVault() async throws {
        let issuerVault = EphemeralIdentityVault()
        let wrongVault = EphemeralIdentityVault()
        let subjectVault = EphemeralIdentityVault()
        let resolvedIssuer = await issuerVault.identity(for: "issuer", makeNewIfNotFound: true)
        let resolvedSubject = await subjectVault.identity(for: "subject", makeNewIfNotFound: true)
        let issuer = try XCTUnwrap(resolvedIssuer)
        let subject = try XCTUnwrap(resolvedSubject)

        let wrongVaultIssuer = Identity(
            issuer.uuid,
            displayName: issuer.displayName,
            identityVault: wrongVault
        )
        wrongVaultIssuer.publicSecureKey = issuer.publicSecureKey
        wrongVaultIssuer.homeVaultReference = issuer.homeVaultReference

        do {
            _ = try await VCIssuerService().mintVC(
                for: subject,
                claiming: ["role": .string("member")],
                type: "MembershipCredential",
                issuerIdentity: wrongVaultIssuer
            )
            XCTFail("A vault that does not own the issuer private key must never mint the credential")
        } catch let error as VCIssuerServiceError {
            XCTAssertEqual(error, .issuerControlProofRequired)
        }
    }
}
