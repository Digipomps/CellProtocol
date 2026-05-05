// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class IdentityAgreementTests: XCTestCase {
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

    func testIdentitySignAndVerify() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let identity = await vault.identity(for: "private", makeNewIfNotFound: true)!

        let message = Data("hello".utf8)
        let signature = try await identity.sign(data: message)
        XCTAssertNotNil(signature)

        let verified = await identity.verify(signature: signature!, for: message)
        XCTAssertTrue(verified)
    }

    func testAgreementEncodesAndDecodesConditions() throws {
        let owner = TestFixtures.makeIdentity(displayName: "owner")
        let agreement = Agreement(owner: owner)
        try agreement.addCondition(LookupCondition(keypath: "identity.flag", expectedValue: .bool(true)))

        let data = try JSONEncoder().encode(agreement)
        let decoded = try JSONDecoder().decode(Agreement.self, from: data)

        XCTAssertGreaterThan(decoded.conditions.count, 0)
        XCTAssertTrue(decoded.conditions.contains(where: { $0 is GrantCondition }))
        XCTAssertTrue(decoded.conditions.contains(where: { $0 is LookupCondition }))
    }

    func testGrantConditionMetForIdentityGrant() async {
        let identity = TestFixtures.makeIdentity(displayName: "user")
        let condition = GrantCondition(requestedGrant: "identity.displayName", requestedPermission: "r--")
        let context = ConnectContext(source: nil, target: nil, identity: identity)

        let state = await condition.isMet(context: context)
        XCTAssertEqual(state, .met)
    }

    func testConditionalEngagementReturnsEngageWhenUnresolved() async {
        let identity = TestFixtures.makeIdentity(displayName: "user")
        let condition = ConditionalEngagement()
        let context = ConnectContext(source: nil, target: nil, identity: identity)

        let state = await condition.isMet(context: context)
        XCTAssertEqual(state, .engage)
    }

    func testConditionalEngagementProvidesConnectChallengeDescriptor() async {
        let identity = TestFixtures.makeIdentity(displayName: "user")
        let condition = ConditionalEngagement()
        let context = ConnectContext(source: nil, target: nil, identity: identity)

        let descriptor = await condition.connectChallengeDescriptor(context: context)
        XCTAssertNotNil(descriptor)
        XCTAssertEqual(descriptor?.reasonCode, "conditional_engagement_unresolved")
        XCTAssertEqual(descriptor?.requiredAction, "open_helper_configuration")
        XCTAssertNotNil(descriptor?.helperCellConfiguration)
    }

    func testLookupConditionMetViaIdentityGet() async throws {
        let vault = MockIdentityVault()
        let resolver = MockCellResolver()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver

        let identity = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let anchor = TestEmitCell(owner: identity, uuid: "entity-anchor")
        _ = try await anchor.set(keypath: "flag", value: .bool(true), requester: identity)

        try await resolver.registerNamedEmitCell(name: "EntityAnchor", emitCell: anchor, scope: .identityUnique, identity: identity)

        let condition = LookupCondition(keypath: "identity.flag", expectedValue: .bool(true))
        let context = ConnectContext(source: nil, target: nil, identity: identity)

        let state = await condition.isMet(context: context)
        XCTAssertEqual(state, .met)
    }

    func testLookupConditionMetViaTargetGet() async throws {
        let identity = TestFixtures.makeIdentity(displayName: "user")
        let target = TestEmitCell(owner: identity, uuid: "target-cell")
        _ = try await target.set(keypath: "ticketValid", value: .bool(true), requester: identity)

        let condition = LookupCondition(keypath: "target.ticketValid", expectedValue: .bool(true))
        let context = ConnectContext(source: nil, target: target, identity: identity)

        let state = await condition.isMet(context: context)
        XCTAssertEqual(state, .met)
    }

    func testLookupConditionMetViaResolverLookup() async throws {
        let vault = MockIdentityVault()
        let resolver = MockCellResolver()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver

        let identity = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = TestEmitCell(owner: identity, uuid: "resolved-cell")
        _ = try await cell.set(keypath: "ticketValid", value: .bool(true), requester: identity)
        try await resolver.registerNamedEmitCell(name: "TicketProof", emitCell: cell, scope: .identityUnique, identity: identity)

        let condition = LookupCondition(keypath: "resolve.TicketProof.ticketValid", expectedValue: .bool(true))
        let context = ConnectContext(source: nil, target: nil, identity: identity)

        let state = await condition.isMet(context: context)
        XCTAssertEqual(state, .met)
    }
}
