// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  SkeletonDataBinding.swift
//  CellBase
//
//  Shared resolution rules for the data-bound fields added for artist pages
//  (PDD kunstnerside-som-flate, capabilities C, D and E):
//
//  - C: `SkeletonImage.urlKeypath` / `altKeypath` pick the image from row data.
//  - D: `SkeletonModifiers.linkURL` / `linkURLKeypath` make a whole element
//    (for example a work card) one link.
//  - E: `SkeletonModifiers.styleVariables` / `styleVariablesKeypath` set theme
//    colours from data, so the owner can change them without editing CSS.
//
//  Every renderer uses these helpers, so web and native agree on which value
//  wins. Renderers still decide which links they open
//  (`SkeletonButtonNavigation.resolveURL`).
//

import Foundation

/// Theme colours a skeleton may set from data. A closed list, not free CSS:
/// renderers map each name to their own token (web: `--haven-<name>`).
public enum SkeletonStyleVariables {
    public static let allowedNames: [String] = ["accent", "ink", "paper", "line", "muted", "surface"]

    public static func isAllowedName(_ name: String) -> Bool {
        allowedNames.contains(name)
    }

    /// `#RRGGBB` or `#RRGGBBAA`, the same hex form `background` uses.
    public static func isColor(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return false }
        let hex = trimmed.dropFirst()
        guard hex.count == 6 || hex.count == 8 else { return false }
        return hex.allSatisfy { $0.isHexDigit }
    }

    /// Keeps only allowed names with valid colours. Data from a cell is never
    /// trusted to be well formed, so invalid entries are dropped, not thrown.
    public static func sanitized(_ value: ValueType?) -> [String: String] {
        guard case let .object(object)? = value else { return [:] }
        var result: [String: String] = [:]
        for (name, entry) in object {
            guard isAllowedName(name), case let .string(color) = entry, isColor(color) else { continue }
            result[name] = color.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    /// Static variables first, then data from `styleVariablesKeypath` on the
    /// row (or root) value. Data wins, so the owner's choice overrides the template.
    public static func resolve(_ modifiers: SkeletonModifiers?, item: ValueType?) -> [String: String] {
        var result: [String: String] = [:]
        for (name, color) in modifiers?.styleVariables ?? [:] where isAllowedName(name) && isColor(color) {
            result[name] = color
        }
        let fromData = sanitized(SkeletonDataBinding.value(at: modifiers?.styleVariablesKeypath, in: item))
        result.merge(fromData) { _, new in new }
        return result
    }
}

public enum SkeletonDataBinding {
    /// Resolves a dotted keypath on an object value. Nil for anything else.
    public static func value(at keypath: String?, in item: ValueType?) -> ValueType? {
        guard let keypath = normalized(keypath), case let .object(object)? = item else { return nil }
        return try? object.get(keypath: keypath)
    }

    public static func string(at keypath: String?, in item: ValueType?) -> String? {
        guard case let .string(value)? = value(at: keypath, in: item) else { return nil }
        return normalized(value)
    }

    /// D: the link for a whole element. A row value wins over the static link.
    /// The result is unvetted; open it only through `SkeletonButtonNavigation`.
    public static func linkURL(_ modifiers: SkeletonModifiers?, item: ValueType?) -> String? {
        string(at: modifiers?.linkURLKeypath, in: item) ?? normalized(modifiers?.linkURL)
    }

    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public extension SkeletonImage {
    /// C: the image URL string for this row. Row data wins over the static `url`.
    /// Nil means "no image"; renderers show their missing-image state.
    func resolvedURLString(item: ValueType?) -> String? {
        if urlKeypath != nil {
            return SkeletonDataBinding.string(at: urlKeypath, in: item)
        }
        return url?.absoluteString
    }

    func resolvedAlt(item: ValueType?) -> String? {
        SkeletonDataBinding.string(at: altKeypath, in: item) ?? SkeletonDataBinding.normalized(alt)
    }
}
