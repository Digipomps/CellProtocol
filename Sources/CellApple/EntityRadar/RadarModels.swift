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

        let update = RadarEntityUpdate(
            remoteUUID: remoteUUID,
            displayName: displayName,
            status: status,
            connected: connected,
            connectedDevices: connectedDevices,
            distanceMeters: distanceMeters,
            direction: direction,
            matchScore: matchScore,
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
