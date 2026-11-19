// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

// PDD_flow-plassering_2026-11-07, WP3 + WP10 (moved from HavenAgentD).
//   T3 agent absorberer      testAttachesWhatIsPlacedHereAndAbsorbsElements
//   T3 ingen fast adresse    testEndpointComesOnlyFromTheAnchor (same test, resolver log)
//   T4 flytting              testDetachesWhenTheSourceIsRemoved
//   test.cell.auth-negative  testPublisherRefusalIsReportedAndNothingIsAbsorbed
//   anchor refusal           testRefusedVenueReportStopsTheRefresh
//   topic filter             testOnlyTheSourcesTopicsAreAbsorbed
//   T4 hjemmescaffold        testHomeScaffoldTakesOverWhenTheAgentLapsesAndBothStopOnWithdrawal
final class FlowPlacementRunnerTests: XCTestCase {
    // A vault of the test's own; the runner never reads the global one.
    private let vault: IdentityVaultProtocol = MockIdentityVault()

    /// The anchor's flowPlacement keypaths, over an in-memory book, owner only.
    private final class LedgerAnchor: Meddle, @unchecked Sendable {
        let ownerUUID: String
        private let lock = NSLock()
        private var storedBook = FlowPlacementBook()
        private var refuseReports = false

        init(ownerUUID: String) { self.ownerUUID = ownerUUID }

        var book: FlowPlacementBook { lock.withLock { storedBook } }
        func setRefuseReports(_ refuse: Bool) { lock.withLock { refuseReports = refuse } }

        func get(keypath: String, requester: Identity) async throws -> ValueType {
            guard requester.uuid == ownerUUID, keypath == FlowPlacementLedger.state else {
                return .object(["status": .string("denied")])
            }
            return try FlowPlacementLedger.stateValue(book, now: Date())
        }

        func set(keypath: String, value: ValueType, requester: Identity) async throws -> ValueType? {
            try lock.withLock {
                guard requester.uuid == ownerUUID, !(refuseReports && keypath == FlowPlacementLedger.venuesReport) else {
                    return .object(["status": .string("denied")])
                }
                let result = try FlowPlacementLedger.apply(action: keypath, value: value, to: storedBook, now: Date())
                storedBook = result.book
                return result.response
            }
        }
    }

    private actor Collected {
        var events: [FlowPlacementAbsorbedEvent] = []
        var resolved: [String] = []
        func add(_ event: FlowPlacementAbsorbedEvent) { events.append(event) }
        func resolvedEndpoint(_ endpoint: String) { resolved.append(endpoint) }
    }

    private let endpoint = "cell://palazzo.digipomps.org/abc"

    private func identity(_ name: String) async -> Identity {
        await vault.identity(for: name, makeNewIfNotFound: true)!
    }

    private func addSource(_ anchor: LedgerAnchor, owner: Identity, topics: [String] = []) async throws {
        var request: Object = [
            "linkCompletion": .object([
                "record": .object(["linkID": .string("link-1")]),
                "cells": .list([.object([
                    "name": .string("PalazzoEntity"), "uuid": .string("abc"),
                    "endpoint": .string("cell:///abc"), "contract": .string("signed")
                ])])
            ]),
            "host": .string("palazzo.digipomps.org"),
            "purposes": .list([.string("notify"), .string("store")])
        ]
        if !topics.isEmpty { request["topics"] = .list(topics.map { .string($0) }) }
        _ = try await anchor.set(keypath: FlowPlacementLedger.sourcesAdd, value: .object(request), requester: owner)
    }

    private func makeRunner(owner: Identity, anchor: LedgerAnchor, emitter: any Emit, collected: Collected,
                            venueID: String? = nil, kind: FlowVenueKind = .agent,
                            lifetime: TimeInterval = FlowPlacementRunner.defaultVenueLifetime) -> FlowPlacementRunner {
        let emitterRef = FlowPlacementCellRef<any Emit>(emitter)
        return FlowPlacementRunner(
            venueID: venueID ?? FlowPlacementRunner.venueID(forAgentIdentityUUID: owner.uuid),
            venueKind: kind,
            owner: owner,
            anchor: FlowPlacementCellRef(anchor),
            venueLifetime: lifetime,
            resolveEmitter: { endpoint, _ in
                await collected.resolvedEndpoint(endpoint)
                return emitterRef
            },
            eventSink: { event in await collected.add(event) }
        )
    }

    private func waitForEvents(_ collected: Collected, count: Int) async -> [FlowPlacementAbsorbedEvent] {
        for _ in 0..<100 {
            let events = await collected.events
            if events.count >= count { return events }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await collected.events
    }

    private func element(_ title: String, topic: String) -> FlowElement {
        FlowElement(title: title, content: .string("payload"), properties: .init(type: .event, contentType: .string))
            .withTopic(topic)
    }

    func testAttachesWhatIsPlacedHereAndAbsorbsElements() async throws {
        let owner = await identity("agent-owner")
        let anchor = LedgerAnchor(ownerUUID: owner.uuid)
        try await addSource(anchor, owner: owner)
        let publisher = FlowElementPusherCell(owner: owner)
        let collected = Collected()
        let runner = makeRunner(owner: owner, anchor: anchor, emitter: publisher, collected: collected)

        let summary = try await runner.refresh()
        XCTAssertEqual(summary.attached, [endpoint])
        XCTAssertEqual(summary.placedHere[endpoint], ["notify", "store"])
        XCTAssertTrue(summary.failed.isEmpty, "\(summary.failed)")
        let resolved = await collected.resolved
        XCTAssertEqual(resolved, [endpoint], "the only endpoint used is the one the anchor holds")
        publisher.pushFlowElement(element("hello", topic: "palazzo.guest"), requester: owner)
        let events = await waitForEvents(collected, count: 1)
        XCTAssertEqual(events.map(\.title), ["hello"])
        XCTAssertEqual(events.first?.sourceID, endpoint)
        XCTAssertEqual(events.first?.purposes, ["notify", "store"])
        // A second refresh keeps the attachment instead of attaching again.
        let again = try await runner.refresh()
        XCTAssertEqual(again.kept, [endpoint])
        XCTAssertTrue(again.attached.isEmpty)
        let resolvedAgain = await collected.resolved
        XCTAssertEqual(resolvedAgain.count, 1)
        await runner.withdraw()
    }

    func testDetachesWhenTheSourceIsRemoved() async throws {
        let owner = await identity("agent-owner")
        let anchor = LedgerAnchor(ownerUUID: owner.uuid)
        try await addSource(anchor, owner: owner)
        let publisher = FlowElementPusherCell(owner: owner)
        let collected = Collected()
        let runner = makeRunner(owner: owner, anchor: anchor, emitter: publisher, collected: collected)
        _ = try await runner.refresh()

        _ = try await anchor.set(keypath: FlowPlacementLedger.sourcesRemove,
            value: .object(["sourceID": .string(endpoint)]), requester: owner)
        let summary = try await runner.refresh()
        XCTAssertEqual(summary.detached, [endpoint])
        let attached = await runner.attachedSourceIDs()
        XCTAssertTrue(attached.isEmpty)
        publisher.pushFlowElement(element("late", topic: "palazzo.guest"), requester: owner)
        try await Task.sleep(nanoseconds: 200_000_000)
        let events = await collected.events
        XCTAssertTrue(events.isEmpty, "a detached source still delivered \(events.map(\.title))")
    }

    func testPublisherRefusalIsReportedAndNothingIsAbsorbed() async throws {
        let owner = await identity("agent-owner")
        let stranger = await identity("publisher-owner")
        let anchor = LedgerAnchor(ownerUUID: owner.uuid)
        try await addSource(anchor, owner: owner)
        let publisher = await GeneralCell(owner: stranger)
        let collected = Collected()
        let runner = makeRunner(owner: owner, anchor: anchor, emitter: publisher, collected: collected)

        let summary = try await runner.refresh()
        XCTAssertTrue(summary.attached.isEmpty, "a publisher with no agreement admitted the agent")
        XCTAssertEqual(summary.failed.map(\.sourceID), [endpoint])
        let attached = await runner.attachedSourceIDs()
        XCTAssertTrue(attached.isEmpty)
    }

    func testRefusedVenueReportStopsTheRefresh() async throws {
        let owner = await identity("agent-owner")
        let anchor = LedgerAnchor(ownerUUID: owner.uuid)
        try await addSource(anchor, owner: owner)
        anchor.setRefuseReports(true)
        let collected = Collected()
        let runner = makeRunner(owner: owner, anchor: anchor, emitter: FlowElementPusherCell(owner: owner), collected: collected)

        do {
            _ = try await runner.refresh()
            XCTFail("refresh should have thrown")
        } catch {
            XCTAssertEqual(error as? FlowPlacementRunnerError, FlowPlacementRunnerError.reportRefused("denied"))
        }
        let resolved = await collected.resolved
        XCTAssertTrue(resolved.isEmpty)
    }

    func testOnlyTheSourcesTopicsAreAbsorbed() async throws {
        let owner = await identity("agent-owner")
        let anchor = LedgerAnchor(ownerUUID: owner.uuid)
        try await addSource(anchor, owner: owner, topics: ["palazzo.guest"])
        let publisher = FlowElementPusherCell(owner: owner)
        let collected = Collected()
        let runner = makeRunner(owner: owner, anchor: anchor, emitter: publisher, collected: collected)
        _ = try await runner.refresh()

        publisher.pushFlowElement(element("other", topic: "palazzo.kitchen"), requester: owner)
        publisher.pushFlowElement(element("mine", topic: "palazzo.guest"), requester: owner)
        let events = await waitForEvents(collected, count: 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        let all = await collected.events
        XCTAssertEqual(events.first?.title, "mine")
        XCTAssertEqual(all.map(\.title), ["mine"])
        await runner.withdraw()
    }

    func testStatusChangesNothing() async throws {
        let owner = await identity("agent-owner")
        let anchor = LedgerAnchor(ownerUUID: owner.uuid)
        try await addSource(anchor, owner: owner)
        let collected = Collected()
        let runner = makeRunner(owner: owner, anchor: anchor, emitter: FlowElementPusherCell(owner: owner), collected: collected)

        let summary = try await runner.status()
        XCTAssertTrue(summary.placedHere.isEmpty, "nothing is placed on a venue that has not reported")
        XCTAssertEqual(summary.unplaced.count, 2)
        let venues = anchor.book.venues
        XCTAssertTrue(venues.isEmpty, "status reported a venue")
        let resolved = await collected.resolved
        XCTAssertTrue(resolved.isEmpty)
    }

    // T4 (WP10): the agent and the entity's home scaffold report to the same
    // anchor. While the agent is on, it holds the source; once it stops
    // reporting and its venue lapses, the home scaffold's next refresh attaches
    // and receives. Withdrawing the access detaches both.
    func testHomeScaffoldTakesOverWhenTheAgentLapsesAndBothStopOnWithdrawal() async throws {
        let owner = await identity("entity-owner")
        let anchor = LedgerAnchor(ownerUUID: owner.uuid)
        try await addSource(anchor, owner: owner)
        let publisher = FlowElementPusherCell(owner: owner)
        let agentEvents = Collected()
        let homeEvents = Collected()
        let agent = makeRunner(owner: owner, anchor: anchor, emitter: publisher, collected: agentEvents,
            venueID: "haven-agentd:test", kind: .agent, lifetime: 1)
        let home = makeRunner(owner: owner, anchor: anchor, emitter: publisher, collected: homeEvents,
            venueID: FlowPlacementRunner.venueID(forHomeScaffoldIdentityUUID: owner.uuid), kind: .homeScaffold)

        let agentFirst = try await agent.refresh()
        let homeFirst = try await home.refresh()
        XCTAssertEqual(agentFirst.attached, [endpoint])
        XCTAssertTrue(homeFirst.attached.isEmpty, "the home scaffold attached while the agent was on")
        XCTAssertEqual(homeFirst.placedElsewhere, 2)

        // The agent is switched off: it stops refreshing, and its 1 s venue lapses.
        try await Task.sleep(nanoseconds: 1_300_000_000)
        let homeAfter = try await home.refresh()
        XCTAssertEqual(homeAfter.attached, [endpoint], "the home scaffold takes over")
        publisher.pushFlowElement(element("while-agent-off", topic: "palazzo.guest"), requester: owner)
        let received = await waitForEvents(homeEvents, count: 1)
        XCTAssertEqual(received.map(\.title), ["while-agent-off"])

        _ = try await anchor.set(keypath: FlowPlacementLedger.sourcesRemove,
            value: .object(["sourceID": .string(endpoint)]), requester: owner)
        let homeDetached = try await home.refresh()
        XCTAssertEqual(homeDetached.detached, [endpoint])
        let agentDetached = try await agent.refresh()
        XCTAssertEqual(agentDetached.detached, [endpoint], "the agent, back on, drops its stale attachment")
        publisher.pushFlowElement(element("after-withdrawal", topic: "palazzo.guest"), requester: owner)
        try await Task.sleep(nanoseconds: 200_000_000)
        let homeAll = await homeEvents.events
        XCTAssertEqual(homeAll.map(\.title), ["while-agent-off"], "a withdrawn source still reached the home scaffold")
        await agent.withdraw()
        await home.withdraw()
    }
}

private extension FlowElement {
    func withTopic(_ topic: String) -> FlowElement {
        var copy = self
        copy.topic = topic
        return copy
    }
}
