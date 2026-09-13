// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@_spi(HAVENRuntime) @testable import CellBase

final class ActiveFeedAuthorizationTests: XCTestCase {
    private final class Received {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ title: String) { lock.withLock { items.append(title) } }
        var titles: [String] { lock.withLock { items } }
    }

    private final class ControlledClock {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000)
        func now() -> Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
    }

    private var previousVault: IdentityVaultProtocol?
    private var previousResolver: CellResolverProtocol?
    private var previousDebug = false

    override func setUp() {
        previousVault = CellBase.defaultIdentityVault
        previousResolver = CellBase.defaultCellResolver
        previousDebug = CellBase.debugValidateAccessForEverything
        CellBase.defaultCellResolver = nil
        CellBase.debugValidateAccessForEverything = false
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.defaultCellResolver = previousResolver
        CellBase.debugValidateAccessForEverything = previousDebug
    }

    func testMemberRevocationStopsExistingFeedAndPreservesOtherReaders() async throws {
        for removeByUUID in [false, true] {
            let vault = MockIdentityVault()
            CellBase.defaultIdentityVault = vault
            let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
            let member = await vault.identity(for: "member", makeNewIfNotFound: true)!
            let other = await vault.identity(for: "other", makeNewIfNotFound: true)!
            let cell = await GeneralCell(owner: owner)
            cell.agreementTemplate.addGrant("r---", for: "feed")
            for reader in [member, other] {
                let agreement = Agreement(owner: owner)
                agreement.addGrant("r---", for: "feed")
                let state = await cell.addAgreement(agreement, for: reader, authorizedBy: owner)
                XCTAssertEqual(state, .signed)
            }
            let emitValue = await cell.makeCellOwnedFlowEmitterForRuntimeBinding(requester: owner)
            let emit = try XCTUnwrap(emitValue)
            let first = expectation(description: "all readers receive first value")
            first.expectedFulfillmentCount = 3
            let retained = expectation(description: "owner and other member retain access")
            retained.expectedFulfillmentCount = 2
            let revoked = expectation(description: "revoked stream terminates")
            let memberValues = Received()
            var subscriptions: [AnyCancellable] = []
            for reader in [owner, member, other] {
                let stream = try await cell.flow(requester: reader)
                subscriptions.append(stream.sink(receiveCompletion: { completion in
                    if reader === member {
                        if case .failure = completion { revoked.fulfill() }
                        else { XCTFail("Revocation should report denied access") }
                    } else {
                        XCTFail("Unrelated reader must remain connected")
                    }
                }, receiveValue: { element in
                    if reader === member { memberValues.append(element.title) }
                    if element.title == "before" { first.fulfill() }
                    if element.title == "after", reader !== member { retained.fulfill() }
                }))
            }
            emit(FlowElement(title: "before", content: .string("first"), properties: nil))
            await fulfillment(of: [first], timeout: 2)
            if removeByUUID { await cell.removeMember(uuid: member.uuid, requester: owner) }
            else { await cell.removeMember(member: member, requester: owner) }
            await fulfillment(of: [revoked], timeout: 1)
            emit(FlowElement(title: "after", content: .string("private update"), properties: nil))
            await fulfillment(of: [retained], timeout: 2)
            XCTAssertEqual(memberValues.titles, ["before"])
            subscriptions.forEach { $0.cancel() }
        }
    }

    func testConditionChangeStopsActiveFeedBeforeNextValue() async throws {
        let gateOwner = Identity()
        let gate = TestEmitCell(owner: gateOwner)
        _ = try await gate.set(keypath: "enabled", value: .bool(true), requester: gateOwner)
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver
        try await resolver.registerNamedEmitCell(name: "Gate", emitCell: gate, scope: .template, identity: gateOwner)
        let fixture = try await makeConditionalFeed(condition: LookupCondition(keypath: "resolve.Gate.enabled"))
        try await assertNextValueDenied(fixture) {
            _ = try await gate.set(keypath: "enabled", value: .bool(false), requester: gateOwner)
        }
    }

    func testTemplateGrantRemovalStopsActiveFeedBeforeNextValue() async throws {
        let fixture = try await makeConditionalFeed()
        try await assertNextValueDenied(fixture) { fixture.cell.agreementTemplate.grants = [] }
    }

    func testContractExpiryStopsActiveFeedBeforeNextValue() async throws {
        let clock = ControlledClock()
        let fixture = try await makeConditionalFeed(duration: 5, clock: clock)
        try await assertNextValueDenied(fixture) { clock.advance(6) }
        do {
            _ = try await fixture.cell.flow(requester: fixture.member)
            XCTFail("An expired grant must not reopen a stream")
        } catch StreamState.denied {}
        let renewed = Agreement(owner: fixture.owner)
        renewed.duration = 5
        renewed.addGrant("r---", for: "feed")
        let renewal = await fixture.cell.addAgreement(renewed, for: fixture.member, authorizedBy: fixture.owner)
        XCTAssertEqual(renewal, .signed)
        let delivered = expectation(description: "new authorization allows a new stream")
        let stream = try await fixture.cell.flow(requester: fixture.member)
        let subscription = stream.sink(receiveCompletion: { _ in }, receiveValue: { _ in delivered.fulfill() })
        fixture.emit(FlowElement(title: "renewed", content: .string("renewed"), properties: nil))
        await fulfillment(of: [delivered], timeout: 2)
        subscription.cancel()
    }

    private struct FeedFixture {
        let cell: GeneralCell
        let owner: Identity
        let member: Identity
        let emit: (FlowElement) -> Void
    }

    private func makeConditionalFeed(duration: Int = 3_600, condition: LookupCondition? = nil, clock: ControlledClock? = nil) async throws -> FeedFixture {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let member = await vault.identity(for: "member", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        if let clock { cell.authorizationClock = clock.now }
        cell.agreementTemplate.addGrant("r---", for: "feed")
        let agreement = Agreement(owner: owner)
        agreement.duration = duration
        agreement.addGrant("r---", for: "feed")
        if let condition {
            try cell.agreementTemplate.addCondition(condition)
            try agreement.addCondition(condition)
        }
        let state = await cell.addAgreement(agreement, for: member, authorizedBy: owner)
        XCTAssertEqual(state, .signed)
        let emitValue = await cell.makeCellOwnedFlowEmitterForRuntimeBinding(requester: owner)
        return FeedFixture(cell: cell, owner: owner, member: member, emit: try XCTUnwrap(emitValue))
    }

    private func assertNextValueDenied(_ fixture: FeedFixture, change: () async throws -> Void) async throws {
        let first = expectation(description: "valid feed delivers")
        let denied = expectation(description: "feed loses authorization")
        let received = Received()
        let publisher = try await fixture.cell.flow(requester: fixture.member)
        let subscription = publisher.sink(receiveCompletion: { completion in
            if case .failure = completion { denied.fulfill() }
        }, receiveValue: { element in
            received.append(element.title)
            if element.title == "before" { first.fulfill() }
        })
        fixture.emit(FlowElement(title: "before", content: .string("first"), properties: nil))
        await fulfillment(of: [first], timeout: 2)
        try await change()
        fixture.emit(FlowElement(title: "after", content: .string("private update"), properties: nil))
        await fulfillment(of: [denied], timeout: 2)
        XCTAssertEqual(received.titles, ["before"])
        subscription.cancel()
    }

    func testPublisherObtainedBeforeRevocationCannotBeSubscribedAfterwardToBypassIt() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let member = await vault.identity(for: "member", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        cell.agreementTemplate.addGrant("r---", for: "feed")
        let agreement = Agreement(owner: owner)
        agreement.addGrant("r---", for: "feed")
        let state = await cell.addAgreement(agreement, for: member, authorizedBy: owner)
        XCTAssertEqual(state, .signed)
        let publisher = try await cell.flow(requester: member)
        await cell.removeMember(member: member, requester: owner)
        let denied = expectation(description: "stale publisher denies delivery")
        let subscription = publisher.sink(receiveCompletion: { completion in
            if case .failure = completion { denied.fulfill() }
        }, receiveValue: { _ in XCTFail("A stale publisher leaked post-revocation data") })
        let emitValue = await cell.makeCellOwnedFlowEmitterForRuntimeBinding(requester: owner)
        let emit = try XCTUnwrap(emitValue)
        emit(FlowElement(title: "after", content: .string("private update"), properties: nil))
        await fulfillment(of: [denied], timeout: 1)
        subscription.cancel()
    }
}
