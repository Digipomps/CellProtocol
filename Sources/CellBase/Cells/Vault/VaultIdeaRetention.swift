// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import Foundation

/// Owner-scoped retention for explicitly enrolled ideas. Existing undated notes
/// are never enrolled by a sweep. Timestamps are deadlines, not conflict order.
public struct VaultIdeaRetention: Codable, Equatable {
    public static let dayMs = 86_400_000
    public static let quarantineMs = 7 * dayMs
    public var defaultTTLDays = 7
    public private(set) var records: [String: Record] = [:]
    public private(set) var deletedIDs: Set<String> = []

    public struct Record: Codable, Equatable {
        public var ttlDays: Int
        public var expiresAtEpochMs: Int
        public var lastExtendedAtEpochMs: Int
        public var quarantinedAtEpochMs: Int?
        /// Monotonic protection: removing a projection cannot make a linked
        /// idea eligible for automatic deletion again.
        public var dependencyRefs: Set<String> = []
        public var isProtected: Bool { !dependencyRefs.isEmpty }
        public var purgeAtEpochMs: Int? { quarantinedAtEpochMs.map { $0 + VaultIdeaRetention.quarantineMs } }
    }

    public init() {}

    public mutating func configure(days: Int) throws {
        try Self.validate(days: days)
        defaultTTLDays = days
    }

    public mutating func enroll(id: String, now: Int) {
        guard records[id] == nil, !deletedIDs.contains(id) else { return }
        records[id] = Record(ttlDays: defaultTTLDays, expiresAtEpochMs: now + defaultTTLDays * Self.dayMs,
            lastExtendedAtEpochMs: now)
    }

    public mutating func setTTL(id: String, days: Int, now: Int) throws {
        try Self.validate(days: days)
        enroll(id: id, now: now)
        guard var record = records[id] else { throw RetentionError.deleted }
        record.ttlDays = days
        record.expiresAtEpochMs = now + days * Self.dayMs
        record.lastExtendedAtEpochMs = now
        record.quarantinedAtEpochMs = nil
        records[id] = record
    }

    public mutating func touch(id: String, now: Int) {
        guard var record = records[id], record.quarantinedAtEpochMs == nil,
              now - record.lastExtendedAtEpochMs >= Self.dayMs else { return }
        record.expiresAtEpochMs = max(now, record.expiresAtEpochMs) + Self.dayMs
        record.lastExtendedAtEpochMs = now
        records[id] = record
    }

    public mutating func restore(id: String, now: Int) throws {
        guard let record = records[id] else { throw RetentionError.notEnrolled }
        try setTTL(id: id, days: record.ttlDays, now: now)
    }

    public mutating func protect(id: String, reference: String) {
        guard var record = records[id] else { return }
        record.dependencyRefs.insert(reference)
        record.quarantinedAtEpochMs = nil
        records[id] = record
    }

    /// Caller must hold the same Vault mutation lock used for notes and links.
    /// External dependency writers register protection before creating the link.
    public mutating func sweep(now: Int, existingIDs: Set<String>, linkedIDs: Set<String>) -> [String] {
        var purged: [String] = []
        for id in records.keys.sorted() {
            guard existingIDs.contains(id), var record = records[id] else { continue }
            if linkedIDs.contains(id) { record.dependencyRefs.insert("vault-link") }
            if record.isProtected {
                record.quarantinedAtEpochMs = nil
            } else if let purgeAt = record.purgeAtEpochMs, now >= purgeAt {
                purged.append(id)
                deletedIDs.insert(id)
                records.removeValue(forKey: id)
                continue
            } else if record.quarantinedAtEpochMs == nil, now >= record.expiresAtEpochMs {
                // Downtime must never skip the visible seven-day recovery period.
                record.quarantinedAtEpochMs = now
            }
            records[id] = record
        }
        return purged
    }

    private static func validate(days: Int) throws {
        guard (1...3650).contains(days) else { throw RetentionError.invalidDays }
    }

    public enum RetentionError: Error { case invalidDays, deleted, notEnrolled }
}
