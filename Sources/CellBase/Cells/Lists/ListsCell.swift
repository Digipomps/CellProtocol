// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// `cell:///Lists` — eier brukerens navngitte lister (handleliste, huskeliste, idéliste …).
///
/// Nøkler (uten Porthole-referanse; flaten «Mine lister» når dem som `my.lists.*`):
/// - get `lists.state` (og nestet: `lists.state.lists`, `lists.state.activeAsRows`, `lists.state.mountsById.<id>` …)
/// - set `lists.list.create|select|rename|remove|clearDone`, `lists.item.add|update|toggle|move|remove`
///
/// Mål-liste for tekst uten liste-ID (`item.add`, `list.rename`, `list.clearDone` med `true`):
/// eksplisitt `listId` → `SkeletonComponentActionContext.mount.instanceID` (montert komponent) → aktiv liste.
/// Rettigheter: eieren har `rw--` på området `lists`; alt annet avvises av GeneralCell før handleren.
/// Persistens: `persistCellSnapshot` etter hver vellykket endring; mislykkes den, står det i `notice`.
/// Kontrakt og fixtures: CellProtocolDocuments/Deliverables/PDD_lister-celle-og-komponent_2026-10-02/contract/.
public final class ListsCell: GeneralCell {
    public static let endpoint = ListsSkeletonFactory.cellEndpoint
    public static let grantArea = "lists"
    public static let unverifiedNotice = "Kunne ikke lagre siste endring (lagring ikke bekreftet). Endringen er gjort i minnet — prøv igjen."

    private let stateLock = NSLock()
    private var store: ListsStore
    private var notice: String?

    private enum CodingKeys: String, CodingKey {
        case store
        case notice
    }

    public required init(owner: Identity) async {
        self.store = ListsStore()
        self.notice = nil
        await super.init(owner: owner)
        persistancy = .persistant
        try? await ensureRuntimeReady()
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.store = try container.decodeIfPresent(ListsStore.self, forKey: .store) ?? ListsStore()
        self.notice = try container.decodeIfPresent(String.self, forKey: .notice)
        try super.init(from: decoder)
        persistancy = .persistant
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        let (snapshot, noticeSnapshot) = withState { ($0, $1) }
        try container.encode(snapshot, forKey: .store)
        try container.encodeIfPresent(noticeSnapshot, forKey: .notice)
    }

    public override func installCellRuntimeBindingsForAccess() async throws {
        agreementTemplate.ensureGrant("rw--", for: Self.grantArea)
        await registerKeys(owner: owner)
    }

    // MARK: - Lesing fra tester og verter

    /// Øyeblikksbilde av tilstanden (verdi, ikke referanse).
    public var storeSnapshot: ListsStore { withState { store, _ in store } }

    private func withState<T>(_ body: (ListsStore, String?) -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body(store, notice)
    }

    private func mutate<T>(_ body: (inout ListsStore) throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body(&store)
    }

    private static func now() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    // MARK: - Nøkler

    private func registerKeys(owner: Identity) async {
        let stateSchema = ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "schemaVersion": ExploreContract.schema(type: "string"),
                "stateVersion": ExploreContract.schema(type: "integer"),
                "activeListId": ExploreContract.oneOfSchema(options: [ExploreContract.schema(type: "string"), .null]),
                "lists": ExploreContract.listSchema(item: ExploreContract.schema(type: "object", description: "ListRow med mount")),
                "activeAsRows": ExploreContract.listSchema(item: ExploreContract.schema(type: "object", description: "ListView, 0 eller 1 rad")),
                "emptyHint": ExploreContract.listSchema(item: ExploreContract.schema(type: "object")),
                "notice": ExploreContract.listSchema(item: ExploreContract.schema(type: "object")),
                "mountsById": ExploreContract.schema(type: "object", description: "listId → SkeletonComponentMount"),
                "counts": ExploreContract.schema(type: "object")
            ],
            requiredKeys: ["status", "schemaVersion", "stateVersion", "activeListId", "lists", "activeAsRows", "emptyHint", "notice", "mountsById", "counts"],
            description: "ListsStatePayload (haven.lists.state.v1)"
        )
        let resultSchema = ExploreContract.oneOfSchema(
            options: [
                ExploreContract.objectSchema(properties: ["status": ExploreContract.schema(type: "string"), "stateVersion": ExploreContract.schema(type: "integer")], requiredKeys: ["status", "stateVersion"], description: "ok"),
                ExploreContract.objectSchema(properties: ["status": ExploreContract.schema(type: "string"), "code": ExploreContract.schema(type: "string"), "message": ExploreContract.schema(type: "string")], requiredKeys: ["status", "code", "message"], description: "error")
            ],
            description: "MutationResult"
        )
        let stringOrObject = ExploreContract.oneOfSchema(options: [ExploreContract.schema(type: "string"), ExploreContract.schema(type: "object")])
        let itemRef = ExploreContract.objectSchema(properties: ["listId": ExploreContract.schema(type: "string"), "itemId": ExploreContract.schema(type: "string")], requiredKeys: ["listId", "itemId"])

        // Rot-nøkkel: gjør `lists.state.<sti>` nåbar gjennom GeneralCells nestede oppslag.
        await registerGet(key: "lists", owner: owner, returns: ExploreContract.objectSchema(properties: ["state": stateSchema], requiredKeys: ["state"]),
                          permissions: ["r---"], description: .string("Rot for nestede oppslag: lists.state.*")) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: Self.grantArea, for: requester) else { return .string("denied") }
            return .object(["state": self.statePayload()])
        }
        await registerGet(key: "lists.state", owner: owner, returns: stateSchema, permissions: ["r---"],
                          description: .string("Brukerens lister, aktiv liste som rad, og én komponentmontering per liste.")) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: Self.grantArea, for: requester) else { return .string("denied") }
            return self.statePayload()
        }

        let setKeys: [(String, ValueType, String)] = [
            ("lists.list.create", stringOrObject, "Ny liste (string eller {title, kind}); blir aktiv."),
            ("lists.list.select", stringOrObject, "Velg aktiv liste ({listId}, string, eller List-valgpayload {selected})."),
            ("lists.list.rename", stringOrObject, "Nytt navn (string → mål-liste, eller {listId, title})."),
            ("lists.list.remove", stringOrObject, "Slett liste ({listId} eller string)."),
            ("lists.list.clearDone", ExploreContract.oneOfSchema(options: [ExploreContract.schema(type: "string"), ExploreContract.schema(type: "object"), ExploreContract.schema(type: "bool")]), "Fjern alle utførte ({listId}, string eller true → mål-liste)."),
            ("lists.item.add", stringOrObject, "Nytt punkt (string → mål-liste, eller {listId?, title})."),
            ("lists.item.update", ExploreContract.objectSchema(properties: ["listId": ExploreContract.schema(type: "string"), "itemId": ExploreContract.schema(type: "string"), "title": ExploreContract.schema(type: "string")], requiredKeys: ["listId", "itemId", "title"]), "Ny tittel på punktet."),
            ("lists.item.toggle", itemRef, "Kryss av / angre ({listId, itemId}); utførte sorteres i bunn."),
            ("lists.item.move", ExploreContract.schema(type: "object", description: "{listId, itemId, direction: up|down} eller slipp-payload {dragPayload, dropTargetPayload}"), "Flytt punkt innenfor åpen-sonen."),
            ("lists.item.remove", itemRef, "Slett punkt.")
        ]
        for (key, input, description) in setKeys {
            await registerSet(key: key, owner: owner, input: input, returns: resultSchema, permissions: ["-w--"], description: .string(description)) { [weak self] requester, payload in
                guard let self else { return .string("failure") }
                guard await self.validateAccess("-w--", at: Self.grantArea, for: requester) else { return .string("denied") }
                return await self.handle(keypath: key, payload: payload)
            }
        }
    }

    private func statePayload() -> ValueType {
        let (snapshot, noticeSnapshot) = withState { ($0, $1) }
        do {
            return try ListsPayloads.statePayload(snapshot, notice: noticeSnapshot)
        } catch {
            return ListsPayloads.error(code: "state_unavailable", message: "Kunne ikke bygge tilstanden: \(error)")
        }
    }

    // MARK: - Handlinger

    private func handle(keypath: String, payload: ValueType) async -> ValueType {
        let now = Self.now()
        let result: ValueType
        do {
            result = try mutate { store in
                switch keypath {
                case "lists.list.create":
                    let (title, kind) = try Self.parseCreate(payload)
                    let list = try store.createList(title: title, kind: kind, now: now)
                    return ListsPayloads.ok(store, extra: ["listId": .string(list.id)])
                case "lists.list.select":
                    let id = try Self.parseSelect(payload)
                    try store.selectList(id: id, now: now)
                    return ListsPayloads.ok(store)
                case "lists.list.rename":
                    let (explicitID, title) = try Self.parseTitled(payload, idKey: "listId")
                    let id = try Self.targetListID(explicit: explicitID, in: store)
                    try store.renameList(id: id, title: title, now: now)
                    return ListsPayloads.ok(store, extra: ["listId": .string(id)])
                case "lists.list.remove":
                    let id = try Self.parseListRef(payload)
                    try store.removeList(id: id, now: now)
                    return ListsPayloads.ok(store)
                case "lists.list.clearDone":
                    let id = try Self.targetListID(explicit: Self.parseOptionalListRef(payload), in: store)
                    let removed = try store.clearDone(listID: id, now: now)
                    return ListsPayloads.ok(store, extra: ["listId": .string(id), "removed": .integer(removed)])
                case "lists.item.add":
                    let (explicitID, title) = try Self.parseTitled(payload, idKey: "listId")
                    let id = try Self.targetListID(explicit: explicitID, in: store)
                    let item = try store.addItem(listID: id, title: title, now: now)
                    return ListsPayloads.ok(store, extra: ["listId": .string(id), "itemId": .string(item.id)])
                case "lists.item.update":
                    let (listID, itemID) = try Self.parseItemRef(payload)
                    guard case let .object(object) = payload, case let .string(title)? = object["title"] else {
                        throw ListsMutationError.invalidPayload("{listId, itemId, title}")
                    }
                    try store.updateItem(listID: listID, itemID: itemID, title: title, now: now)
                    return ListsPayloads.ok(store, extra: ["listId": .string(listID), "itemId": .string(itemID)])
                case "lists.item.toggle":
                    let (listID, itemID) = try Self.parseItemRef(payload)
                    let done = try store.toggleItem(listID: listID, itemID: itemID, now: now)
                    return ListsPayloads.ok(store, extra: ["listId": .string(listID), "itemId": .string(itemID), "done": .bool(done)])
                case "lists.item.move":
                    let (listID, itemID, move) = try Self.parseMove(payload)
                    try store.moveItem(listID: listID, itemID: itemID, move: move, now: now)
                    return ListsPayloads.ok(store, extra: ["listId": .string(listID), "itemId": .string(itemID)])
                case "lists.item.remove":
                    let (listID, itemID) = try Self.parseItemRef(payload)
                    try store.removeItem(listID: listID, itemID: itemID, now: now)
                    return ListsPayloads.ok(store, extra: ["listId": .string(listID), "itemId": .string(itemID)])
                default:
                    throw ListsMutationError.invalidPayload("kjent keypath")
                }
            }
        } catch let error as ListsMutationError {
            return ListsPayloads.error(error)
        } catch {
            return ListsPayloads.error(code: "invalid_payload", message: String(describing: error))
        }
        await persistAfterMutation()
        return result
    }

    private func persistAfterMutation() async {
        guard persistancy == .persistant, let resolver = CellBase.defaultCellResolver as? CellResolver else { return }
        let persisted = await resolver.persistCellSnapshot(self)
        stateLock.lock()
        notice = persisted ? nil : Self.unverifiedNotice
        stateLock.unlock()
    }

    // MARK: - Payload-tolkning (kontraktens former)

    static func targetListID(explicit: String?, in store: ListsStore) throws -> String {
        if let explicit {
            guard store.list(withID: explicit) != nil else { throw ListsMutationError.listNotFound(explicit) }
            return explicit
        }
        if let mounted = SkeletonComponentActionContext.mount?.instanceID, store.list(withID: mounted) != nil {
            return mounted
        }
        if let active = store.activeListID, store.list(withID: active) != nil {
            return active
        }
        throw ListsMutationError.noTargetList
    }

    private static func string(_ value: ValueType?) -> String? {
        if case let .string(s)? = value { return s }
        return nil
    }

    static func parseCreate(_ payload: ValueType) throws -> (String, ListsKind) {
        switch payload {
        case .string(let title):
            return (title, .custom)
        case .object(let object):
            guard let title = string(object["title"]) else { throw ListsMutationError.invalidPayload("string eller {title, kind?}") }
            let kind = string(object["kind"]).flatMap(ListsKind.init(rawValue:)) ?? .custom
            return (title, kind)
        default:
            throw ListsMutationError.invalidPayload("string eller {title, kind?}")
        }
    }

    static func parseSelect(_ payload: ValueType) throws -> String {
        switch payload {
        case .string(let id):
            return id
        case .object(let object):
            if let id = string(object["listId"]) { return id }
            if let id = string(object["selected"]) { return id }
            if case let .object(selected)? = object["selected"], let id = string(selected["id"]) { return id }
            throw ListsMutationError.invalidPayload("{listId}, string eller {selected}")
        default:
            throw ListsMutationError.invalidPayload("{listId}, string eller {selected}")
        }
    }

    static func parseListRef(_ payload: ValueType) throws -> String {
        guard let id = try parseOptionalListRef(payload) else { throw ListsMutationError.invalidPayload("{listId} eller string") }
        return id
    }

    /// `true` betyr «mål-listen» (targetListRule); string/objekt gir eksplisitt id.
    static func parseOptionalListRef(_ payload: ValueType) throws -> String? {
        switch payload {
        case .string(let id):
            return id
        case .object(let object):
            if let id = string(object["listId"]) { return id }
            throw ListsMutationError.invalidPayload("{listId}")
        case .bool(true):
            return nil
        default:
            throw ListsMutationError.invalidPayload("{listId}, string eller true")
        }
    }

    static func parseTitled(_ payload: ValueType, idKey: String) throws -> (String?, String) {
        switch payload {
        case .string(let title):
            return (nil, title)
        case .object(let object):
            guard let title = string(object["title"]) else { throw ListsMutationError.invalidPayload("string eller {\(idKey)?, title}") }
            return (string(object[idKey]), title)
        default:
            throw ListsMutationError.invalidPayload("string eller {\(idKey)?, title}")
        }
    }

    static func parseItemRef(_ payload: ValueType) throws -> (String, String) {
        guard case let .object(object) = payload, let listID = string(object["listId"]), let itemID = string(object["itemId"]) else {
            throw ListsMutationError.invalidPayload("{listId, itemId}")
        }
        return (listID, itemID)
    }

    static func parseMove(_ payload: ValueType) throws -> (String, String, ListsMove) {
        guard case let .object(object) = payload else {
            throw ListsMutationError.invalidPayload("{listId, itemId, direction} eller {dragPayload, dropTargetPayload}")
        }
        if let direction = string(object["direction"]).flatMap(ListsMoveDirection.init(rawValue:)),
           let listID = string(object["listId"]), let itemID = string(object["itemId"]) {
            return (listID, itemID, .step(direction))
        }
        if case let .object(drag)? = object["dragPayload"], case let .object(drop)? = object["dropTargetPayload"],
           let listID = string(drag["listId"]), let itemID = string(drag["itemId"]),
           let targetListID = string(drop["listId"]), let targetItemID = string(drop["itemId"]) {
            guard targetListID == listID else { throw ListsMutationError.invalidPayload("slipp innenfor samme liste") }
            return (listID, itemID, .before(targetItemID: targetItemID))
        }
        throw ListsMutationError.invalidPayload("{listId, itemId, direction} eller {dragPayload, dropTargetPayload}")
    }
}
