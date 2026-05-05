// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct OID4VPDirectPostJWTSubmissionPlan: Equatable, Sendable {
    public var matchResult: OID4VPRequestMatchResult
    public var response: OID4VPResponse
    public var resolvedVerifierMetadata: OID4VPResolvedVerifierMetadata?
    public var preparation: OID4VPDirectPostJWTPreparation
    public var jwe: JOSECompactJWE
    public var submission: OID4VPDirectPostSubmission

    public init(
        matchResult: OID4VPRequestMatchResult,
        response: OID4VPResponse,
        resolvedVerifierMetadata: OID4VPResolvedVerifierMetadata? = nil,
        preparation: OID4VPDirectPostJWTPreparation,
        jwe: JOSECompactJWE,
        submission: OID4VPDirectPostSubmission
    ) {
        self.matchResult = matchResult
        self.response = response
        self.resolvedVerifierMetadata = resolvedVerifierMetadata
        self.preparation = preparation
        self.jwe = jwe
        self.submission = submission
    }
}

public enum OID4VPDirectPostJWTSubmissionAdapter {
    public static func build(
        requestObject: OID4VPRequestObject,
        candidates: [OID4VPCredentialCandidate],
        preferredKeyID: String? = nil,
        preferredContentEncryptionAlgorithm: String? = nil,
        idToken: String? = nil,
        code: String? = nil,
        issuer: String? = nil
    ) throws -> OID4VPDirectPostJWTSubmissionPlan {
        let matchResult = try OID4VPRequestMatcher.match(
            requestObject: requestObject,
            candidates: candidates
        )
        let response = try OID4VPResponseBuilder.build(
            requestObject: requestObject,
            matchResult: matchResult,
            idToken: idToken,
            code: code,
            issuer: issuer
        )
        let resolvedVerifierMetadata = try requestObject.parsedVerifierMetadata().map {
            OID4VPResolvedVerifierMetadata(
                metadata: $0,
                source: .requestClientMetadata,
                clientIdentifierPrefix: requestObject.resolvedClientIdentifierPrefix
            )
        }
        let preparation = try OID4VPDirectPostJWTPreparationBuilder.build(
            requestObject: requestObject,
            response: response,
            preferredKeyID: preferredKeyID,
            preferredContentEncryptionAlgorithm: preferredContentEncryptionAlgorithm
        )
        let jwe = try OID4VPDirectPostJWTEncryptor.encrypt(preparation: preparation)
        let submission = try OID4VPDirectPostBuilder.build(
            requestObject: requestObject,
            response: response,
            jwtResponse: jwe.compactSerialization
        )

        return OID4VPDirectPostJWTSubmissionPlan(
            matchResult: matchResult,
            response: response,
            resolvedVerifierMetadata: resolvedVerifierMetadata,
            preparation: preparation,
            jwe: jwe,
            submission: submission
        )
    }

    public static func build(
        requestObject: OID4VPRequestObject,
        candidates: [OID4VPCredentialCandidate],
        metadataProvider: any OID4VPVerifierMetadataProvider,
        preferredKeyID: String? = nil,
        preferredContentEncryptionAlgorithm: String? = nil,
        idToken: String? = nil,
        code: String? = nil,
        issuer: String? = nil
    ) async throws -> OID4VPDirectPostJWTSubmissionPlan {
        let matchResult = try OID4VPRequestMatcher.match(
            requestObject: requestObject,
            candidates: candidates
        )
        let response = try OID4VPResponseBuilder.build(
            requestObject: requestObject,
            matchResult: matchResult,
            idToken: idToken,
            code: code,
            issuer: issuer
        )
        let resolvedVerifierMetadata = try await OID4VPVerifierMetadataResolver.resolve(
            requestObject: requestObject,
            provider: metadataProvider
        )
        let preparation = try OID4VPDirectPostJWTPreparationBuilder.build(
            requestObject: requestObject,
            resolvedVerifierMetadata: resolvedVerifierMetadata,
            response: response,
            preferredKeyID: preferredKeyID,
            preferredContentEncryptionAlgorithm: preferredContentEncryptionAlgorithm
        )
        let jwe = try OID4VPDirectPostJWTEncryptor.encrypt(preparation: preparation)
        let submission = try OID4VPDirectPostBuilder.build(
            requestObject: requestObject,
            response: response,
            jwtResponse: jwe.compactSerialization
        )

        return OID4VPDirectPostJWTSubmissionPlan(
            matchResult: matchResult,
            response: response,
            resolvedVerifierMetadata: resolvedVerifierMetadata,
            preparation: preparation,
            jwe: jwe,
            submission: submission
        )
    }
}
