// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import XCTest
@_spi(HAVENRuntime) @testable import CellBase

final class ExternalAgreementAdmissionTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    override func setUp() {
        super.setUp()
        XCTAssertFalse(CellBase.debugValidateAccessForEverything, "Probe requires real authorization")
        previousVault = CellBase.defaultIdentityVault
        CellBase.defaultIdentityVault = EphemeralIdentityVault()
    }
    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        super.tearDown()
    }
    // Uses the existing trusted runtime-binding scope only to install handlers;
    // access and membership still use the production authorization path.
    private final class ProbeCell: GeneralCell {
        required init(owner: Identity) async {
            await super.init(owner: owner)
            name = "probe-name"
        }
        required init(from decoder: Decoder) throws { try super.init(from: decoder) }
        override func installCellRuntimeBindingsForAccess() async throws {
            await addInterceptForGet(requester: storedOwnerIdentity, key: "name") { _, _ in
                .string(self.name)
            }
            await addInterceptForSet(requester: storedOwnerIdentity, key: "name") { _, value, _ in
                if case .string(let value) = value { self.name = value }
                return .string(self.name)
            }
        }
    }
    private struct Fixture {
        let a: EphemeralIdentityVault
        let b: EphemeralIdentityVault
        let sVault: EphemeralIdentityVault
        let owner: Identity
        let subject: Identity
        let cell: GeneralCell
    }
    private func identity(_ vault: EphemeralIdentityVault, _ label: String) async -> Identity {
        var identity = Identity(UUID().uuidString, displayName: label, identityVault: vault)
        await vault.addIdentity(identity: &identity, for: "private")
        return identity
    }
    private func fixture() async -> Fixture {
        let a = EphemeralIdentityVault(), b = EphemeralIdentityVault(), s = EphemeralIdentityVault()
        let owner = await identity(a, "test-owner")
        let subject = await identity(s, "test-subject")
        CellBase.defaultIdentityVault = b
        let cell = await ProbeCell(owner: owner.publicIdentitySnapshot())
        cell.authorizationClock = { self.now }
        cell.agreementTemplate.conditions = []
        cell.agreementTemplate.grants = [Grant(keypath: "name", permission: "r---")]
        cell.agreementTemplate.duration = 3600
        return Fixture(a: a, b: b, sVault: s, owner: owner, subject: subject, cell: cell)
    }
    private func signed(_ f: Fixture, issuer: Identity? = nil, resource: String? = nil,
                        duration: Int = 600, issuedAt: Date? = nil, path: String = "name", domain: String? = nil) async throws -> Contract {
        let agreement = Agreement(owner: f.owner.publicIdentitySnapshot())
        agreement.state = .signed
        agreement.signatories = [f.owner.publicIdentitySnapshot(), f.subject.publicIdentitySnapshot()]
        agreement.conditions = []
        agreement.grants = [Grant(keypath: path, permission: "r---")]
        agreement.duration = duration
        let contract = try await Contract.signed(agreement: agreement, issuer: issuer ?? f.owner,
            subject: f.subject.publicIdentitySnapshot(), domain: domain ?? f.cell.identityDomain,
            issuedAt: issuedAt ?? now, targetCellUUID: resource ?? f.cell.uuid)
        let wire = try JSONDecoder().decode(Contract.self, from: JSONEncoder().encode(contract))
        let validSignature = await wire.verifyCryptographicSignature()
        XCTAssertTrue(validSignature, "Negative tests must start with authentic signed bytes")
        return wire
    }
    private struct Snapshot: Decodable {
        let contracts: [Contract]
        let members: [Identity]
    }
    private func snapshot(_ cell: GeneralCell) throws -> Snapshot {
        try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(cell))
    }
    private func denied(_ contract: Contract, _ f: Fixture, presenter: Identity? = nil) async throws {
        let state = await f.cell.acceptExternallySignedAgreement(contract, for: presenter ?? f.subject)
        XCTAssertEqual(state, .rejected)
        let snapshot = try snapshot(f.cell)
        XCTAssertEqual(snapshot.contracts.count, 0)
        XCTAssertEqual(snapshot.members.count, 0)
    }
    func testExternalOwnerSignatureAdmitsSubjectWithoutOwnerKeyInHostAndRejectsWrite() async throws {
        let f = await fixture()
        XCTAssertNil(f.cell.owner.identityVault)
        let ownerInB = await f.b.identity(forUUID: f.owner.uuid)
        XCTAssertNil(ownerInB)
        do { _ = try await f.b.signMessageForIdentity(messageData: Data("probe".utf8), identity: f.owner); XCTFail("B signed as owner") } catch {}
        let contract = try await signed(f)
        XCTAssertNil(contract.issuer.identityVault)
        XCTAssertNil(contract.subject.identityVault)
        let result = await f.cell.acceptExternallySignedAgreement(contract, for: f.subject)
        XCTAssertEqual(result, .signed)
        let read = try await f.cell.get(keypath: "name", requester: f.subject)
        XCTAssertEqual(read, .string("probe-name"))
        do { _ = try await f.cell.set(keypath: "name", value: .string("forbidden"), requester: f.subject); XCTFail("Write admitted") } catch {}
        XCTAssertEqual(f.cell.name, "probe-name")
        let snapshot = try snapshot(f.cell)
        XCTAssertEqual(snapshot.members.count, 1)
        XCTAssertEqual(snapshot.contracts.count, 1)
        XCTAssertNil(snapshot.members.first?.identityVault)
    }
    func testRejectsSignatureFromOtherKeyWithOwnerUUID() async throws {
        let f = await fixture()
        let vault = EphemeralIdentityVault()
        var impostor = Identity(f.owner.uuid, displayName: "test-impostor", identityVault: vault)
        await vault.addIdentity(identity: &impostor, for: "private")
        try await denied(try await signed(f, issuer: impostor), f)
    }
    func testRejectsOwnerSignatureForOtherCellWithSameTemplateAndDomain() async throws {
        let f = await fixture()
        let other = await GeneralCell(owner: f.owner.publicIdentitySnapshot())
        other.identityDomain = f.cell.identityDomain
        other.agreementTemplate = f.cell.agreementTemplate
        try await denied(try await signed(f, resource: other.uuid), f)
    }
    func testRejectsExpiredSignature() async throws {
        let f = await fixture()
        try await denied(try await signed(f, issuedAt: now.addingTimeInterval(-1200)), f)
    }
    func testRejectsNotYetValidSignature() async throws {
        let f = await fixture()
        try await denied(try await signed(f, issuedAt: now.addingTimeInterval(601)), f)
    }
    func testRejectsSubjectWithoutPrivateKeyProof() async throws {
        let f = await fixture()
        try await denied(try await signed(f), f, presenter: f.subject.publicIdentitySnapshot())
    }
    func testRejectsGrantOutsideTemplate() async throws {
        let f = await fixture()
        try await denied(try await signed(f, path: "members"), f)
    }
    func testRejectsDurationBeyondTemplate() async throws {
        let f = await fixture()
        try await denied(try await signed(f, duration: 3601), f)
    }
    func testRejectsThirdIdentityPresentingSubjectsContractAndReading() async throws {
        let f = await fixture()
        let third = await identity(EphemeralIdentityVault(), "test-third")
        let contract = try await signed(f)
        try await denied(contract, f, presenter: third)
        let admitted = await f.cell.acceptExternallySignedAgreement(contract, for: f.subject)
        XCTAssertEqual(admitted, .signed)
        do { _ = try await f.cell.get(keypath: "name", requester: third); XCTFail("Third identity read") } catch {}
    }
    func testRepeatedPresentationDoesNotGrowMembersOrContracts() async throws {
        let f = await fixture()
        let contract = try await signed(f)
        for _ in 0..<2 {
            let result = await f.cell.acceptExternallySignedAgreement(contract, for: f.subject)
            XCTAssertEqual(result, .signed)
        }
        let snapshot = try snapshot(f.cell)
        XCTAssertEqual(snapshot.members.count, 1)
        XCTAssertEqual(snapshot.contracts.count, 1)
    }
    func testRejectsHostAddAgreementWithoutOwnerPrivateKey() async throws {
        let f = await fixture()
        let request = try f.cell.agreementTemplate.publicDescriptorSnapshot()
        let result = await f.cell.addAgreement(request, for: f.subject, authorizedBy: f.cell.owner)
        XCTAssertEqual(result, .rejected)
        let snapshot = try snapshot(f.cell)
        XCTAssertTrue(snapshot.contracts.isEmpty)
    }
    func testOwnerSameIdentityRequiresKeyProofForOrdinaryRead() async throws {
        let f = await fixture()
        _ = try await f.cell.get(keypath: "name", requester: f.owner)
        do { _ = try await f.cell.get(keypath: "name", requester: f.owner.publicIdentitySnapshot()); XCTFail("Owner without proof read") } catch {}
    }
    func testOwnerAndSeparateAgentIdentityBothRequireTheirOwnKeyProof() async throws {
        let f = await fixture()
        let result = await f.cell.acceptExternallySignedAgreement(try await signed(f), for: f.subject)
        XCTAssertEqual(result, .signed)
        _ = try await f.cell.get(keypath: "name", requester: f.subject)
        do { _ = try await f.cell.get(keypath: "name", requester: f.subject.publicIdentitySnapshot()); XCTFail("Agent without proof read") } catch {}
        _ = try await f.cell.get(keypath: "name", requester: f.owner)
    }
    func testRejectsChangedCellBindingAfterWireRoundTrip() async throws {
        let f = await fixture()
        let contract = try await signed(f)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(contract)) as? [String: Any])
        json["targetCellUUID"] = "test-other-cell"
        let modified = try JSONDecoder().decode(Contract.self, from: JSONSerialization.data(withJSONObject: json))
        let valid = await modified.verifyCryptographicSignature()
        XCTAssertFalse(valid)
        try await denied(modified, f)
    }
    func testRejectsUnboundLegacyContractWhileKeepingItsSignatureValid() async throws {
        let f = await fixture()
        let agreement = Agreement(owner: f.owner.publicIdentitySnapshot())
        agreement.state = .signed
        agreement.conditions = []
        agreement.signatories = [f.owner.publicIdentitySnapshot(), f.subject.publicIdentitySnapshot()]
        agreement.grants = f.cell.agreementTemplate.grants
        agreement.duration = 600
        let legacy = try await Contract.signed(agreement: agreement, issuer: f.owner,
            subject: f.subject.publicIdentitySnapshot(), domain: f.cell.identityDomain, issuedAt: now)
        let wire = try JSONDecoder().decode(Contract.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(wire.targetCellUUID)
        XCTAssertEqual(wire.signingSemantics, Contract.issuerOnlySubjectBoundSemantics)
        let valid = await wire.verifyCryptographicSignature()
        XCTAssertTrue(valid)
        try await denied(wire, f)
    }
    func testRejectsOwnerSignatureForWrongDomain() async throws {
        let f = await fixture()
        try await denied(try await signed(f, domain: "other-domain"), f)
    }
    func testRejectsConditionsDifferentFromCurrentTemplate() async throws {
        let f = await fixture()
        let contract = try await signed(f)
        f.cell.agreementTemplate.conditions = [GrantCondition(requestedGrant: "identity.displayName", requestedPermission: "r---")]
        try await denied(contract, f)
    }
    func testPublicRemoteSubjectWithoutSigningProxyCannotProveControl() async throws {
        let f = await fixture()
        let proved = await f.cell.verifyRequesterIdentityControl(f.subject.publicIdentitySnapshot())
        XCTAssertFalse(proved)
        let localProof = await f.cell.verifyRequesterIdentityControl(f.subject)
        XCTAssertTrue(localProof)
    }
    func testRevocationRejectsReplayAndSurvivesSnapshot() async throws {
        let f = await fixture()
        let contract = try await signed(f)
        let admitted = await f.cell.acceptExternallySignedAgreement(contract, for: f.subject)
        XCTAssertEqual(admitted, .signed)
        let revocation = try await ContractRevocation.signed(contract: contract, owner: f.owner, at: now)
        let revoked = await f.cell.acceptExternallySignedRevocation(revocation)
        XCTAssertTrue(revoked)
        let replay = await f.cell.acceptExternallySignedRevocation(revocation)
        XCTAssertFalse(replay)
        let readmission = await f.cell.acceptExternallySignedAgreement(contract, for: f.subject)
        XCTAssertEqual(readmission, .rejected)
        let restored = try JSONDecoder().decode(ProbeCell.self, from: JSONEncoder().encode(f.cell))
        restored.authorizationClock = { self.now }
        let restoredResult = await restored.acceptExternallySignedAgreement(contract, for: f.subject)
        XCTAssertEqual(restoredResult, .rejected)
        XCTAssertTrue(try snapshot(restored).members.isEmpty)
    }

    func testOwnerRemovalBeforeAdmissionBlocksPreviouslySignedContract() async throws {
        let f = await fixture()
        let contract = try await signed(f)
        await f.cell.removeMember(uuid: f.subject.uuid, requester: f.owner)
        let result = await f.cell.acceptExternallySignedAgreement(contract, for: f.subject)
        XCTAssertEqual(result, .rejected)
        XCTAssertTrue(try snapshot(f.cell).contracts.isEmpty)
    }

    func testRenewalWithLaterExpiryReplacesPreviousSubjectContract() async throws {
        let f = await fixture()
        let original = try await signed(f)
        let renewed = try await signed(f, duration: 1200)
        let first = await f.cell.acceptExternallySignedAgreement(original, for: f.subject)
        let second = await f.cell.acceptExternallySignedAgreement(renewed, for: f.subject)
        XCTAssertEqual(first, .signed)
        XCTAssertEqual(second, .signed)
        XCTAssertEqual(try snapshot(f.cell).contracts.map(\.uuid), [renewed.uuid])
        XCTAssertEqual(try snapshot(f.cell).members.count, 1)
        let stale = await f.cell.acceptExternallySignedAgreement(original, for: f.subject)
        XCTAssertEqual(stale, .rejected)
    }

    func testRemovedBindingIsRejectedAndOwnerCanWrite() async throws {
        let f = await fixture()
        let contract = try await signed(f)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(contract)) as? [String: Any])
        json.removeValue(forKey: "targetCellUUID")
        let changed = try JSONDecoder().decode(Contract.self, from: JSONSerialization.data(withJSONObject: json))
        try await denied(changed, f)
        let written = try await f.cell.set(keypath: "name", value: .string("owner-write"), requester: f.owner)
        XCTAssertEqual(written, .string("owner-write"))
    }

    func testExternalAdmissionRejectsFutureWithinLegacyClockSkewWindow() async throws {
        let f = await fixture()
        let contract = try await signed(f, issuedAt: now.addingTimeInterval(60))
        let legacyValid = await contract.verifySignature(now: now)
        XCTAssertTrue(legacyValid, "Legacy signature verification keeps its clock-skew policy")
        try await denied(contract, f)
    }

    func testRepeatedRemovalAtSameClockDefeatsPendingLocalReissue() async throws {
        let f = await fixture()
        let auditor = GeneralAuditor()
        let initial = await auditor.authorizationSnapshot()
        let first = await auditor.removeAuthorization(subjectUUID: f.subject.uuid,
            revokedAt: now.timeIntervalSince1970, restoring: initial)
        let date = Date(timeIntervalSince1970: now.timeIntervalSince1970.nextUp)
        let contract = try await signed(f, issuedAt: date)
        let removedAgain = await auditor.removeAuthorization(subjectUUID: f.subject.uuid,
            revokedAt: now.timeIntervalSince1970, restoring: first)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(removedAgain.revokedBefore[f.subject.uuid]), contract.issuedAt)
        let installed = await auditor.installAuthorization(contract: contract,
            member: f.subject.publicIdentitySnapshot(), restoring: first)
        XCTAssertTrue(installed.contracts.isEmpty)
        XCTAssertTrue(installed.members.isEmpty)
    }

    func testCanonicalSignedContractBytesSurviveRoundTrip() async throws {
        let f = await fixture()
        let agreement = try await signed(f).agreement
        let contract = try await Contract.signed(agreement: agreement, issuer: f.owner,
            subject: f.subject, domain: f.cell.identityDomain, issuedAt: now)
        let data = try SignedAgreementEntitySupport.canonicalData(contract)
        let restored = try JSONDecoder().decode(Contract.self, from: data)
        XCTAssertEqual(try SignedAgreementEntitySupport.canonicalData(restored), data)
    }

    func testFreshLocalOwnerSignatureCanReadmitAtUnchangedClock() async throws {
        let f = await fixture()
        await f.cell.removeMember(member: f.subject, requester: f.owner)
        let request = Agreement(owner: f.owner)
        request.conditions = []
        request.duration = 600
        request.grants = [Grant(keypath: "name", permission: "r---")]
        let result = await f.cell.addAgreement(request, for: f.subject, authorizedBy: f.owner)
        XCTAssertEqual(result, .signed)
        let expected = try await f.cell.get(keypath: "name", requester: f.owner)
        let actual = try await f.cell.get(keypath: "name", requester: f.subject)
        XCTAssertEqual(actual, expected)
    }

    func testAuditorFinalInstallRejectsRevokedContractWithStaleCallerSnapshot() async throws {
        let f = await fixture()
        let contract = try await signed(f)
        let auditor = GeneralAuditor()
        let initial = await auditor.authorizationSnapshot()
        let removed = await auditor.removeAuthorization(subjectUUID: f.subject.uuid,
            revokedAt: now.timeIntervalSince1970, restoring: initial)
        XCTAssertEqual(removed.revokedBefore[f.subject.uuid], now.timeIntervalSince1970)
        let installed = await auditor.installAuthorization(contract: contract,
            member: f.subject.publicIdentitySnapshot(), restoring: initial)
        XCTAssertTrue(installed.contracts.isEmpty)
        XCTAssertTrue(installed.members.isEmpty)
    }

    func testBoundContractCannotAuthorizeDifferentCellUUIDAfterLocalRestoration() async throws {
        let f = await fixture()
        let result = await f.cell.acceptExternallySignedAgreement(try await signed(f), for: f.subject)
        XCTAssertEqual(result, .signed)
        let encoded = try JSONEncoder().encode(f.cell)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["uuid"] = UUID().uuidString
        let restored = try JSONDecoder().decode(ProbeCell.self, from: JSONSerialization.data(withJSONObject: json))
        restored.authorizationClock = { self.now }
        do { _ = try await restored.get(keypath: "name", requester: f.subject); XCTFail("Bound contract authorized a clone") }
        catch let CellAuthorizationError.denied(decision) { XCTAssertFalse(decision.allowed) }
    }

    func testRemovalWhileSubjectProofIsSuspendedCannotInstallMember() async throws {
        let f = await fixture()
        let contract = try await signed(f)
        let gate = SuspendedAdmissionVault(base: f.sVault)
        f.subject.identityVault = gate
        let pending = Task { await f.cell.acceptExternallySignedAgreement(contract, for: f.subject) }
        await gate.waitUntilSuspended()
        await f.cell.removeMember(uuid: f.subject.uuid, requester: f.owner)
        await gate.release()
        let result = await pending.value
        XCTAssertEqual(result, .rejected)
        XCTAssertTrue(try snapshot(f.cell).members.isEmpty)
        XCTAssertTrue(try snapshot(f.cell).contracts.isEmpty)
    }

}



private actor SuspendedAdmissionVault: IdentityVaultProtocol {
    let base: EphemeralIdentityVault
    var suspended = false
    var waiter: CheckedContinuation<Void, Never>?
    var blocked: CheckedContinuation<Void, Never>?
    init(base: EphemeralIdentityVault) { self.base = base }
    func waitUntilSuspended() async {
        if suspended { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { blocked?.resume(); blocked = nil }
    func identityVaultReference() async -> String? { await base.identityVaultReference() }
    func initialize() async -> IdentityVaultProtocol { self }
    func addIdentity(identity: inout Identity, for context: String) async { await base.addIdentity(identity: &identity, for: context) }
    func identity(for context: String, makeNewIfNotFound: Bool) async -> Identity? { await base.identity(for: context, makeNewIfNotFound: makeNewIfNotFound) }
    func identity(forUUID uuid: String) async -> Identity? { await base.identity(forUUID: uuid) }
    func identityExistInVault(_ identity: Identity) async -> Bool { await base.identityExistInVault(identity) }
    func saveIdentity(_ identity: Identity) async { await base.saveIdentity(identity) }
    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        suspended = true
        waiter?.resume(); waiter = nil
        await withCheckedContinuation { blocked = $0 }
        return try await base.signMessageForIdentity(messageData: messageData, identity: identity)
    }
    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool { try await base.verifySignature(signature: signature, messageData: messageData, for: identity) }
    func randomBytes64() async -> Data? { await base.randomBytes64() }
    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) { try await base.aquireKeyForTag(tag: tag) }
}
