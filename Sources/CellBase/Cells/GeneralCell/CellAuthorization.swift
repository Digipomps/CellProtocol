// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum CellAuthorizationPath: String, Codable, Sendable {
    case debugBypass
    case ownerProof
    case signedContract
    case cellSpecific
    case deniedOwnerProofFailed
    case deniedIdentityReferenceMismatch
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
    public var reasonCode: String?
    public var userMessage: String?
    public var requiredAction: String?
    public var canAutoResolve: Bool?
    public var developerHint: String?

    public init(
        allowed: Bool,
        path: CellAuthorizationPath,
        reason: String,
        request: CellAuthorizationRequest,
        reasonCode: String? = nil,
        userMessage: String? = nil,
        requiredAction: String? = nil,
        canAutoResolve: Bool? = nil,
        developerHint: String? = nil
    ) {
        self.allowed = allowed
        self.path = path
        self.reason = reason
        self.request = request
        self.reasonCode = reasonCode
        self.userMessage = userMessage
        self.requiredAction = requiredAction
        self.canAutoResolve = canAutoResolve
        self.developerHint = developerHint
    }
}

public enum CellAuthorizationError: Error {
    case denied(CellAuthorizationDecision)
}

/// Lets a Cell explicitly narrow or strengthen method-level Meddle
/// authorization for one operation. Returning `nil` preserves the default
/// (`r---` for GET and `-w--` for SET).
///
/// The requirement is operation metadata, not caller authority. It must match
/// the operation's exact, singleton Explore permission declaration. Resolver
/// preflight and GeneralCell dispatch still evaluate owner proof,
/// Contract/Grant, or cell-specific policy before executing the operation.
public protocol MeddleOperationAuthorizationRequirementProviding: ExploreOperationContractProviding {
    func meddleAuthorizationRequirement(
        for method: ExploreContractMethod,
        keypath: String
    ) async throws -> String?
}

public enum MeddleOperationAuthorizationRequirementError: Error, Equatable {
    case invalidPermission(String)
    case missingExploreContract(method: String, keypath: String)
    case permissionNotDeclared(permission: String, method: String, keypath: String)
}

enum MeddleOperationAuthorizationRequirementResolver {
    static func resolve(
        target: Any,
        keypath: String,
        method: ExploreContractMethod,
        requester: Identity
    ) async throws -> String? {
        guard let provider = target as? MeddleOperationAuthorizationRequirementProviding,
              let provided = try await provider.meddleAuthorizationRequirement(
                for: method,
                keypath: keypath
              ) else {
            return nil
        }

        let canonical = Permission(provided).permissionString
        guard provided.count == 4,
              canonical == provided,
              provided != "----" else {
            throw MeddleOperationAuthorizationRequirementError.invalidPermission(provided)
        }

        let contract: ValueType
        do {
            contract = try await provider.contract(
                for: keypath,
                method: method,
                requester: requester
            )
        } catch GeneralCellErrors.noSchemaForKey {
            throw MeddleOperationAuthorizationRequirementError.missingExploreContract(
                method: method.rawValue,
                keypath: keypath
            )
        }
        let contractObject = ExploreContract.object(from: contract)
        let declaredPermissions = ExploreContract.list(
            from: contractObject?[ExploreContract.Field.permissions]
        )?.compactMap { ExploreContract.string(from: $0) } ?? []
        guard declaredPermissions == [provided] else {
            throw MeddleOperationAuthorizationRequirementError.permissionNotDeclared(
                permission: provided,
                method: method.rawValue,
                keypath: keypath
            )
        }

        return provided
    }
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
        ownerUUIDMatches: Bool,
        ownerProofValid: Bool,
        contracts: [Agreement],
        cellSpecificAllowed: Bool
    ) -> CellAuthorizationDecision {
        if CellBase.debugValidateAccessForEverything {
            return CellAuthorizationDecision(
                allowed: true,
                path: .debugBypass,
                reason: "Debug access bypass is enabled.",
                request: request,
                reasonCode: "debug_bypass",
                userMessage: "Debug access bypass is enabled.",
                requiredAction: "none",
                canAutoResolve: true
            )
        }

        if ownerReferenceMatches {
            return CellAuthorizationDecision(
                allowed: ownerProofValid,
                path: ownerProofValid ? .ownerProof : .deniedOwnerProofFailed,
                reason: ownerProofValid
                    ? "Requester proved control of the stored owner identity."
                    : "Requester matched the stored owner reference but failed cryptographic proof.",
                request: request,
                reasonCode: ownerProofValid ? "owner_proof_verified" : "owner_proof_failed",
                userMessage: ownerProofValid
                    ? "Access granted by owner identity proof."
                    : "This device has the owner identity reference, but could not prove control of the owner signing key.",
                requiredAction: ownerProofValid ? "none" : "unlock_or_restore_owner_identity",
                canAutoResolve: ownerProofValid,
                developerHint: ownerProofValid
                    ? nil
                    : "The requester UUID and public key match the stored owner, but the identity-origin proof failed. Check that the correct vault is unlocked and signs the exact challenge."
            )
        }

        if ownerUUIDMatches {
            return CellAuthorizationDecision(
                allowed: false,
                path: .deniedIdentityReferenceMismatch,
                reason: "Requester UUID matched the owner UUID, but the public signing key did not match the stored owner identity.",
                request: request,
                reasonCode: "identity_public_key_mismatch",
                userMessage: "The identity UUID matches the owner record, but the signing key does not. Restore the owner identity or link this scaffold with an explicit owner-approved proof.",
                requiredAction: "restore_owner_identity_or_link_scaffold",
                canAutoResolve: false,
                developerHint: "Do not treat UUID equality as ownership. Require the stored owner public key, an entity-extension proof, or a signed contract/capability before granting access."
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
                request: request,
                reasonCode: "signed_contract",
                userMessage: "Access granted by signed contract.",
                requiredAction: "none",
                canAutoResolve: true
            )
        }

        if cellSpecificAllowed {
            return CellAuthorizationDecision(
                allowed: true,
                path: .cellSpecific,
                reason: "Cell-specific authorization hook granted the requested access.",
                request: request,
                reasonCode: "cell_specific_grant",
                userMessage: "Access granted by cell-specific policy.",
                requiredAction: "none",
                canAutoResolve: true
            )
        }

        return CellAuthorizationDecision(
            allowed: false,
            path: .deniedNoGrant,
            reason: "No verified owner proof, signed contract, or cell-specific grant allowed the request.",
            request: request,
            reasonCode: "agreement_or_proof_required",
            userMessage: "Access requires an owner proof, a signed contract, or a concrete policy proof.",
            requiredAction: "request_contract_or_present_proof",
            canAutoResolve: false,
            developerHint: "Route this denial to admission/policy handling so the user can request a contract, present a proof, or complete an entity-extension flow."
        )
    }
}
