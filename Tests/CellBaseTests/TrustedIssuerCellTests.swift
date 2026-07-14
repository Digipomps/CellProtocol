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
    private var previousExploreMode: CellBase.ExploreContractEnforcementMode = .permissive

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousResolver = CellBase.defaultCellResolver
        previousDebugFlag = CellBase.debugValidateAccessForEverything
        previousExploreMode = CellBase.exploreContractEnforcementMode
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.defaultCellResolver = previousResolver
        CellBase.debugValidateAccessForEverything = previousDebugFlag
        CellBase.exploreContractEnforcementMode = previousExploreMode
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

    func testIssuerAndAttestationSourceTrustStayWithinActiveContexts() async throws {
        CellBase.debugValidateAccessForEverything = false
        let vault = Curve25519TestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.makeIdentity(displayName: "context-owner")
        let candidateIssuer = await vault.makeIdentity(displayName: "context-candidate")
        let sourceIssuer = await vault.makeIdentity(displayName: "context-source")
        let cell = await TrustedIssuerCell(owner: owner)
        let contextA = "context-a"
        let contextB = "context-b"

        for contextID in [contextA, contextB] {
            _ = try await cell.set(
                keypath: "trustedIssuers.policy.upsert",
                value: .object([
                    "contextId": .string(contextID),
                    "threshold": .float(0.5),
                    "maximumCredentialAgeSeconds": .float(86_400),
                    "requireRevocationCheck": .bool(false),
                    "requireSubjectBinding": .bool(true),
                    "requireIndependentSources": .integer(contextID == contextB ? 1 : 0),
                    "acceptedIssuerKinds": .list([.string("institution")]),
                    "acceptedDidMethods": .list([.string("did:key")])
                ]),
                requester: owner
            )
        }

        let candidateIssuerID = try candidateIssuer.did()
        let sourceIssuerID = try sourceIssuer.did()
        _ = try await cell.set(
            keypath: "trustedIssuers.issuer.upsert",
            value: .object([
                "issuerId": .string(candidateIssuerID),
                "issuerKind": .string("institution"),
                "baseWeight": .float(0.9),
                "contexts": .list([.string(contextA)]),
                "status": .string("active")
            ]),
            requester: owner
        )

        var candidateClaim = try await VCClaim(
            type: "ContextCredential",
            issuerIdentity: candidateIssuer,
            subjectIdentity: owner,
            credentialSubject: ["scope": .string("test")]
        )
        try await candidateClaim.generateProof(issuerIdentity: candidateIssuer)
        let candidateObject = try JSONDecoder().decode(
            Object.self,
            from: JSONEncoder().encode(candidateClaim)
        )

        func evaluate(
            issuerID: String,
            contextID: String,
            candidateVc: Object,
            evaluationID: String
        ) async throws -> Object {
            let result = try await cell.set(
                keypath: "trustedIssuers.evaluate",
                value: .object([
                    "evaluationId": .string(evaluationID),
                    "issuerId": .string(issuerID),
                    "contextId": .string(contextID),
                    "candidateVc": .object(candidateVc)
                ]),
                requester: owner
            )
            guard let result, case let .object(record) = result else {
                XCTFail("Expected evaluation record")
                return [:]
            }
            return record
        }

        let allowed = try await evaluate(
            issuerID: candidateIssuerID,
            contextID: contextA,
            candidateVc: candidateObject,
            evaluationID: "candidate-allowed"
        )
        XCTAssertEqual(allowed["decision"], .string("trusted"))

        let wrongContext = try await evaluate(
            issuerID: candidateIssuerID,
            contextID: contextB,
            candidateVc: candidateObject,
            evaluationID: "candidate-wrong-context"
        )
        XCTAssertEqual(wrongContext["decision"], .string("untrusted"))
        guard case let .list(wrongContextReasons)? = wrongContext["reasons"] else {
            return XCTFail("Expected context rejection reasons")
        }
        XCTAssertTrue(wrongContextReasons.contains(.string("issuer_context_not_allowed")))

        _ = try await cell.set(
            keypath: "trustedIssuers.issuer.upsert",
            value: .object([
                "issuerId": .string(candidateIssuerID),
                "issuerKind": .string("person"),
                "baseWeight": .float(0.9),
                "contexts": .list([.string(contextA)]),
                "status": .string("active")
            ]),
            requester: owner
        )
        let wrongKind = try await evaluate(
            issuerID: candidateIssuerID,
            contextID: contextA,
            candidateVc: candidateObject,
            evaluationID: "candidate-wrong-kind"
        )
        XCTAssertEqual(wrongKind["decision"], .string("untrusted"))
        guard case let .list(wrongKindReasons)? = wrongKind["reasons"] else {
            return XCTFail("Expected issuer-kind rejection reasons")
        }
        XCTAssertTrue(wrongKindReasons.contains(.string("issuer_kind_not_allowed")))
        let wrongKindRestored = try JSONDecoder().decode(
            TrustedIssuerCell.self,
            from: JSONEncoder().encode(cell)
        )
        let wrongKindRestoredState = try await wrongKindRestored.get(
            keypath: "trustedIssuers.state",
            requester: owner
        )
        guard case let .object(wrongKindRestoredObject) = wrongKindRestoredState,
              case let .list(wrongKindCurrent)? = wrongKindRestoredObject["evaluationsCurrent"],
              case let .object(wrongKindRecord) = wrongKindCurrent.first else {
            return XCTFail("Expected wrong-kind evaluation to survive restart")
        }
        XCTAssertEqual(wrongKindRestoredObject["evaluationCurrentCount"], .integer(1))
        XCTAssertEqual(wrongKindRecord["decision"], .string("untrusted"))
        XCTAssertEqual(wrongKindRecord["evaluationId"], .string("candidate-wrong-kind"))

        _ = try await cell.set(
            keypath: "trustedIssuers.issuer.upsert",
            value: .object([
                "issuerId": .string(candidateIssuerID),
                "issuerKind": .string("institution"),
                "baseWeight": .float(0.5),
                "contexts": .list([.string(contextB)]),
                "status": .string("active")
            ]),
            requester: owner
        )
        let invalidatedState = try await cell.get(
            keypath: "trustedIssuers.state",
            requester: owner
        )
        guard case let .object(invalidatedObject) = invalidatedState else {
            return XCTFail("Expected state after issuer policy change")
        }
        XCTAssertEqual(invalidatedObject["evaluationCurrentCount"], .integer(0))
        _ = try await cell.set(
            keypath: "trustedIssuers.issuer.upsert",
            value: .object([
                "issuerId": .string(sourceIssuerID),
                "issuerKind": .string("institution"),
                "baseWeight": .float(1.0),
                "contexts": .list([.string(contextA)]),
                "status": .string("active")
            ]),
            requester: owner
        )
        _ = try await cell.set(
            keypath: "trustedIssuers.attestation.publish",
            value: .object([
                "attestationId": .string("cross-context-source"),
                "subjectIssuerId": .string(candidateIssuerID),
                "contextId": .string(contextB),
                "weight": .float(1.0),
                "issuer": .string(sourceIssuerID)
            ]),
            requester: owner
        )

        let sourceWrongContext = try await evaluate(
            issuerID: candidateIssuerID,
            contextID: contextB,
            candidateVc: candidateObject,
            evaluationID: "source-wrong-context"
        )
        XCTAssertEqual(sourceWrongContext["decision"], .string("untrusted"))
        guard case let .object(wrongContextComponents)? = sourceWrongContext["components"] else {
            return XCTFail("Expected scoring components")
        }
        XCTAssertEqual(wrongContextComponents["endorsementContribution"], .float(0))

        _ = try await cell.set(
            keypath: "trustedIssuers.issuer.upsert",
            value: .object([
                "issuerId": .string(sourceIssuerID),
                "issuerKind": .string("institution"),
                "baseWeight": .float(1.0),
                "contexts": .list([.string(contextB)]),
                "status": .string("inactive")
            ]),
            requester: owner
        )
        let sourceInactive = try await evaluate(
            issuerID: candidateIssuerID,
            contextID: contextB,
            candidateVc: candidateObject,
            evaluationID: "source-inactive"
        )
        XCTAssertEqual(sourceInactive["decision"], .string("untrusted"))

        _ = try await cell.set(
            keypath: "trustedIssuers.issuer.upsert",
            value: .object([
                "issuerId": .string(sourceIssuerID),
                "issuerKind": .string("institution"),
                "baseWeight": .float(1.0),
                "contexts": .list([.string(contextB)]),
                "status": .string("active")
            ]),
            requester: owner
        )
        let sourceAllowed = try await evaluate(
            issuerID: candidateIssuerID,
            contextID: contextB,
            candidateVc: candidateObject,
            evaluationID: "source-allowed"
        )
        XCTAssertEqual(sourceAllowed["decision"], .string("trusted"))

        _ = try await cell.set(
            keypath: "trustedIssuers.issuer.upsert",
            value: .object([
                "issuerId": .string(sourceIssuerID),
                "issuerKind": .string("institution"),
                "baseWeight": .float(1.0),
                "contexts": .list([.string(contextB)]),
                "status": .string("inactive")
            ]),
            requester: owner
        )
        let stateAfterSourceInvalidation = try await cell.get(
            keypath: "trustedIssuers.state",
            requester: owner
        )
        guard case let .object(sourceInvalidatedObject) = stateAfterSourceInvalidation else {
            return XCTFail("Expected state after source invalidation")
        }
        XCTAssertEqual(sourceInvalidatedObject["evaluationCurrentCount"], .integer(0))

        _ = try await cell.set(
            keypath: "trustedIssuers.issuer.upsert",
            value: .object([
                "issuerId": .string(sourceIssuerID),
                "issuerKind": .string("institution"),
                "baseWeight": .float(1.0),
                "contexts": .list([.string(contextB)]),
                "status": .string("active")
            ]),
            requester: owner
        )
        let sourceAllowedAgain = try await evaluate(
            issuerID: candidateIssuerID,
            contextID: contextB,
            candidateVc: candidateObject,
            evaluationID: "source-allowed-again"
        )
        XCTAssertEqual(sourceAllowedAgain["decision"], .string("trusted"))
        _ = try await cell.set(
            keypath: "trustedIssuers.attestation.revoke",
            value: .object(["attestationId": .string("cross-context-source")]),
            requester: owner
        )
        let stateAfterAttestationRevocation = try await cell.get(
            keypath: "trustedIssuers.state",
            requester: owner
        )
        guard case let .object(attestationInvalidatedObject) = stateAfterAttestationRevocation else {
            return XCTFail("Expected state after attestation revocation")
        }
        XCTAssertEqual(attestationInvalidatedObject["evaluationCurrentCount"], .integer(0))
    }

    func testEvaluationCachesAreBoundedAndColdRestoreCanonicalizesPersistedKeys() async throws {
        CellBase.debugValidateAccessForEverything = false
        let vault = Curve25519TestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.makeIdentity(displayName: "bounded-owner")
        let evaluator = await vault.makeIdentity(displayName: "bounded-evaluator")
        let cell = await TrustedIssuerCell(owner: owner)
        let contextID = "bounded-cache"

        _ = try await cell.set(
            keypath: "trustedIssuers.policy.upsert",
            value: .object([
                "contextId": .string(contextID),
                "threshold": .float(0.5),
                "maximumCredentialAgeSeconds": .float(86_400),
                "requireIndependentSources": .integer(0)
            ]),
            requester: owner
        )

        for index in 0...512 {
            let result = try await cell.set(
                keypath: "trustedIssuers.evaluate",
                value: .object([
                    "evaluationId": .string(String(format: "unregistered-%04d", index)),
                    "issuerId": .string(String(format: "did:key:unregistered-%04d", index)),
                    "contextId": .string(contextID)
                ]),
                requester: evaluator
            )
            guard let result, case let .object(record) = result else {
                return XCTFail("Expected bounded unregistered evaluation record")
            }
            XCTAssertEqual(record["decision"], .string("untrusted"))
        }

        let unregisteredStateValue = try await cell.get(
            keypath: "trustedIssuers.state",
            requester: owner
        )
        var state = try XCTUnwrap(unregisteredStateValue)
        guard case let .object(unregisteredState) = state else {
            return XCTFail("Expected TrustedIssuer state")
        }
        XCTAssertEqual(unregisteredState["evaluationHistoryCount"], .integer(512))
        XCTAssertEqual(unregisteredState["evaluationCurrentCount"], .integer(0))

        let unregisteredHistory = try await cell.get(
            keypath: "trustedIssuers.evaluations.history",
            requester: owner
        )
        guard case let .list(unregisteredRecords) = unregisteredHistory,
              case let .object(firstUnregistered) = unregisteredRecords.first,
              case let .object(lastUnregistered) = unregisteredRecords.last else {
            return XCTFail("Expected bounded evaluation history")
        }
        XCTAssertEqual(firstUnregistered["evaluationId"], .string("unregistered-0001"))
        XCTAssertEqual(lastUnregistered["evaluationId"], .string("unregistered-0512"))

        for index in 0...512 {
            let issuerID = String(format: "did:key:registered-%04d", index)
            _ = try await cell.set(
                keypath: "trustedIssuers.issuer.upsert",
                value: .object([
                    "issuerId": .string(issuerID),
                    "baseWeight": .float(0.5),
                    "contexts": .list([.string(contextID)]),
                    "status": .string("active")
                ]),
                requester: owner
            )
        }
        for index in 0...512 {
            let issuerID = String(format: "did:key:registered-%04d", index)
            let result = try await cell.set(
                keypath: "trustedIssuers.evaluate",
                value: .object([
                    "evaluationId": .string(String(format: "registered-%04d", index)),
                    "issuerId": .string(issuerID),
                    "contextId": .string(contextID)
                ]),
                requester: evaluator
            )
            guard let result, case .object = result else {
                return XCTFail("Expected registered evaluation record")
            }
        }

        let boundedStateValue = try await cell.get(
            keypath: "trustedIssuers.state",
            requester: owner
        )
        state = try XCTUnwrap(boundedStateValue)
        guard case let .object(boundedState) = state,
              case let .list(currentRecords)? = boundedState["evaluationsCurrent"] else {
            return XCTFail("Expected bounded current evaluations")
        }
        XCTAssertEqual(boundedState["evaluationHistoryCount"], .integer(512))
        XCTAssertEqual(boundedState["evaluationCurrentCount"], .integer(512))
        let currentEvaluationIDs = Set(currentRecords.compactMap { value -> String? in
            guard case let .object(record) = value,
                  case let .string(evaluationID)? = record["evaluationId"] else {
                return nil
            }
            return evaluationID
        })
        XCTAssertFalse(currentEvaluationIDs.contains("registered-0000"))
        XCTAssertTrue(currentEvaluationIDs.contains("registered-0512"))

        let encoded = try JSONEncoder().encode(cell)
        var persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var persistedCurrent = try XCTUnwrap(
            persisted["evaluationCurrentByKey"] as? [String: Any]
        )
        var persistedHistory = try XCTUnwrap(
            persisted["evaluationHistory"] as? [[String: Any]]
        )
        var injectedRecord = try XCTUnwrap(persistedHistory.last)
        injectedRecord["evaluationId"] = "persisted-newest"
        injectedRecord["issuerId"] = "did:key:registered-0000"
        injectedRecord["contextId"] = contextID
        injectedRecord["createdAt"] = "9999-12-31T23:59:59Z"
        var legacySnapshot = injectedRecord
        legacySnapshot.removeValue(forKey: "snapshotHash")
        let legacySnapshotData = try JSONSerialization.data(
            withJSONObject: legacySnapshot,
            options: [.sortedKeys]
        )
        injectedRecord["snapshotHash"] = legacySnapshotData.base64EncodedString()
        var corruptedRecord = injectedRecord
        corruptedRecord["evaluationId"] = "persisted-corrupt"
        corruptedRecord["issuerId"] = "did:key:registered-0001"
        corruptedRecord["createdAt"] = "9999-12-31T23:59:59Z"
        corruptedRecord["snapshotHash"] = "corrupt-snapshot"
        persistedCurrent["hostile-noncanonical-key"] = injectedRecord
        persistedCurrent["hostile-corrupt-key"] = corruptedRecord
        persistedHistory.append(injectedRecord)
        persistedHistory.append(corruptedRecord)
        persisted["evaluationCurrentByKey"] = persistedCurrent
        persisted["evaluationHistory"] = persistedHistory

        let hostileData = try JSONSerialization.data(withJSONObject: persisted)
        let restored = try JSONDecoder().decode(TrustedIssuerCell.self, from: hostileData)
        let restoredState = try await restored.get(
            keypath: "trustedIssuers.state",
            requester: owner
        )
        guard case let .object(restoredObject) = restoredState,
              case let .list(restoredCurrent)? = restoredObject["evaluationsCurrent"] else {
            return XCTFail("Expected restored bounded state")
        }
        XCTAssertEqual(restoredObject["evaluationHistoryCount"], .integer(512))
        XCTAssertEqual(restoredObject["evaluationCurrentCount"], .integer(512))
        XCTAssertTrue(restoredCurrent.contains { value in
            guard case let .object(record) = value else { return false }
            return record["evaluationId"] == .string("persisted-newest")
        })
        XCTAssertFalse(restoredCurrent.contains { value in
            guard case let .object(record) = value else { return false }
            return record["evaluationId"] == .string("persisted-corrupt")
        })
        let restoredHistory = try await restored.get(
            keypath: "trustedIssuers.evaluations.history",
            requester: owner
        )
        guard case let .list(restoredHistoryRecords) = restoredHistory else {
            return XCTFail("Expected restored evaluation history")
        }
        XCTAssertFalse(restoredHistoryRecords.contains { value in
            guard case let .object(record) = value else { return false }
            return record["evaluationId"] == .string("persisted-corrupt")
        })

        let restarted = try JSONDecoder().decode(
            TrustedIssuerCell.self,
            from: JSONEncoder().encode(restored)
        )
        let restartedState = try await restarted.get(
            keypath: "trustedIssuers.state",
            requester: owner
        )
        guard case let .object(restartedObject) = restartedState else {
            return XCTFail("Expected restarted bounded state")
        }
        func evaluationIDs(_ value: ValueType?) -> Set<String> {
            guard case let .list(records)? = value else { return [] }
            return Set(records.compactMap { recordValue in
                guard case let .object(record) = recordValue,
                      case let .string(evaluationID)? = record["evaluationId"] else {
                    return nil
                }
                return evaluationID
            })
        }
        XCTAssertEqual(
            evaluationIDs(restartedObject["evaluationsCurrent"]),
            evaluationIDs(restoredObject["evaluationsCurrent"])
        )
        XCTAssertEqual(restartedObject["evaluationHistoryCount"], .integer(512))
    }

    func testEvaluationIdentifiersAreSizeBoundedAndSnapshotUsesCanonicalSHA256() async throws {
        CellBase.debugValidateAccessForEverything = false
        let vault = Curve25519TestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.makeIdentity(displayName: "snapshot-owner")
        let issuer = await vault.makeIdentity(displayName: "snapshot-issuer")
        let cell = await TrustedIssuerCell(owner: owner)
        let contextID = "snapshot-context"
        let issuerID = try issuer.did()

        _ = try await cell.set(
            keypath: "trustedIssuers.policy.upsert",
            value: .object([
                "contextId": .string(contextID),
                "threshold": .float(0.5),
                "maximumCredentialAgeSeconds": .float(86_400),
                "requireIndependentSources": .integer(0)
            ]),
            requester: owner
        )
        _ = try await cell.set(
            keypath: "trustedIssuers.issuer.upsert",
            value: .object([
                "issuerId": .string(issuerID),
                "contexts": .list([.string(contextID)]),
                "status": .string("active")
            ]),
            requester: owner
        )

        let result = try await cell.set(
            keypath: "trustedIssuers.evaluate",
            value: .object([
                "evaluationId": .string("canonical-hash"),
                "issuerId": .string(issuerID),
                "contextId": .string(contextID)
            ]),
            requester: owner
        )
        guard let result,
              case let .object(record) = result,
              case let .string(snapshotHash)? = record["snapshotHash"] else {
            return XCTFail("Expected evaluation snapshot hash")
        }
        XCTAssertEqual(snapshotHash.count, 64)
        XCTAssertTrue(snapshotHash.allSatisfy { "0123456789abcdef".contains($0) })

        var canonicalRecord = record
        canonicalRecord["snapshotHash"] = nil
        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys]
        let expectedHash = FlowHasher.sha256Hex(try canonicalEncoder.encode(canonicalRecord))
        XCTAssertEqual(snapshotHash, expectedHash)

        let oversized = String(repeating: "x", count: 513)
        for payload: Object in [
            [
                "evaluationId": .string(oversized),
                "issuerId": .string(issuerID),
                "contextId": .string(contextID)
            ],
            [
                "evaluationId": .string("oversized-issuer"),
                "issuerId": .string(oversized),
                "contextId": .string(contextID)
            ],
            [
                "evaluationId": .string("oversized-context"),
                "issuerId": .string(issuerID),
                "contextId": .string(oversized)
            ]
        ] {
            let rejected = try await cell.set(
                keypath: "trustedIssuers.evaluate",
                value: .object(payload),
                requester: owner
            )
            guard case let .string(error) = rejected else {
                return XCTFail("Expected oversized identifier rejection")
            }
            XCTAssertTrue(error.contains("at most 512 UTF-8 bytes"))
        }

        let oversizedConfigurationWrites: [(String, Object)] = [
            (
                "trustedIssuers.policy.upsert",
                [
                    "contextId": .string(oversized),
                    "maximumCredentialAgeSeconds": .float(86_400)
                ]
            ),
            (
                "trustedIssuers.policy.delete",
                ["contextId": .string(oversized)]
            ),
            (
                "trustedIssuers.issuer.upsert",
                [
                    "issuerId": .string(oversized),
                    "contexts": .list([.string(contextID)])
                ]
            ),
            (
                "trustedIssuers.issuer.delete",
                ["issuerId": .string(oversized)]
            ),
            (
                "trustedIssuers.attestation.publish",
                [
                    "attestationId": .string(oversized),
                    "subjectIssuerId": .string(issuerID),
                    "contextId": .string(contextID)
                ]
            ),
            (
                "trustedIssuers.attestation.revoke",
                ["attestationId": .string(oversized)]
            )
        ]
        for (keypath, payload) in oversizedConfigurationWrites {
            let rejected = try await cell.set(
                keypath: keypath,
                value: .object(payload),
                requester: owner
            )
            guard case let .string(error) = rejected else {
                return XCTFail("Expected oversized configuration identifier rejection at \(keypath)")
            }
            XCTAssertTrue(error.contains("at most 512 UTF-8 bytes"))
        }
        let missingContexts = try await cell.set(
            keypath: "trustedIssuers.issuer.upsert",
            value: .object([
                "issuerId": .string("did:key:missing-contexts"),
                "status": .string("active")
            ]),
            requester: owner
        )
        XCTAssertEqual(
            missingContexts,
            .string("error: an active issuer must declare at least one allowed context")
        )
        let mixedContexts = try await cell.set(
            keypath: "trustedIssuers.issuer.upsert",
            value: .object([
                "issuerId": .string("did:key:mixed-contexts"),
                "contexts": .list([.string(contextID), .integer(1)]),
                "status": .string("active")
            ]),
            requester: owner
        )
        XCTAssertEqual(
            mixedContexts,
            .string("error: issuer contexts must be non-empty and each fit the identifier limit")
        )
        let nonFinitePolicyInteger = try await cell.set(
            keypath: "trustedIssuers.policy.upsert",
            value: .object([
                "contextId": .string("non-finite-policy"),
                "maximumCredentialAgeSeconds": .float(86_400),
                "requireIndependentSources": .float(.nan)
            ]),
            requester: owner
        )
        XCTAssertEqual(
            nonFinitePolicyInteger,
            .string("error: requireIndependentSources must be a non-negative integer")
        )

        let oversizedCandidate = try await cell.set(
            keypath: "trustedIssuers.evaluate",
            value: .object([
                "evaluationId": .string("oversized-candidate"),
                "issuerId": .string(issuerID),
                "contextId": .string(contextID),
                "candidateVc": .object([
                    "padding": .string(String(repeating: "v", count: 1_048_577))
                ])
            ]),
            requester: owner
        )
        guard let oversizedCandidate,
              case let .object(oversizedCandidateRecord) = oversizedCandidate,
              case let .list(oversizedCandidateReasons)? = oversizedCandidateRecord["reasons"] else {
            return XCTFail("Expected oversized candidate rejection record")
        }
        XCTAssertEqual(oversizedCandidateRecord["decision"], .string("untrusted"))
        XCTAssertTrue(oversizedCandidateReasons.contains(.string("candidate_vc_too_large")))

        let finalState = try await cell.get(
            keypath: "trustedIssuers.state",
            requester: owner
        )
        guard case let .object(finalObject) = finalState else {
            return XCTFail("Expected final TrustedIssuer state")
        }
        XCTAssertEqual(finalObject["evaluationHistoryCount"], .integer(2))
        XCTAssertEqual(finalObject["evaluationCurrentCount"], .integer(1))
    }

    func testProvedClaimConditionUsesTrustedIssuerEvaluation() async throws {
        CellBase.debugValidateAccessForEverything = false
        CellBase.exploreContractEnforcementMode = .strict

        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver

        let issuerVault = Curve25519TestIdentityVault()
        CellBase.defaultIdentityVault = issuerVault
        let issuerIdentity = await issuerVault.makeIdentity(displayName: "issuer")
        let requesterIdentity = await issuerVault.identity(for: "requester", makeNewIfNotFound: true)
        let targetOwnerIdentity = await issuerVault.identity(for: "target-owner", makeNewIfNotFound: true)
        let registryOwnerIdentity = await issuerVault.identity(for: "registry-owner", makeNewIfNotFound: true)
        let requester = try XCTUnwrap(requesterIdentity)
        let targetOwner = try XCTUnwrap(targetOwnerIdentity)
        let registryOwner = try XCTUnwrap(registryOwnerIdentity)
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

        let trustedIssuerCell = await TrustedIssuerCell(owner: registryOwner)
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
            requester: registryOwner
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
            requester: registryOwner
        )

        let target = await GeneralCell(owner: targetOwner)
        let condition = ProvedClaimCondition(
            name: "age_over_13",
            statement: "identity.claims.ageProof >= 13",
            requiredCredentialType: "AgeCredential",
            subjectClaimPath: "age"
        )
        target.agreementTemplate.conditions = [condition]
        target.agreementTemplate.grants = [Grant(keypath: "member.state", permission: "r---")]
        target.agreementAdmissionPolicy = .automaticWhenConditionsMet
        let agreementRequest = Agreement(owner: targetOwner)
        agreementRequest.conditions = [condition]
        agreementRequest.grants = [Grant(keypath: "member.state", permission: "r---")]

        let state = await target.addAgreement(agreementRequest, for: requester)
        XCTAssertEqual(
            state,
            .signed,
            "A cryptographically valid trusted credential must remain evaluable inside Agreement admission."
        )
        let stateAfterAdmission = try await trustedIssuerCell.get(
            keypath: "trustedIssuers.state",
            requester: registryOwner
        )
        guard case .object(let postAdmissionObject) = stateAfterAdmission else {
            return XCTFail("Expected trusted issuer state immediately after admission")
        }
        XCTAssertEqual(postAdmissionObject["evaluationHistoryCount"], .integer(1))
        let requesterCanRead = await target.validateAccess(
            "r---",
            at: "member.state",
            for: requester
        )
        XCTAssertTrue(requesterCanRead)

        let outsiderIdentity = await issuerVault.identity(
            for: "proof-bearing-outsider",
            makeNewIfNotFound: true
        )
        let outsider = try XCTUnwrap(outsiderIdentity)
        let rootDecision = await trustedIssuerCell.authorizationDecision(
            requestedAccess: "-w--",
            at: "trustedIssuers",
            for: outsider
        )
        let evaluateDecision = await trustedIssuerCell.authorizationDecision(
            requestedAccess: "-w--",
            at: "trustedIssuers.evaluate",
            for: outsider
        )
        XCTAssertTrue(rootDecision.allowed)
        XCTAssertEqual(rootDecision.path, .cellSpecific)
        XCTAssertTrue(evaluateDecision.allowed)
        XCTAssertEqual(evaluateDecision.path, .cellSpecific)
        let readRootDecision = await trustedIssuerCell.authorizationDecision(
            requestedAccess: "r---",
            at: "trustedIssuers",
            for: outsider
        )
        let broadRootDecision = await trustedIssuerCell.authorizationDecision(
            requestedAccess: "rw--",
            at: "trustedIssuers",
            for: outsider
        )
        let childDecision = await trustedIssuerCell.authorizationDecision(
            requestedAccess: "-w--",
            at: "trustedIssuers.evaluate.child",
            for: outsider
        )
        XCTAssertFalse(readRootDecision.allowed)
        XCTAssertFalse(broadRootDecision.allowed)
        XCTAssertFalse(childDecision.allowed)

        let publicOutsider = try JSONDecoder().decode(
            Identity.self,
            from: JSONEncoder().encode(outsider)
        )
        let publicRootDecision = await trustedIssuerCell.authorizationDecision(
            requestedAccess: "-w--",
            at: "trustedIssuers",
            for: publicOutsider
        )
        let publicEvaluateDecision = await trustedIssuerCell.authorizationDecision(
            requestedAccess: "-w--",
            at: "trustedIssuers.evaluate",
            for: publicOutsider
        )
        XCTAssertFalse(publicRootDecision.allowed)
        XCTAssertFalse(publicEvaluateDecision.allowed)
        do {
            _ = try await trustedIssuerCell.set(
                keypath: "trustedIssuers.evaluate",
                value: .object(["contextId": .string("age_over_13")]),
                requester: publicOutsider
            )
            XCTFail("A public identity descriptor without signing-key control must not invoke evaluation")
        } catch CellAuthorizationError.denied {
            // Expected.
        }

        let adminKeypaths = [
            "trustedIssuers.policy.upsert",
            "trustedIssuers.policy.delete",
            "trustedIssuers.issuer.upsert",
            "trustedIssuers.issuer.delete",
            "trustedIssuers.attestation.publish",
            "trustedIssuers.attestation.revoke"
        ]
        for keypath in adminKeypaths {
            let exactDecision = await trustedIssuerCell.authorizationDecision(
                requestedAccess: "-w--",
                at: keypath,
                for: outsider
            )
            XCTAssertFalse(exactDecision.allowed, "Unexpected cell-specific admin grant at \(keypath)")
            let result = try await trustedIssuerCell.set(
                keypath: keypath,
                value: .object(["forged": .bool(true)]),
                requester: outsider
            )
            XCTAssertEqual(result, .string("denied"), "Unexpected admin mutation result at \(keypath)")
        }

        let stateAfterDeniedMutations = try await trustedIssuerCell.get(
            keypath: "trustedIssuers.state",
            requester: registryOwner
        )
        guard case .object(let stateObject) = stateAfterDeniedMutations else {
            return XCTFail("Expected trusted issuer state after denied mutation attempts")
        }
        XCTAssertEqual(stateObject["policyCount"], .integer(1))
        XCTAssertEqual(stateObject["issuerCount"], .integer(1))
        XCTAssertEqual(stateObject["attestationCount"], .integer(0))
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
        CellBase.exploreContractEnforcementMode = .strict
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
