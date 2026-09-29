// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@testable import CellBase

final class BridgeResponseLifetimeTests: XCTestCase {
    private func install(_ bridge: BridgeBase, owner: Identity) async throws -> BridgeLifecycleWire {
        let wire = BridgeLifecycleWire()
        wire.channelSession = try await authenticatedSessionFixture(principal: owner)
        try await bridge.setTransport(wire, connection: .outbound)
        try bridge.activateAuthenticatedChannel()
        return wire
    }

    func testHeldAuditorGetCannotConsumeSameKeypathInRenewedBase() async throws {
        let owner = await MockIdentityVault().identity(for: "owner", makeNewIfNotFound: true)!
        let bridge = BridgeBase(owner: owner), barrier = BridgeLifecycleBarrier()
        let oldWire = try await install(bridge, owner: owner)
        let oldSent = expectation(description: "old get")
        oldWire.accepted = { if $0.command == .get { oldSent.fulfill() } }
        let oldGet = Task { try await bridge.get(keypath: "same", requester: owner) }
        await fulfillment(of: [oldSent], timeout: 2)
        let old = try XCTUnwrap(oldWire.commands.last { $0.command == .get })
        bridge.afterResponseLookup = { if $0.cid == old.cid { await barrier.hold() } }
        let stale = Task { try await bridge.consumeResponse(command: .init(cmd: "response", payload: .string("old"), cid: old.cid)) }
        await fulfillment(of: [barrier.entered], timeout: 2)
        await bridge.channelDidClose(try XCTUnwrap(oldWire.channelSession))
        do { _ = try await oldGet.value; XCTFail("Retired get succeeded") } catch {}
        let newWire = try await install(bridge, owner: owner)
        let newSent = expectation(description: "new get")
        newWire.accepted = { if $0.command == .get { newSent.fulfill() } }
        let received = ResponseLifetimeValues()
        let newGet = Task { let value = try await bridge.get(keypath: "same", requester: owner); received.append(value); return value }
        await fulfillment(of: [newSent], timeout: 2)
        let fresh = try XCTUnwrap(newWire.commands.last { $0.command == .get })
        XCTAssertNotEqual(old.cid, fresh.cid)
        await barrier.release()
        do { try await stale.value; XCTFail("Old response admitted") } catch {}
        XCTAssertTrue(received.values.isEmpty)
        XCTAssertNotNil(bridge.auditor.loadBridgeCommandForCommandId(fresh.cid))
        try await bridge.consumeResponse(command: .init(cmd: "response", payload: .string("fresh"), cid: fresh.cid))
        let value = try await newGet.value
        XCTAssertEqual(value, .string("fresh")); XCTAssertEqual(received.values, [.string("fresh")])
        await bridge.channelDidClose(try XCTUnwrap(newWire.channelSession))
    }

    func testHeldAuditorDescriptionCannotReplaceRenewedMetadataOrScope() async throws {
        let owner = await MockIdentityVault().identity(for: "owner", makeNewIfNotFound: true)!
        let bridge = BridgeBase(owner: owner), barrier = BridgeLifecycleBarrier()
        let oldWire = try await install(bridge, owner: owner)
        await bridge.sendCommand(command: .description, identity: owner, payload: nil)
        let old = try XCTUnwrap(oldWire.commands.last)
        bridge.afterResponseLookup = { if $0.cid == old.cid { await barrier.hold() } }
        func description(_ name: String) -> ValueType {
            .description(AnyCell(uuid: name, name: name, contractTemplate: Agreement(owner: owner), identityDomain: name))
        }
        let stale = Task { try await bridge.consumeResponse(command: .init(cmd: "response", payload: description("old"), cid: old.cid)) }
        await fulfillment(of: [barrier.entered], timeout: 2)
        await bridge.channelDidClose(try XCTUnwrap(oldWire.channelSession))
        let freshWire = try await install(bridge, owner: owner)
        await bridge.sendCommand(command: .description, identity: owner, payload: nil)
        let fresh = try XCTUnwrap(freshWire.commands.last)
        try await bridge.consumeResponse(command: .init(cmd: "response", payload: description("fresh"), cid: fresh.cid))
        await barrier.release()
        do { try await stale.value; XCTFail("Old description admitted") } catch {}
        XCTAssertEqual(bridge.uuid, "fresh"); XCTAssertEqual(bridge.name, "fresh"); XCTAssertEqual(bridge.identityDomain, "fresh")
        await bridge.channelDidClose(try XCTUnwrap(freshWire.channelSession))
    }

    func testHeldAuditorFeedCannotPublishIntoRenewedStream() async throws {
        let owner = await MockIdentityVault().identity(for: "owner", makeNewIfNotFound: true)!
        let bridge = BridgeBase(owner: owner), barrier = BridgeLifecycleBarrier()
        let oldWire = try await install(bridge, owner: owner)
        let oldSubscription = try await bridge.flow(requester: owner).sink(receiveCompletion: { _ in }, receiveValue: { _ in })
        let old = try XCTUnwrap(oldWire.commands.last { $0.command == .feed })
        bridge.afterResponseLookup = { if $0.cid == old.cid { await barrier.hold() } }
        let stale = Task { try await bridge.consumeResponse(command: .init(cmd: "response",
            payload: .flowElement(FlowElement(title: "old", content: .string("old"), properties: .init(type: .event, contentType: .string))), cid: old.cid)) }
        await fulfillment(of: [barrier.entered], timeout: 2)
        await bridge.channelDidClose(try XCTUnwrap(oldWire.channelSession))
        let freshWire = try await install(bridge, owner: owner), received = ResponseLifetimeValues()
        let newSubscription = try await bridge.flow(requester: owner).sink(receiveCompletion: { _ in }, receiveValue: { received.append(.string($0.title ?? "")) })
        let fresh = try XCTUnwrap(freshWire.commands.last { $0.command == .feed })
        await barrier.release()
        do { try await stale.value; XCTFail("Old feed admitted") } catch {}
        XCTAssertTrue(received.values.isEmpty)
        try await bridge.consumeResponse(command: .init(cmd: "response", payload: .flowElement(FlowElement(title: "fresh", content: .string("fresh"), properties: .init(type: .event, contentType: .string))), cid: fresh.cid))
        XCTAssertEqual(received.values, [.string("fresh")])
        oldSubscription.cancel(); newSubscription.cancel()
        await bridge.channelDidClose(try XCTUnwrap(freshWire.channelSession))
    }

    func testTwoConcurrentGetsOnSamePathKeepTheirOwnCommandAndImmediateResult() async throws {
        let owner = await MockIdentityVault().identity(for: "owner", makeNewIfNotFound: true)!
        let bridge = BridgeBase(owner: owner), wire = try await install(bridge, owner: owner)
        wire.beforeAccept = { command in
            if command.command == .get {
                try await bridge.consumeResponse(command: .init(cmd: "response", payload: .integer(command.cid), cid: command.cid))
            }
        }
        async let first = bridge.get(keypath: "same", requester: owner)
        async let second = bridge.get(keypath: "same", requester: owner)
        let values = try await [first, second]
        XCTAssertEqual(Set(values.map { String(describing: $0) }).count, 2)
        XCTAssertEqual(bridge.auditor.pendingCommandCount(), 0)
        await bridge.channelDidClose(try XCTUnwrap(wire.channelSession))
    }
}

private final class ResponseLifetimeValues: @unchecked Sendable {
    private let lock = NSLock(); private var stored: [ValueType] = []
    var values: [ValueType] { lock.withLock { stored } }
    func append(_ value: ValueType) { lock.withLock { stored.append(value) } }
}
