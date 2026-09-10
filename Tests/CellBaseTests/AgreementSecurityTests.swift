// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class AgreementSecurityTests: XCTestCase {
    func testIdentityGrantRequiresRequestedPermissionBits() async {
        let identity = Identity()
        identity.grants = [Grant(keypath: "displayName", permission: "r---")]
        XCTAssertTrue(identity.granted(Grant(keypath: "displayName", permission: "r---")))
        for requested in ["-w--", "--x-", "---s", "rw--", "r---r---"] {
            XCTAssertFalse(identity.granted(Grant(keypath: "displayName", permission: requested)), requested)
        }
        let condition = GrantCondition(requestedGrant: "identity.displayName", requestedPermission: "rw--")
        let state = await condition.isMet(context: .init(source: nil, target: nil, identity: identity))
        XCTAssertNotEqual(state, .met)
    }

    func testTargetNameNeverProvesMembershipAndEmptyGrantDoesNotTrap() async {
        let owner = Identity()
        let target = await GeneralCell(owner: owner)
        for path in ["target.isMember", "target.notisMember", "target.private.isMember", "source.isMember", "", ".", "..."] {
            let condition = GrantCondition(requestedGrant: path, requestedPermission: "r---")
            let state = await condition.isMet(context: .init(source: target, target: target, identity: owner))
            XCTAssertNotEqual(state, .met, path)
        }
    }

    func testMalformedOrUnknownConditionsCannotDecodeAsUnconditionalAgreement() throws {
        let agreement = Agreement(owner: Identity())
        let bytes = try JSONEncoder().encode(agreement)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let typed = try XCTUnwrap((object["conditions"] as? [[String: Any]])?.first)
        let valid = try JSONDecoder().decode(Agreement.self, from: bytes)
        XCTAssertEqual(valid.conditions.count, 1)
        var unknown = typed
        unknown["type"] = "futureCondition"
        var missingType = typed
        missingType.removeValue(forKey: "type")
        var malformedBody = typed
        malformedBody["condition"] = ["not": "a condition"]
        for invalid: Any in [NSNull(), "invalid", [unknown], [missingType], [malformedBody], [typed, unknown]] {
            object["conditions"] = invalid
            let invalidBytes = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(Agreement.self, from: invalidBytes))
        }
        // Existing writers omit an empty list. Absence remains compatible.
        object.removeValue(forKey: "conditions")
        let absent = try JSONDecoder().decode(Agreement.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(absent.conditions.isEmpty)
        object["conditions"] = []
        let empty = try JSONDecoder().decode(Agreement.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(empty.conditions.isEmpty)
    }
}
