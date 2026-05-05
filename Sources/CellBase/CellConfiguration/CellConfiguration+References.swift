// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public extension CellConfiguration {
    /// Read-only dictionary view of references indexed by `CellReference.id`.
    public var referencesDict: [String: CellReference] {
        var dict: [String: CellReference] = [:]
        for ref in cellReferences ?? [] {
            dict[ref.id] = ref
        }
        return dict
    }

    /// Read, insert/replace, or remove a reference by id.
    public subscript(referenceId id: String) -> CellReference? {
        get {
            cellReferences?.first(where: { $0.id == id })
        }
        set {
            if let value = newValue {
                if cellReferences == nil {
                    cellReferences = []
                }
                if let idx = cellReferences?.firstIndex(where: { $0.id == id }) {
                    cellReferences?[idx] = value
                } else {
                    cellReferences?.append(value)
                }
            } else {
                cellReferences?.removeAll(where: { $0.id == id })
            }
        }
    }

    /// Returns true when a reference exists for the given id.
    public func containsReference(withId id: String) -> Bool {
        cellReferences?.contains(where: { $0.id == id }) ?? false
    }

    /// Insert or replace a reference based on id.
    public mutating func addOrReplaceReference(_ ref: CellReference) {
        self[referenceId: ref.id] = ref
    }

    /// Remove a reference by id and return true when an item was removed.
    @discardableResult
    public mutating func removeReference(withId id: String) -> Bool {
        let before = cellReferences?.count ?? 0
        self[referenceId: id] = nil
        let after = cellReferences?.count ?? 0
        return after < before
    }
}
