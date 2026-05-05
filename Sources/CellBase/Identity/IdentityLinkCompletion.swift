// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum IdentityLinkCompletionError: Error, Equatable {
    case missingPublicKey(String)
    case missingRequestProof
    case missingApprovalProof
    case invalidPurpose(String)
    case invalidNonce
    case invalidExpiry(String)
    case expired(String)
    case missingEntityBinding
    case missingRequiredContext(String)
    case invalidRequestSignature
    case invalidApprovalSignature
    case requestHashMismatch
    case identityMismatch(String)
    case audienceMismatch(expected: String, actual: String)
    case originMismatch(expected: String, actual: String)
    case scopeEscalation(String)
    case replayDetected(String)
    case missingFreshAuth
    case issuerMismatch
    case issuerTypeNotAllowed(String)
    case invalidCredentialType
    case invalidCredentialSignature
    case invalidCredentialSubject(String)
    case invalidPresentation
    case holderMismatch
}

public struct IdentityLinkCompletionPolicy {
    public var expectedAudience: String
    public var expectedOrigin: String
    public var expectedPresentationChallenge: Data
    public var expectedPresentationDomain: String
    public var requireFreshApprovalAuth: Bool
    public var allowedIssuerTypes: [IdentityLinkIssuerType]

    public init(
        expectedAudience: String,
        expectedOrigin: String,
        expectedPresentationChallenge: Data,
        expectedPresentationDomain: String,
        requireFreshApprovalAuth: Bool = true,
        allowedIssuerTypes: [IdentityLinkIssuerType] = [.existingDevice, .custodian, .recoveryAuthority]
    ) {
        self.expectedAudience = expectedAudience
        self.expectedOrigin = expectedOrigin
        self.expectedPresentationChallenge = expectedPresentationChallenge
        self.expectedPresentationDomain = expectedPresentationDomain
        self.requireFreshApprovalAuth = requireFreshApprovalAuth
        self.allowedIssuerTypes = allowedIssuerTypes
    }
}

public struct IdentityLinkCompletionEnvelope: Codable {
    public var request: IdentityEnrollmentRequest
    public var approval: IdentityEnrollmentApproval
    public var sameEntityCredential: VCClaim
    public var presentation: VCPresentation
    public var issuerIdentity: IdentityPublicKeyDescriptor
    public var expectedAudience: String
    public var expectedOrigin: String
    public var expectedPresentationChallenge: Data
    public var expectedPresentationDomain: String

    public init(
        request: IdentityEnrollmentRequest,
        approval: IdentityEnrollmentApproval,
        sameEntityCredential: VCClaim,
        presentation: VCPresentation,
        issuerIdentity: IdentityPublicKeyDescriptor,
        expectedAudience: String,
        expectedOrigin: String,
        expectedPresentationChallenge: Data,
        expectedPresentationDomain: String
    ) {
        self.request = request
        self.approval = approval
        self.sameEntityCredential = sameEntityCredential
        self.presentation = presentation
        self.issuerIdentity = issuerIdentity
        self.expectedAudience = expectedAudience
        self.expectedOrigin = expectedOrigin
        self.expectedPresentationChallenge = expectedPresentationChallenge
        self.expectedPresentationDomain = expectedPresentationDomain
    }

    public var policy: IdentityLinkCompletionPolicy {
        IdentityLinkCompletionPolicy(
            expectedAudience: expectedAudience,
            expectedOrigin: expectedOrigin,
            expectedPresentationChallenge: expectedPresentationChallenge,
            expectedPresentationDomain: expectedPresentationDomain
        )
    }
}

public struct IdentityLinkCompletionResult {
    public var record: IdentityLinkRecord
    public var requestHash: Data
    public var approvalJTI: String
    public var credentialID: String
    public var presentationID: String

    public init(
        record: IdentityLinkRecord,
        requestHash: Data,
        approvalJTI: String,
        credentialID: String,
        presentationID: String
    ) {
        self.record = record
        self.requestHash = requestHash
        self.approvalJTI = approvalJTI
        self.credentialID = credentialID
        self.presentationID = presentationID
    }
}

public struct IdentityLinkApprovalEnvelope: Codable {
    public var request: IdentityEnrollmentRequest
    public var issuerType: IdentityLinkIssuerType
    public var approvedDomains: [String]?
    public var approvedIdentityContexts: [String]?
    public var approvedScopes: [String]?
    public var expiresAt: String?
    public var jti: String?
    public var freshAuthRequired: Bool
    public var freshAuthPerformedAt: String?
    public var revocationReference: String?

    public init(
        request: IdentityEnrollmentRequest,
        issuerType: IdentityLinkIssuerType = .existingDevice,
        approvedDomains: [String]? = nil,
        approvedIdentityContexts: [String]? = nil,
        approvedScopes: [String]? = nil,
        expiresAt: String? = nil,
        jti: String? = nil,
        freshAuthRequired: Bool = true,
        freshAuthPerformedAt: String? = nil,
        revocationReference: String? = nil
    ) {
        self.request = request
        self.issuerType = issuerType
        self.approvedDomains = approvedDomains
        self.approvedIdentityContexts = approvedIdentityContexts
        self.approvedScopes = approvedScopes
        self.expiresAt = expiresAt
        self.jti = jti
        self.freshAuthRequired = freshAuthRequired
        self.freshAuthPerformedAt = freshAuthPerformedAt
        self.revocationReference = revocationReference
    }
}

public struct IdentityLinkApprovalPackage: Codable {
    public var approval: IdentityEnrollmentApproval
    public var sameEntityCredential: VCClaim
    public var issuerIdentity: IdentityPublicKeyDescriptor

    public init(
        approval: IdentityEnrollmentApproval,
        sameEntityCredential: VCClaim,
        issuerIdentity: IdentityPublicKeyDescriptor
    ) {
        self.approval = approval
        self.sameEntityCredential = sameEntityCredential
        self.issuerIdentity = issuerIdentity
    }
}

public enum IdentityLinkProtocolService {
    public static func descriptor(for identity: Identity) throws -> IdentityPublicKeyDescriptor {
        guard let secureKey = identity.publicSecureKey,
              let publicKey = secureKey.compressedKey else {
            throw IdentityLinkCompletionError.missingPublicKey(identity.uuid)
        }
        return IdentityPublicKeyDescriptor(
            uuid: identity.uuid,
            displayName: identity.displayName,
            publicKey: publicKey,
            algorithm: secureKey.algorithm,
            curveType: secureKey.curveType
        )
    }

    public static func approveEnrollmentRequest(
        _ request: IdentityEnrollmentRequest,
        issuerIdentity: Identity,
        issuerType: IdentityLinkIssuerType = .existingDevice,
        approvedDomains: [String]? = nil,
        approvedIdentityContexts: [String]? = nil,
        approvedScopes: [String]? = nil,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        jti: String = UUID().uuidString,
        freshAuthRequired: Bool = true,
        freshAuthPerformedAt: Date? = Date()
    ) async throws -> IdentityEnrollmentApproval {
        let requestHash = try await validateEnrollmentRequest(request, now: createdAt)
        guard let secureKey = issuerIdentity.publicSecureKey,
              let _ = secureKey.compressedKey else {
            throw IdentityLinkCompletionError.missingPublicKey(issuerIdentity.uuid)
        }
        guard let entityBinding = request.entityBinding else {
            throw IdentityLinkCompletionError.missingEntityBinding
        }

        let expiry = expiresAt ?? createdAt.addingTimeInterval(300)
        var approval = IdentityEnrollmentApproval(
            approvalID: UUID().uuidString,
            requestHash: requestHash,
            entityBinding: entityBinding,
            subjectIdentity: request.newIdentity,
            approvedDomains: approvedDomains ?? request.requestedDomains,
            approvedIdentityContexts: approvedIdentityContexts ?? request.requestedIdentityContexts,
            approvedScopes: approvedScopes ?? request.requestedScopes,
            issuerIdentityUUID: issuerIdentity.uuid,
            issuerType: issuerType,
            audience: request.audience,
            origin: request.origin,
            createdAt: iso8601(createdAt),
            expiresAt: iso8601(expiry),
            jti: jti,
            freshAuthRequired: freshAuthRequired,
            freshAuthMethod: freshAuthRequired ? "local-user-presence" : nil,
            freshAuthPerformedAt: freshAuthPerformedAt.map(iso8601)
        )
        let payload = try approval.canonicalPayloadData()
        guard let signature = try await issuerIdentity.sign(data: payload) else {
            throw IdentityVaultError.signingFailed
        }
        approval.proof = IdentityEnrollmentApprovalProof(
            issuerIdentityUUID: issuerIdentity.uuid,
            issuerType: issuerType,
            algorithm: secureKey.algorithm,
            curveType: secureKey.curveType,
            signature: signature
        )
        return approval
    }

    public static func approveEnrollment(
        _ envelope: IdentityLinkApprovalEnvelope,
        issuerIdentity: Identity,
        now: Date = Date()
    ) async throws -> IdentityLinkApprovalPackage {
        let expiresAt: Date?
        if let requestedExpiry = envelope.expiresAt {
            guard let parsed = ISO8601DateFormatter().date(from: requestedExpiry) else {
                throw IdentityLinkCompletionError.invalidExpiry(requestedExpiry)
            }
            expiresAt = parsed
        } else {
            expiresAt = nil
        }
        let freshAuthPerformedAt: Date?
        if let performedAt = envelope.freshAuthPerformedAt {
            guard let parsed = ISO8601DateFormatter().date(from: performedAt) else {
                throw IdentityLinkCompletionError.invalidExpiry(performedAt)
            }
            freshAuthPerformedAt = parsed
        } else {
            freshAuthPerformedAt = nil
        }
        let approval = try await approveEnrollmentRequest(
            envelope.request,
            issuerIdentity: issuerIdentity,
            issuerType: envelope.issuerType,
            approvedDomains: envelope.approvedDomains,
            approvedIdentityContexts: envelope.approvedIdentityContexts,
            approvedScopes: envelope.approvedScopes,
            createdAt: now,
            expiresAt: expiresAt,
            jti: envelope.jti ?? UUID().uuidString,
            freshAuthRequired: envelope.freshAuthRequired,
            freshAuthPerformedAt: freshAuthPerformedAt ?? (envelope.freshAuthRequired ? now : nil)
        )
        let credential = try await issueSameEntityCredential(
            request: envelope.request,
            approval: approval,
            issuerIdentity: issuerIdentity,
            validUntil: expiresAt ?? now.addingTimeInterval(300),
            revocationReference: envelope.revocationReference
        )
        return IdentityLinkApprovalPackage(
            approval: approval,
            sameEntityCredential: credential,
            issuerIdentity: try descriptor(for: issuerIdentity)
        )
    }

    public static func issueSameEntityCredential(
        request: IdentityEnrollmentRequest,
        approval: IdentityEnrollmentApproval,
        issuerIdentity: Identity,
        validUntil: Date,
        revocationReference: String? = nil
    ) async throws -> VCClaim {
        let requestHash = try requestHash(for: request)
        let targetIdentity = identity(from: request.newIdentity)
        let subject = SameEntityIdentityLinkCredentialSubject(
            id: try did(for: request.newIdentity),
            entityBinding: approval.entityBinding,
            linkedIdentity: request.newIdentity,
            approvedDomains: approval.approvedDomains,
            approvedIdentityContexts: approval.approvedIdentityContexts,
            approvedScopes: approval.approvedScopes,
            enrollmentRequestHash: requestHash,
            assuranceSource: approval.freshAuthRequired ? "fresh_auth_and_possession" : "possession_only",
            assuranceLevel: approval.freshAuthRequired ? "high" : "medium",
            validUntil: iso8601(validUntil),
            revocationReference: revocationReference
        )
        var claim = try await VCClaim(
            type: "SameEntityIdentityLinkCredential",
            issuerIdentity: issuerIdentity,
            subjectIdentity: targetIdentity,
            credentialSubject: try object(from: subject)
        )
        try await claim.generateProof(issuerIdentity: issuerIdentity)
        return claim
    }

    public static func makeVerifierBoundPresentation(
        credential: VCClaim,
        holderIdentity: Identity,
        challenge: Data,
        domain: String
    ) async throws -> VCPresentation {
        var presentation = try await VCPresentation(
            type: "SameEntityIdentityLinkPresentation",
            holderIdentity: holderIdentity,
            subjectIdentity: holderIdentity,
            verifiableCredentials: [credential]
        )
        try await presentation.bindAndSign(
            holderIdentity: holderIdentity,
            challenge: challenge,
            domain: domain
        )
        return presentation
    }

    public static func verifyCompletion(
        _ envelope: IdentityLinkCompletionEnvelope,
        now: Date = Date(),
        usedApprovalJTIs: Set<String> = []
    ) async throws -> IdentityLinkCompletionResult {
        try await verifyCompletion(
            request: envelope.request,
            approval: envelope.approval,
            sameEntityCredential: envelope.sameEntityCredential,
            presentation: envelope.presentation,
            issuerIdentity: envelope.issuerIdentity,
            policy: envelope.policy,
            now: now,
            usedApprovalJTIs: usedApprovalJTIs
        )
    }

    public static func verifyCompletion(
        request: IdentityEnrollmentRequest,
        approval: IdentityEnrollmentApproval,
        sameEntityCredential: VCClaim,
        presentation: VCPresentation,
        issuerIdentity: IdentityPublicKeyDescriptor,
        policy: IdentityLinkCompletionPolicy,
        now: Date = Date(),
        usedApprovalJTIs: Set<String> = []
    ) async throws -> IdentityLinkCompletionResult {
        let requestHash = try await validateEnrollmentRequest(request, now: now)
        try await validateApproval(
            approval,
            request: request,
            requestHash: requestHash,
            issuerIdentity: issuerIdentity,
            policy: policy,
            now: now,
            usedApprovalJTIs: usedApprovalJTIs
        )
        let subject = try await validateSameEntityCredential(
            sameEntityCredential,
            request: request,
            approval: approval,
            issuerIdentity: issuerIdentity,
            requestHash: requestHash,
            now: now
        )
        try await validatePresentation(
            presentation,
            credential: sameEntityCredential,
            linkedIdentity: request.newIdentity,
            policy: policy
        )

        let linkedAt = iso8601(now)
        let record = IdentityLinkRecord(
            linkID: approval.approvalID,
            entityBinding: approval.entityBinding,
            linkedIdentity: request.newIdentity,
            approvedDomains: approval.approvedDomains,
            approvedIdentityContexts: approval.approvedIdentityContexts,
            approvedScopes: approval.approvedScopes,
            issuerIdentityUUID: issuerIdentity.uuid,
            issuerType: approval.issuerType,
            status: .active,
            linkedAt: linkedAt,
            revocationReference: subject.revocationReference
        )
        return IdentityLinkCompletionResult(
            record: record,
            requestHash: requestHash,
            approvalJTI: approval.jti,
            credentialID: sameEntityCredential.id,
            presentationID: presentation.id
        )
    }

    @discardableResult
    public static func validateEnrollmentRequest(
        _ request: IdentityEnrollmentRequest,
        now: Date = Date()
    ) async throws -> Data {
        guard request.purpose == "link_identity" else {
            throw IdentityLinkCompletionError.invalidPurpose(request.purpose)
        }
        guard request.entityBinding != nil else {
            throw IdentityLinkCompletionError.missingEntityBinding
        }
        guard request.nonce.count >= 16 else {
            throw IdentityLinkCompletionError.invalidNonce
        }
        guard !request.audience.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.requestedDomains.isEmpty,
              !request.requestedIdentityContexts.isEmpty,
              !request.requestedScopes.isEmpty else {
            throw IdentityLinkCompletionError.missingRequiredContext("request")
        }
        try ensureNotExpired(request.expiresAt, now: now)
        guard let proof = request.proof,
              let signature = proof.signature,
              signature.isEmpty == false else {
            throw IdentityLinkCompletionError.missingRequestProof
        }
        guard proof.byIdentityUUID == request.newIdentity.uuid,
              proof.algorithm == request.newIdentity.algorithm,
              proof.curveType == request.newIdentity.curveType else {
            throw IdentityLinkCompletionError.identityMismatch("request proof does not match new identity")
        }

        let payload = try request.canonicalPayloadData()
        let valid = try await verifySignature(
            signature: signature,
            payload: payload,
            descriptor: request.newIdentity
        )
        guard valid else {
            throw IdentityLinkCompletionError.invalidRequestSignature
        }
        return sha256(payload)
    }

    private static func validateApproval(
        _ approval: IdentityEnrollmentApproval,
        request: IdentityEnrollmentRequest,
        requestHash: Data,
        issuerIdentity: IdentityPublicKeyDescriptor,
        policy: IdentityLinkCompletionPolicy,
        now: Date,
        usedApprovalJTIs: Set<String>
    ) async throws {
        guard approval.purpose == "approve_link_identity" else {
            throw IdentityLinkCompletionError.invalidPurpose(approval.purpose)
        }
        guard approval.requestHash == requestHash else {
            throw IdentityLinkCompletionError.requestHashMismatch
        }
        guard descriptor(approval.subjectIdentity, matches: request.newIdentity) else {
            throw IdentityLinkCompletionError.identityMismatch("approval subject does not match request identity")
        }
        guard approval.entityBinding == request.entityBinding else {
            throw IdentityLinkCompletionError.identityMismatch("approval entity binding does not match request")
        }
        guard approval.audience == request.audience,
              approval.audience == policy.expectedAudience else {
            throw IdentityLinkCompletionError.audienceMismatch(expected: policy.expectedAudience, actual: approval.audience)
        }
        guard approval.origin == request.origin,
              approval.origin == policy.expectedOrigin else {
            throw IdentityLinkCompletionError.originMismatch(expected: policy.expectedOrigin, actual: approval.origin)
        }
        guard !approval.jti.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IdentityLinkCompletionError.missingRequiredContext("approval.jti")
        }
        guard !usedApprovalJTIs.contains(approval.jti) else {
            throw IdentityLinkCompletionError.replayDetected(approval.jti)
        }
        guard policy.allowedIssuerTypes.contains(approval.issuerType) else {
            throw IdentityLinkCompletionError.issuerTypeNotAllowed(approval.issuerType.rawValue)
        }
        if policy.requireFreshApprovalAuth {
            guard approval.freshAuthRequired,
                  approval.freshAuthPerformedAt != nil else {
                throw IdentityLinkCompletionError.missingFreshAuth
            }
        }
        try ensureNotExpired(approval.expiresAt, now: now)
        try ensureSubset(approval.approvedDomains, of: request.requestedDomains, label: "domains")
        try ensureSubset(approval.approvedIdentityContexts, of: request.requestedIdentityContexts, label: "identityContexts")
        try ensureSubset(approval.approvedScopes, of: request.requestedScopes, label: "scopes")
        guard let proof = approval.proof,
              let signature = proof.signature,
              signature.isEmpty == false else {
            throw IdentityLinkCompletionError.missingApprovalProof
        }
        guard proof.issuerIdentityUUID == issuerIdentity.uuid,
              proof.issuerType == approval.issuerType,
              proof.algorithm == issuerIdentity.algorithm,
              proof.curveType == issuerIdentity.curveType,
              approval.issuerIdentityUUID == issuerIdentity.uuid else {
            throw IdentityLinkCompletionError.issuerMismatch
        }
        let valid = try await verifySignature(
            signature: signature,
            payload: try approval.canonicalPayloadData(),
            descriptor: issuerIdentity
        )
        guard valid else {
            throw IdentityLinkCompletionError.invalidApprovalSignature
        }
    }

    private static func validateSameEntityCredential(
        _ credential: VCClaim,
        request: IdentityEnrollmentRequest,
        approval: IdentityEnrollmentApproval,
        issuerIdentity: IdentityPublicKeyDescriptor,
        requestHash: Data,
        now: Date
    ) async throws -> SameEntityIdentityLinkCredentialSubject {
        guard credential.type.contains("SameEntityIdentityLinkCredential") else {
            throw IdentityLinkCompletionError.invalidCredentialType
        }
        guard case let .reference(issuerDID) = credential.issuer,
              issuerDID == (try did(for: issuerIdentity)) else {
            throw IdentityLinkCompletionError.issuerMismatch
        }
        let issuer = identity(from: issuerIdentity)
        guard try await credential.verify(issuer: issuer) else {
            throw IdentityLinkCompletionError.invalidCredentialSignature
        }
        let subject: SameEntityIdentityLinkCredentialSubject = try decodeObject(credential.credentialSubject)
        guard subject.linkType == "same_entity" else {
            throw IdentityLinkCompletionError.invalidCredentialSubject("linkType")
        }
        guard subject.id == (try did(for: request.newIdentity)) else {
            throw IdentityLinkCompletionError.holderMismatch
        }
        guard descriptor(subject.linkedIdentity, matches: request.newIdentity) else {
            throw IdentityLinkCompletionError.identityMismatch("credential linked identity")
        }
        guard subject.entityBinding == approval.entityBinding,
              subject.enrollmentRequestHash == requestHash,
              subject.approvedDomains == approval.approvedDomains,
              subject.approvedIdentityContexts == approval.approvedIdentityContexts,
              subject.approvedScopes == approval.approvedScopes else {
            throw IdentityLinkCompletionError.invalidCredentialSubject("approval linkage")
        }
        try ensureNotExpired(subject.validUntil, now: now)
        return subject
    }

    private static func validatePresentation(
        _ presentation: VCPresentation,
        credential: VCClaim,
        linkedIdentity: IdentityPublicKeyDescriptor,
        policy: IdentityLinkCompletionPolicy
    ) async throws {
        guard presentation.type.contains("SameEntityIdentityLinkPresentation"),
              presentation.verifiableCredential?.contains(where: { $0.id == credential.id }) == true,
              let holderBinding = presentation.holderBinding,
              descriptor(holderBinding, matches: linkedIdentity),
              case let .reference(holderDID) = presentation.holder,
              holderDID == (try did(for: linkedIdentity)) else {
            throw IdentityLinkCompletionError.holderMismatch
        }
        guard try await presentation.verifyHolderProof(
            expectedChallenge: policy.expectedPresentationChallenge,
            expectedDomain: policy.expectedPresentationDomain
        ) else {
            throw IdentityLinkCompletionError.invalidPresentation
        }
    }

    public static func identity(from descriptor: IdentityPublicKeyDescriptor) -> Identity {
        let identity = Identity(descriptor.uuid, displayName: descriptor.displayName ?? descriptor.uuid, identityVault: DIDIdentityVault())
        identity.publicSecureKey = SecureKey(
            date: Date(),
            privateKey: false,
            use: .signature,
            algorithm: descriptor.algorithm,
            size: descriptor.publicKey.count,
            curveType: descriptor.curveType,
            x: nil,
            y: nil,
            compressedKey: descriptor.publicKey
        )
        return identity
    }

    public static func did(for descriptor: IdentityPublicKeyDescriptor) throws -> String {
        let multibase = try DIDKeyParser.multibaseEncodedPublicKey(descriptor.publicKey, curveType: descriptor.curveType)
        return "did:key:\(multibase)"
    }

    public static func requestHash(for request: IdentityEnrollmentRequest) throws -> Data {
        try sha256(request.canonicalPayloadData())
    }

    public static func object<T: Encodable>(from value: T) throws -> Object {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ValueType.self, from: data)
        guard case let .object(object) = decoded else {
            throw IdentityLinkCompletionError.invalidCredentialSubject("object encoding")
        }
        return object
    }

    public static func value<T: Encodable>(from value: T) throws -> ValueType {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(ValueType.self, from: data)
    }

    public static func decodeObject<T: Decodable>(_ object: Object, as type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(object)
        return try JSONDecoder().decode(T.self, from: data)
    }

    public static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func verifySignature(
        signature: Data,
        payload: Data,
        descriptor: IdentityPublicKeyDescriptor
    ) async throws -> Bool {
        let didIdentityVault = DIDIdentityVault()
        return try await didIdentityVault.verifySignature(
            signature: signature,
            messageData: payload,
            for: descriptor.publicKey,
            curveType: descriptor.curveType
        )
    }

    private static func descriptor(_ lhs: IdentityPublicKeyDescriptor, matches rhs: IdentityPublicKeyDescriptor) -> Bool {
        lhs.uuid == rhs.uuid
            && lhs.publicKey == rhs.publicKey
            && lhs.algorithm == rhs.algorithm
            && lhs.curveType == rhs.curveType
    }

    private static func ensureNotExpired(_ expiresAt: String, now: Date) throws {
        guard let expiry = ISO8601DateFormatter().date(from: expiresAt) else {
            throw IdentityLinkCompletionError.invalidExpiry(expiresAt)
        }
        guard expiry >= now else {
            throw IdentityLinkCompletionError.expired(expiresAt)
        }
    }

    private static func ensureSubset(_ approved: [String], of requested: [String], label: String) throws {
        let requestedSet = Set(requested)
        let unknown = approved.filter { !requestedSet.contains($0) }
        guard unknown.isEmpty else {
            throw IdentityLinkCompletionError.scopeEscalation("\(label): \(unknown.joined(separator: ","))")
        }
    }

    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}
