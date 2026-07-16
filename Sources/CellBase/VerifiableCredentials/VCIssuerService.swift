// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 15/04/2024.
//

import Foundation

enum VCIssuerServiceError: Error, Equatable {
    case issuerControlProofRequired
    case generatedCredentialFailedVerification
}

struct VCIssuerService {

    func mintVC(
        for identity: Identity,
        claiming claim: ValueType,
        type: String,
        issuerIdentity: Identity
    ) async throws -> VCClaim {
        if case let .object(claimObject) = claim {
            return try await mintVC(
                for: identity,
                claiming: claimObject,
                type: type,
                issuerIdentity: issuerIdentity
            )
        }
        throw ValueTypeError.unexpectedValueType
    }

    func mintVC(
        for identity: Identity,
        claiming claim: Object,
        type: String,
        issuerIdentity: Identity
    ) async throws -> VCClaim {
        guard await IdentitySigningChallenge.proveControl(
            of: issuerIdentity,
            domain: "VerifiableCredentials",
            resource: "cell:///identity/\(identity.uuid)/claims",
            action: "issue:\(type)",
            audience: "VCIssuerService"
        ) else {
            throw VCIssuerServiceError.issuerControlProofRequired
        }

        var verifiableClaim = try await VCClaim(
            type: type,
            issuerIdentity: issuerIdentity,
            subjectIdentity: identity,
            credentialSubject: claim
        )
        try await verifiableClaim.generateProof(issuerIdentity: issuerIdentity)
        guard try await verifiableClaim.verify(issuer: issuerIdentity) else {
            throw VCIssuerServiceError.generatedCredentialFailedVerification
        }
        return verifiableClaim
    }
}
