// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class AgreementCodingTests: XCTestCase {
    func testAgreementDecodesLegacyPayloadWithoutUUIDStateOrDuration() throws {
        let owner = Identity("agreement-owner", displayName: "Agreement Owner", identityVault: nil)
        let agreement = Agreement(owner: owner)
        let legacyData = try removingKeys(["uuid", "state", "duration"], from: agreement)

        let decoded = try JSONDecoder().decode(Agreement.self, from: legacyData)

        XCTAssertFalse(decoded.uuid.isEmpty)
        XCTAssertEqual(decoded.name, agreement.name)
        XCTAssertEqual(decoded.state, .signed)
        XCTAssertEqual(decoded.duration, 60 * 60 * 24 * 365)

        let canonicalObject = try jsonObject(from: JSONEncoder().encode(decoded))
        XCTAssertEqual(canonicalObject["state"] as? String, "signed")
        XCTAssertEqual(canonicalObject["duration"] as? Int, 60 * 60 * 24 * 365)
    }

    func testAgreementDecodesUnknownLegacyStateAsSigned() throws {
        let owner = Identity("agreement-owner-unknown-state", displayName: "Agreement Owner", identityVault: nil)
        let agreement = Agreement(owner: owner)
        var object = try jsonObject(from: JSONEncoder().encode(agreement))
        object["state"] = "accepted"

        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(Agreement.self, from: data)

        XCTAssertEqual(decoded.state, .signed)
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
