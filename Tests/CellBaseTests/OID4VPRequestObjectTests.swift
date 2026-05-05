// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class OID4VPRequestObjectTests: XCTestCase {
    func testParsesDirectPostRequestObjectWithDCQL() throws {
        let json = """
        {
          "client_id": "redirect_uri:https://client.example.org/cb",
          "response_type": "vp_token",
          "response_mode": "direct_post",
          "response_uri": "https://client.example.org/post",
          "dcql_query": {
            "credentials": [
              {
                "id": "pid",
                "format": "dc+sd-jwt",
                "meta": {
                  "vct_values": ["https://credentials.example.com/identity_credential"]
                }
              }
            ]
          },
          "nonce": "n-0S6_WzA2Mj",
          "state": "abc-._~123"
        }
        """

        let requestObject = try OID4VPRequestObject.parse(Data(json.utf8))

        XCTAssertEqual(requestObject.clientIdentifierPrefix, "redirect_uri")
        XCTAssertEqual(requestObject.clientIdentifierValue, "https://client.example.org/cb")
        XCTAssertEqual(requestObject.responseMode, .directPost)
        XCTAssertTrue(requestObject.responseType.includesVPToken)
        XCTAssertEqual(requestObject.responseURI?.absoluteString, "https://client.example.org/post")
        XCTAssertEqual(requestObject.dcqlQuery?.credentials.count, 1)
    }

    func testParsesCodeFlowRequestObjectWithScopeOnly() throws {
        let json = """
        {
          "client_id": "https://client.example.org/cb",
          "response_type": "code",
          "redirect_uri": "https://client.example.org/cb",
          "scope": "com.example.healthCardCredential_presentation",
          "state": "simple_state"
        }
        """

        let requestObject = try OID4VPRequestObject.parse(Data(json.utf8))

        XCTAssertEqual(requestObject.clientIdentifierPrefix, nil)
        XCTAssertEqual(requestObject.clientIdentifierValue, "https://client.example.org/cb")
        XCTAssertTrue(requestObject.responseType.includesAuthorizationCode)
        XCTAssertEqual(requestObject.scope, "com.example.healthCardCredential_presentation")
        XCTAssertNil(requestObject.dcqlQuery)
    }

    func testRejectsConflictingScopeAndDCQL() throws {
        let json = """
        {
          "client_id": "https://client.example.org/cb",
          "response_type": "vp_token",
          "dcql_query": {
            "credentials": [
              {
                "id": "pid",
                "format": "dc+sd-jwt",
                "meta": {
                  "vct_values": ["https://credentials.example.com/identity_credential"]
                }
              }
            ]
          },
          "scope": "com.example.healthCardCredential_presentation"
        }
        """

        XCTAssertThrowsError(try OID4VPRequestObject.parse(Data(json.utf8))) { error in
            XCTAssertEqual(error as? OID4VPRequestObjectError, .conflictingPresentationQueryParameters)
        }
    }

    func testRejectsDirectPostWithoutResponseURI() throws {
        let json = """
        {
          "client_id": "https://client.example.org/cb",
          "response_type": "vp_token",
          "response_mode": "direct_post",
          "dcql_query": {
            "credentials": [
              {
                "id": "pid",
                "format": "dc+sd-jwt",
                "meta": {
                  "vct_values": ["https://credentials.example.com/identity_credential"]
                }
              }
            ]
          }
        }
        """

        XCTAssertThrowsError(try OID4VPRequestObject.parse(Data(json.utf8))) { error in
            XCTAssertEqual(error as? OID4VPRequestObjectError, .missingResponseURI)
        }
    }

    func testRejectsVPTokenWithoutPresentationQuery() throws {
        let json = """
        {
          "client_id": "https://client.example.org/cb",
          "response_type": "vp_token"
        }
        """

        XCTAssertThrowsError(try OID4VPRequestObject.parse(Data(json.utf8))) { error in
            XCTAssertEqual(error as? OID4VPRequestObjectError, .missingPresentationQuery)
        }
    }

    func testRejectsInvalidStateCharacters() throws {
        let json = """
        {
          "client_id": "https://client.example.org/cb",
          "response_type": "code",
          "scope": "com.example.healthCardCredential_presentation",
          "state": "contains spaces"
        }
        """

        XCTAssertThrowsError(try OID4VPRequestObject.parse(Data(json.utf8))) { error in
            XCTAssertEqual(error as? OID4VPRequestObjectError, .invalidState)
        }
    }
}
