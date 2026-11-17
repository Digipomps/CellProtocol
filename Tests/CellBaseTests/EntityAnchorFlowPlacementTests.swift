// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

// PDD_flow-plassering_2026-11-07, WP2. The entity's own anchor holds placement.
//   T2 steder              testOwnerReportsVenueAndReadsDecision
//   test.cell.auth-negative testOtherEntityAndKeylessClaimantAreRefused
//   persistence            testPlacementSurvivesRestart
// Runs against the CellApple anchor everywhere and the CellVapor anchor on macOS,
// like EntityAnchorAccessBoundaryTests: a cloud scaffold is not a weaker place.
final class EntityAnchorFlowPlacementTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousDocumentRoot: String?
    private var previousResolver: CellResolverProtocol?
    private var previousKey: Data?
    private var previousDebug = false
    private var root: URL!

    override func setUp() async throws {
        previousVault = CellBase.defaultIdentityVault
        previousDocumentRoot = CellBase.documentRootPath
        previousResolver = CellBase.defaultCellResolver
        previousKey = CellBase.persistedCellMasterKey
        previousDebug = CellBase.debugValidateAccessForEverything
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-placement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CellBase.documentRootPath = root.path
        CellBase.persistedCellMasterKey = Data(repeating: 0x5a, count: 32)
        CellBase.defaultCellResolver = MockCellResolver()
        CellBase.defaultIdentityVault = MockIdentityVault()
        CellBase.debugValidateAccessForEverything = false
    }

    override func tearDown() async throws {
        CellBase.defaultIdentityVault = previousVault
        CellBase.documentRootPath = previousDocumentRoot
        CellBase.defaultCellResolver = previousResolver
        CellBase.persistedCellMasterKey = previousKey
        CellBase.debugValidateAccessForEverything = previousDebug
        try? FileManager.default.removeItem(at: root)
    }

    private enum Scaffold: String, CaseIterable {
        case local = "CellApple"
        #if os(macOS)
        case cloud = "CellVapor"
        #endif

        func anchor(owner: Identity) async -> GeneralCell {
            switch self {
            case .local: return await AppleEntityAnchorCell(owner: owner)
            #if os(macOS)
            case .cloud: return await VaporEntityAnchorCell(owner: owner)
            #endif
            }
        }

        func restart(_ anchor: GeneralCell) throws -> GeneralCell {
            let snapshot = try JSONEncoder().encode(anchor)
            switch self {
            case .local: return try JSONDecoder().decode(AppleEntityAnchorCell.self, from: snapshot)
            #if os(macOS)
            case .cloud: return try JSONDecoder().decode(VaporEntityAnchorCell.self, from: snapshot)
            #endif
            }
        }
    }

    private let endpoint = "cell://palazzo.digipomps.org/abc"

    private func addSource(_ anchor: GeneralCell, requester: Identity) async throws -> ValueType? {
        try await anchor.set(keypath: FlowPlacementLedger.sourcesAdd, value: .object([
            "linkCompletion": .object([
                "record": .object(["linkID": .string("link-1")]),
                "cells": .list([.object([
                    "name": .string("PalazzoEntity"), "uuid": .string("abc"),
                    "endpoint": .string("cell:///abc"), "contract": .string("signed")
                ])])
            ]),
            "host": .string("palazzo.digipomps.org"),
            "purposes": .list([.string("notify")])
        ]), requester: requester)
    }

    private func reportAgent(_ anchor: GeneralCell, requester: Identity) async throws -> ValueType? {
        let venue = try FlowVenue(venueID: "mac-agent", kind: .agent, alwaysOn: true, canPresent: false,
            reportedAt: Date(), expiresAt: Date().addingTimeInterval(600))
        return try await anchor.set(keypath: FlowPlacementLedger.venuesReport, value: try FlowPlacementLedger.encode(venue), requester: requester)
    }

    private func decisions(_ anchor: GeneralCell, requester: Identity) async throws -> [FlowPlacementDecision] {
        let state = try await anchor.get(keypath: FlowPlacementLedger.state, requester: requester)
        guard case let .object(object) = state, let decisions = object["decisions"] else {
            XCTFail("state is not an object: \(state)")
            return []
        }
        return try FlowPlacementLedger.decode(decisions, as: [FlowPlacementDecision].self)
    }

    private func status(_ value: ValueType?) -> String? {
        guard case let .object(object)? = value, case let .string(status)? = object["status"] else { return nil }
        return status
    }

    func testOwnerReportsVenueAndReadsDecision() async throws {
        for scaffold in Scaffold.allCases {
            let entity = await SimulatedEntity.make("A-\(scaffold.rawValue)")
            let anchor = await scaffold.anchor(owner: entity.owner)
            XCTAssertEqual(status(try await addSource(anchor, requester: entity.owner)), "stored", scaffold.rawValue)
            let before = try await decisions(anchor, requester: entity.owner)
            XCTAssertEqual(before.map(\.endpoint), [endpoint], scaffold.rawValue)
            XCTAssertEqual(before.map(\.venueID), [nil], "\(scaffold.rawValue): nothing online yet")

            XCTAssertEqual(status(try await reportAgent(anchor, requester: entity.owner)), "reported", scaffold.rawValue)
            let after = try await decisions(anchor, requester: entity.owner)
            XCTAssertEqual(after.map(\.venueID), ["mac-agent"], scaffold.rawValue)
        }
    }

    func testOtherEntityAndKeylessClaimantAreRefused() async throws {
        for scaffold in Scaffold.allCases {
            let entity = await SimulatedEntity.make("A-\(scaffold.rawValue)")
            let anchor = await scaffold.anchor(owner: entity.owner)
            _ = try await addSource(anchor, requester: entity.owner)
            let other = await SimulatedEntity.make("B")
            let claimant = SimulatedEntity.keylessClaimant(of: entity.owner)
            for intruder in [other.owner, claimant] {
                let wrote = try? await reportAgent(anchor, requester: intruder)
                XCTAssertNotEqual(status(wrote ?? nil), "reported", "\(scaffold.rawValue): an intruder reported a venue")
                let removed = try? await anchor.set(keypath: FlowPlacementLedger.sourcesRemove,
                    value: .object(["sourceID": .string(endpoint)]), requester: intruder)
                XCTAssertNotEqual(status(removed ?? nil), "removed", "\(scaffold.rawValue): an intruder removed a source")
                let read = try? await anchor.get(keypath: FlowPlacementLedger.state, requester: intruder)
                if case let .object(object)? = read {
                    XCTAssertNil(object["sources"], "\(scaffold.rawValue): an intruder read the sources")
                }
            }
            // Nothing changed for the owner.
            let decisions = try await decisions(anchor, requester: entity.owner)
            XCTAssertEqual(decisions.map(\.endpoint), [endpoint], scaffold.rawValue)
            XCTAssertEqual(decisions.map(\.venueID), [nil], scaffold.rawValue)
        }
    }

    func testPlacementSurvivesRestart() async throws {
        for scaffold in Scaffold.allCases {
            let entity = await SimulatedEntity.make("A-\(scaffold.rawValue)")
            let anchor = await scaffold.anchor(owner: entity.owner)
            _ = try await addSource(anchor, requester: entity.owner)
            _ = try await reportAgent(anchor, requester: entity.owner)
            let restarted = try scaffold.restart(anchor)
            try await restarted.installCellRuntimeBindingsForAccess()
            let decisions = try await decisions(restarted, requester: entity.owner)
            XCTAssertEqual(decisions.map(\.venueID), ["mac-agent"], scaffold.rawValue)
        }
    }
}
