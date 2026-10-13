// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

/// WP1 — purpose://candidate.lister.order.* (toggle, done-bottom, manual, clear-done) og payload-formen
/// skjelettet leser. Ren verdi-logikk; ingen celle.
final class ListsStoreTests: XCTestCase {
    private func makeStore() throws -> (ListsStore, String) {
        var store = ListsStore()
        let list = try store.createList(title: "Handleliste", kind: .shopping, id: "l-1", now: 1_000)
        for (index, title) in ["Melk", "Brød", "Egg", "Kaffe"].enumerated() {
            try store.addItem(listID: list.id, title: title, id: "i-\(index + 1)", now: 1_001 + index)
        }
        return (store, list.id)
    }

    private func ids(_ store: ListsStore, _ listID: String) -> [String] {
        store.list(withID: listID)!.items.map(\.id)
    }

    // MARK: order.toggle + order.done-bottom

    func testToggleMovesItemToBottomAndBackToEndOfOpenZone() throws {
        var (store, listID) = try makeStore()
        XCTAssertEqual(ids(store, listID), ["i-1", "i-2", "i-3", "i-4"])

        XCTAssertTrue(try store.toggleItem(listID: listID, itemID: "i-2", now: 2_000))
        XCTAssertEqual(ids(store, listID), ["i-1", "i-3", "i-4", "i-2"], "avkrysset faller til bunnen")
        XCTAssertEqual(store.list(withID: listID)!.items.last?.doneAtEpochMs, 2_000)

        XCTAssertTrue(try store.toggleItem(listID: listID, itemID: "i-1", now: 2_000))
        XCTAssertEqual(ids(store, listID), ["i-3", "i-4", "i-2", "i-1"], "samme millisekund: avkryssingsrekkefølgen bevares")

        XCTAssertFalse(try store.toggleItem(listID: listID, itemID: "i-2", now: 3_000))
        XCTAssertEqual(ids(store, listID), ["i-3", "i-4", "i-2", "i-1"], "angret punkt legges sist blant de åpne, foran de utførte")
        XCTAssertNil(store.list(withID: listID)!.items[2].doneAtEpochMs)
        XCTAssertTrue(store.isNormalized)
    }

    func testAddPutsNewItemLastAmongOpenItemsEvenWhenDoneItemsExist() throws {
        var (store, listID) = try makeStore()
        try store.toggleItem(listID: listID, itemID: "i-4", now: 2_000)
        try store.addItem(listID: listID, title: "Ost", id: "i-5", now: 2_100)
        XCTAssertEqual(ids(store, listID), ["i-1", "i-2", "i-3", "i-5", "i-4"])
    }

    func testBlankTitlesAreRejected() throws {
        var (store, listID) = try makeStore()
        XCTAssertThrowsError(try store.addItem(listID: listID, title: "   ", now: 5)) { error in
            XCTAssertEqual(error as? ListsMutationError, .invalidTitle)
        }
        XCTAssertThrowsError(try store.createList(title: "", now: 5))
        XCTAssertThrowsError(try store.renameList(id: listID, title: " ", now: 5))
        XCTAssertEqual(store.stateVersion, 5, "feil endrer ikke tilstanden")
    }

    // MARK: order.manual

    func testStepMovesStayInsideOpenZoneAndEdgesAreNoOps() throws {
        var (store, listID) = try makeStore()
        try store.moveItem(listID: listID, itemID: "i-3", move: .step(.up), now: 2_000)
        XCTAssertEqual(ids(store, listID), ["i-1", "i-3", "i-2", "i-4"])
        try store.moveItem(listID: listID, itemID: "i-1", move: .step(.up), now: 2_001)
        XCTAssertEqual(ids(store, listID), ["i-1", "i-3", "i-2", "i-4"], "øverst + opp = ingen endring, men lykkes")
        try store.toggleItem(listID: listID, itemID: "i-4", now: 2_002)
        try store.moveItem(listID: listID, itemID: "i-2", move: .step(.down), now: 2_003)
        XCTAssertEqual(ids(store, listID), ["i-1", "i-3", "i-2", "i-4"], "nederst i åpen-sonen + ned = ingen endring; utført blir liggende sist")
        XCTAssertThrowsError(try store.moveItem(listID: listID, itemID: "i-4", move: .step(.up), now: 2_004)) { error in
            XCTAssertEqual(error as? ListsMutationError, .itemDoneCannotMove("i-4"))
        }
    }

    func testDropPlacesDraggedItemBeforeTarget() throws {
        var (store, listID) = try makeStore()
        try store.moveItem(listID: listID, itemID: "i-1", move: .before(targetItemID: "i-4"), now: 2_000)
        XCTAssertEqual(ids(store, listID), ["i-2", "i-3", "i-1", "i-4"], "dratt nedover: havner foran målet")
        try store.moveItem(listID: listID, itemID: "i-4", move: .before(targetItemID: "i-2"), now: 2_001)
        XCTAssertEqual(ids(store, listID), ["i-4", "i-2", "i-3", "i-1"], "dratt oppover: havner foran målet")
        try store.moveItem(listID: listID, itemID: "i-3", move: .before(targetItemID: "i-3"), now: 2_002)
        XCTAssertEqual(ids(store, listID), ["i-4", "i-2", "i-3", "i-1"], "slipp på seg selv: ingen endring")
        try store.toggleItem(listID: listID, itemID: "i-1", now: 2_003)
        try store.moveItem(listID: listID, itemID: "i-4", move: .before(targetItemID: "i-1"), now: 2_004)
        XCTAssertEqual(ids(store, listID), ["i-2", "i-3", "i-4", "i-1"], "slipp på et utført punkt: sist blant de åpne")
    }

    // MARK: order.clear-done

    func testClearDoneRemovesOnlyDoneItems() throws {
        var (store, listID) = try makeStore()
        try store.toggleItem(listID: listID, itemID: "i-1", now: 2_000)
        try store.toggleItem(listID: listID, itemID: "i-3", now: 2_001)
        XCTAssertEqual(try store.clearDone(listID: listID, now: 2_002), 2)
        XCTAssertEqual(ids(store, listID), ["i-2", "i-4"])
        XCTAssertEqual(store.list(withID: listID)!.doneItems.count, 0)
    }

    // MARK: invariant under tilfeldige operasjoner (property-test)

    func testInvariantHoldsForRandomOperationSequences() throws {
        var generator = SeededGenerator(seed: 0x4C49_5354)   // "LIST"
        for sequence in 0..<200 {
            var store = ListsStore()
            let listID = try store.createList(title: "L\(sequence)", id: "l-\(sequence)", now: 1).id
            var nextID = 0
            var now = 10
            for _ in 0..<30 {
                now += 1
                let items = store.list(withID: listID)!.items
                let op = Int.random(in: 0..<7, using: &generator)
                do {
                    switch op {
                    case 0, 1:
                        nextID += 1
                        try store.addItem(listID: listID, title: "p\(nextID)", id: "i-\(nextID)", now: now)
                    case 2, 3:
                        if let item = items.randomElement(using: &generator) { try store.toggleItem(listID: listID, itemID: item.id, now: now) }
                    case 4:
                        if let item = items.randomElement(using: &generator) {
                            let direction: ListsMoveDirection = Bool.random(using: &generator) ? .up : .down
                            try store.moveItem(listID: listID, itemID: item.id, move: .step(direction), now: now)
                        }
                    case 5:
                        if let a = items.randomElement(using: &generator), let b = items.randomElement(using: &generator) {
                            try store.moveItem(listID: listID, itemID: a.id, move: .before(targetItemID: b.id), now: now)
                        }
                    default:
                        if Int.random(in: 0..<4, using: &generator) == 0 {
                            _ = try store.clearDone(listID: listID, now: now)
                        } else if let item = items.randomElement(using: &generator) {
                            try store.removeItem(listID: listID, itemID: item.id, now: now)
                        }
                    }
                } catch let error as ListsMutationError {
                    // Bare den ene feilen er lov i en tilfeldig sekvens: flytting av et utført punkt.
                    guard case .itemDoneCannotMove = error else { XCTFail("uventet feil \(error) i sekvens \(sequence)"); return }
                }
                let after = store.list(withID: listID)!
                XCTAssertTrue(after.isNormalized, "sekvens \(sequence): åpne først, utførte etter doneAt — \(after.items.map { "\($0.id)\($0.done ? "✓" : "")" })")
                let doneAts = after.doneItems.compactMap(\.doneAtEpochMs)
                XCTAssertEqual(doneAts, doneAts.sorted(), "utførte i avkryssingsrekkefølge")
                XCTAssertTrue(after.openItems.allSatisfy { $0.doneAtEpochMs == nil })
            }
        }
    }

    // MARK: payloads skjelettet leser

    func testItemRowCarriesEveryButtonPayloadAndDimsOnlyDoneItems() throws {
        var (store, listID) = try makeStore()
        try store.toggleItem(listID: listID, itemID: "i-2", now: 2_000)
        let list = store.list(withID: listID)!
        let open = ListsPayloads.itemRow(list.items[0], listID: listID)
        let done = ListsPayloads.itemRow(list.items.last!, listID: listID)
        for key in ["id", "title", "done", "togglePayload", "moveUpPayload", "moveDownPayload", "removePayload", "dragPayload", "dropPayload"] {
            XCTAssertNotNil(open[key], "mangler \(key)")
        }
        XCTAssertNil(open["titleColor"], "åpne punkter arver flatens farge")
        XCTAssertEqual(done["titleColor"], .string(ListsSkeletonFactory.secondaryColor))
        XCTAssertEqual(done["done"], .bool(true))
        XCTAssertEqual(open["moveUpPayload"]?["direction"], .string("up"))
        XCTAssertEqual(open["togglePayload"]?["listId"], .string(listID))
        XCTAssertEqual(open["togglePayload"]?["itemId"], .string("i-1"))
    }

    func testListViewAndStateShapes() throws {
        var (store, listID) = try makeStore()
        try store.toggleItem(listID: listID, itemID: "i-2", now: 2_000)
        let view = ListsPayloads.listView(store.list(withID: listID)!, isActive: true)
        XCTAssertEqual(view["summaryText"], .string("3 igjen · 1 utført"))
        XCTAssertEqual(view["doneRows"].flatMap { if case let .list(rows) = $0 { return rows.count } else { return nil } }, 1)
        XCTAssertEqual(view["emptyRows"].flatMap { if case let .list(rows) = $0 { return rows.count } else { return nil } }, 0)
        XCTAssertEqual(view["removeListPayload"]?["listId"], .string(listID))

        let empty = ListsPayloads.listView(ListsListRecord(id: "x", title: "Tom", createdAtEpochMs: 0, updatedAtEpochMs: 0), isActive: false)
        XCTAssertEqual(empty["summaryText"], .string("tom"))
        XCTAssertEqual(empty["emptyRows"].flatMap { if case let .list(rows) = $0 { return rows.count } else { return nil } }, 1)

        let state = try ListsPayloads.statePayload(store, notice: nil)
        for key in ["status", "cell", "schemaVersion", "stateVersion", "updatedAtEpochMs", "activeListId", "lists", "activeAsRows", "emptyHint", "notice", "mountsById", "counts"] {
            XCTAssertNotNil(state[key], "mangler \(key)")
        }
        XCTAssertEqual(state["activeListId"], .string(listID))
        XCTAssertEqual(state["counts"]?["open"], .integer(3))
        XCTAssertEqual(state["counts"]?["done"], .integer(1))
        guard case let .list(rows)? = state["lists"], case let .object(row) = rows[0], case let .object(mount)? = row["mount"] else {
            return XCTFail("lists[0].mount mangler")
        }
        XCTAssertEqual(mount["componentID"], .string(ListsSkeletonFactory.componentID))
        XCTAssertEqual(mount["revision"], .string(ListsSkeletonFactory.componentRevision))
        XCTAssertEqual(mount["sourceCellEndpoint"], .string(ListsSkeletonFactory.cellEndpoint))
        XCTAssertEqual(mount["item"]?["id"], .string(listID))
        let emptyState = try ListsPayloads.statePayload(ListsStore(), notice: "x")
        XCTAssertEqual(emptyState["emptyHint"].flatMap { if case let .list(rows) = $0 { return rows.count } else { return nil } }, 1)
        XCTAssertEqual(emptyState["notice"].flatMap { if case let .list(rows) = $0 { return rows.count } else { return nil } }, 1)
        XCTAssertEqual(emptyState["activeListId"], .null)
    }

    func testStoreCodableRoundTrip() throws {
        var (store, listID) = try makeStore()
        try store.toggleItem(listID: listID, itemID: "i-2", now: 2_000)
        let data = try JSONEncoder().encode(store)
        let restored = try JSONDecoder().decode(ListsStore.self, from: data)
        XCTAssertEqual(restored, store)
    }
}

/// Deterministisk generator så property-testen kan reproduseres.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
