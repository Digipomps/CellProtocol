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
    private var privateKeys: [String: Curve25519.Signing.PrivateKey] = [:]
    private let vaultReference = "curve25519-test:\(UUID().uuidString)"

    func identityVaultReference() async -> String? {
        vaultReference
    }

    func initialize() async -> IdentityVaultProtocol {
        self
    }

    func addIdentity(identity: inout Identity, for identityContext: String) async {
        identity.identityVault = self
        identity.homeVaultReference = vaultReference
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

    func identity(forUUID uuid: String) async -> Identity? {
        identities.values.first(where: { $0.uuid == uuid })
    }

    func identityExistInVault(_ identity: Identity) async -> Bool {
        guard identity.homeVaultReference == vaultReference,
              let stored = identities.values.first(where: { $0.uuid == identity.uuid }) else {
            return false
        }
        return stored.signingPublicKeyFingerprint == identity.signingPublicKeyFingerprint
            && privateKeys[identity.uuid] != nil
    }

    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        guard await identityExistInVault(identity),
              let privateKey = privateKeys[identity.uuid] else {
            throw IdentityVaultError.signingFailed
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
        Data(repeating: 0x11, count: 64)
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
        identity.homeVaultReference = vaultReference
        privateKeys[identity.uuid] = privateKey
        identities[displayName] = identity
        return identity
    }
}

final class TrustedIssuerCellTests: XCTestCase {
    func testTrustedIssuerRejectsUnsupportedDidMethodsAndAdvertisesImplementedSet() async throws {
        let previousVault = CellBase.defaultIdentityVault
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        defer { CellBase.defaultIdentityVault = previousVault }

        let resolvedOwner = await vault.identity(for: "private", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(resolvedOwner)
        let cell = await TrustedIssuerCell(owner: owner)
        let result = try await cell.set(
            keypath: "trustedIssuers.policy.upsert",
            value: .object([
                "contextId": .string("unsupported-did-policy"),
                "maximumCredentialAgeSeconds": .float(3_600),
                "acceptedDidMethods": .list([.string("did:web")])
            ]),
            requester: owner
        )

        guard case .string(let error) = result else {
            return XCTFail("Expected unsupported DID method error")
        }
        XCTAssertTrue(error.contains("unsupported acceptedDidMethods"))

        let state = try await cell.get(keypath: "trustedIssuers.state", requester: owner)
        guard case .object(let stateObject) = state,
              case .list(let methods)? = stateObject["supportedDidMethods"] else {
            return XCTFail("Expected supportedDidMethods in trusted issuer state")
        }
        XCTAssertEqual(methods, [.string("did:key")])
    }

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

    func testVCClaimInitializerBindsSubjectToProvidedIdentityKey() async throws {
        let vault = Curve25519TestIdentityVault()
        let issuer = await vault.makeIdentity(displayName: "issuer")
        let subject = await vault.makeIdentity(displayName: "subject")

        let claim = try await VCClaim(
            type: "IdentityCredential",
            issuerIdentity: issuer,
            subjectIdentity: subject,
            credentialSubject: ["id": .string("attacker-controlled"), "active": .bool(true)]
        )

        XCTAssertEqual(claim.credentialSubject["id"], .string(try subject.did()))
    }

    func testProvedClaimRejectsUUIDOnlyAndSameUUIDWrongKeySubjects() async throws {
        CellBase.debugValidateAccessForEverything = true

        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver

        let vault = Curve25519TestIdentityVault()
        let issuer = await vault.makeIdentity(displayName: "issuer")
        let legitimateSubject = await vault.makeIdentity(displayName: "legitimate-subject")
        let unrelatedKeyOwner = await vault.makeIdentity(displayName: "unrelated-key")
        let forgedRequester = Identity(
            legitimateSubject.uuid,
            displayName: "forged-same-uuid",
            identityVault: nil
        )
        forgedRequester.publicSecureKey = unrelatedKeyOwner.publicSecureKey

        var uuidOnlyClaim = try await VCClaim(
            type: "AgeCredential",
            issuerIdentity: issuer,
            subjectIdentity: legitimateSubject,
            credentialSubject: ["age": .integer(18)]
        )
        uuidOnlyClaim.credentialSubject["id"] = .string(legitimateSubject.uuid)
        try await uuidOnlyClaim.generateProof(issuerIdentity: issuer)

        let claimData = try JSONEncoder().encode(uuidOnlyClaim)
        let claimObject = try JSONDecoder().decode(Object.self, from: claimData)
        let forgedAnchor = TestEmitCell(owner: forgedRequester, uuid: "forged-entity-anchor")
        _ = try await forgedAnchor.set(
            keypath: "claims.ageProof",
            value: .object(claimObject),
            requester: forgedRequester
        )
        try await resolver.registerNamedEmitCell(
            name: "EntityAnchor",
            emitCell: forgedAnchor,
            scope: .identityUnique,
            identity: forgedRequester
        )

        let target = TestEmitCell(owner: issuer, uuid: "protected-target")
        let condition = ProvedClaimCondition(
            name: "age_over_18",
            statement: "identity.claims.ageProof >= 18",
            requiredCredentialType: "AgeCredential",
            subjectClaimPath: "age"
        )

        let state = await condition.isMet(
            context: ConnectContext(source: nil, target: target, identity: forgedRequester)
        )

        XCTAssertEqual(state, .unresolved)

        var didBoundClaim = try await VCClaim(
            type: "AgeCredential",
            issuerIdentity: issuer,
            subjectIdentity: legitimateSubject,
            credentialSubject: ["age": .integer(18)]
        )
        try await didBoundClaim.generateProof(issuerIdentity: issuer)
        let didBoundObject = try JSONDecoder().decode(
            Object.self,
            from: JSONEncoder().encode(didBoundClaim)
        )
        _ = try await forgedAnchor.set(
            keypath: "claims.ageProof",
            value: .object(didBoundObject),
            requester: forgedRequester
        )
        let sameUUIDWrongKeyState = await condition.isMet(
            context: ConnectContext(source: nil, target: target, identity: forgedRequester)
        )
        XCTAssertEqual(sameUUIDWrongKeyState, .unresolved)

        var missingSubjectClaim = didBoundClaim
        missingSubjectClaim.credentialSubject["id"] = nil
        try await missingSubjectClaim.generateProof(issuerIdentity: issuer)
        let missingSubjectObject = try JSONDecoder().decode(
            Object.self,
            from: JSONEncoder().encode(missingSubjectClaim)
        )
        _ = try await forgedAnchor.set(
            keypath: "claims.ageProof",
            value: .object(missingSubjectObject),
            requester: legitimateSubject
        )
        let missingSubjectState = await condition.isMet(
            context: ConnectContext(source: nil, target: target, identity: legitimateSubject)
        )
        XCTAssertEqual(missingSubjectState, .unresolved)
    }

    func testTrustedIssuerCellEvaluateReturnsTrustedForValidCredential() async throws {
        CellBase.debugValidateAccessForEverything = true

        let ownerVault = EphemeralIdentityVault()
        CellBase.defaultIdentityVault = ownerVault
        let issuerVault = Curve25519TestIdentityVault()
        let issuerIdentity = await issuerVault.makeIdentity(displayName: "issuer")
        let ownerIdentity = await ownerVault.identity(for: "owner", makeNewIfNotFound: true)
        let subjectIdentity = await ownerVault.identity(for: "subject", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(ownerIdentity)
        let subject = try XCTUnwrap(subjectIdentity)

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
                "maximumCredentialAgeSeconds": .float(86_400),
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
        let requesterIdentity = await issuerVault.identity(for: "requester", makeNewIfNotFound: true)
        let targetOwnerIdentity = await issuerVault.identity(for: "target-owner", makeNewIfNotFound: true)
        let requester = try XCTUnwrap(requesterIdentity)
        let targetOwner = try XCTUnwrap(targetOwnerIdentity)
        let requesterDID = try requester.did()

        var claim = try await VCClaim(
            type: "AgeCredential",
            issuerIdentity: issuerIdentity,
            subjectIdentity: requester,
            credentialSubject: [
                "id": .string(requesterDID),
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
                "maximumCredentialAgeSeconds": .float(86_400),
                "requireRevocationCheck": .bool(false),
                    "requireSubjectBinding": .bool(true),
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
        let condition = ProvedClaimCondition(
            name: "age_over_13",
            statement: "identity.claims.ageProof >= 13",
            requiredCredentialType: "AgeCredential",
            subjectClaimPath: "age"
        )
        let context = ConnectContext(source: nil, target: target, identity: requester)
        let state = await condition.isMet(context: context)
        XCTAssertEqual(state, .met)
    }

    func testTargetOwnerSignatureIsNotImplicitCredentialTrust() async throws {
        CellBase.debugValidateAccessForEverything = true
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver

        let vault = Curve25519TestIdentityVault()
        let targetOwner = await vault.makeIdentity(displayName: "target-owner-issuer")
        let requester = await vault.makeIdentity(displayName: "requester")
        var claim = try await VCClaim(
            type: "AgeCredential",
            issuerIdentity: targetOwner,
            subjectIdentity: requester,
            credentialSubject: ["age": .integer(18)]
        )
        try await claim.generateProof(issuerIdentity: targetOwner)
        let claimObject = try JSONDecoder().decode(
            Object.self,
            from: JSONEncoder().encode(claim)
        )
        let anchor = TestEmitCell(owner: requester, uuid: "owner-fallback-anchor")
        _ = try await anchor.set(
            keypath: "claims.ageProof",
            value: .object(claimObject),
            requester: requester
        )
        try await resolver.registerNamedEmitCell(
            name: "EntityAnchor",
            emitCell: anchor,
            scope: .identityUnique,
            identity: requester
        )

        let condition = ProvedClaimCondition(
            name: "age_over_18",
            statement: "identity.claims.ageProof >= 18",
            requiredCredentialType: "AgeCredential",
            subjectClaimPath: "age"
        )
        let state = await condition.isMet(
            context: ConnectContext(
                source: nil,
                target: TestEmitCell(owner: targetOwner, uuid: "protected-target"),
                identity: requester
            )
        )

        XCTAssertEqual(state, .unresolved)
    }

    func testTrustedIssuerEvaluationRejectsStaleFutureUnsignedStatusAndWrongCallerProofs() async throws {
        CellBase.debugValidateAccessForEverything = true
        let vault = Curve25519TestIdentityVault()
        let issuer = await vault.makeIdentity(displayName: "issuer")
        let subject = await vault.makeIdentity(displayName: "subject")
        let attacker = await vault.makeIdentity(displayName: "attacker")
        let cell = await TrustedIssuerCell(owner: subject)
        let contextID = "bounded-age"

        func installPolicy(requireRevocation: Bool) async throws {
            _ = try await cell.set(
                keypath: "trustedIssuers.policy.upsert",
                value: .object([
                    "contextId": .string(contextID),
                    "threshold": .float(0.5),
                    "maximumCredentialAgeSeconds": .float(30.0 * 86_400.0),
                    "requireRevocationCheck": .bool(requireRevocation),
                    "requireSubjectBinding": .bool(true),
                    "requireIndependentSources": .integer(0),
                    "acceptedDidMethods": .list([.string("did:key")]),
                    "claimSchema": .object([
                        "credentialType": .string("AgeCredential"),
                        "subjectPath": .string("credentialSubject.age"),
                        "operator": .string(">="),
                        "expectedValue": .integer(18)
                    ])
                ]),
                requester: subject
            )
        }

        try await installPolicy(requireRevocation: false)
        _ = try await cell.set(
            keypath: "trustedIssuers.issuer.upsert",
            value: .object([
                "issuerId": .string(try issuer.did()),
                "displayName": .string("Issuer"),
                "issuerKind": .string("institution"),
                "baseWeight": .float(0.9),
                "contexts": .list([.string(contextID)]),
                "status": .string("active")
            ]),
            requester: subject
        )

        func makeClaim(issuedAt: Date = Date()) async throws -> VCClaim {
            var claim = try await VCClaim(
                type: "AgeCredential",
                issuerIdentity: issuer,
                subjectIdentity: subject,
                credentialSubject: ["age": .integer(20)]
            )
            claim.issuanceDate = issuedAt
            try await claim.generateProof(issuerIdentity: issuer)
            return claim
        }

        func evaluate(
            _ object: Object,
            requester: Identity,
            suppliedRequesterID: String? = nil
        ) async throws -> ValueType {
            var payload: Object = [
                "issuerId": .string(try issuer.did()),
                "contextId": .string(contextID),
                "candidateVc": .object(object)
            ]
            if let suppliedRequesterID {
                payload["requesterId"] = .string(suppliedRequesterID)
            }
            return try await cell.set(
                keypath: "trustedIssuers.evaluate",
                value: .object(payload),
                requester: requester
            ) ?? .null
        }

        func object(_ claim: VCClaim) throws -> Object {
            try JSONDecoder().decode(Object.self, from: JSONEncoder().encode(claim))
        }

        func decision(_ value: ValueType) -> String? {
            guard case let .object(record) = value,
                  case let .string(result)? = record["decision"] else {
                return nil
            }
            return result
        }

        let fresh = try await makeClaim()
        let freshResult = try await evaluate(try object(fresh), requester: subject)
        XCTAssertEqual(decision(freshResult), "trusted")

        let future = try await makeClaim(
            issuedAt: Date().addingTimeInterval(IdentitySigningChallenge.allowedClockSkew + 60)
        )
        let futureResult = try await evaluate(try object(future), requester: subject)
        XCTAssertEqual(decision(futureResult), "untrusted")

        let stale = try await makeClaim(issuedAt: Date().addingTimeInterval(-31 * 86_400))
        let staleResult = try await evaluate(try object(stale), requester: subject)
        XCTAssertEqual(decision(staleResult), "untrusted")

        var unsignedTimeEnvelope = try object(stale)
        unsignedTimeEnvelope["expirationDate"] = .string("2999-01-01T00:00:00Z")
        let unsignedTimeResult = try await evaluate(unsignedTimeEnvelope, requester: subject)
        XCTAssertEqual(decision(unsignedTimeResult), "untrusted")

        var missingProof = try await makeClaim()
        missingProof.proof.signatureData = Data()
        let missingProofResult = try await evaluate(
            try object(missingProof),
            requester: subject
        )
        XCTAssertEqual(decision(missingProofResult), "untrusted")

        let wrongCallerResult = try await evaluate(
            try object(fresh),
            requester: attacker
        )
        XCTAssertEqual(decision(wrongCallerResult), "untrusted")
        let spoofedRequesterResult = try await evaluate(
            try object(fresh),
            requester: attacker,
            suppliedRequesterID: try subject.did()
        )
        guard case let .string(spoofedRequesterError) = spoofedRequesterResult else {
            return XCTFail("Expected requester mismatch error")
        }
        XCTAssertTrue(spoofedRequesterError.contains("does not match"))

        try await installPolicy(requireRevocation: true)
        var embeddedActiveStatus = try object(fresh)
        embeddedActiveStatus["credentialStatus"] = .object(["status": .string("active")])
        let revocationRequired = try await evaluate(
            embeddedActiveStatus,
            requester: subject
        )
        XCTAssertEqual(decision(revocationRequired), "untrusted")
        guard case let .object(revocationRecord) = revocationRequired,
              case let .list(reasons)? = revocationRecord["reasons"] else {
            return XCTFail("Expected revocation failure reasons")
        }
        XCTAssertTrue(reasons.contains(.string("revocation_check_unsupported")))
    }

    func testDecodedTrustedIssuerAwaitsSingleRuntimeInstallAndSerializesConcurrentState() async throws {
        CellBase.debugValidateAccessForEverything = false
        let vault = Curve25519TestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.makeIdentity(displayName: "runtime-owner")
        let issuer = await vault.makeIdentity(displayName: "runtime-issuer")
        let contextID = "runtime-readiness"
        let cell = await TrustedIssuerCell(owner: owner)

        _ = try await cell.set(
            keypath: "trustedIssuers.policy.upsert",
            value: .object([
                "contextId": .string(contextID),
                "threshold": .float(0.5),
                "maximumCredentialAgeSeconds": .float(86_400),
                "requireRevocationCheck": .bool(false),
                "requireSubjectBinding": .bool(true),
                "requireIndependentSources": .integer(0),
                "acceptedDidMethods": .list([.string("did:key")]),
                "claimSchema": .object([
                    "credentialType": .string("AgeCredential"),
                    "subjectPath": .string("credentialSubject.age"),
                    "operator": .string(">="),
                    "expectedValue": .integer(18)
                ])
            ]),
            requester: owner
        )
        _ = try await cell.set(
            keypath: "trustedIssuers.issuer.upsert",
            value: .object([
                "issuerId": .string(try issuer.did()),
                "issuerKind": .string("institution"),
                "baseWeight": .float(0.9),
                "contexts": .list([.string(contextID)]),
                "status": .string("active")
            ]),
            requester: owner
        )

        var claim = try await VCClaim(
            type: "AgeCredential",
            issuerIdentity: issuer,
            subjectIdentity: owner,
            credentialSubject: ["age": .integer(20)]
        )
        try await claim.generateProof(issuerIdentity: issuer)
        let claimObject = try JSONDecoder().decode(
            Object.self,
            from: JSONEncoder().encode(claim)
        )
        let decoded = try JSONDecoder().decode(
            TrustedIssuerCell.self,
            from: JSONEncoder().encode(cell)
        )

        let checks = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let keys = try await decoded.keys(requester: owner)
                    return keys.contains("trustedIssuers.evaluate")
                }
            }
            for index in 0..<24 {
                group.addTask {
                    let result = try await decoded.set(
                        keypath: "trustedIssuers.evaluate",
                        value: .object([
                            "evaluationId": .string("concurrent-\(index)"),
                            "issuerId": .string(try issuer.did()),
                            "contextId": .string(contextID),
                            "candidateVc": .object(claimObject)
                        ]),
                        requester: owner
                    ) ?? .null
                    guard case let .object(record) = result,
                          case .string("trusted")? = record["decision"] else {
                        return false
                    }
                    return true
                }
            }
            for index in 0..<12 {
                group.addTask {
                    let result = try await decoded.set(
                        keypath: "trustedIssuers.policy.upsert",
                        value: .object([
                            "contextId": .string("parallel-policy-\(index)"),
                            "maximumCredentialAgeSeconds": .float(86_400)
                        ]),
                        requester: owner
                    ) ?? .null
                    if case .object = result { return true }
                    return false
                }
            }

            var results = [Bool]()
            for try await result in group {
                results.append(result)
            }
            return results
        }

        XCTAssertEqual(checks.count, 44)
        XCTAssertTrue(checks.allSatisfy { $0 })
        XCTAssertEqual(
            decoded.agreementTemplate.grants.filter {
                $0.keypath == "trustedIssuers" && $0.permission.permissionString == "rw--"
            }.count,
            1
        )

        let state = try await decoded.get(
            keypath: "trustedIssuers.state",
            requester: owner
        )
        guard case let .object(stateObject) = state else {
            return XCTFail("Expected TrustedIssuer state object")
        }
        XCTAssertEqual(stateObject["evaluationHistoryCount"], .integer(24))
        XCTAssertEqual(stateObject["policyCount"], .integer(13))

        let restarted = try JSONDecoder().decode(
            TrustedIssuerCell.self,
            from: JSONEncoder().encode(decoded)
        )
        let restartedState = try await restarted.get(
            keypath: "trustedIssuers.state",
            requester: owner
        )
        guard case let .object(restartedObject) = restartedState else {
            return XCTFail("Expected restarted TrustedIssuer state object")
        }
        XCTAssertEqual(restartedObject["evaluationHistoryCount"], .integer(24))
        XCTAssertEqual(restartedObject["policyCount"], .integer(13))
    }
}
