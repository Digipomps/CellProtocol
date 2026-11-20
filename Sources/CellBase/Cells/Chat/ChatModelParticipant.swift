// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// A language model as a named participant in a chat
/// (PDD_modell-i-felles-chat_2026-11-15).
///
/// The rules here are pure and deterministic, so Python and Go implement the
/// same functions and are checked against the same scenario fixtures
/// (`fixtures/interop/chat-model-v1`). `ChatCell` holds one ledger and asks it
/// whether the model may be admitted, read and answer.
///
/// - The model comes in only when every human member has said yes.
/// - Any member can say no or take back a yes; the model loses access at once.
/// - A member who joins after the model came in sees that it is there; they
///   have not said no, so the model stays. External routes need everyone's
///   explicit yes, including the newcomer's.
/// - Any member can remove the model. It must be proposed again to come back.
public struct ChatModelConsentLedger: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case none
        case proposed
        case active
        case removed
    }

    public struct Consent: Codable, Equatable, Sendable {
        /// Yes to an external model (e.g. Mistral) as well as the local one.
        public var external: Bool
        public var at: String

        public init(external: Bool, at: String) {
            self.external = external
            self.at = at
        }
    }

    public enum Refusal: String, Error, Sendable {
        case notMember = "not_member"
        case alreadyPresent = "already_present"
        case noProposal = "no_proposal"
    }

    public var status: Status
    public var modelUUID: String?
    public var modelDisplayName: String?
    public var proposedByUUID: String?
    public var proposedAt: String?
    /// When the model last became active. It reads nothing written before this.
    public var activatedAt: String?
    public var consents: [String: Consent]
    public var declined: [String: String]

    public init() {
        status = .none
        consents = [:]
        declined = [:]
    }

    // MARK: Events

    public mutating func propose(modelUUID: String, displayName: String, by member: String, external: Bool, at: String, members: [String]) throws {
        guard members.contains(member) else { throw Refusal.notMember }
        guard status == .none || status == .removed else { throw Refusal.alreadyPresent }
        status = .proposed
        self.modelUUID = modelUUID
        modelDisplayName = displayName
        proposedByUUID = member
        proposedAt = at
        activatedAt = nil
        consents = [member: Consent(external: external, at: at)]
        declined = [:]
        reevaluate(members: members, at: at)
    }

    public mutating func consent(by member: String, external: Bool, at: String, members: [String]) throws {
        guard members.contains(member) else { throw Refusal.notMember }
        guard status == .proposed || status == .active else { throw Refusal.noProposal }
        consents[member] = Consent(external: external, at: at)
        declined[member] = nil
        reevaluate(members: members, at: at)
    }

    /// Says no to a proposal, or takes back a yes. The model stops at once.
    public mutating func decline(by member: String, at: String, members: [String]) throws {
        guard members.contains(member) else { throw Refusal.notMember }
        guard status == .proposed || status == .active else { throw Refusal.noProposal }
        consents[member] = nil
        declined[member] = at
        reevaluate(members: members, at: at)
    }

    public mutating func remove(by member: String, at: String, members: [String]) throws {
        guard members.contains(member) else { throw Refusal.notMember }
        guard status == .proposed || status == .active else { throw Refusal.noProposal }
        status = .removed
        activatedAt = nil
        consents = [:]
        declined = [:]
    }

    /// Membership changed (someone joined or left): re-check activation.
    public mutating func membersChanged(members: [String], at: String) {
        reevaluate(members: members, at: at)
    }

    private mutating func reevaluate(members: [String], at: String) {
        switch status {
        case .proposed:
            let allSaidYes = members.isEmpty == false
                && members.allSatisfy { consents[$0] != nil && declined[$0] == nil }
            if allSaidYes {
                status = .active
                activatedAt = at
            }
        case .active:
            if members.contains(where: { declined[$0] != nil }) || members.isEmpty {
                status = .proposed
                activatedAt = nil
            }
        case .none, .removed:
            break
        }
    }

    // MARK: Questions the chat asks

    /// The Agreement condition for the model identity: active, and no current
    /// member has said no.
    public func modelConsentHolds(members: [String]) -> Bool {
        status == .active && members.isEmpty == false && members.allSatisfy { declined[$0] == nil }
    }

    /// External routes need every current member's explicit yes to external.
    public func externalAllowed(members: [String]) -> Bool {
        modelConsentHolds(members: members) && members.allSatisfy { consents[$0]?.external == true }
    }

    /// A member who has not answered a pending proposal.
    public func awaitingAnswer(from member: String, members: [String]) -> Bool {
        status == .proposed && members.contains(member) && consents[member] == nil && declined[member] == nil
    }

    public func consentedMembers(_ members: [String]) -> [String] {
        members.filter { consents[$0] != nil && declined[$0] == nil }
    }
}

/// Pure helpers shared with Python and Go.
public enum ChatModelRules {
    public static let contextLimit = 20
    public static let answerLimitScalars = 4_000
    public static let askLifetimeSeconds: TimeInterval = 600
    public static let mentionTokens = ["@modell", "@model"]

    /// True when a message is addressed to the model: `@modell` or `@model`
    /// (any case) not followed by a letter or digit.
    public static func isAddressedToModel(_ text: String) -> Bool {
        let lower = text.lowercased()
        for token in mentionTokens {
            var searchStart = lower.startIndex
            while let range = lower.range(of: token, range: searchStart ..< lower.endIndex) {
                let precededOK = range.lowerBound == lower.startIndex
                    || !isWordScalar(lower[lower.index(before: range.lowerBound)])
                let followedOK = range.upperBound == lower.endIndex
                    || !isWordScalar(lower[range.upperBound])
                if precededOK && followedOK { return true }
                searchStart = range.upperBound
            }
        }
        return false
    }

    private static func isWordScalar(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
    }

    public struct MessageStamp: Equatable, Sendable {
        public var id: String
        public var createdAt: String

        public init(id: String, createdAt: String) {
            self.id = id
            self.createdAt = createdAt
        }
    }

    /// The messages the model may read for one question: written at or after
    /// `activatedAt`, up to and including the question, at most `limit`, newest kept.
    /// Timestamps are ISO 8601 UTC strings in one format, compared as strings.
    public static func contextMessageIDs(messages: [MessageStamp], activatedAt: String, questionID: String, limit: Int = contextLimit) -> [String] {
        guard let questionIndex = messages.firstIndex(where: { $0.id == questionID }) else { return [] }
        let eligible = messages[...questionIndex].filter { $0.createdAt >= activatedAt }
        return eligible.suffix(max(0, limit)).map(\.id)
    }

    /// Model output as plain text: CR/CRLF become LF, control characters other
    /// than LF and TAB are dropped, surrounding whitespace trimmed, and the
    /// result cut to `answerLimitScalars` Unicode scalars.
    public static func sanitizeAnswer(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var scalars = String.UnicodeScalarView()
        for scalar in normalized.unicodeScalars {
            let value = scalar.value
            if value == 0x0A || value == 0x09 {
                scalars.append(scalar)
            } else if value < 0x20 || value == 0x7F || (0x80 ... 0x9F).contains(value) {
                continue
            } else {
                scalars.append(scalar)
            }
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = trimmed.unicodeScalars.prefix(answerLimitScalars)
        var out = String.UnicodeScalarView()
        out.append(contentsOf: limited)
        return String(out)
    }
}

/// One question to the model. Only an open ask lets the model read.
struct ChatModelAsk: Codable, Equatable {
    var id: String
    var askedByUUID: String
    var askedByDisplayName: String
    var questionMessageID: String
    var routeClass: String
    var createdAt: String
    var contextMessageIDs: [String]
    var status: String

    func objectValue() -> Object {
        [
            "askID": .string(id),
            "askedByUUID": .string(askedByUUID),
            "askedByDisplayName": .string(askedByDisplayName),
            "questionMessageID": .string(questionMessageID),
            "routeClass": .string(routeClass),
            "createdAt": .string(createdAt),
            "contextCount": .integer(contextMessageIDs.count),
            "status": .string(status)
        ]
    }
}

/// What the asker sees when the model could not answer. Only for them.
struct ChatModelNotice: Codable, Equatable {
    var askID: String
    var code: String
    var message: String
    var routeClass: String
    var at: String

    func objectValue() -> Object {
        [
            "askID": .string(askID),
            "code": .string(code),
            "message": .string(message),
            "routeClass": .string(routeClass),
            "at": .string(at)
        ]
    }
}
