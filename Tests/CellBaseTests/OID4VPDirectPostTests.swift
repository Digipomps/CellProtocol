// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class OID4VPDirectPostTests: XCTestCase {
    func testBuildsDirectPostSubmissionForVPTokenResponse() throws {
        let requestObject = OID4VPRequestObject(
            clientID: "https://verifier.example.org",
            responseType: OID4VPResponseType("vp_token"),
            responseMode: .directPost,
            responseURI: URL(string: "https://verifier.example.org/post"),
            dcqlQuery: OID4VPDCQLQuery(credentials: [
                OID4VPDCQLCredentialQuery(id: "pid", format: .sdJwtVc, meta: [:])
            ]),
            state: "abc123"
        )
        let response = OID4VPResponse(
            vpToken: [
                "pid": [
                    .object([
                        "format": .string("dc+sd-jwt"),
                        "credential": .string("eyJhbGciOiJFUzI1NiJ9...")
                    ])
                ]
            ],
            state: "abc123",
            issuer: "https://wallet.example.org"
        )

        let submission = try OID4VPDirectPostBuilder.build(
            requestObject: requestObject,
            response: response
        )

        XCTAssertEqual(submission.responseMode, .directPost)
        XCTAssertEqual(submission.responseURI.absoluteString, "https://verifier.example.org/post")
        XCTAssertEqual(submission.contentType, "application/x-www-form-urlencoded")
        XCTAssertEqual(submission.formParameters["state"], "abc123")
        XCTAssertEqual(submission.formParameters["iss"], "https://wallet.example.org")

        let decodedBody = try parseFormBody(submission.bodyData())
        XCTAssertEqual(decodedBody["state"], "abc123")
        XCTAssertEqual(decodedBody["iss"], "https://wallet.example.org")
        XCTAssertEqual(
            decodedBody["vp_token"],
            #"{"pid":[{"credential":"eyJhbGciOiJFUzI1NiJ9...","format":"dc+sd-jwt"}]}"#
        )
    }

    func testBuildsDirectPostJWTSubmission() throws {
        let requestObject = OID4VPRequestObject(
            clientID: "https://verifier.example.org",
            responseType: OID4VPResponseType("vp_token"),
            responseMode: .directPostJwt,
            responseURI: URL(string: "https://verifier.example.org/post"),
            dcqlQuery: OID4VPDCQLQuery(credentials: [
                OID4VPDCQLCredentialQuery(id: "pid", format: .sdJwtVc, meta: [:])
            ])
        )

        let submission = try OID4VPDirectPostBuilder.build(
            requestObject: requestObject,
            response: OID4VPResponse(),
            jwtResponse: "eyJhbGciOiJFUzI1NiJ9.payload.signature"
        )

        XCTAssertEqual(submission.responseMode, .directPostJwt)
        XCTAssertEqual(submission.formParameters, ["response": "eyJhbGciOiJFUzI1NiJ9.payload.signature"])
        XCTAssertEqual(
            try parseFormBody(submission.bodyData()),
            ["response": "eyJhbGciOiJFUzI1NiJ9.payload.signature"]
        )
    }

    func testBuildsDirectPostErrorSubmission() throws {
        let requestObject = OID4VPRequestObject(
            clientID: "https://verifier.example.org",
            responseType: OID4VPResponseType("vp_token"),
            responseMode: .directPost,
            responseURI: URL(string: "https://verifier.example.org/post"),
            dcqlQuery: OID4VPDCQLQuery(credentials: [
                OID4VPDCQLCredentialQuery(id: "pid", format: .sdJwtVc, meta: [:])
            ])
        )

        let submission = try OID4VPDirectPostBuilder.buildError(
            requestObject: requestObject,
            errorResponse: OID4VPAuthorizationErrorResponse(
                error: "access_denied",
                errorDescription: "holder rejected request",
                state: "state-123"
            )
        )

        XCTAssertEqual(
            try parseFormBody(submission.bodyData()),
            [
                "error": "access_denied",
                "error_description": "holder rejected request",
                "state": "state-123"
            ]
        )
        XCTAssertTrue(String(decoding: submission.bodyData(), as: UTF8.self).contains("holder+rejected+request"))
    }

    func testParsesDirectPostCallbackWithRedirectURIAndAdditionalParameters() throws {
        let data = Data(
            """
            {
              "redirect_uri": "https://wallet.example.org/result",
              "transaction_id": "txn-123",
              "complete": true
            }
            """.utf8
        )

        let callback = try OID4VPDirectPostBuilder.parseCallback(data)

        XCTAssertEqual(callback.redirectURI?.absoluteString, "https://wallet.example.org/result")
        XCTAssertEqual(
            callback.additionalParameters,
            [
                "transaction_id": .string("txn-123"),
                "complete": .boolean(true)
            ]
        )
    }

    func testRejectsDirectPostCallbackWithRelativeRedirectURI() throws {
        let data = Data(
            """
            {
              "redirect_uri": "/result"
            }
            """.utf8
        )

        XCTAssertThrowsError(try OID4VPDirectPostBuilder.parseCallback(data)) { error in
            XCTAssertEqual(error as? OID4VPDirectPostError, .invalidRedirectURI)
        }
    }

    func testRejectsDirectPostJWTSubmissionWithoutJWTResponse() throws {
        let requestObject = OID4VPRequestObject(
            clientID: "https://verifier.example.org",
            responseType: OID4VPResponseType("vp_token"),
            responseMode: .directPostJwt,
            responseURI: URL(string: "https://verifier.example.org/post"),
            dcqlQuery: OID4VPDCQLQuery(credentials: [
                OID4VPDCQLCredentialQuery(id: "pid", format: .sdJwtVc, meta: [:])
            ])
        )

        XCTAssertThrowsError(
            try OID4VPDirectPostBuilder.build(
                requestObject: requestObject,
                response: OID4VPResponse()
            )
        ) { error in
            XCTAssertEqual(error as? OID4VPDirectPostError, .missingJWTResponse)
        }
    }

    private func parseFormBody(_ data: Data) throws -> [String: String] {
        let body = try XCTUnwrap(String(data: data, encoding: .utf8))
        guard !body.isEmpty else {
            return [:]
        }

        return Dictionary(uniqueKeysWithValues: try body.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(try XCTUnwrap(parts.first))
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding
            let value = (parts.count > 1 ? String(parts[1]) : "")
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding
            return (try XCTUnwrap(key), value ?? "")
        })
    }
}
