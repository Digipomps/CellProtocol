// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class OID4VPDCQLTests: XCTestCase {
    func testParsesSdJwtClaimSetsQuery() throws {
        let json = """
        {
          "credentials": [
            {
              "id": "pid",
              "format": "dc+sd-jwt",
              "meta": {
                "vct_values": ["https://credentials.example.com/identity_credential"]
              },
              "claims": [
                {"id": "a", "path": ["last_name"]},
                {"id": "b", "path": ["postal_code"]},
                {"id": "c", "path": ["locality"]},
                {"id": "d", "path": ["region"]},
                {"id": "e", "path": ["date_of_birth"]}
              ],
              "claim_sets": [
                ["a", "c", "d", "e"],
                ["a", "b", "e"]
              ]
            }
          ]
        }
        """

        let query = try OID4VPDCQLQuery.parse(Data(json.utf8))
        XCTAssertEqual(query.credentials.count, 1)

        let credential = try XCTUnwrap(query.credentialQuery(id: "pid"))
        XCTAssertEqual(credential.format, .sdJwtVc)
        XCTAssertTrue(credential.requiresCryptographicHolderBinding)
        XCTAssertEqual(credential.claimSets?.count, 2)
        XCTAssertEqual(credential.claims?.count, 5)

        if case .array(let values)? = credential.meta["vct_values"] {
            XCTAssertEqual(values, [.string("https://credentials.example.com/identity_credential")])
        } else {
            XCTFail("Expected vct_values array")
        }
    }

    func testParsesMdocCredentialSetsQuery() throws {
        let json = """
        {
          "credentials": [
            {
              "id": "mdl-id",
              "format": "mso_mdoc",
              "meta": {
                "doctype_value": "org.iso.18013.5.1.mDL"
              },
              "claims": [
                {"id": "given_name", "path": ["org.iso.18013.5.1", "given_name"]},
                {"id": "family_name", "path": ["org.iso.18013.5.1", "family_name"]}
              ]
            },
            {
              "id": "photo_card-id",
              "format": "mso_mdoc",
              "meta": {
                "doctype_value": "org.iso.23220.photoid.1"
              },
              "claims": [
                {"id": "given_name", "path": ["org.iso.18013.5.1", "given_name"]},
                {"id": "family_name", "path": ["org.iso.18013.5.1", "family_name"]}
              ]
            }
          ],
          "credential_sets": [
            {
              "options": [
                ["mdl-id"],
                ["photo_card-id"]
              ]
            }
          ]
        }
        """

        let query = try OID4VPDCQLQuery.parse(Data(json.utf8))
        XCTAssertEqual(query.credentials.count, 2)
        XCTAssertEqual(query.credentialSets?.count, 1)
        XCTAssertEqual(query.credentialSets?.first?.isRequired, true)

        let firstFormat = try XCTUnwrap(query.credentialQuery(id: "mdl-id")?.format)
        XCTAssertEqual(firstFormat, .isoMdoc)
    }

    func testParsesWildcardAndValueConstraints() throws {
        let json = """
        {
          "credentials": [
            {
              "id": "my_credential",
              "format": "dc+sd-jwt",
              "meta": {
                "vct_values": ["https://credentials.example.com/identity_credential"]
              },
              "claims": [
                {
                  "path": ["address", null, "postal_code"],
                  "values": ["90210", "90211"]
                },
                {
                  "path": ["age_over_18"],
                  "values": [true]
                }
              ]
            }
          ]
        }
        """

        let query = try OID4VPDCQLQuery.parse(Data(json.utf8))
        let claims = try XCTUnwrap(query.credentialQuery(id: "my_credential")?.claims)
        XCTAssertEqual(claims.count, 2)
        XCTAssertEqual(claims[0].path, [.key("address"), .wildcard, .key("postal_code")])
        XCTAssertEqual(claims[0].values, [.string("90210"), .string("90211")])
        XCTAssertEqual(claims[1].values, [.boolean(true)])
    }

    func testRejectsDuplicateCredentialIDs() throws {
        let json = """
        {
          "credentials": [
            {
              "id": "pid",
              "format": "dc+sd-jwt",
              "meta": {"vct_values": ["https://example.com/a"]}
            },
            {
              "id": "pid",
              "format": "dc+sd-jwt",
              "meta": {"vct_values": ["https://example.com/b"]}
            }
          ]
        }
        """

        XCTAssertThrowsError(try OID4VPDCQLQuery.parse(Data(json.utf8))) { error in
            XCTAssertEqual(error as? OID4VPDCQLError, .duplicateCredentialID("pid"))
        }
    }

    func testRejectsClaimSetsWithoutClaims() throws {
        let json = """
        {
          "credentials": [
            {
              "id": "pid",
              "format": "dc+sd-jwt",
              "meta": {"vct_values": ["https://example.com/pid"]},
              "claim_sets": [["a"]]
            }
          ]
        }
        """

        XCTAssertThrowsError(try OID4VPDCQLQuery.parse(Data(json.utf8))) { error in
            XCTAssertEqual(error as? OID4VPDCQLError, .claimSetsWithoutClaims(credentialID: "pid"))
        }
    }

    func testRejectsCredentialSetWithUnknownCredentialReference() throws {
        let json = """
        {
          "credentials": [
            {
              "id": "pid",
              "format": "dc+sd-jwt",
              "meta": {"vct_values": ["https://example.com/pid"]}
            }
          ],
          "credential_sets": [
            {
              "options": [["missing-id"]]
            }
          ]
        }
        """

        XCTAssertThrowsError(try OID4VPDCQLQuery.parse(Data(json.utf8))) { error in
            XCTAssertEqual(
                error as? OID4VPDCQLError,
                .credentialSetReferencesUnknownCredential(credentialID: "missing-id")
            )
        }
    }
}
