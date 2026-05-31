// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum CalendarContract {
    public static let collectionSchema = "haven.calendar.collection.v1"
    public static let itemSchema = "haven.calendar.item.v1"
    public static let occurrenceSchema = "haven.calendar.occurrence.v1"
    public static let visualizationSchema = "haven.calendar.visualization.v1"
    public static let stateSchema = "haven.calendar.store.state.v1"
    public static let endpoint = "cell:///CalendarStore"
    public static let importExportEndpoint = "cell:///CalendarImportExport"
    public static let nativeBridgeEndpoint = "cell:///NativeCalendarBridge"
    public static let storeCellName = "CalendarStore"
    public static let importExportCellName = "CalendarImportExport"
    public static let nativeBridgeCellName = "NativeCalendarBridge"
    public static let flowTopic = "calendar"

    public enum Keys {
        public static let state = "calendar.state"
        public static let collections = "calendar.collections"
        public static let items = "calendar.items"
        public static let occurrences = "calendar.occurrences"
        public static let queryOccurrences = "calendar.queryOccurrences"
        public static let createItem = "calendar.createItem"
        public static let updateItem = "calendar.updateItem"
        public static let deleteItem = "calendar.deleteItem"
        public static let importCalendar = "calendar.import"
        public static let exportCalendar = "calendar.export"
        public static let permissionStatus = "calendar.permissionStatus"
        public static let requestAccess = "calendar.requestAccess"
    }

    public static func collectionSchemaDescriptor() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "schema": ExploreContract.schema(type: "string"),
                "id": ExploreContract.schema(type: "string"),
                "name": ExploreContract.schema(type: "string"),
                "color": ExploreContract.schema(type: "string"),
                "visibility": ExploreContract.schema(type: "string"),
                "source": ExploreContract.schema(type: "object")
            ],
            requiredKeys: ["schema", "id", "name"],
            description: "Canonical HAVEN calendar collection."
        )
    }

    public static func itemSchemaDescriptor() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "schema": ExploreContract.schema(type: "string"),
                "id": ExploreContract.schema(type: "string"),
                "uid": ExploreContract.schema(type: "string"),
                "kind": ExploreContract.schema(type: "string"),
                "title": ExploreContract.schema(type: "string"),
                "description": ExploreContract.schema(type: "string"),
                "time": ExploreContract.schema(type: "object"),
                "location": ExploreContract.schema(type: "object"),
                "status": ExploreContract.schema(type: "string"),
                "availability": ExploreContract.schema(type: "string"),
                "participants": ExploreContract.listSchema(item: ExploreContract.schema(type: "object")),
                "organizer": ExploreContract.schema(type: "object"),
                "recurrence": ExploreContract.schema(type: "object"),
                "exceptions": ExploreContract.listSchema(item: ExploreContract.schema(type: "object")),
                "alarms": ExploreContract.listSchema(item: ExploreContract.schema(type: "object")),
                "links": ExploreContract.listSchema(item: ExploreContract.schema(type: "object")),
                "tags": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "privacy": ExploreContract.schema(type: "object"),
                "source": ExploreContract.schema(type: "object"),
                "revision": ExploreContract.schema(type: "string"),
                "createdAt": ExploreContract.schema(type: "string"),
                "updatedAt": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["schema", "id", "uid", "kind", "title", "time", "privacy", "source", "revision", "createdAt", "updatedAt"],
            description: "Canonical HAVEN calendar item."
        )
    }

    public static func occurrenceSchemaDescriptor() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "schema": ExploreContract.schema(type: "string"),
                "id": ExploreContract.schema(type: "string"),
                "itemId": ExploreContract.schema(type: "string"),
                "uid": ExploreContract.schema(type: "string"),
                "recurrenceId": ExploreContract.schema(type: "string"),
                "title": ExploreContract.schema(type: "string"),
                "startAt": ExploreContract.schema(type: "string"),
                "endAt": ExploreContract.schema(type: "string"),
                "timezone": ExploreContract.schema(type: "string"),
                "isAllDay": ExploreContract.schema(type: "bool"),
                "status": ExploreContract.schema(type: "string"),
                "availability": ExploreContract.schema(type: "string"),
                "locationSummary": ExploreContract.schema(type: "string"),
                "item": ExploreContract.schema(type: "object")
            ],
            requiredKeys: ["schema", "id", "itemId", "uid", "title", "startAt"],
            description: "Expanded calendar occurrence for renderers."
        )
    }

    public static func visualizationSchemaDescriptor() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "schema": ExploreContract.schema(type: "string"),
                "view": ExploreContract.schema(type: "string"),
                "range": ExploreContract.schema(type: "object"),
                "timezone": ExploreContract.schema(type: "string"),
                "itemsKeypath": ExploreContract.schema(type: "string"),
                "selectionKeypath": ExploreContract.schema(type: "string"),
                "actionKeypath": ExploreContract.schema(type: "string"),
                "capabilities": ExploreContract.schema(type: "object"),
                "display": ExploreContract.schema(type: "object"),
                "fallback": ExploreContract.schema(type: "object"),
                "occurrences": ExploreContract.listSchema(item: occurrenceSchemaDescriptor())
            ],
            requiredKeys: ["schema", "view", "range", "timezone"],
            description: "Portable calendar visualization payload for Skeleton Visualization(kind: calendar)."
        )
    }

    public static func stateSchemaDescriptor() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "schema": ExploreContract.schema(type: "string"),
                "collections": ExploreContract.listSchema(item: collectionSchemaDescriptor()),
                "items": ExploreContract.listSchema(item: itemSchemaDescriptor()),
                "occurrences": ExploreContract.listSchema(item: occurrenceSchemaDescriptor()),
                "visualization": visualizationSchemaDescriptor(),
                "permissionStatus": ExploreContract.schema(type: "object")
            ],
            requiredKeys: ["schema", "collections", "items", "occurrences", "visualization"],
            description: "Calendar store state."
        )
    }

    public static func queryInputSchemaDescriptor() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "startAt": ExploreContract.schema(type: "string"),
                "endAt": ExploreContract.schema(type: "string"),
                "timezone": ExploreContract.schema(type: "string"),
                "view": ExploreContract.schema(type: "string"),
                "collectionIds": ExploreContract.listSchema(item: ExploreContract.schema(type: "string"))
            ],
            requiredKeys: [],
            description: "Optional occurrence query window."
        )
    }

    public static func mutationResultSchemaDescriptor() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "ok": ExploreContract.schema(type: "bool"),
                "status": ExploreContract.schema(type: "string"),
                "item": itemSchemaDescriptor(),
                "items": ExploreContract.listSchema(item: itemSchemaDescriptor()),
                "occurrences": ExploreContract.listSchema(item: occurrenceSchemaDescriptor()),
                "message": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["ok", "status"],
            description: "Calendar operation result."
        )
    }
}

public struct CalendarSource: Codable {
    public var system: String
    public var externalId: String?
    public var calendarId: String?
    public var syncToken: String?
    public var etag: String?
    public var importedAt: String?

    public init(
        system: String = "haven",
        externalId: String? = nil,
        calendarId: String? = nil,
        syncToken: String? = nil,
        etag: String? = nil,
        importedAt: String? = nil
    ) {
        self.system = system
        self.externalId = externalId
        self.calendarId = calendarId
        self.syncToken = syncToken
        self.etag = etag
        self.importedAt = importedAt
    }
}

public struct CalendarPrivacy: Codable {
    public var classification: String
    public var visibility: String
    public var ownerScoped: Bool
    public var purposeRefs: [String]
    public var notes: String?

    public init(
        classification: String = "private",
        visibility: String = "owner",
        ownerScoped: Bool = true,
        purposeRefs: [String] = [],
        notes: String? = nil
    ) {
        self.classification = classification
        self.visibility = visibility
        self.ownerScoped = ownerScoped
        self.purposeRefs = purposeRefs
        self.notes = notes
    }
}

public struct CalendarCollection: Codable {
    public var schema: String
    public var id: String
    public var name: String
    public var color: String?
    public var visibility: String
    public var source: CalendarSource

    public init(
        id: String,
        name: String,
        color: String? = nil,
        visibility: String = "private",
        source: CalendarSource = CalendarSource()
    ) {
        self.schema = CalendarContract.collectionSchema
        self.id = id
        self.name = name
        self.color = color
        self.visibility = visibility
        self.source = source
    }
}

public struct CalendarTime: Codable {
    public var startAt: String
    public var endAt: String?
    public var timezone: String?
    public var isAllDay: Bool

    public init(startAt: String, endAt: String? = nil, timezone: String? = nil, isAllDay: Bool = false) {
        self.startAt = startAt
        self.endAt = endAt
        self.timezone = timezone
        self.isAllDay = isAllDay
    }
}

public struct CalendarLocation: Codable {
    public var name: String?
    public var address: String?
    public var url: String?
    public var geo: Object?

    public init(name: String? = nil, address: String? = nil, url: String? = nil, geo: Object? = nil) {
        self.name = name
        self.address = address
        self.url = url
        self.geo = geo
    }
}

public struct CalendarParticipant: Codable {
    public var id: String?
    public var displayName: String?
    public var email: String?
    public var role: String?
    public var status: String?
    public var cellEndpoint: String?

    public init(
        id: String? = nil,
        displayName: String? = nil,
        email: String? = nil,
        role: String? = nil,
        status: String? = nil,
        cellEndpoint: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.role = role
        self.status = status
        self.cellEndpoint = cellEndpoint
    }
}

public struct CalendarRecurrence: Codable {
    public var rrule: String?
    public var rdate: [String]
    public var exdate: [String]
    public var recurrenceId: String?

    public init(rrule: String? = nil, rdate: [String] = [], exdate: [String] = [], recurrenceId: String? = nil) {
        self.rrule = rrule
        self.rdate = rdate
        self.exdate = exdate
        self.recurrenceId = recurrenceId
    }
}

public struct CalendarException: Codable {
    public var recurrenceId: String
    public var isCancelled: Bool
    public var replacement: CalendarItem?

    public init(recurrenceId: String, isCancelled: Bool = false, replacement: CalendarItem? = nil) {
        self.recurrenceId = recurrenceId
        self.isCancelled = isCancelled
        self.replacement = replacement
    }
}

public struct CalendarAlarm: Codable {
    public var trigger: String
    public var action: String?
    public var description: String?

    public init(trigger: String, action: String? = nil, description: String? = nil) {
        self.trigger = trigger
        self.action = action
        self.description = description
    }
}

public struct CalendarLink: Codable {
    public var label: String?
    public var url: String
    public var kind: String?

    public init(label: String? = nil, url: String, kind: String? = nil) {
        self.label = label
        self.url = url
        self.kind = kind
    }
}

public struct CalendarItem: Codable {
    public var schema: String
    public var id: String
    public var uid: String
    public var kind: String
    public var title: String
    public var description: String?
    public var time: CalendarTime
    public var location: CalendarLocation?
    public var status: String
    public var availability: String
    public var participants: [CalendarParticipant]
    public var organizer: CalendarParticipant?
    public var recurrence: CalendarRecurrence?
    public var exceptions: [CalendarException]
    public var alarms: [CalendarAlarm]
    public var links: [CalendarLink]
    public var tags: [String]
    public var privacy: CalendarPrivacy
    public var source: CalendarSource
    public var revision: String
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String = UUID().uuidString,
        uid: String? = nil,
        kind: String = "event",
        title: String,
        description: String? = nil,
        time: CalendarTime,
        location: CalendarLocation? = nil,
        status: String = "confirmed",
        availability: String = "busy",
        participants: [CalendarParticipant] = [],
        organizer: CalendarParticipant? = nil,
        recurrence: CalendarRecurrence? = nil,
        exceptions: [CalendarException] = [],
        alarms: [CalendarAlarm] = [],
        links: [CalendarLink] = [],
        tags: [String] = [],
        privacy: CalendarPrivacy = CalendarPrivacy(),
        source: CalendarSource = CalendarSource(),
        revision: String = UUID().uuidString,
        createdAt: String = CalendarDateCodec.isoString(Date()),
        updatedAt: String = CalendarDateCodec.isoString(Date())
    ) {
        self.schema = CalendarContract.itemSchema
        self.id = id
        self.uid = uid ?? id
        self.kind = kind
        self.title = title
        self.description = description
        self.time = time
        self.location = location
        self.status = status
        self.availability = availability
        self.participants = participants
        self.organizer = organizer
        self.recurrence = recurrence
        self.exceptions = exceptions
        self.alarms = alarms
        self.links = links
        self.tags = tags
        self.privacy = privacy
        self.source = source
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CalendarOccurrence: Codable {
    public var schema: String
    public var id: String
    public var itemId: String
    public var uid: String
    public var recurrenceId: String?
    public var title: String
    public var startAt: String
    public var endAt: String?
    public var timezone: String?
    public var isAllDay: Bool
    public var status: String
    public var availability: String
    public var locationSummary: String?
    public var item: CalendarItem

    public init(
        id: String,
        itemId: String,
        uid: String,
        recurrenceId: String? = nil,
        title: String,
        startAt: String,
        endAt: String? = nil,
        timezone: String? = nil,
        isAllDay: Bool = false,
        status: String,
        availability: String,
        locationSummary: String? = nil,
        item: CalendarItem
    ) {
        self.schema = CalendarContract.occurrenceSchema
        self.id = id
        self.itemId = itemId
        self.uid = uid
        self.recurrenceId = recurrenceId
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.timezone = timezone
        self.isAllDay = isAllDay
        self.status = status
        self.availability = availability
        self.locationSummary = locationSummary
        self.item = item
    }
}

public struct CalendarVisualizationRange: Codable {
    public var startAt: String
    public var endAt: String

    public init(startAt: String, endAt: String) {
        self.startAt = startAt
        self.endAt = endAt
    }
}

public struct CalendarVisualizationSpec: Codable {
    public var schema: String
    public var view: String
    public var range: CalendarVisualizationRange
    public var timezone: String
    public var itemsKeypath: String?
    public var selectionKeypath: String?
    public var actionKeypath: String?
    public var capabilities: Object
    public var display: Object
    public var fallback: Object
    public var occurrences: [CalendarOccurrence]

    public init(
        view: String = "agenda",
        range: CalendarVisualizationRange,
        timezone: String = "UTC",
        itemsKeypath: String? = nil,
        selectionKeypath: String? = nil,
        actionKeypath: String? = nil,
        capabilities: Object = [:],
        display: Object = [:],
        fallback: Object = [:],
        occurrences: [CalendarOccurrence] = []
    ) {
        self.schema = CalendarContract.visualizationSchema
        self.view = view
        self.range = range
        self.timezone = timezone
        self.itemsKeypath = itemsKeypath
        self.selectionKeypath = selectionKeypath
        self.actionKeypath = actionKeypath
        self.capabilities = capabilities
        self.display = display
        self.fallback = fallback
        self.occurrences = occurrences
    }
}

public enum CalendarDateCodec {
    private static let internetFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let internetFormatterNoFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Foundation.Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let compactDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Foundation.Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    public static func date(from raw: String?) -> Date? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.isEmpty == false else {
            return nil
        }
        if let date = internetFormatter.date(from: trimmed) ?? internetFormatterNoFractions.date(from: trimmed) {
            return date
        }
        if trimmed.count == 8, let date = compactDateFormatter.date(from: trimmed) {
            return date
        }
        if trimmed.count == 10, let date = dateOnlyFormatter.date(from: trimmed) {
            return date
        }
        return nil
    }

    public static func isoString(_ date: Date) -> String {
        internetFormatterNoFractions.string(from: date)
    }

    public static func compactUTCDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Foundation.Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    public static func compactUTCDate(_ date: Date) -> String {
        compactDateFormatter.string(from: date)
    }
}

public enum CalendarValueCodec {
    public static func value(from object: Object) -> ValueType {
        .object(object)
    }

    public static func string(_ value: ValueType?) -> String? {
        guard let value else { return nil }
        switch value {
        case let .string(string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let .integer(integer):
            return String(integer)
        case let .number(number):
            return String(number)
        case let .float(float):
            return String(float)
        case let .bool(bool):
            return bool ? "true" : "false"
        default:
            return nil
        }
    }

    public static func bool(_ value: ValueType?) -> Bool? {
        switch value {
        case let .bool(bool)?:
            return bool
        case let .string(raw)?:
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    public static func object(_ value: ValueType?) -> Object? {
        guard case let .object(object)? = value else { return nil }
        return object
    }

    public static func list(_ value: ValueType?) -> ValueTypeList {
        guard case let .list(list)? = value else { return [] }
        return list
    }

    public static func stringList(_ value: ValueType?) -> [String] {
        list(value).compactMap(string)
    }
}

public extension CalendarSource {
    func asObject() -> Object {
        var object: Object = ["system": .string(system)]
        object["externalId"] = externalId.map(ValueType.string) ?? .null
        object["calendarId"] = calendarId.map(ValueType.string) ?? .null
        object["syncToken"] = syncToken.map(ValueType.string) ?? .null
        object["etag"] = etag.map(ValueType.string) ?? .null
        object["importedAt"] = importedAt.map(ValueType.string) ?? .null
        return object
    }

    static func fromObject(_ object: Object?) -> CalendarSource {
        CalendarSource(
            system: CalendarValueCodec.string(object?["system"]) ?? "haven",
            externalId: CalendarValueCodec.string(object?["externalId"]),
            calendarId: CalendarValueCodec.string(object?["calendarId"]),
            syncToken: CalendarValueCodec.string(object?["syncToken"]),
            etag: CalendarValueCodec.string(object?["etag"]),
            importedAt: CalendarValueCodec.string(object?["importedAt"])
        )
    }
}

public extension CalendarPrivacy {
    func asObject() -> Object {
        var object: Object = [
            "classification": .string(classification),
            "visibility": .string(visibility),
            "ownerScoped": .bool(ownerScoped),
            "purposeRefs": .list(purposeRefs.map(ValueType.string))
        ]
        object["notes"] = notes.map(ValueType.string) ?? .null
        return object
    }

    static func fromObject(_ object: Object?) -> CalendarPrivacy {
        CalendarPrivacy(
            classification: CalendarValueCodec.string(object?["classification"]) ?? "private",
            visibility: CalendarValueCodec.string(object?["visibility"]) ?? "owner",
            ownerScoped: CalendarValueCodec.bool(object?["ownerScoped"]) ?? true,
            purposeRefs: CalendarValueCodec.stringList(object?["purposeRefs"]),
            notes: CalendarValueCodec.string(object?["notes"])
        )
    }
}

public extension CalendarCollection {
    func asObject() -> Object {
        var object: Object = [
            "schema": .string(schema),
            "id": .string(id),
            "name": .string(name),
            "visibility": .string(visibility),
            "source": .object(source.asObject())
        ]
        object["color"] = color.map(ValueType.string) ?? .null
        return object
    }

    static func fromObject(_ object: Object) -> CalendarCollection? {
        guard let id = CalendarValueCodec.string(object["id"]),
              let name = CalendarValueCodec.string(object["name"]) else {
            return nil
        }
        return CalendarCollection(
            id: id,
            name: name,
            color: CalendarValueCodec.string(object["color"]),
            visibility: CalendarValueCodec.string(object["visibility"]) ?? "private",
            source: CalendarSource.fromObject(CalendarValueCodec.object(object["source"]))
        )
    }
}

public extension CalendarTime {
    func asObject() -> Object {
        var object: Object = [
            "startAt": .string(startAt),
            "isAllDay": .bool(isAllDay)
        ]
        object["endAt"] = endAt.map(ValueType.string) ?? .null
        object["timezone"] = timezone.map(ValueType.string) ?? .null
        return object
    }

    static func fromObject(_ object: Object?) -> CalendarTime? {
        guard let startAt = CalendarValueCodec.string(object?["startAt"]) ?? CalendarValueCodec.string(object?["startsAt"]) else {
            return nil
        }
        return CalendarTime(
            startAt: startAt,
            endAt: CalendarValueCodec.string(object?["endAt"]) ?? CalendarValueCodec.string(object?["endsAt"]),
            timezone: CalendarValueCodec.string(object?["timezone"]) ?? CalendarValueCodec.string(object?["timeZone"]),
            isAllDay: CalendarValueCodec.bool(object?["isAllDay"]) ?? false
        )
    }
}

public extension CalendarLocation {
    func asObject() -> Object {
        var object = Object()
        object["name"] = name.map(ValueType.string) ?? .null
        object["address"] = address.map(ValueType.string) ?? .null
        object["url"] = url.map(ValueType.string) ?? .null
        object["geo"] = geo.map(ValueType.object) ?? .null
        return object
    }

    static func fromObject(_ object: Object?) -> CalendarLocation? {
        guard let object else { return nil }
        return CalendarLocation(
            name: CalendarValueCodec.string(object["name"]),
            address: CalendarValueCodec.string(object["address"]),
            url: CalendarValueCodec.string(object["url"]),
            geo: CalendarValueCodec.object(object["geo"])
        )
    }
}

public extension CalendarParticipant {
    func asObject() -> Object {
        var object = Object()
        object["id"] = id.map(ValueType.string) ?? .null
        object["displayName"] = displayName.map(ValueType.string) ?? .null
        object["email"] = email.map(ValueType.string) ?? .null
        object["role"] = role.map(ValueType.string) ?? .null
        object["status"] = status.map(ValueType.string) ?? .null
        object["cellEndpoint"] = cellEndpoint.map(ValueType.string) ?? .null
        return object
    }

    static func fromObject(_ object: Object?) -> CalendarParticipant? {
        guard let object else { return nil }
        return CalendarParticipant(
            id: CalendarValueCodec.string(object["id"]),
            displayName: CalendarValueCodec.string(object["displayName"]) ?? CalendarValueCodec.string(object["name"]),
            email: CalendarValueCodec.string(object["email"]),
            role: CalendarValueCodec.string(object["role"]),
            status: CalendarValueCodec.string(object["status"]),
            cellEndpoint: CalendarValueCodec.string(object["cellEndpoint"])
        )
    }
}

public extension CalendarRecurrence {
    func asObject() -> Object {
        var object = Object()
        object["rrule"] = rrule.map(ValueType.string) ?? .null
        object["rdate"] = .list(rdate.map(ValueType.string))
        object["exdate"] = .list(exdate.map(ValueType.string))
        object["recurrenceId"] = recurrenceId.map(ValueType.string) ?? .null
        return object
    }

    static func fromObject(_ object: Object?) -> CalendarRecurrence? {
        guard let object else { return nil }
        let recurrence = CalendarRecurrence(
            rrule: CalendarValueCodec.string(object["rrule"]) ?? CalendarValueCodec.string(object["RRULE"]),
            rdate: CalendarValueCodec.stringList(object["rdate"]),
            exdate: CalendarValueCodec.stringList(object["exdate"]),
            recurrenceId: CalendarValueCodec.string(object["recurrenceId"])
        )
        if recurrence.rrule == nil && recurrence.rdate.isEmpty && recurrence.exdate.isEmpty && recurrence.recurrenceId == nil {
            return nil
        }
        return recurrence
    }
}

public extension CalendarException {
    func asObject() -> Object {
        var object: Object = [
            "recurrenceId": .string(recurrenceId),
            "isCancelled": .bool(isCancelled)
        ]
        object["replacement"] = replacement.map { .object($0.asObject()) } ?? .null
        return object
    }

    static func fromObject(_ object: Object?) -> CalendarException? {
        guard let object,
              let recurrenceId = CalendarValueCodec.string(object["recurrenceId"]) else {
            return nil
        }
        return CalendarException(
            recurrenceId: recurrenceId,
            isCancelled: CalendarValueCodec.bool(object["isCancelled"]) ?? false,
            replacement: CalendarValueCodec.object(object["replacement"]).flatMap(CalendarItem.fromObject)
        )
    }
}

public extension CalendarAlarm {
    func asObject() -> Object {
        var object: Object = ["trigger": .string(trigger)]
        object["action"] = action.map(ValueType.string) ?? .null
        object["description"] = description.map(ValueType.string) ?? .null
        return object
    }

    static func fromObject(_ object: Object?) -> CalendarAlarm? {
        guard let trigger = CalendarValueCodec.string(object?["trigger"]) else { return nil }
        return CalendarAlarm(
            trigger: trigger,
            action: CalendarValueCodec.string(object?["action"]),
            description: CalendarValueCodec.string(object?["description"])
        )
    }
}

public extension CalendarLink {
    func asObject() -> Object {
        var object: Object = ["url": .string(url)]
        object["label"] = label.map(ValueType.string) ?? .null
        object["kind"] = kind.map(ValueType.string) ?? .null
        return object
    }

    static func fromObject(_ object: Object?) -> CalendarLink? {
        guard let url = CalendarValueCodec.string(object?["url"]) else { return nil }
        return CalendarLink(
            label: CalendarValueCodec.string(object?["label"]),
            url: url,
            kind: CalendarValueCodec.string(object?["kind"])
        )
    }
}

public extension CalendarItem {
    func asObject() -> Object {
        var object: Object = [
            "schema": .string(schema),
            "id": .string(id),
            "uid": .string(uid),
            "kind": .string(kind),
            "title": .string(title),
            "time": .object(time.asObject()),
            "status": .string(status),
            "availability": .string(availability),
            "participants": .list(participants.map { .object($0.asObject()) }),
            "exceptions": .list(exceptions.map { .object($0.asObject()) }),
            "alarms": .list(alarms.map { .object($0.asObject()) }),
            "links": .list(links.map { .object($0.asObject()) }),
            "tags": .list(tags.map(ValueType.string)),
            "privacy": .object(privacy.asObject()),
            "source": .object(source.asObject()),
            "revision": .string(revision),
            "createdAt": .string(createdAt),
            "updatedAt": .string(updatedAt)
        ]
        object["description"] = description.map(ValueType.string) ?? .null
        object["location"] = location.map { .object($0.asObject()) } ?? .null
        object["organizer"] = organizer.map { .object($0.asObject()) } ?? .null
        object["recurrence"] = recurrence.map { .object($0.asObject()) } ?? .null
        return object
    }

    static func fromObject(_ object: Object) -> CalendarItem? {
        let now = CalendarDateCodec.isoString(Date())
        guard let title = CalendarValueCodec.string(object["title"]) ?? CalendarValueCodec.string(object["summary"]),
              let time = CalendarTime.fromObject(CalendarValueCodec.object(object["time"]) ?? object) else {
            return nil
        }
        let participants = CalendarValueCodec.list(object["participants"]).compactMap { value in
            CalendarParticipant.fromObject(CalendarValueCodec.object(value))
        }
        let exceptions = CalendarValueCodec.list(object["exceptions"]).compactMap { value in
            CalendarException.fromObject(CalendarValueCodec.object(value))
        }
        let alarms = CalendarValueCodec.list(object["alarms"]).compactMap { value in
            CalendarAlarm.fromObject(CalendarValueCodec.object(value))
        }
        let links = CalendarValueCodec.list(object["links"]).compactMap { value in
            CalendarLink.fromObject(CalendarValueCodec.object(value))
        }
        return CalendarItem(
            id: CalendarValueCodec.string(object["id"]) ?? UUID().uuidString,
            uid: CalendarValueCodec.string(object["uid"]) ?? CalendarValueCodec.string(object["UID"]),
            kind: CalendarValueCodec.string(object["kind"]) ?? "event",
            title: title,
            description: CalendarValueCodec.string(object["description"]),
            time: time,
            location: CalendarLocation.fromObject(CalendarValueCodec.object(object["location"])),
            status: CalendarValueCodec.string(object["status"]) ?? "confirmed",
            availability: CalendarValueCodec.string(object["availability"]) ?? "busy",
            participants: participants,
            organizer: CalendarParticipant.fromObject(CalendarValueCodec.object(object["organizer"])),
            recurrence: CalendarRecurrence.fromObject(CalendarValueCodec.object(object["recurrence"])),
            exceptions: exceptions,
            alarms: alarms,
            links: links,
            tags: CalendarValueCodec.stringList(object["tags"]),
            privacy: CalendarPrivacy.fromObject(CalendarValueCodec.object(object["privacy"])),
            source: CalendarSource.fromObject(CalendarValueCodec.object(object["source"])),
            revision: CalendarValueCodec.string(object["revision"]) ?? UUID().uuidString,
            createdAt: CalendarValueCodec.string(object["createdAt"]) ?? now,
            updatedAt: CalendarValueCodec.string(object["updatedAt"]) ?? now
        )
    }
}

public extension CalendarOccurrence {
    func asObject() -> Object {
        var object: Object = [
            "schema": .string(schema),
            "id": .string(id),
            "itemId": .string(itemId),
            "uid": .string(uid),
            "title": .string(title),
            "startAt": .string(startAt),
            "isAllDay": .bool(isAllDay),
            "status": .string(status),
            "availability": .string(availability),
            "item": .object(item.asObject())
        ]
        object["recurrenceId"] = recurrenceId.map(ValueType.string) ?? .null
        object["endAt"] = endAt.map(ValueType.string) ?? .null
        object["timezone"] = timezone.map(ValueType.string) ?? .null
        object["locationSummary"] = locationSummary.map(ValueType.string) ?? .null
        return object
    }
}

public extension CalendarVisualizationSpec {
    func asObject() -> Object {
        var object: Object = [
            "schema": .string(schema),
            "view": .string(view),
            "range": .object([
                "startAt": .string(range.startAt),
                "endAt": .string(range.endAt)
            ]),
            "timezone": .string(timezone),
            "capabilities": .object(capabilities),
            "display": .object(display),
            "fallback": .object(fallback),
            "occurrences": .list(occurrences.map { .object($0.asObject()) })
        ]
        object["itemsKeypath"] = itemsKeypath.map(ValueType.string) ?? .null
        object["selectionKeypath"] = selectionKeypath.map(ValueType.string) ?? .null
        object["actionKeypath"] = actionKeypath.map(ValueType.string) ?? .null
        return object
    }
}

public enum CalendarOccurrenceExpander {
    private struct Rule {
        var frequency: String
        var interval: Int
        var count: Int?
        var until: Date?
    }

    public static func occurrences(for item: CalendarItem, rangeStart: Date, rangeEnd: Date) -> [CalendarOccurrence] {
        guard let startDate = CalendarDateCodec.date(from: item.time.startAt) else {
            return []
        }
        let endDate = CalendarDateCodec.date(from: item.time.endAt)
        let duration = max((endDate ?? defaultEnd(for: startDate, item: item)).timeIntervalSince(startDate), item.time.isAllDay ? 86_400 : 60)
        let recurrence = item.recurrence
        let exceptionByID = Dictionary(uniqueKeysWithValues: item.exceptions.map { ($0.recurrenceId, $0) })
        var starts: [Date] = []

        if let rule = parseRule(recurrence?.rrule) {
            starts.append(contentsOf: expandedStarts(from: startDate, rule: rule, rangeStart: rangeStart, rangeEnd: rangeEnd))
        } else {
            starts.append(startDate)
        }

        starts.append(contentsOf: (recurrence?.rdate ?? []).compactMap(CalendarDateCodec.date))
        starts = starts
            .filter { overlaps(start: $0, end: $0.addingTimeInterval(duration), rangeStart: rangeStart, rangeEnd: rangeEnd) }
            .sorted()

        let exdates = Set((recurrence?.exdate ?? []).compactMap { CalendarDateCodec.date(from: $0).map(CalendarDateCodec.isoString) })
        var seen = Set<String>()
        var result: [CalendarOccurrence] = []

        for start in starts {
            let recurrenceId = CalendarDateCodec.isoString(start)
            guard seen.insert(recurrenceId).inserted else { continue }
            if exdates.contains(recurrenceId) {
                continue
            }
            if let exception = exceptionByID[recurrenceId] {
                if exception.isCancelled {
                    continue
                }
                if let replacement = exception.replacement {
                    result.append(makeOccurrence(item: replacement, start: CalendarDateCodec.date(from: replacement.time.startAt) ?? start, duration: duration, recurrenceId: recurrenceId))
                    continue
                }
            }
            result.append(makeOccurrence(item: item, start: start, duration: duration, recurrenceId: recurrence?.rrule == nil ? recurrence?.recurrenceId : recurrenceId))
        }

        return result.sorted {
            (CalendarDateCodec.date(from: $0.startAt) ?? .distantPast) < (CalendarDateCodec.date(from: $1.startAt) ?? .distantPast)
        }
    }

    public static func occurrences(for items: [CalendarItem], rangeStart: Date, rangeEnd: Date) -> [CalendarOccurrence] {
        items.flatMap { occurrences(for: $0, rangeStart: rangeStart, rangeEnd: rangeEnd) }
            .sorted {
                (CalendarDateCodec.date(from: $0.startAt) ?? .distantPast) < (CalendarDateCodec.date(from: $1.startAt) ?? .distantPast)
            }
    }

    private static func makeOccurrence(item: CalendarItem, start: Date, duration: TimeInterval, recurrenceId: String?) -> CalendarOccurrence {
        let end = start.addingTimeInterval(duration)
        let occurrenceStart = CalendarDateCodec.isoString(start)
        let id = [item.id, recurrenceId ?? occurrenceStart].joined(separator: "::")
        return CalendarOccurrence(
            id: id,
            itemId: item.id,
            uid: item.uid,
            recurrenceId: recurrenceId,
            title: item.title,
            startAt: occurrenceStart,
            endAt: CalendarDateCodec.isoString(end),
            timezone: item.time.timezone,
            isAllDay: item.time.isAllDay,
            status: item.status,
            availability: item.availability,
            locationSummary: item.location?.name ?? item.location?.address,
            item: item
        )
    }

    private static func defaultEnd(for start: Date, item: CalendarItem) -> Date {
        start.addingTimeInterval(item.time.isAllDay ? 86_400 : 3_600)
    }

    private static func overlaps(start: Date, end: Date, rangeStart: Date, rangeEnd: Date) -> Bool {
        start < rangeEnd && end > rangeStart
    }

    private static func parseRule(_ raw: String?) -> Rule? {
        guard let raw, raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        var fields: [String: String] = [:]
        for part in raw.split(separator: ";") {
            let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pieces.count == 2 {
                fields[pieces[0].uppercased()] = pieces[1]
            }
        }
        guard let frequency = fields["FREQ"]?.uppercased() else { return nil }
        return Rule(
            frequency: frequency,
            interval: max(1, Int(fields["INTERVAL"] ?? "") ?? 1),
            count: Int(fields["COUNT"] ?? ""),
            until: CalendarDateCodec.date(from: fields["UNTIL"])
        )
    }

    private static func expandedStarts(from start: Date, rule: Rule, rangeStart: Date, rangeEnd: Date) -> [Date] {
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let component: Foundation.Calendar.Component
        switch rule.frequency {
        case "DAILY":
            component = .day
        case "WEEKLY":
            component = .weekOfYear
        case "MONTHLY":
            component = .month
        case "YEARLY":
            component = .year
        default:
            return [start]
        }

        var dates: [Date] = []
        var cursor = start
        var generated = 0
        while cursor < rangeEnd {
            generated += 1
            if cursor >= rangeStart || cursor.addingTimeInterval(86_400) > rangeStart {
                dates.append(cursor)
            }
            if let count = rule.count, generated >= count {
                break
            }
            if let until = rule.until, cursor >= until {
                break
            }
            guard let next = calendar.date(byAdding: component, value: rule.interval, to: cursor) else {
                break
            }
            cursor = next
            if generated > 10_000 {
                break
            }
        }
        return dates
    }
}
