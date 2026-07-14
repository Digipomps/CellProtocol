// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@_spi(HAVENRuntime) @testable import CellBase

final class GeneralCellInterfaceTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousResolver: CellResolverProtocol?
    private var previousDebugFlag: Bool = false
    private var previousExploreEnforcementMode: CellBase.ExploreContractEnforcementMode = .permissive

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousResolver = CellBase.defaultCellResolver
        previousDebugFlag = CellBase.debugValidateAccessForEverything
        previousExploreEnforcementMode = CellBase.exploreContractEnforcementMode
        CellBase.debugValidateAccessForEverything = false
        CellBase.exploreContractEnforcementMode = .permissive
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.defaultCellResolver = previousResolver
        CellBase.debugValidateAccessForEverything = previousDebugFlag
        CellBase.exploreContractEnforcementMode = previousExploreEnforcementMode
        super.tearDown()
    }

    func testGetInterceptReturnsValue() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.addInterceptForGet(requester: owner, key: "echo") { _, _ in
            return .string("ok")
        }

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "echo",
            requester: owner,
            expectedMethod: .get,
            expectedInputType: "null",
            expectedReturnType: "unknown"
        )
        try await CellContractHarness.assertDescription(
            on: cell,
            key: "echo",
            requester: owner,
            expected: .string("*")
        )
        try await CellContractHarness.assertGet(
            on: cell,
            key: "echo",
            requester: owner,
            expectedValue: .string("ok")
        )
    }

    func testOwnerLookupReturnsPublicDescriptorWithoutAuthority() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let requester = await vault.identity(for: "requester", makeNewIfNotFound: true)!
        owner.properties = ["private": .string("must-not-leak")]
        let cell = await GeneralCell(owner: owner)

        let exposed = try await cell.getOwner(requester: requester)

        XCTAssertEqual(exposed.uuid, owner.uuid)
        XCTAssertEqual(exposed.signingPublicKeyFingerprint, owner.signingPublicKeyFingerprint)
        XCTAssertNil(exposed.identityVault)
        XCTAssertNil(exposed.homeVaultReference)
        XCTAssertNil(exposed.properties)
        XCTAssertTrue(exposed.grants.isEmpty)
        XCTAssertFalse(exposed.publicSecureKey?.privateKey ?? true)
        let ownerControlVerified = await cell.verifyRequesterIdentityControl(owner)
        XCTAssertTrue(ownerControlVerified)

        let forged = Identity(owner.uuid, displayName: "forged", identityVault: requester.identityVault)
        forged.publicSecureKey = requester.publicSecureKey
        forged.homeVaultReference = requester.homeVaultReference
        let forgedControlVerified = await cell.verifyRequesterIdentityControl(forged)
        XCTAssertFalse(forgedControlVerified)
    }

    func testSetInterceptRegistersSchemaAndReturnsValue() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.addInterceptForSet(requester: owner, key: "echo") { _, _, _ in
            return .string("set-ok")
        }

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "echo",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "unknown",
            expectedReturnType: "unknown"
        )
        try await CellContractHarness.assertDescription(
            on: cell,
            key: "echo",
            requester: owner,
            expected: .string("*")
        )
        try await CellContractHarness.assertSet(
            on: cell,
            key: "echo",
            input: .string("hi"),
            requester: owner,
            expectedResponse: .string("set-ok")
        )
    }

    func testNonOwnerDeniedWithoutContract() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let other = await vault.identity(for: "other", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.addInterceptForGet(requester: owner, key: "secret") { _, _ in
            return .string("nope")
        }

        do {
            _ = try await cell.get(keypath: "secret", requester: other)
            XCTFail("Expected denied error")
        } catch let error as CellAuthorizationError {
            guard case .denied(let decision) = error else {
                XCTFail("Expected denied authorization error, got \(error)")
                return
            }
            XCTAssertEqual(decision.reasonCode, "agreement_or_proof_required")
        } catch {
            XCTAssertTrue(error is GeneralCell.KeyValueErrors)
        }
    }

    func testNonOwnerAllowedWithSignedContract() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let other = await vault.identity(for: "other", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.addInterceptForGet(requester: owner, key: "shared") { _, _ in
            return .string("shared-ok")
        }
        cell.agreementTemplate.addGrant("r---", for: "shared")

        let agreement = Agreement(owner: owner)
        agreement.addGrant("r---", for: "shared")
        agreement.signatories.append(other)

        let state = await cell.addAgreement(agreement, for: other, authorizedBy: owner)
        XCTAssertEqual(state, .signed)

        let value = try await cell.get(keypath: "shared", requester: other)
        XCTAssertEqual(value, .string("shared-ok"))
    }

    func testRequesterCannotEscalateAgreementBeyondCellTemplate() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let requester = await vault.identity(for: "requester", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        cell.agreementTemplate.addGrant("r---", for: "published.state")

        let attackerSuppliedAgreement = Agreement(owner: owner)
        attackerSuppliedAgreement.addGrant("rwxs", for: "private.admin")

        let state = await cell.addAgreement(attackerSuppliedAgreement, for: requester)
        let attackerCanAdminister = await cell.validateAccess(
            "rwxs",
            at: "private.admin",
            for: requester
        )

        XCTAssertEqual(state, .rejected)
        XCTAssertFalse(
            attackerCanAdminister,
            "A requester must never mint authority outside the Cell owner's current Agreement template."
        )
    }

    func testRequesterCannotEscalatePermissionOnPublishedTemplateKey() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let requester = await vault.identity(for: "requester", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        cell.agreementTemplate.addGrant("r---", for: "published.state")
        cell.agreementAdmissionPolicy = .ownerPublishedRead

        let request = Agreement(owner: owner)
        request.addGrant("rwxs", for: "published.state")

        let state = await cell.addAgreement(request, for: requester)
        let requesterCanEscalate = await cell.validateAccess("rwxs", at: "published.state", for: requester)

        XCTAssertEqual(state, .rejected)
        XCTAssertFalse(requesterCanEscalate)
    }

    func testOwnerPublishedReadRejectsLatentOtherPermissionBits() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let requester = await vault.identity(for: "requester", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        cell.agreementAdmissionPolicy = .ownerPublishedRead
        cell.agreementTemplate.conditions = []
        cell.agreementTemplate.grants = [Grant(keypath: "published.state", permission: "r---rwxs")]

        let request = Agreement(owner: owner)
        request.conditions = []
        request.grants = [Grant(keypath: "published.state", permission: "r---rwxs")]

        let state = await cell.addAgreement(request, for: requester)

        XCTAssertEqual(state, .rejected)
    }

    func testDefaultAdmissionPolicyRejectsConditionlessAutomaticWriteContract() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let requester = await vault.identity(for: "requester", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        cell.agreementTemplate.conditions = []
        cell.agreementTemplate.grants = []
        cell.agreementTemplate.addGrant("rw--", for: "state")

        let request = Agreement(owner: owner)
        request.conditions = []
        request.grants = []
        request.addGrant("rw--", for: "state")

        let state = await cell.addAgreement(request, for: requester)
        let requesterCanWrite = await cell.validateAccess("rw--", at: "state", for: requester)

        XCTAssertEqual(state, .rejected)
        XCTAssertFalse(requesterCanWrite)
    }

    func testAutomaticAdmissionRequiresPredicateBoundProvedClaim() async throws {
        let vault = MockIdentityVault()
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let generic = ProvedClaimCondition(
            name: "generic trusted credential",
            statement: "identity.claims.admin = true"
        )
        let bound = ProvedClaimCondition(
            name: "bound admin credential",
            statement: "identity.claims.admin = true",
            requiredCredentialType: "AdminCredential",
            subjectClaimPath: "admin"
        )

        XCTAssertFalse(cell.isAuthorizationEnforcingCondition(generic))
        XCTAssertTrue(cell.isAuthorizationEnforcingCondition(bound))
    }

    func testExplicitOwnerPublishedReadPolicyAllowsOnlyTemplateBoundRead() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let requester = await vault.identity(for: "requester", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        cell.agreementAdmissionPolicy = .ownerPublishedRead
        cell.agreementTemplate.conditions = []
        cell.agreementTemplate.grants = []
        cell.agreementTemplate.addGrant("r---", for: "published.state")

        let request = Agreement(owner: owner)
        request.conditions = []
        request.grants = []
        request.addGrant("r---", for: "published.state")

        let state = await cell.addAgreement(request, for: requester)
        let requesterCanRead = await cell.validateAccess("r---", at: "published.state", for: requester)

        XCTAssertEqual(state, .signed)
        XCTAssertTrue(requesterCanRead)
    }

    func testCurrentAgreementTemplateRevokesPreviouslyIssuedGrant() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let requester = await vault.identity(for: "requester", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        cell.agreementTemplate.addGrant("r---", for: "shared")

        let request = Agreement(owner: owner)
        request.addGrant("r---", for: "shared")
        let state = await cell.addAgreement(request, for: requester, authorizedBy: owner)
        XCTAssertEqual(state, .signed)
        let requesterCanReadBeforeRevocation = await cell.validateAccess("r---", at: "shared", for: requester)
        XCTAssertTrue(requesterCanReadBeforeRevocation)

        cell.agreementTemplate.grants.removeAll { $0.keypath == "shared" }

        let requesterCanReadAfterRevocation = await cell.validateAccess("r---", at: "shared", for: requester)
        XCTAssertFalse(requesterCanReadAfterRevocation)
        let admissionAfterRevocation = await cell.admit(
            context: ConnectContext(source: nil, target: cell, identity: requester)
        )
        XCTAssertEqual(admissionAfterRevocation, .signContract)
        let encoded = try JSONEncoder().encode(cell)
        let restored = try JSONDecoder().decode(GeneralCell.self, from: encoded)
        let restoredAdmission = await restored.admit(
            context: ConnectContext(source: nil, target: restored, identity: requester)
        )
        XCTAssertEqual(restoredAdmission, .signContract)
    }

    func testAgreementRequestCannotOutliveCurrentTemplate() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let requester = await vault.identity(for: "requester", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        cell.agreementTemplate.duration = 60
        cell.agreementTemplate.addGrant("r---", for: "shared")

        let request = Agreement(owner: owner)
        request.duration = 61
        request.addGrant("r---", for: "shared")

        let state = await cell.addAgreement(request, for: requester, authorizedBy: owner)
        XCTAssertEqual(state, .rejected)
    }

    func testConcurrentRepeatedAgreementIssuanceIsIdempotent() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let requester = await vault.identity(for: "requester", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        cell.agreementTemplate.addGrant("r---", for: "shared")

        let states = await withTaskGroup(of: AgreementState.self, returning: [AgreementState].self) { group in
            for _ in 0..<40 {
                group.addTask {
                    let request = Agreement(owner: owner)
                    request.addGrant("r---", for: "shared")
                    return await cell.addAgreement(request, for: requester, authorizedBy: owner)
                }
            }
            var values: [AgreementState] = []
            for await state in group {
                values.append(state)
            }
            return values
        }

        XCTAssertEqual(states.count, 40)
        XCTAssertTrue(states.allSatisfy { $0 == .signed })
        let encoded = try JSONEncoder().encode(cell)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let contracts = try XCTUnwrap(object["contracts"] as? [[String: Any]])
        XCTAssertEqual(contracts.count, 1)
    }

    func testSequentialAttachRequestsDoNotMutatePublishedAgreementTemplate() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let first = await vault.identity(for: "first", makeNewIfNotFound: true)!
        let second = await vault.identity(for: "second", makeNewIfNotFound: true)!
        let source = await GeneralCell(owner: first)
        let published = await GeneralCell(owner: owner)
        published.agreementAdmissionPolicy = .ownerPublishedRead
        published.agreementTemplate.conditions = []
        published.agreementTemplate.grants = []
        published.agreementTemplate.addGrant("r---", for: "published.state")
        source.agreementTemplate.addGrant("-w--", for: "second")
        let sourceWriteRequest = Agreement(owner: first)
        sourceWriteRequest.addGrant("-w--", for: "second")
        let sourceWriteState = await source.addAgreement(
            sourceWriteRequest,
            for: second,
            authorizedBy: first
        )
        XCTAssertEqual(sourceWriteState, .signed)

        let firstState = try await source.attach(emitter: published, label: "first", requester: first)
        let secondState = try await source.attach(emitter: published, label: "second", requester: second)

        XCTAssertEqual(firstState, .connected)
        XCTAssertEqual(secondState, .connected)
        XCTAssertEqual(published.agreementTemplate.state, .template)
        XCTAssertEqual(published.agreementTemplate.signatories.count, 1)
        XCTAssertEqual(published.agreementTemplate.signatories.first, owner)
        let firstCanRead = await published.validateAccess("r---", at: "published.state", for: first)
        let secondCanRead = await published.validateAccess("r---", at: "published.state", for: second)
        XCTAssertTrue(firstCanRead)
        XCTAssertTrue(secondCanRead)
    }

    func testRemovingMemberRevokesContractsAcrossRestart() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let requester = await vault.identity(for: "requester", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        cell.agreementTemplate.addGrant("r---", for: "shared")

        let request = Agreement(owner: owner)
        request.addGrant("r---", for: "shared")
        let state = await cell.addAgreement(request, for: requester, authorizedBy: owner)
        XCTAssertEqual(state, .signed)

        await cell.removeMember(member: requester, requester: owner)

        let canRead = await cell.validateAccess("r---", at: "shared", for: requester)
        let admission = await cell.admit(
            context: ConnectContext(source: nil, target: cell, identity: requester)
        )
        XCTAssertFalse(canRead)
        XCTAssertEqual(admission, .signContract)

        let restored = try JSONDecoder().decode(
            GeneralCell.self,
            from: JSONEncoder().encode(cell)
        )
        let restoredCanRead = await restored.validateAccess("r---", at: "shared", for: requester)
        let restoredAdmission = await restored.admit(
            context: ConnectContext(source: nil, target: restored, identity: requester)
        )
        XCTAssertFalse(restoredCanRead)
        XCTAssertEqual(restoredAdmission, .signContract)
    }

    func testFirstAgreementAfterRestartPreservesExistingAuthorizations() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let first = await vault.identity(for: "first", makeNewIfNotFound: true)!
        let second = await vault.identity(for: "second", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        cell.agreementTemplate.addGrant("r---", for: "shared")

        let firstRequest = Agreement(owner: owner)
        firstRequest.addGrant("r---", for: "shared")
        let firstState = await cell.addAgreement(firstRequest, for: first, authorizedBy: owner)
        XCTAssertEqual(firstState, .signed)
        let restored = try JSONDecoder().decode(
            GeneralCell.self,
            from: JSONEncoder().encode(cell)
        )

        let secondRequest = Agreement(owner: owner)
        secondRequest.addGrant("r---", for: "shared")
        let secondState = await restored.addAgreement(
            secondRequest,
            for: second,
            authorizedBy: owner
        )

        XCTAssertEqual(secondState, .signed)
        let firstCanRead = await restored.validateAccess("r---", at: "shared", for: first)
        let secondCanRead = await restored.validateAccess("r---", at: "shared", for: second)
        XCTAssertTrue(firstCanRead)
        XCTAssertTrue(secondCanRead)
        let encoded = try JSONEncoder().encode(restored)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let contracts = try XCTUnwrap(object["contracts"] as? [[String: Any]])
        XCTAssertEqual(contracts.count, 2)
    }

    func testFirstRemovalAfterRestartPreservesOtherAuthorizations() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let first = await vault.identity(for: "first", makeNewIfNotFound: true)!
        let second = await vault.identity(for: "second", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        cell.agreementTemplate.addGrant("r---", for: "shared")

        for subject in [first, second] {
            let request = Agreement(owner: owner)
            request.addGrant("r---", for: "shared")
            let state = await cell.addAgreement(request, for: subject, authorizedBy: owner)
            XCTAssertEqual(state, .signed)
        }
        let restored = try JSONDecoder().decode(
            GeneralCell.self,
            from: JSONEncoder().encode(cell)
        )

        await restored.removeMember(member: first, requester: owner)

        let firstCanRead = await restored.validateAccess("r---", at: "shared", for: first)
        let secondCanRead = await restored.validateAccess("r---", at: "shared", for: second)
        XCTAssertFalse(firstCanRead)
        XCTAssertTrue(secondCanRead)
        let encoded = try JSONEncoder().encode(restored)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let contracts = try XCTUnwrap(object["contracts"] as? [[String: Any]])
        XCTAssertEqual(contracts.count, 1)
    }

    func testConcurrentFirstRemovalAndAdditionAfterRestartDoNotResurrectRevokedContract() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let first = await vault.identity(for: "first", makeNewIfNotFound: true)!
        let second = await vault.identity(for: "second", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        cell.agreementTemplate.addGrant("r---", for: "shared")
        let firstRequest = Agreement(owner: owner)
        firstRequest.addGrant("r---", for: "shared")
        let firstState = await cell.addAgreement(firstRequest, for: first, authorizedBy: owner)
        XCTAssertEqual(firstState, .signed)

        let restored = try JSONDecoder().decode(
            GeneralCell.self,
            from: JSONEncoder().encode(cell)
        )
        let secondRequest = Agreement(owner: owner)
        secondRequest.addGrant("r---", for: "shared")

        async let removal: Void = restored.removeMember(member: first, requester: owner)
        async let addition = restored.addAgreement(secondRequest, for: second, authorizedBy: owner)
        _ = await removal
        let secondState = await addition

        XCTAssertEqual(secondState, .signed)
        let firstCanRead = await restored.validateAccess("r---", at: "shared", for: first)
        let secondCanRead = await restored.validateAccess("r---", at: "shared", for: second)
        XCTAssertFalse(firstCanRead)
        XCTAssertTrue(secondCanRead)
        let encoded = try JSONEncoder().encode(restored)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let contracts = try XCTUnwrap(object["contracts"] as? [[String: Any]])
        XCTAssertEqual(contracts.count, 1)
    }

    func testStoragePermissionRequiresExplicitIdentityBoundSGrant() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let reader = await vault.identity(for: "reader", makeNewIfNotFound: true)!
        let storer = await vault.identity(for: "storer", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        cell.agreementTemplate.addGrant("r--s", for: "shared")

        let readAgreement = Agreement(owner: owner)
        readAgreement.addGrant("r---", for: "shared")
        readAgreement.signatories.append(reader)
        let readAgreementState = await cell.addAgreement(readAgreement, for: reader, authorizedBy: owner)
        XCTAssertEqual(readAgreementState, .signed)

        let storageAgreement = Agreement(owner: owner)
        storageAgreement.addGrant("r--s", for: "shared")
        storageAgreement.signatories.append(storer)
        let storageAgreementState = await cell.addAgreement(storageAgreement, for: storer, authorizedBy: owner)
        XCTAssertEqual(storageAgreementState, .signed)

        let readerCanRead = await cell.validateAccess("r---", at: "shared", for: reader)
        let readerCanStore = await cell.validateAccess("---s", at: "shared", for: reader)
        let storerCanRead = await cell.validateAccess("r---", at: "shared", for: storer)
        let storerCanStore = await cell.validateAccess("---s", at: "shared", for: storer)

        XCTAssertTrue(readerCanRead)
        XCTAssertFalse(
            readerCanStore,
            "Read authority must not imply permission to retain output."
        )
        XCTAssertTrue(storerCanRead)
        XCTAssertTrue(storerCanStore)
    }

    func testPersistedOwnerProofUsesStoredPublicKeyNotUUID() async throws {
        let ownerVault = MockIdentityVault()
        CellBase.defaultIdentityVault = ownerVault
        let owner = await ownerVault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let encodedCell = try JSONEncoder().encode(cell)

        let restoredVault = MockIdentityVault()
        CellBase.defaultIdentityVault = restoredVault
        let restoredCell = try JSONDecoder().decode(GeneralCell.self, from: encodedCell)

        let forgedVault = MockIdentityVault()
        var forgedOwner = Identity(owner.uuid, displayName: "forged-owner", identityVault: forgedVault)
        await forgedVault.addIdentity(identity: &forgedOwner, for: "forged-owner")

        let ownerCanRead = await restoredCell.validateAccess("r---", at: "state", for: owner)
        XCTAssertTrue(
            ownerCanRead,
            "The real owner should still prove control after the cell is decoded with a fresh default vault."
        )
        let ownerAdmission = await restoredCell.admit(context: ConnectContext(source: nil, target: restoredCell, identity: owner))
        XCTAssertEqual(
            ownerAdmission,
            .connected
        )
        let forgedOwnerCanRead = await restoredCell.validateAccess("r---", at: "state", for: forgedOwner)
        XCTAssertFalse(
            forgedOwnerCanRead,
            "Same UUID with a different signing key must never authenticate as owner."
        )
        let forgedOwnerDecision = await restoredCell.authorizationDecision(
            requestedAccess: "r---",
            at: "state",
            for: forgedOwner
        )
        XCTAssertFalse(forgedOwnerDecision.allowed)
        XCTAssertEqual(forgedOwnerDecision.path, .deniedIdentityReferenceMismatch)
        XCTAssertEqual(forgedOwnerDecision.reasonCode, "identity_public_key_mismatch")
        XCTAssertEqual(forgedOwnerDecision.requiredAction, "restore_owner_identity_or_link_scaffold")
        let forgedOwnerAdmission = await restoredCell.admit(context: ConnectContext(source: nil, target: restoredCell, identity: forgedOwner))
        XCTAssertEqual(
            forgedOwnerAdmission,
            .signContract
        )
    }

    func testUninitializedInterceptSetupRejectsForgedOwnerUUID() async throws {
        let ownerVault = MockIdentityVault()
        CellBase.defaultIdentityVault = ownerVault
        let owner = await ownerVault.identity(for: "private", makeNewIfNotFound: true)!

        let forgedVault = MockIdentityVault()
        var forgedOwner = Identity(owner.uuid, displayName: "forged-owner", identityVault: forgedVault)
        await forgedVault.addIdentity(identity: &forgedOwner, for: "forged-owner")

        let cell = await GeneralCell(owner: owner)
        await cell.addInterceptForGet(requester: forgedOwner, key: "pwned") { _, _ in
            .string("forged")
        }
        await cell.addInterceptForGet(requester: owner, key: "safe") { _, _ in
            .string("owner")
        }

        let keys = try await cell.keys(requester: owner)
        XCTAssertFalse(keys.contains("pwned"))
        XCTAssertTrue(keys.contains("safe"))
    }

    func testVaultRefusesToSignWhenPresentedIdentityKeyDiffersFromStoredKey() async throws {
        let ownerVault = MockIdentityVault()
        CellBase.defaultIdentityVault = ownerVault
        let owner = await ownerVault.identity(for: "private", makeNewIfNotFound: true)!

        let forgedVault = MockIdentityVault()
        var forgedOwner = Identity(owner.uuid, displayName: "forged-owner", identityVault: forgedVault)
        await forgedVault.addIdentity(identity: &forgedOwner, for: "forged-owner")
        forgedOwner.identityVault = ownerVault

        let challenge = try IdentitySigningChallenge.signingData(
            for: forgedOwner,
            trustedIdentity: owner,
            domain: "private",
            resource: "test-cell",
            action: "checkIdentityOrigin",
            audience: "GeneralCellInterfaceTests",
            nonce: Data("nonce".utf8)
        )

        do {
            _ = try await ownerVault.signMessageForIdentity(messageData: challenge, identity: forgedOwner)
            XCTFail("A vault must not sign with a stored private key for a presented Identity carrying a different public key.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("publicKeyMismatch"))
        }
    }

    func testVaultRefusesToSignWhenPresentedIdentityKeyIsMissing() async throws {
        let ownerVault = MockIdentityVault()
        CellBase.defaultIdentityVault = ownerVault
        let owner = await ownerVault.identity(for: "private", makeNewIfNotFound: true)!
        let strippedOwner = Identity(owner.uuid, displayName: "stripped-owner", identityVault: ownerVault)

        let challenge = try IdentitySigningChallenge.signingData(
            for: strippedOwner,
            trustedIdentity: owner,
            domain: "private",
            resource: "test-cell",
            action: "checkIdentityOrigin",
            audience: "GeneralCellInterfaceTests",
            nonce: Data("nonce".utf8)
        )

        do {
            _ = try await ownerVault.signMessageForIdentity(messageData: challenge, identity: strippedOwner)
            XCTFail("A vault must not sign for a presented Identity that lacks the stored public signing key.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("publicKeyMismatch"))
        }
    }

    func testSignedContractAccessUsesStoredSignatoryPublicKeyNotUUID() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let member = await vault.identity(for: "member", makeNewIfNotFound: true)!

        let forgedVault = MockIdentityVault()
        var forgedMember = Identity(member.uuid, displayName: "forged-member", identityVault: forgedVault)
        await forgedVault.addIdentity(identity: &forgedMember, for: "forged-member")

        let cell = await GeneralCell(owner: owner)
        await cell.addInterceptForGet(requester: owner, key: "shared") { _, _ in
            .string("shared-ok")
        }
        cell.agreementTemplate.addGrant("r---", for: "shared")

        let agreement = Agreement(owner: owner)
        agreement.addGrant("r---", for: "shared")
        agreement.signatories.append(member)

        let state = await cell.addAgreement(agreement, for: member, authorizedBy: owner)
        XCTAssertEqual(state, .signed)

        let memberCanRead = await cell.validateAccess("r---", at: "shared", for: member)
        XCTAssertTrue(memberCanRead)
        let forgedMemberCanRead = await cell.validateAccess("r---", at: "shared", for: forgedMember)
        XCTAssertFalse(
            forgedMemberCanRead,
            "Contract membership must be proven against the persisted signatory public key, not UUID equality."
        )
        let memberAdmission = await cell.admit(context: ConnectContext(source: nil, target: cell, identity: member))
        XCTAssertEqual(
            memberAdmission,
            .connected
        )
        let forgedMemberAdmission = await cell.admit(context: ConnectContext(source: nil, target: cell, identity: forgedMember))
        XCTAssertEqual(
            forgedMemberAdmission,
            .signContract
        )

        let value = try await cell.get(keypath: "shared", requester: member)
        XCTAssertEqual(value, .string("shared-ok"))
        try await CellContractHarness.assertGetDenied(on: cell, key: "shared", requester: forgedMember)
    }

    func testSignedContractsPersistAcrossGeneralCellDecode() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let member = await vault.identity(for: "member", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        cell.agreementTemplate.addGrant("r---", for: "shared")

        let agreement = Agreement(owner: owner)
        agreement.addGrant("r---", for: "shared")
        agreement.signatories.append(member)

        let state = await cell.addAgreement(agreement, for: member, authorizedBy: owner)
        XCTAssertEqual(state, .signed)

        let encoded = try JSONEncoder().encode(cell)
        let restored = try JSONDecoder().decode(GeneralCell.self, from: encoded)
        CellBase.defaultIdentityVault = nil

        XCTAssertNil(restored.storedOwnerIdentity.identityVault)
        let memberCanRead = await restored.validateAccess("r---", at: "shared", for: member)
        XCTAssertTrue(memberCanRead)
    }

    func testResolverUsesCentralAuthorizationDecisionBeforeMeddle() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let resolver = CellResolver.sharedInstance
        CellBase.defaultCellResolver = resolver
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await AuthorizationSpyCell(owner: owner)
        let endpoint = "AuthSpy-\(UUID().uuidString)"

        await cell.addInterceptForGet(requester: owner, key: "state") { _, _ in
            .string("ok")
        }
        try await resolver.registerNamedEmitCell(
            name: endpoint,
            emitCell: cell,
            scope: .scaffoldUnique,
            identity: owner
        )
        defer {
            Task {
                await resolver.unregisterEmitCell(uuid: cell.uuid)
            }
        }

        let value = try await resolver.get(
            from: try XCTUnwrap(URL(string: "cell:///\(endpoint)/state")),
            requester: owner
        )

        XCTAssertEqual(value, .string("ok"))
        let authorizationDecisionCount = await cell.authorizationDecisionCount()
        XCTAssertGreaterThanOrEqual(
            authorizationDecisionCount,
            2,
            "Resolver should preflight through the same central authorization decision used by GeneralCell.get."
        )
    }

    func testCellSpecificAccessHookAllowsSubclassManagedReadWithoutContract() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let other = await vault.identity(for: "other", makeNewIfNotFound: true)!
        let outsider = await vault.identity(for: "outsider", makeNewIfNotFound: true)!
        let cell = await CellSpecificAccessHarnessCell(owner: owner)

        await cell.addInterceptForGet(requester: owner, key: "sharedByCell") { _, _ in
            .string("cell-specific-ok")
        }
        cell.allow(identity: other, access: "r---", keypath: "sharedByCell")

        let value = try await cell.get(keypath: "sharedByCell", requester: other)
        XCTAssertEqual(value, .string("cell-specific-ok"))
        let outsiderCanRead = await cell.validateAccess("r---", at: "sharedByCell", for: outsider)
        let otherCanWrite = await cell.validateAccess("rw--", at: "sharedByCell", for: other)
        XCTAssertFalse(outsiderCanRead)
        XCTAssertFalse(otherCanWrite)
    }

    func testExplicitSchemaRegistrationForGetAndSet() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.addInterceptForGet(requester: owner, key: "readOnly") { _, _ in
            .string("ok")
        }

        await cell.registerExploreSchema(
            requester: owner,
            key: "readOnly",
            schema: .object([
                "method": .string("get"),
                "returns": .string("String")
            ]),
            description: .string("Read-only key")
        )

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "readOnly",
            requester: owner,
            expectedMethod: .get,
            expectedInputType: "null",
            expectedReturnType: "string"
        )
        try await CellContractHarness.assertDescription(
            on: cell,
            key: "readOnly",
            requester: owner,
            expected: .string("Read-only key")
        )

        await cell.addInterceptForSet(requester: owner, key: "writeOnly") { _, _, _ in
            .string("set-ok")
        }
        await cell.registerExploreSchema(
            requester: owner,
            key: "writeOnly",
            schema: .object([
                "method": .string("set"),
                "payload": .string("Object")
            ]),
            description: .string("Write-only key")
        )

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "writeOnly",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "object",
            expectedReturnType: "unknown"
        )
        try await CellContractHarness.assertDescription(
            on: cell,
            key: "writeOnly",
            requester: owner,
            expected: .string("Write-only key")
        )
    }

    func testRegisterExploreContractSupportsFlowEffects() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.addInterceptForSet(requester: owner, key: "publish") { [weak cell] _, value, requester in
            let flowContent: FlowElementValueType
            switch value {
            case let .object(object):
                flowContent = .object(object)
            case let .string(string):
                flowContent = .string(string)
            case let .list(list):
                flowContent = .list(list)
            case let .bool(bool):
                flowContent = .bool(bool)
            case let .number(number):
                flowContent = .number(number)
            case let .integer(number):
                flowContent = .number(number)
            case let .float(number):
                flowContent = .number(Int(number))
            case let .data(data):
                flowContent = .data(data)
            default:
                flowContent = .object(["value": value])
            }
            var flowElement = FlowElement(
                id: UUID().uuidString,
                title: "publish",
                content: flowContent,
                properties: FlowElement.Properties(type: .event, contentType: .object)
            )
            flowElement.topic = "publish.completed"
            cell?.pushFlowElement(flowElement, requester: requester)
            return .object(["status": .string("ok")])
        }

        await cell.registerExploreContract(
            requester: owner,
            key: "publish",
            method: .set,
            input: ExploreContract.objectSchema(
                properties: [
                    "message": ExploreContract.schema(type: "string")
                ],
                requiredKeys: ["message"]
            ),
            returns: ExploreContract.objectSchema(
                properties: [
                    "status": ExploreContract.schema(type: "string")
                ],
                requiredKeys: ["status"]
            ),
            permissions: ["-w--"],
            required: true,
            flowEffects: [
                ExploreContract.flowEffect(
                    trigger: .set,
                    topic: "publish.completed",
                    contentType: "object",
                    minimumCount: 1
                )
            ],
            description: .string("Publishes a message and emits a completion flow element")
        )

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "publish",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "object",
            expectedReturnType: "object"
        )
        try await CellContractHarness.assertDescription(
            on: cell,
            key: "publish",
            requester: owner,
            expected: .string("Publishes a message and emits a completion flow element")
        )
        try await CellContractHarness.assertSetTriggersFlow(
            testCase: self,
            on: cell,
            key: "publish",
            input: .object(["message": .string("Hello")]),
            requester: owner,
            expectedTopic: "publish.completed",
            expectedResponse: .object(["status": .string("ok")])
        )
    }

    func testStrictModeRejectsImplicitSetRegistration() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.exploreContractEnforcementMode = .strict
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.addInterceptForSet(requester: owner, key: "strict.writeOnly") { _, _, _ in
            .string("should-not-register")
        }

        let keys = try await cell.keys(requester: owner)
        XCTAssertFalse(keys.contains("strict.writeOnly"))

        do {
            _ = try await cell.set(
                keypath: "strict.writeOnly",
                value: .string("hi"),
                requester: owner
            )
            XCTFail("Expected strict mode to reject implicit registration")
        } catch {
            XCTAssertTrue(error is GeneralCell.KeyValueErrors)
        }
    }

    func testStrictModeAllowsExplicitRegisterSetHelper() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.exploreContractEnforcementMode = .strict
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.registerSet(
            key: "strict.writeOnly",
            owner: owner,
            input: ExploreContract.schema(type: "string"),
            returns: ExploreContract.schema(type: "string"),
            permissions: ["-w--"],
            description: .string("Strictly registered write key")
        ) { _, payload in
            payload
        }

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "strict.writeOnly",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "string",
            expectedReturnType: "string"
        )
        try await CellContractHarness.assertDescription(
            on: cell,
            key: "strict.writeOnly",
            requester: owner,
            expected: .string("Strictly registered write key")
        )
        try await CellContractHarness.assertSet(
            on: cell,
            key: "strict.writeOnly",
            input: .string("hi"),
            requester: owner,
            expectedResponse: .string("hi")
        )
    }

    func testStrictModeRequiresContractForExactHandlerMethod() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.exploreContractEnforcementMode = .strict
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.registerExploreContract(
            requester: owner,
            key: "dual",
            method: .set,
            input: ExploreContract.schema(type: "string"),
            returns: ExploreContract.schema(type: "string")
        )
        await cell.addInterceptForGet(requester: owner, key: "dual") { _, _ in
            .string("must-not-install")
        }

        do {
            _ = try await cell.get(keypath: "dual", requester: owner)
            XCTFail("A SET contract must not authorize GET handler installation")
        } catch GeneralCell.KeyValueErrors.notFound {
        }

        await cell.registerExploreContract(
            requester: owner,
            key: "dual",
            method: .get,
            input: .null,
            returns: ExploreContract.schema(type: "string")
        )
        await cell.addInterceptForGet(requester: owner, key: "dual") { _, _ in
            .string("get-ok")
        }

        let getValue = try await cell.get(keypath: "dual", requester: owner)
        XCTAssertEqual(getValue, .string("get-ok"))
        let getContract = try await cell.contract(for: "dual", method: .get, requester: owner)
        let setContract = try await cell.contract(for: "dual", method: .set, requester: owner)
        XCTAssertEqual(
            ExploreContract.string(from: ExploreContract.object(from: getContract)?[ExploreContract.Field.method]),
            "get"
        )
        XCTAssertEqual(
            ExploreContract.string(from: ExploreContract.object(from: setContract)?[ExploreContract.Field.method]),
            "set"
        )

        // Legacy Explore remains last-registration-wins for compatibility.
        let legacy = try await cell.typeForKey(key: "dual", requester: owner)
        XCTAssertEqual(
            ExploreContract.string(from: ExploreContract.object(from: legacy)?[ExploreContract.Field.method]),
            "get"
        )

        let catalog = try await cell.exploreContractCatalog(requester: owner)
        let getRecord = try XCTUnwrap(catalog.records.first { $0.key == "dual" && $0.method == "get" })
        let setRecord = try XCTUnwrap(catalog.records.first { $0.key == "dual" && $0.method == "set" })
        XCTAssertEqual(getRecord.id, "GeneralCell#dual")
        XCTAssertEqual(setRecord.id, "GeneralCell#dual#set")
        XCTAssertTrue(getRecord.markdown.contains("## `dual` [GET]"))
        XCTAssertTrue(getRecord.markdown.contains("Method: `get`"))
        XCTAssertTrue(setRecord.markdown.contains("## `dual` [SET]"))
        XCTAssertTrue(catalog.markdown.contains("## `dual` [GET]"))
        XCTAssertTrue(catalog.markdown.contains("## `dual` [SET]"))
    }

    func testOperationCatalogRetainsLegacySchemaWithoutMethodMetadata() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.registerExploreSchema(
            requester: owner,
            key: "legacy",
            schema: .string("string"),
            description: .string("Legacy schema")
        )

        let catalog = try await cell.exploreContractCatalog(requester: owner)
        XCTAssertEqual(catalog.records.count, 1)
        XCTAssertEqual(catalog.records.first?.id, "GeneralCell#legacy")
        XCTAssertEqual(catalog.records.first?.key, "legacy")
        XCTAssertEqual(catalog.records.first?.contract, .string("string"))
    }

    func testStrictModeGetContractCannotAuthorizeSetHandler() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.exploreContractEnforcementMode = .strict
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.registerExploreContract(
            requester: owner,
            key: "read-only-contract",
            method: .get,
            input: .null,
            returns: ExploreContract.schema(type: "string")
        )
        await cell.addInterceptForSet(requester: owner, key: "read-only-contract") { _, _, _ in
            .string("must-not-install")
        }

        do {
            _ = try await cell.set(
                keypath: "read-only-contract",
                value: .string("no"),
                requester: owner
            )
            XCTFail("A GET contract must not authorize SET handler installation")
        } catch GeneralCell.KeyValueErrors.notFound {
        }
        let legacy = try await cell.typeForKey(key: "read-only-contract", requester: owner)
        XCTAssertEqual(
            ExploreContract.string(from: ExploreContract.object(from: legacy)?[ExploreContract.Field.method]),
            "get"
        )
    }

    func testPermissiveAndWarnHandlersRetainExplicitMethodlessLegacySchema() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!

        for mode in [CellBase.ExploreContractEnforcementMode.permissive, .warn] {
            CellBase.exploreContractEnforcementMode = mode
            let cell = await GeneralCell(owner: owner)
            let legacySchema: ValueType = .object([
                "returns": .string("string"),
                "customLegacyMarker": .string("retained")
            ])
            await cell.registerExploreSchema(
                requester: owner,
                key: "legacy.handler",
                schema: legacySchema,
                description: .string("Legacy handler schema")
            )
            let advertisedBefore = try await cell.typeForKey(key: "legacy.handler", requester: owner)

            await cell.addInterceptForGet(requester: owner, key: "legacy.handler") { _, _ in
                .string("ok")
            }

            let advertisedAfter = try await cell.typeForKey(key: "legacy.handler", requester: owner)
            let description = try await cell.schemaDescriptionForKey(key: "legacy.handler", requester: owner)
            XCTAssertTrue(ExploreContractValidator.deepEqual(advertisedAfter, advertisedBefore))
            XCTAssertEqual(description, .string("Legacy handler schema"))
            let result = try await cell.get(keypath: "legacy.handler", requester: owner)
            XCTAssertEqual(result, .string("ok"))
        }
    }

    func testStrictModeRejectsMethodlessLegacySchemaForHandlerInstallation() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.exploreContractEnforcementMode = .strict
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.registerExploreSchema(
            requester: owner,
            key: "legacy.strict",
            schema: .string("string"),
            description: .string("Legacy strict schema")
        )
        await cell.addInterceptForGet(requester: owner, key: "legacy.strict") { _, _ in
            .string("must-not-install")
        }

        do {
            _ = try await cell.get(keypath: "legacy.strict", requester: owner)
            XCTFail("Strict mode must require an exact method contract")
        } catch GeneralCell.KeyValueErrors.notFound {
        }
        let advertised = try await cell.typeForKey(key: "legacy.strict", requester: owner)
        XCTAssertEqual(advertised, .string("string"))
    }

    func testCatalogRetainsLegacyBaseAlongsideMethodSpecificContract() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.registerExploreContract(
            requester: owner,
            key: "mixed",
            method: .get,
            input: .null,
            returns: ExploreContract.schema(type: "string")
        )
        await cell.registerExploreSchema(
            requester: owner,
            key: "mixed",
            schema: .object(["customLegacyMarker": .string("retained")]),
            description: .string("Legacy base")
        )

        let catalog = try await cell.exploreContractCatalog(requester: owner)
        let mixedRecords = catalog.records.filter { $0.key == "mixed" }
        XCTAssertEqual(mixedRecords.count, 2)
        XCTAssertEqual(
            Set(mixedRecords.map { "\($0.id)|\($0.method)" }),
            Set(["GeneralCell#mixed|unspecified", "GeneralCell#mixed#get|get"])
        )
    }

    func testExactChildGrantCannotReachLegacyRootGetterOrSetter() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let member = await vault.identity(for: "member", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        var rootWasMutated = false

        await cell.setInterceptValueForKey(requester: owner, key: "profile") { _ in
            .object(["name": .string("Private"), "secret": .string("must-not-leak")])
        }
        await cell.setInterceptSetValueForKey(requester: owner, key: "profile") { _, _ in
            rootWasMutated = true
        }
        cell.agreementTemplate.addGrant("r---", for: "profile.name")
        cell.agreementTemplate.addGrant("-w--", for: "profile.name")
        let agreement = Agreement(owner: owner)
        agreement.addGrant("r---", for: "profile.name")
        agreement.addGrant("-w--", for: "profile.name")
        agreement.signatories.append(member)
        let agreementStatus = await cell.addAgreement(agreement, for: member, authorizedBy: owner)
        XCTAssertEqual(agreementStatus, .signed)

        do {
            _ = try await cell.get(keypath: "profile.name", requester: member)
            XCTFail("A child grant must not authorize a legacy root getter")
        } catch {
            XCTAssertTrue(error is CellAuthorizationError)
        }
        do {
            _ = try await cell.set(keypath: "profile.name", value: .string("Changed"), requester: member)
            XCTFail("A child grant must not authorize a legacy root setter")
        } catch {
            XCTAssertTrue(error is CellAuthorizationError)
        }
        XCTAssertFalse(rootWasMutated)
    }

    func testRootGrantStillAuthorizesExactHandlerCompatibilityFallback() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let member = await vault.identity(for: "member", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.addInterceptForGet(requester: owner, key: "profile.name") { _, _ in .string("Visible") }
        cell.agreementTemplate.addGrant("r---", for: "profile")
        let agreement = Agreement(owner: owner)
        agreement.addGrant("r---", for: "profile")
        agreement.signatories.append(member)
        let agreementStatus = await cell.addAgreement(agreement, for: member, authorizedBy: owner)
        XCTAssertEqual(agreementStatus, .signed)

        let value = try await cell.get(keypath: "profile.name", requester: member)
        XCTAssertEqual(value, .string("Visible"))
    }

    func testAttachSignContractWithUnmetConditionEmitsConnectChallenge() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let requester = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let emitterOwner = await vault.identity(for: "other", makeNewIfNotFound: true)!

        let absorbCell = await GeneralCell(owner: requester)
        let emitCell = TestEmitCell(owner: emitterOwner, admittedState: .signContract)

        let agreement = Agreement(owner: emitterOwner)
        agreement.conditions = [LookupCondition(keypath: "identity.contractApproval", expectedValue: .bool(true))]
        emitCell.agreementTemplate = agreement

        let feed = try await absorbCell.flow(requester: requester)
        let challengeExpectation = expectation(description: "connect.challenge emitted")
        let cancellable = feed.sink(receiveCompletion: { _ in }, receiveValue: { flowElement in
            guard flowElement.topic == "connect.challenge",
                  case let .object(payload) = flowElement.content else {
                return
            }

            if case let .string(state) = payload["state"] {
                XCTAssertEqual(state, "unmet")
            } else {
                XCTFail("Expected unmet state in connect.challenge payload")
            }

            if case let .string(requiredAction) = payload["requiredAction"] {
                XCTAssertFalse(requiredAction.isEmpty)
            } else {
                XCTFail("Expected requiredAction in connect.challenge payload")
            }

            XCTAssertNotNil(payload["agreement"])
            XCTAssertNotNil(payload["context"])
            if case let .string(sessionID) = payload["sessionId"] {
                XCTAssertFalse(sessionID.isEmpty)
            } else {
                XCTFail("Expected sessionId in connect.challenge payload")
            }
            if case let .cellConfiguration(configuration) = payload["helperCellConfiguration"] {
                XCTAssertEqual(configuration.discovery?.sourceCellEndpoint, "cell:///AgreementWorkbench")
                XCTAssertEqual(configuration.cellReferences?.first?.endpoint, "cell:///AgreementWorkbench")
            } else {
                XCTFail("Expected AgreementWorkbench helperCellConfiguration in connect.challenge payload")
            }
            challengeExpectation.fulfill()
        })

        let state = try await absorbCell.attach(emitter: emitCell, label: "challenge", requester: requester)
        XCTAssertEqual(state, .signContract)

        await fulfillment(of: [challengeExpectation], timeout: 1.0)
        cancellable.cancel()
    }

    func testAttachDeniedEmitsConnectChallenge() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let requester = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let emitterOwner = await vault.identity(for: "other", makeNewIfNotFound: true)!

        let absorbCell = await GeneralCell(owner: requester)
        let emitCell = TestEmitCell(owner: emitterOwner, admittedState: .denied)

        let feed = try await absorbCell.flow(requester: requester)
        let challengeExpectation = expectation(description: "connect.challenge denied emitted")
        let cancellable = feed.sink(receiveCompletion: { _ in }, receiveValue: { flowElement in
            guard flowElement.topic == "connect.challenge",
                  case let .object(payload) = flowElement.content else {
                return
            }

            if case let .string(state) = payload["state"] {
                XCTAssertEqual(state, "denied")
            } else {
                XCTFail("Expected denied state in connect.challenge payload")
            }

            if case let .string(reasonCode) = payload["reasonCode"] {
                XCTAssertEqual(reasonCode, "connect_denied")
            } else {
                XCTFail("Expected connect_denied reasonCode in payload")
            }
            challengeExpectation.fulfill()
        })

        let state = try await absorbCell.attach(emitter: emitCell, label: "denied", requester: requester)
        XCTAssertEqual(state, .denied)

        await fulfillment(of: [challengeExpectation], timeout: 1.0)
        cancellable.cancel()
    }

    func testAttachSignContractWithConditionalEngagementIncludesHelperConfiguration() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let requester = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let emitterOwner = await vault.identity(for: "other", makeNewIfNotFound: true)!

        let absorbCell = await GeneralCell(owner: requester)
        let emitCell = TestEmitCell(owner: emitterOwner, admittedState: .signContract)

        let agreement = Agreement(owner: emitterOwner)
        agreement.conditions = [ConditionalEngagement()]
        emitCell.agreementTemplate = agreement

        let feed = try await absorbCell.flow(requester: requester)
        let challengeExpectation = expectation(description: "conditional engagement challenge emitted")
        let cancellable = feed.sink(receiveCompletion: { _ in }, receiveValue: { flowElement in
            guard flowElement.topic == "connect.challenge",
                  case let .object(payload) = flowElement.content else {
                return
            }

            if case let .string(requiredAction) = payload["requiredAction"] {
                XCTAssertEqual(requiredAction, "open_helper_configuration")
            } else {
                XCTFail("Expected open_helper_configuration action")
            }

            if case .cellConfiguration = payload["helperCellConfiguration"] {
                // expected helper present
            } else {
                XCTFail("Expected helperCellConfiguration in connect.challenge payload")
            }
            if case let .string(sessionID) = payload["sessionId"] {
                XCTAssertFalse(sessionID.isEmpty)
            } else {
                XCTFail("Expected sessionId in connect.challenge payload")
            }
            challengeExpectation.fulfill()
        })

        let state = try await absorbCell.attach(emitter: emitCell, label: "engagement", requester: requester)
        XCTAssertEqual(state, .signContract)

        await fulfillment(of: [challengeExpectation], timeout: 1.0)
        cancellable.cancel()
    }

    func testRetryAdmissionSessionReconnectsAfterConditionBecomesMet() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let requester = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let emitterOwner = await vault.identity(for: "other", makeNewIfNotFound: true)!

        let absorbCell = await GeneralCell(owner: requester)
        let emitCell = TestEmitCell(owner: emitterOwner, admittedState: .signContract)

        let agreement = Agreement(owner: emitterOwner)
        agreement.conditions = [LookupCondition(keypath: "target.ticketValid", expectedValue: .bool(true))]
        emitCell.agreementTemplate = agreement

        let feed = try await absorbCell.flow(requester: requester)
        let challengeExpectation = expectation(description: "connect.challenge with session emitted")
        var capturedSessionID: String?
        let cancellable = feed.sink(receiveCompletion: { _ in }, receiveValue: { flowElement in
            guard flowElement.topic == "connect.challenge",
                  case let .object(payload) = flowElement.content else {
                return
            }
            if case let .string(sessionID) = payload["sessionId"] {
                capturedSessionID = sessionID
                challengeExpectation.fulfill()
            }
        })

        let initialState = try await absorbCell.attach(emitter: emitCell, label: "auto-retry", requester: requester)
        XCTAssertEqual(initialState, .signContract)
        await fulfillment(of: [challengeExpectation], timeout: 1.0)

        _ = try await emitCell.set(keypath: "ticketValid", value: .bool(true), requester: emitterOwner)
        let retriedState = try await absorbCell.retryAdmissionSession(id: try XCTUnwrap(capturedSessionID), requester: requester)
        XCTAssertEqual(retriedState, .connected)

        cancellable.cancel()
    }

    func testDecodedAbsorbCellInstallsFeedBindingBeforeAttachmentAndSubscription() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let source = await DecodedFeedBindingProbeCell(owner: owner)
        let encoded = try JSONEncoder().encode(source)
        let restored = try JSONDecoder().decode(DecodedFeedBindingProbeCell.self, from: encoded)
        let emitter = FlowElementPusherCell(owner: owner)

        let transformedEvent = expectation(description: "decoded feed binding transformed event")
        let cancellable = restored.getFeedPublisher().sink(
            receiveCompletion: { _ in },
            receiveValue: { event in
                guard event.title == "runtime-bound:source-event" else { return }
                transformedEvent.fulfill()
            }
        )

        let connectState = try await restored.attach(
            emitter: emitter,
            label: "decoded-source",
            requester: owner
        )
        XCTAssertEqual(connectState, .connected)
        try await restored.absorbFlow(label: "decoded-source", requester: owner)

        emitter.pushFlowElement(
            FlowElement(
                title: "source-event",
                content: .string("payload"),
                properties: .init(type: .content, contentType: .string)
            ),
            requester: owner
        )

        await fulfillment(of: [transformedEvent], timeout: 1.0)
        cancellable.cancel()
    }
}

private final class CellSpecificAccessHarnessCell: GeneralCell {
    private var allowedAccess = Set<String>()

    required init(owner: Identity) async {
        await super.init(owner: owner)
    }

    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }

    func allow(identity: Identity, access: String, keypath: String) {
        allowedAccess.insert(Self.accessKey(identity: identity, access: access, keypath: keypath))
    }

    override func validateCellSpecificAccess(_ requestedAccess: String, at keypath: String, for identity: Identity) async -> Bool {
        allowedAccess.contains(Self.accessKey(identity: identity, access: requestedAccess, keypath: keypath))
    }

    private static func accessKey(identity: Identity, access: String, keypath: String) -> String {
        "\(identity.uuid)|\(access)|\(keypath)"
    }
}

private final class AuthorizationSpyCell: GeneralCell {
    private let counter = AuthorizationDecisionCounter()

    func authorizationDecisionCount() async -> Int {
        await counter.value()
    }

    required init(owner: Identity) async {
        await super.init(owner: owner)
    }

    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }

    override func authorizationDecision(
        requestedAccess: String,
        at keypath: String,
        for identity: Identity
    ) async -> CellAuthorizationDecision {
        await counter.increment()
        return await super.authorizationDecision(
            requestedAccess: requestedAccess,
            at: keypath,
            for: identity
        )
    }
}

private actor AuthorizationDecisionCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private final class DecodedFeedBindingProbeCell: GeneralCell {
    required init(owner: Identity) async {
        await super.init(owner: owner)
    }

    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }

    override func installCellRuntimeBindingsForAccess() async throws {
        agreementTemplate.ensureGrant("r---", for: "feed")
        await addIntercept(requester: storedOwnerIdentity) { event, _ in
            var transformed = event
            transformed.title = "runtime-bound:\(event.title)"
            return transformed
        }
    }
}
