// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// A JSON value inside a rich-text delta: attribute values and embed objects.
/// Encodes as plain JSON, so a delta from Swift is byte-compatible with the
/// web document adapter (Quill) and with `haven.document.change.v1`.
public enum RichTextValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([RichTextValue])
    case object([String: RichTextValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([RichTextValue].self) { self = .array(value); return }
        self = .object(try container.decode([String: RichTextValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public typealias RichTextAttributes = [String: RichTextValue]

/// One Quill delta operation. Lengths are UTF-16 code units; an embed counts 1
/// and stands for U+FFFC in the text, as in `NSTextAttachment`.
public struct RichTextOp: Codable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case insertText(String)
        case insertEmbed([String: RichTextValue])
        case retain(Int)
        case delete(Int)
    }

    public var kind: Kind
    public var attributes: RichTextAttributes?

    public init(_ kind: Kind, attributes: RichTextAttributes? = nil) {
        self.kind = kind
        self.attributes = (attributes?.isEmpty ?? true) ? nil : attributes
    }

    public static func insert(_ text: String, _ attributes: RichTextAttributes? = nil) -> RichTextOp { RichTextOp(.insertText(text), attributes: attributes) }
    public static func embed(_ value: [String: RichTextValue], _ attributes: RichTextAttributes? = nil) -> RichTextOp { RichTextOp(.insertEmbed(value), attributes: attributes) }
    public static func retain(_ count: Int, _ attributes: RichTextAttributes? = nil) -> RichTextOp { RichTextOp(.retain(count), attributes: attributes) }
    public static func delete(_ count: Int) -> RichTextOp { RichTextOp(.delete(count)) }

    public var length: Int {
        switch kind {
        case .insertText(let text): return text.utf16.count
        case .insertEmbed: return 1
        case .retain(let count), .delete(let count): return count
        }
    }

    public var isInsert: Bool { if case .insertText = kind { return true }; if case .insertEmbed = kind { return true }; return false }
    public var isDelete: Bool { if case .delete = kind { return true }; return false }
    public var isRetain: Bool { if case .retain = kind { return true }; return false }

    private enum CodingKeys: String, CodingKey { case insert, retain, delete, attributes }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let attributes = try container.decodeIfPresent(RichTextAttributes.self, forKey: .attributes)
        if let text = try? container.decode(String.self, forKey: .insert) {
            self.init(.insertText(text), attributes: attributes)
        } else if let embed = try? container.decode([String: RichTextValue].self, forKey: .insert) {
            self.init(.insertEmbed(embed), attributes: attributes)
        } else if let count = try container.decodeIfPresent(Int.self, forKey: .retain) {
            self.init(.retain(count), attributes: attributes)
        } else if let count = try container.decodeIfPresent(Int.self, forKey: .delete) {
            self.init(.delete(count))
        } else {
            throw Swift.DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Delta op needs insert, retain or delete"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch kind {
        case .insertText(let text): try container.encode(text, forKey: .insert)
        case .insertEmbed(let embed): try container.encode(embed, forKey: .insert)
        case .retain(let count): try container.encode(count, forKey: .retain)
        case .delete(let count): try container.encode(count, forKey: .delete)
        }
        if let attributes, !attributes.isEmpty { try container.encode(attributes, forKey: .attributes) }
    }
}

/// Quill-delta semantics (quill-delta 5: push, chop, compose, transform,
/// transformPosition) in pure Swift. The shared fixture corpus
/// `Tests/CellBaseTests/Fixtures/RichTextDeltaVectors.v1.json` is run both
/// here and against the Quill bundle the web document adapter loads.
public struct RichTextDelta: Codable, Hashable, Sendable {
    public private(set) var ops: [RichTextOp]

    /// Keeps the ops as given, like `new Delta(ops)` in Quill.
    public init(_ ops: [RichTextOp] = []) { self.ops = ops }

    /// The same change with adjacent ops merged as `push` merges them.
    public var normalized: RichTextDelta {
        var result = RichTextDelta()
        for op in ops { result.push(op) }
        return result
    }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode([RichTextOp].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ops)
    }

    /// Total length of the inserts (the document length when the delta is a document).
    public var length: Int { ops.reduce(0) { $0 + $1.length } }
    public var isDocument: Bool { ops.allSatisfy(\.isInsert) }

    // MARK: Building

    public mutating func insert(_ text: String, _ attributes: RichTextAttributes? = nil) {
        guard !text.isEmpty else { return }
        push(.insert(text, attributes))
    }

    public mutating func retain(_ count: Int, _ attributes: RichTextAttributes? = nil) {
        guard count > 0 else { return }
        push(.retain(count, attributes))
    }

    public mutating func delete(_ count: Int) {
        guard count > 0 else { return }
        push(.delete(count))
    }

    public mutating func push(_ newOp: RichTextOp) {
        if newOp.length == 0, !(newOp.isInsert) { return }
        if case .insertText(let text) = newOp.kind, text.isEmpty { return }
        var index = ops.count
        if index > 0 {
            var lastOp = ops[index - 1]
            if case .delete(let a) = lastOp.kind, case .delete(let b) = newOp.kind {
                ops[index - 1] = .delete(a + b); return
            }
            // Inserts go before deletes so equal deltas have one shape.
            if lastOp.isDelete, newOp.isInsert {
                index -= 1
                if index == 0 { ops.insert(newOp, at: 0); return }
                lastOp = ops[index - 1]
            }
            if lastOp.attributes == newOp.attributes {
                if case .insertText(let a) = lastOp.kind, case .insertText(let b) = newOp.kind {
                    ops[index - 1] = .insert(a + b, newOp.attributes); return
                }
                if case .retain(let a) = lastOp.kind, case .retain(let b) = newOp.kind {
                    ops[index - 1] = .retain(a + b, newOp.attributes); return
                }
            }
        }
        if index == ops.count { ops.append(newOp) } else { ops.insert(newOp, at: index) }
    }

    /// Drops a trailing plain retain, which changes nothing.
    public func chopped() -> RichTextDelta {
        var copy = self
        if let last = copy.ops.last, case .retain = last.kind, last.attributes == nil { copy.ops.removeLast() }
        return copy
    }

    // MARK: Compose / transform

    public func compose(_ other: RichTextDelta) -> RichTextDelta {
        var thisIter = RichTextOpIterator(ops)
        var otherIter = RichTextOpIterator(other.ops)
        var result = RichTextDelta()
        if let firstOther = otherIter.peek(), case .retain(let firstRetain) = firstOther.kind, firstOther.attributes == nil {
            var firstLeft = firstRetain
            while thisIter.peekType == .insert, thisIter.peekLength <= firstLeft {
                firstLeft -= thisIter.peekLength
                result.ops.append(thisIter.next()) // Quill collects these unmerged
            }
            if firstRetain - firstLeft > 0 { _ = otherIter.next(firstRetain - firstLeft) }
        }
        while thisIter.hasNext || otherIter.hasNext {
            if otherIter.peekType == .insert {
                result.push(otherIter.next())
            } else if thisIter.peekType == .delete {
                result.push(thisIter.next())
            } else {
                let length = min(thisIter.peekLength, otherIter.peekLength)
                let thisOp = thisIter.next(length)
                let otherOp = otherIter.next(length)
                if otherOp.isRetain {
                    let newKind: RichTextOp.Kind = thisOp.isRetain ? .retain(length) : thisOp.kind
                    let attributes = Self.composeAttributes(thisOp.attributes, otherOp.attributes, keepNull: thisOp.isRetain)
                    let newOp = RichTextOp(newKind, attributes: attributes)
                    result.push(newOp)
                    if !otherIter.hasNext, result.ops.last == newOp {
                        // Quill's concat: the first op merges, the rest is appended as is.
                        let rest = thisIter.rest()
                        if let first = rest.first {
                            result.push(first)
                            result.ops.append(contentsOf: rest.dropFirst())
                        }
                        return result.chopped()
                    }
                } else if otherOp.isDelete, thisOp.isRetain {
                    result.push(otherOp)
                }
                // other deletes an insert of ours: both vanish.
            }
        }
        return result.chopped()
    }

    /// Transforms `other` against this delta. With `priority`, this delta
    /// happened first (its inserts go before others at the same position).
    public func transform(_ other: RichTextDelta, priority: Bool) -> RichTextDelta {
        var thisIter = RichTextOpIterator(ops)
        var otherIter = RichTextOpIterator(other.ops)
        var result = RichTextDelta()
        while thisIter.hasNext || otherIter.hasNext {
            if thisIter.peekType == .insert, priority || otherIter.peekType != .insert {
                result.retain(thisIter.next().length)
            } else if otherIter.peekType == .insert {
                result.push(otherIter.next())
            } else {
                let length = min(thisIter.peekLength, otherIter.peekLength)
                let thisOp = thisIter.next(length)
                let otherOp = otherIter.next(length)
                if thisOp.isDelete { continue }
                if otherOp.isDelete { result.push(otherOp); continue }
                result.retain(length, Self.transformAttributes(thisOp.attributes, otherOp.attributes, priority: priority))
            }
        }
        return result.chopped()
    }

    public func transformPosition(_ position: Int, priority: Bool = false) -> Int {
        var index = position
        var iter = RichTextOpIterator(ops)
        var offset = 0
        while iter.hasNext, offset <= index {
            let length = iter.peekLength
            let type = iter.peekType
            _ = iter.next()
            if type == .delete { index -= min(length, index - offset); continue }
            if type == .insert, offset < index || !priority { index += length }
            offset += length
        }
        return index
    }

    static func composeAttributes(_ a: RichTextAttributes?, _ b: RichTextAttributes?, keepNull: Bool) -> RichTextAttributes? {
        var attributes = b ?? [:]
        if !keepNull { attributes = attributes.filter { $0.value != .null } }
        for (key, value) in a ?? [:] where b?[key] == nil { attributes[key] = value }
        return attributes.isEmpty ? nil : attributes
    }

    static func transformAttributes(_ a: RichTextAttributes?, _ b: RichTextAttributes?, priority: Bool) -> RichTextAttributes? {
        guard let a else { return b }
        guard let b else { return nil }
        guard priority else { return b }
        let attributes = b.filter { a[$0.key] == nil }
        return attributes.isEmpty ? nil : attributes
    }
}

/// Walks ops in UTF-16 units, splitting them on demand (Quill's OpIterator).
public struct RichTextOpIterator {
    public enum OpType { case insert, retain, delete }

    private let ops: [RichTextOp]
    private var index = 0
    private var offset = 0

    public init(_ ops: [RichTextOp]) { self.ops = ops }

    public var hasNext: Bool { peekLength < Int.max }

    public func peek() -> RichTextOp? { index < ops.count ? ops[index] : nil }

    public var peekLength: Int { index < ops.count ? ops[index].length - offset : Int.max }

    public var peekType: OpType {
        guard index < ops.count else { return .retain }
        switch ops[index].kind {
        case .delete: return .delete
        case .retain: return .retain
        default: return .insert
        }
    }

    public mutating func next(_ requested: Int = Int.max) -> RichTextOp {
        guard index < ops.count else { return .retain(Int.max) }
        let op = ops[index]
        let start = offset
        let opLength = op.length
        var length = requested
        if length >= opLength - start {
            length = opLength - start
            index += 1
            offset = 0
        } else {
            offset += length
        }
        switch op.kind {
        case .delete: return .delete(length)
        case .retain: return .retain(length, op.attributes)
        case .insertEmbed: return op
        case .insertText(let text):
            if start == 0, length == opLength { return op }
            let units = Array(text.utf16)[start..<(start + length)]
            return .insert(String(decoding: units, as: UTF16.self), op.attributes)
        }
    }

    public mutating func rest() -> [RichTextOp] {
        guard hasNext else { return [] }
        if offset == 0 { return Array(ops[index...]) }
        let savedIndex = index, savedOffset = offset
        let first = next()
        let remaining = Array(ops[index...])
        index = savedIndex; offset = savedOffset
        return [first] + remaining
    }
}

// MARK: - Documents

extension RichTextDelta {
    /// One unit of a document: a UTF-16 code unit, or an embed (U+FFFC).
    public struct Unit: Hashable, Sendable {
        public var codeUnit: UInt16
        public var embed: [String: RichTextValue]?
        public var attributes: RichTextAttributes

        public init(codeUnit: UInt16, embed: [String: RichTextValue]? = nil, attributes: RichTextAttributes = [:]) {
            self.codeUnit = codeUnit
            self.embed = embed
            self.attributes = attributes
        }
    }

    public static let objectReplacementCharacter: UInt16 = 0xFFFC

    /// Flattens a document (inserts only) to units.
    public var units: [Unit] {
        ops.flatMap { op -> [Unit] in
            let attributes = op.attributes ?? [:]
            switch op.kind {
            case .insertText(let text): return text.utf16.map { Unit(codeUnit: $0, embed: nil, attributes: attributes) }
            case .insertEmbed(let embed): return [Unit(codeUnit: Self.objectReplacementCharacter, embed: embed, attributes: attributes)]
            default: return []
            }
        }
    }

    public init(units: some Sequence<Unit>) {
        self.init()
        var pending: [UInt16] = []
        var pendingAttributes: RichTextAttributes = [:]
        func flush(_ delta: inout RichTextDelta) {
            guard !pending.isEmpty else { return }
            delta.push(.insert(String(decoding: pending, as: UTF16.self), pendingAttributes))
            pending.removeAll()
        }
        for unit in units {
            if let embed = unit.embed {
                flush(&self)
                push(.embed(embed, unit.attributes))
                continue
            }
            if unit.attributes != pendingAttributes { flush(&self); pendingAttributes = unit.attributes }
            pending.append(unit.codeUnit)
        }
        flush(&self)
    }

    /// Plain text of a document, with U+FFFC for each embed.
    public var plainText: String {
        String(decoding: units.map(\.codeUnit), as: UTF16.self)
    }

    /// The change that turns document `old` into document `new`. Unchanged
    /// units at both ends are retained; a middle of equal text with other
    /// attributes becomes attribute retains (so comments and concurrent edits
    /// keep their place); anything else is delete + insert. `cursor`, when
    /// given, keeps the common prefix from running past the edit position,
    /// so typing "a" after "a" inserts where the user typed.
    public static func diff(from old: RichTextDelta, to new: RichTextDelta, cursor: Int? = nil) -> RichTextDelta {
        let a = old.units, b = new.units
        var prefix = 0
        let prefixLimit = min(a.count, b.count, cursor ?? Int.max)
        while prefix < prefixLimit, a[prefix] == b[prefix] { prefix += 1 }
        // Never split a surrogate pair: a lone surrogate cannot be a String.
        func isLow(_ unit: Unit) -> Bool { unit.embed == nil && (0xDC00...0xDFFF).contains(unit.codeUnit) }
        while prefix > 0, (prefix < a.count && isLow(a[prefix])) || (prefix < b.count && isLow(b[prefix])) { prefix -= 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        while suffix > 0, isLow(a[a.count - suffix]) || isLow(b[b.count - suffix]) { suffix -= 1 }
        let oldMiddle = Array(a[prefix..<(a.count - suffix)])
        let newMiddle = Array(b[prefix..<(b.count - suffix)])
        var delta = RichTextDelta()
        delta.retain(prefix)
        if oldMiddle.count == newMiddle.count,
           zip(oldMiddle, newMiddle).allSatisfy({ $0.codeUnit == $1.codeUnit && $0.embed == $1.embed }) {
            for (before, after) in zip(oldMiddle, newMiddle) {
                var change: RichTextAttributes = after.attributes.filter { before.attributes[$0.key] != $0.value }
                for key in before.attributes.keys where after.attributes[key] == nil { change[key] = .null }
                delta.retain(1, change)
            }
        } else {
            delta.delete(oldMiddle.count)
            for op in RichTextDelta(units: newMiddle).ops { delta.push(op) }
        }
        return delta.chopped()
    }
}
