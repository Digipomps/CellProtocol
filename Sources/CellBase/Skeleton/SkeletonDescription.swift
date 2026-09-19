// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  SkeletonDescription.swift
//  CellProtocol
//
//  Created by Kjetil Hustveit on 22/10/2024.
//
import Foundation

private let skeletonUnavailableUserMessage = "Innholdet er ikke tilgjengelig akkurat nå."

private func skeletonLooksLikeUserFacingTechnicalFailure(_ string: String) -> Bool {
    let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\""))
    let normalized = string.trimmingCharacters(in: trimSet).lowercased()
    guard normalized.isEmpty == false else { return false }
    return normalized.hasPrefix("failure:")
        || normalized == "failure"
        || normalized.hasPrefix("denied(")
        || normalized.contains("consume command get failed")
        || normalized.contains("cellauthorizationdecision")
        || normalized.contains("deniednogrant")
        || normalized.contains("no verified owner proof")
        || normalized.contains("getting content failed with error:")
}

private func skeletonUserFacingString(_ string: String) -> String {
    skeletonLooksLikeUserFacingTechnicalFailure(string) ? skeletonUnavailableUserMessage : string
}

public typealias SkeletonElementList = [SkeletonElement]
public typealias SkeletonElementObject = [String: SkeletonElement]

public enum SkeletonMotionHint: String, Codable, CaseIterable {
    case appear
    case expand
    case collapse
    case minimize
    case restore
    case replace
    case emphasize
}

public enum SkeletonPresentationKind: String, Codable, CaseIterable {
    case overlay
    case drawer
    case sheet
    case popover
    case modal
}

public enum SkeletonPresentationPlacement: String, Codable, CaseIterable {
    case leading
    case trailing
    case top
    case bottom
    case center
    case anchor
}

public enum SkeletonBackdropStyle: String, Codable, CaseIterable {
    case none
    case dim
    case blur
}

public enum SkeletonDismissBehavior: String, Codable, CaseIterable {
    case disabled
    case closeAction
}

public struct SkeletonPresentationFallback: Codable, Equatable {
    public var kind: SkeletonPresentationKind?
    public var placement: SkeletonPresentationPlacement?

    public init(
        kind: SkeletonPresentationKind? = nil,
        placement: SkeletonPresentationPlacement? = nil
    ) {
        self.kind = kind
        self.placement = placement
    }
}

public struct SkeletonPresentation: Codable, Equatable {
    public var kind: SkeletonPresentationKind
    public var placement: SkeletonPresentationPlacement?
    public var closeActionKeypath: String?
    public var openStateKeypath: String?
    public var dismissOnBackdrop: Bool?
    public var backdropStyle: SkeletonBackdropStyle?
    public var escapeKeyBehavior: SkeletonDismissBehavior?
    public var focusTrap: Bool?
    public var anchorRole: String?
    public var anchorKeypath: String?
    public var zIndex: Int?
    public var mobileFallback: SkeletonPresentationFallback?
    public var accessibilityLabel: String?

    public init(
        kind: SkeletonPresentationKind,
        placement: SkeletonPresentationPlacement? = nil,
        closeActionKeypath: String? = nil,
        openStateKeypath: String? = nil,
        dismissOnBackdrop: Bool? = nil,
        backdropStyle: SkeletonBackdropStyle? = nil,
        escapeKeyBehavior: SkeletonDismissBehavior? = nil,
        focusTrap: Bool? = nil,
        anchorRole: String? = nil,
        anchorKeypath: String? = nil,
        zIndex: Int? = nil,
        mobileFallback: SkeletonPresentationFallback? = nil,
        accessibilityLabel: String? = nil
    ) {
        self.kind = kind
        self.placement = placement
        self.closeActionKeypath = closeActionKeypath
        self.openStateKeypath = openStateKeypath
        self.dismissOnBackdrop = dismissOnBackdrop
        self.backdropStyle = backdropStyle
        self.escapeKeyBehavior = escapeKeyBehavior
        self.focusTrap = focusTrap
        self.anchorRole = anchorRole
        self.anchorKeypath = anchorKeypath
        self.zIndex = zIndex
        self.mobileFallback = mobileFallback
        self.accessibilityLabel = accessibilityLabel
    }
}

public enum SkeletonVisibilityScope: String, Codable, CaseIterable {
    case root
    case item
    case context
}

public struct SkeletonVisibilityRule: Codable, Equatable {
    public var when: SkeletonCondition?

    enum CodingKeys: String, CodingKey {
        case when
    }

    public init(when: SkeletonCondition? = nil) {
        self.when = when
    }

    public init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.when = .expression(SkeletonConditionExpression(isMalformed: true))
            return
        }
        do {
            self.when = try container.decodeIfPresent(SkeletonCondition.self, forKey: .when)
        } catch {
            self.when = .expression(SkeletonConditionExpression(isMalformed: true))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(when, forKey: .when)
    }

    public func isVisible(root: ValueType? = nil, item: ValueType? = nil, context: ValueType? = nil) -> Bool {
        guard let when else {
            return true
        }
        return when.evaluate(root: root, item: item, context: context)
    }
}

public indirect enum SkeletonCondition: Codable, Equatable {
    case expression(SkeletonConditionExpression)

    public init(
        scope: SkeletonVisibilityScope? = nil,
        keypath: String? = nil,
        exists: Bool? = nil,
        equals: ValueType? = nil,
        notEquals: ValueType? = nil,
        inValues: [ValueType]? = nil,
        contains: ValueType? = nil,
        allOf: [SkeletonCondition]? = nil,
        anyOf: [SkeletonCondition]? = nil,
        not: SkeletonCondition? = nil
    ) {
        self = .expression(
            SkeletonConditionExpression(
                scope: scope,
                keypath: keypath,
                exists: exists,
                equals: equals,
                notEquals: notEquals,
                inValues: inValues,
                contains: contains,
                allOf: allOf,
                anyOf: anyOf,
                not: not
            )
        )
    }

    public init(from decoder: any Decoder) throws {
        self = .expression(try SkeletonConditionExpression(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .expression(let expression):
            try expression.encode(to: encoder)
        }
    }

    public func evaluate(root: ValueType? = nil, item: ValueType? = nil, context: ValueType? = nil) -> Bool {
        switch self {
        case .expression(let expression):
            return expression.evaluate(root: root, item: item, context: context)
        }
    }
}

public struct SkeletonConditionExpression: Codable, Equatable {
    public var scope: SkeletonVisibilityScope?
    public var keypath: String?
    public var exists: Bool?
    public var equals: ValueType?
    public var notEquals: ValueType?
    public var inValues: [ValueType]?
    public var contains: ValueType?
    public var allOf: [SkeletonCondition]?
    public var anyOf: [SkeletonCondition]?
    public var not: SkeletonCondition?
    public var isMalformed: Bool

    enum CodingKeys: String, CodingKey {
        case scope
        case keypath
        case exists
        case equals
        case notEquals
        case inValues = "in"
        case contains
        case allOf
        case anyOf
        case not
    }

    public init(
        scope: SkeletonVisibilityScope? = nil,
        keypath: String? = nil,
        exists: Bool? = nil,
        equals: ValueType? = nil,
        notEquals: ValueType? = nil,
        inValues: [ValueType]? = nil,
        contains: ValueType? = nil,
        allOf: [SkeletonCondition]? = nil,
        anyOf: [SkeletonCondition]? = nil,
        not: SkeletonCondition? = nil,
        isMalformed: Bool = false
    ) {
        self.scope = scope
        self.keypath = keypath
        self.exists = exists
        self.equals = equals
        self.notEquals = notEquals
        self.inValues = inValues
        self.contains = contains
        self.allOf = allOf
        self.anyOf = anyOf
        self.not = not
        self.isMalformed = isMalformed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var isMalformed = false

        if container.contains(.scope) {
            do {
                if let rawScope = try container.decodeIfPresent(String.self, forKey: .scope) {
                    if let scope = SkeletonVisibilityScope(rawValue: rawScope) {
                        self.scope = scope
                    } else {
                        self.scope = nil
                        isMalformed = true
                    }
                } else {
                    self.scope = nil
                }
            } catch {
                self.scope = nil
                isMalformed = true
            }
        } else {
            self.scope = nil
        }

        do {
            self.keypath = try container.decodeIfPresent(String.self, forKey: .keypath)
        } catch {
            self.keypath = nil
            isMalformed = true
        }
        do {
            self.exists = try container.decodeIfPresent(Bool.self, forKey: .exists)
        } catch {
            self.exists = nil
            isMalformed = true
        }
        do {
            self.equals = try container.decodeIfPresent(ValueType.self, forKey: .equals)
        } catch {
            self.equals = nil
            isMalformed = true
        }
        do {
            self.notEquals = try container.decodeIfPresent(ValueType.self, forKey: .notEquals)
        } catch {
            self.notEquals = nil
            isMalformed = true
        }
        do {
            self.inValues = try container.decodeIfPresent([ValueType].self, forKey: .inValues)
        } catch {
            self.inValues = nil
            isMalformed = true
        }
        do {
            self.contains = try container.decodeIfPresent(ValueType.self, forKey: .contains)
        } catch {
            self.contains = nil
            isMalformed = true
        }
        do {
            self.allOf = try container.decodeIfPresent([SkeletonCondition].self, forKey: .allOf)
        } catch {
            self.allOf = nil
            isMalformed = true
        }
        do {
            self.anyOf = try container.decodeIfPresent([SkeletonCondition].self, forKey: .anyOf)
        } catch {
            self.anyOf = nil
            isMalformed = true
        }
        do {
            self.not = try container.decodeIfPresent(SkeletonCondition.self, forKey: .not)
        } catch {
            self.not = nil
            isMalformed = true
        }

        self.isMalformed = isMalformed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(scope, forKey: .scope)
        try container.encodeIfPresent(keypath, forKey: .keypath)
        try container.encodeIfPresent(exists, forKey: .exists)
        try container.encodeIfPresent(equals, forKey: .equals)
        try container.encodeIfPresent(notEquals, forKey: .notEquals)
        try container.encodeIfPresent(inValues, forKey: .inValues)
        try container.encodeIfPresent(contains, forKey: .contains)
        try container.encodeIfPresent(allOf, forKey: .allOf)
        try container.encodeIfPresent(anyOf, forKey: .anyOf)
        try container.encodeIfPresent(not, forKey: .not)
    }

    public func evaluate(root: ValueType? = nil, item: ValueType? = nil, context: ValueType? = nil) -> Bool {
        if isMalformed {
            return false
        }

        var evaluatedAnyPredicate = false

        if let allOf {
            evaluatedAnyPredicate = true
            guard allOf.allSatisfy({ $0.evaluate(root: root, item: item, context: context) }) else {
                return false
            }
        }

        if let anyOf {
            evaluatedAnyPredicate = true
            guard anyOf.contains(where: { $0.evaluate(root: root, item: item, context: context) }) else {
                return false
            }
        }

        if let not {
            evaluatedAnyPredicate = true
            guard not.evaluate(root: root, item: item, context: context) == false else {
                return false
            }
        }

        let resolvedValue: ValueType?
        if let keypath, keypath.isEmpty == false {
            evaluatedAnyPredicate = true
            resolvedValue = Self.resolve(keypath: keypath, scope: scope ?? .root, root: root, item: item, context: context)
        } else {
            resolvedValue = nil
        }

        if let exists {
            evaluatedAnyPredicate = true
            guard (resolvedValue != nil) == exists else {
                return false
            }
        }

        if let equals {
            evaluatedAnyPredicate = true
            guard let resolvedValue, Self.valuesMatch(resolvedValue, equals) else {
                return false
            }
        }

        if let notEquals {
            evaluatedAnyPredicate = true
            guard let resolvedValue, Self.valuesMatch(resolvedValue, notEquals) == false else {
                return false
            }
        }

        if let inValues {
            evaluatedAnyPredicate = true
            guard let resolvedValue, inValues.contains(where: { Self.valuesMatch(resolvedValue, $0) }) else {
                return false
            }
        }

        if let contains {
            evaluatedAnyPredicate = true
            guard let resolvedValue, Self.value(resolvedValue, contains: contains) else {
                return false
            }
        }

        return evaluatedAnyPredicate
    }

    private static func resolve(
        keypath: String,
        scope: SkeletonVisibilityScope,
        root: ValueType?,
        item: ValueType?,
        context: ValueType?
    ) -> ValueType? {
        let scopedValue: ValueType?
        switch scope {
        case .root:
            scopedValue = root
        case .item:
            scopedValue = item ?? context
        case .context:
            scopedValue = context ?? item ?? root
        }

        guard let scopedValue else {
            return nil
        }

        if keypath == "." || keypath == "$" {
            return scopedValue
        }

        switch scopedValue {
        case .object(let object):
            return try? object.get(keypath: keypath)
        default:
            return nil
        }
    }

    private static func value(_ value: ValueType, contains candidate: ValueType) -> Bool {
        switch (value, candidate) {
        case (.string(let string), .string(let substring)):
            return string.contains(substring)
        case (.list(let list), _):
            return list.contains(where: { valuesMatch($0, candidate) })
        default:
            return false
        }
    }

    private static func valuesMatch(_ lhs: ValueType, _ rhs: ValueType) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.string(let lhs), .string(let rhs)):
            return lhs == rhs
        case (.bool(let lhs), .bool(let rhs)):
            return lhs == rhs
        case (.integer(let lhs), .integer(let rhs)):
            return lhs == rhs
        case (.number(let lhs), .number(let rhs)):
            return lhs == rhs
        case (.float(let lhs), .float(let rhs)):
            return lhs == rhs
        case (.integer(let lhs), .float(let rhs)),
            (.number(let lhs), .float(let rhs)):
            return Double(lhs) == rhs
        case (.float(let lhs), .integer(let rhs)),
            (.float(let lhs), .number(let rhs)):
            return lhs == Double(rhs)
        case (.integer(let lhs), .number(let rhs)),
            (.number(let lhs), .integer(let rhs)):
            return lhs == rhs
        default:
            return false
        }
    }
}

// MARK: - Portable layout and style contracts (WP-R1)

/// New fields fail with a field name; legacy lossy modifier decoding is unchanged.
public struct SkeletonFormatError: Error, Equatable, CustomStringConvertible {
    public let field: String
    public let reason: String
    public var description: String { "SkeletonFormatError[\(field)]: \(reason)" }
}

private func skeletonNumber(_ value: Double?, field: String, minimum: Double? = nil, positive: Bool = false) throws {
    guard let value else { return }
    guard value.isFinite else { throw SkeletonFormatError(field: field, reason: "must be finite") }
    if let minimum, value < minimum {
        throw SkeletonFormatError(field: field, reason: "must be >= \(minimum)")
    }
    if positive && value <= 0 { throw SkeletonFormatError(field: field, reason: "must be > 0") }
}

private func skeletonRange(_ minimum: Double?, _ maximum: Double?, field: String) throws {
    if let minimum, let maximum, minimum > maximum {
        throw SkeletonFormatError(field: field, reason: "minimum exceeds maximum")
    }
}

private func skeletonNonempty(_ value: String, field: String) throws {
    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw SkeletonFormatError(field: field, reason: "must not be blank")
    }
}

private extension KeyedDecodingContainer {
    func skeletonValue<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        do { return try decodeIfPresent(type, forKey: key) }
        catch { throw SkeletonFormatError(field: key.stringValue, reason: String(describing: error)) }
    }
    func skeletonRequired<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        do { return try decode(type, forKey: key) }
        catch { throw SkeletonFormatError(field: key.stringValue, reason: String(describing: error)) }
    }
}

/// Closed objects for the new typed structures. No CSS, actions, or legacy aliases.
private func skeletonKnownKeys(_ decoder: Decoder, allowed: [String]) throws {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    for key in container.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) where !allowed.contains(key.stringValue) {
        throw SkeletonFormatError(field: key.stringValue, reason: "unknown field")
    }
}

public enum SkeletonNumericVariant: String, Codable { case proportional, tabular }
public enum SkeletonRowDecoration: String, Codable { case platform, none }
public enum SkeletonControlStyle: String, Codable { case platform, plain }
public enum SkeletonBorderStyle: String, Codable { case solid, dashed, dotted }
public enum SkeletonEdge: String, Codable { case top, leading, bottom, trailing }
public enum SkeletonTextDecoration: String, Codable { case none, underline }
public enum SkeletonLayoutAxis: String, Codable { case horizontal, vertical }
public enum SkeletonCapability: String, Codable, Hashable { case pointer, hover, keyboard, drag, touch }
public enum SkeletonComponentVariant: String, Codable { case inline, pinned }

/// Logical edges, in the same units as width. Omitted edges use uniform padding,
/// then zero; an explicit zero overrides padding. Insets must be finite and >= 0.
public struct SkeletonInsets: Codable, Equatable {
    public var top: Double?
    public var leading: Double?
    public var bottom: Double?
    public var trailing: Double?

    public init(
        top: Double? = nil,
        leading: Double? = nil,
        bottom: Double? = nil,
        trailing: Double? = nil
    ) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case top, leading, bottom, trailing
    }

    public init(from decoder: Decoder) throws {
        try skeletonKnownKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.top = try container.skeletonValue(Double.self, forKey: .top)
        self.leading = try container.skeletonValue(Double.self, forKey: .leading)
        self.bottom = try container.skeletonValue(Double.self, forKey: .bottom)
        self.trailing = try container.skeletonValue(Double.self, forKey: .trailing)
        try validate()
    }

    public func validate() throws {
        try skeletonNumber(top, field: "top", minimum: 0)
        try skeletonNumber(leading, field: "leading", minimum: 0)
        try skeletonNumber(bottom, field: "bottom", minimum: 0)
        try skeletonNumber(trailing, field: "trailing", minimum: 0)
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(top, forKey: .top)
        try container.encodeIfPresent(leading, forKey: .leading)
        try container.encodeIfPresent(bottom, forKey: .bottom)
        try container.encodeIfPresent(trailing, forKey: .trailing)
    }

    public func resolved(padding: Double? = nil) -> SkeletonInsets {
        SkeletonInsets(top: top ?? padding ?? 0, leading: leading ?? padding ?? 0,
                       bottom: bottom ?? padding ?? 0, trailing: trailing ?? padding ?? 0)
    }
}

/// A partial visual override. Missing properties leave the existing style intact.
public struct SkeletonInteractionStyle: Codable, Equatable {
    public var background: String?
    public var foregroundColor: String?
    public var opacity: Double?

    public init(
        background: String? = nil,
        foregroundColor: String? = nil,
        opacity: Double? = nil
    ) {
        self.background = background
        self.foregroundColor = foregroundColor
        self.opacity = opacity
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case background, foregroundColor, opacity
    }

    public init(from decoder: Decoder) throws {
        try skeletonKnownKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.background = try container.skeletonValue(String.self, forKey: .background)
        self.foregroundColor = try container.skeletonValue(String.self, forKey: .foregroundColor)
        self.opacity = try container.skeletonValue(Double.self, forKey: .opacity)
        try validate()
    }

    public func validate() throws {
        try skeletonNumber(opacity, field: "opacity", minimum: 0)
        if let opacity, opacity > 1 { throw SkeletonFormatError(field: "opacity", reason: "must be <= 1") }
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(background, forKey: .background)
        try container.encodeIfPresent(foregroundColor, forKey: .foregroundColor)
        try container.encodeIfPresent(opacity, forKey: .opacity)
    }
}

/// Host drag state is transient (R4). Absence means no override. When both drag
/// states apply, dragSource properties override dragActive properties.
public struct SkeletonInteractionStyles: Codable, Equatable {
    public var hover: SkeletonInteractionStyle?
    public var focusVisible: SkeletonInteractionStyle?
    public var dragSource: SkeletonInteractionStyle?
    public var dragActive: SkeletonInteractionStyle?

    public init(
        hover: SkeletonInteractionStyle? = nil,
        focusVisible: SkeletonInteractionStyle? = nil,
        dragSource: SkeletonInteractionStyle? = nil,
        dragActive: SkeletonInteractionStyle? = nil
    ) {
        self.hover = hover
        self.focusVisible = focusVisible
        self.dragSource = dragSource
        self.dragActive = dragActive
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case hover, focusVisible, dragSource, dragActive
    }

    public init(from decoder: Decoder) throws {
        try skeletonKnownKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hover = try container.skeletonValue(SkeletonInteractionStyle.self, forKey: .hover)
        self.focusVisible = try container.skeletonValue(SkeletonInteractionStyle.self, forKey: .focusVisible)
        self.dragSource = try container.skeletonValue(SkeletonInteractionStyle.self, forKey: .dragSource)
        self.dragActive = try container.skeletonValue(SkeletonInteractionStyle.self, forKey: .dragActive)
    }

    public func dragStyle(isSource: Bool, isActive: Bool) -> SkeletonInteractionStyle? {
        // A source always implies an active drag, even if a caller omitted that flag.
        let active = (isActive || isSource) ? dragActive : nil
        guard isSource, let source = dragSource else { return active }
        return SkeletonInteractionStyle(background: source.background ?? active?.background,
            foregroundColor: source.foregroundColor ?? active?.foregroundColor,
            opacity: source.opacity ?? active?.opacity)
    }
}

/// Decorative overlay at the logical leading edge; no layout or hit-test area.
/// Offset is signed; dimensions/insets/radius are finite and nonnegative.
public struct SkeletonLeadingMarker: Codable, Equatable {
    public var width: Double
    public var insetTop: Double
    public var insetBottom: Double
    public var offset: Double
    public var cornerRadius: Double
    public var color: String

    public init(
        width: Double,
        insetTop: Double,
        insetBottom: Double,
        offset: Double,
        cornerRadius: Double,
        color: String
    ) {
        self.width = width
        self.insetTop = insetTop
        self.insetBottom = insetBottom
        self.offset = offset
        self.cornerRadius = cornerRadius
        self.color = color
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case width, insetTop, insetBottom, offset, cornerRadius, color
    }

    public init(from decoder: Decoder) throws {
        try skeletonKnownKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.width = try container.skeletonRequired(Double.self, forKey: .width)
        self.insetTop = try container.skeletonRequired(Double.self, forKey: .insetTop)
        self.insetBottom = try container.skeletonRequired(Double.self, forKey: .insetBottom)
        self.offset = try container.skeletonRequired(Double.self, forKey: .offset)
        self.cornerRadius = try container.skeletonRequired(Double.self, forKey: .cornerRadius)
        self.color = try container.skeletonRequired(String.self, forKey: .color)
        try validate()
    }

    public func validate() throws {
        try skeletonNumber(width, field: "width", minimum: 0)
        try skeletonNumber(insetTop, field: "insetTop", minimum: 0)
        try skeletonNumber(insetBottom, field: "insetBottom", minimum: 0)
        try skeletonNumber(offset, field: "offset")
        try skeletonNumber(cornerRadius, field: "cornerRadius", minimum: 0)
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(width, forKey: .width)
        try container.encode(insetTop, forKey: .insetTop)
        try container.encode(insetBottom, forKey: .insetBottom)
        try container.encode(offset, forKey: .offset)
        try container.encode(cornerRadius, forKey: .cornerRadius)
        try container.encode(color, forKey: .color)
    }
}

/// Inclusive declared thresholds; all capability requirements must hold. Unknown
/// dimensions cannot match a threshold. Array order determines the first match.
/// Overrides change layout only, preserving the mounted element and its state.
public struct SkeletonLayoutVariant: Codable {
    public var when: SkeletonCondition?
    public var minAvailableWidth: Double?
    public var maxAvailableWidth: Double?
    public var minAvailableHeight: Double?
    public var maxAvailableHeight: Double?
    public var requiresCapability: [SkeletonCapability]?
    public var axis: SkeletonLayoutAxis?
    public var columns: [SkeletonGridColumn]?
    public var spacing: Double?
    public var paddingInsets: SkeletonInsets?
    public var minHeight: Double?
    public var maxHeight: Double?
    public var flexGrow: Double?
    public var fontSize: Double?
    public var borderColor: String?
    public var foregroundColor: String?
    /// WP-F: skjuler elementet mens varianten gjelder (for eksempel treet i appbredde).
    public var hidden: Bool?
    /// WP-F: fast bredde mens varianten gjelder; overstyrer elementets `width`.
    public var width: Double?

    public init(
        when: SkeletonCondition? = nil,
        minAvailableWidth: Double? = nil,
        maxAvailableWidth: Double? = nil,
        minAvailableHeight: Double? = nil,
        maxAvailableHeight: Double? = nil,
        requiresCapability: [SkeletonCapability]? = nil,
        axis: SkeletonLayoutAxis? = nil,
        columns: [SkeletonGridColumn]? = nil,
        spacing: Double? = nil,
        paddingInsets: SkeletonInsets? = nil,
        minHeight: Double? = nil,
        maxHeight: Double? = nil,
        flexGrow: Double? = nil,
        fontSize: Double? = nil,
        borderColor: String? = nil,
        foregroundColor: String? = nil,
        hidden: Bool? = nil,
        width: Double? = nil
    ) {
        self.when = when
        self.minAvailableWidth = minAvailableWidth
        self.maxAvailableWidth = maxAvailableWidth
        self.minAvailableHeight = minAvailableHeight
        self.maxAvailableHeight = maxAvailableHeight
        self.requiresCapability = requiresCapability
        self.axis = axis
        self.columns = columns
        self.spacing = spacing
        self.paddingInsets = paddingInsets
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.flexGrow = flexGrow
        self.fontSize = fontSize
        self.borderColor = borderColor
        self.foregroundColor = foregroundColor
        self.hidden = hidden
        self.width = width
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case when, minAvailableWidth, maxAvailableWidth, minAvailableHeight, maxAvailableHeight, requiresCapability, axis, columns, spacing, paddingInsets, minHeight, maxHeight, flexGrow, fontSize, borderColor, foregroundColor, hidden, width
    }

    public init(from decoder: Decoder) throws {
        try skeletonKnownKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.when = try container.skeletonValue(SkeletonCondition.self, forKey: .when)
        self.minAvailableWidth = try container.skeletonValue(Double.self, forKey: .minAvailableWidth)
        self.maxAvailableWidth = try container.skeletonValue(Double.self, forKey: .maxAvailableWidth)
        self.minAvailableHeight = try container.skeletonValue(Double.self, forKey: .minAvailableHeight)
        self.maxAvailableHeight = try container.skeletonValue(Double.self, forKey: .maxAvailableHeight)
        self.requiresCapability = try container.skeletonValue([SkeletonCapability].self, forKey: .requiresCapability)
        self.axis = try container.skeletonValue(SkeletonLayoutAxis.self, forKey: .axis)
        self.columns = try container.skeletonValue([SkeletonGridColumn].self, forKey: .columns)
        if columns != nil {
            var encodedColumns = try container.nestedUnkeyedContainer(forKey: .columns)
            while !encodedColumns.isAtEnd {
                try skeletonKnownKeys(encodedColumns.superDecoder(), allowed: ["type", "value", "min", "max"])
            }
        }
        self.spacing = try container.skeletonValue(Double.self, forKey: .spacing)
        self.paddingInsets = try container.skeletonValue(SkeletonInsets.self, forKey: .paddingInsets)
        self.minHeight = try container.skeletonValue(Double.self, forKey: .minHeight)
        self.maxHeight = try container.skeletonValue(Double.self, forKey: .maxHeight)
        self.flexGrow = try container.skeletonValue(Double.self, forKey: .flexGrow)
        self.fontSize = try container.skeletonValue(Double.self, forKey: .fontSize)
        self.borderColor = try container.skeletonValue(String.self, forKey: .borderColor)
        self.foregroundColor = try container.skeletonValue(String.self, forKey: .foregroundColor)
        self.hidden = try container.skeletonValue(Bool.self, forKey: .hidden)
        self.width = try container.skeletonValue(Double.self, forKey: .width)
        try validate()
    }

    public func validate() throws {
        try skeletonNumber(minAvailableWidth, field: "minAvailableWidth", minimum: 0)
        try skeletonNumber(maxAvailableWidth, field: "maxAvailableWidth", minimum: 0)
        try skeletonNumber(minAvailableHeight, field: "minAvailableHeight", minimum: 0)
        try skeletonNumber(maxAvailableHeight, field: "maxAvailableHeight", minimum: 0)
        try skeletonNumber(spacing, field: "spacing", minimum: 0)
        try skeletonNumber(minHeight, field: "minHeight", minimum: 0)
        try skeletonNumber(maxHeight, field: "maxHeight", minimum: 0)
        try skeletonNumber(flexGrow, field: "flexGrow", minimum: 0)
        try skeletonNumber(fontSize, field: "fontSize", positive: true)
        try skeletonNumber(width, field: "width", minimum: 0)
        try skeletonRange(minAvailableWidth, maxAvailableWidth, field: "availableWidth")
        try skeletonRange(minAvailableHeight, maxAvailableHeight, field: "availableHeight")
        try skeletonRange(minHeight, maxHeight, field: "height")
        if let when { try Self.validateCondition(when) }
        if let columns {
            guard !columns.isEmpty else { throw SkeletonFormatError(field: "columns", reason: "must not be empty") }
            for (index, column) in columns.enumerated() {
                let field = "columns[\(index)]"
                try skeletonNumber(column.value, field: field + ".value", minimum: 0)
                try skeletonNumber(column.min, field: field + ".min", minimum: 0)
                try skeletonNumber(column.max, field: field + ".max", minimum: 0)
                try skeletonRange(column.min, column.max, field: field)
                if column.type == .fixed && column.value == nil {
                    throw SkeletonFormatError(field: field + ".value", reason: "fixed column requires value")
                }
                if column.type == .adaptive {
                    guard let minimum = column.min, minimum > 0 else {
                        throw SkeletonFormatError(field: field + ".min", reason: "adaptive column requires min > 0")
                    }
                }
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(when, forKey: .when)
        try container.encodeIfPresent(minAvailableWidth, forKey: .minAvailableWidth)
        try container.encodeIfPresent(maxAvailableWidth, forKey: .maxAvailableWidth)
        try container.encodeIfPresent(minAvailableHeight, forKey: .minAvailableHeight)
        try container.encodeIfPresent(maxAvailableHeight, forKey: .maxAvailableHeight)
        try container.encodeIfPresent(requiresCapability, forKey: .requiresCapability)
        try container.encodeIfPresent(axis, forKey: .axis)
        try container.encodeIfPresent(columns, forKey: .columns)
        try container.encodeIfPresent(spacing, forKey: .spacing)
        try container.encodeIfPresent(paddingInsets, forKey: .paddingInsets)
        try container.encodeIfPresent(minHeight, forKey: .minHeight)
        try container.encodeIfPresent(maxHeight, forKey: .maxHeight)
        try container.encodeIfPresent(flexGrow, forKey: .flexGrow)
        try container.encodeIfPresent(fontSize, forKey: .fontSize)
        try container.encodeIfPresent(borderColor, forKey: .borderColor)
        try container.encodeIfPresent(foregroundColor, forKey: .foregroundColor)
        try container.encodeIfPresent(hidden, forKey: .hidden)
        try container.encodeIfPresent(width, forKey: .width)
    }

    private static func validateCondition(_ condition: SkeletonCondition) throws {
        guard case .expression(let expression) = condition else { return }
        if expression.isMalformed {
            throw SkeletonFormatError(field: "when", reason: "malformed condition")
        }
        for child in (expression.allOf ?? []) + (expression.anyOf ?? []) { try validateCondition(child) }
        if let child = expression.not { try validateCondition(child) }
    }

    public func matches(_ layout: SkeletonLayoutContext, root: ValueType? = nil,
                        item: ValueType? = nil, context: ValueType? = nil) -> Bool {
        guard (try? validate()) != nil else { return false }
        func within(_ value: Double?, _ minimum: Double?, _ maximum: Double?) -> Bool {
            guard minimum != nil || maximum != nil else { return true }
            guard let value else { return false }
            return (minimum.map { value >= $0 } ?? true) && (maximum.map { value <= $0 } ?? true)
        }
        return within(layout.availableWidth, minAvailableWidth, maxAvailableWidth)
            && within(layout.availableHeight, minAvailableHeight, maxAvailableHeight)
            && Set(requiresCapability ?? []).isSubset(of: layout.capabilities)
            && (when?.evaluate(root: root, item: item, context: context) ?? true)
    }
}

/// V3-A: the host declares available content space once, then known containers
/// narrow it for their children (fixed panel/drawer widths or allocated Grid tracks).
/// No measurement occurs here. Undeclared axes inherit; nil means unknown, never
/// infinity. A child cannot enlarge a known parent budget. Capabilities are inherited.
public struct SkeletonLayoutContext: Equatable {
    public let availableWidth: Double?
    public let availableHeight: Double?
    public let capabilities: Set<SkeletonCapability>

    public init(availableWidth: Double? = nil, availableHeight: Double? = nil,
                capabilities: Set<SkeletonCapability> = []) throws {
        try skeletonNumber(availableWidth, field: "availableWidth", minimum: 0)
        try skeletonNumber(availableHeight, field: "availableHeight", minimum: 0)
        self.availableWidth = availableWidth
        self.availableHeight = availableHeight
        self.capabilities = capabilities
    }

    public func narrowed(availableWidth: Double? = nil, availableHeight: Double? = nil) throws -> SkeletonLayoutContext {
        try skeletonNumber(availableWidth, field: "availableWidth", minimum: 0)
        try skeletonNumber(availableHeight, field: "availableHeight", minimum: 0)
        func narrow(_ parent: Double?, _ child: Double?) -> Double? {
            guard let child else { return parent }
            return parent.map { min($0, child) } ?? child
        }
        return try SkeletonLayoutContext(availableWidth: narrow(self.availableWidth, availableWidth),
            availableHeight: narrow(self.availableHeight, availableHeight), capabilities: capabilities)
    }
}

/// Stil- og layoutmodifikatorer som hvert skjelettelement bærer.
///
/// Feltene ligger i en copy-on-write-boks på heapen. Hvert element har
/// modifikatorene sine inline, og med 70 valgfrie felt ble hvert element
/// 1,3-5,5 KB. Debugbygg av funksjoner som setter sammen store skjeletter
/// (for eksempel `PersonalCopilotConfigurationFactory.chatHubSkeletonBody`)
/// trengte da stackrammer større enn de 512 KiB en Swift-concurrency-tråd har
/// på Apple-plattformer, og testprosessene døde med `Thread stack size exceeded`
/// (WP-R4b). Boksen gjør `SkeletonModifiers` én peker bred. Verdisemantikk,
/// offentlig API og JSON-format er uendret.
public struct SkeletonModifiers: Codable {
    private final class Box {
        var fields: SkeletonModifiersFields
        init(_ fields: SkeletonModifiersFields) { self.fields = fields }
    }

    private var box: Box

    public init() {
        box = Box(SkeletonModifiersFields())
    }

    public init(from decoder: any Decoder) throws {
        box = Box(try SkeletonModifiersFields(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try box.fields.encode(to: encoder)
    }

    /// Nil means use the base layout, with no remount or action substitution.
    public func layoutVariant(in layout: SkeletonLayoutContext, root: ValueType? = nil,
                              item: ValueType? = nil, context: ValueType? = nil) -> SkeletonLayoutVariant? {
        box.fields.layoutVariant(in: layout, root: root, item: item, context: context)
    }

    private mutating func uniqueBox() -> Box {
        if !isKnownUniquelyReferenced(&box) { box = Box(box.fields) }
        return box
    }

    public var localization: [String: SkeletonLocalizedText]? {
        get { box.fields.localization }
        set { uniqueBox().fields.localization = newValue }
    }

    public var padding: Double? {
        get { box.fields.padding }
        set { uniqueBox().fields.padding = newValue }
    }

    public var maxWidthInfinity: Bool? {
        get { box.fields.maxWidthInfinity }
        set { uniqueBox().fields.maxWidthInfinity = newValue }
    }

    public var maxHeightInfinity: Bool? {
        get { box.fields.maxHeightInfinity }
        set { uniqueBox().fields.maxHeightInfinity = newValue }
    }

    public var width: Double? {
        get { box.fields.width }
        set { uniqueBox().fields.width = newValue }
    }

    public var height: Double? {
        get { box.fields.height }
        set { uniqueBox().fields.height = newValue }
    }

    public var hAlignment: String? {
        get { box.fields.hAlignment }
        set { uniqueBox().fields.hAlignment = newValue }
    }

    public var vAlignment: String? {
        get { box.fields.vAlignment }
        set { uniqueBox().fields.vAlignment = newValue }
    }

    public var hAlignmentKeypath: String? {
        get { box.fields.hAlignmentKeypath }
        set { uniqueBox().fields.hAlignmentKeypath = newValue }
    }

    public var background: String? {
        get { box.fields.background }
        set { uniqueBox().fields.background = newValue }
    }

    public var backgroundKeypath: String? {
        get { box.fields.backgroundKeypath }
        set { uniqueBox().fields.backgroundKeypath = newValue }
    }

    public var cornerRadius: Double? {
        get { box.fields.cornerRadius }
        set { uniqueBox().fields.cornerRadius = newValue }
    }

    public var shadowRadius: Double? {
        get { box.fields.shadowRadius }
        set { uniqueBox().fields.shadowRadius = newValue }
    }

    public var shadowX: Double? {
        get { box.fields.shadowX }
        set { uniqueBox().fields.shadowX = newValue }
    }

    public var shadowY: Double? {
        get { box.fields.shadowY }
        set { uniqueBox().fields.shadowY = newValue }
    }

    public var shadowColor: String? {
        get { box.fields.shadowColor }
        set { uniqueBox().fields.shadowColor = newValue }
    }

    public var borderWidth: Double? {
        get { box.fields.borderWidth }
        set { uniqueBox().fields.borderWidth = newValue }
    }

    public var borderColor: String? {
        get { box.fields.borderColor }
        set { uniqueBox().fields.borderColor = newValue }
    }

    public var opacity: Double? {
        get { box.fields.opacity }
        set { uniqueBox().fields.opacity = newValue }
    }

    public var hidden: Bool? {
        get { box.fields.hidden }
        set { uniqueBox().fields.hidden = newValue }
    }

    public var wrap: Bool? {
        get { box.fields.wrap }
        set { uniqueBox().fields.wrap = newValue }
    }

    public var visibility: SkeletonVisibilityRule? {
        get { box.fields.visibility }
        set { uniqueBox().fields.visibility = newValue }
    }

    public var foregroundColor: String? {
        get { box.fields.foregroundColor }
        set { uniqueBox().fields.foregroundColor = newValue }
    }

    public var foregroundColorKeypath: String? {
        get { box.fields.foregroundColorKeypath }
        set { uniqueBox().fields.foregroundColorKeypath = newValue }
    }

    public var fontStyle: String? {
        get { box.fields.fontStyle }
        set { uniqueBox().fields.fontStyle = newValue }
    }

    public var fontSize: Double? {
        get { box.fields.fontSize }
        set { uniqueBox().fields.fontSize = newValue }
    }

    public var fontWeight: String? {
        get { box.fields.fontWeight }
        set { uniqueBox().fields.fontWeight = newValue }
    }

    public var lineLimit: Int? {
        get { box.fields.lineLimit }
        set { uniqueBox().fields.lineLimit = newValue }
    }

    public var multilineTextAlignment: String? {
        get { box.fields.multilineTextAlignment }
        set { uniqueBox().fields.multilineTextAlignment = newValue }
    }

    public var minimumScaleFactor: Double? {
        get { box.fields.minimumScaleFactor }
        set { uniqueBox().fields.minimumScaleFactor = newValue }
    }

    public var styleRole: String? {
        get { box.fields.styleRole }
        set { uniqueBox().fields.styleRole = newValue }
    }

    public var styleClasses: [String]? {
        get { box.fields.styleClasses }
        set { uniqueBox().fields.styleClasses = newValue }
    }

    public var motionHint: SkeletonMotionHint? {
        get { box.fields.motionHint }
        set { uniqueBox().fields.motionHint = newValue }
    }

    public var motionSourceRole: String? {
        get { box.fields.motionSourceRole }
        set { uniqueBox().fields.motionSourceRole = newValue }
    }

    public var presentation: SkeletonPresentation? {
        get { box.fields.presentation }
        set { uniqueBox().fields.presentation = newValue }
    }

    public var draggableRole: String? {
        get { box.fields.draggableRole }
        set { uniqueBox().fields.draggableRole = newValue }
    }

    public var dragPayloadKeypath: String? {
        get { box.fields.dragPayloadKeypath }
        set { uniqueBox().fields.dragPayloadKeypath = newValue }
    }

    public var dragPreviewRole: String? {
        get { box.fields.dragPreviewRole }
        set { uniqueBox().fields.dragPreviewRole = newValue }
    }

    public var accessibilityDragLabel: String? {
        get { box.fields.accessibilityDragLabel }
        set { uniqueBox().fields.accessibilityDragLabel = newValue }
    }

    public var dropTargetRole: String? {
        get { box.fields.dropTargetRole }
        set { uniqueBox().fields.dropTargetRole = newValue }
    }

    public var acceptedDragRoles: [String]? {
        get { box.fields.acceptedDragRoles }
        set { uniqueBox().fields.acceptedDragRoles = newValue }
    }

    public var dropTargetPayloadKeypath: String? {
        get { box.fields.dropTargetPayloadKeypath }
        set { uniqueBox().fields.dropTargetPayloadKeypath = newValue }
    }

    public var dropActionKeypath: String? {
        get { box.fields.dropActionKeypath }
        set { uniqueBox().fields.dropActionKeypath = newValue }
    }

    public var dropIntents: [String]? {
        get { box.fields.dropIntents }
        set { uniqueBox().fields.dropIntents = newValue }
    }

    public var dropValidationStateKeypath: String? {
        get { box.fields.dropValidationStateKeypath }
        set { uniqueBox().fields.dropValidationStateKeypath = newValue }
    }

    public var dropDeniedReasonKeypath: String? {
        get { box.fields.dropDeniedReasonKeypath }
        set { uniqueBox().fields.dropDeniedReasonKeypath = newValue }
    }

    public var accessibilityDropLabel: String? {
        get { box.fields.accessibilityDropLabel }
        set { uniqueBox().fields.accessibilityDropLabel = newValue }
    }

    public var paddingInsets: SkeletonInsets? {
        get { box.fields.paddingInsets }
        set { uniqueBox().fields.paddingInsets = newValue }
    }

    public var fontFamilies: [String]? {
        get { box.fields.fontFamilies }
        set { uniqueBox().fields.fontFamilies = newValue }
    }

    public var lineHeightMultiple: Double? {
        get { box.fields.lineHeightMultiple }
        set { uniqueBox().fields.lineHeightMultiple = newValue }
    }

    public var letterSpacing: Double? {
        get { box.fields.letterSpacing }
        set { uniqueBox().fields.letterSpacing = newValue }
    }

    public var numericVariant: SkeletonNumericVariant? {
        get { box.fields.numericVariant }
        set { uniqueBox().fields.numericVariant = newValue }
    }

    public var itemSpacing: Double? {
        get { box.fields.itemSpacing }
        set { uniqueBox().fields.itemSpacing = newValue }
    }

    public var rowInsets: SkeletonInsets? {
        get { box.fields.rowInsets }
        set { uniqueBox().fields.rowInsets = newValue }
    }

    public var rowDecoration: SkeletonRowDecoration? {
        get { box.fields.rowDecoration }
        set { uniqueBox().fields.rowDecoration = newValue }
    }

    public var minHeight: Double? {
        get { box.fields.minHeight }
        set { uniqueBox().fields.minHeight = newValue }
    }

    public var maxHeight: Double? {
        get { box.fields.maxHeight }
        set { uniqueBox().fields.maxHeight = newValue }
    }

    public var minWidth: Double? {
        get { box.fields.minWidth }
        set { uniqueBox().fields.minWidth = newValue }
    }

    public var flexGrow: Double? {
        get { box.fields.flexGrow }
        set { uniqueBox().fields.flexGrow = newValue }
    }

    public var controlStyle: SkeletonControlStyle? {
        get { box.fields.controlStyle }
        set { uniqueBox().fields.controlStyle = newValue }
    }

    public var accessibilityLabel: String? {
        get { box.fields.accessibilityLabel }
        set { uniqueBox().fields.accessibilityLabel = newValue }
    }

    public var borderStyle: SkeletonBorderStyle? {
        get { box.fields.borderStyle }
        set { uniqueBox().fields.borderStyle = newValue }
    }

    public var shadowSpread: Double? {
        get { box.fields.shadowSpread }
        set { uniqueBox().fields.shadowSpread = newValue }
    }

    public var borderEdges: [SkeletonEdge]? {
        get { box.fields.borderEdges }
        set { uniqueBox().fields.borderEdges = newValue }
    }

    public var contentClip: Bool? {
        get { box.fields.contentClip }
        set { uniqueBox().fields.contentClip = newValue }
    }

    public var layoutVariants: [SkeletonLayoutVariant]? {
        get { box.fields.layoutVariants }
        set { uniqueBox().fields.layoutVariants = newValue }
    }

    public var interactionStyles: SkeletonInteractionStyles? {
        get { box.fields.interactionStyles }
        set { uniqueBox().fields.interactionStyles = newValue }
    }

    public var textDecoration: SkeletonTextDecoration? {
        get { box.fields.textDecoration }
        set { uniqueBox().fields.textDecoration = newValue }
    }

    public var textRotationDegrees: Double? {
        get { box.fields.textRotationDegrees }
        set { uniqueBox().fields.textRotationDegrees = newValue }
    }

    public var leadingMarker: SkeletonLeadingMarker? {
        get { box.fields.leadingMarker }
        set { uniqueBox().fields.leadingMarker = newValue }
    }
}

/// Feltene til `SkeletonModifiers`, uendret fra da de lå inline. Brukes bare
/// bak copy-on-write-boksen i `SkeletonModifiers`; se forklaringen der.
struct SkeletonModifiersFields: Codable {
    public var localization: [String: SkeletonLocalizedText]?
    public var padding: Double?
    public var maxWidthInfinity: Bool?
    public var maxHeightInfinity: Bool?
    public var width: Double?
    public var height: Double?
    public var hAlignment: String? // leading, center, trailing
    public var vAlignment: String? // top, center, bottom
    // When set on a row inside a List/Grid's flowElementSkeleton, resolves
    // hAlignment from this keypath on the row's own item data instead of the
    // static hAlignment above - e.g. a chat message list where each row's
    // alignment depends on whether that message's authorUUID is the viewer's
    // own. Ignored outside a per-item row context; falls back to the static
    // hAlignment (if any) when the keypath is absent or doesn't resolve.
    public var hAlignmentKeypath: String?
    public var background: String? // hex color like #RRGGBBAA or #RRGGBB
    // Same per-item resolution as hAlignmentKeypath, for background.
    public var backgroundKeypath: String?
    public var cornerRadius: Double?
    public var shadowRadius: Double?
    public var shadowX: Double?
    public var shadowY: Double?
    public var shadowColor: String?
    public var borderWidth: Double?
    public var borderColor: String?
    public var opacity: Double?
    public var hidden: Bool?
    // When true on a container element (HStack, List), children wrap onto
    // additional rows instead of overflowing/clipping on one axis, each
    // sized to its own content (flexbox flex-wrap, not a fixed-track grid).
    // Meaningless on non-container elements; renderers ignore it there.
    public var wrap: Bool?
    public var visibility: SkeletonVisibilityRule?
    
    public var foregroundColor: String?
    // Same per-item resolution as hAlignmentKeypath, for foregroundColor.
    public var foregroundColorKeypath: String?
    public var fontStyle: String?
    public var fontSize: Double?
    public var fontWeight: String?
    public var lineLimit: Int?
    public var multilineTextAlignment: String?
    public var minimumScaleFactor: Double?
    public var styleRole: String?
    public var styleClasses: [String]?
    public var motionHint: SkeletonMotionHint?
    public var motionSourceRole: String?
    public var presentation: SkeletonPresentation?
    public var draggableRole: String?
    public var dragPayloadKeypath: String?
    public var dragPreviewRole: String?
    public var accessibilityDragLabel: String?
    public var dropTargetRole: String?
    public var acceptedDragRoles: [String]?
    public var dropTargetPayloadKeypath: String?
    public var dropActionKeypath: String?
    public var dropIntents: [String]?
    public var dropValidationStateKeypath: String?
    public var dropDeniedReasonKeypath: String?
    public var accessibilityDropLabel: String?

    // M1-M10 defaults: nil preserves the existing renderer style/layout. Insets
    // fall back per edge to uniform padding; fontFamilies is ordered, ending in
    // the host's existing font fallback. lineHeightMultiple (> 0) is the line box
    // height / fontSize, not extra inter-line spacing. Signed tracking, spread,
    // and rotation are allowed; sizes, itemSpacing and flexGrow must be >= 0.
    // nil rowDecoration/controlStyle means platform; nil borderStyle means solid;
    // nil borderEdges means all, [] means none. contentClip defaults to false and
    // clips to the rounded content boundary. nil textDecoration means no override.
    public var paddingInsets: SkeletonInsets?
    public var fontFamilies: [String]?
    public var lineHeightMultiple: Double?
    public var letterSpacing: Double?
    public var numericVariant: SkeletonNumericVariant?
    public var itemSpacing: Double?
    public var rowInsets: SkeletonInsets?
    public var rowDecoration: SkeletonRowDecoration?
    public var minHeight: Double?
    public var maxHeight: Double?
    public var minWidth: Double?
    public var flexGrow: Double?
    public var controlStyle: SkeletonControlStyle?
    public var accessibilityLabel: String?
    public var borderStyle: SkeletonBorderStyle?
    public var shadowSpread: Double?
    public var borderEdges: [SkeletonEdge]?
    public var contentClip: Bool?
    public var layoutVariants: [SkeletonLayoutVariant]?
    public var interactionStyles: SkeletonInteractionStyles?
    public var textDecoration: SkeletonTextDecoration?
    public var textRotationDegrees: Double?
    public var leadingMarker: SkeletonLeadingMarker?

    public init() {}

    /// Nil means use the base layout, with no remount or action substitution.
    public func layoutVariant(in layout: SkeletonLayoutContext, root: ValueType? = nil,
                              item: ValueType? = nil, context: ValueType? = nil) -> SkeletonLayoutVariant? {
        layoutVariants?.first { $0.matches(layout, root: root, item: item, context: context) }
    }


    enum CodingKeys: String, CodingKey {
        case paddingInsets
        case fontFamilies
        case lineHeightMultiple
        case letterSpacing
        case numericVariant
        case itemSpacing
        case rowInsets
        case rowDecoration
        case minHeight
        case maxHeight
        case minWidth
        case flexGrow
        case controlStyle
        case accessibilityLabel
        case borderStyle
        case shadowSpread
        case borderEdges
        case contentClip
        case layoutVariants
        case interactionStyles
        case textDecoration
        case textRotationDegrees
        case leadingMarker
        case localization
        case padding
        case maxWidthInfinity
        case maxHeightInfinity
        case width
        case height
        case hAlignment
        case vAlignment
        case hAlignmentKeypath
        case background
        case backgroundKeypath
        case cornerRadius
        case shadowRadius
        case shadowX
        case shadowY
        case shadowColor
        case borderWidth
        case borderColor
        case opacity
        case hidden
        case wrap
        case visibility
        case foregroundColor
        case foregroundColorKeypath
        case fontStyle
        case fontSize
        case fontWeight
        case lineLimit
        case multilineTextAlignment
        case minimumScaleFactor
        case styleRole
        case styleClasses
        case motionHint
        case motionSourceRole
        case presentation
        case draggableRole
        case dragPayloadKeypath
        case dragPreviewRole
        case accessibilityDragLabel
        case dropTargetRole
        case acceptedDragRoles
        case dropTargetPayloadKeypath
        case dropActionKeypath
        case dropIntents
        case dropValidationStateKeypath
        case dropDeniedReasonKeypath
        case accessibilityDropLabel
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.paddingInsets = try container.skeletonValue(SkeletonInsets.self, forKey: .paddingInsets)
        self.fontFamilies = try container.skeletonValue([String].self, forKey: .fontFamilies)
        self.lineHeightMultiple = try container.skeletonValue(Double.self, forKey: .lineHeightMultiple)
        self.letterSpacing = try container.skeletonValue(Double.self, forKey: .letterSpacing)
        self.numericVariant = try container.skeletonValue(SkeletonNumericVariant.self, forKey: .numericVariant)
        self.itemSpacing = try container.skeletonValue(Double.self, forKey: .itemSpacing)
        self.rowInsets = try container.skeletonValue(SkeletonInsets.self, forKey: .rowInsets)
        self.rowDecoration = try container.skeletonValue(SkeletonRowDecoration.self, forKey: .rowDecoration)
        self.minHeight = try container.skeletonValue(Double.self, forKey: .minHeight)
        self.maxHeight = try container.skeletonValue(Double.self, forKey: .maxHeight)
        self.minWidth = try container.skeletonValue(Double.self, forKey: .minWidth)
        self.flexGrow = try container.skeletonValue(Double.self, forKey: .flexGrow)
        self.controlStyle = try container.skeletonValue(SkeletonControlStyle.self, forKey: .controlStyle)
        self.accessibilityLabel = try container.skeletonValue(String.self, forKey: .accessibilityLabel)
        self.borderStyle = try container.skeletonValue(SkeletonBorderStyle.self, forKey: .borderStyle)
        self.shadowSpread = try container.skeletonValue(Double.self, forKey: .shadowSpread)
        self.borderEdges = try container.skeletonValue([SkeletonEdge].self, forKey: .borderEdges)
        self.contentClip = try container.skeletonValue(Bool.self, forKey: .contentClip)
        self.layoutVariants = try container.skeletonValue([SkeletonLayoutVariant].self, forKey: .layoutVariants)
        self.interactionStyles = try container.skeletonValue(SkeletonInteractionStyles.self, forKey: .interactionStyles)
        self.textDecoration = try container.skeletonValue(SkeletonTextDecoration.self, forKey: .textDecoration)
        self.textRotationDegrees = try container.skeletonValue(Double.self, forKey: .textRotationDegrees)
        self.leadingMarker = try container.skeletonValue(SkeletonLeadingMarker.self, forKey: .leadingMarker)
        try skeletonNumber(lineHeightMultiple, field: "lineHeightMultiple", positive: true)
        try skeletonNumber(letterSpacing, field: "letterSpacing")
        try skeletonNumber(itemSpacing, field: "itemSpacing", minimum: 0)
        try skeletonNumber(minHeight, field: "minHeight", minimum: 0)
        try skeletonNumber(maxHeight, field: "maxHeight", minimum: 0)
        try skeletonNumber(minWidth, field: "minWidth", minimum: 0)
        try skeletonNumber(flexGrow, field: "flexGrow", minimum: 0)
        try skeletonNumber(shadowSpread, field: "shadowSpread")
        try skeletonNumber(textRotationDegrees, field: "textRotationDegrees")
        try skeletonRange(minHeight, maxHeight, field: "height")
        if let fontFamilies {
            for family in fontFamilies { try skeletonNonempty(family, field: "fontFamilies") }
        }

        self.localization = try container.decodeIfPresent([String: SkeletonLocalizedText].self, forKey: .localization)
        self.padding = Self.decodeLossy(Double.self, from: container, forKey: .padding)
        self.maxWidthInfinity = Self.decodeLossy(Bool.self, from: container, forKey: .maxWidthInfinity)
        self.maxHeightInfinity = Self.decodeLossy(Bool.self, from: container, forKey: .maxHeightInfinity)
        self.width = Self.decodeLossy(Double.self, from: container, forKey: .width)
        self.height = Self.decodeLossy(Double.self, from: container, forKey: .height)
        self.hAlignment = Self.decodeLossy(String.self, from: container, forKey: .hAlignment)
        self.vAlignment = Self.decodeLossy(String.self, from: container, forKey: .vAlignment)
        self.hAlignmentKeypath = Self.decodeLossy(String.self, from: container, forKey: .hAlignmentKeypath)
        self.background = Self.decodeLossy(String.self, from: container, forKey: .background)
        self.backgroundKeypath = Self.decodeLossy(String.self, from: container, forKey: .backgroundKeypath)
        self.cornerRadius = Self.decodeLossy(Double.self, from: container, forKey: .cornerRadius)
        self.shadowRadius = Self.decodeLossy(Double.self, from: container, forKey: .shadowRadius)
        self.shadowX = Self.decodeLossy(Double.self, from: container, forKey: .shadowX)
        self.shadowY = Self.decodeLossy(Double.self, from: container, forKey: .shadowY)
        self.shadowColor = Self.decodeLossy(String.self, from: container, forKey: .shadowColor)
        self.borderWidth = Self.decodeLossy(Double.self, from: container, forKey: .borderWidth)
        self.borderColor = Self.decodeLossy(String.self, from: container, forKey: .borderColor)
        self.opacity = Self.decodeLossy(Double.self, from: container, forKey: .opacity)
        self.hidden = Self.decodeLossy(Bool.self, from: container, forKey: .hidden)
        self.wrap = Self.decodeLossy(Bool.self, from: container, forKey: .wrap)
        self.visibility = Self.decodeLossy(SkeletonVisibilityRule.self, from: container, forKey: .visibility)
        self.foregroundColor = Self.decodeLossy(String.self, from: container, forKey: .foregroundColor)
        self.foregroundColorKeypath = Self.decodeLossy(String.self, from: container, forKey: .foregroundColorKeypath)
        self.fontStyle = Self.decodeLossy(String.self, from: container, forKey: .fontStyle)
        self.fontSize = Self.decodeLossy(Double.self, from: container, forKey: .fontSize)
        self.fontWeight = Self.decodeLossy(String.self, from: container, forKey: .fontWeight)
        self.lineLimit = Self.decodeLossy(Int.self, from: container, forKey: .lineLimit)
        self.multilineTextAlignment = Self.decodeLossy(String.self, from: container, forKey: .multilineTextAlignment)
        self.minimumScaleFactor = Self.decodeLossy(Double.self, from: container, forKey: .minimumScaleFactor)
        self.styleRole = Self.decodeLossy(String.self, from: container, forKey: .styleRole)
        self.styleClasses = Self.decodeLossy([String].self, from: container, forKey: .styleClasses)
        self.motionHint = Self.decodeLossy(SkeletonMotionHint.self, from: container, forKey: .motionHint)
        self.motionSourceRole = Self.decodeLossy(String.self, from: container, forKey: .motionSourceRole)
        self.presentation = Self.decodeLossy(SkeletonPresentation.self, from: container, forKey: .presentation)
        self.draggableRole = Self.decodeLossy(String.self, from: container, forKey: .draggableRole)
        self.dragPayloadKeypath = Self.decodeLossy(String.self, from: container, forKey: .dragPayloadKeypath)
        self.dragPreviewRole = Self.decodeLossy(String.self, from: container, forKey: .dragPreviewRole)
        self.accessibilityDragLabel = Self.decodeLossy(String.self, from: container, forKey: .accessibilityDragLabel)
        self.dropTargetRole = Self.decodeLossy(String.self, from: container, forKey: .dropTargetRole)
        self.acceptedDragRoles = Self.decodeLossy([String].self, from: container, forKey: .acceptedDragRoles)
        self.dropTargetPayloadKeypath = Self.decodeLossy(String.self, from: container, forKey: .dropTargetPayloadKeypath)
        self.dropActionKeypath = Self.decodeLossy(String.self, from: container, forKey: .dropActionKeypath)
        self.dropIntents = Self.decodeLossy([String].self, from: container, forKey: .dropIntents)
        self.dropValidationStateKeypath = Self.decodeLossy(String.self, from: container, forKey: .dropValidationStateKeypath)
        self.dropDeniedReasonKeypath = Self.decodeLossy(String.self, from: container, forKey: .dropDeniedReasonKeypath)
        self.accessibilityDropLabel = Self.decodeLossy(String.self, from: container, forKey: .accessibilityDropLabel)
    }

    private static func decodeLossy<T: Decodable>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> T? {
        guard container.contains(key) else {
            return nil
        }
        do {
            return try container.decodeIfPresent(type, forKey: key)
        } catch {
            CellBase.diagnosticLog("Ignoring invalid SkeletonModifiers.\(key.stringValue): \(error)", domain: .skeleton)
            return nil
        }
    }
}

public struct SkeletonImage : Codable, Identifiable {
    public var id = UUID()
    
    public var url: URL?
    public var name: String?
    public var type: String? // png, jpeg, gif
    public var resizable = false
    public var scaledToFit = false
    public var padding: Double?
    public var modifiers: SkeletonModifiers?
    
    public init(name: String) {
        self.name = name
    }
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let urlString = try container.decodeIfPresent(String.self, forKey: .url) {
            self.url = URL(string: urlString)
        }
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        
        if container.contains(.resizable) {
            resizable = try container.decode(Bool.self, forKey: .resizable)
        }
        
        if container.contains(.scaledToFit) {
            scaledToFit = try container.decode(Bool.self, forKey: .scaledToFit)
        }
        
        if container.contains(.padding) {
            self.padding = try container.decode(Double.self, forKey: .padding)
        }
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }
    
    public enum CodingKeys: CodingKey {
        //        case id
        case url
        case name
        case type
        case resizable
        case scaledToFit
        case padding
        case modifiers
        case Image
    }
    
    enum ElementKey: CodingKey { case Image }

    
    public func encode(to encoder: any Encoder) throws {
//        print("Encode SkeletonImage")
        var container = encoder.container(keyedBy: ElementKey.self)
        
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self,
                                                              forKey: .Image)
        //        try container.encode(self.id, forKey: .id)
        try elementContainer.encodeIfPresent(self.url, forKey: .url)
        try elementContainer.encodeIfPresent(self.name, forKey: .name)
        try elementContainer.encodeIfPresent(self.type, forKey: .type)
        if self.resizable {
            try elementContainer.encode(self.resizable, forKey: .resizable)
        }
        if self.scaledToFit {
            try elementContainer.encode(self.scaledToFit, forKey: .scaledToFit)
        }
        try elementContainer.encodeIfPresent(self.padding, forKey: .padding)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

public struct SkeletonSpacer : Codable, Identifiable {
    public var id = UUID()
    public var width: Double?
    public var modifiers: SkeletonModifiers?
    
    public enum CodingKeys: CodingKey {
        //        case id
        case width
        case modifiers
    }
    enum ElementKey: CodingKey { case Spacer }
    
    public init() {
        
    }
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.width = try container.decodeIfPresent(Double.self, forKey: .width)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }
    
    public func encode(to encoder: any Encoder) throws {
//        print("Encode SkeletonSpacer")
        var container = encoder.container(keyedBy: ElementKey.self)
        
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self,
                                                         forKey: .Spacer)
        if width != nil {
            
            try elementContainer.encode(self.width, forKey: .width)
            
        }
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
    
}


public struct SkeletonText: Codable, Identifiable {
    public var id = UUID()
    public var text: String?
    public var url: URL?
    public var keypath: String?
    public var modifiers: SkeletonModifiers?
      
    public enum CodingKeys: CodingKey {
        //        case id
        case url
        case text
        case resizable
        case scaledToFit
        case keypath
        case modifiers
    }
    enum ElementKey: CodingKey { case Text }
    
    public init(text: String) {
        self.text = text
    }
    
    public init(url: URL) {
        self.url = url
    }
    
    public init(keypath: String) {
        self.keypath = keypath
    }
    
    private func stringValue(from value: ValueType) -> String {
        switch value {
        case .string(let string):
            return skeletonUserFacingString(string)
        case .integer(let integer):
            return String(integer)
        case .number(let number):
            return String(number)
        case .float(let float):
            return String(float)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .null:
            return "null"
        default:
            return (try? value.jsonString()) ?? "Unsupported value"
        }
    }

    private func asyncContentFailureMessage(for error: Error) -> String {
        let detail = String(describing: error)
        let normalized = detail.lowercased()

        if normalized.contains("cellauthorizationdecision") ||
            normalized.contains("deniednogrant") ||
            normalized.contains("no verified owner proof") ||
            normalized.contains("denied(") {
            return skeletonUnavailableUserMessage
        }

        if normalized.contains("bad response from the server") ||
            normalized.contains("502") ||
            normalized.contains("notconnected") ||
            normalized.contains("transportunavailable") {
            return "Tjenesten er midlertidig utilgjengelig. Prøv igjen om litt."
        }

        if normalized.contains("timeout") {
            return "Det tok for lang tid å hente innhold. Prøv igjen."
        }

        if normalized.contains("notfound") {
            return skeletonUnavailableUserMessage
        }

        return skeletonUnavailableUserMessage
    }

    public func asyncContent(userInfoValue: ValueType? = nil, requester explicitRequester: Identity? = nil) async -> String {
        
        if userInfoValue != nil && keypath != nil {
            switch userInfoValue {
            case .string(let string):
                return string
            case .float(let float):
                return String(float)
            case .integer(let integer):
                return String(integer)
            case .number(let integer):
                return String(integer)
            case .object(let object):
                if let keypath {
                    // Scalars must render as themselves. jsonString() wraps a
                    // string in quotes, so every bound value used to arrive in
                    // the UI as "Klar" instead of Klar. stringValue(from:)
                    // already encodes composites and passes scalars through.
                    if let returnObjectValue = try? object.get(keypath: keypath) {
                        return stringValue(from: returnObjectValue)
                    } else {
                        return skeletonUnavailableUserMessage
                    }
                    
                }
            default:
                return skeletonUnavailableUserMessage
            }
            
            
        } else if text != nil {
            return text ?? "err"
        } else if url != nil || keypath != nil {
            if let resolver = CellBase.defaultCellResolver,
               let vault = CellBase.defaultIdentityVault {
                
                do {
                    let fetchURL: URL?
                    if let url {
                        fetchURL = url
                    } else if let keypath, keypath.hasPrefix("cell://") {
                        fetchURL = URL(string: keypath)
                    } else {
                        fetchURL = URL(string: "cell:///Porthole")
                    }

                    let identity: Identity?
                    if let explicitRequester {
                        identity = explicitRequester
                    } else {
                        identity = await vault.identity(for: "private", makeNewIfNotFound: true)
                    }

                    if let fetchURL,
                       let identity {
                        let pathComponents = fetchURL.pathComponents
                        guard pathComponents.count > 1 else {
                            return skeletonUnavailableUserMessage
                        }

                        let cellName = pathComponents[1]
                        let endpoint: String
                        if let host = fetchURL.host, host.isEmpty == false {
                            endpoint = "cell://\(host)/\(cellName)"
                        } else {
                            endpoint = "cell:///\(cellName)"
                        }
                        CellBase.diagnosticLog("SkeletonText loading cellName=\(cellName) components=\(pathComponents)", domain: .skeleton)
                        let porthole = try await resolver.cellAtEndpoint(endpoint: endpoint, requester: identity)
                        if let meddlePorthole = porthole as? Meddle {
                            let resolvedKeypath: String?
                            if url != nil {
                                resolvedKeypath = pathComponents.count > 2 ? fetchURL.lastPathComponent : nil
                            } else if let keypath, keypath.hasPrefix("cell://") {
                                resolvedKeypath = pathComponents.count > 2 ? fetchURL.lastPathComponent : nil
                            } else {
                                resolvedKeypath = keypath
                            }

                            if let resolvedKeypath, resolvedKeypath.isEmpty == false {
                                CellBase.diagnosticLog("SkeletonText loading keypath=\(resolvedKeypath)", domain: .skeleton)
                                let fetchedValue = try await meddlePorthole.get(keypath: resolvedKeypath, requester: identity)
                                CellBase.diagnosticLog("SkeletonText fetched content for keypath=\(resolvedKeypath)", domain: .skeleton)
                                return stringValue(from: fetchedValue)
                            }
                        }
                    }
                } catch {
                    CellBase.diagnosticLog("SkeletonText asyncContent failed with error: \(error)", domain: .skeleton)
                    return asyncContentFailureMessage(for: error)
                }
            } else {
                CellBase.diagnosticLog("SkeletonText asyncContent missing resolver or vault", domain: .skeleton)
            }
        }
        return skeletonUnavailableUserMessage
    }
    
    
    public init(from decoder: any Decoder) throws {
//        print("Decode SkeletonText")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        if let urlString = try container.decodeIfPresent(String.self, forKey: .url) {
            self.url = URL(string: urlString)
        }
        self.keypath = try container.decodeIfPresent(String.self, forKey: .keypath)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        //        try container.encode(self.id, forKey: .id)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self,
                                                         forKey: .Text)
        
        try elementContainer.encodeIfPresent(self.url, forKey: .url)
        try elementContainer.encodeIfPresent(self.text, forKey: .text)
        try elementContainer.encodeIfPresent(self.keypath, forKey: .keypath)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
    
}

public struct SkeletonAutocomplete: Codable, Equatable {
    public var queryActionKeypath: String?
    public var suggestionsKeypath: String?
    public var optionLabelKeypath: String?
    public var optionValueKeypath: String?
    public var optionDetailKeypaths: [String]?
    public var selectionActionKeypath: String?
    public var debounceMilliseconds: Int
    public var minCharacters: Int
    public var allowsCustomValue: Bool

    enum CodingKeys: CodingKey {
        case queryActionKeypath
        case suggestionsKeypath
        case optionLabelKeypath
        case optionValueKeypath
        case optionDetailKeypaths
        case selectionActionKeypath
        case debounceMilliseconds
        case minCharacters
        case allowsCustomValue
    }

    public init(
        queryActionKeypath: String? = nil,
        suggestionsKeypath: String? = nil,
        optionLabelKeypath: String? = nil,
        optionValueKeypath: String? = nil,
        optionDetailKeypaths: [String]? = nil,
        selectionActionKeypath: String? = nil,
        debounceMilliseconds: Int = 250,
        minCharacters: Int = 0,
        allowsCustomValue: Bool = true
    ) {
        self.queryActionKeypath = queryActionKeypath
        self.suggestionsKeypath = suggestionsKeypath
        self.optionLabelKeypath = optionLabelKeypath
        self.optionValueKeypath = optionValueKeypath
        self.optionDetailKeypaths = optionDetailKeypaths
        self.selectionActionKeypath = selectionActionKeypath
        self.debounceMilliseconds = debounceMilliseconds
        self.minCharacters = minCharacters
        self.allowsCustomValue = allowsCustomValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.queryActionKeypath = try container.decodeIfPresent(String.self, forKey: .queryActionKeypath)
        self.suggestionsKeypath = try container.decodeIfPresent(String.self, forKey: .suggestionsKeypath)
        self.optionLabelKeypath = try container.decodeIfPresent(String.self, forKey: .optionLabelKeypath)
        self.optionValueKeypath = try container.decodeIfPresent(String.self, forKey: .optionValueKeypath)
        self.optionDetailKeypaths = try container.decodeIfPresent([String].self, forKey: .optionDetailKeypaths)
        self.selectionActionKeypath = try container.decodeIfPresent(String.self, forKey: .selectionActionKeypath)
        self.debounceMilliseconds = try container.decodeIfPresent(Int.self, forKey: .debounceMilliseconds) ?? 250
        self.minCharacters = try container.decodeIfPresent(Int.self, forKey: .minCharacters) ?? 0
        self.allowsCustomValue = try container.decodeIfPresent(Bool.self, forKey: .allowsCustomValue) ?? true
    }
}

public struct SkeletonTextField: Codable, Identifiable {
    public var id = UUID()
    public var text: String?
    public var sourceKeypath: String?
    public var targetKeypath: String?
    public var placeholder: String?
    public var autocomplete: SkeletonAutocomplete?
    public var modifiers: SkeletonModifiers?

    public enum CodingKeys: CodingKey {
        case text
        case sourceKeypath
        case targetKeypath
        case placeholder
        case autocomplete
        case modifiers
    }
    enum ElementKey: CodingKey { case TextField }

    public init(
        text: String? = nil,
        sourceKeypath: String? = nil,
        targetKeypath: String? = nil,
        placeholder: String? = nil,
        autocomplete: SkeletonAutocomplete? = nil,
        modifiers: SkeletonModifiers? = nil
    ) {
        self.text = text
        self.sourceKeypath = sourceKeypath
        self.targetKeypath = targetKeypath
        self.placeholder = placeholder
        self.autocomplete = autocomplete
        self.modifiers = modifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.sourceKeypath = try container.decodeIfPresent(String.self, forKey: .sourceKeypath)
        self.targetKeypath = try container.decodeIfPresent(String.self, forKey: .targetKeypath)
        self.placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        self.autocomplete = try container.decodeIfPresent(SkeletonAutocomplete.self, forKey: .autocomplete)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .TextField)
        try elementContainer.encodeIfPresent(self.text, forKey: .text)
        try elementContainer.encodeIfPresent(self.sourceKeypath, forKey: .sourceKeypath)
        try elementContainer.encodeIfPresent(self.targetKeypath, forKey: .targetKeypath)
        try elementContainer.encodeIfPresent(self.placeholder, forKey: .placeholder)
        try elementContainer.encodeIfPresent(self.autocomplete, forKey: .autocomplete)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
    
    public func asyncContent(userInfoValue: ValueType? = nil) async -> String {
        // Behavior mirrors SkeletonText.asyncContent: prefer provided userInfoValue/keypath, fallback to static text
        if let userInfoValue, let sourceKeypath {
            switch userInfoValue {
            case .string(let string):
                return string
            case .float(let float):
                return String(float)
            case .integer(let integer):
                return String(integer)
            case .number(let integer):
                return String(integer)
            case .object(let object):
                if let returnObjectValue = try? object.get(keypath: sourceKeypath),
                   let responseString = try? returnObjectValue.jsonString() {
                    return skeletonUserFacingString(responseString)
                } else {
                    return skeletonUnavailableUserMessage
                }
            default:
                return skeletonUnavailableUserMessage
            }
        } else if let text {
            return text
        }
        return ""
    }
}

public enum SkeletonTextAreaEditorMode: String, Codable {
    case plain
    case richMarkdown
}

public struct SkeletonTextArea: Codable, Identifiable {
    public var id = UUID()
    public var text: String?
    public var sourceKeypath: String?
    public var targetKeypath: String?
    public var placeholder: String?
    public var minLines: Int?
    public var maxLines: Int?
    public var submitOnEnter: Bool?
    public var submitActionKeypath: String?
    public var editorMode: SkeletonTextAreaEditorMode?
    public var modifiers: SkeletonModifiers?

    public enum CodingKeys: CodingKey {
        case text
        case sourceKeypath
        case targetKeypath
        case placeholder
        case minLines
        case maxLines
        case submitOnEnter
        case submitActionKeypath
        case editorMode
        case modifiers
    }
    enum ElementKey: CodingKey { case TextArea }

    public init(
        text: String? = nil,
        sourceKeypath: String? = nil,
        targetKeypath: String? = nil,
        placeholder: String? = nil,
        minLines: Int? = nil,
        maxLines: Int? = nil,
        submitOnEnter: Bool? = nil,
        submitActionKeypath: String? = nil,
        editorMode: SkeletonTextAreaEditorMode? = nil,
        modifiers: SkeletonModifiers? = nil
    ) {
        self.text = text
        self.sourceKeypath = sourceKeypath
        self.targetKeypath = targetKeypath
        self.placeholder = placeholder
        self.minLines = minLines
        self.maxLines = maxLines
        self.submitOnEnter = submitOnEnter
        self.submitActionKeypath = submitActionKeypath
        self.editorMode = editorMode
        self.modifiers = modifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.sourceKeypath = try container.decodeIfPresent(String.self, forKey: .sourceKeypath)
        self.targetKeypath = try container.decodeIfPresent(String.self, forKey: .targetKeypath)
        self.placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        self.minLines = try container.decodeIfPresent(Int.self, forKey: .minLines)
        self.maxLines = try container.decodeIfPresent(Int.self, forKey: .maxLines)
        self.submitOnEnter = try container.decodeIfPresent(Bool.self, forKey: .submitOnEnter)
        self.submitActionKeypath = try container.decodeIfPresent(String.self, forKey: .submitActionKeypath)
        self.editorMode = try container.decodeIfPresent(SkeletonTextAreaEditorMode.self, forKey: .editorMode)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .TextArea)
        try elementContainer.encodeIfPresent(self.text, forKey: .text)
        try elementContainer.encodeIfPresent(self.sourceKeypath, forKey: .sourceKeypath)
        try elementContainer.encodeIfPresent(self.targetKeypath, forKey: .targetKeypath)
        try elementContainer.encodeIfPresent(self.placeholder, forKey: .placeholder)
        try elementContainer.encodeIfPresent(self.minLines, forKey: .minLines)
        try elementContainer.encodeIfPresent(self.maxLines, forKey: .maxLines)
        try elementContainer.encodeIfPresent(self.submitOnEnter, forKey: .submitOnEnter)
        try elementContainer.encodeIfPresent(self.submitActionKeypath, forKey: .submitActionKeypath)
        try elementContainer.encodeIfPresent(self.editorMode, forKey: .editorMode)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }

    public func asyncContent(userInfoValue: ValueType? = nil) async -> String {
        let proxy = SkeletonTextField(
            text: text,
            sourceKeypath: sourceKeypath,
            targetKeypath: targetKeypath,
            placeholder: placeholder,
            modifiers: modifiers
        )
        return await proxy.asyncContent(userInfoValue: userInfoValue)
    }
}

public struct SkeletonHStack: Codable, Identifiable {
    public var id = UUID()
    public var elements: SkeletonElementList
    public var spacing: Double?
    public var modifiers: SkeletonModifiers?
    
    enum ElementKey: CodingKey { case HStack }
    enum CodingKeys: CodingKey {
        case elements
        case spacing
        case modifiers
    }
    
    public init(elements: SkeletonElementList, spacing: Double? = nil, modifiers: SkeletonModifiers? = nil) {
        self.elements = elements
        self.spacing = spacing
        self.modifiers = modifiers
    }
    public init(from decoder: any Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.elements) || container.contains(.spacing) || container.contains(.modifiers) {
            self.elements = try container.decodeIfPresent(SkeletonElementList.self, forKey: .elements) ?? SkeletonElementList()
            self.spacing = try container.decodeIfPresent(Double.self, forKey: .spacing)
            self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
            return
        }
        
         do {
             var unkeyedContainer = try decoder.unkeyedContainer()
             var elements = SkeletonElementList()
             while unkeyedContainer.isAtEnd != true {
                 do {
                     let decodedObject = try unkeyedContainer.decode(SkeletonElement.self)
                     elements.append(decodedObject)
                 } catch { CellBase.diagnosticLog("Decoding SkeletonHStack element failed with error: \(error)", domain: .skeleton) }
             }
             self.elements = elements
             self.spacing = nil
             self.modifiers = nil
             return
         } catch {
             CellBase.diagnosticLog("Decoding SkeletonHStack failed with error: \(error)", domain: .skeleton)
             elements = SkeletonElementList() // hmmmm
             self.spacing = nil
             self.modifiers = nil
         }
         
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        if spacing == nil && modifiers == nil {
            var elementContainer = container.nestedUnkeyedContainer(forKey: .HStack)
            for element in elements {
                try elementContainer.encode(element)
            }
            return
        }

        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .HStack)
        try elementContainer.encode(self.elements, forKey: .elements)
        try elementContainer.encodeIfPresent(self.spacing, forKey: .spacing)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }

}

public struct SkeletonVStack: Codable, Identifiable {
    public var id = UUID()
    public var elements: SkeletonElementList
    public var spacing: Double?
    public var modifiers: SkeletonModifiers?
    
    enum ElementKey: CodingKey { case VStack }
    public enum CodingKeys: CodingKey {
        case id
        case elements
        case spacing
        case modifiers
    }
    
    public init(elements: SkeletonElementList, spacing: Double? = nil, modifiers: SkeletonModifiers? = nil) {
        self.elements = elements
        self.spacing = spacing
        self.modifiers = modifiers
    }
    
    public init(from decoder: any Decoder) throws {

        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.elements) || container.contains(.spacing) || container.contains(.modifiers) {
            self.elements = try container.decodeIfPresent(SkeletonElementList.self, forKey: .elements) ?? SkeletonElementList()
            self.spacing = try container.decodeIfPresent(Double.self, forKey: .spacing)
            self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
            return
        }

        elements = SkeletonElementList()
         do {
             
             var unkeyedContainer = try decoder.unkeyedContainer()
             
             while unkeyedContainer.isAtEnd != true {
                 do {
                     let decodedObject = try unkeyedContainer.decode(SkeletonElement.self)
                     elements.append(decodedObject)
//                     print("decodedObject: \(decodedObject)")
                 } catch {
                     CellBase.diagnosticLog("Decoding SkeletonVStack element failed with error: \(error)", domain: .skeleton)
                 }
             }
             self.spacing = nil
             self.modifiers = nil
             return
         } catch {
             CellBase.diagnosticLog("Decoding SkeletonVStack failed with error: \(error)", domain: .skeleton)
             self.spacing = nil
             self.modifiers = nil
         }
         
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        if spacing == nil && modifiers == nil {
            var elementContainer = container.nestedUnkeyedContainer(forKey: .VStack)
            for element in elements {
                try elementContainer.encode(element)
            }
            return
        }

        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .VStack)
        try elementContainer.encode(self.elements, forKey: .elements)
        try elementContainer.encodeIfPresent(self.spacing, forKey: .spacing)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

/// A cell-supplied, already ordered visible node list. No renderer traversal or
/// filtering. ID/parentID and level (root = 1) are independent of leading inset.
/// Selection sends {nodeID:String}; expansion sends {nodeID:String, expanded:Bool}
/// and waits for the cell's confirmed list. Row data drives row/disclosure modifiers.
/// All keypaths and the wrapped rowSkeleton are required; optional modifiers add
/// no List shell. Missing actions are format errors and also audit errors for
/// programmatically incomplete trees.
public struct SkeletonTree: Codable, Identifiable {
    public var id = UUID() // transient Swift identity; never a source/node/instance identifier
    public var keypath: String
    public var idKeypath: String
    public var parentIDKeypath: String
    public var levelKeypath: String
    public var leadingInsetKeypath: String
    public var hasChildrenKeypath: String
    public var expandedKeypath: String
    public var selectedIDStateKeypath: String
    public var selectionActionKeypath: String
    public var expansionActionKeypath: String
    public var rowSkeleton: SkeletonVStack
    public var disclosureModifiers: SkeletonModifiers?
    public var rowModifiers: SkeletonModifiers?
    public var modifiers: SkeletonModifiers?

    public init(
        keypath: String,
        idKeypath: String,
        parentIDKeypath: String,
        levelKeypath: String,
        leadingInsetKeypath: String,
        hasChildrenKeypath: String,
        expandedKeypath: String,
        selectedIDStateKeypath: String,
        selectionActionKeypath: String,
        expansionActionKeypath: String,
        rowSkeleton: SkeletonVStack,
        disclosureModifiers: SkeletonModifiers? = nil,
        rowModifiers: SkeletonModifiers? = nil,
        modifiers: SkeletonModifiers? = nil
    ) {
        self.keypath = keypath
        self.idKeypath = idKeypath
        self.parentIDKeypath = parentIDKeypath
        self.levelKeypath = levelKeypath
        self.leadingInsetKeypath = leadingInsetKeypath
        self.hasChildrenKeypath = hasChildrenKeypath
        self.expandedKeypath = expandedKeypath
        self.selectedIDStateKeypath = selectedIDStateKeypath
        self.selectionActionKeypath = selectionActionKeypath
        self.expansionActionKeypath = expansionActionKeypath
        self.rowSkeleton = rowSkeleton
        self.disclosureModifiers = disclosureModifiers
        self.rowModifiers = rowModifiers
        self.modifiers = modifiers
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case keypath, idKeypath, parentIDKeypath, levelKeypath, leadingInsetKeypath, hasChildrenKeypath, expandedKeypath, selectedIDStateKeypath, selectionActionKeypath, expansionActionKeypath, rowSkeleton, disclosureModifiers, rowModifiers, modifiers
    }

    public init(from decoder: Decoder) throws {
        let payloadDecoder: Decoder
        let wrapper = try decoder.container(keyedBy: DynamicCodingKey.self)
        if wrapper.allKeys.count == 1, let key = wrapper.allKeys.first, key.stringValue == "Tree" {
            payloadDecoder = try wrapper.superDecoder(forKey: key)
        } else { payloadDecoder = decoder }
        try skeletonKnownKeys(payloadDecoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try payloadDecoder.container(keyedBy: CodingKeys.self)
        self.keypath = try container.skeletonRequired(String.self, forKey: .keypath)
        self.idKeypath = try container.skeletonRequired(String.self, forKey: .idKeypath)
        self.parentIDKeypath = try container.skeletonRequired(String.self, forKey: .parentIDKeypath)
        self.levelKeypath = try container.skeletonRequired(String.self, forKey: .levelKeypath)
        self.leadingInsetKeypath = try container.skeletonRequired(String.self, forKey: .leadingInsetKeypath)
        self.hasChildrenKeypath = try container.skeletonRequired(String.self, forKey: .hasChildrenKeypath)
        self.expandedKeypath = try container.skeletonRequired(String.self, forKey: .expandedKeypath)
        self.selectedIDStateKeypath = try container.skeletonRequired(String.self, forKey: .selectedIDStateKeypath)
        self.selectionActionKeypath = try container.skeletonRequired(String.self, forKey: .selectionActionKeypath)
        self.expansionActionKeypath = try container.skeletonRequired(String.self, forKey: .expansionActionKeypath)
        // Do not pass a wrapper to VStack's permissive bare-payload decoder.
        let rowDecoder = try container.superDecoder(forKey: .rowSkeleton)
        let rowWrapper = try rowDecoder.container(keyedBy: DynamicCodingKey.self)
        guard rowWrapper.allKeys.count == 1, let key = rowWrapper.allKeys.first, key.stringValue == "VStack" else {
            throw SkeletonFormatError(field: "rowSkeleton", reason: "expected a wrapped VStack")
        }
        let body = try rowWrapper.superDecoder(forKey: key)
        // VStack's legacy decoder can turn invalid payloads into an empty stack.
        if let object = try? body.container(keyedBy: SkeletonVStack.CodingKeys.self) {
            _ = try object.skeletonRequired(SkeletonElementList.self, forKey: .elements)
        } else {
            _ = try body.unkeyedContainer()
        }
        let decodedRow = try container.skeletonRequired(SkeletonElement.self, forKey: .rowSkeleton)
        guard case .VStack(let row) = decodedRow else {
            let reason: String
            if case .Unsupported(let failure) = decodedRow { reason = failure.reason ?? "unsupported VStack" }
            else { reason = "expected VStack" }
            throw SkeletonFormatError(field: "rowSkeleton", reason: reason)
        }
        self.rowSkeleton = row
        self.disclosureModifiers = try container.skeletonValue(SkeletonModifiers.self, forKey: .disclosureModifiers)
        self.rowModifiers = try container.skeletonValue(SkeletonModifiers.self, forKey: .rowModifiers)
        self.modifiers = try container.skeletonValue(SkeletonModifiers.self, forKey: .modifiers)
        try skeletonNonempty(keypath, field: "keypath")
        try skeletonNonempty(idKeypath, field: "idKeypath")
        try skeletonNonempty(parentIDKeypath, field: "parentIDKeypath")
        try skeletonNonempty(levelKeypath, field: "levelKeypath")
        try skeletonNonempty(leadingInsetKeypath, field: "leadingInsetKeypath")
        try skeletonNonempty(hasChildrenKeypath, field: "hasChildrenKeypath")
        try skeletonNonempty(expandedKeypath, field: "expandedKeypath")
        try skeletonNonempty(selectedIDStateKeypath, field: "selectedIDStateKeypath")
        try skeletonNonempty(selectionActionKeypath, field: "selectionActionKeypath")
        try skeletonNonempty(expansionActionKeypath, field: "expansionActionKeypath")
    }

    private enum ElementKey: CodingKey { case Tree }

    public func encode(to encoder: Encoder) throws {
        try skeletonNonempty(keypath, field: "keypath")
        try skeletonNonempty(idKeypath, field: "idKeypath")
        try skeletonNonempty(parentIDKeypath, field: "parentIDKeypath")
        try skeletonNonempty(levelKeypath, field: "levelKeypath")
        try skeletonNonempty(leadingInsetKeypath, field: "leadingInsetKeypath")
        try skeletonNonempty(hasChildrenKeypath, field: "hasChildrenKeypath")
        try skeletonNonempty(expandedKeypath, field: "expandedKeypath")
        try skeletonNonempty(selectedIDStateKeypath, field: "selectedIDStateKeypath")
        try skeletonNonempty(selectionActionKeypath, field: "selectionActionKeypath")
        try skeletonNonempty(expansionActionKeypath, field: "expansionActionKeypath")
        var wrapper = encoder.container(keyedBy: ElementKey.self)
        var container = wrapper.nestedContainer(keyedBy: CodingKeys.self, forKey: .Tree)
        try container.encode(keypath, forKey: .keypath)
        try container.encode(idKeypath, forKey: .idKeypath)
        try container.encode(parentIDKeypath, forKey: .parentIDKeypath)
        try container.encode(levelKeypath, forKey: .levelKeypath)
        try container.encode(leadingInsetKeypath, forKey: .leadingInsetKeypath)
        try container.encode(hasChildrenKeypath, forKey: .hasChildrenKeypath)
        try container.encode(expandedKeypath, forKey: .expandedKeypath)
        try container.encode(selectedIDStateKeypath, forKey: .selectedIDStateKeypath)
        try container.encode(selectionActionKeypath, forKey: .selectionActionKeypath)
        try container.encode(expansionActionKeypath, forKey: .expansionActionKeypath)
        try container.encode(rowSkeleton, forKey: .rowSkeleton)
        try container.encodeIfPresent(disclosureModifiers, forKey: .disclosureModifiers)
        try container.encodeIfPresent(rowModifiers, forKey: .rowModifiers)
        try container.encodeIfPresent(modifiers, forKey: .modifiers)
    }
}

/// Mount a versioned definition obtained through sourceKeypath. The source
/// descriptor owns componentID/revision; instanceID is a nonblank, persisted,
/// opaque ID supplied by the cell. Two mounts of one source need different IDs.
/// Preserve instanceID across layout/variant changes; do not key mounts by source
/// keypath or the transient UUID. variant is required (inline or pinned).
/// Resolution, subscriptions and persistence are host/cell work, not parser I/O.
public struct SkeletonComponentSurface: Codable, Identifiable {
    public var id = UUID() // transient Swift identity; never a source/node/instance identifier
    public var sourceKeypath: String
    /// Fast instans-ID for én flate.
    public var instanceID: String?
    /// WP-F (vei B): instans-ID lest fra data (radens item først, så roten), slik at hver rad i
    /// en List får sin egen flate og tilstand. Nøyaktig én av `instanceID` og
    /// `instanceIDKeypath` er satt.
    public var instanceIDKeypath: String?
    public var variant: SkeletonComponentVariant
    public var modifiers: SkeletonModifiers?

    public init(
        sourceKeypath: String,
        instanceID: String,
        variant: SkeletonComponentVariant,
        modifiers: SkeletonModifiers? = nil
    ) {
        self.sourceKeypath = sourceKeypath
        self.instanceID = instanceID
        self.variant = variant
        self.modifiers = modifiers
    }

    public init(
        sourceKeypath: String,
        instanceIDKeypath: String,
        variant: SkeletonComponentVariant,
        modifiers: SkeletonModifiers? = nil
    ) {
        self.sourceKeypath = sourceKeypath
        self.instanceIDKeypath = instanceIDKeypath
        self.variant = variant
        self.modifiers = modifiers
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sourceKeypath, instanceID, instanceIDKeypath, variant, modifiers
    }

    private static func validateInstance(_ id: String?, _ keypath: String?) throws {
        switch (id, keypath) {
        case let (id?, nil): try skeletonNonempty(id, field: "instanceID")
        case let (nil, keypath?): try skeletonNonempty(keypath, field: "instanceIDKeypath")
        case (nil, nil): throw SkeletonFormatError(field: "instanceID", reason: "instanceID or instanceIDKeypath is required")
        default: throw SkeletonFormatError(field: "instanceIDKeypath", reason: "use either instanceID or instanceIDKeypath, not both")
        }
    }

    public init(from decoder: Decoder) throws {
        let payloadDecoder: Decoder
        let wrapper = try decoder.container(keyedBy: DynamicCodingKey.self)
        if wrapper.allKeys.count == 1, let key = wrapper.allKeys.first, key.stringValue == "ComponentSurface" {
            payloadDecoder = try wrapper.superDecoder(forKey: key)
        } else { payloadDecoder = decoder }
        try skeletonKnownKeys(payloadDecoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try payloadDecoder.container(keyedBy: CodingKeys.self)
        self.sourceKeypath = try container.skeletonRequired(String.self, forKey: .sourceKeypath)
        self.instanceID = try container.skeletonValue(String.self, forKey: .instanceID)
        self.instanceIDKeypath = try container.skeletonValue(String.self, forKey: .instanceIDKeypath)
        self.variant = try container.skeletonRequired(SkeletonComponentVariant.self, forKey: .variant)
        self.modifiers = try container.skeletonValue(SkeletonModifiers.self, forKey: .modifiers)
        try skeletonNonempty(sourceKeypath, field: "sourceKeypath")
        try Self.validateInstance(instanceID, instanceIDKeypath)
    }

    private enum ElementKey: CodingKey { case ComponentSurface }

    public func encode(to encoder: Encoder) throws {
        try skeletonNonempty(sourceKeypath, field: "sourceKeypath")
        try Self.validateInstance(instanceID, instanceIDKeypath)
        var wrapper = encoder.container(keyedBy: ElementKey.self)
        var container = wrapper.nestedContainer(keyedBy: CodingKeys.self, forKey: .ComponentSurface)
        try container.encode(sourceKeypath, forKey: .sourceKeypath)
        try container.encodeIfPresent(instanceID, forKey: .instanceID)
        try container.encodeIfPresent(instanceIDKeypath, forKey: .instanceIDKeypath)
        try container.encode(variant, forKey: .variant)
        try container.encodeIfPresent(modifiers, forKey: .modifiers)
    }
}

/// Cell-supplied value at ComponentSurface.sourceKeypath (WP-R1, §2.2).
/// The definition is unchanged across instances of the same componentID/revision.
/// Reads use this mount's item first, then the host root; absent item uses root
/// only. Actions target sourceCellEndpoint with {instanceID, componentID, revision}
/// in a separate `mount` field beside the original payload. The source cell
/// authorizes the action. The surface owns instanceID, including across updates;
/// changing revision remounts the definition while retaining that instanceID.
/// This descriptor performs no lookup, subscription, dispatch or authorization.
public struct SkeletonComponentMount: Codable {
    public var componentID: String
    public var revision: String
    public var sourceCellEndpoint: String
    public var skeleton: SkeletonElement
    public var item: ValueType?

    public init(componentID: String, revision: String, sourceCellEndpoint: String,
                skeleton: SkeletonElement, item: ValueType? = nil) {
        self.componentID = componentID
        self.revision = revision
        self.sourceCellEndpoint = sourceCellEndpoint
        self.skeleton = skeleton
        self.item = item
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case componentID, revision, sourceCellEndpoint, skeleton, item
    }

    private func validate() throws {
        try skeletonNonempty(componentID, field: "componentID")
        try skeletonNonempty(revision, field: "revision")
        try skeletonNonempty(sourceCellEndpoint, field: "sourceCellEndpoint")
        if case .Unsupported(let failure) = skeleton {
            throw SkeletonFormatError(field: "skeleton", reason: failure.reason ?? "unsupported definition")
        }
    }

    public init(from decoder: Decoder) throws {
        try skeletonKnownKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.componentID = try container.skeletonRequired(String.self, forKey: .componentID)
        self.revision = try container.skeletonRequired(String.self, forKey: .revision)
        self.sourceCellEndpoint = try container.skeletonRequired(String.self, forKey: .sourceCellEndpoint)
        // Legacy element decoders can accept scalar payloads as empty elements.
        // Require the canonical single-key wrapper and an object/array payload.
        do {
            let definition = try container.superDecoder(forKey: .skeleton)
            let wrapper = try definition.container(keyedBy: DynamicCodingKey.self)
            guard wrapper.allKeys.count == 1, let key = wrapper.allKeys.first else {
                throw SkeletonFormatError(field: "skeleton", reason: "expected one element wrapper")
            }
            let body = try wrapper.superDecoder(forKey: key)
            if (try? body.container(keyedBy: DynamicCodingKey.self)) == nil {
                _ = try body.unkeyedContainer()
            }
        } catch {
            throw SkeletonFormatError(field: "skeleton", reason: String(describing: error))
        }
        self.skeleton = try container.skeletonRequired(SkeletonElement.self, forKey: .skeleton)
        self.item = try container.skeletonValue(ValueType.self, forKey: .item)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(componentID, forKey: .componentID)
        try container.encode(revision, forKey: .revision)
        try container.encode(sourceCellEndpoint, forKey: .sourceCellEndpoint)
        try container.encode(skeleton, forKey: .skeleton)
        try container.encodeIfPresent(item, forKey: .item)
    }
}

public enum SkeletonListSelectionMode: String, Codable {
    case none
    case single
    case multiple
}

public enum SkeletonListSelectionPayloadMode: String, Codable {
    case item
    case itemID = "item_id"
    case selectedItems = "selected_items"
    case selectedIDs = "selected_ids"
}

public enum SkeletonListSelectionTrigger: String, Codable {
    case select
    case deselect
    case activate
}

public enum SkeletonListConfigurationError: Error {
    case missingSelectionValueKeypath(SkeletonListSelectionPayloadMode)
}

public enum SkeletonListSelectionPayloadError: Error {
    case invalidSelectionIndex(Int)
    case missingSelectionValue(String)
}

public struct SkeletonList: Codable, Identifiable {
    public var id = UUID()
    public var elements: ValueTypeList
    public var topic: String? // Which topic to update from
    public var keypath: String?
    public var filterTypes: [String]?
    public var selectionMode: SkeletonListSelectionMode?
    public var selectionValueKeypath: String?
    public var selectionStateKeypath: String?
    public var selectionActionKeypath: String?
    public var activationActionKeypath: String?
    public var selectionPayloadMode: SkeletonListSelectionPayloadMode?
    public var allowsEmptySelection: Bool?
    
    /// U2 (admin workbench 2026-09-05): keypath *inside a row* that holds the row's children
    /// (a list). When set, the renderer shows the list as a tree with a toggle per row that
    /// has children. Expansion is local to the renderer — no round trip to the cell.
    public var childrenKeypath: String?
    /// U2: optional root-state keypath holding the initially expanded row identities
    /// (a list of `selectionValueKeypath` values, or the single string "*" for all).
    /// Absent → every row with children starts expanded.
    public var expandedStateKeypath: String?
    /// U3: when true the list keeps the newest row in view as rows arrive, unless the
    /// reader has scrolled away from the bottom. Meant for logs and streams.
    public var followTail: Bool?
    public var flowElementSkeleton: SkeletonVStack?
    public var modifiers: SkeletonModifiers?
    
    enum ElementKey: CodingKey { case List }
    
    enum CodingKeys: CodingKey {
        case topic
        case keypath
        case filterTypes
        case selectionMode
        case selectionValueKeypath
        case selectionStateKeypath
        case selectionActionKeypath
        case activationActionKeypath
        case selectionPayloadMode
        case allowsEmptySelection
        case flowElementSkeleton
        case childrenKeypath
        case expandedStateKeypath
        case followTail
        case elements
        case modifiers
    }
    
    public init(elements: ValueTypeList, topic: String? = nil, keypath: String? = nil, flowElementSkeleton: SkeletonVStack? = nil) {
        self.elements = elements
        self.topic = topic
        self.keypath = keypath
        self.flowElementSkeleton = flowElementSkeleton
    }
    
    public init(topic: String? = nil, keypath: String? = nil, flowElementSkeleton: SkeletonVStack? = nil) {
        self.elements = ValueTypeList()
        self.topic = topic
        self.keypath = keypath
        self.flowElementSkeleton = flowElementSkeleton
    }
    
    
    public init(from decoder: any Decoder) throws {
//        print("Decode SkeletonList")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        //        self.elements = try container.decode(SkeletonElementList.self, forKey: .elements)

        self.flowElementSkeleton = nil

        let tempDecodedSkeletonVStackAsElement = try container.decodeIfPresent(SkeletonElement.self, forKey: .flowElementSkeleton)
        
        if case let .VStack(skeletonVStack) = tempDecodedSkeletonVStackAsElement {
            self.flowElementSkeleton = skeletonVStack
        }
        
        self.elements = ValueTypeList()
        if let valueList = try container.decodeIfPresent(ValueTypeList.self, forKey: .elements) {
            self.elements = valueList
        }
        self.topic = try container.decodeIfPresent(String.self, forKey: .topic)
        self.keypath = try container.decodeIfPresent(String.self, forKey: .keypath)
        self.filterTypes = try container.decodeIfPresent([String].self, forKey: .filterTypes)
        self.selectionMode = try container.decodeIfPresent(SkeletonListSelectionMode.self, forKey: .selectionMode)
        self.childrenKeypath = try container.decodeIfPresent(String.self, forKey: .childrenKeypath)
        self.expandedStateKeypath = try container.decodeIfPresent(String.self, forKey: .expandedStateKeypath)
        self.followTail = try container.decodeIfPresent(Bool.self, forKey: .followTail)
        self.selectionValueKeypath = try container.decodeIfPresent(String.self, forKey: .selectionValueKeypath)
        self.selectionStateKeypath = try container.decodeIfPresent(String.self, forKey: .selectionStateKeypath)
        self.selectionActionKeypath = try container.decodeIfPresent(String.self, forKey: .selectionActionKeypath)
        self.activationActionKeypath = try container.decodeIfPresent(String.self, forKey: .activationActionKeypath)
        self.selectionPayloadMode = try container.decodeIfPresent(SkeletonListSelectionPayloadMode.self, forKey: .selectionPayloadMode)
        self.allowsEmptySelection = try container.decodeIfPresent(Bool.self, forKey: .allowsEmptySelection)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)

        try validateSelectionConfiguration()
    }
    
    
    // Is this the wrong place for this method?
    public func getElements() async throws -> ValueTypeList {
        if let resolver = CellBase.defaultCellResolver,
           let vault = CellBase.defaultIdentityVault,
           let requester = await vault.identity(for: "private", makeNewIfNotFound: false),
           let keypath = self.keypath,
           let cellURL = try? urlFromKeypath(keypath: keypath)
        {
        
            let inititalElements = try await resolver.get(from: cellURL, requester: requester)
            guard case .list(let valueTypeList) = inititalElements else {
                CellBase.diagnosticLog("Skeleton list expected List value from \(cellURL)", domain: .skeleton)
                return ValueTypeList()
            }
            return valueTypeList
        }
        
        return ValueTypeList()
    }
    
    public func encode(to encoder: any Encoder) throws {
        try validateSelectionConfiguration()
        
        var elementsContainer = encoder.container(keyedBy: ElementKey.self)
        
        var container = elementsContainer.nestedContainer(keyedBy: CodingKeys.self, forKey: .List)
        
        try container.encodeIfPresent(self.topic, forKey: .topic)
        try container.encodeIfPresent(self.keypath, forKey: .keypath)
        try container.encodeIfPresent(self.filterTypes, forKey: .filterTypes)
        try container.encodeIfPresent(self.selectionMode, forKey: .selectionMode)
        try container.encodeIfPresent(self.selectionValueKeypath, forKey: .selectionValueKeypath)
        try container.encodeIfPresent(self.selectionStateKeypath, forKey: .selectionStateKeypath)
        try container.encodeIfPresent(self.selectionActionKeypath, forKey: .selectionActionKeypath)
        try container.encodeIfPresent(self.activationActionKeypath, forKey: .activationActionKeypath)
        try container.encodeIfPresent(self.selectionPayloadMode, forKey: .selectionPayloadMode)
        try container.encodeIfPresent(self.allowsEmptySelection, forKey: .allowsEmptySelection)
        try container.encodeIfPresent(self.childrenKeypath, forKey: .childrenKeypath)
        try container.encodeIfPresent(self.expandedStateKeypath, forKey: .expandedStateKeypath)
        try container.encodeIfPresent(self.followTail, forKey: .followTail)
        if let rowSkeleton = self.flowElementSkeleton {
            try container.encode(SkeletonElement.VStack(rowSkeleton), forKey: .flowElementSkeleton)
        }
        try container.encodeIfPresent(self.elements, forKey: .elements)
        try container.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }

    private func validateSelectionConfiguration() throws {
        switch self.selectionPayloadMode {
        case .itemID?, .selectedIDs?:
            if self.selectionValueKeypath?.isEmpty != false {
                throw SkeletonListConfigurationError.missingSelectionValueKeypath(self.selectionPayloadMode!)
            }
        default:
            break
        }
    }

    public func selectionPayload(trigger: SkeletonListSelectionTrigger, rows: [ValueType], selectedIndices: [Int]) throws -> ValueType {
        try validateSelectionConfiguration()

        let normalizedIndices = Array(Set(selectedIndices)).sorted()
        for index in normalizedIndices where rows.indices.contains(index) == false {
            throw SkeletonListSelectionPayloadError.invalidSelectionIndex(index)
        }

        let effectiveSelectionMode: SkeletonListSelectionMode = {
            switch self.selectionMode {
            case .multiple?:
                return .multiple
            case .single?:
                return .single
            default:
                return normalizedIndices.count > 1 ? .multiple : .single
            }
        }()

        let effectivePayloadMode: SkeletonListSelectionPayloadMode = {
            if let selectionPayloadMode {
                return selectionPayloadMode
            }
            switch effectiveSelectionMode {
            case .multiple:
                return .selectedItems
            case .single, .none:
                return .item
            }
        }()

        var payload: Object = [
            "selectionMode": .string(effectiveSelectionMode.rawValue),
            "trigger": .string(trigger.rawValue)
        ]

        switch effectiveSelectionMode {
        case .multiple:
            let selectedRows = try normalizedIndices.map { index in
                try selectionPayloadValue(from: rows[index], payloadMode: effectivePayloadMode)
            }
            payload["selectedIndices"] = .list(normalizedIndices.map { .integer($0) })
            payload["selected"] = .list(selectedRows)
        case .single, .none:
            let selectedIndex = normalizedIndices.first
            payload["selectedIndex"] = selectedIndex.map { .integer($0) } ?? .null
            if let selectedIndex {
                payload["selected"] = try selectionPayloadValue(from: rows[selectedIndex], payloadMode: effectivePayloadMode)
            } else {
                payload["selected"] = .null
            }
        }

        return .object(payload)
    }

    private func selectionPayloadValue(from row: ValueType, payloadMode: SkeletonListSelectionPayloadMode) throws -> ValueType {
        switch payloadMode {
        case .item, .selectedItems:
            return row
        case .itemID, .selectedIDs:
            guard let selectionValueKeypath,
                  let selectedValue = row[selectionValueKeypath] else {
                throw SkeletonListSelectionPayloadError.missingSelectionValue(selectionValueKeypath ?? "")
            }
            return selectedValue
        }
    }
    
    func urlFromKeypath(keypath: String) throws -> URL {
        var url: URL?
        if keypath.hasPrefix("cell://") {
            url = URL(string: keypath)
        } else {
            url = URL(string: "cell:///Porthole/\(keypath)")
        }
        if let url = url {
            return url
        }
        throw URLKeypathError.badURL
    }
}

public enum URLKeypathError: Error {
    case badURL
}

public struct SkeletonObject: Codable, Identifiable {
    public var id = UUID()
    public var elements: SkeletonElementObject
    public var modifiers: SkeletonModifiers?
    
    public init(elements: SkeletonElementObject, modifiers: SkeletonModifiers? = nil) {
        self.elements = elements
        self.modifiers = modifiers  
    }

    public static func empty(modifiers: SkeletonModifiers? = nil) -> SkeletonObject {
        SkeletonObject(elements: [:], modifiers: modifiers)
    }
    
    enum ElementKey: CodingKey { case Object }
    enum CodingKeys: CodingKey {
        case elements
        case modifiers
    }

    public init(from decoder: any Decoder) throws {
        // Prefer direct decoding when elements are present (legacy unwrapped form)
        let directContainer = try decoder.container(keyedBy: CodingKeys.self)
        if directContainer.contains(.elements) {
            self.elements = try directContainer.decode(SkeletonElementObject.self, forKey: .elements)
            self.modifiers = try directContainer.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
            return
        }
        // Otherwise decode from the wrapped { "Object": { ... } } form
        let wrapper = try decoder.container(keyedBy: ElementKey.self)
        let container = try wrapper.nestedContainer(keyedBy: CodingKeys.self, forKey: .Object)
        self.elements = try container.decode(SkeletonElementObject.self, forKey: .elements)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .Object)
        try elementContainer.encode(self.elements, forKey: .elements)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

public struct SkeletonCellReference: Codable, Identifiable {
    public var id = UUID()
    public var keypath: String
    public var topic: String
    public var filterTypes: [String]?
    public var flowElementSkeleton: SkeletonVStack?
    public var scaledToFit = false
    public var padding: Double?
    public var modifiers: SkeletonModifiers?
    
    public enum CodingKeys: CodingKey {
        case id
        case keypath
        case topic
        case filterTypes
        case flowElementSkeleton
        case scaledToFit
        case padding
        case modifiers
    }
    
    enum ElementKey: CodingKey { case Reference }
    
    public init(keypath: String, topic: String) {
        self.keypath = keypath
        self.topic = topic
        
    }
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
//        self.elements = try container.decode(SkeletonElementList.self, forKey: .elements)
//        print("Decode SkeletonCellReference")

        if let id =  try container.decodeIfPresent(UUID.self, forKey: .id) {
            self.id = id
        }
        self.keypath = try container.decode(String.self, forKey: .keypath)
        self.topic = try container.decode(String.self, forKey: .topic)
        self.filterTypes = try container.decodeIfPresent([String].self, forKey: .filterTypes)
        let tempDecodedSkeletonVStackAsElement = try container.decodeIfPresent(SkeletonElement.self, forKey: .flowElementSkeleton)
        
        if case let .VStack(skeletonVStack) = tempDecodedSkeletonVStackAsElement {
            self.flowElementSkeleton = skeletonVStack
        }
//        self.flowElementSkeleton = try container.decodeIfPresent(SkeletonVStack.self, forKey: .flowElementSkeleton)
        if container.contains(.scaledToFit) {
            scaledToFit = try container.decode(Bool.self, forKey: .scaledToFit)
        }
        
        if container.contains(.padding) {
            self.padding = try container.decode(Double.self, forKey: .padding)
        }
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }
  
    public func encode(to encoder: any Encoder) throws {
//        print("Encode SkeletonReference")
        var container = encoder.container(keyedBy: ElementKey.self)
        
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self,
                                                         forKey: .Reference)
        
        try elementContainer.encode(self.keypath, forKey: .keypath)
        try elementContainer.encode(self.topic, forKey: .topic)
        try elementContainer.encodeIfPresent(self.filterTypes, forKey: .filterTypes)
        try elementContainer.encode(self.flowElementSkeleton, forKey: .flowElementSkeleton)
        if self.scaledToFit {
            try elementContainer.encode(self.scaledToFit, forKey: .scaledToFit)
        }
        if self.padding != nil {
            try elementContainer.encode(self.padding, forKey: .padding)
        }
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

public struct SkeletonButton: Codable, Identifiable {
    public var id = UUID()
    public var keypath: String
    public var label: String
    public var url: String?
    public var payload: ValueType?
    public var keypathKeypath: String?
    public var labelKeypath: String?
    public var payloadKeypath: String?
    /// SF Symbol name (e.g. "person.circle", "calendar", "message"), matching the
    /// convention `SkeletonImage.name` already uses for `type == "system"` images.
    /// Web renderers translate this into their own icon set (see the
    /// SF-Symbol-to-Lucide mapping table in skeleton-runtime.js) rather than the
    /// protocol carrying platform-specific icon identifiers.
    public var icon: String?
    public var modifiers: SkeletonModifiers?

    public init(
        keypath: String,
        label: String,
        url: String? = nil,
        payload: ValueType? = nil,
        keypathKeypath: String? = nil,
        labelKeypath: String? = nil,
        payloadKeypath: String? = nil,
        icon: String? = nil
    ) {
        self.keypath = keypath
        self.label = label
        self.url = url
        self.payload = payload
        self.keypathKeypath = keypathKeypath
        self.labelKeypath = labelKeypath
        self.payloadKeypath = payloadKeypath
        self.icon = icon
    }

    public enum CodingKeys: CodingKey {
        case id
        case keypath
        case label
        case url
        case payload
        case keypathKeypath
        case labelKeypath
        case payloadKeypath
        case icon
        case modifiers
    }

    enum ElementKey: CodingKey { case Button }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        //        self.elements = try container.decode(SkeletonElementList.self, forKey: .elements)
//        print("Decode SkeletonButton")

        if let id =  try container.decodeIfPresent(UUID.self, forKey: .id) {
            self.id = id
        }
        self.keypath = try container.decode(String.self, forKey: .keypath)
        self.label = try container.decode(String.self, forKey: .label)
        self.url = try container.decodeIfPresent(String.self, forKey: .url)
        self.payload = try container.decodeIfPresent(ValueType.self, forKey: .payload)
        self.keypathKeypath = try container.decodeIfPresent(String.self, forKey: .keypathKeypath)
        self.labelKeypath = try container.decodeIfPresent(String.self, forKey: .labelKeypath)
        self.payloadKeypath = try container.decodeIfPresent(String.self, forKey: .payloadKeypath)
        self.icon = try container.decodeIfPresent(String.self, forKey: .icon)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)


    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)

        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self,
                                                         forKey: .Button)

        try elementContainer.encode(self.keypath, forKey: .keypath)
        try elementContainer.encode(self.label, forKey: .label)
        try elementContainer.encodeIfPresent(self.url, forKey: .url)
        try elementContainer.encodeIfPresent(self.payload, forKey: .payload)
        try elementContainer.encodeIfPresent(self.keypathKeypath, forKey: .keypathKeypath)
        try elementContainer.encodeIfPresent(self.labelKeypath, forKey: .labelKeypath)
        try elementContainer.encodeIfPresent(self.payloadKeypath, forKey: .payloadKeypath)
        try elementContainer.encodeIfPresent(self.icon, forKey: .icon)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
        
    
    public func execute(requester explicitRequester: Identity? = nil) async -> ValueType? {
        guard SkeletonButtonNavigation.isNavigationButton(self) == false else {
            return nil
        }
        guard let resolver = CellBase.defaultCellResolver else {
            return nil
        }

        let requester: Identity?
        if let explicitRequester {
            requester = explicitRequester
        } else if let vault = CellBase.defaultIdentityVault {
            requester = await vault.identity(for: "private", makeNewIfNotFound: true)
        } else {
            requester = nil
        }

        guard let requester else {
            return nil
        }

        do {
            let targetCell = try await resolver.cellAtEndpoint(endpoint: url ?? "cell:///Porthole", requester: requester)
            if let meddleTarget = targetCell as? Meddle {
                if payload != nil {
                    return try await meddleTarget.set(keypath: keypath, value: payload!, requester: requester)
                } else {
                    return try await meddleTarget.get(keypath: keypath, requester: requester)
                }
            }
        } catch {
            CellBase.diagnosticLog("Execute button failed with error: \(error)", domain: .skeleton)
        }
        return nil
    }
}

public struct SkeletonDivider: Codable, Identifiable {
    public var id = UUID()
    public var modifiers: SkeletonModifiers?
    
    enum CodingKeys: CodingKey {
        case modifiers
    }
    enum ElementKey: CodingKey { case Divider }
    
    public init() {}
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .Divider)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

public struct SkeletonScrollView: Codable, Identifiable {
    public var id = UUID()
    public var axis: String?
    public var elements: SkeletonElementList
    public var modifiers: SkeletonModifiers?
    
    enum ElementKey: CodingKey { case ScrollView }
    enum CodingKeys: CodingKey {
        case axis
        case elements
        case modifiers
    }
    
    public init(axis: String? = nil, elements: SkeletonElementList) {
        self.axis = axis
        self.elements = elements
    }
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.axis = try container.decodeIfPresent(String.self, forKey: .axis)
        self.elements = try container.decode(SkeletonElementList.self, forKey: .elements)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .ScrollView)
        try elementContainer.encodeIfPresent(self.axis, forKey: .axis)
        try elementContainer.encode(self.elements, forKey: .elements)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

public struct SkeletonSection: Codable, Identifiable {
    public var id = UUID()
    public var header: SkeletonElement?
    public var footer: SkeletonElement?
    public var content: SkeletonElementList
    public var modifiers: SkeletonModifiers?
    
    enum ElementKey: CodingKey { case Section }
    enum CodingKeys: CodingKey {
        case header
        case footer
        case content
        case modifiers
    }
    
    public init(header: SkeletonElement? = nil, footer: SkeletonElement? = nil, content: SkeletonElementList) {
        self.header = header
        self.footer = footer
        self.content = content
    }
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.header = try container.decodeIfPresent(SkeletonElement.self, forKey: .header)
        self.footer = try container.decodeIfPresent(SkeletonElement.self, forKey: .footer)
        self.content = try container.decode(SkeletonElementList.self, forKey: .content)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .Section)
        try elementContainer.encodeIfPresent(self.header, forKey: .header)
        try elementContainer.encodeIfPresent(self.footer, forKey: .footer)
        try elementContainer.encode(self.content, forKey: .content)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

public struct SkeletonTabPanel: Codable, Identifiable {
    public var id: String
    public var content: SkeletonElementList
    public var modifiers: SkeletonModifiers?

    public enum CodingKeys: CodingKey {
        case id
        case content
        case modifiers
    }

    public init(id: String, content: SkeletonElementList, modifiers: SkeletonModifiers? = nil) {
        self.id = id
        self.content = content
        self.modifiers = modifiers
    }
}

public struct SkeletonTabs: Codable, Identifiable {
    public var id = UUID()
    public var tabsKeypath: String?
    public var activeTabStateKeypath: String
    public var selectionActionKeypath: String?
    public var idKeypath: String
    public var labelKeypath: String
    public var panels: [SkeletonTabPanel]
    public var modifiers: SkeletonModifiers?

    enum ElementKey: CodingKey { case Tabs }
    public enum CodingKeys: CodingKey {
        case id
        case tabsKeypath
        case activeTabStateKeypath
        case selectionActionKeypath
        case idKeypath
        case labelKeypath
        case panels
        case modifiers
    }

    public init(
        id: UUID = UUID(),
        tabsKeypath: String? = nil,
        activeTabStateKeypath: String,
        selectionActionKeypath: String? = nil,
        idKeypath: String = "id",
        labelKeypath: String = "title",
        panels: [SkeletonTabPanel],
        modifiers: SkeletonModifiers? = nil
    ) {
        self.id = id
        self.tabsKeypath = tabsKeypath
        self.activeTabStateKeypath = activeTabStateKeypath
        self.selectionActionKeypath = selectionActionKeypath
        self.idKeypath = idKeypath
        self.labelKeypath = labelKeypath
        self.panels = panels
        self.modifiers = modifiers
    }

    public init(from decoder: any Decoder) throws {
        if let last = decoder.codingPath.last, last.stringValue == "Tabs" {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decodedID = try container.decodeIfPresent(UUID.self, forKey: .id)
            if let decodedID { self.id = decodedID }
            self.tabsKeypath = try container.decodeIfPresent(String.self, forKey: .tabsKeypath)
            self.activeTabStateKeypath = try container.decode(String.self, forKey: .activeTabStateKeypath)
            self.selectionActionKeypath = try container.decodeIfPresent(String.self, forKey: .selectionActionKeypath)
            self.idKeypath = try container.decodeIfPresent(String.self, forKey: .idKeypath) ?? "id"
            self.labelKeypath = try container.decodeIfPresent(String.self, forKey: .labelKeypath) ?? "title"
            self.panels = try container.decode([SkeletonTabPanel].self, forKey: .panels)
            self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
        } else {
            let wrapper = try decoder.container(keyedBy: ElementKey.self)
            let container = try wrapper.nestedContainer(keyedBy: CodingKeys.self, forKey: .Tabs)
            let decodedID = try container.decodeIfPresent(UUID.self, forKey: .id)
            if let decodedID { self.id = decodedID }
            self.tabsKeypath = try container.decodeIfPresent(String.self, forKey: .tabsKeypath)
            self.activeTabStateKeypath = try container.decode(String.self, forKey: .activeTabStateKeypath)
            self.selectionActionKeypath = try container.decodeIfPresent(String.self, forKey: .selectionActionKeypath)
            self.idKeypath = try container.decodeIfPresent(String.self, forKey: .idKeypath) ?? "id"
            self.labelKeypath = try container.decodeIfPresent(String.self, forKey: .labelKeypath) ?? "title"
            self.panels = try container.decode([SkeletonTabPanel].self, forKey: .panels)
            self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .Tabs)
        try elementContainer.encode(self.id, forKey: .id)
        try elementContainer.encodeIfPresent(self.tabsKeypath, forKey: .tabsKeypath)
        try elementContainer.encode(self.activeTabStateKeypath, forKey: .activeTabStateKeypath)
        try elementContainer.encodeIfPresent(self.selectionActionKeypath, forKey: .selectionActionKeypath)
        try elementContainer.encode(self.idKeypath, forKey: .idKeypath)
        try elementContainer.encode(self.labelKeypath, forKey: .labelKeypath)
        try elementContainer.encode(self.panels, forKey: .panels)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

/// A single destination in a `SkeletonNavigationBar`.
///
/// An item is either an in-page action (`keypath` non-empty: tapping it calls
/// `set(keypath:value:)` on the current configuration, mirroring `SkeletonButton`)
/// or a cross-configuration navigation (`keypath` empty + `url` present, the same
/// convention `SkeletonButtonNavigation.isNavigationButton` already recognizes for
/// `SkeletonButton`). Only one of the two "active" signals applies per item, matching
/// whichever destination kind it is:
/// - `activeValue`: for in-page items, compared against the bar's
///   `activeStateKeypath` current value.
/// - `activeConfigurationName`: for cross-configuration items, compared against the
///   name of the CellConfiguration currently loaded by the renderer.
public struct SkeletonNavigationBarItem: Codable, Identifiable {
    public var id = UUID()
    public var keypath: String
    public var label: String
    public var url: String?
    public var payload: ValueType?
    public var keypathKeypath: String?
    public var labelKeypath: String?
    public var payloadKeypath: String?
    public var activeValue: String?
    public var activeConfigurationName: String?
    public var modifiers: SkeletonModifiers?

    public init(
        keypath: String,
        label: String,
        url: String? = nil,
        payload: ValueType? = nil,
        keypathKeypath: String? = nil,
        labelKeypath: String? = nil,
        payloadKeypath: String? = nil,
        activeValue: String? = nil,
        activeConfigurationName: String? = nil,
        modifiers: SkeletonModifiers? = nil
    ) {
        self.keypath = keypath
        self.label = label
        self.url = url
        self.payload = payload
        self.keypathKeypath = keypathKeypath
        self.labelKeypath = labelKeypath
        self.payloadKeypath = payloadKeypath
        self.activeValue = activeValue
        self.activeConfigurationName = activeConfigurationName
        self.modifiers = modifiers
    }

    public enum CodingKeys: CodingKey {
        case id
        case keypath
        case label
        case url
        case payload
        case keypathKeypath
        case labelKeypath
        case payloadKeypath
        case activeValue
        case activeConfigurationName
        case modifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(UUID.self, forKey: .id) {
            self.id = id
        }
        self.keypath = try container.decode(String.self, forKey: .keypath)
        self.label = try container.decode(String.self, forKey: .label)
        self.url = try container.decodeIfPresent(String.self, forKey: .url)
        self.payload = try container.decodeIfPresent(ValueType.self, forKey: .payload)
        self.keypathKeypath = try container.decodeIfPresent(String.self, forKey: .keypathKeypath)
        self.labelKeypath = try container.decodeIfPresent(String.self, forKey: .labelKeypath)
        self.payloadKeypath = try container.decodeIfPresent(String.self, forKey: .payloadKeypath)
        self.activeValue = try container.decodeIfPresent(String.self, forKey: .activeValue)
        self.activeConfigurationName = try container.decodeIfPresent(String.self, forKey: .activeConfigurationName)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.keypath, forKey: .keypath)
        try container.encode(self.label, forKey: .label)
        try container.encodeIfPresent(self.url, forKey: .url)
        try container.encodeIfPresent(self.payload, forKey: .payload)
        try container.encodeIfPresent(self.keypathKeypath, forKey: .keypathKeypath)
        try container.encodeIfPresent(self.labelKeypath, forKey: .labelKeypath)
        try container.encodeIfPresent(self.payloadKeypath, forKey: .payloadKeypath)
        try container.encodeIfPresent(self.activeValue, forKey: .activeValue)
        try container.encodeIfPresent(self.activeConfigurationName, forKey: .activeConfigurationName)
        try container.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

/// A bottom-anchored app-navigation bar, distinct from `SkeletonTabs`.
///
/// `Tabs` selection is pure in-page state (`activeTabStateKeypath` compared against
/// panel ids). `NavigationBar` additionally supports items that navigate to a whole
/// different `CellConfiguration` (see `SkeletonNavigationBarItem`), so "which item is
/// active" cannot be answered by a single state-keypath comparison the way `Tabs`
/// answers it — the renderer resolves each item's active flag independently based on
/// its destination kind.
public struct SkeletonNavigationBar: Codable, Identifiable {
    public var id = UUID()
    /// Root-state keypath read to determine which in-page item (if any) is active,
    /// compared against each item's `activeValue`. Mirrors `SkeletonTabs.activeTabStateKeypath`.
    public var activeStateKeypath: String?
    public var items: [SkeletonNavigationBarItem]
    public var modifiers: SkeletonModifiers?

    enum ElementKey: CodingKey { case NavigationBar }
    public enum CodingKeys: CodingKey {
        case id
        case activeStateKeypath
        case items
        case modifiers
    }

    public init(
        id: UUID = UUID(),
        activeStateKeypath: String? = nil,
        items: [SkeletonNavigationBarItem],
        modifiers: SkeletonModifiers? = nil
    ) {
        self.id = id
        self.activeStateKeypath = activeStateKeypath
        self.items = items
        self.modifiers = modifiers
    }

    public init(from decoder: any Decoder) throws {
        if let last = decoder.codingPath.last, last.stringValue == "NavigationBar" {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decodedID = try container.decodeIfPresent(UUID.self, forKey: .id)
            if let decodedID { self.id = decodedID }
            self.activeStateKeypath = try container.decodeIfPresent(String.self, forKey: .activeStateKeypath)
            self.items = try container.decode([SkeletonNavigationBarItem].self, forKey: .items)
            self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
        } else {
            let wrapper = try decoder.container(keyedBy: ElementKey.self)
            let container = try wrapper.nestedContainer(keyedBy: CodingKeys.self, forKey: .NavigationBar)
            let decodedID = try container.decodeIfPresent(UUID.self, forKey: .id)
            if let decodedID { self.id = decodedID }
            self.activeStateKeypath = try container.decodeIfPresent(String.self, forKey: .activeStateKeypath)
            self.items = try container.decode([SkeletonNavigationBarItem].self, forKey: .items)
            self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .NavigationBar)
        try elementContainer.encode(self.id, forKey: .id)
        try elementContainer.encodeIfPresent(self.activeStateKeypath, forKey: .activeStateKeypath)
        try elementContainer.encode(self.items, forKey: .items)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

// New structs added as per instructions:

public enum SkeletonGridColumnType: String, Codable { case fixed, flexible, adaptive }
public struct SkeletonGridColumn: Codable {
    public var type: SkeletonGridColumnType
    public var value: Double? // for fixed
    public var min: Double?   // for flexible/adaptive
    public var max: Double?   // for flexible/adaptive

    public init(type: SkeletonGridColumnType, value: Double? = nil, min: Double? = nil, max: Double? = nil) {
        self.type = type
        self.value = value
        self.min = min
        self.max = max
    }

    public static func fixed(_ value: Double) -> SkeletonGridColumn {
        SkeletonGridColumn(type: .fixed, value: value)
    }

    public static func flexible(min: Double = 0, max: Double? = nil) -> SkeletonGridColumn {
        SkeletonGridColumn(type: .flexible, min: min, max: max)
    }

    public static func adaptive(min: Double, max: Double? = nil) -> SkeletonGridColumn {
        SkeletonGridColumn(type: .adaptive, min: min, max: max)
    }
}

public struct SkeletonZStack: Codable, Identifiable {
    public var id = UUID()
    public var elements: SkeletonElementList
    public var modifiers: SkeletonModifiers?

    enum ElementKey: CodingKey { case ZStack }
    enum CodingKeys: CodingKey {
        case id
        case elements
        case modifiers
    }

    public init(elements: SkeletonElementList, modifiers: SkeletonModifiers? = nil) {
        self.elements = elements
        self.modifiers = modifiers
    }

    public init(from decoder: any Decoder) throws {
        if let last = decoder.codingPath.last, last.stringValue == "ZStack" {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decodedId = try container.decodeIfPresent(UUID.self, forKey: .id)
            if let decodedId { self.id = decodedId }
            self.elements = try container.decode(SkeletonElementList.self, forKey: .elements)
            self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
        } else {
            let wrapper = try decoder.container(keyedBy: ElementKey.self)
            let container = try wrapper.nestedContainer(keyedBy: CodingKeys.self, forKey: .ZStack)
            let decodedId = try container.decodeIfPresent(UUID.self, forKey: .id)
            if let decodedId { self.id = decodedId }
            self.elements = try container.decode(SkeletonElementList.self, forKey: .elements)
            self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .ZStack)
        try elementContainer.encode(self.id, forKey: .id)
        try elementContainer.encode(self.elements, forKey: .elements)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

public struct SkeletonGrid: Codable, Identifiable {
    public var id = UUID()
    public var columns: [SkeletonGridColumn]
    public var spacing: Double?
    public var keypath: String?
    public var itemSkeleton: SkeletonElement?
    public var elements: SkeletonElementList
    public var modifiers: SkeletonModifiers?

    enum ElementKey: CodingKey { case Grid }
    enum CodingKeys: CodingKey {
        case id
        case columns
        case spacing
        case keypath
        case itemSkeleton
        case elements
        case modifiers
    }

    public init(
        columns: [SkeletonGridColumn],
        spacing: Double? = nil,
        keypath: String? = nil,
        itemSkeleton: SkeletonElement? = nil,
        elements: SkeletonElementList = [],
        modifiers: SkeletonModifiers? = nil
    ) {
        self.columns = columns
        self.spacing = spacing
        self.keypath = keypath
        self.itemSkeleton = itemSkeleton
        self.elements = elements
        self.modifiers = modifiers
    }

    public init(from decoder: any Decoder) throws {
        // Try to decode either directly with CodingKeys, or via a nested container under ElementKey.Grid
        if let last = decoder.codingPath.last, last.stringValue == "Grid" {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decodedId = try container.decodeIfPresent(UUID.self, forKey: .id)
            if let decodedId { self.id = decodedId }
            self.columns = try container.decode([SkeletonGridColumn].self, forKey: .columns)
            self.spacing = try container.decodeIfPresent(Double.self, forKey: .spacing)
            self.keypath = try container.decodeIfPresent(String.self, forKey: .keypath)
            self.itemSkeleton = try container.decodeIfPresent(SkeletonElement.self, forKey: .itemSkeleton)
            self.elements = (try container.decodeIfPresent(SkeletonElementList.self, forKey: .elements)) ?? []
            self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
        } else {
            let wrapper = try decoder.container(keyedBy: ElementKey.self)
            let container = try wrapper.nestedContainer(keyedBy: CodingKeys.self, forKey: .Grid)
            let decodedId = try container.decodeIfPresent(UUID.self, forKey: .id)
            if let decodedId { self.id = decodedId }
            self.columns = try container.decode([SkeletonGridColumn].self, forKey: .columns)
            self.spacing = try container.decodeIfPresent(Double.self, forKey: .spacing)
            self.keypath = try container.decodeIfPresent(String.self, forKey: .keypath)
            self.itemSkeleton = try container.decodeIfPresent(SkeletonElement.self, forKey: .itemSkeleton)
            self.elements = (try container.decodeIfPresent(SkeletonElementList.self, forKey: .elements)) ?? []
            self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
        }
    }

    public func getItems() async throws -> ValueTypeList {
        if let resolver = CellBase.defaultCellResolver,
           let vault = CellBase.defaultIdentityVault,
           let requester = await vault.identity(for: "private", makeNewIfNotFound: false),
           let keypath = self.keypath,
           let cellURL = try? urlFromKeypath(keypath: keypath)
        {
            let initialItems = try await resolver.get(from: cellURL, requester: requester)
            guard case .list(let valueTypeList) = initialItems else {
                CellBase.diagnosticLog("Skeleton grid expected List value from \(cellURL)", domain: .skeleton)
                return ValueTypeList()
            }
            return valueTypeList
        }

        return ValueTypeList()
    }

    private func urlFromKeypath(keypath: String) throws -> URL {
        var url: URL?
        if keypath.hasPrefix("cell://") {
            url = URL(string: keypath)
        } else {
            url = URL(string: "cell:///Porthole/\(keypath)")
        }
        if let url {
            return url
        }
        throw URLKeypathError.badURL
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .Grid)
        try elementContainer.encode(self.columns, forKey: .columns)
        try elementContainer.encodeIfPresent(self.spacing, forKey: .spacing)
        try elementContainer.encodeIfPresent(self.keypath, forKey: .keypath)
        try elementContainer.encodeIfPresent(self.itemSkeleton, forKey: .itemSkeleton)
        try elementContainer.encodeIfPresent(self.elements, forKey: .elements)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

public struct SkeletonToggle: Codable, Identifiable {
    public var id = UUID()
    public var label: String
    public var keypath: String // cell:/// or relative (resolved like other keypaths)
    public var modifiers: SkeletonModifiers?
    public var isOn: Bool = false
    
    public init(id: UUID = UUID(), label: String, keypath: String, modifiers: SkeletonModifiers? = nil, isOn: Bool = false) {
        self.id = id
        self.label = label
        self.keypath = keypath
        self.modifiers = modifiers
        self.isOn = isOn    
    }
    
    enum ElementKey: CodingKey { case Toggle }
    enum CodingKeys: CodingKey {
        case id
        case label
        case keypath
        case modifiers
        case isOn
    }
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        //        self.elements = try container.decode(SkeletonElementList.self, forKey: .elements)
//        print("Decode SkeletonButton")
        
        if let id =  try container.decodeIfPresent(UUID.self, forKey: .id) {
            self.id = id
        }
        self.keypath = try container.decode(String.self, forKey: .keypath)
        self.label = try container.decode(String.self, forKey: .label)
        self.isOn = try container.decode(Bool.self, forKey: .isOn)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
        
        
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self,
                                                         forKey: .Toggle)
        
        try elementContainer.encode(self.keypath, forKey: .keypath)
        try elementContainer.encode(self.label, forKey: .label)
        try elementContainer.encodeIfPresent(self.isOn, forKey: .isOn)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

public struct SkeletonPicker: Codable, Identifiable {
    public var id = UUID()
    public var label: String?
    public var placeholder: String?
    public var elements: ValueTypeList
    public var keypath: String?
    public var optionLabelKeypath: String?
    public var selectionValueKeypath: String?
    public var selectionStateKeypath: String?
    public var selectionActionKeypath: String?
    public var selectionPayloadMode: SkeletonListSelectionPayloadMode?
    public var allowsEmptySelection: Bool?
    public var modifiers: SkeletonModifiers?

    enum ElementKey: CodingKey { case Picker }
    enum CodingKeys: CodingKey {
        case id
        case label
        case placeholder
        case elements
        case keypath
        case optionLabelKeypath
        case selectionValueKeypath
        case selectionStateKeypath
        case selectionActionKeypath
        case selectionPayloadMode
        case allowsEmptySelection
        case modifiers
    }

    public init(
        id: UUID = UUID(),
        label: String? = nil,
        placeholder: String? = nil,
        elements: ValueTypeList = ValueTypeList(),
        keypath: String? = nil,
        optionLabelKeypath: String? = nil,
        selectionValueKeypath: String? = nil,
        selectionStateKeypath: String? = nil,
        selectionActionKeypath: String? = nil,
        selectionPayloadMode: SkeletonListSelectionPayloadMode? = nil,
        allowsEmptySelection: Bool? = nil,
        modifiers: SkeletonModifiers? = nil
    ) {
        self.id = id
        self.label = label
        self.placeholder = placeholder
        self.elements = elements
        self.keypath = keypath
        self.optionLabelKeypath = optionLabelKeypath
        self.selectionValueKeypath = selectionValueKeypath
        self.selectionStateKeypath = selectionStateKeypath
        self.selectionActionKeypath = selectionActionKeypath
        self.selectionPayloadMode = selectionPayloadMode
        self.allowsEmptySelection = allowsEmptySelection
        self.modifiers = modifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedID = try container.decodeIfPresent(UUID.self, forKey: .id) {
            self.id = decodedID
        }
        self.label = try container.decodeIfPresent(String.self, forKey: .label)
        self.placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        self.elements = (try container.decodeIfPresent(ValueTypeList.self, forKey: .elements)) ?? ValueTypeList()
        self.keypath = try container.decodeIfPresent(String.self, forKey: .keypath)
        self.optionLabelKeypath = try container.decodeIfPresent(String.self, forKey: .optionLabelKeypath)
        self.selectionValueKeypath = try container.decodeIfPresent(String.self, forKey: .selectionValueKeypath)
        self.selectionStateKeypath = try container.decodeIfPresent(String.self, forKey: .selectionStateKeypath)
        self.selectionActionKeypath = try container.decodeIfPresent(String.self, forKey: .selectionActionKeypath)
        self.selectionPayloadMode = try container.decodeIfPresent(SkeletonListSelectionPayloadMode.self, forKey: .selectionPayloadMode)
        self.allowsEmptySelection = try container.decodeIfPresent(Bool.self, forKey: .allowsEmptySelection)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)

        try validateSelectionConfiguration()
    }

    public func getElements() async throws -> ValueTypeList {
        if let resolver = CellBase.defaultCellResolver,
           let vault = CellBase.defaultIdentityVault,
           let requester = await vault.identity(for: "private", makeNewIfNotFound: false),
           let keypath = self.keypath,
           let cellURL = try? urlFromKeypath(keypath: keypath)
        {
            let initialElements = try await resolver.get(from: cellURL, requester: requester)
            guard case .list(let valueTypeList) = initialElements else {
                CellBase.diagnosticLog("Skeleton picker expected List value from \(cellURL)", domain: .skeleton)
                return ValueTypeList()
            }
            return valueTypeList
        }

        return ValueTypeList()
    }

    private func urlFromKeypath(keypath: String) throws -> URL {
        var url: URL?
        if keypath.hasPrefix("cell://") {
            url = URL(string: keypath)
        } else {
            url = URL(string: "cell:///Porthole/\(keypath)")
        }
        if let url {
            return url
        }
        throw URLKeypathError.badURL
    }

    public func encode(to encoder: any Encoder) throws {
        try validateSelectionConfiguration()

        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .Picker)
        try elementContainer.encode(self.id, forKey: .id)
        try elementContainer.encodeIfPresent(self.label, forKey: .label)
        try elementContainer.encodeIfPresent(self.placeholder, forKey: .placeholder)
        try elementContainer.encodeIfPresent(self.elements, forKey: .elements)
        try elementContainer.encodeIfPresent(self.keypath, forKey: .keypath)
        try elementContainer.encodeIfPresent(self.optionLabelKeypath, forKey: .optionLabelKeypath)
        try elementContainer.encodeIfPresent(self.selectionValueKeypath, forKey: .selectionValueKeypath)
        try elementContainer.encodeIfPresent(self.selectionStateKeypath, forKey: .selectionStateKeypath)
        try elementContainer.encodeIfPresent(self.selectionActionKeypath, forKey: .selectionActionKeypath)
        try elementContainer.encodeIfPresent(self.selectionPayloadMode, forKey: .selectionPayloadMode)
        try elementContainer.encodeIfPresent(self.allowsEmptySelection, forKey: .allowsEmptySelection)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }

    public func selectionPayload(trigger: SkeletonListSelectionTrigger, rows: [ValueType], selectedIndex: Int?) throws -> ValueType {
        var proxyList = SkeletonList(elements: ValueTypeList())
        proxyList.selectionMode = .single
        proxyList.selectionValueKeypath = selectionValueKeypath
        proxyList.selectionPayloadMode = selectionPayloadMode
        proxyList.allowsEmptySelection = allowsEmptySelection
        return try proxyList.selectionPayload(
            trigger: trigger,
            rows: rows,
            selectedIndices: selectedIndex.map { [$0] } ?? []
        )
    }

    private func validateSelectionConfiguration() throws {
        switch self.selectionPayloadMode {
        case .itemID?, .selectedIDs?:
            if self.selectionValueKeypath?.isEmpty != false {
                throw SkeletonListConfigurationError.missingSelectionValueKeypath(self.selectionPayloadMode!)
            }
        default:
            break
        }
    }
}

public struct SkeletonVisualization: Codable, Identifiable {
    public var id = UUID()
    public var kind: String
    public var keypath: String?
    public var stateKeypath: String?
    public var actionKeypath: String?
    public var spec: ValueType?
    public var modifiers: SkeletonModifiers?

    public init(
        id: UUID = UUID(),
        kind: String,
        keypath: String? = nil,
        stateKeypath: String? = nil,
        actionKeypath: String? = nil,
        spec: ValueType? = nil,
        modifiers: SkeletonModifiers? = nil
    ) {
        self.id = id
        self.kind = kind
        self.keypath = keypath
        self.stateKeypath = stateKeypath
        self.actionKeypath = actionKeypath
        self.spec = spec
        self.modifiers = modifiers
    }

    enum ElementKey: CodingKey { case Visualization }
    enum CodingKeys: CodingKey {
        case id
        case kind
        case keypath
        case stateKeypath
        case actionKeypath
        case spec
        case modifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedID = try container.decodeIfPresent(UUID.self, forKey: .id) {
            self.id = decodedID
        }
        self.kind = try container.decode(String.self, forKey: .kind)
        self.keypath = try container.decodeIfPresent(String.self, forKey: .keypath)
        self.stateKeypath = try container.decodeIfPresent(String.self, forKey: .stateKeypath)
        self.actionKeypath = try container.decodeIfPresent(String.self, forKey: .actionKeypath)
        self.spec = try container.decodeIfPresent(ValueType.self, forKey: .spec)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .Visualization)
        try elementContainer.encode(self.id, forKey: .id)
        try elementContainer.encode(self.kind, forKey: .kind)
        try elementContainer.encodeIfPresent(self.keypath, forKey: .keypath)
        try elementContainer.encodeIfPresent(self.stateKeypath, forKey: .stateKeypath)
        try elementContainer.encodeIfPresent(self.actionKeypath, forKey: .actionKeypath)
        try elementContainer.encodeIfPresent(self.spec, forKey: .spec)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

public struct SkeletonUnsupported: Codable, Identifiable {
    public var id = UUID()
    public var elementType: String
    public var reason: String?
    public var rawPayload: ValueType?
    public var modifiers: SkeletonModifiers?

    enum ElementKey: CodingKey { case Unsupported }
    enum CodingKeys: String, CodingKey {
        case id
        case elementType
        case type
        case reason
        case rawPayload
        case payload
        case modifiers
    }

    public init(
        id: UUID = UUID(),
        elementType: String,
        reason: String? = nil,
        rawPayload: ValueType? = nil,
        modifiers: SkeletonModifiers? = nil
    ) {
        self.id = id
        self.elementType = elementType
        self.reason = reason
        self.rawPayload = rawPayload
        self.modifiers = modifiers
    }

    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys>
        if let wrapper = try? decoder.container(keyedBy: ElementKey.self),
           wrapper.contains(.Unsupported) {
            container = try wrapper.nestedContainer(keyedBy: CodingKeys.self, forKey: .Unsupported)
        } else {
            container = try decoder.container(keyedBy: CodingKeys.self)
        }

        self.id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.elementType = (try? container.decodeIfPresent(String.self, forKey: .elementType))
            ?? (try? container.decodeIfPresent(String.self, forKey: .type))
            ?? "Unknown"
        self.reason = try? container.decodeIfPresent(String.self, forKey: .reason)
        self.rawPayload = (try? container.decodeIfPresent(ValueType.self, forKey: .rawPayload))
            ?? (try? container.decodeIfPresent(ValueType.self, forKey: .payload))
        self.modifiers = try? container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .Unsupported)
        try elementContainer.encode(id, forKey: .id)
        try elementContainer.encode(elementType, forKey: .elementType)
        try elementContainer.encodeIfPresent(reason, forKey: .reason)
        try elementContainer.encodeIfPresent(rawPayload, forKey: .rawPayload)
        try elementContainer.encodeIfPresent(modifiers, forKey: .modifiers)
    }
}

public indirect enum SkeletonElement : Codable, Identifiable {
    case List(SkeletonList)
    case Tree(SkeletonTree)
    case ComponentSurface(SkeletonComponentSurface)
    case Object(SkeletonObject)
    case Spacer(SkeletonSpacer)
    case Image(SkeletonImage)
    case Text(SkeletonText)
    case AttachmentField(SkeletonAttachmentField)
    case FileUpload(SkeletonFileUpload)
    case TextField(SkeletonTextField)
    case TextArea(SkeletonTextArea)
    case HStack(SkeletonHStack)
    case VStack(SkeletonVStack)
    case Reference(SkeletonCellReference)
    case Button(SkeletonButton)
    case Divider(SkeletonDivider)
    case ScrollView(SkeletonScrollView)
    case Section(SkeletonSection)
    case Tabs(SkeletonTabs)
    case NavigationBar(SkeletonNavigationBar)
    case ZStack(SkeletonZStack)
    case Grid(SkeletonGrid)
    case Toggle(SkeletonToggle)
    case Picker(SkeletonPicker)
    case Visualization(SkeletonVisualization)
    case Unsupported(SkeletonUnsupported)
    
    public var id: UUID {
        switch self {
        case .Tree(let value): return value.id
        case .ComponentSurface(let value): return value.id
        case .Text(let value):
            return value.id

        case .AttachmentField(let value):
            return value.id

        case .FileUpload(let value):
            return value.id
            
        case .TextField(let value):
            return value.id

        case .TextArea(let value):
            return value.id

        case .HStack(let value):
            return value.id
            
        case .VStack(let value):
            return value.id
            
        case .Image(let value):
            return value.id
            
        case .List(let value):
            return value.id
            
        case .Object(let value):
            return value.id
            
        case .Spacer(let value):
            return value.id
            
        case .Reference(let value):
            return value.id
            
        case .Button(let value):
            return value.id
            
        case .Divider(let value):
            return value.id
            
        case .ScrollView(let value):
            return value.id
            
        case .Section(let value):
            return value.id

        case .Tabs(let value):
            return value.id

        case .NavigationBar(let value):
            return value.id

        case .ZStack(let value):
            return value.id
            
        case .Grid(let value):
            return value.id
            
        case .Toggle(let value):
            return value.id

        case .Picker(let value):
            return value.id
        case .Visualization(let value):
            return value.id

        case .Unsupported(let value):
            return value.id
        }
    
    }

    private static func rawPayload(from decoder: any Decoder) -> ValueType? {
        guard let container = try? decoder.singleValueContainer() else {
            return nil
        }
        return try? container.decode(ValueType.self)
    }

    private static func unsupported(
        elementType: String,
        reason: String,
        decoder: any Decoder
    ) -> SkeletonElement {
        CellBase.diagnosticLog("Unsupported skeleton element \(elementType): \(reason)", domain: .skeleton)
        return .Unsupported(SkeletonUnsupported(
            elementType: elementType,
            reason: reason,
            rawPayload: rawPayload(from: decoder)
        ))
    }

    private static func decodeKnownElement(
        named key: String,
        from decoder: any Decoder,
        trace: (String) -> Void
    ) -> SkeletonElement? {
        func decode<T: Decodable>(_ type: T.Type, wrap: (T) -> SkeletonElement) -> SkeletonElement {
            do {
                let singleValueContainer = try decoder.singleValueContainer()
                return wrap(try singleValueContainer.decode(T.self))
            } catch {
                trace("Decoding \(key) failed with error: \(error)")
                return unsupported(
                    elementType: key,
                    reason: "Decode failed: \(error)",
                    decoder: decoder
                )
            }
        }

        switch key {
        case "Tree": return decode(SkeletonTree.self, wrap: SkeletonElement.Tree)
        case "ComponentSurface": return decode(SkeletonComponentSurface.self, wrap: SkeletonElement.ComponentSurface)
        case "List":
            return decode(SkeletonList.self, wrap: SkeletonElement.List)
        case "Object":
            return decode(SkeletonObject.self, wrap: SkeletonElement.Object)
        case "Spacer":
            return decode(SkeletonSpacer.self, wrap: SkeletonElement.Spacer)
        case "Image":
            return decode(SkeletonImage.self, wrap: SkeletonElement.Image)
        case "Text":
            return decode(SkeletonText.self, wrap: SkeletonElement.Text)
        case "AttachmentField":
            return decode(SkeletonAttachmentField.self, wrap: SkeletonElement.AttachmentField)
        case "FileUpload":
            return decode(SkeletonFileUpload.self, wrap: SkeletonElement.FileUpload)
        case "TextField":
            return decode(SkeletonTextField.self, wrap: SkeletonElement.TextField)
        case "TextArea":
            return decode(SkeletonTextArea.self, wrap: SkeletonElement.TextArea)
        case "HStack":
            return decode(SkeletonHStack.self, wrap: SkeletonElement.HStack)
        case "VStack":
            return decode(SkeletonVStack.self, wrap: SkeletonElement.VStack)
        case "Reference":
            return decode(SkeletonCellReference.self, wrap: SkeletonElement.Reference)
        case "Button":
            return decode(SkeletonButton.self, wrap: SkeletonElement.Button)
        case "Divider":
            return decode(SkeletonDivider.self, wrap: SkeletonElement.Divider)
        case "ScrollView":
            return decode(SkeletonScrollView.self, wrap: SkeletonElement.ScrollView)
        case "Section":
            return decode(SkeletonSection.self, wrap: SkeletonElement.Section)
        case "Tabs":
            return decode(SkeletonTabs.self, wrap: SkeletonElement.Tabs)
        case "NavigationBar":
            return decode(SkeletonNavigationBar.self, wrap: SkeletonElement.NavigationBar)
        case "ZStack":
            return decode(SkeletonZStack.self, wrap: SkeletonElement.ZStack)
        case "Grid":
            return decode(SkeletonGrid.self, wrap: SkeletonElement.Grid)
        case "Toggle":
            return decode(SkeletonToggle.self, wrap: SkeletonElement.Toggle)
        case "Picker":
            return decode(SkeletonPicker.self, wrap: SkeletonElement.Picker)
        case "Visualization":
            return decode(SkeletonVisualization.self, wrap: SkeletonElement.Visualization)
        case "Unsupported":
            return decode(SkeletonUnsupported.self, wrap: SkeletonElement.Unsupported)
        default:
            return nil
        }
    }

    private static func decodeWrappedElementIfPresent(
        from decoder: any Decoder,
        trace: (String) -> Void
    ) -> SkeletonElement? {
        guard let container = try? decoder.container(keyedBy: DynamicCodingKey.self),
              container.allKeys.count == 1,
              let key = container.allKeys.first else {
            return nil
        }

        do {
            return try container.decode(SkeletonElement.self, forKey: key)
        } catch {
            trace("Decoding nested SkeletonElement with key \(key.stringValue) failed with error: \(error)")
            return unsupported(
                elementType: key.stringValue,
                reason: "Decode failed: \(error)",
                decoder: decoder
            )
        }
    }

    public init(from decoder: any Decoder) throws {
        func trace(_ message: String) {
            CellBase.diagnosticLog(message, domain: .skeleton)
        }

        if let key = decoder.codingPath.last, key.intValue == nil {
            let keyName = key.stringValue
            trace("Decoding key: \(keyName)")
            if let decoded = Self.decodeKnownElement(named: keyName, from: decoder, trace: trace) {
                self = decoded
                return
            }
            if let decoded = Self.decodeWrappedElementIfPresent(from: decoder, trace: trace) {
                self = decoded
                return
            }
            self = Self.unsupported(
                elementType: keyName,
                reason: "Unknown skeleton element type",
                decoder: decoder
            )
            return
        }

        guard let container = try? decoder.container(keyedBy: DynamicCodingKey.self) else {
            self = Self.unsupported(
                elementType: "InvalidSkeletonElement",
                reason: "Expected single-key skeleton element object",
                decoder: decoder
            )
            return
        }

        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            self = Self.unsupported(
                elementType: "InvalidSkeletonElement",
                reason: "Expected one skeleton element key, found \(container.allKeys.count)",
                decoder: decoder
            )
            return
        }

        do {
            self = try container.decode(SkeletonElement.self, forKey: key)
            return
        } catch {
            trace("Decoding SkeletonElement with key \(key.stringValue) failed with error: \(error)")
            self = Self.unsupported(
                elementType: key.stringValue,
                reason: "Decode failed: \(error)",
                decoder: decoder
            )
            return
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        
        var container = encoder.singleValueContainer()
        switch self {
        case let .Tree(value):
            try container.encode(value)
        case let .ComponentSurface(value):
            try container.encode(value)
        case let .List(value):
            try container.encode(value) //
        case let .Object(value):
            try container.encode(value)
        case let .Spacer(value):
            try container.encode(value)
        case let .Image(value):
            try container.encode(value)
        case let .Text(value):
            try container.encode(value)
        case let .AttachmentField(value):
            try container.encode(value)
        case let .FileUpload(value):
            try container.encode(value)
        case let .TextField(value):
            try container.encode(value)
        case let .TextArea(value):
            try container.encode(value)
        case let .HStack(value):
            try container.encode(value)
        case let .VStack(value):
            try container.encode(value)
        case let .Reference(value):
            try container.encode(value)
        case let .Button(value):
            try container.encode(value)
        case let .Divider(value):
            try container.encode(value)
        case let .ScrollView(value):
            try container.encode(value)
        case let .Section(value):
            try container.encode(value)
        case let .Tabs(value):
            try container.encode(value)
        case let .NavigationBar(value):
            try container.encode(value)
        case let .ZStack(value):
            try container.encode(value)
        case let .Grid(value):
            try container.encode(value)
        case let .Toggle(value):
            try container.encode(value)
        case let .Picker(value):
            try container.encode(value)
        case let .Visualization(value):
            try container.encode(value)
        case let .Unsupported(value):
            try container.encode(value)
        }
    }
}
