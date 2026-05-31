// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum CalendarImportExportError: Error, CustomStringConvertible {
    case invalidPayload(String)
    case unsupportedFormat(String)

    public var description: String {
        switch self {
        case let .invalidPayload(message):
            return message
        case let .unsupportedFormat(format):
            return "Unsupported calendar format: \(format)"
        }
    }
}

public struct CalendarImportResult {
    public var items: [CalendarItem]
    public var collections: [CalendarCollection]
    public var warnings: [String]

    public init(items: [CalendarItem], collections: [CalendarCollection] = [], warnings: [String] = []) {
        self.items = items
        self.collections = collections
        self.warnings = warnings
    }

    public func asObject() -> Object {
        [
            "ok": .bool(true),
            "status": .string(warnings.isEmpty ? "imported" : "importedWithWarnings"),
            "items": .list(items.map { .object($0.asObject()) }),
            "collections": .list(collections.map { .object($0.asObject()) }),
            "warnings": .list(warnings.map(ValueType.string))
        ]
    }
}

public struct CalendarExportResult {
    public var format: String
    public var text: String
    public var itemCount: Int

    public init(format: String, text: String, itemCount: Int) {
        self.format = format
        self.text = text
        self.itemCount = itemCount
    }

    public func asObject() -> Object {
        [
            "ok": .bool(true),
            "status": .string("exported"),
            "format": .string(format),
            "text": .string(text),
            "itemCount": .integer(itemCount)
        ]
    }
}

public enum CalendarImportExportCodec {
    public static func importItems(format: String, text: String, now: Date = Date()) throws -> CalendarImportResult {
        switch normalizedFormat(format) {
        case "ics", "ical", "icalendar", "text/calendar":
            return CalendarICSCodec.importItems(text: text, now: now)
        case "jscalendar", "js-calendar", "application/calendar+json":
            return try CalendarJSCalendarCodec.importItems(text: text, now: now)
        default:
            throw CalendarImportExportError.unsupportedFormat(format)
        }
    }

    public static func exportItems(format: String, items: [CalendarItem]) throws -> CalendarExportResult {
        switch normalizedFormat(format) {
        case "ics", "ical", "icalendar", "text/calendar":
            return CalendarICSCodec.exportItems(items)
        case "jscalendar", "js-calendar", "application/calendar+json":
            return try CalendarJSCalendarCodec.exportItems(items)
        default:
            throw CalendarImportExportError.unsupportedFormat(format)
        }
    }

    public static func normalizedFormat(_ raw: String?) -> String {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return value.isEmpty ? "ics" : value
    }
}

public enum CalendarICSCodec {
    private struct Property {
        var name: String
        var parameters: [String: String]
        var value: String
    }

    public static func importItems(text: String, now: Date = Date()) -> CalendarImportResult {
        let lines = unfoldedLines(text)
        var events: [[Property]] = []
        var current: [Property]?
        var warnings: [String] = []

        for line in lines {
            let upper = line.uppercased()
            if upper == "BEGIN:VEVENT" {
                current = []
                continue
            }
            if upper == "END:VEVENT" {
                if let event = current {
                    events.append(event)
                }
                current = nil
                continue
            }
            guard current != nil else { continue }
            guard let property = parseProperty(line) else {
                warnings.append("Skipped invalid iCalendar line: \(line)")
                continue
            }
            current?.append(property)
        }

        let importedAt = CalendarDateCodec.isoString(now)
        let items = events.compactMap { event -> CalendarItem? in
            let properties = Dictionary(grouping: event, by: \.name)
            let uid = firstValue("UID", in: properties) ?? UUID().uuidString
            let title = firstValue("SUMMARY", in: properties) ?? "Untitled event"
            let description = firstValue("DESCRIPTION", in: properties)
            let locationName = firstValue("LOCATION", in: properties)
            let status = firstValue("STATUS", in: properties)?.lowercased() ?? "confirmed"
            let dtStart = firstProperty("DTSTART", in: properties)
            let dtEnd = firstProperty("DTEND", in: properties)
            let startAt = decodedDateString(dtStart?.value)
            guard let startAt else {
                warnings.append("Skipped iCalendar event without DTSTART: \(uid)")
                return nil
            }
            let isAllDay = dtStart?.parameters["VALUE"]?.uppercased() == "DATE" || dtStart?.value.count == 8
            let timezone = dtStart?.parameters["TZID"] ?? dtEnd?.parameters["TZID"]
            let recurrence = CalendarRecurrence(
                rrule: firstValue("RRULE", in: properties),
                rdate: allValues("RDATE", in: properties).flatMap(splitDateList).compactMap(decodedDateString),
                exdate: allValues("EXDATE", in: properties).flatMap(splitDateList).compactMap(decodedDateString),
                recurrenceId: firstValue("RECURRENCE-ID", in: properties).flatMap(decodedDateString)
            )
            let effectiveRecurrence = recurrence.rrule == nil && recurrence.rdate.isEmpty && recurrence.exdate.isEmpty && recurrence.recurrenceId == nil
                ? nil
                : recurrence

            return CalendarItem(
                id: stableIdentifier(from: uid),
                uid: uid,
                kind: "event",
                title: decodeText(title),
                description: description.map(decodeText),
                time: CalendarTime(
                    startAt: startAt,
                    endAt: decodedDateString(dtEnd?.value),
                    timezone: timezone,
                    isAllDay: isAllDay
                ),
                location: locationName.map { CalendarLocation(name: decodeText($0)) },
                status: status,
                availability: status == "cancelled" ? "free" : "busy",
                recurrence: effectiveRecurrence,
                tags: ["ics"],
                source: CalendarSource(system: "ics", externalId: uid, calendarId: nil, importedAt: importedAt),
                createdAt: importedAt,
                updatedAt: importedAt
            )
        }

        return CalendarImportResult(items: items, warnings: warnings)
    }

    public static func exportItems(_ items: [CalendarItem]) -> CalendarExportResult {
        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//HAVEN//CellProtocol Calendar//EN",
            "CALSCALE:GREGORIAN"
        ]

        for item in items.sorted(by: { $0.uid < $1.uid }) {
            lines.append("BEGIN:VEVENT")
            lines.append("UID:\(escapeText(item.uid))")
            lines.append("DTSTAMP:\(CalendarDateCodec.compactUTCDateTime(Date()))")
            lines.append(dateLine(name: "DTSTART", value: item.time.startAt, isAllDay: item.time.isAllDay, timezone: item.time.timezone))
            if let endAt = item.time.endAt {
                lines.append(dateLine(name: "DTEND", value: endAt, isAllDay: item.time.isAllDay, timezone: item.time.timezone))
            }
            lines.append("SUMMARY:\(escapeText(item.title))")
            if let description = item.description, description.isEmpty == false {
                lines.append("DESCRIPTION:\(escapeText(description))")
            }
            if let location = item.location?.name ?? item.location?.address, location.isEmpty == false {
                lines.append("LOCATION:\(escapeText(location))")
            }
            lines.append("STATUS:\(item.status.uppercased())")
            if let recurrence = item.recurrence {
                if let rrule = recurrence.rrule, rrule.isEmpty == false {
                    lines.append("RRULE:\(rrule)")
                }
                if recurrence.rdate.isEmpty == false {
                    lines.append("RDATE:\(recurrence.rdate.compactMap { compactDateValue($0, isAllDay: item.time.isAllDay) }.joined(separator: ","))")
                }
                if recurrence.exdate.isEmpty == false {
                    lines.append("EXDATE:\(recurrence.exdate.compactMap { compactDateValue($0, isAllDay: item.time.isAllDay) }.joined(separator: ","))")
                }
            }
            lines.append("END:VEVENT")
        }

        lines.append("END:VCALENDAR")
        return CalendarExportResult(format: "ics", text: folded(lines).joined(separator: "\r\n") + "\r\n", itemCount: items.count)
    }

    private static func unfoldedLines(_ text: String) -> [String] {
        var lines: [String] = []
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if rawLine.hasPrefix(" ") || rawLine.hasPrefix("\t") {
                if lines.isEmpty {
                    lines.append(rawLine.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    lines[lines.count - 1] += String(rawLine.dropFirst())
                }
            } else {
                lines.append(rawLine.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return lines.filter { $0.isEmpty == false }
    }

    private static func parseProperty(_ line: String) -> Property? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let head = String(line[..<colon])
        let value = String(line[line.index(after: colon)...])
        let pieces = head.split(separator: ";").map(String.init)
        guard let name = pieces.first?.uppercased(), name.isEmpty == false else { return nil }
        var parameters: [String: String] = [:]
        for part in pieces.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 {
                parameters[pair[0].uppercased()] = pair[1]
            }
        }
        return Property(name: name, parameters: parameters, value: value)
    }

    private static func firstProperty(_ name: String, in properties: [String: [Property]]) -> Property? {
        properties[name.uppercased()]?.first
    }

    private static func firstValue(_ name: String, in properties: [String: [Property]]) -> String? {
        firstProperty(name, in: properties)?.value
    }

    private static func allValues(_ name: String, in properties: [String: [Property]]) -> [String] {
        properties[name.uppercased()]?.map(\.value) ?? []
    }

    private static func splitDateList(_ value: String) -> [String] {
        value.split(separator: ",").map(String.init)
    }

    private static func decodedDateString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if raw.count == 8, let date = CalendarDateCodec.date(from: raw) {
            return CalendarDateCodec.isoString(date)
        }
        if raw.hasSuffix("Z") && raw.contains("T") {
            let expanded = raw
                .replacingOccurrences(of: "T", with: "T")
                .replacingOccurrences(of: "Z", with: "Z")
            if let date = compactDateTimeFormatter.date(from: expanded) {
                return CalendarDateCodec.isoString(date)
            }
        }
        if let date = floatingDateTimeFormatter.date(from: raw) {
            return CalendarDateCodec.isoString(date)
        }
        return CalendarDateCodec.date(from: raw).map(CalendarDateCodec.isoString)
    }

    private static let compactDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Foundation.Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static let floatingDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Foundation.Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter
    }()

    private static func dateLine(name: String, value: String, isAllDay: Bool, timezone: String?) -> String {
        let suffix = compactDateValue(value, isAllDay: isAllDay) ?? value
        if isAllDay {
            return "\(name);VALUE=DATE:\(suffix)"
        }
        if let timezone, timezone.isEmpty == false, timezone.uppercased() != "UTC" {
            return "\(name);TZID=\(timezone):\(suffix.replacingOccurrences(of: "Z", with: ""))"
        }
        return "\(name):\(suffix)"
    }

    private static func compactDateValue(_ value: String, isAllDay: Bool) -> String? {
        guard let date = CalendarDateCodec.date(from: value) else { return nil }
        return isAllDay ? CalendarDateCodec.compactUTCDate(date) : CalendarDateCodec.compactUTCDateTime(date)
    }

    private static func escapeText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;")
    }

    private static func decodeText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func stableIdentifier(from uid: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = uid.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return value.isEmpty ? UUID().uuidString : value
    }

    private static func folded(_ lines: [String]) -> [String] {
        lines.flatMap { line -> [String] in
            guard line.count > 75 else { return [line] }
            var result: [String] = []
            var remaining = line
            var isFirst = true
            while remaining.count > 75 {
                let index = remaining.index(remaining.startIndex, offsetBy: isFirst ? 75 : 74)
                result.append((isFirst ? "" : " ") + remaining[..<index])
                remaining = String(remaining[index...])
                isFirst = false
            }
            result.append((isFirst ? "" : " ") + remaining)
            return result
        }
    }
}

public enum CalendarJSCalendarCodec {
    public static func importItems(text: String, now: Date = Date()) throws -> CalendarImportResult {
        guard let data = text.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CalendarImportExportError.invalidPayload("JSCalendar import requires a JSON object.")
        }
        let rawEvents: [[String: Any]]
        if let events = json["events"] as? [[String: Any]] {
            rawEvents = events
        } else if (json["@type"] as? String)?.lowercased().contains("event") == true {
            rawEvents = [json]
        } else {
            rawEvents = []
        }
        let nowString = CalendarDateCodec.isoString(now)
        let items = rawEvents.compactMap { event -> CalendarItem? in
            guard let title = event["title"] as? String ?? event["summary"] as? String,
                  let start = event["start"] as? String ?? event["startAt"] as? String else {
                return nil
            }
            let uid = event["uid"] as? String ?? event["id"] as? String ?? UUID().uuidString
            return CalendarItem(
                id: event["id"] as? String ?? uid,
                uid: uid,
                title: title,
                description: event["description"] as? String,
                time: CalendarTime(
                    startAt: CalendarDateCodec.date(from: start).map(CalendarDateCodec.isoString) ?? start,
                    endAt: (event["end"] as? String ?? event["endAt"] as? String).flatMap { CalendarDateCodec.date(from: $0).map(CalendarDateCodec.isoString) ?? $0 },
                    timezone: event["timeZone"] as? String ?? event["timezone"] as? String,
                    isAllDay: event["showWithoutTime"] as? Bool ?? false
                ),
                location: (event["location"] as? String).map { CalendarLocation(name: $0) },
                status: event["status"] as? String ?? "confirmed",
                tags: ["jscalendar"],
                source: CalendarSource(system: "jscalendar", externalId: uid, importedAt: nowString),
                createdAt: nowString,
                updatedAt: nowString
            )
        }
        return CalendarImportResult(items: items)
    }

    public static func exportItems(_ items: [CalendarItem]) throws -> CalendarExportResult {
        let events = items.map { item -> [String: Any] in
            var event: [String: Any] = [
                "@type": "Event",
                "id": item.id,
                "uid": item.uid,
                "title": item.title,
                "start": item.time.startAt,
                "status": item.status
            ]
            if let endAt = item.time.endAt {
                event["end"] = endAt
            }
            if let timezone = item.time.timezone {
                event["timeZone"] = timezone
            }
            if let description = item.description {
                event["description"] = description
            }
            if let location = item.location?.name ?? item.location?.address {
                event["location"] = location
            }
            return event
        }
        let object: [String: Any] = [
            "@type": "Calendar",
            "prodId": "HAVEN CellProtocol",
            "events": events
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return CalendarExportResult(format: "jscalendar", text: text, itemCount: items.count)
    }
}
