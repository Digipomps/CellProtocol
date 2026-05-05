// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import CellBase

actor Curve25519TestIdentityVault: IdentityVaultProtocol {
    private var identities: [String: Identity] = [:]
    private let privateKey = Curve25519.Signing.PrivateKey()

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
        try privateKey.signature(for: messageData)
    }

    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool {
        guard let compressedKey = identity.publicSecureKey?.compressedKey else {
            return false
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: compressedKey)
        return publicKey.isValidSignature(signature, for: messageData)
    }

    func randomBytes64() async -> Data? {
        Data(repeating: 0x11, count: 64)
    }

    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) {
        ("test-key-\(tag)", "test-iv-\(tag)")
    }

    func makeIdentity(displayName: String) -> Identity {
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
        return identity
    }
}

final class TrustedIssuerCellTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousResolver: CellResolverProtocol?
    private var previousDebugFlag: Bool = false

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousResolver = CellBase.defaultCellResolver
        previousDebugFlag = CellBase.debugValidateAccessForEverything
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.defaultCellResolver = previousResolver
        CellBase.debugValidateAccessForEverything = previousDebugFlag
        super.tearDown()
    }

    func testTrustedIssuerCellEvaluateReturnsTrustedForValidCredential() async throws {
        CellBase.debugValidateAccessForEverything = true

        let issuerVault = Curve25519TestIdentityVault()
        let issuerIdentity = await issuerVault.makeIdentity(displayName: "issuer")
        let owner = TestFixtures.makeIdentity(displayName: "owner")
        let subject = TestFixtures.makeIdentity(displayName: "subject", uuid: UUID())

        let credentialSubject: Object = [
            "id": .string("did:key:z6MkhvN4subject"),
            "age": .integer(20)
        ]
        var claim = try await VCClaim(
            type: "AgeCredential",
            issuerIdentity: issuerIdentity,
            subjectIdentity: subject,
            credentialSubject: credentialSubject
        )
        try await claim.generateProof(issuerIdentity: issuerIdentity)

        let trustedIssuerCell = await TrustedIssuerCell(owner: owner)

        _ = try await trustedIssuerCell.set(
            keypath: "trustedIssuers.policy.upsert",
            value: .object([
                "contextId": .string("age_over_13"),
                "displayName": .string("Age over 13"),
                "threshold": .float(0.5),
                "requireRevocationCheck": .bool(false),
                "requireSubjectBinding": .bool(false),
                "requireIndependentSources": .integer(0),
                "acceptedDidMethods": .list([.string("did:key")]),
                "claimSchema": .object([
                    "credentialType": .string("AgeCredential"),
                    "subjectPath": .string("credentialSubject.age"),
                    "operator": .string(">="),
                    "expectedValue": .integer(13)
                ])
            ]),
            requester: owner
        )

        _ = try await trustedIssuerCell.set(
            keypath: "trustedIssuers.issuer.upsert",
            value: .object([
                "issuerId": .string(try issuerIdentity.did()),
                "displayName": .string("Issuer"),
                "issuerKind": .string("institution"),
                "baseWeight": .float(0.9),
                "contexts": .list([.string("age_over_13")]),
                "status": .string("active")
            ]),
            requester: owner
        )

        let claimData = try JSONEncoder().encode(claim)
        let claimObject = try JSONDecoder().decode(Object.self, from: claimData)

        let result = try await trustedIssuerCell.set(
            keypath: "trustedIssuers.evaluate",
            value: .object([
                "issuerId": .string(try issuerIdentity.did()),
                "contextId": .string("age_over_13"),
                "candidateVc": .object(claimObject)
            ]),
            requester: owner
        )

        guard
            let result,
            case .object(let resultObject) = result,
            case .string(let decision)? = resultObject["decision"]
        else {
            XCTFail("Missing decision from trusted issuer evaluation")
            return
        }
        XCTAssertEqual(decision, "trusted")
    }

    func testProvedClaimConditionUsesTrustedIssuerEvaluation() async throws {
        CellBase.debugValidateAccessForEverything = true

        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver

        let issuerVault = Curve25519TestIdentityVault()
        let issuerIdentity = await issuerVault.makeIdentity(displayName: "issuer")
        let requester = TestFixtures.makeIdentity(displayName: "requester", uuid: UUID())
        let targetOwner = TestFixtures.makeIdentity(displayName: "target-owner", uuid: UUID())

        var claim = try await VCClaim(
            type: "AgeCredential",
            issuerIdentity: issuerIdentity,
            subjectIdentity: requester,
            credentialSubject: [
                "id": .string("did:key:z6MkhvN4subject"),
                "age": .integer(18)
            ]
        )
        try await claim.generateProof(issuerIdentity: issuerIdentity)
        let claimData = try JSONEncoder().encode(claim)
        let claimObject = try JSONDecoder().decode(Object.self, from: claimData)

        let entityAnchor = TestEmitCell(owner: requester, uuid: "entity-anchor")
        _ = try await entityAnchor.set(keypath: "claims.ageProof", value: .object(claimObject), requester: requester)
        try await resolver.registerNamedEmitCell(name: "EntityAnchor", emitCell: entityAnchor, scope: .identityUnique, identity: requester)

        let trustedIssuerCell = await TrustedIssuerCell(owner: requester)
        try await resolver.registerNamedEmitCell(name: "TrustedIssuers", emitCell: trustedIssuerCell, scope: .scaffoldUnique, identity: requester)

        _ = try await trustedIssuerCell.set(
            keypath: "trustedIssuers.policy.upsert",
            value: .object([
                "contextId": .string("age_over_13"),
                "threshold": .float(0.5),
                "requireRevocationCheck": .bool(false),
                "requireSubjectBinding": .bool(false),
                "requireIndependentSources": .integer(0),
                "acceptedDidMethods": .list([.string("did:key")]),
                "claimSchema": .object([
                    "credentialType": .string("AgeCredential"),
                    "subjectPath": .string("credentialSubject.age"),
                    "operator": .string(">="),
                    "expectedValue": .integer(13)
                ])
            ]),
            requester: requester
        )
        _ = try await trustedIssuerCell.set(
            keypath: "trustedIssuers.issuer.upsert",
            value: .object([
                "issuerId": .string(try issuerIdentity.did()),
                "displayName": .string("Issuer"),
                "issuerKind": .string("institution"),
                "baseWeight": .float(0.9),
                "contexts": .list([.string("age_over_13")])
            ]),
            requester: requester
        )

        let target = TestEmitCell(owner: targetOwner, uuid: "target-cell")
        let condition = ProvedClaimCondition(name: "age_over_13", statement: "identity.claims.ageProof = true")
        let context = ConnectContext(source: nil, target: target, identity: requester)
        let state = await condition.isMet(context: context)
        XCTAssertEqual(state, .met)
    }
}
