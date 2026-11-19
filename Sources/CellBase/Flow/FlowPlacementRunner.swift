// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

// PDD_flow-plassering_2026-11-07, WP3 and WP10. A venue (the Mac agent, the
// entity's home scaffold) reports itself to its entity's anchor, reads the
// decisions that name it, and absorbs those sources. It holds no address for any
// publisher: every endpoint comes from the anchor. The publisher still
// authorizes the attach (`admit`) and every element. Moved here from
// HavenAgentD so the agent and the home scaffold run the same code.

/// One FlowElement the venue absorbed for a placed source.
public struct FlowPlacementAbsorbedEvent: Codable, Equatable, Sendable {
    public var receivedAt: Date
    public var sourceID: String
    public var endpoint: String
    public var purposes: [String]
    public var topic: String
    public var title: String
    public var origin: String?

    public init(receivedAt: Date, sourceID: String, endpoint: String, purposes: [String], topic: String, title: String, origin: String?) {
        self.receivedAt = receivedAt
        self.sourceID = sourceID
        self.endpoint = endpoint
        self.purposes = purposes
        self.topic = topic
        self.title = title
        self.origin = origin
    }
}

public struct FlowPlacementRunnerSummary: Codable, Equatable, Sendable {
    public struct Failure: Codable, Equatable, Sendable {
        public var sourceID: String
        public var endpoint: String
        public var reason: String
    }

    public var venueID: String
    /// ISO 8601, so the CLI's plain JSON stays readable.
    public var venueExpiresAt: String?
    /// Sources placed on this venue, with their purposes.
    public var placedHere: [String: [String]]
    public var attached: [String]
    public var detached: [String]
    public var kept: [String]
    public var failed: [Failure]
    /// Decisions without any venue right now, with the anchor's reason.
    public var unplaced: [String: String]
    public var placedElsewhere: Int
}

public enum FlowPlacementRunnerError: Error, LocalizedError, Equatable {
    case reportRefused(String)
    case stateUnreadable(String)
    case notAMeddleCell(String)
    case attachRefused(String)

    public var errorDescription: String? {
        switch self {
        case .reportRefused(let status): return "The entity anchor refused the venue report (\(status))."
        case .stateUnreadable(let detail): return "The entity anchor's flowPlacement.state could not be read: \(detail)"
        case .notAMeddleCell(let endpoint): return "\(endpoint) does not accept get/set."
        case .attachRefused(let state): return "The publisher did not admit the attach (\(state))."
        }
    }
}

/// A cell handed across isolation. Cells guard their own state (they are
/// actors or lock internally); this only tells the compiler so.
public struct FlowPlacementCellRef<Value>: @unchecked Sendable {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}

/// Reports one agent venue and keeps its absorbed sources in line with the
/// entity's decisions. Call `refresh()` periodically, well inside `venueLifetime`.
public actor FlowPlacementRunner {
    public typealias EmitterResolver = @Sendable (_ endpoint: String, _ requester: Identity) async throws -> FlowPlacementCellRef<any Emit>
    public typealias AbsorberFactory = @Sendable (_ owner: Identity) async -> FlowPlacementCellRef<GeneralCell>
    public typealias EventSink = @Sendable (FlowPlacementAbsorbedEvent) async -> Void

    public static let defaultVenueLifetime: TimeInterval = 10 * 60
    public static func labelPrefix() -> String { "flowPlacement." }

    private struct Placement {
        let endpoint: String
        let absorber: FlowPlacementCellRef<GeneralCell>
        let label: String
        var purposes: [String]
        let cancellable: FlowPlacementCellRef<AnyCancellable>
    }

    public let venueID: String
    public let venueKind: FlowVenueKind
    private let owner: Identity
    private let anchor: FlowPlacementCellRef<any Meddle>
    private let resolveEmitter: EmitterResolver
    private let makeAbsorber: AbsorberFactory
    private let eventSink: EventSink
    private let venueLifetime: TimeInterval
    private let clock: @Sendable () -> Date
    private var placements: [String: Placement] = [:]

    public init(
        venueID: String,
        venueKind: FlowVenueKind = .agent,
        owner: Identity,
        anchor: FlowPlacementCellRef<any Meddle>,
        venueLifetime: TimeInterval = FlowPlacementRunner.defaultVenueLifetime,
        resolveEmitter: @escaping EmitterResolver,
        makeAbsorber: @escaping AbsorberFactory = { owner in FlowPlacementCellRef(await GeneralCell(owner: owner)) },
        eventSink: @escaping EventSink,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.venueID = venueID
        self.venueKind = venueKind
        self.owner = owner
        self.anchor = anchor
        self.venueLifetime = min(venueLifetime, FlowVenue.maximumLifetime)
        self.resolveEmitter = resolveEmitter
        self.makeAbsorber = makeAbsorber
        self.eventSink = eventSink
        self.clock = clock
    }

    /// The venue id an agent uses: stable per agent identity, so a restart
    /// replaces its own report instead of adding a second venue.
    public static func venueID(forAgentIdentityUUID uuid: String) -> String {
        "haven-agentd:\(uuid)"
    }

    /// The venue id a home scaffold uses for one entity: stable per scaffold
    /// identity, so a restart replaces its own report.
    public static func venueID(forHomeScaffoldIdentityUUID uuid: String) -> String {
        "home-scaffold:\(uuid)"
    }

    /// Reports the venue, then attaches and detaches so the absorbed sources
    /// match the decisions naming this venue.
    public func refresh() async throws -> FlowPlacementRunnerSummary {
        let expiresAt = try await reportVenue()
        let state = try await readState()
        return await reconcile(state: state, venueExpiresAt: expiresAt)
    }

    /// Reads the state and reports what is placed here, changing nothing.
    public func status() async throws -> FlowPlacementRunnerSummary {
        let state = try await readState()
        let venue = state.venues.first { $0.venueID == venueID }
        var summary = Self.summarize(state: state, venueID: venueID, venueExpiresAt: venue?.expiresAt)
        summary.kept = placements.keys.sorted()
        return summary
    }

    /// Withdraws the venue and detaches everything, for a clean stop.
    public func withdraw() async {
        for sourceID in placements.keys.sorted() {
            await detach(sourceID)
        }
        _ = try? await Self.set(anchor, FlowPlacementLedger.venuesWithdraw,
            FlowPlacementCellRef(.object(["venueID": .string(venueID)])), owner)
    }

    public func attachedSourceIDs() -> [String] { placements.keys.sorted() }

    // MARK: - Steps

    private func reportVenue() async throws -> Date {
        let now = clock()
        let venue = try FlowVenue(
            venueID: venueID,
            kind: venueKind,
            alwaysOn: venueKind != .app,
            canPresent: venueKind == .app,
            reportedAt: now,
            expiresAt: now.addingTimeInterval(venueLifetime)
        )
        let response = try await Self.set(anchor, FlowPlacementLedger.venuesReport,
            FlowPlacementCellRef(try FlowPlacementLedger.encode(venue)), owner).value
        guard Self.status(of: response) == "reported" else {
            throw FlowPlacementRunnerError.reportRefused(Self.status(of: response) ?? "no status")
        }
        return venue.expiresAt
    }

    struct State {
        var sources: [FlowSource]
        var venues: [FlowVenue]
        var decisions: [FlowPlacementDecision]
    }

    private func readState() async throws -> State {
        let value: ValueType
        do {
            value = try await Self.get(anchor, FlowPlacementLedger.state, owner).value
        } catch {
            throw FlowPlacementRunnerError.stateUnreadable(String(describing: error))
        }
        guard case let .object(object) = value,
              let sources = object["sources"],
              let venues = object["venues"],
              let decisions = object["decisions"] else {
            throw FlowPlacementRunnerError.stateUnreadable(Self.status(of: value) ?? "not a state object")
        }
        do {
            return State(
                sources: try FlowPlacementLedger.decode(sources, as: [FlowSource].self),
                venues: try FlowPlacementLedger.decode(venues, as: [FlowVenue].self),
                decisions: try FlowPlacementLedger.decode(decisions, as: [FlowPlacementDecision].self)
            )
        } catch {
            throw FlowPlacementRunnerError.stateUnreadable(String(describing: error))
        }
    }

    private func reconcile(state: State, venueExpiresAt: Date) async -> FlowPlacementRunnerSummary {
        var summary = Self.summarize(state: state, venueID: venueID, venueExpiresAt: venueExpiresAt)
        let wanted = summary.placedHere
        let sourcesByID = Dictionary(state.sources.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })

        for sourceID in placements.keys.sorted() where wanted[sourceID] == nil {
            await detach(sourceID)
            summary.detached.append(sourceID)
        }
        for (sourceID, purposes) in wanted.sorted(by: { $0.key < $1.key }) {
            if placements[sourceID] != nil {
                placements[sourceID]?.purposes = purposes
                summary.kept.append(sourceID)
                continue
            }
            let endpoint = sourcesByID[sourceID]?.endpoint
                ?? state.decisions.first { $0.sourceID == sourceID }?.endpoint
                ?? sourceID
            do {
                try await attach(sourceID: sourceID, endpoint: endpoint, purposes: purposes,
                    topics: sourcesByID[sourceID]?.topics ?? [])
                summary.attached.append(sourceID)
            } catch {
                summary.failed.append(.init(sourceID: sourceID, endpoint: endpoint, reason: String(describing: error)))
            }
        }
        return summary
    }

    private func attach(sourceID: String, endpoint: String, purposes: [String], topics: [String]) async throws {
        let emitter = try await resolveEmitter(endpoint, owner)
        let absorber = await makeAbsorber(owner)
        let label = Self.labelPrefix() + Self.labelSafe(sourceID)
        let cancellable = try await Self.connect(
            emitter: emitter, absorber: absorber, label: label, owner: owner,
            topics: Set(topics), sourceID: sourceID, endpoint: endpoint, purposes: purposes,
            sink: eventSink, clock: clock)
        placements[sourceID] = Placement(endpoint: endpoint, absorber: absorber, label: label,
            purposes: purposes, cancellable: cancellable)
    }

    private func detach(_ sourceID: String) async {
        guard let placement = placements.removeValue(forKey: sourceID) else { return }
        placement.cancellable.value.cancel()
        await Self.disconnect(placement.absorber, label: placement.label, owner: owner)
    }

    // MARK: - Cell calls, outside the actor's isolation

    private static func get(_ cell: FlowPlacementCellRef<any Meddle>, _ keypath: String, _ requester: Identity) async throws -> FlowPlacementCellRef<ValueType> {
        FlowPlacementCellRef(try await cell.value.get(keypath: keypath, requester: requester))
    }

    private static func set(_ cell: FlowPlacementCellRef<any Meddle>, _ keypath: String, _ value: FlowPlacementCellRef<ValueType>, _ requester: Identity) async throws -> FlowPlacementCellRef<ValueType?> {
        FlowPlacementCellRef(try await cell.value.set(keypath: keypath, value: value.value, requester: requester))
    }

    private static func disconnect(_ absorber: FlowPlacementCellRef<GeneralCell>, label: String, owner: Identity) async {
        await absorber.value.detachAndWait(label: label, requester: owner)
    }

    /// Attaches through the publisher's own admission, subscribes to the
    /// absorber's feed, then starts the absorb. Undoes all of it on failure.
    private static func connect(
        emitter: FlowPlacementCellRef<any Emit>,
        absorber: FlowPlacementCellRef<GeneralCell>,
        label: String,
        owner: Identity,
        topics: Set<String>,
        sourceID: String,
        endpoint: String,
        purposes: [String],
        sink: @escaping EventSink,
        clock: @escaping @Sendable () -> Date
    ) async throws -> FlowPlacementCellRef<AnyCancellable> {
        let cell = absorber.value
        let connectState = try await cell.attach(emitter: emitter.value, label: label, requester: owner)
        guard connectState == .connected else {
            await cell.detachAndWait(label: label, requester: owner)
            throw FlowPlacementRunnerError.attachRefused(String(describing: connectState))
        }
        let cancellable: AnyCancellable
        do {
            let publisher = try await cell.flow(requester: owner)
            cancellable = publisher.sink(
                receiveCompletion: { _ in },
                receiveValue: { element in
                    guard topics.isEmpty || topics.contains(element.topic) else { return }
                    let event = FlowPlacementAbsorbedEvent(
                        receivedAt: clock(), sourceID: sourceID, endpoint: endpoint, purposes: purposes,
                        topic: element.topic, title: element.title, origin: element.origin)
                    Task { await sink(event) }
                }
            )
        } catch {
            await cell.detachAndWait(label: label, requester: owner)
            throw error
        }
        do {
            try await cell.absorbFlow(label: label, requester: owner)
        } catch {
            cancellable.cancel()
            await cell.detachAndWait(label: label, requester: owner)
            throw error
        }
        return FlowPlacementCellRef(cancellable)
    }

    // MARK: - Pure helpers

    static func summarize(state: State, venueID: String, venueExpiresAt: Date?) -> FlowPlacementRunnerSummary {
        var placedHere: [String: [String]] = [:]
        var unplaced: [String: String] = [:]
        var elsewhere = 0
        for decision in state.decisions {
            switch decision.venueID {
            case venueID?:
                placedHere[decision.sourceID, default: []].append(decision.purpose.rawValue)
            case nil:
                unplaced["\(decision.sourceID)#\(decision.purpose.rawValue)"] = decision.reason
            default:
                elsewhere += 1
            }
        }
        for key in placedHere.keys { placedHere[key]?.sort() }
        return FlowPlacementRunnerSummary(
            venueID: venueID, venueExpiresAt: venueExpiresAt.map { ISO8601DateFormatter().string(from: $0) }, placedHere: placedHere,
            attached: [], detached: [], kept: [], failed: [], unplaced: unplaced, placedElsewhere: elsewhere)
    }

    static func status(of value: ValueType?) -> String? {
        guard case let .object(object)? = value, case let .string(status)? = object["status"] else { return nil }
        return status
    }

    static func labelSafe(_ sourceID: String) -> String {
        String(sourceID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" })
    }
}
