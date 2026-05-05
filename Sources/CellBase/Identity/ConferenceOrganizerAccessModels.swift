// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum ConferenceOrganizerAccessRole: String, Codable, Equatable, Sendable {
    case admin = "conference.organizer.admin"
}

public struct ConferenceRoleGrantScopeDescriptor: Codable, Equatable, Sendable {
    public var conferenceID: String
    public var accessSurface: String

    public init(
        conferenceID: String,
        accessSurface: String = "organizer.admin"
    ) {
        self.conferenceID = conferenceID
        self.accessSurface = accessSurface
    }
}

public struct ConferenceRoleGrantCredentialSubject: Codable, Equatable, Sendable {
    public var id: String
    public var grantedRole: ConferenceOrganizerAccessRole
    public var entityBinding: EntityBindingDescriptor
    public var scope: ConferenceRoleGrantScopeDescriptor
    public var validUntil: String
    public var revocationReference: String?

    public init(
        id: String,
        grantedRole: ConferenceOrganizerAccessRole,
        entityBinding: EntityBindingDescriptor,
        scope: ConferenceRoleGrantScopeDescriptor,
        validUntil: String,
        revocationReference: String? = nil
    ) {
        self.id = id
        self.grantedRole = grantedRole
        self.entityBinding = entityBinding
        self.scope = scope
        self.validUntil = validUntil
        self.revocationReference = revocationReference
    }
}

public enum OrganizerAccessEvidenceSource: String, Codable, Equatable, Sendable {
    case directOwner
    case stableOrganizerIdentity
    case credentialBundle
}

public enum OrganizerAccessDecisionStatus: String, Codable, Equatable, Sendable {
    case granted
    case denied
}

public enum OrganizerAccessIssueCode: String, Codable, Equatable, Sendable {
    case missingSameEntityCredential
    case missingRoleGrantCredential
    case invalidSameEntityCredential
    case invalidRoleGrantCredential
    case requesterBindingMismatch
    case linkedIdentityMismatch
    case issuerMismatch
    case roleMismatch
    case conferenceMismatch
    case entityBindingMismatch
    case credentialExpired
}

public struct OrganizerAccessIssue: Codable, Equatable, Sendable {
    public var code: OrganizerAccessIssueCode
    public var message: String

    public init(code: OrganizerAccessIssueCode, message: String) {
        self.code = code
        self.message = message
    }
}

public struct OrganizerEntityBindingResolution: Codable, Equatable, Sendable {
    public var entityBinding: EntityBindingDescriptor
    public var sameEntityProofKeypath: String
    public var roleGrantProofKeypath: String
    public var issuerDid: String

    public init(
        entityBinding: EntityBindingDescriptor,
        sameEntityProofKeypath: String,
        roleGrantProofKeypath: String,
        issuerDid: String
    ) {
        self.entityBinding = entityBinding
        self.sameEntityProofKeypath = sameEntityProofKeypath
        self.roleGrantProofKeypath = roleGrantProofKeypath
        self.issuerDid = issuerDid
    }
}

public struct OrganizerAccessDecision: Codable, Equatable, Sendable {
    public var status: OrganizerAccessDecisionStatus
    public var evidenceSource: OrganizerAccessEvidenceSource?
    public var requiredRole: ConferenceOrganizerAccessRole
    public var conferenceID: String
    public var resolution: OrganizerEntityBindingResolution?
    public var issues: [OrganizerAccessIssue]

    public init(
        status: OrganizerAccessDecisionStatus,
        evidenceSource: OrganizerAccessEvidenceSource?,
        requiredRole: ConferenceOrganizerAccessRole,
        conferenceID: String,
        resolution: OrganizerEntityBindingResolution? = nil,
        issues: [OrganizerAccessIssue] = []
    ) {
        self.status = status
        self.evidenceSource = evidenceSource
        self.requiredRole = requiredRole
        self.conferenceID = conferenceID
        self.resolution = resolution
        self.issues = issues
    }

    public var granted: Bool {
        status == .granted
    }
}

public enum ConferenceOrganizerAccessVerifier {
    public static let defaultSameEntityProofKeypaths = [
        "identity.proofs.conference.organizer.sameEntity"
    ]

    public static func defaultRoleGrantProofKeypaths(
        conferenceID: String,
        role: ConferenceOrganizerAccessRole = .admin
    ) -> [String] {
        let normalizedConferenceID = normalizedKeypathComponent(conferenceID)
        return [
            "identity.proofs.conference.roles.organizer.admin",
            "identity.proofs.conference.roles.\(normalizedConferenceID).organizer.admin"
        ]
    }

    public static func evaluateFromIdentityProofs(
        requester: Identity,
        ownerUUID: String,
        stableOrganizerUUID: String? = nil,
        conferenceID: String,
        requiredRole: ConferenceOrganizerAccessRole = .admin,
        sameEntityProofKeypaths: [String]? = nil,
        roleGrantProofKeypaths: [String]? = nil
    ) async -> OrganizerAccessDecision {
        if requester.uuid == ownerUUID {
            return OrganizerAccessDecision(
                status: .granted,
                evidenceSource: .directOwner,
                requiredRole: requiredRole,
                conferenceID: conferenceID
            )
        }

        if let stableOrganizerUUID, requester.uuid == stableOrganizerUUID {
            return OrganizerAccessDecision(
                status: .granted,
                evidenceSource: .stableOrganizerIdentity,
                requiredRole: requiredRole,
                conferenceID: conferenceID
            )
        }

        let sameEntityPaths = sameEntityProofKeypaths ?? defaultSameEntityProofKeypaths
        let rolePaths = roleGrantProofKeypaths ?? defaultRoleGrantProofKeypaths(
            conferenceID: conferenceID,
            role: requiredRole
        )

        guard let sameEntityCandidate = await loadCredential(from: sameEntityPaths, requester: requester) else {
            return denied(
                conferenceID: conferenceID,
                requiredRole: requiredRole,
                code: .missingSameEntityCredential,
                message: "No same-entity credential found for organizer access."
            )
        }

        guard let roleGrantCandidate = await loadCredential(from: rolePaths, requester: requester) else {
            return denied(
                conferenceID: conferenceID,
                requiredRole: requiredRole,
                code: .missingRoleGrantCredential,
                message: "No organizer role grant found for the requested conference."
            )
        }

        do {
            guard try await sameEntityCandidate.claim.verify() else {
                return denied(
                    conferenceID: conferenceID,
                    requiredRole: requiredRole,
                    code: .invalidSameEntityCredential,
                    message: "Same-entity credential signature verification failed."
                )
            }

            guard try await roleGrantCandidate.claim.verify() else {
                return denied(
                    conferenceID: conferenceID,
                    requiredRole: requiredRole,
                    code: .invalidRoleGrantCredential,
                    message: "Organizer role grant signature verification failed."
                )
            }

            let sameEntitySubject: SameEntityIdentityLinkCredentialSubject = try decodeCredentialSubject(
                from: sameEntityCandidate.claim
            )
            let roleGrantSubject: ConferenceRoleGrantCredentialSubject = try decodeCredentialSubject(
                from: roleGrantCandidate.claim
            )

            guard sameEntitySubject.id == roleGrantSubject.id else {
                return denied(
                    conferenceID: conferenceID,
                    requiredRole: requiredRole,
                    code: .requesterBindingMismatch,
                    message: "Organizer access proofs do not agree on the same subject identifier."
                )
            }

            guard requesterMatchesLinkedIdentity(
                sameEntitySubject.linkedIdentity,
                subjectDid: sameEntitySubject.id,
                requester: requester
            ) else {
                return denied(
                    conferenceID: conferenceID,
                    requiredRole: requiredRole,
                    code: .requesterBindingMismatch,
                    message: "Organizer access credential subject does not match the current requester identity."
                )
            }

            guard sameEntitySubject.linkedIdentity.uuid == requester.uuid else {
                return denied(
                    conferenceID: conferenceID,
                    requiredRole: requiredRole,
                    code: .linkedIdentityMismatch,
                    message: "Same-entity credential does not bind the current requester identity."
                )
            }

            guard roleGrantSubject.grantedRole == requiredRole else {
                return denied(
                    conferenceID: conferenceID,
                    requiredRole: requiredRole,
                    code: .roleMismatch,
                    message: "Organizer role grant does not satisfy the required organizer role."
                )
            }

            guard roleGrantSubject.scope.conferenceID == conferenceID else {
                return denied(
                    conferenceID: conferenceID,
                    requiredRole: requiredRole,
                    code: .conferenceMismatch,
                    message: "Organizer role grant does not apply to the requested conference."
                )
            }

            guard sameEntitySubject.entityBinding == roleGrantSubject.entityBinding else {
                return denied(
                    conferenceID: conferenceID,
                    requiredRole: requiredRole,
                    code: .entityBindingMismatch,
                    message: "Organizer role grant and same-entity proof resolve to different entity bindings."
                )
            }

            guard let sameEntityIssuerDid = issuerDid(from: sameEntityCandidate.claim.issuer),
                  let roleGrantIssuerDid = issuerDid(from: roleGrantCandidate.claim.issuer),
                  sameEntityIssuerDid == roleGrantIssuerDid else {
                return denied(
                    conferenceID: conferenceID,
                    requiredRole: requiredRole,
                    code: .issuerMismatch,
                    message: "Organizer access proofs were not issued by the same authority."
                )
            }

            guard isStillValid(sameEntitySubject.validUntil),
                  isStillValid(roleGrantSubject.validUntil) else {
                return denied(
                    conferenceID: conferenceID,
                    requiredRole: requiredRole,
                    code: .credentialExpired,
                    message: "Organizer access credential has expired."
                )
            }

            return OrganizerAccessDecision(
                status: .granted,
                evidenceSource: .credentialBundle,
                requiredRole: requiredRole,
                conferenceID: conferenceID,
                resolution: OrganizerEntityBindingResolution(
                    entityBinding: roleGrantSubject.entityBinding,
                    sameEntityProofKeypath: sameEntityCandidate.keypath,
                    roleGrantProofKeypath: roleGrantCandidate.keypath,
                    issuerDid: roleGrantIssuerDid
                )
            )
        } catch {
            return OrganizerAccessDecision(
                status: .denied,
                evidenceSource: nil,
                requiredRole: requiredRole,
                conferenceID: conferenceID,
                issues: [
                    OrganizerAccessIssue(
                        code: .invalidRoleGrantCredential,
                        message: "Organizer access credential parsing failed: \(error)"
                    )
                ]
            )
        }
    }

    private static func denied(
        conferenceID: String,
        requiredRole: ConferenceOrganizerAccessRole,
        code: OrganizerAccessIssueCode,
        message: String
    ) -> OrganizerAccessDecision {
        OrganizerAccessDecision(
            status: .denied,
            evidenceSource: nil,
            requiredRole: requiredRole,
            conferenceID: conferenceID,
            issues: [OrganizerAccessIssue(code: code, message: message)]
        )
    }

    private static func loadCredential(
        from keypaths: [String],
        requester: Identity
    ) async -> (claim: VCClaim, keypath: String)? {
        for keypath in keypaths {
            do {
                let value = try await requester.get(keypath: keypath, requester: requester)
                let claim = try parseCredential(from: value)
                return (claim, keypath)
            } catch {
                continue
            }
        }
        return nil
    }

    private static func parseCredential(from value: ValueType) throws -> VCClaim {
        switch value {
        case .verifiableCredential(let claim):
            return claim
        case .object(let payload):
            if let nested = payload["credential"] {
                return try parseCredential(from: nested)
            }
            if let nested = payload["claim"] {
                return try parseCredential(from: nested)
            }
            let claimData = try JSONEncoder().encode(payload)
            return try JSONDecoder().decode(VCClaim.self, from: claimData)
        default:
            throw ConferenceOrganizerAccessVerificationError.invalidCredentialFormat
        }
    }

    private static func decodeCredentialSubject<T: Decodable>(from claim: VCClaim) throws -> T {
        let subjectData = try JSONEncoder().encode(claim.credentialSubject)
        return try JSONDecoder().decode(T.self, from: subjectData)
    }

    private static func requesterMatchesLinkedIdentity(
        _ linkedIdentity: IdentityPublicKeyDescriptor,
        subjectDid: String,
        requester: Identity
    ) -> Bool {
        guard linkedIdentity.uuid == requester.uuid else {
            return false
        }

        if let requesterDid = try? requester.did(), requesterDid == subjectDid {
            return true
        }

        if let compressedKey = requester.publicSecureKey?.compressedKey,
           compressedKey == linkedIdentity.publicKey {
            return true
        }

        return false
    }

    private static func issuerDid(from issuer: IssuerType) -> String? {
        switch issuer {
        case .reference(let did):
            return did
        case .embedded(let object):
            if case let .string(did)? = object["id"] {
                return did
            }
            return nil
        }
    }

    private static func isStillValid(_ value: String) -> Bool {
        guard let date = iso8601Formatter.date(from: value) else {
            return false
        }
        return date >= Date()
    }

    private static func normalizedKeypathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = value.lowercased().unicodeScalars.map { scalar -> String in
            allowed.contains(scalar) ? String(scalar) : "_"
        }
        let collapsed = scalars.joined()
        while collapsed.contains("__") {
            return normalizedKeypathComponent(collapsed.replacingOccurrences(of: "__", with: "_"))
        }
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

enum ConferenceOrganizerAccessVerificationError: Error {
    case invalidCredentialFormat
}
