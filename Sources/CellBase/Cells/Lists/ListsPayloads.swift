// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// Det cellen leverer på `lists.state`, i den formen skjelettet leser (rad-payloads for knappene,
// 0/1-rads-lister for valgfrie seksjoner, én SkeletonComponentMount per liste).
// Eksempelet som bildene ble rendret fra: PDD-mappens `skeleton/state-fylt.json`.
public enum ListsPayloads {
    public static let cellName = "Lists"

    public static func summaryText(open: Int, done: Int) -> String {
        if open == 0 && done == 0 { return "tom" }
        var parts: [String] = []
        parts.append(open > 0 ? "\(open) igjen" : "alt utført")
        if done > 0 { parts.append("\(done) utført") }
        return parts.joined(separator: " · ")
    }

    static func ref(listID: String, itemID: String? = nil, extra: Object = [:]) -> ValueType {
        var object: Object = ["listId": .string(listID)]
        if let itemID { object["itemId"] = .string(itemID) }
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }

    public static func itemRow(_ item: ListsItemRecord, listID: String) -> ValueType {
        var row: Object = [
            "id": .string(item.id),
            "title": .string(item.title),
            "done": .bool(item.done),
            "createdAtEpochMs": .integer(item.createdAtEpochMs),
            "updatedAtEpochMs": .integer(item.updatedAtEpochMs),
            "togglePayload": ref(listID: listID, itemID: item.id),
            "moveUpPayload": ref(listID: listID, itemID: item.id, extra: ["direction": .string(ListsMoveDirection.up.rawValue)]),
            "moveDownPayload": ref(listID: listID, itemID: item.id, extra: ["direction": .string(ListsMoveDirection.down.rawValue)]),
            "removePayload": ref(listID: listID, itemID: item.id),
            "dragPayload": ref(listID: listID, itemID: item.id),
            "dropPayload": ref(listID: listID, itemID: item.id)
        ]
        if let doneAt = item.doneAtEpochMs { row["doneAtEpochMs"] = .integer(doneAt) }
        if item.done { row["titleColor"] = .string(ListsSkeletonFactory.secondaryColor) }   // utførte dempes; åpne arver
        return .object(row)
    }

    /// Hele listen slik sjekkliste-skjelettet leser den (flatens `activeAsRows[0]` og monteringens `item`).
    public static func listView(_ list: ListsListRecord, isActive: Bool) -> ValueType {
        let open = list.openItems.count
        let done = list.doneItems.count
        var view: Object = [
            "id": .string(list.id),
            "title": .string(list.title),
            "kind": .string(list.kind.rawValue),
            "kindLabel": .string(list.kind.label),
            "isActive": .bool(isActive),
            "openCount": .integer(open),
            "doneCount": .integer(done),
            "summaryText": .string(summaryText(open: open, done: done)),
            "items": .list(list.items.map { itemRow($0, listID: list.id) }),
            "emptyRows": .list(list.items.isEmpty ? [.object(["text": .string("Ingen punkter ennå. Skriv noe over og trykk Enter.")])] : []),
            "doneRows": .list(done > 0 ? [.object(["id": .string("clear")])] : []),
            "removeListPayload": ref(listID: list.id),
            "clearDonePayload": ref(listID: list.id),
            "selectPayload": ref(listID: list.id)
        ]
        view["updatedAtEpochMs"] = .integer(list.updatedAtEpochMs)
        return .object(view)
    }

    public static func mount(for list: ListsListRecord, isActive: Bool) -> SkeletonComponentMount {
        ListsSkeletonFactory.componentMount(item: listView(list, isActive: isActive))
    }

    static func mountValue(for list: ListsListRecord, isActive: Bool) throws -> ValueType {
        let data = try JSONEncoder().encode(mount(for: list, isActive: isActive))
        return try JSONDecoder().decode(ValueType.self, from: data)
    }

    /// Raden i «liste av lister»: lett, men bærer monteringen så en vert kan montere hver rad.
    public static func listRow(_ list: ListsListRecord, isActive: Bool) throws -> ValueType {
        let open = list.openItems.count
        let done = list.doneItems.count
        return .object([
            "id": .string(list.id),
            "title": .string(list.title),
            "kind": .string(list.kind.rawValue),
            "isActive": .bool(isActive),
            "openCount": .integer(open),
            "doneCount": .integer(done),
            "summaryText": .string(summaryText(open: open, done: done)),
            "selectPayload": ref(listID: list.id),
            "mount": try mountValue(for: list, isActive: isActive)
        ])
    }

    public static func statePayload(_ store: ListsStore, notice: String?) throws -> ValueType {
        var mountsByID = Object()
        var rows = ValueTypeList()
        for list in store.lists {
            let isActive = list.id == store.activeListID
            rows.append(try listRow(list, isActive: isActive))
            mountsByID[list.id] = try mountValue(for: list, isActive: isActive)
        }
        let active = store.activeList.map { [listView($0, isActive: true)] } ?? []
        let openTotal = store.lists.reduce(0) { $0 + $1.openItems.count }
        let doneTotal = store.lists.reduce(0) { $0 + $1.doneItems.count }
        return .object([
            "status": .string("ok"),
            "cell": .string(cellName),
            "schemaVersion": .string(ListsStore.schemaVersion),
            "stateVersion": .integer(store.stateVersion),
            "updatedAtEpochMs": .integer(store.updatedAtEpochMs),
            "activeListId": store.activeListID.map(ValueType.string) ?? .null,
            "lists": .list(rows),
            "activeAsRows": .list(active),
            "emptyHint": .list(store.lists.isEmpty ? [.object(["text": .string("Du har ingen lister ennå. Skriv et navn over og trykk Enter.")])] : []),
            "notice": .list(notice.map { [.object(["text": .string($0)])] } ?? []),
            "mountsById": .object(mountsByID),
            "counts": .object(["lists": .integer(store.lists.count), "open": .integer(openTotal), "done": .integer(doneTotal)])
        ])
    }

    // MARK: - Svar

    public static func ok(_ store: ListsStore, extra: Object = [:]) -> ValueType {
        var object: Object = ["status": .string("ok"), "stateVersion": .integer(store.stateVersion)]
        if let active = store.activeListID { object["activeListId"] = .string(active) }
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }

    public static func error(_ error: ListsMutationError) -> ValueType {
        .object(["status": .string("error"), "code": .string(error.code), "message": .string(error.message)])
    }

    public static func error(code: String, message: String) -> ValueType {
        .object(["status": .string("error"), "code": .string(code), "message": .string(message)])
    }
}
