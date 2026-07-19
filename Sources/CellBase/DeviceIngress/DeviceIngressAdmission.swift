// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum DeviceIngressValidationError: Error, Equatable, Sendable {
    case wrongSchema
    case wrongEnvelopeKind
    case invalidIdentifier
    case invalidNonce
    case wrongPurpose
    case wrongAudience
    case wrongDomain
    case operationBindingMismatch
    case invalidSubject
    case invalidAuthorityReference
    case authoritySubjectMismatch
    case authorityExpired
    case issuedInFuture
    case expired
    case invalidLifetime
    case invalidProof
    case invalidDomainBinding
    case missingBodyDigest
    case missingChallengeDigest
    case challengeMismatch
    case bodyEmpty
    case bodyTooLarge
    case bodyDigestMismatch
    case challengeDigestMismatch
    case requestOutsideChallengeLifetime
    case resolverUnavailable
    case authorityCellUnavailable
    case authorityDenied(String)
    case authorityResolutionMismatch
    case authorityGenerationStale
    case revocationRollbackDetected
    case agreementProofInvalid
    case replayDetected
    case admissionLedgerRollback
    case admissionLedgerUnavailable
    case invalidAdmissionReceipt
    case mutationDenied(String)
    case invalidMutationReceipt
}

public struct DeviceIngressVerifiedPair: Sendable {
    public let challenge: DeviceIngressEnvelope
    public let request: DeviceIngressEnvelope
    public let challengeSHA256: Data
    public let requestSHA256: Data
    public let bodySHA256: Data

    init(
        challenge: DeviceIngressEnvelope,
        request: DeviceIngressEnvelope,
        challengeSHA256: Data,
        requestSHA256: Data,
        bodySHA256: Data
    ) {
        self.challenge = challenge
        self.request = request
        self.challengeSHA256 = challengeSHA256
        self.requestSHA256 = requestSHA256
        self.bodySHA256 = bodySHA256
    }
}

public enum DeviceIngressEnvelopeVerifier {
    public static func verifyChallenge(
        canonicalData: Data,
        expectedAudience: String,
        expectedIssuer: IdentityPublicKeyDescriptor,
        now: Date = Date()
    ) throws -> DeviceIngressEnvelope {
        let challenge = try DeviceIngressCanonicalWire.decodeCanonical(canonicalData)
        try validateCommon(
            challenge,
            expectedKind: .challenge,
            expectedAudience: expectedAudience,
            nowMilliseconds: milliseconds(now)
        )
        guard descriptorsReferenceSameIdentity(challenge.signer, expectedIssuer) else {
            throw DeviceIngressValidationError.invalidProof
        }
        guard challenge.bodySHA256 == nil,
              challenge.challengeSHA256 == nil,
              challenge.domainBinding == nil else {
            throw DeviceIngressValidationError.wrongEnvelopeKind
        }
        try validateSignature(challenge)
        return challenge
    }

    public static func verifyRequest(
        canonicalData: Data,
        protectedBody: Data,
        canonicalChallengeData: Data,
        expectedAudience: String,
        expectedChallengeIssuer: IdentityPublicKeyDescriptor,
        now: Date = Date()
    ) throws -> DeviceIngressVerifiedPair {
        guard protectedBody.isEmpty == false else {
            throw DeviceIngressValidationError.bodyEmpty
        }
        guard protectedBody.count <= DeviceIngressEnvelope.maximumBodyBytes else {
            throw DeviceIngressValidationError.bodyTooLarge
        }
        let challenge = try verifyChallenge(
            canonicalData: canonicalChallengeData,
            expectedAudience: expectedAudience,
            expectedIssuer: expectedChallengeIssuer,
            now: now
        )
        let request = try DeviceIngressCanonicalWire.decodeCanonical(canonicalData)
        let nowMilliseconds = milliseconds(now)
        try validateCommon(
            request,
            expectedKind: .request,
            expectedAudience: expectedAudience,
            nowMilliseconds: nowMilliseconds
        )
        guard descriptorsReferenceSameIdentity(request.signer, request.subject) else {
            throw DeviceIngressValidationError.invalidProof
        }
        guard request.challengeID == challenge.challengeID,
              request.nonce == challenge.nonce,
              request.operation == challenge.operation,
              request.purpose == challenge.purpose,
              request.audience == challenge.audience,
              request.identityDomain == challenge.identityDomain,
              request.resource == challenge.resource,
              request.action == challenge.action,
              request.capability == challenge.capability,
              request.requiredAccess == challenge.requiredAccess,
              request.subject == challenge.subject,
              request.authority == challenge.authority else {
            throw DeviceIngressValidationError.challengeMismatch
        }
        guard let bodyDigest = request.bodySHA256 else {
            throw DeviceIngressValidationError.missingBodyDigest
        }
        guard let challengeDigest = request.challengeSHA256 else {
            throw DeviceIngressValidationError.missingChallengeDigest
        }
        let expectedBodyDigest = DeviceIngressCanonicalWire.sha256(protectedBody)
        guard bodyDigest == expectedBodyDigest else {
            throw DeviceIngressValidationError.bodyDigestMismatch
        }
        let expectedChallengeDigest = DeviceIngressCanonicalWire.sha256(canonicalChallengeData)
        guard challengeDigest == expectedChallengeDigest else {
            throw DeviceIngressValidationError.challengeDigestMismatch
        }
        guard request.issuedAtMilliseconds >= challenge.issuedAtMilliseconds,
              request.expiresAtMilliseconds <= challenge.expiresAtMilliseconds,
              request.expiresAtMilliseconds <= request.authority.validUntilMilliseconds else {
            throw DeviceIngressValidationError.requestOutsideChallengeLifetime
        }
        guard let domainBinding = request.domainBinding,
              domainBinding.schema == IdentityDomainBinding.currentSchema,
              domainBinding.bindingKind == IdentityDomainBinding.vaultContextKind,
              domainBinding.domain == request.identityDomain,
              domainBinding.identityUUID == request.subject.uuid,
              domainBinding.signingKeyFingerprint == signingKeyFingerprint(for: request.subject),
              domainBinding.grantsAuthority == false else {
            throw DeviceIngressValidationError.invalidDomainBinding
        }
        try validateSignature(request)
        return DeviceIngressVerifiedPair(
            challenge: challenge,
            request: request,
            challengeSHA256: expectedChallengeDigest,
            requestSHA256: DeviceIngressCanonicalWire.sha256(canonicalData),
            bodySHA256: expectedBodyDigest
        )
    }

    private static func validateCommon(
        _ envelope: DeviceIngressEnvelope,
        expectedKind: DeviceIngressEnvelopeKind,
        expectedAudience: String,
        nowMilliseconds: Int64
    ) throws {
        guard envelope.schema == DeviceIngressEnvelope.currentSchema else {
            throw DeviceIngressValidationError.wrongSchema
        }
        guard envelope.kind == expectedKind else {
            throw DeviceIngressValidationError.wrongEnvelopeKind
        }
        guard validIdentifier(envelope.envelopeID),
              validIdentifier(envelope.challengeID),
              validIdentifier(envelope.audience) else {
            throw DeviceIngressValidationError.invalidIdentifier
        }
        guard envelope.nonce.count >= DeviceIngressEnvelope.minimumNonceBytes,
              envelope.nonce.count <= DeviceIngressEnvelope.maximumNonceBytes else {
            throw DeviceIngressValidationError.invalidNonce
        }
        guard envelope.purpose == DeviceIngressEnvelope.purpose else {
            throw DeviceIngressValidationError.wrongPurpose
        }
        guard envelope.audience == expectedAudience else {
            throw DeviceIngressValidationError.wrongAudience
        }
        guard envelope.identityDomain == DeviceIngressEnvelope.identityDomain else {
            throw DeviceIngressValidationError.wrongDomain
        }
        guard envelope.resource == envelope.operation.resource,
              envelope.action == envelope.operation.action,
              envelope.capability == envelope.operation.capability,
              envelope.requiredAccess == envelope.operation.requiredAccess else {
            throw DeviceIngressValidationError.operationBindingMismatch
        }
        guard validDescriptor(envelope.subject),
              validDescriptor(envelope.signer) else {
            throw DeviceIngressValidationError.invalidSubject
        }
        try validateAuthority(
            envelope.authority,
            subject: envelope.subject,
            envelopeIssuedAtMilliseconds: envelope.issuedAtMilliseconds,
            nowMilliseconds: nowMilliseconds
        )
        let maximumLifetime = expectedKind == .challenge
            ? DeviceIngressEnvelope.maximumChallengeLifetimeMilliseconds
            : DeviceIngressEnvelope.maximumRequestLifetimeMilliseconds
        guard envelope.issuedAtMilliseconds >= 0,
              envelope.expiresAtMilliseconds
                <= DeviceIngressEnvelope.maximumJSONSafeTimestampMilliseconds,
              envelope.expiresAtMilliseconds > envelope.issuedAtMilliseconds,
              envelope.expiresAtMilliseconds - envelope.issuedAtMilliseconds <= maximumLifetime else {
            throw DeviceIngressValidationError.invalidLifetime
        }
        guard envelope.issuedAtMilliseconds
                <= nowMilliseconds + DeviceIngressEnvelope.maximumClockSkewMilliseconds else {
            throw DeviceIngressValidationError.issuedInFuture
        }
        guard envelope.expiresAtMilliseconds > nowMilliseconds else {
            throw DeviceIngressValidationError.expired
        }
    }

    private static func validateAuthority(
        _ authority: DeviceIngressAuthorityReference,
        subject: IdentityPublicKeyDescriptor,
        envelopeIssuedAtMilliseconds: Int64,
        nowMilliseconds: Int64
    ) throws {
        guard authority.schema == DeviceIngressAuthorityReference.currentSchema,
              validIdentifier(authority.authorityID),
              validIdentifier(authority.agreementID),
              validIdentifier(authority.subjectIdentityUUID),
              validIdentifier(authority.subjectSigningKeyFingerprint),
              validIdentifier(authority.revocationLedgerID),
              authority.authorityGeneration > 0,
              authority.authorityGeneration
                <= DeviceIngressAuthorityReference.maximumJSONSafeGeneration,
              authority.revocationGeneration
                <= DeviceIngressAuthorityReference.maximumJSONSafeGeneration else {
            throw DeviceIngressValidationError.invalidAuthorityReference
        }
        guard validIdentityUUID(authority.subjectIdentityUUID),
              authority.subjectIdentityUUID == subject.uuid,
              authority.subjectSigningKeyFingerprint == signingKeyFingerprint(for: subject) else {
            throw DeviceIngressValidationError.authoritySubjectMismatch
        }
        guard authority.validUntilMilliseconds > authority.issuedAtMilliseconds,
              authority.issuedAtMilliseconds >= 0,
              authority.validUntilMilliseconds
                <= DeviceIngressEnvelope.maximumJSONSafeTimestampMilliseconds,
              authority.validUntilMilliseconds - authority.issuedAtMilliseconds
                <= DeviceIngressAuthorityReference.maximumAuthorityLifetimeMilliseconds,
              authority.issuedAtMilliseconds <= envelopeIssuedAtMilliseconds,
              authority.issuedAtMilliseconds
                <= nowMilliseconds + DeviceIngressEnvelope.maximumClockSkewMilliseconds else {
            throw DeviceIngressValidationError.invalidAuthorityReference
        }
        guard authority.validUntilMilliseconds > nowMilliseconds else {
            throw DeviceIngressValidationError.authorityExpired
        }
    }

    private static func validateSignature(_ envelope: DeviceIngressEnvelope) throws {
        guard let proof = envelope.proof,
              proof.schema == DeviceIngressIdentityProof.currentSchema,
              proof.type == DeviceIngressIdentityProof.identitySignatureType,
              proof.signerIdentityUUID == envelope.signer.uuid,
              IdentityPublicKeySignatureVerifier.verify(
                signature: proof.signature,
                messageData: try envelope.canonicalPayloadData(),
                descriptor: envelope.signer
              ) else {
            throw DeviceIngressValidationError.invalidProof
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == value
            && trimmed.isEmpty == false
            && trimmed.utf8.count <= 512
            && trimmed.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x21 && scalar.value <= 0x7E
            }
    }

    private static func validDescriptor(_ descriptor: IdentityPublicKeyDescriptor) -> Bool {
        guard validIdentityUUID(descriptor.uuid),
              descriptor.displayName == nil,
              descriptor.publicKey.isEmpty == false,
              descriptor.publicKey.count <= 256 else {
            return false
        }
        return signingKeyFingerprint(for: descriptor) != nil
    }

    private static func validIdentityUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil && value.utf8.count == 36
    }

    static func signingKeyFingerprint(for descriptor: IdentityPublicKeyDescriptor) -> String? {
        IdentityLinkProtocolService.identity(from: descriptor).signingPublicKeyFingerprint
    }

    static func descriptorsReferenceSameIdentity(
        _ lhs: IdentityPublicKeyDescriptor,
        _ rhs: IdentityPublicKeyDescriptor
    ) -> Bool {
        lhs.uuid == rhs.uuid
            && lhs.publicKey == rhs.publicKey
            && lhs.algorithm == rhs.algorithm
            && lhs.curveType == rhs.curveType
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
    }
}

public struct DeviceIngressAuthorityRequest: Sendable {
    public let operation: DeviceIngressOperation
    public let resource: String
    public let action: String
    public let capability: String
    public let requiredAccess: String
    public let purpose: String
    public let audience: String
    public let identityDomain: String
    public let subject: IdentityPublicKeyDescriptor
    public let domainBinding: IdentityDomainBinding
    public let authority: DeviceIngressAuthorityReference
    public let requestSHA256: Data

    init(verifiedPair: DeviceIngressVerifiedPair) throws {
        guard let binding = verifiedPair.request.domainBinding else {
            throw DeviceIngressValidationError.invalidDomainBinding
        }
        operation = verifiedPair.request.operation
        resource = verifiedPair.request.resource
        action = verifiedPair.request.action
        capability = verifiedPair.request.capability
        requiredAccess = verifiedPair.request.requiredAccess
        purpose = verifiedPair.request.purpose
        audience = verifiedPair.request.audience
        identityDomain = verifiedPair.request.identityDomain
        subject = verifiedPair.request.subject
        domainBinding = binding
        authority = verifiedPair.request.authority
        requestSHA256 = verifiedPair.requestSHA256
    }
}

public enum DeviceIngressAuthorityPath: String, Codable, Sendable {
    case signedAgreement = "signed_agreement"
}

/// Exact signed Agreement scope. The hash of this canonical structure is the
/// only Grant keypath accepted for an ingress operation.
public struct DeviceIngressAgreementScope: Codable, Equatable, Sendable {
    public static let currentSchema = "cellprotocol.device-ingress.agreement-scope.v1"

    public let schema: String
    public let operation: DeviceIngressOperation
    public let resource: String
    public let action: String
    public let capability: String
    public let requiredAccess: String
    public let purpose: String
    public let audience: String
    public let identityDomain: String

    public init(request: DeviceIngressAuthorityRequest) {
        self.init(
            operation: request.operation,
            purpose: request.purpose,
            audience: request.audience,
            identityDomain: request.identityDomain
        )
    }

    public init(
        operation: DeviceIngressOperation,
        purpose: String = DeviceIngressEnvelope.purpose,
        audience: String,
        identityDomain: String = DeviceIngressEnvelope.identityDomain
    ) {
        schema = Self.currentSchema
        self.operation = operation
        resource = operation.resource
        action = operation.action
        capability = operation.capability
        requiredAccess = operation.requiredAccess
        self.purpose = purpose
        self.audience = audience
        self.identityDomain = identityDomain
    }

    public func canonicalData() throws -> Data {
        try DeviceIngressCanonicalWire.canonicalData(for: self, excludingTopLevelKeys: [])
    }

    public func grantKeypath() throws -> String {
        "deviceIngress." + DeviceIngressCanonicalWire.base64URL(
            DeviceIngressCanonicalWire.sha256(try canonicalData())
        )
    }
}

/// Evidence returned by the resolver-selected target Cell. The caller cannot
/// replace this with a digest claim: CellBase decodes the complete immutable
/// Contract, byte-compares its canonical representation, verifies its issuer
/// signature and exact subject/domain/Grant binding independently.
public struct DeviceIngressAuthorityEvidence: Sendable {
    public static let maximumSignedAgreementBytes = 65_536

    public let canonicalSignedAgreement: Data
    public let authorityID: String
    public let authorityGeneration: UInt64
    public let revocationLedgerID: String
    public let revocationGeneration: UInt64

    public init(
        canonicalSignedAgreement: Data,
        authorityID: String,
        authorityGeneration: UInt64,
        revocationLedgerID: String,
        revocationGeneration: UInt64
    ) {
        self.canonicalSignedAgreement = canonicalSignedAgreement
        self.authorityID = authorityID
        self.authorityGeneration = authorityGeneration
        self.revocationLedgerID = revocationLedgerID
        self.revocationGeneration = revocationGeneration
    }
}

public enum DeviceIngressAuthorityDecision: Sendable {
    case authorized(DeviceIngressAuthorityEvidence)
    case denied(reasonCode: String)
}

public struct DeviceIngressResolvedAuthority: Sendable {
    public let path: DeviceIngressAuthorityPath
    public let targetCellUUID: String
    public let targetOwner: IdentityPublicKeyDescriptor
    public let authorityID: String
    public let agreementID: String
    public let signedAgreementSHA256: Data
    public let agreementGrantKeypath: String
    public let subjectIdentityUUID: String
    public let subjectSigningKeyFingerprint: String
    public let authorityGeneration: UInt64
    public let revocationLedgerID: String
    public let revocationGeneration: UInt64
    public let validUntilMilliseconds: Int64

    init(
        targetCellUUID: String,
        targetOwner: IdentityPublicKeyDescriptor,
        authorityID: String,
        agreementID: String,
        signedAgreementSHA256: Data,
        agreementGrantKeypath: String,
        subjectIdentityUUID: String,
        subjectSigningKeyFingerprint: String,
        authorityGeneration: UInt64,
        revocationLedgerID: String,
        revocationGeneration: UInt64,
        validUntilMilliseconds: Int64
    ) {
        path = .signedAgreement
        self.targetCellUUID = targetCellUUID
        self.targetOwner = targetOwner
        self.authorityID = authorityID
        self.agreementID = agreementID
        self.signedAgreementSHA256 = signedAgreementSHA256
        self.agreementGrantKeypath = agreementGrantKeypath
        self.subjectIdentityUUID = subjectIdentityUUID
        self.subjectSigningKeyFingerprint = subjectSigningKeyFingerprint
        self.authorityGeneration = authorityGeneration
        self.revocationLedgerID = revocationLedgerID
        self.revocationGeneration = revocationGeneration
        self.validUntilMilliseconds = validUntilMilliseconds
    }
}

public struct DeviceIngressMutationCommand: Sendable {
    public let authorityRequest: DeviceIngressAuthorityRequest
    public let admissionRecord: DeviceIngressAdmissionRecord
    public let admissionReceipt: DeviceIngressAdmissionReceipt
    public let protectedBody: Data

    init(
        authorityRequest: DeviceIngressAuthorityRequest,
        admissionRecord: DeviceIngressAdmissionRecord,
        admissionReceipt: DeviceIngressAdmissionReceipt,
        protectedBody: Data
    ) {
        self.authorityRequest = authorityRequest
        self.admissionRecord = admissionRecord
        self.admissionReceipt = admissionReceipt
        self.protectedBody = protectedBody
    }
}

public struct DeviceIngressMutationReceipt: Codable, Equatable, Sendable {
    public static let currentSchema = "cellprotocol.device-ingress.mutation-receipt.v1"
    public static let atomicRecheckAndDurableMutation =
        "same_cell_atomic_authority_recheck_and_durable_mutation"

    public let schema: String
    public let admissionID: String
    public let requestSHA256: Data
    public let targetCellUUID: String
    public let targetOwnerSigningKeyFingerprint: String
    public let signedAgreementSHA256: Data
    public let authorityGeneration: UInt64
    public let revocationGeneration: UInt64
    public let mutationRecordSHA256: Data
    public let committedAtMilliseconds: Int64
    public let persistenceSemantics: String

    public init(
        schema: String = Self.currentSchema,
        admissionID: String,
        requestSHA256: Data,
        targetCellUUID: String,
        targetOwnerSigningKeyFingerprint: String,
        signedAgreementSHA256: Data,
        authorityGeneration: UInt64,
        revocationGeneration: UInt64,
        mutationRecordSHA256: Data,
        committedAtMilliseconds: Int64,
        persistenceSemantics: String = Self.atomicRecheckAndDurableMutation
    ) {
        self.schema = schema
        self.admissionID = admissionID
        self.requestSHA256 = requestSHA256
        self.targetCellUUID = targetCellUUID
        self.targetOwnerSigningKeyFingerprint = targetOwnerSigningKeyFingerprint
        self.signedAgreementSHA256 = signedAgreementSHA256
        self.authorityGeneration = authorityGeneration
        self.revocationGeneration = revocationGeneration
        self.mutationRecordSHA256 = mutationRecordSHA256
        self.committedAtMilliseconds = committedAtMilliseconds
        self.persistenceSemantics = persistenceSemantics
    }
}

public enum DeviceIngressMutationDecision: Sendable {
    case committed(DeviceIngressMutationReceipt)
    case denied(reasonCode: String)
}

/// Implemented by the resolver-selected authority Cell, never by HTTP or
/// another transport adapter. `commitDeviceIngressMutation` must serialize a
/// fresh Agreement/revocation-generation CAS and the durable mutation in the
/// same Cell operation. Replacing the resolver mapping cannot replace the
/// already selected object reference.
public protocol DeviceIngressAuthorityCell: AnyObject {
    func resolveDeviceIngressAuthority(
        for request: DeviceIngressAuthorityRequest
    ) async -> DeviceIngressAuthorityDecision

    func commitDeviceIngressMutation(
        _ command: DeviceIngressMutationCommand
    ) async -> DeviceIngressMutationDecision
}

struct DeviceIngressAuthorizedTarget {
    let cell: any DeviceIngressAuthorityCell
    let request: DeviceIngressAuthorityRequest
    let resolved: DeviceIngressResolvedAuthority
}

enum DeviceIngressResolverAuthorizer {
    static func authorize(
        _ request: DeviceIngressAuthorityRequest,
        resolver: any CellResolverProtocol,
        now: Date = Date()
    ) async throws -> DeviceIngressAuthorizedTarget {
        let requester = IdentityLinkProtocolService.identity(from: request.subject)
        let target: Emit
        do {
            target = try await resolver.cellAtEndpoint(
                endpoint: request.resource,
                requester: requester
            )
        } catch {
            throw DeviceIngressValidationError.resolverUnavailable
        }
        guard let authorityCell = target as? any DeviceIngressAuthorityCell else {
            throw DeviceIngressValidationError.authorityCellUnavailable
        }
        let targetOwner: Identity
        do {
            targetOwner = try await target.getOwner(requester: requester)
        } catch {
            throw DeviceIngressValidationError.authorityCellUnavailable
        }
        guard let targetOwnerDescriptor = DeviceIngressIdentityDescriptor.publicDescriptor(
            for: targetOwner
        ) else {
            throw DeviceIngressValidationError.authorityCellUnavailable
        }
        let decision = await authorityCell.resolveDeviceIngressAuthority(for: request)
        let evidence: DeviceIngressAuthorityEvidence
        switch decision {
        case .authorized(let value):
            evidence = value
        case .denied(let reasonCode):
            throw DeviceIngressValidationError.authorityDenied(reasonCode)
        }
        let resolved = try await validateAuthorityEvidence(
            evidence,
            target: target,
            targetOwner: targetOwner,
            targetOwnerDescriptor: targetOwnerDescriptor,
            requester: requester,
            request: request,
            now: now
        )
        return DeviceIngressAuthorizedTarget(
            cell: authorityCell,
            request: request,
            resolved: resolved
        )
    }

    private static func validateAuthorityEvidence(
        _ evidence: DeviceIngressAuthorityEvidence,
        target: Emit,
        targetOwner: Identity,
        targetOwnerDescriptor: IdentityPublicKeyDescriptor,
        requester: Identity,
        request: DeviceIngressAuthorityRequest,
        now: Date
    ) async throws -> DeviceIngressResolvedAuthority {
        let reference = request.authority
        guard evidence.canonicalSignedAgreement.isEmpty == false,
              evidence.canonicalSignedAgreement.count
                <= DeviceIngressAuthorityEvidence.maximumSignedAgreementBytes else {
            throw DeviceIngressValidationError.agreementProofInvalid
        }
        let contract: Contract
        do {
            contract = try JSONDecoder().decode(
                Contract.self,
                from: evidence.canonicalSignedAgreement
            )
            guard try SignedAgreementEntitySupport.canonicalData(contract)
                    == evidence.canonicalSignedAgreement else {
                throw DeviceIngressValidationError.agreementProofInvalid
            }
        } catch let error as DeviceIngressValidationError {
            throw error
        } catch {
            throw DeviceIngressValidationError.agreementProofInvalid
        }
        guard contract.uuid == reference.agreementID,
              milliseconds(contract.issuedAt) == reference.issuedAtMilliseconds,
              milliseconds(contract.expiresAt) == reference.validUntilMilliseconds,
              await contract.verifyAuthorizationBinding(
                expectedIssuer: targetOwner,
                expectedSubject: requester,
                expectedDomain: request.identityDomain,
                now: now
              ) else {
            throw DeviceIngressValidationError.agreementProofInvalid
        }
        let grantKeypath = try DeviceIngressAgreementScope(request: request).grantKeypath()
        let requiredGrant = Grant(keypath: grantKeypath, permission: request.requiredAccess)
        guard contract.agreement.grants.contains(where: { $0.granted(requiredGrant) }) else {
            throw DeviceIngressValidationError.agreementProofInvalid
        }
        guard evidence.authorityID == reference.authorityID,
              evidence.revocationLedgerID == reference.revocationLedgerID else {
            throw DeviceIngressValidationError.authorityResolutionMismatch
        }
        guard evidence.authorityGeneration >= reference.authorityGeneration,
              evidence.revocationGeneration >= reference.revocationGeneration else {
            throw DeviceIngressValidationError.revocationRollbackDetected
        }
        guard evidence.authorityGeneration == reference.authorityGeneration,
              evidence.revocationGeneration == reference.revocationGeneration else {
            throw DeviceIngressValidationError.authorityGenerationStale
        }
        guard reference.validUntilMilliseconds > milliseconds(now.timeIntervalSince1970) else {
            throw DeviceIngressValidationError.authorityExpired
        }
        return DeviceIngressResolvedAuthority(
            targetCellUUID: target.uuid,
            targetOwner: targetOwnerDescriptor,
            authorityID: reference.authorityID,
            agreementID: reference.agreementID,
            signedAgreementSHA256: DeviceIngressCanonicalWire.sha256(
                evidence.canonicalSignedAgreement
            ),
            agreementGrantKeypath: grantKeypath,
            subjectIdentityUUID: reference.subjectIdentityUUID,
            subjectSigningKeyFingerprint: reference.subjectSigningKeyFingerprint,
            authorityGeneration: reference.authorityGeneration,
            revocationLedgerID: reference.revocationLedgerID,
            revocationGeneration: reference.revocationGeneration,
            validUntilMilliseconds: reference.validUntilMilliseconds
        )
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int64 {
        Int64((seconds * 1_000).rounded(.towardZero))
    }
}

public struct DeviceIngressAdmissionRecord: Codable, Equatable, Sendable {
    public static let currentSchema = "cellprotocol.device-ingress.admission-record.v1"

    public let schema: String
    public let admissionID: String
    public let requestSHA256: Data
    public let challengeSHA256: Data
    public let bodySHA256: Data
    public let nonceSHA256: Data
    public let targetCellUUID: String
    public let targetOwnerSigningKeyFingerprint: String
    public let authorityID: String
    public let authorityGeneration: UInt64
    public let agreementID: String
    public let signedAgreementSHA256: Data
    public let revocationLedgerID: String
    public let revocationGeneration: UInt64
    public let subjectIdentityUUID: String
    public let subjectSigningKeyFingerprint: String
    public let operation: DeviceIngressOperation
    public let capability: String
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let admittedAtMilliseconds: Int64

    public init(
        verifiedPair: DeviceIngressVerifiedPair,
        resolvedAuthority: DeviceIngressResolvedAuthority,
        admittedAt: Date
    ) {
        let request = verifiedPair.request
        schema = Self.currentSchema
        admissionID = DeviceIngressCanonicalWire.base64URL(verifiedPair.requestSHA256)
        requestSHA256 = verifiedPair.requestSHA256
        challengeSHA256 = verifiedPair.challengeSHA256
        bodySHA256 = verifiedPair.bodySHA256
        nonceSHA256 = DeviceIngressCanonicalWire.sha256(request.nonce)
        targetCellUUID = resolvedAuthority.targetCellUUID
        targetOwnerSigningKeyFingerprint = DeviceIngressEnvelopeVerifier.signingKeyFingerprint(
            for: resolvedAuthority.targetOwner
        ) ?? ""
        authorityID = resolvedAuthority.authorityID
        authorityGeneration = resolvedAuthority.authorityGeneration
        agreementID = resolvedAuthority.agreementID
        signedAgreementSHA256 = resolvedAuthority.signedAgreementSHA256
        revocationLedgerID = resolvedAuthority.revocationLedgerID
        revocationGeneration = resolvedAuthority.revocationGeneration
        subjectIdentityUUID = resolvedAuthority.subjectIdentityUUID
        subjectSigningKeyFingerprint = resolvedAuthority.subjectSigningKeyFingerprint
        operation = request.operation
        capability = request.capability
        issuedAtMilliseconds = request.issuedAtMilliseconds
        expiresAtMilliseconds = request.expiresAtMilliseconds
        admittedAtMilliseconds = Int64(
            (admittedAt.timeIntervalSince1970 * 1_000).rounded(.towardZero)
        )
    }

    public func canonicalData() throws -> Data {
        try DeviceIngressCanonicalWire.canonicalData(for: self, excludingTopLevelKeys: [])
    }
}

public struct DeviceIngressAdmissionReceipt: Codable, Equatable, Sendable {
    public static let currentSchema = "cellprotocol.device-ingress.admission-receipt.v1"
    public static let durableBeforeMutation = "atomic_durable_before_cell_mutation"

    public let schema: String
    public let admissionID: String
    public let recordSHA256: Data
    public let durableSequence: UInt64
    public let committedAtMilliseconds: Int64
    public let persistenceSemantics: String

    public init(
        schema: String = Self.currentSchema,
        admissionID: String,
        recordSHA256: Data,
        durableSequence: UInt64,
        committedAtMilliseconds: Int64,
        persistenceSemantics: String = Self.durableBeforeMutation
    ) {
        self.schema = schema
        self.admissionID = admissionID
        self.recordSHA256 = recordSHA256
        self.durableSequence = durableSequence
        self.committedAtMilliseconds = committedAtMilliseconds
        self.persistenceSemantics = persistenceSemantics
    }
}

public enum DeviceIngressAdmissionCommitOutcome: Sendable {
    case committed(DeviceIngressAdmissionReceipt)
    case replay(existingAdmissionID: String)
    case generationRollback
    case unavailable
}

/// Production implementations must atomically and durably insert the admission
/// record before returning `.committed`. They must reject duplicate challenge/
/// nonce records and enforce monotonic authority and revocation generations.
public protocol DeviceIngressDurableAdmissionLedger: Sendable {
    func commit(
        _ record: DeviceIngressAdmissionRecord
    ) async -> DeviceIngressAdmissionCommitOutcome
}

public struct DeviceIngressCompletedAdmission: Sendable {
    public let pair: DeviceIngressVerifiedPair
    public let authority: DeviceIngressResolvedAuthority
    public let record: DeviceIngressAdmissionRecord
    public let admissionReceipt: DeviceIngressAdmissionReceipt
    public let mutationReceipt: DeviceIngressMutationReceipt

    init(
        pair: DeviceIngressVerifiedPair,
        authority: DeviceIngressResolvedAuthority,
        record: DeviceIngressAdmissionRecord,
        admissionReceipt: DeviceIngressAdmissionReceipt,
        mutationReceipt: DeviceIngressMutationReceipt
    ) {
        self.pair = pair
        self.authority = authority
        self.record = record
        self.admissionReceipt = admissionReceipt
        self.mutationReceipt = mutationReceipt
    }
}

enum DeviceIngressAdmissionPipeline {
    /// The only authority-producing path: exact proof verification, independent
    /// signed-Agreement verification, durable replay consumption, and a same-
    /// Cell atomic authority-generation CAS plus durable mutation.
    static func verifyAuthorizeCommitAndMutate(
        canonicalRequestData: Data,
        protectedBody: Data,
        canonicalChallengeData: Data,
        expectedAudience: String,
        expectedChallengeIssuer: IdentityPublicKeyDescriptor,
        resolver: any CellResolverProtocol,
        ledger: any DeviceIngressDurableAdmissionLedger,
        now: Date = Date()
    ) async throws -> DeviceIngressCompletedAdmission {
        let pair = try DeviceIngressEnvelopeVerifier.verifyRequest(
            canonicalData: canonicalRequestData,
            protectedBody: protectedBody,
            canonicalChallengeData: canonicalChallengeData,
            expectedAudience: expectedAudience,
            expectedChallengeIssuer: expectedChallengeIssuer,
            now: now
        )
        let authorityRequest = try DeviceIngressAuthorityRequest(verifiedPair: pair)
        let authorizedTarget = try await DeviceIngressResolverAuthorizer.authorize(
            authorityRequest,
            resolver: resolver,
            now: now
        )
        let record = DeviceIngressAdmissionRecord(
            verifiedPair: pair,
            resolvedAuthority: authorizedTarget.resolved,
            admittedAt: now
        )
        let outcome = await ledger.commit(record)
        let receipt: DeviceIngressAdmissionReceipt
        switch outcome {
        case .committed(let value):
            receipt = value
        case .replay:
            throw DeviceIngressValidationError.replayDetected
        case .generationRollback:
            throw DeviceIngressValidationError.admissionLedgerRollback
        case .unavailable:
            throw DeviceIngressValidationError.admissionLedgerUnavailable
        }
        let expectedRecordHash = DeviceIngressCanonicalWire.sha256(try record.canonicalData())
        guard receipt.schema == DeviceIngressAdmissionReceipt.currentSchema,
              receipt.admissionID == record.admissionID,
              receipt.recordSHA256 == expectedRecordHash,
              receipt.durableSequence > 0,
              receipt.committedAtMilliseconds >= record.admittedAtMilliseconds,
              receipt.committedAtMilliseconds < record.expiresAtMilliseconds,
              receipt.persistenceSemantics == DeviceIngressAdmissionReceipt.durableBeforeMutation else {
            throw DeviceIngressValidationError.invalidAdmissionReceipt
        }
        let mutationDecision = await authorizedTarget.cell.commitDeviceIngressMutation(
            DeviceIngressMutationCommand(
                authorityRequest: authorizedTarget.request,
                admissionRecord: record,
                admissionReceipt: receipt,
                protectedBody: protectedBody
            )
        )
        let mutationReceipt: DeviceIngressMutationReceipt
        switch mutationDecision {
        case .committed(let value):
            mutationReceipt = value
        case .denied(let reasonCode):
            throw DeviceIngressValidationError.mutationDenied(reasonCode)
        }
        guard mutationReceipt.schema == DeviceIngressMutationReceipt.currentSchema,
              mutationReceipt.admissionID == record.admissionID,
              mutationReceipt.requestSHA256 == record.requestSHA256,
              mutationReceipt.targetCellUUID == record.targetCellUUID,
              mutationReceipt.targetOwnerSigningKeyFingerprint
                == record.targetOwnerSigningKeyFingerprint,
              mutationReceipt.signedAgreementSHA256 == record.signedAgreementSHA256,
              mutationReceipt.authorityGeneration == record.authorityGeneration,
              mutationReceipt.revocationGeneration == record.revocationGeneration,
              mutationReceipt.mutationRecordSHA256.count == 32,
              mutationReceipt.committedAtMilliseconds >= receipt.committedAtMilliseconds,
              mutationReceipt.committedAtMilliseconds < record.expiresAtMilliseconds,
              mutationReceipt.persistenceSemantics
                == DeviceIngressMutationReceipt.atomicRecheckAndDurableMutation else {
            throw DeviceIngressValidationError.invalidMutationReceipt
        }
        return DeviceIngressCompletedAdmission(
            pair: pair,
            authority: authorizedTarget.resolved,
            record: record,
            admissionReceipt: receipt,
            mutationReceipt: mutationReceipt
        )
    }
}

/// A Scaffold composition root creates one instance with its pinned issuer,
/// resolver and durable ledger. Transport adapters can submit bytes, but cannot
/// choose or replace the trust context and cannot invoke staged authorization.
public actor DeviceIngressAdmissionService {
    private let expectedAudience: String
    private let expectedChallengeIssuer: IdentityPublicKeyDescriptor
    private let resolver: any CellResolverProtocol
    private let ledger: any DeviceIngressDurableAdmissionLedger

    @_spi(HAVENRuntime)
    public init(
        expectedAudience: String,
        expectedChallengeIssuer: IdentityPublicKeyDescriptor,
        resolver: any CellResolverProtocol,
        ledger: any DeviceIngressDurableAdmissionLedger
    ) {
        self.expectedAudience = expectedAudience
        self.expectedChallengeIssuer = expectedChallengeIssuer
        self.resolver = resolver
        self.ledger = ledger
    }

    public func admitAndMutate(
        canonicalRequestData: Data,
        protectedBody: Data,
        canonicalChallengeData: Data
    ) async throws -> DeviceIngressCompletedAdmission {
        try await admitAndMutate(
            canonicalRequestData: canonicalRequestData,
            protectedBody: protectedBody,
            canonicalChallengeData: canonicalChallengeData,
            now: Date()
        )
    }

    func admitAndMutate(
        canonicalRequestData: Data,
        protectedBody: Data,
        canonicalChallengeData: Data,
        now: Date
    ) async throws -> DeviceIngressCompletedAdmission {
        try await DeviceIngressAdmissionPipeline.verifyAuthorizeCommitAndMutate(
            canonicalRequestData: canonicalRequestData,
            protectedBody: protectedBody,
            canonicalChallengeData: canonicalChallengeData,
            expectedAudience: expectedAudience,
            expectedChallengeIssuer: expectedChallengeIssuer,
            resolver: resolver,
            ledger: ledger,
            now: now
        )
    }
}
