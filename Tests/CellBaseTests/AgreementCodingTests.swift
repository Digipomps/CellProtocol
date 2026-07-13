// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class AgreementCodingTests: XCTestCase {
    func testAsyncAgreementInitializesOwnerAndSignatoryAtomically() async {
        let previousVault = CellBase.defaultIdentityVault
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        defer { CellBase.defaultIdentityVault = previousVault }

        let agreement = await Agreement()

        XCTAssertEqual(agreement.signatories.count, 1)
        XCTAssertEqual(agreement.owner.uuid, agreement.signatories[0].uuid)
        XCTAssertEqual(
            agreement.owner.signingPublicKeyFingerprint,
            agreement.signatories[0].signingPublicKeyFingerprint
        )
        XCTAssertNotNil(agreement.owner.identityVault)
    }

    func testAsyncAgreementHasDeterministicFallbackWithoutVault() async {
        let previousVault = CellBase.defaultIdentityVault
        CellBase.defaultIdentityVault = nil
        defer { CellBase.defaultIdentityVault = previousVault }

        let agreement = await Agreement()

        XCTAssertEqual(agreement.signatories.count, 1)
        XCTAssertEqual(agreement.owner.uuid, agreement.signatories[0].uuid)
        XCTAssertEqual(
            agreement.owner.signingPublicKeyFingerprint,
            agreement.signatories[0].signingPublicKeyFingerprint
        )
        XCTAssertNil(agreement.owner.identityVault)
    }

    func testAgreementDecodesLegacyPayloadWithoutUUIDStateOrDurationAsTemplate() throws {
        let owner = Identity("agreement-owner", displayName: "Agreement Owner", identityVault: nil)
        let agreement = Agreement(owner: owner)
        let legacyData = try removingKeys(["uuid", "state", "duration"], from: agreement)

        let decoded = try JSONDecoder().decode(Agreement.self, from: legacyData)

        XCTAssertFalse(decoded.uuid.isEmpty)
        XCTAssertEqual(decoded.name, agreement.name)
        XCTAssertEqual(decoded.state, .template)
        XCTAssertEqual(decoded.duration, 60 * 60 * 24 * 365)

        let canonicalObject = try jsonObject(from: JSONEncoder().encode(decoded))
        XCTAssertEqual(canonicalObject["state"] as? String, "template")
        XCTAssertEqual(canonicalObject["duration"] as? Int, 60 * 60 * 24 * 365)
    }

    func testAgreementDecodesUnknownLegacyStateAsTemplate() throws {
        let owner = Identity("agreement-owner-unknown-state", displayName: "Agreement Owner", identityVault: nil)
        let agreement = Agreement(owner: owner)
        var object = try jsonObject(from: JSONEncoder().encode(agreement))
        object["state"] = "accepted"

        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(Agreement.self, from: data)

        XCTAssertEqual(decoded.state, .template)
    }

    func testGrantDecodesLegacyPayloadWithoutUUID() throws {
        let grant = Grant("Legacy grant", keypath: "state", permission: "r---")
        let legacyData = try removingKeys(["uuid"], from: grant)

        let decoded = try JSONDecoder().decode(Grant.self, from: legacyData)

        XCTAssertFalse(decoded.uuid.isEmpty)
        XCTAssertEqual(decoded.name, grant.name)
        XCTAssertEqual(decoded.keypath, grant.keypath)
        XCTAssertEqual(decoded.permission.permissionString, grant.permission.permissionString)
    }

    func testEnsureGrantIsIdempotentAndAcceptsBroaderExistingCapability() {
        let agreement = Agreement(owner: Identity())
        agreement.grants = []

        agreement.ensureGrant("r---", for: "state")
        agreement.ensureGrant("r---", for: "state")
        agreement.ensureGrant("rw--", for: "state")
        agreement.ensureGrant("r---", for: "state")

        XCTAssertEqual(agreement.grants.count, 2)
        XCTAssertEqual(agreement.grants[0].permission.permissionString, "r---")
        XCTAssertEqual(agreement.grants[1].permission.permissionString, "rw--")
    }

    func testCanonicalFourCharacterPermissionsPreserveStorageAndStaySeparated() throws {
        let read = Grant(keypath: "person", permission: "r---")
        let write = Grant(keypath: "person", permission: "-w--")
        let readWrite = Grant(keypath: "person", permission: "rw--")
        let execute = Grant(keypath: "person", permission: "--x-")
        let storage = Grant(keypath: "person", permission: "---s")
        let readStorage = Grant(keypath: "person", permission: "r--s")
        let all = Grant(keypath: "person", permission: "rwxs")

        XCTAssertEqual(read.permission.permissionString, "r---")
        XCTAssertEqual(write.permission.permissionString, "-w--")
        XCTAssertEqual(readWrite.permission.permissionString, "rw--")
        XCTAssertEqual(execute.permission.permissionString, "--x-")
        XCTAssertEqual(storage.permission.permissionString, "---s")
        XCTAssertEqual(readStorage.permission.permissionString, "r--s")
        XCTAssertEqual(all.permission.permissionString, "rwxs")
        XCTAssertEqual(all.permission.description(), "group: rwxs other: ----")

        XCTAssertTrue(readWrite.granted(read))
        XCTAssertTrue(readWrite.granted(write))
        XCTAssertFalse(read.granted(write))
        XCTAssertFalse(write.granted(read))
        XCTAssertFalse(readWrite.granted(execute))
        XCTAssertTrue(readStorage.granted(read))
        XCTAssertTrue(readStorage.granted(storage))
        XCTAssertFalse(read.granted(storage))
        XCTAssertFalse(storage.granted(read))
        XCTAssertTrue(all.granted(storage))
        XCTAssertFalse(Permission.matchPermission(permissionRequested: "---s", permissionGranted: "rwx-"))
        XCTAssertTrue(Permission.matchPermission(permissionRequested: "---s", permissionGranted: "rwxs"))
    }

    func testLegacyPermissionWidthsDecodeWithoutGrantingStorage() throws {
        let legacyRead = Grant(keypath: "person", permission: "r--")
        let legacyGroupAndOther = Permission("r---w-")

        XCTAssertEqual(legacyRead.permission.permissionString, "r---")
        XCTAssertFalse(legacyRead.permission.matchGroupPermission(permission: Permission.s))
        XCTAssertEqual(legacyGroupAndOther.permissionString, "r---")
        XCTAssertTrue(legacyGroupAndOther.matchOtherPermission(permission: Permission.w))
        XCTAssertFalse(legacyGroupAndOther.matchOtherPermission(permission: Permission.s))
    }

    func testCanonicalGroupAndOtherPermissionsSupportStorage() throws {
        let permission = Permission("r--s-w-s")

        XCTAssertEqual(permission.permissionString, "r--s")
        XCTAssertTrue(permission.matchGroupPermission(permission: Permission.r | Permission.s))
        XCTAssertTrue(permission.matchOtherPermission(permission: Permission.w | Permission.s))
        XCTAssertFalse(permission.matchOtherPermission(permission: Permission.x))
    }

    func testPermissionIntegerWireFormatRemainsBackwardCompatibleAndAddsStorageBit() throws {
        let legacyJSON = Data(#"{"uuid":"legacy","group":4,"other":0}"#.utf8)
        let legacy = try JSONDecoder().decode(Permission.self, from: legacyJSON)

        XCTAssertEqual(legacy.permissionString, "r---")
        XCTAssertFalse(legacy.matchGroupPermission(permission: Permission.s))

        let storage = Permission("---s")
        let encoded = try jsonObject(from: JSONEncoder().encode(storage))
        XCTAssertEqual(encoded["group"] as? Int, 8)
        XCTAssertEqual(encoded["other"] as? Int, 0)

        let roundTripped = try JSONDecoder().decode(Permission.self, from: JSONEncoder().encode(storage))
        XCTAssertEqual(roundTripped.permissionString, "---s")
    }

    func testInvalidPermissionRequestsDenyInsteadOfMatchingEverything() throws {
        let grant = Grant(keypath: "person", permission: "r---")
        let invalidRequest = Grant(keypath: "person", permission: "invalid")

        XCTAssertEqual(invalidRequest.permission.permissionString, "----")
        XCTAssertFalse(grant.granted(invalidRequest))
        XCTAssertFalse(Permission.matchPermission(permissionRequested: "invalid", permissionGranted: "r---"))
        XCTAssertFalse(Permission.matchPermission(permissionRequested: "r--q", permissionGranted: "rwxs"))
        XCTAssertFalse(Permission.matchPermission(permissionRequested: "---S", permissionGranted: "rwxs"))
    }

    func testGrantSubsetChecksIncludeOtherPermissionBits() {
        let publicRead = Grant(keypath: "state", permission: "r---")
        let latentOtherAuthority = Grant(keypath: "state", permission: "r---rwxs")
        XCTAssertFalse(publicRead.granted(latentOtherAuthority))
        XCTAssertFalse(Permission.matchPermission(
            permissionRequested: "r---rwxs",
            permissionGranted: "r---"
        ))

        let delegatedReadWrite = Grant(keypath: "state", permission: "r---rw--")
        let delegatedRead = Grant(keypath: "state", permission: "r---r---")
        XCTAssertTrue(delegatedReadWrite.granted(delegatedReadWrite))
        XCTAssertTrue(delegatedReadWrite.granted(delegatedRead))
    }

    func testAgreementSetAddsConditionWhenExistingConditionsAreEmpty() throws {
        let owner = Identity("agreement-owner-empty-conditions", displayName: "Agreement Owner", identityVault: nil)
        let agreement = Agreement(owner: owner)
        agreement.conditions = []

        let condition = GrantCondition(requestedGrant: "state", requestedPermission: "r---")
        let typedCondition = TypedCondition(type: .grant, condition: condition)
        let value = try JSONDecoder().decode(ValueType.self, from: JSONEncoder().encode(typedCondition))

        agreement.set(keypath: "conditions", value: value)

        XCTAssertEqual(agreement.conditions.count, 1)
        XCTAssertEqual(agreement.conditions.first?.uuid, condition.uuid)
    }

    func testContractSignsAgreementSnapshotAndDetectsTampering() async throws {
        let previousVault = CellBase.defaultIdentityVault
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        defer { CellBase.defaultIdentityVault = previousVault }

        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let subject = await vault.identity(for: "subject", makeNewIfNotFound: true)!
        let agreement = Agreement(owner: owner)
        agreement.addGrant("r---", for: "state")
        agreement.signatories.append(subject)
        agreement.state = .signed

        let contract = try await Contract.signed(
            agreement: agreement,
            issuer: owner,
            subject: subject,
            domain: "private"
        )

        let validSignature = await contract.verifySignature()
        XCTAssertTrue(validSignature)
        contract.agreement.addGrant("r---", for: "tampered")
        let tamperedSignature = await contract.verifySignature()
        XCTAssertFalse(tamperedSignature)
    }

    func testDecodedContractVerifiesWithoutIssuerOrGlobalVault() async throws {
        let previousVault = CellBase.defaultIdentityVault
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        defer { CellBase.defaultIdentityVault = previousVault }

        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let subject = await vault.identity(for: "subject", makeNewIfNotFound: true)!
        let agreement = Agreement(owner: owner)
        agreement.addGrant("r---", for: "state")
        agreement.signatories.append(subject)
        agreement.state = .signed
        let contract = try await Contract.signed(
            agreement: agreement,
            issuer: owner,
            subject: subject,
            domain: "private"
        )

        let decoded = try JSONDecoder().decode(
            Contract.self,
            from: JSONEncoder().encode(contract)
        )
        CellBase.defaultIdentityVault = nil

        XCTAssertNil(decoded.issuer.identityVault)
        let verified = await decoded.verifySignature()
        XCTAssertTrue(verified)
    }

    func testContractRejectsFutureExpiredOverlongAndWrongDomainBindings() async throws {
        let previousVault = CellBase.defaultIdentityVault
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        defer { CellBase.defaultIdentityVault = previousVault }

        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let subject = await vault.identity(for: "subject", makeNewIfNotFound: true)!
        let agreement = Agreement(owner: owner)
        agreement.conditions = []
        agreement.grants = [Grant(keypath: "state", permission: "r---")]
        agreement.signatories.append(subject)
        agreement.state = .signed

        let future = try await Contract.signed(
            agreement: agreement,
            issuer: owner,
            subject: subject,
            domain: "private",
            issuedAt: Date(timeIntervalSinceNow: Contract.allowedClockSkew + 1)
        )
        let futureValid = await future.verifySignature()
        XCTAssertFalse(futureValid)

        agreement.duration = 1
        let expired = try await Contract.signed(
            agreement: agreement,
            issuer: owner,
            subject: subject,
            domain: "private",
            issuedAt: Date(timeIntervalSinceNow: -2)
        )
        let expiredValid = await expired.verifySignature()
        XCTAssertFalse(expiredValid)

        agreement.duration = Int(Contract.maximumDuration) + 1
        let overlong = try await Contract.signed(
            agreement: agreement,
            issuer: owner,
            subject: subject,
            domain: "private"
        )
        let overlongValid = await overlong.verifySignature()
        XCTAssertFalse(overlongValid)

        agreement.duration = 60
        let bound = try await Contract.signed(
            agreement: agreement,
            issuer: owner,
            subject: subject,
            domain: "private"
        )
        let wrongDomainValid = await bound.verifyAuthorizationBinding(
            expectedIssuer: owner,
            expectedSubject: subject,
            expectedDomain: "other"
        )
        XCTAssertFalse(wrongDomainValid)
    }

    private func removingKeys<T: Encodable>(_ keys: [String], from value: T) throws -> Data {
        var object = try jsonObject(from: JSONEncoder().encode(value))
        for key in keys {
            object.removeValue(forKey: key)
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func jsonObject(from data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }
}
