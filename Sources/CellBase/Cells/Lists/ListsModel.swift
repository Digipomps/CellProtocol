// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// Verdi-logikken bak `ListsCell` (cell:///Lists): brukerens navngitte lister med punkter som kan
// krysses av og flyttes. Invariant etter enhver mutasjon: `items == åpne (manuell rekkefølge)
// + utførte (doneAtEpochMs stigende)` — utførte ligger alltid i bunn, som i Apple Notater.
// Ingen celle-, resolver- eller rendereravhengigheter her; alt er testbart som rene verdier.
// Kontrakt: CellProtocolDocuments/Deliverables/PDD_lister-celle-og-komponent_2026-10-02/contract/.

public enum ListsKind: String, Codable, CaseIterable, Sendable {
    case shopping, reminders, ideas, custom

    public var label: String {
        switch self {
        case .shopping: return "Handleliste"
        case .reminders: return "Huskeliste"
        case .ideas: return "Idéliste"
        case .custom: return "Liste"
        }
    }
}

public struct ListsItemRecord: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var done: Bool
    public var createdAtEpochMs: Int
    public var updatedAtEpochMs: Int
    public var doneAtEpochMs: Int?

    public init(id: String, title: String, done: Bool = false, createdAtEpochMs: Int, updatedAtEpochMs: Int, doneAtEpochMs: Int? = nil) {
        self.id = id
        self.title = title
        self.done = done
        self.createdAtEpochMs = createdAtEpochMs
        self.updatedAtEpochMs = updatedAtEpochMs
        self.doneAtEpochMs = doneAtEpochMs
    }
}

public struct ListsListRecord: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var kind: ListsKind
    public var createdAtEpochMs: Int
    public var updatedAtEpochMs: Int
    public var items: [ListsItemRecord]

    public init(id: String, title: String, kind: ListsKind = .custom, createdAtEpochMs: Int, updatedAtEpochMs: Int, items: [ListsItemRecord] = []) {
        self.id = id
        self.title = title
        self.kind = kind
        self.createdAtEpochMs = createdAtEpochMs
        self.updatedAtEpochMs = updatedAtEpochMs
        self.items = items
    }

    public var openItems: [ListsItemRecord] { items.filter { !$0.done } }
    public var doneItems: [ListsItemRecord] { items.filter { $0.done } }

    /// Den eneste sorteringsregelen: åpne først i sin rekkefølge, så utførte etter avkryssingstid.
    public mutating func normalize() {
        let open = items.filter { !$0.done }
        let done = items.filter { $0.done }.enumerated().sorted { lhs, rhs in
            let l = lhs.element.doneAtEpochMs ?? 0
            let r = rhs.element.doneAtEpochMs ?? 0
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)
        items = open + done
    }

    public var isNormalized: Bool {
        var copy = self
        copy.normalize()
        return copy.items == items
    }
}

public enum ListsMutationError: Error, Equatable, Sendable {
    case invalidPayload(String)
    case invalidTitle
    case noTargetList
    case listNotFound(String)
    case itemNotFound(String)
    case itemDoneCannotMove(String)

    public var code: String {
        switch self {
        case .invalidPayload: return "invalid_payload"
        case .invalidTitle: return "invalid_title"
        case .noTargetList: return "no_target_list"
        case .listNotFound: return "list_not_found"
        case .itemNotFound: return "item_not_found"
        case .itemDoneCannotMove: return "item_done_cannot_move"
        }
    }

    public var message: String {
        switch self {
        case .invalidPayload(let expected): return "Forventet \(expected)."
        case .invalidTitle: return "Punktet trenger en tekst."
        case .noTargetList: return "Lag en liste først."
        case .listNotFound: return "Fant ikke listen."
        case .itemNotFound: return "Fant ikke punktet."
        case .itemDoneCannotMove: return "Utførte punkter ligger i bunn og kan ikke flyttes."
        }
    }
}

public enum ListsMoveDirection: String, Codable, Sendable {
    case up, down
}

/// Hvor et punkt skal flyttes: ett steg med pilene, eller «foran målet» fra et slipp.
public enum ListsMove: Equatable, Sendable {
    case step(ListsMoveDirection)
    case before(targetItemID: String)
}

/// Tilstanden til én brukers lister. Ren verdi; cellen holder én og persisterer den.
public struct ListsStore: Codable, Equatable, Sendable {
    public static let schemaVersion = "haven.lists.state.v1"

    public var lists: [ListsListRecord]
    public var activeListID: String?
    public var stateVersion: Int
    public var updatedAtEpochMs: Int

    public init(lists: [ListsListRecord] = [], activeListID: String? = nil, stateVersion: Int = 0, updatedAtEpochMs: Int = 0) {
        self.lists = lists
        self.activeListID = activeListID
        self.stateVersion = stateVersion
        self.updatedAtEpochMs = updatedAtEpochMs
    }

    public func list(withID id: String) -> ListsListRecord? {
        lists.first { $0.id == id }
    }

    public var activeList: ListsListRecord? {
        guard let activeListID else { return nil }
        return list(withID: activeListID)
    }

    public var isNormalized: Bool { lists.allSatisfy(\.isNormalized) }

    // MARK: - Mutasjoner (alle returnerer uten å kaste bare når invarianten holder etterpå)

    @discardableResult
    public mutating func createList(title: String, kind: ListsKind = .custom, id: String = UUID().uuidString, now: Int) throws -> ListsListRecord {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ListsMutationError.invalidTitle }
        let record = ListsListRecord(id: id, title: trimmed, kind: kind, createdAtEpochMs: now, updatedAtEpochMs: now)
        lists.append(record)
        activeListID = record.id
        bump(now)
        return record
    }

    public mutating func selectList(id: String, now: Int) throws {
        guard list(withID: id) != nil else { throw ListsMutationError.listNotFound(id) }
        activeListID = id
        bump(now)
    }

    public mutating func renameList(id: String, title: String, now: Int) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ListsMutationError.invalidTitle }
        let index = try listIndex(id)
        lists[index].title = trimmed
        lists[index].updatedAtEpochMs = now
        bump(now)
    }

    public mutating func removeList(id: String, now: Int) throws {
        let index = try listIndex(id)
        lists.remove(at: index)
        if activeListID == id { activeListID = lists.first?.id }
        bump(now)
    }

    public mutating func clearDone(listID: String, now: Int) throws -> Int {
        let index = try listIndex(listID)
        let before = lists[index].items.count
        lists[index].items.removeAll { $0.done }
        lists[index].updatedAtEpochMs = now
        bump(now)
        return before - lists[index].items.count
    }

    @discardableResult
    public mutating func addItem(listID: String, title: String, id: String = UUID().uuidString, now: Int) throws -> ListsItemRecord {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ListsMutationError.invalidTitle }
        let index = try listIndex(listID)
        let item = ListsItemRecord(id: id, title: trimmed, createdAtEpochMs: now, updatedAtEpochMs: now)
        // Nytt punkt sist blant de åpne; normalize() legger de utførte bak igjen.
        lists[index].items.append(item)
        lists[index].normalize()
        lists[index].updatedAtEpochMs = now
        bump(now)
        return item
    }

    public mutating func updateItem(listID: String, itemID: String, title: String, now: Int) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ListsMutationError.invalidTitle }
        let (l, i) = try itemIndex(listID: listID, itemID: itemID)
        lists[l].items[i].title = trimmed
        lists[l].items[i].updatedAtEpochMs = now
        lists[l].updatedAtEpochMs = now
        bump(now)
    }

    /// Avkrysset → sist i utført-sonen (doneAt = now). Angret → sist i åpen-sonen, doneAt fjernes.
    @discardableResult
    public mutating func toggleItem(listID: String, itemID: String, now: Int) throws -> Bool {
        let (l, i) = try itemIndex(listID: listID, itemID: itemID)
        var item = lists[l].items.remove(at: i)
        item.done.toggle()
        item.updatedAtEpochMs = now
        if item.done {
            // Strengt senere enn alle som alt er utført, så rekkefølgen blir avkryssingsrekkefølgen
            // selv om to avkryssinger får samme millisekund.
            let latest = lists[l].items.compactMap(\.doneAtEpochMs).max() ?? 0
            item.doneAtEpochMs = max(now, latest + 1)
            lists[l].items.append(item)
        } else {
            item.doneAtEpochMs = nil
            let firstDone = lists[l].items.firstIndex { $0.done } ?? lists[l].items.count
            lists[l].items.insert(item, at: firstDone)
        }
        lists[l].normalize()
        lists[l].updatedAtEpochMs = now
        bump(now)
        return item.done
    }

    public mutating func removeItem(listID: String, itemID: String, now: Int) throws {
        let (l, i) = try itemIndex(listID: listID, itemID: itemID)
        lists[l].items.remove(at: i)
        lists[l].updatedAtEpochMs = now
        bump(now)
    }

    /// Flytter bare innenfor åpen-sonen. Et steg i kanten er en no-op som fortsatt lykkes.
    public mutating func moveItem(listID: String, itemID: String, move: ListsMove, now: Int) throws {
        let (l, i) = try itemIndex(listID: listID, itemID: itemID)
        guard !lists[l].items[i].done else { throw ListsMutationError.itemDoneCannotMove(itemID) }
        var open = lists[l].items.filter { !$0.done }
        let done = lists[l].items.filter { $0.done }
        guard let from = open.firstIndex(where: { $0.id == itemID }) else { throw ListsMutationError.itemNotFound(itemID) }
        switch move {
        case .step(.up):
            guard from > 0 else { return }
            open.swapAt(from, from - 1)
        case .step(.down):
            guard from < open.count - 1 else { return }
            open.swapAt(from, from + 1)
        case .before(let targetID):
            guard targetID != itemID else { return }
            guard let target = open.firstIndex(where: { $0.id == targetID }) else {
                // Slipp på et utført punkt (eller ukjent): legg sist blant de åpne.
                if done.contains(where: { $0.id == targetID }) {
                    let moving = open.remove(at: from)
                    open.append(moving)
                    break
                }
                throw ListsMutationError.itemNotFound(targetID)
            }
            let moving = open.remove(at: from)
            let insertAt = from < target ? target - 1 : target
            open.insert(moving, at: insertAt)
        }
        lists[l].items = open + done
        lists[l].updatedAtEpochMs = now
        bump(now)
    }

    // MARK: - Hjelpere

    private mutating func bump(_ now: Int) {
        stateVersion += 1
        updatedAtEpochMs = now
    }

    private func listIndex(_ id: String) throws -> Int {
        guard let index = lists.firstIndex(where: { $0.id == id }) else { throw ListsMutationError.listNotFound(id) }
        return index
    }

    private func itemIndex(listID: String, itemID: String) throws -> (Int, Int) {
        let l = try listIndex(listID)
        guard let i = lists[l].items.firstIndex(where: { $0.id == itemID }) else { throw ListsMutationError.itemNotFound(itemID) }
        return (l, i)
    }
}
