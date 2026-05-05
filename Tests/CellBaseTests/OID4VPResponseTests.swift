// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class OID4VPResponseTests: XCTestCase {
    func testBuildsSingleVPTokenResponseFromMatcherOutput() throws {
        let requestObject = OID4VPRequestObject(
            clientID: "https://verifier.example.org",
            responseType: OID4VPResponseType("vp_token"),
            dcqlQuery: OID4VPDCQLQuery(credentials: [
                OID4VPDCQLCredentialQuery(
                    id: "pid",
                    format: .sdJwtVc,
                    meta: ["vct_values": .array([.string("https://example.com/pid")])]
                )
            ]),
            state: "abc123"
        )

        let candidate = OID4VPCredentialCandidate(
            id: "credential-1",
            format: .sdJwtVc,
            meta: ["vct_values": .array([.string("https://example.com/pid")])],
            claims: .object([:]),
            presentation: .string("eyJhbGciOiJFUzI1NiJ9...")
        )

        let matches = try OID4VPRequestMatcher.match(requestObject: requestObject, candidates: [candidate])
        let response = try OID4VPResponseBuilder.build(
            requestObject: requestObject,
            matchResult: matches,
            idToken: "id-token",
            issuer: "https://wallet.example.org"
        )

        XCTAssertTrue(response.hasVPToken)
        XCTAssertEqual(response.state, "abc123")
        XCTAssertEqual(response.idToken, "id-token")
        XCTAssertEqual(response.issuer, "https://wallet.example.org")
        XCTAssertEqual(
            response.presentations(for: "pid"),
            [OID4VPResponsePresentation.string("eyJhbGciOiJFUzI1NiJ9...")]
        )
    }

    func testBuildsMultiplePresentationsWhenQueryAllowsMultiple() throws {
        let requestObject = OID4VPRequestObject(
            clientID: "https://verifier.example.org",
            responseType: OID4VPResponseType("vp_token"),
            dcqlQuery: OID4VPDCQLQuery(credentials: [
                OID4VPDCQLCredentialQuery(
                    id: "membership",
                    format: .jwtVcJson,
                    multiple: true,
                    meta: ["types": .array([.string("MembershipCredential")])]
                )
            ])
        )

        let first = OID4VPCredentialCandidate(
            id: "membership-a",
            format: .jwtVcJson,
            meta: ["types": .array([.string("MembershipCredential")])],
            claims: .object([:]),
            presentation: .string("jwt-a")
        )
        let second = OID4VPCredentialCandidate(
            id: "membership-b",
            format: .jwtVcJson,
            meta: ["types": .array([.string("MembershipCredential")])],
            claims: .object([:]),
            presentation: .object(["vp": .string("jwt-b")])
        )

        let matches = try OID4VPRequestMatcher.match(requestObject: requestObject, candidates: [first, second])
        let response = try OID4VPResponseBuilder.build(requestObject: requestObject, matchResult: matches)

        XCTAssertEqual(
            response.presentations(for: "membership"),
            [
                OID4VPResponsePresentation.string("jwt-a"),
                OID4VPResponsePresentation.object(["vp": .string("jwt-b")])
            ]
        )
    }

    func testOmitsAlternativeCredentialWithoutMatchWhenCredentialSetIsSatisfied() throws {
        let requestObject = OID4VPRequestObject(
            clientID: "https://verifier.example.org",
            responseType: OID4VPResponseType("vp_token"),
            dcqlQuery: OID4VPDCQLQuery(
                credentials: [
                    OID4VPDCQLCredentialQuery(
                        id: "mdl-id",
                        format: .isoMdoc,
                        meta: ["doctype_value": .string("org.iso.18013.5.1.mDL")]
                    ),
                    OID4VPDCQLCredentialQuery(
                        id: "photo-id",
                        format: .isoMdoc,
                        meta: ["doctype_value": .string("org.iso.23220.photoid.1")]
                    )
                ],
                credentialSets: [
                    OID4VPDCQLCredentialSetQuery(options: [["mdl-id"], ["photo-id"]])
                ]
            )
        )

        let candidate = OID4VPCredentialCandidate(
            id: "mdl",
            format: .isoMdoc,
            meta: ["doctype_value": .string("org.iso.18013.5.1.mDL")],
            claims: .object([:]),
            presentation: .object(["doctype": .string("org.iso.18013.5.1.mDL")])
        )

        let matches = try OID4VPRequestMatcher.match(requestObject: requestObject, candidates: [candidate])
        let response = try OID4VPResponseBuilder.build(requestObject: requestObject, matchResult: matches)

        XCTAssertEqual(
            response.presentations(for: "mdl-id"),
            [OID4VPResponsePresentation.object(["doctype": .string("org.iso.18013.5.1.mDL")])]
        )
        XCTAssertEqual(response.presentations(for: "photo-id"), [])
    }

    func testRejectsMatchedCandidateWithoutPresentationPayload() throws {
        let requestObject = OID4VPRequestObject(
            clientID: "https://verifier.example.org",
            responseType: OID4VPResponseType("vp_token"),
            dcqlQuery: OID4VPDCQLQuery(credentials: [
                OID4VPDCQLCredentialQuery(
                    id: "pid",
                    format: .sdJwtVc,
                    meta: ["vct_values": .array([.string("https://example.com/pid")])]
                )
            ])
        )

        let candidate = OID4VPCredentialCandidate(
            id: "credential-1",
            format: .sdJwtVc,
            meta: ["vct_values": .array([.string("https://example.com/pid")])],
            claims: .object([:])
        )

        let matches = try OID4VPRequestMatcher.match(requestObject: requestObject, candidates: [candidate])

        XCTAssertThrowsError(try OID4VPResponseBuilder.build(requestObject: requestObject, matchResult: matches)) { error in
            XCTAssertEqual(
                error as? OID4VPResponseError,
                .missingPresentation(queryID: "pid", candidateID: "credential-1")
            )
        }
    }
}
