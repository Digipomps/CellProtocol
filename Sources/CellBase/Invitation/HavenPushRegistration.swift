// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  HavenPushRegistration.swift
//  CellProtocol
//
//  An APNs token belongs to an entity, not to a person's name or e-mail address
//  (purpose://candidate.testmatrise.apns.token-belongs-to-an-entity). The app
//  signs the registration with the entity's own key; the scaffold stores
//  entity, environment, bundleId, token and the time — nothing else — and pins
//  the first key it saw for that entity, so a later claim on the same entity
//  from another key is refused.
//
//  Contract: PDD_testmatrise-og-apns-chat/contract/apns_invite_v1.json
//  (push.register, push.revoke).
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// MARK: - Format rules

public enum HavenPushEnvironment: String, Codable, Equatable, Sendable {
    case sandbox
    case production
}

public enum HavenPushFormat {
    /// Identity UUID, with or without upper case.
    public static func isValidEntity(_ value: String) -> Bool {
        value.utf8.count == 36 && value.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) || $0 == 0x2D
        }
    }

    /// APNs device token: lower-case hex, opaque.
    public static func isValidToken(_ value: String) -> Bool {
        (64...200).contains(value.utf8.count) && value.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
        }
    }

    public static func isValidBundleID(_ value: String) -> Bool {
        (3...155).contains(value.utf8.count) && value.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x2E
        }
    }
}

// MARK: - Registration

public struct HavenPushRegistration: Codable, Equatable, Sendable, CanonicalPayloadSignable {

    public static let schema = "haven.push.register.v1"

    public var schema: String
    public var entity: String
    public var environment: HavenPushEnvironment
    public var bundleId: String
    public var token: String
    public var issuedAt: Int
    /// The public key the signature is checked against. `signer.uuid` must be `entity`.
    public var signer: IdentityPublicKeyDescriptor
    public var proof: HavenSignatureProof?

    public init(
        schema: String = HavenPushRegistration.schema,
        entity: String,
        environment: HavenPushEnvironment,
        bundleId: String,
        token: String,
        issuedAt: Int,
        signer: IdentityPublicKeyDescriptor,
        proof: HavenSignatureProof? = nil
    ) {
        self.schema = schema
        self.entity = entity
        self.environment = environment
        self.bundleId = bundleId
        self.token = token
        self.issuedAt = issuedAt
        self.signer = signer
        self.proof = proof
    }

    public func canonicalPayloadData() throws -> Data {
        try CanonicalPayloadEncoder.data(for: self, excludingTopLevelKeys: ["proof"])
    }

    /// Stable handle for the (entity, environment, bundle, token) tuple; revocation refers to it.
    public var registrationID: String {
        let text = [entity.lowercased(), environment.rawValue, bundleId, token].joined(separator: "|")
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return "pr-" + digest.prefix(32)
    }

    public static func make(
        entity identity: Identity,
        environment: HavenPushEnvironment,
        bundleId: String,
        token: String,
        now: Date = Date()
    ) async throws -> HavenPushRegistration {
        guard let descriptor = IdentityPublicKeySignatureVerifier.descriptor(for: identity) else {
            throw IdentityVaultError.signingFailed
        }
        var registration = HavenPushRegistration(
            entity: descriptor.uuid,
            environment: environment,
            bundleId: bundleId,
            token: token,
            issuedAt: Int(now.timeIntervalSince1970),
            signer: descriptor
        )
        registration.proof = try await HavenInviteSigning.proof(over: try registration.canonicalPayloadData(), by: identity)
        return registration
    }
}

public struct HavenPushRevocation: Codable, Equatable, Sendable, CanonicalPayloadSignable {

    public static let schema = "haven.push.revoke.v1"

    public var schema: String
    public var entity: String
    public var registrationID: String
    public var issuedAt: Int
    public var signer: IdentityPublicKeyDescriptor
    public var proof: HavenSignatureProof?

    public init(
        schema: String = HavenPushRevocation.schema,
        entity: String,
        registrationID: String,
        issuedAt: Int,
        signer: IdentityPublicKeyDescriptor,
        proof: HavenSignatureProof? = nil
    ) {
        self.schema = schema
        self.entity = entity
        self.registrationID = registrationID
        self.issuedAt = issuedAt
        self.signer = signer
        self.proof = proof
    }

    public func canonicalPayloadData() throws -> Data {
        try CanonicalPayloadEncoder.data(for: self, excludingTopLevelKeys: ["proof"])
    }

    public static func make(
        registrationID: String,
        by identity: Identity,
        now: Date = Date()
    ) async throws -> HavenPushRevocation {
        guard let descriptor = IdentityPublicKeySignatureVerifier.descriptor(for: identity) else {
            throw IdentityVaultError.signingFailed
        }
        var revocation = HavenPushRevocation(
            entity: descriptor.uuid,
            registrationID: registrationID,
            issuedAt: Int(now.timeIntervalSince1970),
            signer: descriptor
        )
        revocation.proof = try await HavenInviteSigning.proof(over: try revocation.canonicalPayloadData(), by: identity)
        return revocation
    }
}

// MARK: - Verifier

public enum HavenPushVerifier {

    /// A registration or revocation older (or newer) than this is refused, so a captured one cannot be replayed later.
    public static let maxClockSkewSeconds = 600

    public enum Failure: Error, Equatable, Sendable {
        case unsigned
        case signatureDoesNotMatchEntity
        case badEntity
        case badTokenFormat
        case badBundleID
        case stale
        case keyChanged
        case unknownRegistration
        case notTheOwnerOfRegistration

        /// The codes the contract names under `denies`.
        public var code: String {
            switch self {
            case .unsigned: return "unsigned"
            case .signatureDoesNotMatchEntity: return "signature_does_not_match_entity"
            case .badEntity: return "bad_entity"
            case .badTokenFormat: return "bad_token_format"
            case .badBundleID: return "bad_bundle_id"
            case .stale: return "stale"
            case .keyChanged: return "key_changed"
            case .unknownRegistration: return "unknown_registration"
            case .notTheOwnerOfRegistration: return "not_the_owner_of_registration"
            }
        }
    }

    public static func verify(_ registration: HavenPushRegistration, now: Date = Date()) throws {
        guard HavenPushFormat.isValidEntity(registration.entity) else { throw Failure.badEntity }
        guard HavenPushFormat.isValidToken(registration.token) else { throw Failure.badTokenFormat }
        guard HavenPushFormat.isValidBundleID(registration.bundleId) else { throw Failure.badBundleID }
        guard fresh(registration.issuedAt, now: now) else { throw Failure.stale }
        try verifySignature(of: registration, proof: registration.proof, signer: registration.signer, entity: registration.entity)
    }

    public static func verify(_ revocation: HavenPushRevocation, now: Date = Date()) throws {
        guard HavenPushFormat.isValidEntity(revocation.entity) else { throw Failure.badEntity }
        guard fresh(revocation.issuedAt, now: now) else { throw Failure.stale }
        try verifySignature(of: revocation, proof: revocation.proof, signer: revocation.signer, entity: revocation.entity)
    }

    private static func fresh(_ issuedAt: Int, now: Date) -> Bool {
        abs(Int(now.timeIntervalSince1970) - issuedAt) <= maxClockSkewSeconds
    }

    private static func verifySignature(
        of payload: some CanonicalPayloadSignable,
        proof: HavenSignatureProof?,
        signer: IdentityPublicKeyDescriptor,
        entity: String
    ) throws {
        guard let proof, let signature = proof.signature, !signature.isEmpty else { throw Failure.unsigned }
        guard signer.uuid.lowercased() == entity.lowercased(), proof.byIdentityUUID.lowercased() == entity.lowercased() else {
            throw Failure.signatureDoesNotMatchEntity
        }
        guard IdentityPublicKeySignatureVerifier.verify(
            signature: signature,
            messageData: try payload.canonicalPayloadData(),
            descriptor: signer
        ) else {
            throw Failure.signatureDoesNotMatchEntity
        }
    }
}

// MARK: - Registry

/// What the scaffold keeps: per registration only entity, environment, bundleId, token, issuedAt and the
/// key that signed it. No names, no e-mail, no contact lists. In memory here; the scaffold persists it.
public struct HavenPushRegistry: Codable, Equatable, Sendable {

    public static let maxActivePerEntity = 8

    public struct Record: Codable, Equatable, Sendable {
        public var registrationID: String
        public var entity: String
        public var environment: HavenPushEnvironment
        /// Both are dropped when the registration is revoked.
        public var bundleId: String?
        public var token: String?
        public var issuedAt: Int
        /// First key seen for this entity. Kept after revocation so the entity cannot be taken over later.
        public var signerKey: Data
        public var revokedAt: Int?

        public var isActive: Bool { revokedAt == nil && token != nil }
    }

    public private(set) var records: [Record]

    public init(records: [Record] = []) { self.records = records }

    /// Verifies and stores. The same token registered again is a refresh, not a duplicate.
    @discardableResult
    public mutating func register(_ registration: HavenPushRegistration, now: Date = Date()) throws -> Record {
        try HavenPushVerifier.verify(registration, now: now)
        let entity = registration.entity.lowercased()
        if let pinned = records.first(where: { $0.entity == entity })?.signerKey,
           pinned != registration.signer.publicKey {
            throw HavenPushVerifier.Failure.keyChanged
        }
        let record = Record(
            registrationID: registration.registrationID,
            entity: entity,
            environment: registration.environment,
            bundleId: registration.bundleId,
            token: registration.token,
            issuedAt: registration.issuedAt,
            signerKey: registration.signer.publicKey,
            revokedAt: nil
        )
        if let index = records.firstIndex(where: { $0.registrationID == record.registrationID }) {
            records[index] = record
            return record
        }
        records.append(record)
        let active = records.enumerated().filter { $0.element.entity == entity && $0.element.isActive }
        if active.count > Self.maxActivePerEntity, let oldest = active.min(by: { $0.element.issuedAt < $1.element.issuedAt }) {
            clear(at: oldest.offset, at: now)
        }
        return record
    }

    public mutating func revoke(_ revocation: HavenPushRevocation, now: Date = Date()) throws {
        try HavenPushVerifier.verify(revocation, now: now)
        guard let index = records.firstIndex(where: { $0.registrationID == revocation.registrationID }) else {
            throw HavenPushVerifier.Failure.unknownRegistration
        }
        let record = records[index]
        guard record.entity == revocation.entity.lowercased(), record.signerKey == revocation.signer.publicKey else {
            throw HavenPushVerifier.Failure.notTheOwnerOfRegistration
        }
        clear(at: index, at: now)
    }

    /// APNs answered 410 Unregistered: treat as revoked, internally. Not visible to any sender.
    public mutating func markUnregistered(registrationID: String, now: Date = Date()) {
        guard let index = records.firstIndex(where: { $0.registrationID == registrationID }) else { return }
        clear(at: index, at: now)
    }

    public func activeRegistrations(entity: String) -> [Record] {
        let key = entity.lowercased()
        return records.filter { $0.entity == key && $0.isActive }
    }

    /// True when the entity has registered before but every registration is revoked.
    public func hasOnlyRevoked(entity: String) -> Bool {
        let key = entity.lowercased()
        let mine = records.filter { $0.entity == key }
        return !mine.isEmpty && !mine.contains { $0.isActive }
    }

    private mutating func clear(at index: Int, at now: Date) {
        records[index].token = nil
        records[index].bundleId = nil
        records[index].revokedAt = Int(now.timeIntervalSince1970)
    }
}
