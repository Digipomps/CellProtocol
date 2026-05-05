// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class OID4VPRequestMatcherTests: XCTestCase {
    func testMatchesRequestObjectAgainstCandidateUsingFormatMetaTrustAndWildcardClaims() throws {
        let requestObject = OID4VPRequestObject(
            clientID: "https://verifier.example.org",
            responseType: OID4VPResponseType("vp_token"),
            dcqlQuery: OID4VPDCQLQuery(credentials: [
                OID4VPDCQLCredentialQuery(
                    id: "pid",
                    format: .sdJwtVc,
                    meta: [
                        "vct_values": .array([.string("https://credentials.example.com/identity_credential")])
                    ],
                    trustedAuthorities: [
                        OID4VPDCQLTrustedAuthorityQuery(type: "issuer", values: ["did:web:issuer.example"])
                    ],
                    requireCryptographicHolderBinding: true,
                    claims: [
                        OID4VPDCQLClaimsQuery(
                            id: "postal",
                            path: [.key("address"), .wildcard, .key("postal_code")],
                            values: [.string("0123")]
                        ),
                        OID4VPDCQLClaimsQuery(
                            path: [.key("age_over_18")],
                            values: [.boolean(true)]
                        )
                    ]
                )
            ])
        )

        let candidate = OID4VPCredentialCandidate(
            id: "credential-1",
            format: .sdJwtVc,
            meta: [
                "vct_values": .array([
                    .string("https://credentials.example.com/identity_credential"),
                    .string("https://credentials.example.com/other")
                ])
            ],
            claims: .object([
                "address": .array([
                    .object(["postal_code": .string("0123")]),
                    .object(["postal_code": .string("9999")])
                ]),
                "age_over_18": .boolean(true)
            ]),
            trustedAuthorities: ["issuer": ["did:web:issuer.example"]],
            hasCryptographicHolderBinding: true
        )

        let result = try OID4VPRequestMatcher.match(requestObject: requestObject, candidates: [candidate])

        XCTAssertTrue(result.hasAnyMatches)
        XCTAssertTrue(result.satisfiesRequiredConstraints)
        XCTAssertEqual(result.unsatisfiedRequiredCredentialQueryIDs, [])
        XCTAssertEqual(result.unsatisfiedRequiredCredentialSetIndices, [])

        let match = try XCTUnwrap(result.matches(for: "pid").first)
        XCTAssertEqual(match.candidate.id, "credential-1")
        XCTAssertEqual(match.satisfiedClaimIDs, ["postal"])
        XCTAssertEqual(match.satisfiedClaimSetIndices, [])
    }

    func testClaimSetsRequireOneNamedAlternativeSetAndStillRequireUncoveredNamedClaims() {
        let query = OID4VPDCQLQuery(credentials: [
            OID4VPDCQLCredentialQuery(
                id: "pid",
                format: .sdJwtVc,
                meta: ["vct_values": .array([.string("https://example.com/pid")])],
                claims: [
                    OID4VPDCQLClaimsQuery(id: "family", path: [.key("family_name")]),
                    OID4VPDCQLClaimsQuery(id: "dob", path: [.key("date_of_birth")]),
                    OID4VPDCQLClaimsQuery(id: "postal", path: [.key("postal_code")])
                ],
                claimSets: [["family", "dob"]]
            )
        ])

        let matchingCandidate = OID4VPCredentialCandidate(
            id: "matching",
            format: .sdJwtVc,
            meta: ["vct_values": .array([.string("https://example.com/pid")])],
            claims: .object([
                "family_name": .string("Hansen"),
                "date_of_birth": .string("2010-01-01"),
                "postal_code": .string("0123")
            ])
        )

        let missingUncoveredNamedClaim = OID4VPCredentialCandidate(
            id: "missing-postal",
            format: .sdJwtVc,
            meta: ["vct_values": .array([.string("https://example.com/pid")])],
            claims: .object([
                "family_name": .string("Hansen"),
                "date_of_birth": .string("2010-01-01")
            ])
        )

        let result = OID4VPRequestMatcher.match(query: query, candidates: [matchingCandidate, missingUncoveredNamedClaim])

        XCTAssertEqual(result.matches(for: "pid").count, 1)
        XCTAssertEqual(result.matches(for: "pid").first?.candidate.id, "matching")
        XCTAssertEqual(result.matches(for: "pid").first?.satisfiedClaimSetIndices, [0])
        XCTAssertTrue(result.satisfiesRequiredConstraints)
    }

    func testCredentialSetsTreatAlternativeCredentialsAsSufficient() {
        let query = OID4VPDCQLQuery(
            credentials: [
                OID4VPDCQLCredentialQuery(
                    id: "mdl-id",
                    format: .isoMdoc,
                    meta: ["doctype_value": .string("org.iso.18013.5.1.mDL")]
                ),
                OID4VPDCQLCredentialQuery(
                    id: "photo_card-id",
                    format: .isoMdoc,
                    meta: ["doctype_value": .string("org.iso.23220.photoid.1")]
                )
            ],
            credentialSets: [
                OID4VPDCQLCredentialSetQuery(options: [["mdl-id"], ["photo_card-id"]])
            ]
        )

        let mdlCandidate = OID4VPCredentialCandidate(
            id: "mdl-credential",
            format: .isoMdoc,
            meta: ["doctype_value": .string("org.iso.18013.5.1.mDL")],
            claims: .object([:])
        )

        let result = OID4VPRequestMatcher.match(query: query, candidates: [mdlCandidate])

        XCTAssertEqual(result.matches(for: "mdl-id").count, 1)
        XCTAssertEqual(result.matches(for: "photo_card-id").count, 0)
        XCTAssertEqual(result.satisfiedCredentialSetIndices, [0])
        XCTAssertEqual(result.unsatisfiedRequiredCredentialQueryIDs, [])
        XCTAssertEqual(result.unsatisfiedRequiredCredentialSetIndices, [])
        XCTAssertTrue(result.satisfiesRequiredConstraints)
    }

    func testThrowsWhenRequestObjectDoesNotCarryDCQL() {
        let requestObject = OID4VPRequestObject(
            clientID: "https://verifier.example.org",
            responseType: OID4VPResponseType("code"),
            scope: "org.example.pid_presentation"
        )

        XCTAssertThrowsError(try OID4VPRequestMatcher.match(requestObject: requestObject, candidates: [])) { error in
            XCTAssertEqual(error as? OID4VPRequestMatcherError, .missingDCQLQuery)
        }
    }
}
