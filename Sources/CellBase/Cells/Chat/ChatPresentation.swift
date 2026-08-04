// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

enum ChatPresentation {
    static let participantPresentationSchema = "haven.chat.participant-presentation.v1"
    static let groupPresentationSchema = "haven.chat.group-presentation.v1"

    static func initials(from displayName: String) -> String {
        let sanitized = removingUnsafePresentationControls(from: displayName)
        let words = sanitized
            .split(whereSeparator: isInitialSeparator)
            .prefix(2)
        return words.compactMap(firstLetterOrNumber).map { initial in
            String(String(initial).uppercased().prefix(1))
        }.joined()
    }

    static func participantPresentation(
        displayName: String,
        scopeID: String?,
        participantID: String
    ) -> Object {
        let initials = initials(from: displayName)
        return [
            "schema": .string(participantPresentationSchema),
            "kind": .string(initials.isEmpty ? "generic" : "initials"),
            "text": initials.isEmpty ? .null : .string(initials),
            "styleRole": .string(styleRole(scopeID: scopeID, participantID: participantID))
        ]
    }

    static func groupPresentation(
        members: [(participantID: String, displayName: String)],
        scopeID: String,
        excludingParticipantID: String?,
        visibleLimit: Int = 3
    ) -> Object {
        let visibleCapacity = max(0, visibleLimit)
        let orderedMembers = members
            .filter { $0.participantID != excludingParticipantID }
            .sorted { lhs, rhs in
                let lhsOrder = stableScopedHash(scopeID: scopeID, participantID: lhs.participantID)
                let rhsOrder = stableScopedHash(scopeID: scopeID, participantID: rhs.participantID)
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs.participantID < rhs.participantID
            }
        let visibleMembers = orderedMembers.prefix(visibleCapacity)
        let marks = visibleMembers.map { member in
            ValueType.object(participantPresentation(
                displayName: member.displayName,
                scopeID: scopeID,
                participantID: member.participantID
            ))
        }
        let kind: String
        switch orderedMembers.count {
        case 0:
            kind = "empty"
        case 1:
            kind = "person"
        default:
            kind = "group"
        }

        return [
            "schema": .string(groupPresentationSchema),
            "kind": .string(kind),
            "marks": .list(marks),
            "participantCount": .integer(orderedMembers.count),
            "visibleCount": .integer(marks.count),
            "overflowCount": .integer(max(orderedMembers.count - marks.count, 0))
        ]
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

    private static func firstLetterOrNumber(in word: Substring) -> Character? {
        word.first(where: { character in
            character.unicodeScalars.contains(where: { scalar in
                CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
            })
        })
    }

    private static func isInitialSeparator(_ character: Character) -> Bool {
        if character.isWhitespace || character == "_" {
            return true
        }
        return character.unicodeScalars.contains { scalar in
            CharacterSet(charactersIn: "-").contains(scalar) || scalar.properties.generalCategory == .dashPunctuation
        }
    }

    private static func removingUnsafePresentationControls(from raw: String) -> String {
        raw.unicodeScalars.reduce(into: "") { result, scalar in
            guard CharacterSet.controlCharacters.contains(scalar) == false,
                  isBidirectionalControl(scalar) == false else {
                return
            }
            result.unicodeScalars.append(scalar)
        }
    }

    private static func isBidirectionalControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A ... 0x202E, 0x2066 ... 0x2069, 0xFEFF:
            return true
        default:
            return false
        }
    }

    private static func styleRole(scopeID: String?, participantID: String) -> String {
        guard let scopeID,
              scopeID.isEmpty == false,
              participantID.isEmpty == false else {
            return "participant-tone-default"
        }
        let tone = Int(stableScopedHash(scopeID: scopeID, participantID: participantID) % 8) + 1
        return "participant-tone-\(tone)"
    }

    private static func stableScopedHash(scopeID: String, participantID: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let scopedInput = "\(participantPresentationSchema)\u{0}\(scopeID)\u{0}\(participantID)"
        for byte in scopedInput.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
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
