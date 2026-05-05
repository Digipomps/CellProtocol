// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import CellBase

actor OrganizerAccessTestIdentityVault: IdentityVaultProtocol {
    private var identities: [String: Identity] = [:]
    private var privateKeys: [String: Curve25519.Signing.PrivateKey] = [:]

    func initialize() async -> IdentityVaultProtocol {
        self
    }

    func addIdentity(identity: inout Identity, for identityContext: String) async {
        identity.identityVault = self
        identities[identityContext] = identity
    }

    func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity? {
        if let existing = identities[identityContext] {
            return existing
        }
        guard makeNewIfNotFound else { return nil }
        let identity = makeIdentity(displayName: identityContext)
        identities[identityContext] = identity
        return identity
    }

    func saveIdentity(_ identity: Identity) async {
        identities[identity.displayName] = identity
    }

    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        guard let privateKey = privateKeys[identity.uuid] else {
            throw TestError.noPrivateKey
        }
        return try privateKey.signature(for: messageData)
    }

    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool {
        guard let compressedKey = identity.publicSecureKey?.compressedKey else {
            return false
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: compressedKey)
        return publicKey.isValidSignature(signature, for: messageData)
    }

    func randomBytes64() async -> Data? {
        Data(repeating: 0x42, count: 64)
    }

    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) {
        ("test-key-\(tag)", "test-iv-\(tag)")
    }

    func makeIdentity(displayName: String) -> Identity {
        let privateKey = Curve25519.Signing.PrivateKey()
        let identity = Identity(UUID().uuidString, displayName: displayName, identityVault: self)
        identity.publicSecureKey = SecureKey(
            date: Date(),
            privateKey: false,
            use: .signature,
            algorithm: .EdDSA,
            size: 32,
            curveType: .Curve25519,
            x: nil,
            y: nil,
            compressedKey: privateKey.publicKey.rawRepresentation
        )
        privateKeys[identity.uuid] = privateKey
        return identity
    }

    enum TestError: Error {
        case noPrivateKey
    }
}

final class ConferenceOrganizerAccessModelsTests: XCTestCase {
    private var previousResolver: CellResolverProtocol?
    private var previousVault: IdentityVaultProtocol?

    override func setUp() {
        super.setUp()
        previousResolver = CellBase.defaultCellResolver
        previousVault = CellBase.defaultIdentityVault
    }

    override func tearDown() {
        CellBase.defaultCellResolver = previousResolver
        CellBase.defaultIdentityVault = previousVault
        super.tearDown()
    }

    func testOrganizerAccessVerifierGrantsDirectOwner() async throws {
        let owner = Identity("organizer-owner", displayName: "Organizer Owner", identityVault: nil)

        let decision = await ConferenceOrganizerAccessVerifier.evaluateFromIdentityProofs(
            requester: owner,
            ownerUUID: owner.uuid,
            stableOrganizerUUID: "conference-organizer",
            conferenceID: "conference-dimy-2026"
        )

        XCTAssertTrue(decision.granted)
        XCTAssertEqual(decision.evidenceSource, .directOwner)
    }

    func testOrganizerAccessVerifierGrantsCredentialBackedRequester() async throws {
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver

        let vault = OrganizerAccessTestIdentityVault()
        CellBase.defaultIdentityVault = vault

        let owner = await vault.makeIdentity(displayName: "organizer-owner")
        let requester = await vault.makeIdentity(displayName: "binding-requester")
        try await registerEntityAnchor(for: requester, resolver: resolver)

        try await installOrganizerProofs(
            issuer: owner,
            requester: requester,
            conferenceID: "conference-dimy-2026"
        )

        let decision = await ConferenceOrganizerAccessVerifier.evaluateFromIdentityProofs(
            requester: requester,
            ownerUUID: owner.uuid,
            stableOrganizerUUID: "conference-organizer",
            conferenceID: "conference-dimy-2026"
        )

        XCTAssertTrue(decision.granted)
        XCTAssertEqual(decision.evidenceSource, .credentialBundle)
        XCTAssertEqual(decision.resolution?.sameEntityProofKeypath, "identity.proofs.conference.organizer.sameEntity")
        XCTAssertEqual(decision.resolution?.roleGrantProofKeypath, "identity.proofs.conference.roles.organizer.admin")
    }

    func testOrganizerAccessVerifierRejectsConferenceMismatch() async throws {
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver

        let vault = OrganizerAccessTestIdentityVault()
        CellBase.defaultIdentityVault = vault

        let owner = await vault.makeIdentity(displayName: "organizer-owner")
        let requester = await vault.makeIdentity(displayName: "binding-requester")
        try await registerEntityAnchor(for: requester, resolver: resolver)

        try await installOrganizerProofs(
            issuer: owner,
            requester: requester,
            conferenceID: "conference-other-2026"
        )

        let decision = await ConferenceOrganizerAccessVerifier.evaluateFromIdentityProofs(
            requester: requester,
            ownerUUID: owner.uuid,
            stableOrganizerUUID: "conference-organizer",
            conferenceID: "conference-dimy-2026"
        )

        XCTAssertFalse(decision.granted)
        XCTAssertEqual(decision.issues.first?.code, .conferenceMismatch)
    }

    private func installOrganizerProofs(
        issuer: Identity,
        requester: Identity,
        conferenceID: String
    ) async throws {
        let entityBinding = EntityBindingDescriptor(
            mode: .pairwise,
            bindingID: "pairwise-organizer-entity",
            audience: conferenceID
        )
        let linkedIdentity = try linkedIdentityDescriptor(for: requester)
        let requesterDid = try requester.did()
        let validUntil = Self.isoFormatter.string(from: Date().addingTimeInterval(3600))

        let sameEntitySubject = SameEntityIdentityLinkCredentialSubject(
            id: requesterDid,
            entityBinding: entityBinding,
            linkedIdentity: linkedIdentity,
            approvedDomains: ["conference"],
            approvedIdentityContexts: ["private"],
            approvedScopes: ["conference.organizer.admin"],
            enrollmentRequestHash: Data("request-hash".utf8),
            assuranceSource: "existing_device",
            assuranceLevel: "high",
            validUntil: validUntil
        )

        var sameEntityClaim = try await VCClaim(
            type: "SameEntityIdentityLinkCredential",
            issuerIdentity: issuer,
            subjectIdentity: requester,
            credentialSubject: try object(from: sameEntitySubject)
        )
        try await sameEntityClaim.generateProof(issuerIdentity: issuer)

        let roleGrantSubject = ConferenceRoleGrantCredentialSubject(
            id: requesterDid,
            grantedRole: .admin,
            entityBinding: entityBinding,
            scope: ConferenceRoleGrantScopeDescriptor(conferenceID: conferenceID),
            validUntil: validUntil
        )

        var roleGrantClaim = try await VCClaim(
            type: "ConferenceRoleGrantCredential",
            issuerIdentity: issuer,
            subjectIdentity: requester,
            credentialSubject: try object(from: roleGrantSubject)
        )
        try await roleGrantClaim.generateProof(issuerIdentity: issuer)

        _ = try await requester.set(
            keypath: "identity.proofs.conference.organizer.sameEntity",
            value: .object(try claimObject(from: sameEntityClaim)),
            requester: requester
        )
        _ = try await requester.set(
            keypath: "identity.proofs.conference.roles.organizer.admin",
            value: .object(try claimObject(from: roleGrantClaim)),
            requester: requester
        )
    }

    private func registerEntityAnchor(for identity: Identity, resolver: MockCellResolver) async throws {
        let entityAnchor = TestEmitCell(owner: identity, uuid: "entity-anchor-\(identity.uuid)")
        try await resolver.registerNamedEmitCell(
            name: "EntityAnchor",
            emitCell: entityAnchor,
            scope: .identityUnique,
            identity: identity
        )
    }

    private func linkedIdentityDescriptor(for identity: Identity) throws -> IdentityPublicKeyDescriptor {
        guard let secureKey = identity.publicSecureKey,
              let compressedKey = secureKey.compressedKey else {
            throw TestError.missingPublicKey
        }
        return IdentityPublicKeyDescriptor(
            uuid: identity.uuid,
            displayName: identity.displayName,
            publicKey: compressedKey,
            algorithm: secureKey.algorithm,
            curveType: secureKey.curveType
        )
    }

    private func object<T: Encodable>(from value: T) throws -> Object {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ValueType.self, from: data)
        guard case let .object(object) = decoded else {
            throw TestError.invalidObjectEncoding
        }
        return object
    }

    private func claimObject(from claim: VCClaim) throws -> Object {
        let data = try JSONEncoder().encode(claim)
        let decoded = try JSONDecoder().decode(ValueType.self, from: data)
        guard case let .object(object) = decoded else {
            throw TestError.invalidObjectEncoding
        }
        return object
    }

    private enum TestError: Error {
        case missingPublicKey
        case invalidObjectEncoding
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
