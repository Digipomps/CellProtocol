// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// Flow placement: when an entity gains access to a cell that emits Flow, the
// entity — not a configured address — decides which of its runtimes consumes
// that Flow. See Docs/FlowPlacement.md.
//
// A placement decision never grants access. The publishing cell still checks
// every element against the requester's contract (Docs/ActiveFeedAuthorization.md).

/// Why the entity wants a Flow. Unknown values fail to decode, so an unknown
/// purpose can never be placed.
public enum FlowPlacementPurpose: String, Codable, Sendable, CaseIterable {
    /// Show to the person now, on the device that shows the surface.
    case present
    /// Tell the person something happened.
    case notify
    /// Keep a copy in the entity.
    case store
    /// Hand the event to an agent job.
    case agentJob
}

/// A runtime the entity can consume Flow on.
public enum FlowVenueKind: String, Codable, Sendable, CaseIterable {
    /// An agent such as HAVENAgentD on the person's own computer.
    case agent
    /// An app on a phone, tablet or computer.
    case app
    /// The person's own home scaffold. Never the publisher's scaffold.
    case homeScaffold
}

/// A cell the entity has access to and that emits Flow.
public struct FlowSource: Codable, Equatable, Sendable {
    /// Stable id. The fully qualified endpoint.
    public var sourceID: String
    /// `cell://<host>/<uuid-or-name>`. Always with a host.
    public var endpoint: String
    /// Display name the publisher gave the cell, when known.
    public var name: String?
    /// Topics the entity wants from this source. Empty means every topic.
    public var topics: [String]
    /// What the entity wants the Flow for.
    public var purposes: [FlowPlacementPurpose]
    /// The access the source came from: an identity-link id, a contract id.
    public var grantReference: String?
    public var addedAt: Date
    public var expiresAt: Date?

    public init(
        endpoint: String,
        name: String? = nil,
        topics: [String] = [],
        purposes: [FlowPlacementPurpose],
        grantReference: String? = nil,
        addedAt: Date = Date(),
        expiresAt: Date? = nil
    ) throws {
        guard FlowSource.isQualifiedEndpoint(endpoint) else {
            throw FlowPlacementError.endpointWithoutHost(endpoint)
        }
        guard !purposes.isEmpty else { throw FlowPlacementError.noPurpose }
        self.sourceID = endpoint
        self.endpoint = endpoint
        self.name = name
        self.topics = topics
        self.purposes = Array(Set(purposes)).sorted { $0.rawValue < $1.rawValue }
        self.grantReference = grantReference
        self.addedAt = addedAt
        self.expiresAt = expiresAt
    }

    public func isActive(at now: Date) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt > now
    }

    /// `cell://host/path` with a non-empty host and a non-empty path.
    public static func isQualifiedEndpoint(_ endpoint: String) -> Bool {
        guard endpoint.hasPrefix("cell://") else { return false }
        let rest = endpoint.dropFirst("cell://".count)
        guard let slash = rest.firstIndex(of: "/") else { return false }
        let host = rest[..<slash]
        let path = rest[rest.index(after: slash)...]
        return !host.isEmpty && !path.isEmpty
    }

    /// Qualifies `cell:///<path>` with the host the client talked to. An
    /// endpoint that already names a host is kept only when it is that host.
    public static func qualify(_ endpoint: String, host: String) throws -> String {
        guard FlowSource.isPlainHost(host) else { throw FlowPlacementError.invalidHost(host) }
        if endpoint.hasPrefix("cell:///") {
            let path = endpoint.dropFirst("cell:///".count)
            guard !path.isEmpty else { throw FlowPlacementError.endpointWithoutHost(endpoint) }
            return "cell://\(host)/\(path)"
        }
        guard isQualifiedEndpoint(endpoint) else { throw FlowPlacementError.endpointWithoutHost(endpoint) }
        let rest = endpoint.dropFirst("cell://".count)
        let named = rest[..<rest.firstIndex(of: "/")!]
        guard String(named) == host else { throw FlowPlacementError.hostMismatch(endpoint: endpoint, host: host) }
        return endpoint
    }

    /// The sources an identity-link completion grants: every listed cell with a
    /// signed contract, qualified with the host the completion came from.
    /// Shape: `{ "linkID"?: String, "record"?: {"linkID"}, "cells": [{name, uuid, endpoint, contract}] }`.
    public static func sources(
        fromLinkCompletion completion: ValueType,
        host: String,
        purposes: [FlowPlacementPurpose],
        topics: [String] = [],
        now: Date = Date()
    ) throws -> [FlowSource] {
        guard case let .object(object) = completion else { throw FlowPlacementError.invalidCompletion }
        guard case let .list(cells)? = object["cells"] else { throw FlowPlacementError.invalidCompletion }
        let linkID = stringValue(object["linkID"])
            ?? { if case let .object(record)? = object["record"] { return stringValue(record["linkID"]) } else { return nil } }()
        var result = [FlowSource]()
        for cell in cells {
            guard case let .object(entry) = cell,
                  stringValue(entry["contract"]) == "signed",
                  let rawEndpoint = stringValue(entry["endpoint"]) ?? stringValue(entry["uuid"]).map({ "cell:///\($0)" }) else {
                continue
            }
            let endpoint = try qualify(rawEndpoint, host: host)
            result.append(try FlowSource(
                endpoint: endpoint,
                name: stringValue(entry["name"]),
                topics: topics,
                purposes: purposes,
                grantReference: linkID.map { "identityLink:\($0)" },
                addedAt: now
            ))
        }
        return result
    }

    private static func isPlainHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:"))
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func stringValue(_ value: ValueType?) -> String? {
        guard case let .string(string)? = value, !string.isEmpty else { return nil }
        return string
    }
}

/// A runtime's report of itself to the entity. Expires unless reported again.
public struct FlowVenue: Codable, Equatable, Sendable {
    public static let maximumLifetime: TimeInterval = 24 * 60 * 60

    public var venueID: String
    public var kind: FlowVenueKind
    /// Stays on when the person is away (an agent or a scaffold).
    public var alwaysOn: Bool
    /// Can show things to the person.
    public var canPresent: Bool
    /// Sources whose surface this venue shows right now.
    public var presentingSourceIDs: [String]
    public var reportedAt: Date
    public var expiresAt: Date

    public init(
        venueID: String,
        kind: FlowVenueKind,
        alwaysOn: Bool,
        canPresent: Bool,
        presentingSourceIDs: [String] = [],
        reportedAt: Date = Date(),
        expiresAt: Date
    ) throws {
        guard !venueID.isEmpty, venueID.count <= 200 else { throw FlowPlacementError.invalidVenueID }
        guard expiresAt > reportedAt else { throw FlowPlacementError.venueAlreadyExpired }
        guard expiresAt.timeIntervalSince(reportedAt) <= FlowVenue.maximumLifetime else {
            throw FlowPlacementError.venueLifetimeTooLong
        }
        self.venueID = venueID
        self.kind = kind
        self.alwaysOn = alwaysOn
        self.canPresent = canPresent
        self.presentingSourceIDs = presentingSourceIDs
        self.reportedAt = reportedAt
        self.expiresAt = expiresAt
    }

    public func isOnline(at now: Date) -> Bool { expiresAt > now }
}

/// Which venue consumes one source for one purpose, and why.
public struct FlowPlacementDecision: Codable, Equatable, Sendable {
    public var sourceID: String
    public var endpoint: String
    public var purpose: FlowPlacementPurpose
    /// `nil` when no venue fits right now.
    public var venueID: String?
    public var reason: String
    public var decidedAt: Date

    public init(sourceID: String, endpoint: String, purpose: FlowPlacementPurpose, venueID: String?, reason: String, decidedAt: Date) {
        self.sourceID = sourceID
        self.endpoint = endpoint
        self.purpose = purpose
        self.venueID = venueID
        self.reason = reason
        self.decidedAt = decidedAt
    }
}

/// A flow the person set up: one more of their runtimes follows a source, on
/// top of the default placement (Kjetil 2026-11-20: a cell may subscribe to as
/// many Flow sources as it wants). It grants no access; it only says where.
public struct FlowSubscription: Codable, Equatable, Sendable {
    public var subscriptionID: String
    public var sourceID: String
    public var venueID: String
    public var purposes: [FlowPlacementPurpose]
    public var createdAt: Date

    public init(sourceID: String, venueID: String, purposes: [FlowPlacementPurpose], createdAt: Date = Date()) throws {
        guard !sourceID.isEmpty, sourceID.count <= 1_000 else { throw FlowPlacementError.invalidPayload("sourceID") }
        guard !venueID.isEmpty, venueID.count <= 200 else { throw FlowPlacementError.invalidVenueID }
        var unique = [FlowPlacementPurpose]()
        for purpose in purposes where !unique.contains(purpose) { unique.append(purpose) }
        guard !unique.isEmpty else { throw FlowPlacementError.noPurpose }
        self.subscriptionID = FlowSubscription.id(sourceID: sourceID, venueID: venueID)
        self.sourceID = sourceID
        self.venueID = venueID
        self.purposes = unique
        self.createdAt = createdAt
    }

    /// One subscription per (source, venue); adding again replaces its purposes.
    public static func id(sourceID: String, venueID: String) -> String { "\(venueID)|\(sourceID)" }
}

/// The first placement rule (G1 S3, 2026-11-08):
/// - `present` goes to the device that shows the source's surface now.
/// - `notify`, `store` and `agentJob` go to an online agent, otherwise to the
///   home scaffold.
/// Ties go to the venue that reported most recently, then the lowest venue id,
/// so each (source, purpose) has one default venue.
/// Then every subscription the person set up adds its venue, when that venue
/// is online and is not already the default. A venue never gets the same
/// (source, purpose) twice; many venues may follow one source (2026-11-20).
public enum FlowPlacementPolicy {
    public static func decide(
        sources: [FlowSource],
        venues: [FlowVenue],
        subscriptions: [FlowSubscription] = [],
        now: Date
    ) -> [FlowPlacementDecision] {
        let online = venues.filter { $0.isOnline(at: now) }
        var decisions = [FlowPlacementDecision]()
        for source in sources.sorted(by: { $0.sourceID < $1.sourceID }) {
            for purpose in source.purposes {
                guard source.isActive(at: now) else {
                    decisions.append(.init(sourceID: source.sourceID, endpoint: source.endpoint, purpose: purpose,
                        venueID: nil, reason: "Tilgangen til kilden er utløpt.", decidedAt: now))
                    continue
                }
                let (venue, reason) = choose(purpose: purpose, source: source, online: online)
                decisions.append(.init(sourceID: source.sourceID, endpoint: source.endpoint, purpose: purpose,
                    venueID: venue?.venueID, reason: reason, decidedAt: now))
                let followers = subscriptions
                    .filter { $0.sourceID == source.sourceID && $0.purposes.contains(purpose) && $0.venueID != venue?.venueID }
                    .map(\.venueID)
                for venueID in Set(followers).sorted() where online.contains(where: { $0.venueID == venueID }) {
                    decisions.append(.init(sourceID: source.sourceID, endpoint: source.endpoint, purpose: purpose,
                        venueID: venueID, reason: "Du har satt opp at dette stedet også følger kilden.", decidedAt: now))
                }
            }
        }
        return decisions
    }

    private static func choose(purpose: FlowPlacementPurpose, source: FlowSource, online: [FlowVenue]) -> (FlowVenue?, String) {
        switch purpose {
        case .present:
            if let venue = newest(online.filter { $0.canPresent && $0.presentingSourceIDs.contains(source.sourceID) }) {
                return (venue, "Enheten viser flaten nå.")
            }
            return (nil, "Ingen enhet viser flaten nå.")
        case .notify, .store, .agentJob:
            if let venue = newest(online.filter { $0.kind == .agent }) {
                return (venue, "Agenten er på nett.")
            }
            if let venue = newest(online.filter { $0.kind == .homeScaffold }) {
                return (venue, "Ingen agent er på nett; hjemmescaffoldet tar over.")
            }
            return (nil, "Ingen agent eller hjemmescaffold er på nett.")
        }
    }

    private static func newest(_ venues: [FlowVenue]) -> FlowVenue? {
        venues.min { lhs, rhs in
            if lhs.reportedAt != rhs.reportedAt { return lhs.reportedAt > rhs.reportedAt }
            return lhs.venueID < rhs.venueID
        }
    }
}

public enum FlowPlacementError: Error, Equatable, Sendable {
    case endpointWithoutHost(String)
    case invalidHost(String)
    case hostMismatch(endpoint: String, host: String)
    case invalidCompletion
    case noPurpose
    case invalidVenueID
    case venueAlreadyExpired
    case venueLifetimeTooLong
    case unknownSource(String)
    case unknownAction(String)
    case invalidPayload(String)
    case tooManySources
    case tooManyVenues
    case tooManySubscriptions
    case unknownSubscription(String)
}

/// The entity's placement state: what it has access to, where it can run, and
/// what it chose. Stored by the EntityAnchor under `flowPlacement.book`.
public struct FlowPlacementBook: Codable, Equatable, Sendable {
    public static let maximumSources = 500
    public static let maximumVenues = 50

    public static let maximumSubscriptions = 500

    public var sources: [String: FlowSource]
    public var venues: [String: FlowVenue]
    public var subscriptions: [String: FlowSubscription]

    public init(sources: [String: FlowSource] = [:], venues: [String: FlowVenue] = [:], subscriptions: [String: FlowSubscription] = [:]) {
        self.sources = sources
        self.venues = venues
        self.subscriptions = subscriptions
    }

    private enum CodingKeys: String, CodingKey { case sources, venues, subscriptions }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sources = try container.decode([String: FlowSource].self, forKey: .sources)
        venues = try container.decode([String: FlowVenue].self, forKey: .venues)
        // Books stored before 2026-11-20 have no subscriptions.
        subscriptions = try container.decodeIfPresent([String: FlowSubscription].self, forKey: .subscriptions) ?? [:]
    }

    public func decisions(at now: Date) -> [FlowPlacementDecision] {
        FlowPlacementPolicy.decide(sources: Array(sources.values), venues: Array(venues.values),
            subscriptions: Array(subscriptions.values), now: now)
    }
}

/// The EntityAnchor keypaths for flow placement, implemented once for every
/// anchor. The anchor checks owner access before calling `apply`.
public enum FlowPlacementLedger {
    public static let bookKeypath = "flowPlacement.book"
    public static let flowTopic = "flowPlacement.decisions"

    public static let sourcesAdd = "flowPlacement.sources.add"
    public static let sourcesRemove = "flowPlacement.sources.remove"
    public static let venuesReport = "flowPlacement.venues.report"
    public static let venuesWithdraw = "flowPlacement.venues.withdraw"
    public static let subscriptionsAdd = "flowPlacement.subscriptions.add"
    public static let subscriptionsRemove = "flowPlacement.subscriptions.remove"
    public static let state = "flowPlacement.state"

    public static let setActions = [sourcesAdd, sourcesRemove, venuesReport, venuesWithdraw, subscriptionsAdd, subscriptionsRemove]

    /// Applies one set action. Returns the new book and the response value.
    /// `sources.add` takes a FlowSource, a list of them, or
    /// `{linkCompletion, host, purposes, topics?}`.
    public static func apply(
        action: String,
        value: ValueType,
        to book: FlowPlacementBook,
        now: Date = Date()
    ) throws -> (book: FlowPlacementBook, response: ValueType) {
        var book = book
        switch action {
        case sourcesAdd:
            let added = try sourcesToAdd(from: value, now: now)
            for source in added { book.sources[source.sourceID] = source }
            guard book.sources.count <= FlowPlacementBook.maximumSources else { throw FlowPlacementError.tooManySources }
            return (book, try stateValue(book, now: now, status: "stored", extra: ["sourceIDs": .list(added.map { .string($0.sourceID) })]))
        case sourcesRemove:
            let sourceID = try requiredString(value, key: "sourceID")
            guard book.sources.removeValue(forKey: sourceID) != nil else { throw FlowPlacementError.unknownSource(sourceID) }
            book.subscriptions = book.subscriptions.filter { $0.value.sourceID != sourceID }
            return (book, try stateValue(book, now: now, status: "removed"))
        case venuesReport:
            let venue = try decode(value, as: FlowVenue.self)
            // Re-validate through the initializer: a decoded value skips it.
            let checked = try FlowVenue(venueID: venue.venueID, kind: venue.kind, alwaysOn: venue.alwaysOn,
                canPresent: venue.canPresent, presentingSourceIDs: venue.presentingSourceIDs,
                reportedAt: now, expiresAt: venue.expiresAt)
            book.venues[checked.venueID] = checked
            book.venues = book.venues.filter { $0.value.isOnline(at: now) }
            guard book.venues.count <= FlowPlacementBook.maximumVenues else { throw FlowPlacementError.tooManyVenues }
            return (book, try stateValue(book, now: now, status: "reported"))
        case venuesWithdraw:
            let venueID = try requiredString(value, key: "venueID")
            book.venues.removeValue(forKey: venueID)
            return (book, try stateValue(book, now: now, status: "withdrawn"))
        case subscriptionsAdd:
            // `{sourceID, venueID, purposes}`; the source must be one the entity has.
            let sourceID = try requiredString(value, key: "sourceID")
            guard book.sources[sourceID] != nil else { throw FlowPlacementError.unknownSource(sourceID) }
            guard case let .object(object) = value, case let .list(rawPurposes)? = object["purposes"] else {
                throw FlowPlacementError.noPurpose
            }
            let subscription = try FlowSubscription(
                sourceID: sourceID,
                venueID: try requiredString(value, key: "venueID"),
                purposes: try rawPurposes.map { try decode($0, as: FlowPlacementPurpose.self) },
                createdAt: now)
            book.subscriptions[subscription.subscriptionID] = subscription
            guard book.subscriptions.count <= FlowPlacementBook.maximumSubscriptions else {
                throw FlowPlacementError.tooManySubscriptions
            }
            return (book, try stateValue(book, now: now, status: "subscribed",
                extra: ["subscriptionID": .string(subscription.subscriptionID)]))
        case subscriptionsRemove:
            let id = FlowSubscription.id(sourceID: try requiredString(value, key: "sourceID"),
                venueID: try requiredString(value, key: "venueID"))
            guard book.subscriptions.removeValue(forKey: id) != nil else { throw FlowPlacementError.unknownSubscription(id) }
            return (book, try stateValue(book, now: now, status: "unsubscribed"))
        default:
            throw FlowPlacementError.unknownAction(action)
        }
    }

    public static func stateValue(_ book: FlowPlacementBook, now: Date, status: String = "ready", extra: Object = [:]) throws -> ValueType {
        var object: Object = [
            "status": .string(status),
            "sources": try encode(book.sources.values.sorted { $0.sourceID < $1.sourceID }),
            "venues": try encode(book.venues.values.sorted { $0.venueID < $1.venueID }),
            "subscriptions": try encode(book.subscriptions.values.sorted { $0.subscriptionID < $1.subscriptionID }),
            "decisions": try encode(book.decisions(at: now))
        ]
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }

    public static func load(_ value: ValueType?) throws -> FlowPlacementBook {
        guard let value, value != .null else { return FlowPlacementBook() }
        return try decode(value, as: FlowPlacementBook.self)
    }

    public static func encode<T: Encodable>(_ value: T) throws -> ValueType {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(ValueType.self, from: data)
    }

    public static func decode<T: Decodable>(_ value: ValueType, as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(value)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw FlowPlacementError.invalidPayload(String(describing: T.self))
        }
    }

    private static func sourcesToAdd(from value: ValueType, now: Date) throws -> [FlowSource] {
        if case let .object(object) = value, let completion = object["linkCompletion"] {
            let host = try requiredString(value, key: "host")
            guard case let .list(rawPurposes)? = object["purposes"] else { throw FlowPlacementError.noPurpose }
            let purposes = try rawPurposes.map { try decode($0, as: FlowPlacementPurpose.self) }
            let topics: [String]
            if case let .list(rawTopics)? = object["topics"] {
                topics = rawTopics.compactMap { if case let .string(topic) = $0 { return topic } else { return nil } }
            } else {
                topics = []
            }
            return try FlowSource.sources(fromLinkCompletion: completion, host: host, purposes: purposes, topics: topics, now: now)
        }
        let decoded: [FlowSource]
        if case .list = value {
            decoded = try decode(value, as: [FlowSource].self)
        } else {
            decoded = [try decode(value, as: FlowSource.self)]
        }
        // Re-validate through the initializer: a decoded value skips it.
        return try decoded.map {
            try FlowSource(endpoint: $0.endpoint, name: $0.name, topics: $0.topics, purposes: $0.purposes,
                grantReference: $0.grantReference, addedAt: now, expiresAt: $0.expiresAt)
        }
    }

    private static func requiredString(_ value: ValueType, key: String) throws -> String {
        guard case let .object(object) = value, case let .string(string)? = object[key], !string.isEmpty else {
            throw FlowPlacementError.invalidPayload(key)
        }
        return string
    }
}
