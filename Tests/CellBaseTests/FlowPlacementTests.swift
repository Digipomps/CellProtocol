// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

// PDD_flow-plassering_2026-11-07, WP1.
//   T1 kilde-post   testLinkCompletionBecomesQualifiedSources …
//   T3 valg         testPlacementTable, testEachSourceAndPurposeHasOneDecision, negatives
final class FlowPlacementTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - T1: access becomes a source with a host

    private func linkCompletion(_ cells: [ValueType]) -> ValueType {
        .object([
            "status": .string("completed"),
            "record": .object(["linkID": .string("link-1")]),
            "cells": .list(cells)
        ])
    }

    private func cell(_ name: String, _ uuid: String, contract: String = "signed", endpoint: String? = nil) -> ValueType {
        .object([
            "name": .string(name),
            "uuid": .string(uuid),
            "endpoint": .string(endpoint ?? "cell:///\(uuid)"),
            "contract": .string(contract)
        ])
    }

    func testLinkCompletionBecomesQualifiedSources() throws {
        let sources = try FlowSource.sources(
            fromLinkCompletion: linkCompletion([cell("PalazzoEntity", "abc"), cell("Other", "def", contract: "rejected")]),
            host: "palazzo.digipomps.org",
            purposes: [.notify, .store],
            now: now
        )
        XCTAssertEqual(sources.count, 1, "only cells with a signed contract become sources")
        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(source.endpoint, "cell://palazzo.digipomps.org/abc")
        XCTAssertEqual(source.sourceID, source.endpoint)
        XCTAssertEqual(source.name, "PalazzoEntity")
        XCTAssertEqual(source.purposes, [.notify, .store])
        XCTAssertEqual(source.grantReference, "identityLink:link-1")
    }

    func testEndpointNamingAnotherHostIsRefused() {
        XCTAssertThrowsError(try FlowSource.sources(
            fromLinkCompletion: linkCompletion([cell("X", "abc", endpoint: "cell://evil.example/abc")]),
            host: "palazzo.digipomps.org", purposes: [.notify]
        )) { error in
            XCTAssertEqual(error as? FlowPlacementError, .hostMismatch(endpoint: "cell://evil.example/abc", host: "palazzo.digipomps.org"))
        }
    }

    func testInvalidHostAndUnqualifiedEndpointsAreRefused() {
        XCTAssertThrowsError(try FlowSource.qualify("cell:///abc", host: "palazzo.digipomps.org/x"))
        XCTAssertThrowsError(try FlowSource.qualify("cell:///abc", host: ""))
        XCTAssertThrowsError(try FlowSource.qualify("cell:///", host: "palazzo.digipomps.org"))
        XCTAssertThrowsError(try FlowSource(endpoint: "cell:///abc", purposes: [.notify]))
        XCTAssertThrowsError(try FlowSource(endpoint: "https://palazzo.digipomps.org/abc", purposes: [.notify]))
        XCTAssertThrowsError(try FlowSource(endpoint: "cell://palazzo.digipomps.org/abc", purposes: []))
    }

    // MARK: - T3: the placement rule (G1 S3)

    private func source(_ uuid: String, _ purposes: [FlowPlacementPurpose], expiresAt: Date? = nil) throws -> FlowSource {
        try FlowSource(endpoint: "cell://palazzo.digipomps.org/\(uuid)", purposes: purposes, addedAt: now, expiresAt: expiresAt)
    }

    private func venue(_ id: String, _ kind: FlowVenueKind, presenting: [String] = [], reportedSecondsAgo: TimeInterval = 10, ttl: TimeInterval = 600) throws -> FlowVenue {
        let reportedAt = now.addingTimeInterval(-reportedSecondsAgo)
        return try FlowVenue(
            venueID: id, kind: kind,
            alwaysOn: kind != .app,
            canPresent: kind == .app,
            presentingSourceIDs: presenting,
            reportedAt: reportedAt,
            expiresAt: reportedAt.addingTimeInterval(ttl)
        )
    }

    private func decision(_ decisions: [FlowPlacementDecision], _ source: FlowSource, _ purpose: FlowPlacementPurpose) -> FlowPlacementDecision? {
        decisions.first { $0.sourceID == source.sourceID && $0.purpose == purpose }
    }

    func testPlacementTable() throws {
        let s = try source("abc", [.present, .notify, .store, .agentJob])
        let phone = try venue("phone", .app, presenting: [s.sourceID])
        let ipad = try venue("ipad", .app) // not showing the surface
        let mac = try venue("mac-agent", .agent)
        let home = try venue("home", .homeScaffold)

        struct Row { let venues: [FlowVenue]; let expected: [FlowPlacementPurpose: String?] }
        let rows: [Row] = [
            Row(venues: [phone, ipad, mac, home], expected: [.present: "phone", .notify: "mac-agent", .store: "mac-agent", .agentJob: "mac-agent"]),
            Row(venues: [ipad, mac, home], expected: [.present: nil, .notify: "mac-agent", .store: "mac-agent", .agentJob: "mac-agent"]),
            Row(venues: [phone, home], expected: [.present: "phone", .notify: "home", .store: "home", .agentJob: "home"]),
            Row(venues: [phone], expected: [.present: "phone", .notify: nil, .store: nil, .agentJob: nil]),
            Row(venues: [], expected: [.present: nil, .notify: nil, .store: nil, .agentJob: nil]),
        ]
        for (index, row) in rows.enumerated() {
            let decisions = FlowPlacementPolicy.decide(sources: [s], venues: row.venues, now: now)
            for (purpose, expected) in row.expected {
                XCTAssertEqual(decision(decisions, s, purpose)?.venueID, expected, "row \(index) purpose \(purpose)")
                XCTAssertFalse(decision(decisions, s, purpose)?.reason.isEmpty ?? true, "row \(index) has a reason")
            }
        }
    }

    func testOfflineVenueIsNotChosen() throws {
        let s = try source("abc", [.notify])
        let staleAgent = try venue("mac-agent", .agent, reportedSecondsAgo: 700, ttl: 600)
        let home = try venue("home", .homeScaffold)
        let decisions = FlowPlacementPolicy.decide(sources: [s], venues: [staleAgent, home], now: now)
        XCTAssertEqual(decision(decisions, s, .notify)?.venueID, "home")
    }

    func testExpiredSourceIsNotPlaced() throws {
        let s = try source("abc", [.notify], expiresAt: now.addingTimeInterval(-1))
        let decisions = FlowPlacementPolicy.decide(sources: [s], venues: [try venue("mac-agent", .agent)], now: now)
        XCTAssertNil(decision(decisions, s, .notify)?.venueID)
    }

    func testEachSourceAndPurposeHasOneDecisionAndTiesAreStable() throws {
        let a = try source("a", [.notify, .store])
        let b = try source("b", [.notify])
        let agent1 = try venue("agent-1", .agent, reportedSecondsAgo: 5)
        let agent2 = try venue("agent-2", .agent, reportedSecondsAgo: 5)
        let agentOld = try venue("agent-0", .agent, reportedSecondsAgo: 50)
        let decisions = FlowPlacementPolicy.decide(sources: [b, a], venues: [agent2, agentOld, agent1], now: now)
        XCTAssertEqual(decisions.count, 3)
        XCTAssertEqual(Set(decisions.map { "\($0.sourceID)|\($0.purpose.rawValue)" }).count, 3, "one decision per (source, purpose)")
        XCTAssertTrue(decisions.allSatisfy { $0.venueID == "agent-1" }, "newest report wins, then lowest id")
        let again = FlowPlacementPolicy.decide(sources: [a, b], venues: [agent1, agentOld, agent2], now: now)
        XCTAssertEqual(again, decisions, "order of inputs does not change the decision")
    }

    func testUnknownPurposeAndVenueKindFailToDecode() {
        XCTAssertThrowsError(try FlowPlacementLedger.decode(.string("everything"), as: FlowPlacementPurpose.self))
        XCTAssertThrowsError(try FlowPlacementLedger.decode(.string("publisherScaffold"), as: FlowVenueKind.self))
    }

    func testVenueLifetimeIsBounded() {
        XCTAssertThrowsError(try FlowVenue(venueID: "x", kind: .agent, alwaysOn: true, canPresent: false,
            reportedAt: now, expiresAt: now.addingTimeInterval(FlowVenue.maximumLifetime + 1)))
        XCTAssertThrowsError(try FlowVenue(venueID: "x", kind: .agent, alwaysOn: true, canPresent: false,
            reportedAt: now, expiresAt: now))
        XCTAssertThrowsError(try FlowVenue(venueID: "", kind: .agent, alwaysOn: true, canPresent: false,
            reportedAt: now, expiresAt: now.addingTimeInterval(60)))
    }

    // MARK: - Ledger actions

    func testLedgerAddsReportsDecidesAndRemoves() throws {
        var book = FlowPlacementBook()
        let add: ValueType = .object([
            "linkCompletion": linkCompletion([cell("PalazzoEntity", "abc")]),
            "host": .string("palazzo.digipomps.org"),
            "purposes": .list([.string("notify")]),
            "topics": .list([.string("palazzo.entity.consent")])
        ])
        (book, _) = try FlowPlacementLedger.apply(action: FlowPlacementLedger.sourcesAdd, value: add, to: book, now: now)
        XCTAssertEqual(Array(book.sources.keys), ["cell://palazzo.digipomps.org/abc"])
        XCTAssertEqual(book.sources.values.first?.topics, ["palazzo.entity.consent"])

        let agent = try FlowPlacementLedger.encode(try venue("mac-agent", .agent, reportedSecondsAgo: 0))
        let response: ValueType
        (book, response) = try FlowPlacementLedger.apply(action: FlowPlacementLedger.venuesReport, value: agent, to: book, now: now)
        guard case let .object(object) = response, case let .list(decisions)? = object["decisions"] else {
            return XCTFail("state has decisions: \(response)")
        }
        let decoded = try FlowPlacementLedger.decode(.list(decisions), as: [FlowPlacementDecision].self)
        XCTAssertEqual(decoded.map(\.venueID), ["mac-agent"])

        (book, _) = try FlowPlacementLedger.apply(action: FlowPlacementLedger.venuesWithdraw, value: .object(["venueID": .string("mac-agent")]), to: book, now: now)
        XCTAssertTrue(book.venues.isEmpty)
        XCTAssertNil(book.decisions(at: now).first?.venueID)

        (book, _) = try FlowPlacementLedger.apply(action: FlowPlacementLedger.sourcesRemove, value: .object(["sourceID": .string("cell://palazzo.digipomps.org/abc")]), to: book, now: now)
        XCTAssertTrue(book.sources.isEmpty)
    }

    func testLedgerRefusesBadInput() throws {
        let book = FlowPlacementBook()
        // A decoded source with no host is re-validated, not trusted.
        let unqualified: ValueType = .object([
            "sourceID": .string("cell:///abc"), "endpoint": .string("cell:///abc"),
            "topics": .list([]), "purposes": .list([.string("notify")]),
            "addedAt": .string("2027-01-15T08:00:00Z")
        ])
        XCTAssertThrowsError(try FlowPlacementLedger.apply(action: FlowPlacementLedger.sourcesAdd, value: unqualified, to: book, now: now))
        XCTAssertThrowsError(try FlowPlacementLedger.apply(action: FlowPlacementLedger.sourcesRemove, value: .object(["sourceID": .string("nope")]), to: book, now: now))
        XCTAssertThrowsError(try FlowPlacementLedger.apply(action: "flowPlacement.everything", value: .null, to: book, now: now))
        // A venue that claims a lifetime past the bound is refused even when it says it reported long ago.
        let longLived: ValueType = .object([
            "venueID": .string("x"), "kind": .string("agent"), "alwaysOn": .bool(true), "canPresent": .bool(false),
            "presentingSourceIDs": .list([]),
            "reportedAt": .string("2020-01-01T00:00:00Z"),
            "expiresAt": .string("2030-01-01T00:00:00Z")
        ])
        XCTAssertThrowsError(try FlowPlacementLedger.apply(action: FlowPlacementLedger.venuesReport, value: longLived, to: book, now: now))
    }

    func testBookRoundTripsThroughValueType() throws {
        var book = FlowPlacementBook()
        let s = try source("abc", [.present, .notify])
        book.sources[s.sourceID] = s
        let v = try venue("phone", .app, presenting: [s.sourceID])
        book.venues[v.venueID] = v
        let restored = try FlowPlacementLedger.load(try FlowPlacementLedger.encode(book))
        XCTAssertEqual(restored, book)
        XCTAssertEqual(try FlowPlacementLedger.load(nil), FlowPlacementBook())
    }
}
