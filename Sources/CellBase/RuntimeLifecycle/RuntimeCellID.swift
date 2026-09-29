// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Stable runtime identifier for lifecycle scheduling.
/// Keep separate from reducer state to avoid introducing non-deterministic concerns.
public struct RuntimeCellID: Hashable, Codable, Sendable, RawRepresentable {
    @UUIDText public private(set) var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.$rawValue == rhs.$rawValue }
    public static func != (lhs: Self, rhs: Self) -> Bool { !(lhs == rhs) }
    public func hash(into hasher: inout Hasher) { $rawValue.hash(into: &hasher) }
}
