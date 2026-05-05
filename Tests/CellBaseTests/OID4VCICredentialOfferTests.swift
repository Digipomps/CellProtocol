// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class OID4VCICredentialOfferTests: XCTestCase {
    func testParsesAuthorizationCodeCredentialOfferObject() throws {
        let json = """
        {
          "credential_issuer": "https://credential-issuer.example.com",
          "credential_configuration_ids": [
            "UniversityDegreeCredential"
          ],
          "grants": {
            "authorization_code": {
              "issuer_state": "opaque-state",
              "authorization_server": "https://auth.example.com"
            }
          }
        }
        """

        let offer = try OID4VCICredentialOffer.parse(Data(json.utf8))

        XCTAssertEqual(offer.credentialIssuer, "https://credential-issuer.example.com")
        XCTAssertEqual(offer.credentialConfigurationIDs, ["UniversityDegreeCredential"])
        XCTAssertEqual(offer.grants?.authorizationCode?.issuerState, "opaque-state")
        XCTAssertEqual(offer.grants?.authorizationCode?.authorizationServer, "https://auth.example.com")
        XCTAssertNil(offer.grants?.preAuthorizedCode)
    }

    func testParsesByValueCredentialOfferURLWithPreAuthorizedCode() throws {
        let offerJSON = """
        {"credential_issuer":"https://credential-issuer.example.com","credential_configuration_ids":["UniversityDegree_LDP_VC"],"grants":{"urn:ietf:params:oauth:grant-type:pre-authorized_code":{"pre-authorized_code":"adhjhdjajkdkhjhdj","tx_code":{"length":4,"input_mode":"numeric","description":"Please provide the one-time code"}}}}
        """
        let encodedOffer = offerJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "openid-credential-offer://?credential_offer=\(encodedOffer)")!

        let envelope = try OID4VCICredentialOfferEnvelope.parse(url: url)
        let offer = try XCTUnwrap(envelope.offer)

        XCTAssertEqual(offer.credentialConfigurationIDs, ["UniversityDegree_LDP_VC"])
        XCTAssertEqual(offer.grants?.preAuthorizedCode?.preAuthorizedCode, "adhjhdjajkdkhjhdj")
        XCTAssertEqual(offer.grants?.preAuthorizedCode?.transactionCode?.length, 4)
        XCTAssertEqual(offer.grants?.preAuthorizedCode?.transactionCode?.inputMode, .numeric)
    }

    func testParsesByReferenceCredentialOfferURL() throws {
        let url = URL(string: "openid-credential-offer://?credential_offer_uri=https%3A%2F%2Fissuer.example.com%2Foffers%2F123")!

        let envelope = try OID4VCICredentialOfferEnvelope.parse(url: url)

        XCTAssertEqual(envelope.offerURL?.absoluteString, "https://issuer.example.com/offers/123")
        XCTAssertNil(envelope.offer)
    }

    func testRejectsConflictingOfferQueryParameters() throws {
        let url = URL(string: "openid-credential-offer://?credential_offer=%7B%7D&credential_offer_uri=https%3A%2F%2Fissuer.example.com%2Foffers%2F123")!

        XCTAssertThrowsError(try OID4VCICredentialOfferEnvelope.parse(url: url)) { error in
            XCTAssertEqual(error as? OID4VCICredentialOfferError, .conflictingOfferParameters)
        }
    }

    func testRejectsDuplicateCredentialConfigurationIDs() throws {
        let json = """
        {
          "credential_issuer": "https://credential-issuer.example.com",
          "credential_configuration_ids": [
            "UniversityDegreeCredential",
            "UniversityDegreeCredential"
          ]
        }
        """

        XCTAssertThrowsError(try OID4VCICredentialOffer.parse(Data(json.utf8))) { error in
            XCTAssertEqual(
                error as? OID4VCICredentialOfferError,
                .duplicateCredentialConfigurationID("UniversityDegreeCredential")
            )
        }
    }

    func testRejectsNonHTTPSCredentialIssuer() throws {
        let json = """
        {
          "credential_issuer": "http://credential-issuer.example.com",
          "credential_configuration_ids": [
            "UniversityDegreeCredential"
          ]
        }
        """

        XCTAssertThrowsError(try OID4VCICredentialOffer.parse(Data(json.utf8))) { error in
            XCTAssertEqual(error as? OID4VCICredentialOfferError, .invalidCredentialIssuer)
        }
    }
}
