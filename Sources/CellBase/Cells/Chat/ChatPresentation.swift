// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

enum ChatPresentation {
    static func initials(from displayName: String) -> String {
        let words = displayName
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .prefix(2)
        let token = words.compactMap { $0.first.map(String.init) }.joined()
        if token.isEmpty == false {
            return token.uppercased()
        }

        return String(displayName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2)).uppercased()
    }

    static func isMarkdown(contentType: String) -> Bool {
        contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "text/markdown"
    }

    static func formatLabel(for contentType: String) -> String {
        isMarkdown(contentType: contentType) ? "Markdown" : "Plain text"
    }

    static func formatDescription(for contentType: String) -> String {
        if isMarkdown(contentType: contentType) {
            return "Beholder enkel formatering som overskrifter, lister, lenker og fremheving."
        }
        return "Sendes som vanlig tekst uten formattering og er tryggest for enkle klienter."
    }

    static func preview(for content: String, limit: Int = 140) -> String {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func richTextContent(from content: String, contentType: String) -> String {
        guard isMarkdown(contentType: contentType) else {
            return escapeMarkdown(content)
        }
        return content
    }

    static func absoluteTimestamp(from iso8601: String) -> String {
        guard let date = date(from: iso8601) else { return iso8601 }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func relativeTimestamp(from iso8601: String, reference: Date = Date()) -> String {
        guard let date = date(from: iso8601) else { return absoluteTimestamp(from: iso8601) }

        let seconds = Int(reference.timeIntervalSince(date).rounded())
        if abs(seconds) < 45 {
            return "nå"
        }

        let future = seconds < 0
        let absolute = abs(seconds)
        let value: Int
        let unit: String
        switch absolute {
        case ..<3600:
            value = max(1, absolute / 60)
            unit = "m"
        case ..<86400:
            value = max(1, absolute / 3600)
            unit = "t"
        case ..<604800:
            value = max(1, absolute / 86400)
            unit = "d"
        default:
            return absoluteTimestamp(from: iso8601)
        }

        return future ? "om \(value)\(unit)" : "\(value)\(unit) siden"
    }

    static func messageCountLabel(_ count: Int) -> String {
        count == 1 ? "1 melding" : "\(count) meldinger"
    }

    static func characterCountLabel(_ count: Int) -> String {
        count == 1 ? "1 tegn" : "\(count) tegn"
    }

    static func lineCountLabel(_ count: Int) -> String {
        count == 1 ? "1 linje" : "\(count) linjer"
    }

    static func composerHelperText(for contentType: String) -> String {
        if isMarkdown(contentType: contentType) {
            return "Bruk markdown for punktlister, lenker, kode og fet/kursiv tekst."
        }
        return "Bruk plain text for raske beskjeder eller når du vil unngå formattering."
    }

    static func composerSendHint(isEmpty: Bool, contentType: String) -> String {
        guard isEmpty == false else {
            return "Skriv en melding før du sender til den delte staging-chatten."
        }
        if isMarkdown(contentType: contentType) {
            return "Klar til sending som markdown til alle klienter som absorberer samme chat."
        }
        return "Klar til sending som plain text til alle klienter som absorberer samme chat."
    }

    static func presenceLabel(for presence: String, lastAction: String) -> String {
        switch presence.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "messaging":
            return "Skriver"
        case "present":
            if lastAction.lowercased() == "subscribed" {
                return "Ble med"
            }
            return "Aktiv"
        default:
            let normalized = presence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.isEmpty == false else { return "Ukjent" }
            return normalized.prefix(1).uppercased() + normalized.dropFirst()
        }
    }

    static func activitySummary(messageCount: Int, lastSeenAt: String) -> String {
        "\(messageCountLabel(messageCount)) · sist sett \(relativeTimestamp(from: lastSeenAt))"
    }

    private static func date(from iso8601: String) -> Date? {
        timestampFormatter.date(from: iso8601)
    }

    private static func escapeMarkdown(_ raw: String) -> String {
        raw.reduce(into: "") { partialResult, character in
            switch character {
            case "\\", "`", "*", "_", "[", "]", "(", ")", "#", ">", "!":
                partialResult.append("\\")
                partialResult.append(character)
            default:
                partialResult.append(character)
            }
        }
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
