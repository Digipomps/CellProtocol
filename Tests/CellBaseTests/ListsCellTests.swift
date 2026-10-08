// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@testable import CellBase

/// WP2 — purpose://candidate.lister.cell (+ lists-crud, items-crud), purpose://cell.authorization-honours-keypath,
/// antiformålet not.leak-other-users, og targetListRule (valg A: SkeletonComponentActionContext).
final class ListsCellTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        super.tearDown()
    }

    private func makeCell() async -> (ListsCell, Identity, Identity) {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let other = await vault.identity(for: "someone-else", makeNewIfNotFound: true)!
        let cell = await ListsCell(owner: owner)
        return (cell, owner, other)
    }

    private func set(_ cell: ListsCell, _ keypath: String, _ value: ValueType, as requester: Identity) async throws -> Object {
        guard let response = try await cell.set(keypath: keypath, value: value, requester: requester),
              case let .object(object) = response else {
            XCTFail("forventet objektsvar fra \(keypath)")
            return [:]
        }
        return object
    }

    private func string(_ value: ValueType?) -> String? {
        if case let .string(s)? = value { return s }
        return nil
    }

    // MARK: cell.lists-crud + cell.items-crud

    func testCreateSelectRenameAddToggleRemoveThroughKeypaths() async throws {
        let (cell, owner, _) = await makeCell()

        let created = try await set(cell, "lists.list.create", .string("Handleliste"), as: owner)
        XCTAssertEqual(created["status"], .string("ok"))
        let handle = try XCTUnwrap(string(created["listId"]))
        XCTAssertEqual(string(created["activeListId"]), handle, "ny liste blir aktiv")

        let ideas = try await set(cell, "lists.list.create", .object(["title": .string("Idéer"), "kind": .string("ideas")]), as: owner)
        let ideasID = try XCTUnwrap(string(ideas["listId"]))
        XCTAssertEqual(string(ideas["activeListId"]), ideasID)

        // Rendererens valgpayload fra «liste av lister»
        let selected = try await set(cell, "lists.list.select", .object(["selectionMode": .string("single"), "trigger": .string("select"), "selectedIndex": .integer(0), "selected": .string(handle)]), as: owner)
        XCTAssertEqual(string(selected["activeListId"]), handle)

        // Tekst uten liste-ID → aktiv liste
        let added = try await set(cell, "lists.item.add", .string("Melk"), as: owner)
        XCTAssertEqual(string(added["listId"]), handle)
        let melk = try XCTUnwrap(string(added["itemId"]))
        _ = try await set(cell, "lists.item.add", .string("Brød"), as: owner)
        let toIdeas = try await set(cell, "lists.item.add", .object(["listId": .string(ideasID), "title": .string("Celle for lister")]), as: owner)
        XCTAssertEqual(string(toIdeas["listId"]), ideasID)

        let toggled = try await set(cell, "lists.item.toggle", .object(["listId": .string(handle), "itemId": .string(melk)]), as: owner)
        XCTAssertEqual(toggled["done"], .bool(true))

        let renamed = try await set(cell, "lists.list.rename", .string("Handleliste uke 41"), as: owner)
        XCTAssertEqual(string(renamed["listId"]), handle)

        let state = try await cell.get(keypath: "lists.state", requester: owner)
        XCTAssertEqual(state["status"], .string("ok"))
        XCTAssertEqual(state["activeListId"], .string(handle))
        XCTAssertEqual(state["counts"]?["lists"], .integer(2))
        XCTAssertEqual(state["counts"]?["open"], .integer(2))
        XCTAssertEqual(state["counts"]?["done"], .integer(1))
        guard case let .list(activeRows)? = state["activeAsRows"], activeRows.count == 1 else { return XCTFail("activeAsRows skal ha én rad") }
        XCTAssertEqual(activeRows[0]["title"], .string("Handleliste uke 41"))
        XCTAssertEqual(activeRows[0]["summaryText"], .string("1 igjen · 1 utført"))
        guard case let .list(items)? = activeRows[0]["items"], items.count == 2 else { return XCTFail("to punkter") }
        XCTAssertEqual(items[0]["title"], .string("Brød"), "åpent først")
        XCTAssertEqual(items[1]["done"], .bool(true), "utført i bunn")

        let removed = try await set(cell, "lists.item.remove", .object(["listId": .string(handle), "itemId": .string(melk)]), as: owner)
        XCTAssertEqual(removed["status"], .string("ok"))
        let cleared = try await set(cell, "lists.list.clearDone", .bool(true), as: owner)
        XCTAssertEqual(cleared["removed"], .integer(0))
        let removedList = try await set(cell, "lists.list.remove", .object(["listId": .string(ideasID)]), as: owner)
        XCTAssertEqual(string(removedList["activeListId"]), handle)
        XCTAssertEqual(cell.storeSnapshot.lists.count, 1)
    }

    func testNestedKeypathsResolveThroughRootIntercept() async throws {
        let (cell, owner, _) = await makeCell()
        _ = try await set(cell, "lists.list.create", .string("Huskeliste"), as: owner)
        _ = try await set(cell, "lists.item.add", .string("Ringe tannlegen"), as: owner)
        let lists = try await cell.get(keypath: "lists.state.lists", requester: owner)
        guard case let .list(rows) = lists, rows.count == 1 else { return XCTFail("lists.state.lists skal gi én rad, fikk \(lists)") }
        let id = try XCTUnwrap(string(rows[0]["id"]))
        let mount = try await cell.get(keypath: "lists.state.mountsById.\(id)", requester: owner)
        XCTAssertEqual(mount["componentID"], .string(ListsSkeletonFactory.componentID))
        let data = try JSONEncoder().encode(mount)
        let decoded = try JSONDecoder().decode(SkeletonComponentMount.self, from: data)
        XCTAssertEqual(decoded.sourceCellEndpoint, ListsSkeletonFactory.cellEndpoint)
        XCTAssertEqual(decoded.item?["id"], .string(id))
    }

    func testStructuredErrorsForBadInput() async throws {
        let (cell, owner, _) = await makeCell()
        let noList = try await set(cell, "lists.item.add", .string("Melk"), as: owner)
        XCTAssertEqual(noList["code"], .string("no_target_list"))
        _ = try await set(cell, "lists.list.create", .string("Handleliste"), as: owner)
        let blank = try await set(cell, "lists.item.add", .string("   "), as: owner)
        XCTAssertEqual(blank["status"], .string("error"))
        XCTAssertEqual(blank["code"], .string("invalid_title"))
        let unknownList = try await set(cell, "lists.item.add", .object(["listId": .string("nope"), "title": .string("x")]), as: owner)
        XCTAssertEqual(unknownList["code"], .string("list_not_found"))
        let badToggle = try await set(cell, "lists.item.toggle", .integer(42), as: owner)
        XCTAssertEqual(badToggle["code"], .string("invalid_payload"))
        let added = try await set(cell, "lists.item.add", .string("Kaffe"), as: owner)
        let kaffe = try XCTUnwrap(string(added["itemId"]))
        let listID = try XCTUnwrap(string(added["listId"]))
        _ = try await set(cell, "lists.item.toggle", .object(["listId": .string(listID), "itemId": .string(kaffe)]), as: owner)
        let moveDone = try await set(cell, "lists.item.move", .object(["listId": .string(listID), "itemId": .string(kaffe), "direction": .string("up")]), as: owner)
        XCTAssertEqual(moveDone["code"], .string("item_done_cannot_move"))
    }

    func testDropPayloadFromWebRendererMovesItem() async throws {
        let (cell, owner, _) = await makeCell()
        _ = try await set(cell, "lists.list.create", .string("Handleliste"), as: owner)
        var ids: [String] = []
        for title in ["Melk", "Brød", "Egg", "Kaffe"] {
            let added = try await set(cell, "lists.item.add", .string(title), as: owner)
            ids.append(try XCTUnwrap(string(added["itemId"])))
        }
        let listID = try XCTUnwrap(cell.storeSnapshot.activeListID)
        let drop: ValueType = .object([
            "dragRole": .string("list-item"),
            "dragPayload": .object(["listId": .string(listID), "itemId": .string(ids[1])]),
            "dropTargetRole": .string("list-item-slot"),
            "dropTargetPayload": .object(["listId": .string(listID), "itemId": .string(ids[3])]),
            "dropIntent": .string("move"),
            "modifierActive": .bool(false)
        ])
        let moved = try await set(cell, "lists.item.move", drop, as: owner)
        XCTAssertEqual(moved["status"], .string("ok"))
        XCTAssertEqual(cell.storeSnapshot.activeList?.items.map(\.id), [ids[0], ids[2], ids[1], ids[3]])
    }

    // MARK: targetListRule — valg A: monteringskontekst vinner over aktiv liste

    func testMountedComponentContextTargetsTheMountedListNotTheActiveOne() async throws {
        let (cell, owner, _) = await makeCell()
        let createdHandle = try await set(cell, "lists.list.create", .string("Handleliste"), as: owner)
        let handle = try XCTUnwrap(string(createdHandle["listId"]))
        let createdIdeas = try await set(cell, "lists.list.create", .string("Idéer"), as: owner)
        let ideas = try XCTUnwrap(string(createdIdeas["listId"]))
        _ = try await set(cell, "lists.list.select", .string(handle), as: owner)
        XCTAssertEqual(cell.storeSnapshot.activeListID, handle)

        let mount = SkeletonComponentActionMount(instanceID: ideas, componentID: ListsSkeletonFactory.componentID, revision: ListsSkeletonFactory.componentRevision)
        let response = try await SkeletonComponentActionContext.$mount.withValue(mount) {
            try await set(cell, "lists.item.add", .string("Lanes i utviklerbenken"), as: owner)
        }
        XCTAssertEqual(string(response["listId"]), ideas, "tekst i en montering går til den monterte listen")
        XCTAssertEqual(cell.storeSnapshot.list(withID: ideas)?.items.count, 1)
        XCTAssertEqual(cell.storeSnapshot.list(withID: handle)?.items.count, 0)

        let unknownMount = SkeletonComponentActionMount(instanceID: "finnes-ikke", componentID: ListsSkeletonFactory.componentID, revision: "1")
        let fallback = try await SkeletonComponentActionContext.$mount.withValue(unknownMount) {
            try await set(cell, "lists.item.add", .string("Melk"), as: owner)
        }
        XCTAssertEqual(string(fallback["listId"]), handle, "ukjent instans → aktiv liste")
    }

    // MARK: cell.authorization-honours-keypath + not.leak-other-users

    func testOtherIdentityIsDeniedOnReadAndWrite() async throws {
        let (cell, owner, other) = await makeCell()
        _ = try await set(cell, "lists.list.create", .string("Handleliste"), as: owner)

        do {
            let value = try await cell.get(keypath: "lists.state", requester: other)
            XCTAssertEqual(value, .string("denied"), "annen identitet får aldri tilstanden; fikk \(value)")
        } catch is CellAuthorizationError {
            // avvist før handleren — også riktig
        }
        do {
            let value = try await cell.set(keypath: "lists.item.add", value: .string("Melk"), requester: other)
            XCTAssertEqual(value, .string("denied"))
        } catch is CellAuthorizationError {
        }
        XCTAssertEqual(cell.storeSnapshot.activeList?.items.count, 0, "ingenting ble skrevet")
    }

    func testUnknownKeypathIsNotFoundForOwner() async throws {
        let (cell, owner, _) = await makeCell()
        do {
            let value = try await cell.get(keypath: "lists.nope", requester: owner)
            XCTFail("lists.nope skal ikke svare, fikk \(value)")
        } catch {
            // KeyValueErrors.notFound (eller nestet oppslag som feiler) — begge er «finnes ikke»
        }
        do {
            _ = try await cell.set(keypath: "lists.nope", value: .string("x"), requester: owner)
            XCTFail("set lists.nope skal ikke lykkes")
        } catch {
        }
    }

    // MARK: cell — persistens

    func testEncodeDecodeRoundTripKeepsStateByteForByte() async throws {
        let (cell, owner, _) = await makeCell()
        _ = try await set(cell, "lists.list.create", .string("Handleliste"), as: owner)
        _ = try await set(cell, "lists.item.add", .string("Melk"), as: owner)
        _ = try await set(cell, "lists.item.add", .string("Brød"), as: owner)
        let listID = try XCTUnwrap(cell.storeSnapshot.activeListID)
        let melk = try XCTUnwrap(cell.storeSnapshot.activeList?.items.first?.id)
        _ = try await set(cell, "lists.item.toggle", .object(["listId": .string(listID), "itemId": .string(melk)]), as: owner)

        let data = try JSONEncoder().encode(cell)
        let restored = try JSONDecoder().decode(ListsCell.self, from: data)
        try await restored.ensureRuntimeReady()

        XCTAssertEqual(restored.storeSnapshot, cell.storeSnapshot)
        XCTAssertEqual(restored.persistancy, .persistant)
        let beforeState = try await cell.get(keypath: "lists.state", requester: owner)
        let afterState = try await restored.get(keypath: "lists.state", requester: owner)
        let before = try canonical(beforeState)
        let after = try canonical(afterState)
        XCTAssertEqual(before, after)
    }


    // MARK: WP5 — eksport av cellens ekte tilstand til web-harnessen (images/render.js)

    /// Skriver `lists.state` for tre lister til en fil i TMPDIR og navngir den i loggen. Byggeskriptet kopierer
    /// den til `skeleton/state-fra-cellen.json`, og `images/render-wp5.js` rendrer monteringene fra den.
    func testPrintsRealStateForTheWebHarness() async throws {
        let (cell, owner, _) = await makeCell()
        let createdHandle = try await set(cell, "lists.list.create", .object(["title": .string("Handleliste"), "kind": .string("shopping")]), as: owner)
        let handle = try XCTUnwrap(string(createdHandle["listId"]))
        for title in ["Melk", "Brød", "Egg", "Kaffe", "Smør", "Pasta"] {
            _ = try await set(cell, "lists.item.add", .object(["listId": .string(handle), "title": .string(title)]), as: owner)
        }
        let handleItems = try XCTUnwrap(cell.storeSnapshot.list(withID: handle)?.items.map(\.id))
        _ = try await set(cell, "lists.item.toggle", .object(["listId": .string(handle), "itemId": .string(handleItems[4])]), as: owner)
        _ = try await set(cell, "lists.item.toggle", .object(["listId": .string(handle), "itemId": .string(handleItems[5])]), as: owner)
        let createdHuske = try await set(cell, "lists.list.create", .object(["title": .string("Huskeliste"), "kind": .string("reminders")]), as: owner)
        let huske = try XCTUnwrap(string(createdHuske["listId"]))
        for title in ["Ringe tannlegen", "Levere pakke på posten", "Bestille vinterdekk"] {
            _ = try await set(cell, "lists.item.add", .object(["listId": .string(huske), "title": .string(title)]), as: owner)
        }
        let huskeItems = try XCTUnwrap(cell.storeSnapshot.list(withID: huske)?.items.map(\.id))
        _ = try await set(cell, "lists.item.toggle", .object(["listId": .string(huske), "itemId": .string(huskeItems[2])]), as: owner)
        let createdIdeer = try await set(cell, "lists.list.create", .object(["title": .string("Idéer"), "kind": .string("ideas")]), as: owner)
        let ideer = try XCTUnwrap(string(createdIdeer["listId"]))
        for title in ["Celle for lister som kan dras inn hvor som helst", "Palazzo: ukens Sicilia-artikkel"] {
            _ = try await set(cell, "lists.item.add", .object(["listId": .string(ideer), "title": .string(title)]), as: owner)
        }
        _ = try await set(cell, "lists.list.select", .string(handle), as: owner)
        let state = try await cell.get(keypath: "lists.state", requester: owner)
        XCTAssertEqual(state["counts"]?["lists"], .integer(3))
        // Samme form som Porthole web legger i bootstrap.state: referansen `my` → cellens `lists`-rot.
        let rootData: ValueType = .object(["my": .object(["lists": .object(["state": state])])])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(rootData)
        // Til fil, ikke stdout: XCTests egen logging flettes inn i stdout og ødela JSON-en (sett 08.10).
        let exportURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lists-state-export.json")
        try data.write(to: exportURL, options: .atomic)
        print("===LISTS-STATE-FILE=== \(exportURL.path)")
    }

    private func canonical(_ value: ValueType) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
