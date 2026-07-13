// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

open class CalendarStoreCell: GeneralCell {
    enum CodingKeys: CodingKey {
        case generalCell
        case owner
        case collectionsByID
        case itemsByID
        case selectedOccurrenceID
        case lastImportStatus
        case lastExportStatus
    }

    private let stateQueue = DispatchQueue(label: "CellBase.CalendarStoreCell.State")
    private var collectionsByID: [String: CalendarCollection]
    private var itemsByID: [String: CalendarItem]
    private var selectedOccurrenceID: String?
    private var lastImportStatus: String
    private var lastExportStatus: String

    public required init(owner: Identity) async {
        let collection = CalendarCollection(
            id: "primary",
            name: "Primary",
            color: "#2563EB",
            visibility: "private",
            source: CalendarSource(system: "haven")
        )
        self.collectionsByID = [collection.id: collection]
        self.itemsByID = [:]
        self.selectedOccurrenceID = nil
        self.lastImportStatus = "No calendar import has run yet."
        self.lastExportStatus = "No calendar export has run yet."
        await super.init(owner: owner)
        self.identityDomain = "Calendar"
        try? await ensureRuntimeReady()
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.collectionsByID = try container.decodeIfPresent([String: CalendarCollection].self, forKey: .collectionsByID) ?? [:]
        self.itemsByID = try container.decodeIfPresent([String: CalendarItem].self, forKey: .itemsByID) ?? [:]
        self.selectedOccurrenceID = try container.decodeIfPresent(String.self, forKey: .selectedOccurrenceID)
        self.lastImportStatus = try container.decodeIfPresent(String.self, forKey: .lastImportStatus) ?? "No calendar import has run yet."
        self.lastExportStatus = try container.decodeIfPresent(String.self, forKey: .lastExportStatus) ?? "No calendar export has run yet."
        try super.init(from: decoder)
    }

    open override func installCellRuntimeBindingsForAccess() async throws {
        await setup(owner: owner)
    }

    open override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        let snapshot = stateQueue.sync {
            (
                collectionsByID: collectionsByID,
                itemsByID: itemsByID,
                selectedOccurrenceID: selectedOccurrenceID,
                lastImportStatus: lastImportStatus,
                lastExportStatus: lastExportStatus
            )
        }
        try container.encode(snapshot.collectionsByID, forKey: .collectionsByID)
        try container.encode(snapshot.itemsByID, forKey: .itemsByID)
        try container.encodeIfPresent(snapshot.selectedOccurrenceID, forKey: .selectedOccurrenceID)
        try container.encode(snapshot.lastImportStatus, forKey: .lastImportStatus)
        try container.encode(snapshot.lastExportStatus, forKey: .lastExportStatus)
    }

    private func setup(owner: Identity) async {
        for key in [
            CalendarContract.Keys.state,
            CalendarContract.Keys.collections,
            CalendarContract.Keys.items,
            CalendarContract.Keys.occurrences,
            CalendarContract.Keys.permissionStatus
        ] {
            agreementTemplate.ensureGrant("r---", for: key)
        }
        for key in [
            CalendarContract.Keys.queryOccurrences,
            CalendarContract.Keys.createItem,
            CalendarContract.Keys.updateItem,
            CalendarContract.Keys.deleteItem,
            CalendarContract.Keys.importCalendar,
            CalendarContract.Keys.exportCalendar
        ] {
            agreementTemplate.ensureGrant("rw--", for: key)
        }

        await registerGet(
            key: CalendarContract.Keys.state,
            owner: owner,
            returns: CalendarContract.stateSchemaDescriptor(),
            permissions: ["r---"],
            required: true,
            description: .string("Returns canonical calendar store state and a portable calendar visualization spec.")
        ) { requester in
            guard await self.validateAccess("r---", at: CalendarContract.Keys.state, for: requester) else { return .string("denied") }
            return .object(self.stateObject())
        }

        await registerGet(
            key: CalendarContract.Keys.collections,
            owner: owner,
            returns: ExploreContract.listSchema(item: CalendarContract.collectionSchemaDescriptor()),
            permissions: ["r---"],
            required: true,
            description: .string("Returns canonical calendar collections.")
        ) { requester in
            guard await self.validateAccess("r---", at: CalendarContract.Keys.collections, for: requester) else { return .string("denied") }
            return .list(self.orderedCollections().map { .object($0.asObject()) })
        }

        await registerGet(
            key: CalendarContract.Keys.items,
            owner: owner,
            returns: ExploreContract.listSchema(item: CalendarContract.itemSchemaDescriptor()),
            permissions: ["r---"],
            required: true,
            description: .string("Returns canonical calendar items.")
        ) { requester in
            guard await self.validateAccess("r---", at: CalendarContract.Keys.items, for: requester) else { return .string("denied") }
            return .list(self.orderedItems().map { .object($0.asObject()) })
        }

        await registerGet(
            key: CalendarContract.Keys.occurrences,
            owner: owner,
            returns: ExploreContract.listSchema(item: CalendarContract.occurrenceSchemaDescriptor()),
            permissions: ["r---"],
            required: true,
            description: .string("Returns expanded calendar occurrences for the default window.")
        ) { requester in
            guard await self.validateAccess("r---", at: CalendarContract.Keys.occurrences, for: requester) else { return .string("denied") }
            let window = Self.defaultWindow(now: Date())
            return .list(self.occurrences(start: window.start, end: window.end).map { .object($0.asObject()) })
        }

        await registerGet(
            key: CalendarContract.Keys.permissionStatus,
            owner: owner,
            returns: Self.permissionStatusSchema(),
            permissions: ["r---"],
            required: true,
            description: .string("Returns non-native calendar store permission status.")
        ) { requester in
            guard await self.validateAccess("r---", at: CalendarContract.Keys.permissionStatus, for: requester) else { return .string("denied") }
            return .object(Self.localPermissionStatus())
        }

        await registerSet(
            key: CalendarContract.Keys.queryOccurrences,
            owner: owner,
            input: CalendarContract.queryInputSchemaDescriptor(),
            returns: CalendarContract.stateSchemaDescriptor(),
            permissions: ["-w--"],
            required: true,
            description: .string("Queries expanded calendar occurrences for an explicit range.")
        ) { requester, payload in
            guard await self.validateAccess("rw--", at: CalendarContract.Keys.queryOccurrences, for: requester) else { return .string("denied") }
            return .object(self.queryOccurrencesObject(payload: payload))
        }

        await registerSet(
            key: CalendarContract.Keys.createItem,
            owner: owner,
            input: CalendarContract.itemSchemaDescriptor(),
            returns: CalendarContract.mutationResultSchemaDescriptor(),
            permissions: ["-w--"],
            required: true,
            flowEffects: [ExploreContract.flowEffect(trigger: .set, topic: CalendarContract.flowTopic, contentType: "object")],
            description: .string("Creates a canonical calendar item.")
        ) { requester, payload in
            guard await self.validateAccess("rw--", at: CalendarContract.Keys.createItem, for: requester) else { return .string("denied") }
            return await self.createItem(payload: payload, requester: requester)
        }

        await registerSet(
            key: CalendarContract.Keys.updateItem,
            owner: owner,
            input: CalendarContract.itemSchemaDescriptor(),
            returns: CalendarContract.mutationResultSchemaDescriptor(),
            permissions: ["-w--"],
            required: true,
            flowEffects: [ExploreContract.flowEffect(trigger: .set, topic: CalendarContract.flowTopic, contentType: "object")],
            description: .string("Updates or replaces a canonical calendar item.")
        ) { requester, payload in
            guard await self.validateAccess("rw--", at: CalendarContract.Keys.updateItem, for: requester) else { return .string("denied") }
            return await self.updateItem(payload: payload, requester: requester)
        }

        await registerSet(
            key: CalendarContract.Keys.deleteItem,
            owner: owner,
            input: ExploreContract.oneOfSchema(options: [ExploreContract.schema(type: "string"), ExploreContract.objectSchema(properties: ["id": ExploreContract.schema(type: "string")])]),
            returns: CalendarContract.mutationResultSchemaDescriptor(),
            permissions: ["-w--"],
            required: true,
            flowEffects: [ExploreContract.flowEffect(trigger: .set, topic: CalendarContract.flowTopic, contentType: "object")],
            description: .string("Deletes a canonical calendar item by id.")
        ) { requester, payload in
            guard await self.validateAccess("rw--", at: CalendarContract.Keys.deleteItem, for: requester) else { return .string("denied") }
            return await self.deleteItem(payload: payload, requester: requester)
        }

        await registerSet(
            key: CalendarContract.Keys.importCalendar,
            owner: owner,
            input: Self.importSchema(),
            returns: CalendarContract.mutationResultSchemaDescriptor(),
            permissions: ["-w--"],
            required: true,
            flowEffects: [ExploreContract.flowEffect(trigger: .set, topic: CalendarContract.flowTopic, contentType: "object")],
            description: .string("Imports ICS or JSCalendar text into the calendar store.")
        ) { requester, payload in
            guard await self.validateAccess("rw--", at: CalendarContract.Keys.importCalendar, for: requester) else { return .string("denied") }
            return await self.importCalendar(payload: payload, requester: requester)
        }

        await registerSet(
            key: CalendarContract.Keys.exportCalendar,
            owner: owner,
            input: Self.exportSchema(),
            returns: Self.exportResultSchema(),
            permissions: ["-w--"],
            required: true,
            description: .string("Exports selected or all calendar items as ICS or JSCalendar.")
        ) { requester, payload in
            guard await self.validateAccess("rw--", at: CalendarContract.Keys.exportCalendar, for: requester) else { return .string("denied") }
            return self.exportCalendar(payload: payload)
        }
    }

    private func orderedCollections() -> [CalendarCollection] {
        stateQueue.sync { collectionsByID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    }

    private func orderedItems() -> [CalendarItem] {
        stateQueue.sync {
            itemsByID.values.sorted {
                let lhs = CalendarDateCodec.date(from: $0.time.startAt) ?? .distantPast
                let rhs = CalendarDateCodec.date(from: $1.time.startAt) ?? .distantPast
                if lhs == rhs { return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                return lhs < rhs
            }
        }
    }

    private func occurrences(start: Date, end: Date) -> [CalendarOccurrence] {
        CalendarOccurrenceExpander.occurrences(for: orderedItems(), rangeStart: start, rangeEnd: end)
    }

    private func stateObject(now: Date = Date()) -> Object {
        let window = Self.defaultWindow(now: now)
        let occurrences = occurrences(start: window.start, end: window.end)
        let visualization = visualizationSpec(view: "agenda", start: window.start, end: window.end, occurrences: occurrences)
        let snapshot = stateQueue.sync {
            (
                importStatus: lastImportStatus,
                exportStatus: lastExportStatus,
                selectedOccurrenceID: selectedOccurrenceID
            )
        }
        return [
            "schema": .string(CalendarContract.stateSchema),
            "collections": .list(orderedCollections().map { .object($0.asObject()) }),
            "items": .list(orderedItems().map { .object($0.asObject()) }),
            "occurrences": .list(occurrences.map { .object($0.asObject()) }),
            "visualization": .object(visualization.asObject()),
            "selectedOccurrenceID": snapshot.selectedOccurrenceID.map(ValueType.string) ?? .null,
            "permissionStatus": .object(Self.localPermissionStatus()),
            "lastImportStatus": .string(snapshot.importStatus),
            "lastExportStatus": .string(snapshot.exportStatus)
        ]
    }

    private func queryOccurrencesObject(payload: ValueType) -> Object {
        let object = CalendarValueCodec.object(payload) ?? [:]
        let now = Date()
        let fallback = Self.defaultWindow(now: now)
        let start = CalendarDateCodec.date(from: CalendarValueCodec.string(object["startAt"])) ?? fallback.start
        let end = CalendarDateCodec.date(from: CalendarValueCodec.string(object["endAt"])) ?? fallback.end
        let view = CalendarValueCodec.string(object["view"]) ?? "agenda"
        let occurrences = occurrences(start: start, end: end)
        return [
            "schema": .string(CalendarContract.stateSchema),
            "status": .string("queried"),
            "occurrences": .list(occurrences.map { .object($0.asObject()) }),
            "visualization": .object(visualizationSpec(view: view, start: start, end: end, occurrences: occurrences).asObject())
        ]
    }

    private func createItem(payload: ValueType, requester: Identity) async -> ValueType {
        let object = mutationItemObject(payload)
        guard var item = object.flatMap(CalendarItem.fromObject) else {
            return .object(errorObject("invalid_item", "calendar.createItem requires a CalendarItem object."))
        }
        let now = CalendarDateCodec.isoString(Date())
        item.schema = CalendarContract.itemSchema
        item.createdAt = item.createdAt.isEmpty ? now : item.createdAt
        item.updatedAt = now
        item.revision = UUID().uuidString
        stateQueue.sync {
            itemsByID[item.id] = item
        }
        await emitCalendarEvent(kind: "calendar.item.created", item: item, requester: requester)
        return .object(mutationResult(status: "created", item: item))
    }

    private func updateItem(payload: ValueType, requester: Identity) async -> ValueType {
        guard let rawObject = mutationItemObject(payload) else {
            return .object(errorObject("invalid_item", "calendar.updateItem requires an object."))
        }
        let id = CalendarValueCodec.string(rawObject["id"])
            ?? CalendarValueCodec.object(rawObject["item"]).flatMap { CalendarValueCodec.string($0["id"]) }
        guard let id else {
            return .object(errorObject("missing_id", "calendar.updateItem requires an item id."))
        }
        let merged = stateQueue.sync { () -> Object? in
            guard let existing = itemsByID[id] else { return rawObject }
            var object = existing.asObject()
            for (key, value) in rawObject where key != "item" {
                object[key] = value
            }
            if let itemObject = CalendarValueCodec.object(rawObject["item"]) {
                for (key, value) in itemObject {
                    object[key] = value
                }
            }
            return object
        }
        guard var item = merged.flatMap(CalendarItem.fromObject) else {
            return .object(errorObject("invalid_item", "calendar.updateItem could not parse the item payload."))
        }
        item.updatedAt = CalendarDateCodec.isoString(Date())
        item.revision = UUID().uuidString
        stateQueue.sync {
            itemsByID[item.id] = item
        }
        await emitCalendarEvent(kind: "calendar.item.updated", item: item, requester: requester)
        return .object(mutationResult(status: "updated", item: item))
    }

    private func deleteItem(payload: ValueType, requester: Identity) async -> ValueType {
        let id = CalendarValueCodec.string(payload)
            ?? CalendarValueCodec.object(payload).flatMap { CalendarValueCodec.string($0["id"]) }
        guard let id else {
            return .object(errorObject("missing_id", "calendar.deleteItem requires an item id."))
        }
        let removed = stateQueue.sync { itemsByID.removeValue(forKey: id) }
        guard let removed else {
            return .object(errorObject("not_found", "Calendar item not found."))
        }
        await emitCalendarEvent(kind: "calendar.item.deleted", item: removed, requester: requester)
        return .object([
            "ok": .bool(true),
            "status": .string("deleted"),
            "item": .object(removed.asObject()),
            "message": .string("Calendar item deleted.")
        ])
    }

    private func importCalendar(payload: ValueType, requester: Identity) async -> ValueType {
        guard let object = CalendarValueCodec.object(payload),
              let text = CalendarValueCodec.string(object["text"]) ?? CalendarValueCodec.string(object["ics"]) else {
            return .object(errorObject("invalid_import", "calendar.import requires text or ics."))
        }
        let format = CalendarValueCodec.string(object["format"]) ?? "ics"
        do {
            let result = try CalendarImportExportCodec.importItems(format: format, text: text)
            stateQueue.sync {
                for collection in result.collections {
                    collectionsByID[collection.id] = collection
                }
                for item in result.items {
                    itemsByID[item.id] = item
                }
                lastImportStatus = "Imported \(result.items.count) item(s) from \(format)."
            }
            for item in result.items {
                await emitCalendarEvent(kind: "calendar.item.imported", item: item, requester: requester)
            }
            var response = result.asObject()
            response["status"] = .string("imported")
            response["occurrences"] = .list(occurrences(start: Self.defaultWindow(now: Date()).start, end: Self.defaultWindow(now: Date()).end).map { .object($0.asObject()) })
            return .object(response)
        } catch {
            return .object(errorObject("import_failed", String(describing: error)))
        }
    }

    private func exportCalendar(payload: ValueType) -> ValueType {
        let object = CalendarValueCodec.object(payload) ?? [:]
        let format = CalendarValueCodec.string(object["format"]) ?? "ics"
        let ids = Set(CalendarValueCodec.stringList(object["itemIds"]))
        let allItems = orderedItems()
        let selected = ids.isEmpty ? allItems : allItems.filter { ids.contains($0.id) || ids.contains($0.uid) }
        do {
            let result = try CalendarImportExportCodec.exportItems(format: format, items: selected)
            stateQueue.sync {
                lastExportStatus = "Exported \(result.itemCount) item(s) as \(result.format)."
            }
            return .object(result.asObject())
        } catch {
            return .object(errorObject("export_failed", String(describing: error)))
        }
    }

    private func mutationItemObject(_ value: ValueType) -> Object? {
        guard let object = CalendarValueCodec.object(value) else { return nil }
        return CalendarValueCodec.object(object["item"]) ?? object
    }

    private func mutationResult(status: String, item: CalendarItem) -> Object {
        let window = Self.defaultWindow(now: Date())
        return [
            "ok": .bool(true),
            "status": .string(status),
            "item": .object(item.asObject()),
            "occurrences": .list(occurrences(start: window.start, end: window.end).map { .object($0.asObject()) }),
            "message": .string("Calendar item \(status).")
        ]
    }

    private func errorObject(_ code: String, _ message: String) -> Object {
        [
            "ok": .bool(false),
            "status": .string("error"),
            "code": .string(code),
            "message": .string(message)
        ]
    }

    private func visualizationSpec(view: String, start: Date, end: Date, occurrences: [CalendarOccurrence]) -> CalendarVisualizationSpec {
        CalendarVisualizationSpec(
            view: view,
            range: CalendarVisualizationRange(startAt: CalendarDateCodec.isoString(start), endAt: CalendarDateCodec.isoString(end)),
            timezone: "UTC",
            itemsKeypath: CalendarContract.Keys.occurrences,
            selectionKeypath: "calendar.selection",
            actionKeypath: CalendarContract.Keys.queryOccurrences,
            capabilities: [
                "views": .list(["agenda", "day", "week", "month", "timeline"].map(ValueType.string)),
                "canSelect": .bool(true),
                "canMutate": .bool(true),
                "nativePermissionRequired": .bool(false)
            ],
            display: [
                "emptyTitle": .string("No calendar items"),
                "emptyMessage": .string("Create or import calendar items to populate this view.")
            ],
            fallback: [
                "kind": .string("list"),
                "items": .list(occurrences.map { .object($0.asObject()) })
            ],
            occurrences: occurrences
        )
    }

    private func emitCalendarEvent(kind: String, item: CalendarItem, requester: Identity) async {
        var flowElement = FlowElement(
            title: kind,
            content: .object([
                "schema": .string(CalendarContract.itemSchema),
                "itemId": .string(item.id),
                "uid": .string(item.uid),
                "title": .string(item.title),
                "updatedAt": .string(item.updatedAt)
            ]),
            properties: FlowElement.Properties(type: .event, contentType: .object)
        )
        flowElement.topic = CalendarContract.flowTopic
        flowElement.origin = uuid
        pushFlowElement(flowElement, requester: requester)
    }

    private static func defaultWindow(now: Date) -> (start: Date, end: Date) {
        let calendar = Foundation.Calendar(identifier: .gregorian)
        let start = calendar.date(byAdding: .day, value: -30, to: now) ?? now.addingTimeInterval(-30 * 86_400)
        let end = calendar.date(byAdding: .day, value: 60, to: now) ?? now.addingTimeInterval(60 * 86_400)
        return (start, end)
    }

    private static func localPermissionStatus() -> Object {
        [
            "nativeBridge": .string("not-required"),
            "calendar": .string("cell-local"),
            "reminders": .string("not-applicable"),
            "requiresExplicitUserAction": .bool(true),
            "remoteConfigurationsReceiveNativePermission": .bool(false)
        ]
    }

    private static func permissionStatusSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "nativeBridge": ExploreContract.schema(type: "string"),
                "calendar": ExploreContract.schema(type: "string"),
                "reminders": ExploreContract.schema(type: "string"),
                "requiresExplicitUserAction": ExploreContract.schema(type: "bool"),
                "remoteConfigurationsReceiveNativePermission": ExploreContract.schema(type: "bool")
            ],
            requiredKeys: ["nativeBridge", "requiresExplicitUserAction", "remoteConfigurationsReceiveNativePermission"],
            description: "Calendar permission status."
        )
    }

    private static func importSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "format": ExploreContract.schema(type: "string"),
                "text": ExploreContract.schema(type: "string"),
                "ics": ExploreContract.schema(type: "string")
            ],
            requiredKeys: [],
            description: "Calendar import payload."
        )
    }

    private static func exportSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "format": ExploreContract.schema(type: "string"),
                "itemIds": ExploreContract.listSchema(item: ExploreContract.schema(type: "string"))
            ],
            requiredKeys: [],
            description: "Calendar export payload."
        )
    }

    private static func exportResultSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "ok": ExploreContract.schema(type: "bool"),
                "status": ExploreContract.schema(type: "string"),
                "format": ExploreContract.schema(type: "string"),
                "text": ExploreContract.schema(type: "string"),
                "itemCount": ExploreContract.schema(type: "integer")
            ],
            requiredKeys: ["ok", "status", "format", "text", "itemCount"],
            description: "Calendar export result."
        )
    }
}

open class CalendarImportExportCell: GeneralCell {
    public required init(owner: Identity) async {
        await super.init(owner: owner)
        self.identityDomain = "Calendar"
        try? await ensureRuntimeReady()
    }

    public required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }

    open override func installCellRuntimeBindingsForAccess() async throws {
        await setup(owner: owner)
    }

    private func setup(owner: Identity) async {
        agreementTemplate.ensureGrant("rw--", for: CalendarContract.Keys.importCalendar)
        agreementTemplate.ensureGrant("rw--", for: CalendarContract.Keys.exportCalendar)

        await registerSet(
            key: CalendarContract.Keys.importCalendar,
            owner: owner,
            input: ExploreContract.objectSchema(
                properties: [
                    "format": ExploreContract.schema(type: "string"),
                    "text": ExploreContract.schema(type: "string"),
                    "ics": ExploreContract.schema(type: "string")
                ],
                description: "ICS or JSCalendar import payload."
            ),
            returns: CalendarContract.mutationResultSchemaDescriptor(),
            permissions: ["-w--"],
            required: true,
            description: .string("Parses ICS or JSCalendar and returns canonical CalendarItem objects without mutating a store.")
        ) { requester, payload in
            guard await self.validateAccess("rw--", at: CalendarContract.Keys.importCalendar, for: requester) else { return .string("denied") }
            guard let object = CalendarValueCodec.object(payload),
                  let text = CalendarValueCodec.string(object["text"]) ?? CalendarValueCodec.string(object["ics"]) else {
                return .object(self.errorObject("invalid_import", "calendar.import requires text or ics."))
            }
            do {
                let result = try CalendarImportExportCodec.importItems(format: CalendarValueCodec.string(object["format"]) ?? "ics", text: text)
                return .object(result.asObject())
            } catch {
                return .object(self.errorObject("import_failed", String(describing: error)))
            }
        }

        await registerSet(
            key: CalendarContract.Keys.exportCalendar,
            owner: owner,
            input: ExploreContract.objectSchema(
                properties: [
                    "format": ExploreContract.schema(type: "string"),
                    "items": ExploreContract.listSchema(item: CalendarContract.itemSchemaDescriptor())
                ],
                description: "Calendar export payload."
            ),
            returns: ExploreContract.objectSchema(
                properties: [
                    "format": ExploreContract.schema(type: "string"),
                    "text": ExploreContract.schema(type: "string"),
                    "itemCount": ExploreContract.schema(type: "integer")
                ],
                description: "Calendar export result."
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Exports canonical CalendarItem objects as ICS or JSCalendar.")
        ) { requester, payload in
            guard await self.validateAccess("rw--", at: CalendarContract.Keys.exportCalendar, for: requester) else { return .string("denied") }
            let object = CalendarValueCodec.object(payload) ?? [:]
            let items = CalendarValueCodec.list(object["items"]).compactMap { value in
                CalendarValueCodec.object(value).flatMap(CalendarItem.fromObject)
            }
            do {
                let result = try CalendarImportExportCodec.exportItems(format: CalendarValueCodec.string(object["format"]) ?? "ics", items: items)
                return .object(result.asObject())
            } catch {
                return .object(self.errorObject("export_failed", String(describing: error)))
            }
        }
    }

    private func errorObject(_ code: String, _ message: String) -> Object {
        [
            "ok": .bool(false),
            "status": .string("error"),
            "code": .string(code),
            "message": .string(message)
        ]
    }
}

public enum CalendarConfigurationFactory {
    public static func makeStoreConfiguration() -> CellConfiguration {
        var configuration = CellConfiguration(name: "Calendar")
        configuration.description = "Canonical HAVEN calendar store with portable skeleton calendar visualization."
        configuration.discovery = CellConfigurationDiscovery(
            sourceCellEndpoint: CalendarContract.endpoint,
            sourceCellName: CalendarContract.storeCellName,
            purpose: "Calendar data and schedule viewing",
            purposeDescription: "Store, import, export, and render canonical calendar items without granting native calendar access implicitly.",
            interests: ["calendar", "schedule", "time", "planning", "ics", "jscalendar"],
            menuSlots: ["upperRight", "lowerRight"]
        )
        configuration.addReference(CellReference(endpoint: CalendarContract.endpoint, subscribeFeed: false, label: "calendar"))

        let refreshButton = SkeletonButton(
            keypath: "calendar.calendar.queryOccurrences",
            label: "Refresh",
            payload: .object(["view": .string("agenda")])
        )
        let exportButton = SkeletonButton(
            keypath: "calendar.calendar.export",
            label: "Export ICS",
            payload: .object(["format": .string("ics")])
        )

        var listRow = SkeletonVStack(elements: [
            .Text(SkeletonText(keypath: "title")),
            .Text(SkeletonText(keypath: "startAt")),
            .Text(SkeletonText(keypath: "locationSummary"))
        ], spacing: 4)
        listRow.modifiers = SkeletonModifiers()
        listRow.modifiers?.padding = 8
        listRow.modifiers?.borderWidth = 1
        listRow.modifiers?.borderColor = "#CBD5E1"
        listRow.modifiers?.cornerRadius = 8

        configuration.skeleton = .ScrollView(SkeletonScrollView(elements: [
            .VStack(SkeletonVStack(elements: [
                .Text(SkeletonText(text: "Calendar")),
                .Text(SkeletonText(keypath: "calendar.calendar.state.lastImportStatus")),
                .Visualization(SkeletonVisualization(
                    kind: "calendar",
                    keypath: "calendar.calendar.state.visualization",
                    actionKeypath: "calendar.calendar.queryOccurrences",
                    modifiers: {
                        var modifiers = SkeletonModifiers()
                        modifiers.height = 420
                        return modifiers
                    }()
                )),
                .HStack(SkeletonHStack(elements: [
                    .Button(refreshButton),
                    .Button(exportButton)
                ], spacing: 8)),
                .List(SkeletonList(
                    topic: nil,
                    keypath: "calendar.calendar.state.occurrences",
                    flowElementSkeleton: listRow
                ))
            ], spacing: 12))
        ]))
        return configuration
    }
}
