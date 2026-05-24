// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum CellAuthorizationPath: String, Codable, Sendable {
    case debugBypass
    case ownerProof
    case signedContract
    case cellSpecific
    case deniedOwnerProofFailed
    case deniedNoGrant
}

public struct CellAuthorizationRequest: Codable, Sendable {
    public var cellUUID: String
    public var identityDomain: String
    public var keypath: String
    public var requestedAccess: String
    public var requesterUUID: String
    public var requesterSigningKeyFingerprint: String?

    public init(
        cellUUID: String,
        identityDomain: String,
        keypath: String,
        requestedAccess: String,
        requester: Identity
    ) {
        self.cellUUID = cellUUID
        self.identityDomain = identityDomain
        self.keypath = keypath
        self.requestedAccess = requestedAccess
        self.requesterUUID = requester.uuid
        self.requesterSigningKeyFingerprint = requester.signingPublicKeyFingerprint
    }
}

public struct CellAuthorizationDecision: Codable, Sendable {
    public var allowed: Bool
    public var path: CellAuthorizationPath
    public var reason: String
    public var request: CellAuthorizationRequest

    public init(
        allowed: Bool,
        path: CellAuthorizationPath,
        reason: String,
        request: CellAuthorizationRequest
    ) {
        self.allowed = allowed
        self.path = path
        self.reason = reason
        self.request = request
    }
}

public enum CellAuthorizationError: Error {
    case denied(CellAuthorizationDecision)
}

public protocol CellAuthorizationDeciding {
    func authorizationDecision(
        requestedAccess: String,
        at keypath: String,
        for identity: Identity
    ) async -> CellAuthorizationDecision
}

public enum CellAuthorizationPolicy {
    public static func decide(
        request: CellAuthorizationRequest,
        ownerReferenceMatches: Bool,
        ownerProofValid: Bool,
        contracts: [Agreement],
        cellSpecificAllowed: Bool
    ) -> CellAuthorizationDecision {
        if CellBase.debugValidateAccessForEverything {
            return CellAuthorizationDecision(
                allowed: true,
                path: .debugBypass,
                reason: "Debug access bypass is enabled.",
                request: request
            )
        }

        if ownerReferenceMatches {
            return CellAuthorizationDecision(
                allowed: ownerProofValid,
                path: ownerProofValid ? .ownerProof : .deniedOwnerProofFailed,
                reason: ownerProofValid
                    ? "Requester proved control of the stored owner identity."
                    : "Requester matched the stored owner reference but failed cryptographic proof.",
                request: request
            )
        }

        let requestedGrant = Grant(
            keypath: request.keypath,
            permission: request.requestedAccess
        )
        if contracts.contains(where: { $0.checkGrant(requestedGrant: requestedGrant) }) {
            return CellAuthorizationDecision(
                allowed: true,
                path: .signedContract,
                reason: "Requester has a verified signed contract granting the requested access.",
                request: request
            )
        }

        if cellSpecificAllowed {
            return CellAuthorizationDecision(
                allowed: true,
                path: .cellSpecific,
                reason: "Cell-specific authorization hook granted the requested access.",
                request: request
            )
        }

        return CellAuthorizationDecision(
            allowed: false,
            path: .deniedNoGrant,
            reason: "No verified owner proof, signed contract, or cell-specific grant allowed the request.",
            request: request
        )
    }
}
