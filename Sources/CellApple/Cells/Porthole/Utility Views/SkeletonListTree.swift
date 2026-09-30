// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import CellBase

/// Visible pre-order row, with its source path retained independently of its visible index.
struct SkeletonListTreeRow {
    let value: ValueType
    let path: [Int]
    let depth: Int
    let identity: String
    let hasChildren: Bool
    let expanded: Bool
}

/// Snapshot-only counterparts of Porthole's listRowIdentity, listRowChildren and
/// flattenListTree. This code has no Cell, action handler or asynchronous reads.
enum SkeletonListTree {
    static func identity(_ value: ValueType, selectionValueKeypath: String?, path: [Int]) -> String {
        if case .object(let object) = value {
            // Porthole uses a direct property lookup for the identity key (also
            // when it contains a dot); only childrenKeypath traverses nested data.
            for key in [selectionValueKeypath, "id", "uuid"].compactMap({ $0 }) where !key.isEmpty {
                if let identity = object[key], identity != .null {
                    return identityString(identity)
                }
            }
        }
        return "#" + path.map(String.init).joined(separator: ".")
    }

    static func children(_ value: ValueType, keypath: String?) -> ValueTypeList {
        guard let keypath, !keypath.isEmpty else { return [] }
        if case .object(let object) = value, case .list(let children)? = object[keypath] {
            return children
        }
        if case .list(let children)? = SkeletonRenderDataContext.value(keypath, in: value) {
            return children
        }
        return []
    }

    static func initialExpansion(keypath: String?, value: ValueType?) -> Set<String> {
        guard let keypath, !keypath.isEmpty else { return ["*"] }
        switch value {
        case .string("*"): return ["*"]
        case .list(let identities): return Set(identities.map(identityString))
        default: return []
        }
    }

    static func flatten(
        _ rows: ValueTypeList,
        childrenKeypath: String?,
        selectionValueKeypath: String? = nil,
        expanded: Set<String>? = nil,
        expandedStateKeypath: String? = nil,
        expandedStateValue: ValueType? = nil
    ) -> [SkeletonListTreeRow] {
        let open = expanded ?? initialExpansion(keypath: expandedStateKeypath, value: expandedStateValue)
        var result: [SkeletonListTreeRow] = []
        func walk(_ values: ValueTypeList, path: [Int]) {
            for (index, value) in values.enumerated() {
                let rowPath = path + [index]
                let id = identity(value, selectionValueKeypath: selectionValueKeypath, path: rowPath)
                let childRows = children(value, keypath: childrenKeypath)
                let isExpanded = !childRows.isEmpty && (open.contains("*") || open.contains(id))
                result.append(.init(value: value, path: rowPath, depth: path.count,
                                    identity: id, hasChildren: !childRows.isEmpty, expanded: isExpanded))
                if isExpanded { walk(childRows, path: rowPath) }
            }
        }
        walk(rows, path: [])
        return result
    }

    /// JSON identity coercion follows JavaScript String(value), including list
    /// seed entries. Null row IDs are filtered before calling this function.
    private static func identityString(_ value: ValueType) -> String {
        switch value {
        case .string(let value): return value
        case .integer(let value), .number(let value): return String(value)
        case .float(let value):
            if value == 0 { return "0" }
            return numberIdentity(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .list(let values):
            return values.map { $0 == .null ? "" : identityString($0) }.joined(separator: ",")
        default: return "[object Object]"
        }
    }

    private static func numberIdentity(_ value: Double) -> String {
        let raw = String(value)
        let parts = raw.lowercased().split(separator: "e")
        guard parts.count == 2, let exponent = Int(parts[1]) else {
            return raw.hasSuffix(".0") ? String(raw.dropLast(2)) : raw
        }
        let negative = value < 0
        let rawMantissa = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let mantissa = rawMantissa.hasSuffix(".0") ? String(rawMantissa.dropLast(2)) : rawMantissa
        let digits = mantissa.replacingOccurrences(of: ".", with: "")
        if abs(value) >= 1e-6 && abs(value) < 1e21 {
            let point = 1 + exponent
            let sign = negative ? "-" : ""
            if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + digits }
            if point >= digits.count { return sign + digits + String(repeating: "0", count: point - digits.count) }
            let index = digits.index(digits.startIndex, offsetBy: point)
            return sign + digits[..<index] + "." + digits[index...]
        }
        return (negative ? "-" : "") + mantissa + "e" + (exponent >= 0 ? "+" : "") + String(exponent)
    }
}

/// Kept by CellListView across data refreshes. An unchanged seed preserves local
/// toggles; a changed seed replaces them, as in Porthole's seedExpandedFromState.
struct SkeletonListTreeExpansion {
    private(set) var expanded: Set<String>?
    private var seedSignature: String?

    func seeded(keypath: String?, value: ValueType?) -> Self {
        var next = self
        guard let keypath, !keypath.isEmpty else {
            if next.expanded == nil { next.expanded = ["*"] }
            return next
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let signature = (try? encoder.encode(value ?? .null)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        if signature != seedSignature || expanded == nil {
            next.seedSignature = signature
            next.expanded = SkeletonListTree.initialExpansion(keypath: keypath, value: value)
        }
        return next
    }

    mutating func toggle(_ row: SkeletonListTreeRow, visibleRows: [SkeletonListTreeRow]) {
        guard row.hasChildren else { return }
        var identities = expanded ?? []
        if identities.remove("*") != nil {
            identities.formUnion(visibleRows.filter { $0.hasChildren && $0.expanded }.map(\.identity))
        }
        if !identities.insert(row.identity).inserted { identities.remove(row.identity) }
        expanded = identities
    }
}
