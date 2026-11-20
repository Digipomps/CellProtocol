// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// PDD_flow-plassering_2026-11-07, WP4/WP5/WP10. The new identity's side of a
// same-entity link into another scaffold's entity (for Palazzo: "extend the
// Palazzo entity to HAVEN"). The identity (the Mac agent, or the entity's home
// scaffold) signs an enrollment request; the other side's owner approves it
// there; the identity then completes with a presentation bound to a fresh
// challenge. Only that identity's key signs here, and nothing is approved.
// Moved here from HavenAgentD so the agent and the home scaffold share it.

public enum IdentityLinkClientError: Error, LocalizedError, Equatable {
    case invalidApproval(String)
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case .invalidApproval(let detail): return "The approval package is not usable: \(detail)"
        case .invalidRequest(let detail): return "The enrollment request is not usable: \(detail)"
        }
    }
}

public enum IdentityLinkClient {
    public static let defaultScopes = ["entity.same"]

    /// A signed enrollment request naming `identity` as the new identity.
    public static func makeEnrollmentRequest(
        for identity: Identity,
        audience: String,
        origin: String,
        requestedDomains: [String],
        requestedIdentityContexts: [String],
        requestedScopes: [String] = IdentityLinkClient.defaultScopes,
        lifetime: TimeInterval = 600,
        deviceLabel: String = "HAVEN agent",
        platform: String = "HAVEN",
        now: Date = Date()
    ) async throws -> IdentityEnrollmentRequest {
        guard !requestedDomains.isEmpty, !requestedIdentityContexts.isEmpty, !requestedScopes.isEmpty else {
            throw IdentityLinkClientError.invalidRequest("domains, identity contexts and scopes must not be empty")
        }
        let descriptor = try IdentityLinkProtocolService.descriptor(for: identity)
        var nonce = Data(count: 32)
        for index in 0..<nonce.count { nonce[index] = UInt8.random(in: 0...255) }
        var request = IdentityEnrollmentRequest(
            requestID: UUID().uuidString,
            entityBinding: EntityBindingDescriptor(
                mode: .localEntityAnchor,
                entityAnchorReference: identity.entityAnchorReference,
                audience: audience
            ),
            newIdentity: descriptor,
            requestedDomains: requestedDomains,
            requestedIdentityContexts: requestedIdentityContexts,
            requestedScopes: requestedScopes,
            audience: audience,
            origin: origin,
            createdAt: IdentityLinkProtocolService.iso8601(now),
            expiresAt: IdentityLinkProtocolService.iso8601(now.addingTimeInterval(max(60, min(lifetime, 3600)))),
            nonce: nonce,
            platform: platform,
            deviceLabel: deviceLabel
        )
        let canonical = try request.canonicalPayloadData()
        guard let signature = try await identity.sign(data: canonical) else {
            throw IdentityVaultError.signingFailed
        }
        request.proof = IdentityEnrollmentRequestProof(
            byIdentityUUID: identity.uuid,
            algorithm: descriptor.algorithm,
            curveType: descriptor.curveType,
            signature: signature
        )
        _ = try await IdentityLinkProtocolService.validateEnrollmentRequest(request, now: now)
        return request
    }

    /// The `link.complete` payload: the request, the other side's approval
    /// package, and a presentation `holder` signs over a fresh challenge.
    /// `approvalResponse` is what the approving side returned: either the
    /// cell value (`{anchorOwnerUUID, approvalPackage, …}`) or the HTTP body
    /// that wraps it as `value`.
    public static func completionPayload(
        approvalResponse: ValueType,
        request: ValueType,
        holder: Identity,
        presentationDomain: String
    ) async throws -> ValueType {
        guard case var .object(approval) = approvalResponse else {
            throw IdentityLinkClientError.invalidApproval("not an object")
        }
        if case let .object(inner)? = approval["value"] { approval = inner }
        guard case let .string(anchorOwnerUUID)? = approval["anchorOwnerUUID"], !anchorOwnerUUID.isEmpty else {
            throw IdentityLinkClientError.invalidApproval("anchorOwnerUUID is missing")
        }
        guard case let .object(package)? = approval["approvalPackage"],
              let approvalValue = package["approval"],
              let credentialValue = package["sameEntityCredential"],
              let issuerValue = package["issuerIdentity"] else {
            throw IdentityLinkClientError.invalidApproval("approvalPackage with approval, sameEntityCredential and issuerIdentity is missing")
        }
        let parsedRequest: IdentityEnrollmentRequest
        do {
            parsedRequest = try decode(request, as: IdentityEnrollmentRequest.self)
        } catch {
            throw IdentityLinkClientError.invalidRequest(String(describing: error))
        }
        guard parsedRequest.newIdentity.uuid == holder.uuid else {
            throw IdentityLinkClientError.invalidRequest("the request names another identity")
        }
        let credential = try decode(credentialValue, as: VCClaim.self)
        var challenge = Data(count: 32)
        for index in 0..<challenge.count { challenge[index] = UInt8.random(in: 0...255) }
        let presentation = try await IdentityLinkProtocolService.makeVerifierBoundPresentation(
            credential: credential,
            holderIdentity: holder,
            challenge: challenge,
            domain: presentationDomain
        )
        return .object([
            "anchorOwnerUUID": .string(anchorOwnerUUID),
            "request": request,
            "approval": approvalValue,
            "sameEntityCredential": credentialValue,
            "presentation": try IdentityLinkProtocolService.value(from: presentation),
            "issuerIdentity": issuerValue,
            "expectedAudience": .string(parsedRequest.audience),
            "expectedOrigin": .string(parsedRequest.origin),
            "expectedPresentationChallenge": .string(challenge.base64EncodedString()),
            "expectedPresentationDomain": .string(presentationDomain)
        ])
    }

    static func decode<T: Decodable>(_ value: ValueType, as type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
}
