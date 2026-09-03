// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import CellBase

public struct RadarDirection3D: Codable, Hashable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public var azimuthRadians: Double {
        atan2(x, z)
    }
}

public struct RadarEntityUpdate: Hashable {
    public var remoteUUID: String?
    public var displayName: String?
    public var status: String?
    public var connected: Bool?
    public var connectedDevices: [String]?
    public var distanceMeters: Double?
    public var direction: RadarDirection3D?
    public var matchScore: Double?
    public var kind: NearbyEntityKind?
    public var beaconOverlapCount: Int
    public var probeDisclosure: [String]?
    public var matchedPurposeTokens: [String]
    public var matchedInterestTokens: [String]
    public var timestamp: Date

    public init(
        remoteUUID: String? = nil,
        displayName: String? = nil,
        status: String? = nil,
        connected: Bool? = nil,
        connectedDevices: [String]? = nil,
        distanceMeters: Double? = nil,
        direction: RadarDirection3D? = nil,
        matchScore: Double? = nil,
        kind: NearbyEntityKind? = nil,
        beaconOverlapCount: Int = 0,
        probeDisclosure: [String]? = nil,
        matchedPurposeTokens: [String] = [],
        matchedInterestTokens: [String] = [],
        timestamp: Date = Date()
    ) {
        self.remoteUUID = remoteUUID
        self.displayName = displayName
        self.status = status
        self.connected = connected
        self.connectedDevices = connectedDevices
        self.distanceMeters = distanceMeters
        self.direction = direction
        self.matchScore = matchScore
        self.kind = kind
        self.beaconOverlapCount = beaconOverlapCount
        self.probeDisclosure = probeDisclosure
        self.matchedPurposeTokens = matchedPurposeTokens
        self.matchedInterestTokens = matchedInterestTokens
        self.timestamp = timestamp
    }
}

public enum RadarScannerEvent: Hashable {
    case found(RadarEntityUpdate)
    case connected(RadarEntityUpdate)
    case lost(RadarEntityUpdate)
    case proximity(RadarEntityUpdate)
    case status(RadarEntityUpdate)
}

public struct NearbyEntity: Identifiable, Hashable {
    public var id: String { remoteUUID }

    public var remoteUUID: String
    public var displayName: String
    public var status: String
    public var connected: Bool
    public var connectedDevices: [String]
    public var distanceMeters: Double?
    public var direction: RadarDirection3D?
    public var matchScore: Double?
    public var kind: NearbyEntityKind?
    public var beaconOverlapCount: Int
    public var probeDisclosure: [String]?
    public var matchedPurposeTokens: [String]
    public var matchedInterestTokens: [String]
    public var firstSeenAt: Date
    public var lastSeenAt: Date

    public init(update: RadarEntityUpdate, defaultStatus: String) {
        let remoteUUID = update.remoteUUID ?? UUID().uuidString
        self.remoteUUID = remoteUUID
        self.displayName = NearbyEntity.defaultDisplayName(
            remoteUUID: remoteUUID,
            fallback: update.displayName
        )
        self.status = NearbyEntity.normalizedStatus(update.status, fallback: defaultStatus)
        self.connected = update.connected ?? false
        self.connectedDevices = update.connectedDevices ?? []
        self.distanceMeters = update.distanceMeters
        self.direction = update.direction
        self.matchScore = update.matchScore
        self.kind = update.kind
        self.beaconOverlapCount = update.beaconOverlapCount
        self.probeDisclosure = update.probeDisclosure
        self.matchedPurposeTokens = update.matchedPurposeTokens
        self.matchedInterestTokens = update.matchedInterestTokens
        self.firstSeenAt = update.timestamp
        self.lastSeenAt = update.timestamp
    }

    public mutating func merge(update: RadarEntityUpdate, defaultStatus: String) {
        if let remoteUUID = update.remoteUUID {
            self.remoteUUID = remoteUUID
        }
        if let displayName = update.displayName, !displayName.isEmpty {
            self.displayName = displayName
        }
        if let status = update.status, !status.isEmpty {
            self.status = status
        } else if !defaultStatus.isEmpty {
            self.status = defaultStatus
        }
        if let connected = update.connected {
            self.connected = connected
        }
        if let connectedDevices = update.connectedDevices {
            self.connectedDevices = connectedDevices
        }
        if let distanceMeters = update.distanceMeters {
            self.distanceMeters = distanceMeters
        }
        if let direction = update.direction {
            self.direction = direction
        }
        if let matchScore = update.matchScore {
            self.matchScore = matchScore
        }
        if let kind = update.kind {
            self.kind = kind
        }
        if update.beaconOverlapCount > 0 || self.beaconOverlapCount == 0 {
            self.beaconOverlapCount = update.beaconOverlapCount
        }
        if let probeDisclosure = update.probeDisclosure {
            self.probeDisclosure = probeDisclosure
        }
        if !update.matchedPurposeTokens.isEmpty || self.matchedPurposeTokens.isEmpty {
            self.matchedPurposeTokens = update.matchedPurposeTokens
        }
        if !update.matchedInterestTokens.isEmpty || self.matchedInterestTokens.isEmpty {
            self.matchedInterestTokens = update.matchedInterestTokens
        }
        if update.timestamp < self.firstSeenAt {
            self.firstSeenAt = update.timestamp
        }
        if update.timestamp > self.lastSeenAt {
            self.lastSeenAt = update.timestamp
        }
    }

    public var fallbackAngleRadians: Double {
        RadarStableHash.unitDouble(for: remoteUUID) * 2.0 * .pi
    }

    public var radarAngleRadians: Double {
        direction?.azimuthRadians ?? fallbackAngleRadians
    }

    public var radarRadiusNormalized: Double {
        guard let distanceMeters else {
            return 0.72
        }
        let normalized = distanceMeters / 8.0
        return min(max(normalized, 0.12), 0.98)
    }

    public var radarXNormalized: Double {
        cos(radarAngleRadians) * radarRadiusNormalized
    }

    public var radarYNormalized: Double {
        sin(radarAngleRadians) * radarRadiusNormalized
    }

    static func defaultDisplayName(remoteUUID: String, fallback: String?) -> String {
        if let fallback, !fallback.isEmpty {
            return fallback
        }
        if remoteUUID.count <= 12 {
            return remoteUUID
        }
        return "\(remoteUUID.prefix(8))...\(remoteUUID.suffix(4))"
    }

    static func normalizedStatus(_ status: String?, fallback: String) -> String {
        if let status, !status.isEmpty {
            return status
        }
        return fallback
    }
}

public enum RadarEventParser {
    public static func parse(_ flowElement: FlowElement) -> RadarScannerEvent? {
        guard flowElement.topic.hasPrefix("scanner.") else {
            return nil
        }
        guard case let .object(object) = flowElement.content else {
            return nil
        }

        let timestamp = extractDate(object["timestamp"]) ?? Date()
        let remoteUUID = extractString(object["remoteUUID"]) ?? extractString(object["payload"])
        let displayName = extractString(object["displayName"]) ?? extractString(object["displayname"])
        let status = extractString(object["status"])
        let connected = extractBool(object["connected"])
        let connectedDevices = extractStringList(object["connectedDevices"])
        let distanceMeters = extractDouble(object["distanceMeters"])
        let direction = extractDirection(object["direction"])
        let matchScore = extractDouble(object["matchScore"])
        let kind = extractString(object["entityKind"]).flatMap(NearbyEntityKind.init(rawValue:))
        let beaconOverlapCount = extractInt(object["beaconOverlapCount"]) ?? 0
        let probeDisclosure = extractProbeDisclosure(object["probeDisclosure"])
        let matchedPurposeTokens = extractStringList(object["matchedPurposeTokens"]) ?? []
        let matchedInterestTokens = extractStringList(object["matchedInterestTokens"]) ?? []

        let update = RadarEntityUpdate(
            remoteUUID: remoteUUID,
            displayName: displayName,
            status: status,
            connected: connected,
            connectedDevices: connectedDevices,
            distanceMeters: distanceMeters,
            direction: direction,
            matchScore: matchScore,
            kind: kind,
            beaconOverlapCount: beaconOverlapCount,
            probeDisclosure: probeDisclosure,
            matchedPurposeTokens: matchedPurposeTokens,
            matchedInterestTokens: matchedInterestTokens,
            timestamp: timestamp
        )

        switch flowElement.topic {
        case "scanner.found":
            return .found(update)
        case "scanner.connected":
            return .connected(update)
        case "scanner.lost":
            return .lost(update)
        case "scanner.proximity":
            return .proximity(update)
        case "scanner.status":
            return .status(update)
        default:
            return nil
        }
    }

    private static func extractString(_ value: ValueType?) -> String? {
        guard let value else { return nil }
        switch value {
        case let .string(string):
            return string
        default:
            return nil
        }
    }

    private static func extractBool(_ value: ValueType?) -> Bool? {
        guard let value else { return nil }
        switch value {
        case let .bool(bool):
            return bool
        default:
            return nil
        }
    }

    private static func extractDouble(_ value: ValueType?) -> Double? {
        guard let value else { return nil }
        switch value {
        case let .float(float):
            return float
        case let .integer(integer):
            return Double(integer)
        case let .number(number):
            return Double(number)
        case let .string(string):
            return Double(string)
        default:
            return nil
        }
    }

    private static func extractInt(_ value: ValueType?) -> Int? {
        guard let value else { return nil }
        switch value {
        case let .integer(integer), let .number(integer):
            return integer
        case let .float(float):
            return Int(float)
        case let .string(string):
            return Int(string)
        default:
            return nil
        }
    }

    private static func extractProbeDisclosure(_ value: ValueType?) -> [String]? {
        guard let value else { return nil }
        switch value {
        case let .list(list):
            return list.compactMap(extractString)
        case let .object(object):
            guard case let .list(references)? = object["references"] else { return nil }
            return references.compactMap(extractString)
        default:
            return nil
        }
    }

    private static func extractDate(_ value: ValueType?) -> Date? {
        guard let timestamp = extractDouble(value) else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    private static func extractStringList(_ value: ValueType?) -> [String]? {
        guard let value else { return nil }
        guard case let .list(list) = value else {
            return nil
        }
        let strings = list.compactMap { entry -> String? in
            if case let .string(string) = entry {
                return string
            }
            return nil
        }
        return strings
    }

    private static func extractDirection(_ value: ValueType?) -> RadarDirection3D? {
        guard let value else { return nil }
        guard case let .object(object) = value else {
            return nil
        }
        guard
            let x = extractDouble(object["x"]),
            let y = extractDouble(object["y"]),
            let z = extractDouble(object["z"])
        else {
            return nil
        }
        return RadarDirection3D(x: x, y: y, z: z)
    }
}

private enum RadarStableHash {
    static func unitDouble(for string: String) -> Double {
        let hash = fnv1a64(string)
        return Double(hash % 1_000_000) / 1_000_000.0
    }

    private static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

// MARK: - Ledger: the entities as the scanner currently sees them

/// Folds scanner flow events into a current picture of who is nearby. Pure
/// value semantics, so the view model on a screen and the cell that emits
/// the events keep the same picture — and the cell can hand it to a skeleton
/// as a radar spec without a view model in between.
public struct RadarEntityLedger: Equatable {
    public private(set) var entitiesById: [String: NearbyEntity] = [:]
    public private(set) var connectedDevices: [String] = []
    public private(set) var scannerStatus: String = "idle"
    public private(set) var selectedRemoteUUID: String?

    /// Metres at the outer ring. Everything beyond is clamped to the edge.
    public var rangeMeters: Double = 8.0
    /// How long a silent entity stays before it is dropped.
    public var staleAfter: TimeInterval = 20.0

    public init() {}

    public var entities: [NearbyEntity] {
        entitiesById.values.sorted { lhs, rhs in
            if lhs.connected != rhs.connected { return lhs.connected && !rhs.connected }
            let lhsDistance = lhs.distanceMeters ?? .greatestFiniteMagnitude
            let rhsDistance = rhs.distanceMeters ?? .greatestFiniteMagnitude
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    public mutating func consume(_ flowElement: FlowElement) {
        guard let event = RadarEventParser.parse(flowElement) else { return }
        consume(event)
    }

    public mutating func consume(_ event: RadarScannerEvent) {
        switch event {
        case let .found(update):
            upsert(update, fallbackStatus: "found")
        case var .connected(update):
            if let devices = update.connectedDevices { connectedDevices = devices }
            if update.remoteUUID != nil, update.connected == nil { update.connected = true }
            upsert(update, fallbackStatus: "connected")
        case let .lost(update):
            guard let remoteUUID = Self.normalizedRemoteUUID(update.remoteUUID),
                  var entity = entitiesById[remoteUUID] else { return }
            var lostUpdate = update
            lostUpdate.remoteUUID = remoteUUID
            if lostUpdate.status == nil { lostUpdate.status = "lost" }
            lostUpdate.connected = false
            entity.merge(update: lostUpdate, defaultStatus: "lost")
            entitiesById[remoteUUID] = entity
        case let .proximity(update):
            upsert(update, fallbackStatus: "nearby")
        case let .status(update):
            if let status = update.status, !status.isEmpty { scannerStatus = status }
            upsert(update, fallbackStatus: scannerStatus)
        }
    }

    public mutating func select(_ remoteUUID: String?) {
        selectedRemoteUUID = remoteUUID.flatMap(Self.normalizedRemoteUUID)
    }

    public mutating func clear() {
        entitiesById.removeAll()
        connectedDevices.removeAll()
        selectedRemoteUUID = nil
    }

    public mutating func remove(_ remoteUUID: String) {
        entitiesById.removeValue(forKey: remoteUUID)
        if selectedRemoteUUID == remoteUUID { selectedRemoteUUID = nil }
    }

    /// Drops what has not been heard from. Returns the ids that went.
    @discardableResult
    public mutating func prune(now: Date = Date()) -> [String] {
        let cutoff = now.addingTimeInterval(-staleAfter)
        let stale = entitiesById.filter { $0.value.lastSeenAt < cutoff && !$0.value.connected }.map(\.key)
        for id in stale { entitiesById.removeValue(forKey: id) }
        if let selected = selectedRemoteUUID, stale.contains(selected) { selectedRemoteUUID = nil }
        return stale
    }

    private mutating func upsert(_ update: RadarEntityUpdate, fallbackStatus: String) {
        guard let remoteUUID = Self.normalizedRemoteUUID(update.remoteUUID) else { return }
        var normalized = update
        normalized.remoteUUID = remoteUUID
        if normalized.status?.isEmpty ?? true { normalized.status = fallbackStatus }
        if var entity = entitiesById[remoteUUID] {
            entity.merge(update: normalized, defaultStatus: fallbackStatus)
            entitiesById[remoteUUID] = entity
        } else {
            entitiesById[remoteUUID] = NearbyEntity(update: normalized, defaultStatus: fallbackStatus)
        }
    }

    static func normalizedRemoteUUID(_ remoteUUID: String?) -> String? {
        let trimmed = remoteUUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Radar spec

    /// What a `Visualization(kind: "radar")` draws. Positions are normalized
    /// to the unit disc (x right, y down, bearing 0 straight up); distance
    /// and recency travel alongside so the view can size and fade blips
    /// without knowing the scanner.
    public func radarSpec(now: Date = Date()) -> Object {
        let blips: [ValueType] = entities.map { entity in
            let age = max(0, now.timeIntervalSince(entity.lastSeenAt))
            let radius = normalizedRadius(for: entity.distanceMeters)
            let angle = entity.radarAngleRadians
            var blip: Object = [
                "id": .string(entity.remoteUUID),
                "label": .string(entity.displayName),
                "status": .string(entity.status),
                "connected": .bool(entity.connected),
                "x": .float(sin(angle) * radius),
                "y": .float(-cos(angle) * radius),
                "bearingDegrees": .float((angle * 180.0 / .pi).truncatingRemainder(dividingBy: 360)),
                "hasDirection": .bool(entity.direction != nil),
                "ageSeconds": .float(age),
                "strength": .float(max(0.15, 1.0 - min(age, staleAfter) / staleAfter)),
                "matchScore": .float(entity.matchScore ?? 0),
                "beaconOverlapCount": .integer(entity.beaconOverlapCount),
                "kind": .string(entity.kind?.rawValue ?? "")
            ]
            if let distance = entity.distanceMeters {
                blip["distanceMeters"] = .float(distance)
                blip["distanceText"] = .string(String(format: distance < 10 ? "%.1f m" : "%.0f m", distance))
            } else {
                blip["distanceText"] = .string("—")
            }
            return .object(blip)
        }
        let nearest = entities.compactMap(\.distanceMeters).min()
        var spec: Object = [
            "kind": .string("radar"),
            "status": .string(scannerStatus),
            "rangeMeters": .float(rangeMeters),
            "rings": .list([0.25, 0.5, 0.75, 1.0].map { .float($0) }),
            "ringLabels": .list([0.25, 0.5, 0.75, 1.0].map { .string(String(format: "%.0f m", rangeMeters * $0)) }),
            "sweep": .bool(scannerStatus != "stopped" && scannerStatus != "idle"),
            "blipCount": .integer(entities.count),
            "connectedCount": .integer(connectedDevices.count),
            "blips": .list(blips),
            "updatedAt": .float(now.timeIntervalSince1970)
        ]
        spec["nearestMeters"] = nearest.map { .float($0) } ?? .null
        spec["nearestText"] = .string(nearest.map { String(format: $0 < 10 ? "%.1f" : "%.0f", $0) } ?? "--.-")
        spec["selectedID"] = selectedRemoteUUID.map { .string($0) } ?? .null
        return spec
    }

    func normalizedRadius(for distanceMeters: Double?) -> Double {
        guard let distanceMeters else { return 0.72 }
        return min(max(distanceMeters / rangeMeters, 0.08), 0.97)
    }
}
