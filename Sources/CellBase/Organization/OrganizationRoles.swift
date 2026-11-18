// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// purpose://candidate.informasjonssystemer-gruppeentitet.roles
// purpose://candidate.informasjonssystemer-gruppeentitet.revoke
// purpose://candidate.informasjonssystemer-gruppeentitet.status-offline
//
// An organization gives roles as verifiable credentials signed by its own key
// (the vault's custodian key), never by an owner's personal key. Every field
// that decides access (role, cohort, validUntil) lives in credentialSubject,
// which the proof covers. Revocation is a signed status list that the node
// mirrors; a check reads the mirror and never calls the organization. A mirror
// that is missing or too old gives `unknown`, which fails closed.

public enum OrganizationRoleCredential {
    /// Generic type carried by every organization role credential.
    public static let genericType = "OrganizationRoleCredential"

    public enum Field {
        public static let organization = "organization"
        public static let role = "role"
        public static let cohort = "cohort"
        public static let validUntil = "validUntil"
        public static let policyHash = "policyHash"
    }

    /// The unsigned credential the owners approve. Its hash is the proposal's
    /// payload hash; the vault signs exactly this.
    public static func unsigned(
        organizationAnchorID: String,
        credentialType: String,
        custodian: IdentityPublicKeyDescriptor,
        subject: IdentityPublicKeyDescriptor,
        role: String,
        cohort: String?,
        validUntil: String,
        policyHash: Data,
        issuedAt: Date
    ) throws -> VCClaim {
        let issuer = IdentityLinkProtocolService.identity(from: custodian)
        let holder = IdentityLinkProtocolService.identity(from: subject)
        var subjectObject: Object = [
            Field.organization: .string(organizationAnchorID),
            Field.role: .string(role),
            Field.validUntil: .string(validUntil),
            Field.policyHash: .string(policyHash.base64EncodedString()),
        ]
        if let cohort { subjectObject[Field.cohort] = .string(cohort) }
        var claim = VCClaim(issuerIdentity: issuer, subjectIdentity: holder, credentialSubject: subjectObject)
        claim.type = ["VerifiableCredential", genericType, credentialType]
        // Whole seconds: the wire format is RFC 3339 without fractions, so the
        // hash the owners approve must survive an encode/decode round trip.
        claim.issuanceDate = Date(timeIntervalSince1970: issuedAt.timeIntervalSince1970.rounded(.down))
        return claim
    }

    public static func payloadHash(of claim: VCClaim) throws -> Data {
        OrganizationHashing.sha256(try claim.canonicalUnsignedClaimData())
    }

    /// What the owner is shown, derived only from the credential.
    public static func summary(of claim: VCClaim, displayName: String) -> String {
        let subject = claim.credentialSubject
        let role = subject[Field.role].flatMap(stringValue) ?? "?"
        let until = subject[Field.validUntil].flatMap(stringValue) ?? "?"
        let holder = subject["id"].flatMap(stringValue) ?? "?"
        var text = "\(displayName) gir rollen «\(role)» til \(holder)"
        if let cohort = subject[Field.cohort].flatMap(stringValue) { text += " i kullet \(cohort)" }
        return text + ", gyldig til \(until)."
    }

    static func stringValue(_ value: ValueType) -> String? {
        if case let .string(text) = value { return text }
        return nil
    }
}

/// A signed list of revoked credential ids. Each new list has a higher sequence.
public struct OrganizationRoleStatusList: Codable, Equatable, Sendable, CanonicalPayloadSignable {
    public var version: Int
    public var organizationAnchorID: String
    /// did:key of the custodian key that signs the organization's credentials.
    public var issuerDID: String
    public var sequence: Int
    public var issuedAt: String
    public var revokedCredentialIDs: [String]
    public var signature: Data?

    public init(
        version: Int = 1,
        organizationAnchorID: String,
        issuerDID: String,
        sequence: Int,
        issuedAt: String,
        revokedCredentialIDs: [String],
        signature: Data? = nil
    ) {
        self.version = version
        self.organizationAnchorID = organizationAnchorID
        self.issuerDID = issuerDID
        self.sequence = sequence
        self.issuedAt = issuedAt
        self.revokedCredentialIDs = Array(Set(revokedCredentialIDs)).sorted()
        self.signature = signature
    }

    public func canonicalPayloadData() throws -> Data {
        try CanonicalPayloadEncoder.data(for: self, excludingTopLevelKeys: ["signature"])
    }

    public func payloadHash() throws -> Data {
        OrganizationHashing.sha256(try canonicalPayloadData())
    }

    public func signatureIsValid() -> Bool {
        guard let signature,
              let payload = try? canonicalPayloadData(),
              let material = try? DIDKeyParser.extractPublicKeyAndDID(from: issuerDID) else {
            return false
        }
        let algorithm: CurveAlgorithm
        switch material.curveType {
        case .Curve25519: algorithm = .EdDSA
        case .P256: algorithm = .ECDSA
        case .secp256k1: return false
        }
        return IdentityPublicKeySignatureVerifier.verify(
            signature: signature,
            messageData: payload,
            descriptor: IdentityPublicKeyDescriptor(uuid: issuerDID, publicKey: material.publicKey,
                                                    algorithm: algorithm, curveType: material.curveType)
        )
    }

    /// What the owner is shown when a revocation is proposed.
    public func summary(displayName: String, newlyRevoked: [String]) -> String {
        "\(displayName) trekker tilbake \(newlyRevoked.count) rolle(r): \(newlyRevoked.sorted().joined(separator: ", ")). Statusliste nr. \(sequence)."
    }
}

public enum CredentialStatusDecision: String, Equatable, Sendable {
    case valid
    case revoked
    /// No mirror, or the mirror is older than the allowed age. Fails closed.
    case unknown
}

public enum CredentialStatusMirrorError: Error, Equatable, Sendable {
    case signatureInvalid
    case sequenceNotNewer(current: Int, offered: Int)
    case issuerMismatch
}

/// The node's mirror of each issuer's latest status list. Checks are local.
public actor CredentialStatusRegistry {
    public static let shared = CredentialStatusRegistry()
    /// Ten minutes (PDD formål status-offline; Kjetil har ikke satt annen grense).
    public static let defaultMaximumAge: TimeInterval = 600

    private struct Mirror {
        var list: OrganizationRoleStatusList
        var refreshedAt: Date
    }
    private var mirrors: [String: Mirror] = [:]

    public init() {}

    /// Accepts a newer signed list, or refreshes the mirror time when the same
    /// list is offered again (the organization's "still current" heartbeat).
    public func accept(_ list: OrganizationRoleStatusList, now: Date = Date()) throws {
        guard list.signatureIsValid() else { throw CredentialStatusMirrorError.signatureInvalid }
        if let current = mirrors[list.issuerDID] {
            if current.list == list {
                mirrors[list.issuerDID]?.refreshedAt = now
                return
            }
            guard list.sequence > current.list.sequence else {
                throw CredentialStatusMirrorError.sequenceNotNewer(current: current.list.sequence, offered: list.sequence)
            }
        }
        mirrors[list.issuerDID] = Mirror(list: list, refreshedAt: now)
    }

    public func hasMirror(issuerDID: String) -> Bool {
        mirrors[issuerDID] != nil
    }

    public func status(
        issuerDID: String,
        credentialID: String,
        now: Date = Date(),
        maximumAge: TimeInterval = CredentialStatusRegistry.defaultMaximumAge
    ) -> CredentialStatusDecision {
        guard let mirror = mirrors[issuerDID] else { return .unknown }
        guard now.timeIntervalSince(mirror.refreshedAt) <= maximumAge else { return .unknown }
        return mirror.list.revokedCredentialIDs.contains(credentialID) ? .revoked : .valid
    }

    public func clear() {
        mirrors.removeAll()
    }
}
